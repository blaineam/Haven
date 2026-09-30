// Pure helpers for the newer qa-e2e-full.mjs steps (relayfirst, screenshare, callgate, launch,
// responsive). Everything here is a decision over data the harness already read — no I/O — so it is
// unit-tested (e2e-steps.test.mjs, soren suite `qa-harness`) instead of being trusted.

/** A numeric counter from a dump section (missing / non-numeric → 0). */
export function num(v) {
  return typeof v === 'number' && Number.isFinite(v) ? v : 0;
}

/** after[key] - before[key] for two snapshots of the same counter section. */
export function delta(before, after, key) {
  return num(after?.[key]) - num(before?.[key]);
}

// ── Android system UI (uiautomator dump) ────────────────────────────────────────────────────

/** Parse `uiautomator dump` XML into flat nodes: {text, desc, id, cls, clickable, bounds}. */
export function parseUiNodes(xml) {
  const out = [];
  const re = /<node\b([^>]*?)\/?>/g;
  const attr = (s, name) => {
    const m = s.match(new RegExp(`\\s${name}="([^"]*)"`));
    return m ? m[1].replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&#39;/g, "'") : '';
  };
  for (let m; (m = re.exec(String(xml || ''))); ) {
    const a = m[1];
    const b = attr(a, 'bounds').match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
    out.push({
      text: attr(a, 'text'),
      desc: attr(a, 'content-desc'),
      id: attr(a, 'resource-id'),
      cls: attr(a, 'class'),
      clickable: attr(a, 'clickable') === 'true',
      bounds: b ? b.slice(1).map(Number) : null,
    });
  }
  return out;
}

/** First node whose text or content-desc matches `re` (and has bounds). */
export function findNode(nodes, re) {
  return nodes.find((n) => n.bounds && (re.test(n.text) || re.test(n.desc))) || null;
}

/** Tap point for a node's bounds. */
export function center(node) {
  const [x1, y1, x2, y2] = node.bounds;
  return [Math.round((x1 + x2) / 2), Math.round((y1 + y2) / 2)];
}

/** The MediaProjection consent vocabulary across Android 10–15 (AOSP + Pixel system UI). */
export const CONSENT = {
  entire: /^(share )?(the )?entire screen$|^full screen$/i,
  single: /^(share )?(a single|one) app$/i,
  confirm: /^(start|start now|share screen|share|next|start recording|start casting)$/i,
  cancel: /^(cancel|don.t allow|deny)$/i,
  // Anything that says we are looking at the consent surface at all.
  surface: /share your screen|start recording or casting|start casting|will have access to all of the information|screen sharing|share screen with|recording or casting/i,
};

/** Is the consent dialog (or the app chooser that follows "single app") on screen? */
export function isConsentSurface(nodes) {
  return nodes.some((n) => CONSENT.surface.test(n.text) || CONSENT.surface.test(n.desc)
    || CONSENT.entire.test(n.text) || CONSENT.single.test(n.text));
}

/**
 * Foreground service types held by a package, from `dumpsys activity services <pkg>`.
 * Returns the OR of every `foregroundServiceType=0x…` seen (0 when none).
 */
export function fgsTypes(dumpsys) {
  let t = 0;
  for (const m of String(dumpsys || '').matchAll(/foregroundServiceType=0x([0-9a-fA-F]+)/g)) t |= parseInt(m[1], 16);
  return t;
}

/** ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION. */
export const FGS_MEDIA_PROJECTION = 0x20;

export function holdsMediaProjection(dumpsys) {
  return (fgsTypes(dumpsys) & FGS_MEDIA_PROJECTION) !== 0 || /types=[^\n]*mediaProjection/i.test(String(dumpsys || ''));
}

/**
 * HavenScreenShare logcat audit: every "capture started" must be preceded (since the previous
 * capture) by "FGS mediaProjection ready=true", and nothing may say the start failed.
 * Returns {captures, ordered, failures:[lines]}.
 */
export function auditShareLog(text) {
  const lines = String(text || '').split('\n');
  let readySinceLastCapture = false;
  let captures = 0;
  let ordered = true;
  const failures = [];
  for (const l of lines) {
    if (/FGS mediaProjection ready=true/.test(l)) readySinceLastCapture = true;
    if (/capture started/.test(l)) {
      captures++;
      if (!readySinceLastCapture) ordered = false;
      readySinceLastCapture = false;
    }
    if (/screen share start failed|SecurityException/.test(l)) failures.push(l.trim());
  }
  return { captures, ordered, failures };
}

/** Longest side of a frame (0 when unknown). */
export function longSide(w, h) {
  return Math.max(num(w), num(h));
}

/** Every remote track slot on an Apple dump's call.remote_tracks, flattened. */
export function remoteSlots(call) {
  const out = [];
  for (const [peer, slots] of Object.entries(call?.remote_tracks || {})) {
    out.push({ peer, camera: slots?.camera || null, screen: slots?.screen || null });
  }
  return out;
}

/** The slots of whichever peer is sharing its screen (first one found), or null. */
export function sharedScreen(call) {
  return remoteSlots(call).find((s) => s.screen) || null;
}

// ── heavy-work gate ─────────────────────────────────────────────────────────────────────────

/** The gate is closed FOR THE GIVEN REASON (e.g. "haven-call", "forced=qa"). */
export function suspendedFor(hw, reasonPart) {
  return hw?.suspended === true && String(hw?.reason || '').includes(reasonPart);
}

/**
 * The gate has let go of `reasonPart`. A simulator's thermal state mirrors the HOST Mac, which may
 * be hot during a QA run, so "suspended=false" alone would be a flaky proxy: the gate may stay
 * closed for heat after the call ends. What must go is the reason the step introduced.
 */
export function liftedFrom(hw, reasonPart) {
  return hw != null && (hw.suspended !== true || !String(hw.reason || '').includes(reasonPart));
}

// ── responsiveness (fix/responsiveness dump fields) ────────────────────────────────────────

export const PERF_FIELDS = [
  'mainStallCount', 'mainStallMaxMs', 'engineUserWaitP95Ms', 'engineUserWaitMaxMs',
  'persistExportCount', 'lastPersistExportAtMs', 'refreshCount', 'mediaStoreOnMainCount', 'heldRefSetSize',
];

/** Which of the responsiveness fields a dump's `perf` section is missing. */
export function missingPerfFields(perf) {
  if (!perf || typeof perf !== 'object') return [...PERF_FIELDS];
  return PERF_FIELDS.filter((k) => typeof perf[k] !== 'number');
}

/** Persist-export allowance during a burst: at most one per 2.5 s of burst, plus slack of 2. */
export function persistExportAllowance(burstMs) {
  return Math.floor(Math.max(0, burstMs) / 2500) + 2;
}

/**
 * The local latency the last `react` op reported (`react_latency`, Apple): ms from the tap to the
 * feed publishing it. `publishedMs: -1` means nothing published within 5 s — that is a failure, so
 * it reads as Infinity rather than as a fast -1. null when no react has been measured.
 */
export function reactLatency(dump) {
  const r = dump?.react_latency || {};
  if (typeof r.publishedMs === 'number') return r.publishedMs < 0 ? Infinity : r.publishedMs;
  if (typeof r.engineAppliedMs === 'number') return r.engineAppliedMs;
  return null;
}

// ── progress (docs/QA.md "Progress fields") ────────────────────────────────────────────────

/** Is a `got` series monotonically non-decreasing? */
export function nonDecreasing(series) {
  for (let i = 1; i < series.length; i++) if (series[i] < series[i - 1]) return false;
  return true;
}

/**
 * Read the pill's transition log (`sync_badge_history`, newest last) for one circle since `sinceMs`:
 * did it go synced → syncing/retrying (≥1 pending) → synced (0 pending)? Sampling the live pill raced
 * the upload — a small post starts and finishes between two dumps — so the step asserts on the log
 * the app keeps instead. `settled` = the LAST entry after the first send is synced with 0 pending.
 */
export function badgeTransitions(history, { sinceMs = 0, circle } = {}) {
  const rows = (Array.isArray(history) ? history : [])
    .filter((e) => num(e?.atMs) >= sinceMs && (!circle || e?.circle === circle));
  const seq = rows.map((e) => `${e.state}:${num(e.pending)}${e.detail && e.detail !== e.state ? `(${e.detail})` : ''}`);
  const firstSend = rows.findIndex((e) => (e.state === 'syncing' || e.state === 'retrying') && num(e.pending) >= 1);
  const sawSending = firstSend >= 0;
  const last = rows[rows.length - 1];
  const settled = sawSending && rows.length > firstSend + 1 && last?.state === 'synced' && num(last?.pending) === 0;
  return { sawSending, settled, seq };
}

/**
 * Fold one dump's progress fields into a per-ref record for the refs we watch:
 * rec[ref] = {got: [..], total, lanes: Set, present, gaveUpWhileReceiving}.
 */
export function recordProgress(rec, dump, refs, presentOf) {
  const gaveUp = new Set(dump?.media_gave_up || []);
  for (const ref of refs) {
    const r = (rec[ref] ??= { got: [], total: 0, lanes: [], present: false, gaveUpWhileReceiving: false, gaveUp: false });
    const t = (dump?.media_transfers || []).find((x) => x.ref === ref);
    if (t) {
      r.got.push(num(t.got));
      r.total = Math.max(r.total, num(t.total));
      if (!r.lanes.includes(t.lane)) r.lanes.push(t.lane);
    }
    if (gaveUp.has(ref)) {
      r.gaveUp = true;
      // Given up while the series was still climbing = the placeholder lied mid-transfer.
      if (r.got.length >= 2 && r.got[r.got.length - 1] > r.got[r.got.length - 2]) r.gaveUpWhileReceiving = true;
    }
    if (presentOf(ref)) r.present = true;
  }
  return rec;
}

// ── launch ──────────────────────────────────────────────────────────────────────────────────

/** Did `circle` get its first content ingest no later than every other circle that got one? */
export function ingestedFirst(circleFirstIngest, circle) {
  const m = circleFirstIngest || {};
  if (typeof m[circle] !== 'number') return false;
  return Object.entries(m).every(([c, t]) => c === circle || typeof t !== 'number' || m[circle] <= t);
}

/** The first feed paint did not wait on the DM warm (null warm = not gating). */
export function feedNotGatedOnDmWarm(launch) {
  const f = launch?.first_feed_rendered_ms;
  const w = launch?.dm_warmup_done_ms;
  if (typeof f !== 'number') return false;
  return typeof w !== 'number' || f <= w;
}

// ── android emulator health ─────────────────────────────────────────────────────────────────
//
// The 2026-09-30 gate lost its android leg MID-RUN: qemu-system-aarch64 (emulator 36.6.11) aborted
// in its own gRPC server (`__throw_bad_function_call` under `CallbackWithSuccessTag::StaticRun`)
// 5h20m after boot, and the guest had stopped acking network frames minutes before. The harness then
// scored every android-authored satellite lane "never", waited out a 900 s budget on content whose
// author no longer existed, and diagnosed the corpse as "app process GONE". The same host abort is
// on record five times in a week, each 2h49m–6h30m into an emulator's life — an EMULATOR failure,
// not a product one, and it must read as one.

/** adb stderr that means the device itself is gone (not a failing command on a live device). */
export function adbDeviceGone(text) {
  return /no devices\/emulators found|device offline|device '[^']*' not found|device not found/i.test(String(text || ''));
}

/** The qemu host crash report written during this run, if any: newest `qemu-system-*.ips` whose
 *  mtime is at/after `sinceMs`. `reports` = [{ name, mtimeMs }]. */
export function qemuCrashSince(reports, sinceMs) {
  const hits = (reports || [])
    .filter((r) => /^qemu-system-.*\.ips$/.test(r?.name || '') && num(r.mtimeMs) >= num(sinceMs))
    .sort((a, b) => b.mtimeMs - a.mtimeMs);
  return hits[0]?.name || null;
}
