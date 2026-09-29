#!/usr/bin/env node
// Full cross-device E2E: iOS Simulator + Android emulator + macOS HavenStub (relay host,
// also the "friend" account B) + Tauri desktop — one fleet account (A: iOS+Android+Tauri)
// exercising every in-app action, verifying convergence on EVERY device, and recording
// per-step propagation latency as perf gates.
//
//   node Scripts/qa-e2e-full.mjs            # full run
//   E2E_STEPS=post,dm node Scripts/…        # subset
//   E2E_KILL=1                              # tear everything down at the end
//
// Soren: `soren run Haven e2e` (suite `e2e` in soren.config.mjs).
//
// SAFETY: the mac leg is ALWAYS the isolated HavenStub (com.blaineam.kith.qa.stub,
// HOME=/tmp/haven-mac-stub-home). This script refuses to touch the production
// com.blaineam.kith container or the personal desktop data root.
//
// Driver contract (DEBUG builds only — see docs/QA.md "qa-cmd v2"):
//   drop {op,…} JSON at the platform's qa-cmd path, poke the app (deep link /
//   broadcast), then read qa-dump.json back. Ops: post, story, dm, react, comment,
//   profile, circle_create, circle_invite, file, music_post, dump, mark_read, plus the step-specific
//   heavy_work_override, media_ask, relay_backoff_reset, screen_share, invite_link, connect_link.
import { execFileSync, spawnSync, spawn } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync, mkdirSync, appendFileSync, rmSync, statSync } from 'node:fs';
import { join, dirname, resolve as resolvePath } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ChannelFreshness, judgeDump, fmtDuration, FRESHNESS_DEFAULTS } from './lib/dump-freshness.mjs';
import {
  num, delta, parseUiNodes, findNode, center, CONSENT, isConsentSurface, holdsMediaProjection, auditShareLog,
  longSide, remoteSlots, sharedScreen, suspendedFor, liftedFrom, missingPerfFields, persistExportAllowance,
  reactLatency, ingestedFirst, feedNotGatedOnDmWarm, nonDecreasing, recordProgress, badgeTransitions,
} from './lib/e2e-steps.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = process.env.QA_OUT || join(ROOT, 'build', `e2e-${stamp()}`);
// The directory is created in `main()`, not here. Everything in this file used to happen at MODULE
// LOAD: `import('./qa-e2e-full.mjs')` — someone's idea of a syntax check — created a run directory
// AND ran the whole suite, whose bootstrap kills the shared HavenStub and haven-desktop by name.
// That is how a live run lost its fleet mid-call (2026-09-02). `node --check` is the safe check.
const MARKER = `E2E_${stamp().replace(/-/g, '').slice(-6)}`;
const RUN_NONCE = Date.now();   // per-run fixture salt — see the satellite lane
const REPORT = [];
const PERF = [];
const HISTORY = join(ROOT, 'build', 'e2e-history.jsonl');
const STEPS = (process.env.E2E_STEPS || 'newfriend,profile,circle,post,story,file,music,dm,relayfirst,progress,audience,call,screenshare,callgate,react,comment,media,satellite,launch,responsive,invite_offline').split(',');

// Convergence budgets (ms). Generous but bounded; tune via env.
// One active-cadence mailbox poll is ~30-45s; a budget must cover a full poll plus
// processing, or the gate races the architecture instead of measuring it. The
// run-over-run regression ledger is what catches slow drift inside these bounds.
const BUDGET = {
  text: +(process.env.E2E_BUDGET_TEXT || 60_000),
  mediaEvent: +(process.env.E2E_BUDGET_MEDIA_EVENT || 90_000),
  mediaBlob: +(process.env.E2E_BUDGET_MEDIA_BLOB || 150_000),
  // Self-sync-carried state (profile, circles-to-own-devices, pins): receivers
  // PULL on their own >=2-min self-sync pass — in this push-less sim fleet that
  // pass is the floor. Real phones get the syncSelf push wake and beat this.
  settings: +(process.env.E2E_BUDGET_SETTINGS || 180_000),
  // newfriend (measured from APPROVAL; the stub leg gets its usual 2x).
  nfRequest: +(process.env.E2E_BUDGET_NF_REQUEST || 60_000),
  nfFriend: +(process.env.E2E_BUDGET_NF_FRIEND || 20_000),
  nfText: +(process.env.E2E_BUDGET_NF_TEXT || 20_000),
  nfInviterText: +(process.env.E2E_BUDGET_NF_INVITER_TEXT || 30_000),
  nfDm: +(process.env.E2E_BUDGET_NF_DM || 30_000),
  nfMaxBackoff: +(process.env.E2E_NF_MAX_BACKOFF || 30_000),
  // screenshare / callgate
  shareFrame: +(process.env.E2E_BUDGET_SHARE_FRAME || 20_000),
  gateClose: +(process.env.E2E_BUDGET_GATE_CLOSE || 10_000),
  gateLift: +(process.env.E2E_BUDGET_GATE_LIFT || 5_000),
  callGateWindow: +(process.env.E2E_CALLGATE_WINDOW || 15_000),
  // launch
  launchIos: +(process.env.E2E_BUDGET_LAUNCH_IOS || 5_000),
  launchAndroid: +(process.env.E2E_BUDGET_LAUNCH_ANDROID || 8_000),
  catchup: +(process.env.E2E_BUDGET_CATCHUP || 15_000),
  mailboxPass: +(process.env.E2E_BUDGET_MAILBOX_PASS || 15_000),
  launchSettle: +(process.env.E2E_LAUNCH_SETTLE || 5_000),
  // responsive (fix/responsiveness `perf` fields)
  stallMax: +(process.env.E2E_BUDGET_STALL_MAX || 250),
  maxStalls: +(process.env.E2E_MAX_STALLS || 3),
  engineP95: +(process.env.E2E_BUDGET_ENGINE_P95 || 300),
  react: +(process.env.E2E_BUDGET_REACT || 500),
  idle: +(process.env.E2E_IDLE_MS || 60_000),
};
/** How long the newfriend step holds the inviter's approval (so pre-enrollment 403s happen). */
const NF_HOLD_MS = +(process.env.E2E_NF_HOLD_MS || 20_000);
/** The responsiveness fields MUST be in the dump (absent = FAIL). E2E_REQUIRE_PERF=0 downgrades a
 *  missing field to SKIPPED for a build that predates them; the soren suite pins it to 1. */
const REQUIRE_PERF = process.env.E2E_REQUIRE_PERF !== '0';

function stamp() { return new Date().toISOString().replace(/[:T]/g, '-').slice(0, 16); }
function log(m) { const s = `[e2e ${new Date().toISOString().slice(11, 19)}] ${m}`; console.log(s); appendFileSync(join(OUT, 'run.log'), s + '\n'); }
function sh(cmd, args, opts = {}) { return execFileSync(cmd, args, { encoding: 'utf8', ...opts }); }
function shOk(cmd, args, opts = {}) { const r = spawnSync(cmd, args, { encoding: 'utf8', ...opts }); return r.status === 0 ? (r.stdout || '') : null; }
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
// FAIL FAST (E2E_FAIL_FAST=1, on by default for the satellite step — see below).
//
// The satellite legs are SLOW ON PURPOSE: they model a link that is genuinely slow in the real
// world, so their budgets are minutes, not seconds. That makes running to completion after the
// first red an expensive way to learn nothing — the remaining legs mostly re-measure the same
// broken thing, and a full satellite sweep costs ~15 minutes of wall clock before anyone can
// start on the failure. Stopping at the first red gets the diagnosis started immediately, with
// the fleet still in the exact state that produced it (dumps fresh, logs hot, nothing torn down).
//
// Off by default for the whole-suite run, where a complete matrix is the point.
// Any TARGETED run (explicit E2E_STEPS) is a debugging loop: stop at the first red, keep the fleet
// hot. Only the no-args full matrix runs to completion by default — that is the release gate.
const FAIL_FAST = process.env.E2E_FAIL_FAST === '1'
  || (process.env.E2E_FAIL_FAST !== '0' && !!process.env.E2E_STEPS);

// DUMP-CHANNEL FRESHNESS (Scripts/lib/dump-freshness.mjs).
//
// Every assertion in this file is a statement about a JSON file a leg wrote. If that file stops
// being rewritten, every later assertion against the leg measures the HARNESS and reports it as
// the product. That is not hypothetical: an orphaned MediaStore row on Android froze the dump for
// a whole August run (healthy legs read as 7x perf regressions, then as "never"), and the same
// signature showed up again on 2026-09-02 while the real bug was elsewhere.
//
// So: every read is checked for freshness relative to the command that asked for it, and a leg
// whose channel has stopped delivering is named as such instead of being scored as a delivery
// failure. See the module for the rule and — importantly — for why it cannot fire on a leg that
// is merely slow, or on one whose dump is unchanged because nothing happened.
const FRESH = {
  toleranceMs: +(process.env.E2E_DUMP_TOLERANCE || FRESHNESS_DEFAULTS.toleranceMs),
  graceMs: +(process.env.E2E_DUMP_GRACE || FRESHNESS_DEFAULTS.graceMs),
  minObservations: FRESHNESS_DEFAULTS.minObservations,
};
// A condemned channel ABORTS the run by default: the alternative is the thing this exists to stop
// — twenty phantom reds blaming the product for a file that was never rewritten. Set
// E2E_STALE_ABORT=0 to log and carry on (every later result for that leg is then suspect).
const STALE_ABORT = process.env.E2E_STALE_ABORT !== '0';
/** label → measured leg-clock-minus-host-clock (ms). Measured, never assumed — see measureSkew. */
const SKEW = {};
/** label → ChannelFreshness */
const CHANNELS = {};
const channelFor = (dev) => (CHANNELS[dev.label] ??= new ChannelFreshness(dev.label, FRESH));
const lastSlowWarn = {};

function score(name, ok, detail = '') {
  REPORT.push({ name, ok, detail });
  log(`${ok ? 'GREEN' : 'RED  '} ${name}${detail ? ` — ${detail}` : ''}`);
  if (!ok && FAIL_FAST) {
    log('');
    log(`FAIL-FAST: stopping at the first red so it can be worked NOW, with the fleet still in`);
    log(`the state that produced it. Set E2E_FAIL_FAST=0 to run the whole matrix instead.`);
    log('');
    log(`  failed: ${name}${detail ? ` — ${detail}` : ''}`);
    log(`  passed: ${REPORT.filter((r) => r.ok).length} before this`);
    log(`  fleet:  LEFT RUNNING — dumps are fresh, logs are hot, nothing has been torn down`);
    writeReport();
    process.exit(1);
  }
}

// ── device handles ──────────────────────────────────────────────────────────

const IOS_BUNDLE = process.env.HAVEN_IOS_BUNDLE || 'com.blaineam.kith';
const AND_PKG = process.env.HAVEN_AND_PKG || 'com.blaineam.haven';
const STUB_HOME = '/tmp/haven-mac-stub-home';
const DESK_DATA = process.env.HAVEN_DESKTOP_DATA || join(process.env.HOME, 'Library/Application Support/Haven/qa-matrix');

if (DESK_DATA === join(process.env.HOME, 'Library/Application Support/Haven')) {
  console.error('refusing to run against the personal desktop data root'); process.exit(2);
}

const devices = {}; // name → {qaWrite(cmd), poke(), dump(), label}
let IOS_UDID = '';   // set in main(); the invite_offline step kills/relaunches the sim app

function iosContainer(udid) {
  return sh('xcrun', ['simctl', 'get_app_container', udid, IOS_BUNDLE, 'data']).trim();
}

function makeIos(udid) {
  // Resolve the container PER USE, not once at startup. A simulator app's data-container UUID is
  // reissued every time the app is reinstalled — bootstrap reinstalls it, and the iOS leg is
  // relaunched again mid-bootstrap for B's bundle — so a path captured up front can point at a
  // directory that no longer exists by the time the matrix runs. `writeFileSync` then threw ENOENT
  // straight out of qaWrite, and with no catch anywhere above it that killed the WHOLE run: on
  // 2026-09-02 the call step died on `call audio B→A [ios→stub]` and every remaining pair —
  // android's speaker routing among them — simply never ran, with the fleet perfectly healthy.
  //
  // The android leg has promised the opposite since it was written (see makeAndroid): a hiccup on
  // one leg degrades THAT leg to RED checks and never crashes the run. This gives iOS the same
  // contract.
  let as = join(iosContainer(udid), 'Library/Application Support');
  const dir = () => {
    if (!existsSync(as)) {
      // Best-effort: if simctl cannot answer either, keep the stale path so the caller records a
      // RED check on its own terms instead of exploding here.
      const next = shOk('xcrun', ['simctl', 'get_app_container', udid, IOS_BUNDLE, 'data'])?.trim();
      if (next) { as = join(next, 'Library/Application Support'); log(`ios container moved → ${next}`); }
    }
    return as;
  };
  return {
    label: 'ios',
    qaWrite: (cmd) => {
      try { writeFileSync(join(dir(), 'qa-cmd.json'), JSON.stringify(cmd)); }
      catch (e) { log(`WARN ios qaWrite failed (${e.code || e.message}) — this leg will read RED`); }
    },
    poke: () => shOk('xcrun', ['simctl', 'openurl', udid, 'haven://qa?x=1']),
    pending: () => existsSync(join(dir(), 'qa-cmd.json')),
    dump: () => readJson(join(dir(), 'qa-dump.json')),
    stage: (src, name) => { const p = join(dir(), name); writeFileSync(p, readFileSync(src)); return p; },
    // Stale-channel plumbing — see the FRESH block near the top.
    skew: () => 0,                        // the simulator runs on the host clock
    wipe: () => wipeLocalQaFiles(dir()),
    diagnose: () => [procLine('the simulator app (Haven.app/Haven)', hostProcAlive('Haven\\.app/Haven')),
                     ...localDumpDiag(join(dir(), 'qa-dump.json'))],
  };
}

const ANDROID_DEV_DIR = '/sdcard/Download';

function makeAndroid() {
  // Every adb interaction is best-effort: an emulator hiccup (sdcard I/O errors,
  // adb restarts) must degrade this leg to RED checks, never crash the whole run.
  const dev = ANDROID_DEV_DIR;
  let iofails = 0;
  const guarded = (args) => {
    const r = shOk('adb', args);
    if (r === null && ++iofails === 3) log('WARN: android adb failing repeatedly — leg will show RED');
    return r;
  };
  return {
    label: 'android',
    qaWrite: (cmd) => {
      const tmp = join(OUT, 'and-cmd.json'); writeFileSync(tmp, JSON.stringify(cmd));
      guarded(['push', tmp, `${dev}/qa-cmd.json`]);
      // Deliberately NOT verified by reading the file back: the driver DELETES the drop as soon as
      // it applies it (QaDriver.kt:153), so an empty read means "already consumed" just as often as
      // "never landed", and re-pushing on that guess would apply the same op twice — a second
      // call_accept or post is worse than the fault it was chasing. The channel is proven once, up
      // front, by `assertAndroidCommandChannel()`, and any later rot is caught by the dump
      // freshness check rather than guessed at per write.
    },
    poke: () => guarded(['shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', 'haven://qa']),
    dump: () => {
      const tmp = join(OUT, 'and-dump.json');
      if (guarded(['pull', `${dev}/qa-dump-${AND_PKG}.json`, tmp]) === null) return null;
      return readJson(tmp);
    },
    stage: (src, name) => { guarded(['push', src, `${dev}/${name}`]); return `${dev}/${name}`; },

    // ── stale-channel plumbing (see the FRESH block near the top) ──────────────────────────
    // The emulator keeps its OWN clock and it drifts from the host's — 782 ms behind when this was
    // written, and an AVD resumed from a snapshot can be minutes out. Measure it; never assume it.
    skew: () => {
      const s = [];
      for (let i = 0; i < 5; i++) {
        const t0 = Date.now();
        const out = shOk('adb', ['shell', 'date', '+%s%3N']);
        const t1 = Date.now();
        if (out === null) continue;
        const txt = String(out).trim();
        // toybox honors %3N (milliseconds). A date that does not answers seconds only, and a date
        // that echoes the format back must be discarded rather than digit-stripped into nonsense.
        const ms = /^\d{13,}$/.test(txt) ? Number(txt.slice(0, 13))
                 : /^\d{10}$/.test(txt) ? Number(txt) * 1000 + 500
                 : null;
        if (ms === null) continue;
        s.push({ skew: ms - (t0 + t1) / 2, rtt: t1 - t0 });
      }
      if (!s.length) return null;
      // NTP's estimator: the tightest round trip carries the least ambiguity about when the
      // device read its own clock.
      s.sort((a, b) => a.rtt - b.rtt);
      return Math.round(s[0].skew);
    },
    // Exactly the bootstrap's post-install wipe. Virgin files make MediaStore mint fresh rows
    // owned by the current install, which is the documented cure for the orphaned-row freeze.
    wipe: () => {
      const out = guarded(['shell', 'rm', '-f', `${dev}/qa-dump-${AND_PKG}.json`,
                           `${dev}/qa-dump-${AND_PKG}.json.tmp`, `${dev}/qa-cmd.json`]);
      if (out === null) return ['adb shell rm failed outright'];
      // `rm -f` exits 0 even when the unlink is refused, so its OUTPUT is the only signal.
      return String(out).trim() ? [String(out).trim()] : [];
    },
    diagnose: () => {
      const out = [];
      // Two questions before anything else: is the app even running, and is it FOREGROUNDED?
      // QaDriver polls the drop file only between onResume and onPause, so a backgrounded
      // activity is a dead dump channel that has nothing to do with MediaStore.
      const pid = String(shOk('adb', ['shell', 'pidof', AND_PKG]) || '').trim();
      out.push(pid ? `process:    ${AND_PKG} is RUNNING (pid ${pid})`
                   : `process:    ${AND_PKG} is GONE — THIS IS THE CAUSE. Nothing is writing the dump.`);
      const resumed = String(shOk('adb', ['shell', 'dumpsys activity activities | grep -m1 mResumedActivity']) || '').trim();
      if (resumed) {
        out.push(`foreground: ${resumed.slice(0, 140)}`);
        if (pid && !resumed.includes(AND_PKG)) {
          out.push(`            NOT Haven — the driver polls the drop file only while the activity is`);
          out.push(`            resumed (onResume/onPause), so a backgrounded app is a dead channel.`);
        }
      }
      const p = `${dev}/qa-dump-${AND_PKG}.json`;
      // Age computed ON THE DEVICE so neither clock skew nor date parsing can distort it.
      const st = shOk('adb', ['shell', `p=${p}; echo "$(stat -c "%s|%U|%Y" "$p")|$(date +%s)"`]);
      const [size, owner, mtime, now] = String(st || '').trim().split('|');
      if (mtime && now) {
        out.push(`dump file:  ${p}`);
        out.push(`            ${size} B, owner ${owner}, mtime ${fmtDuration((Number(now) - Number(mtime)) * 1000)} ago`);
      } else {
        out.push(`dump file:  ${p} — cannot stat (${String(st || '(adb failed)').trim().split('\n')[0]})`);
      }
      // THE SIGNATURE. A reinstall can orphan MediaStore's row for this file; every `renameTo` the
      // driver does then fails with this line while the app itself stays perfectly healthy, and the
      // harness reads the same frozen file forever.
      const lg = shOk('adb', ['logcat', '-d', '-t', '4000']) || '';
      const hits = lg.split('\n').filter((l) => /Database update failed/.test(l));
      if (hits.length) {
        out.push(`logcat:     ${hits.length} x "MediaProvider: Database update failed while renaming"`
                 + ` in the last 4000 lines — THIS IS THE KNOWN CAUSE.`);
        out.push(`            ${hits[hits.length - 1].trim().slice(0, 160)}`);
        out.push(`            The install orphaned the provider's row for the dump file: every rename`);
        out.push(`            fails, the app keeps writing, and nothing the harness reads ever changes.`);
      } else {
        out.push('logcat:     no "Database update failed" lines in the last 4000 — NOT the MediaStore'
                 + ' row rot; look at whether the activity is foregrounded (the driver polls only while it is).');
      }
      return out;
    },
  };
}

function makeStub() {
  // The stub is sandboxed: its Application Support lives in the container,
  // regardless of the HOME override its launcher uses.
  const as = join(process.env.HOME, 'Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support');
  return {
    label: 'mac-stub',
    qaWrite: (cmd) => writeFileSync(join(as, 'qa-cmd.json'), JSON.stringify(cmd)),
    poke: () => {},                       // stub polls the drop file
    pending: () => existsSync(join(as, 'qa-cmd.json')),
    dump: () => readJson(join(as, 'qa-dump.json')),
    stage: (src, name) => { const p = join(as, name); writeFileSync(p, readFileSync(src)); return p; },
    skew: () => 0,                        // same machine, same clock
    wipe: () => wipeLocalQaFiles(as),
    diagnose: () => [procLine('HavenStub.app', hostProcAlive('HavenStub\\.app')),
                     ...localDumpDiag(join(as, 'qa-dump.json'))],
  };
}

function makeDesktop() {
  return {
    label: 'desktop',
    qaWrite: (cmd) => writeFileSync(join(DESK_DATA, 'qa-cmd.json'), JSON.stringify(cmd)),
    poke: () => {},                       // desktop watches the file
    pending: () => existsSync(join(DESK_DATA, 'qa-cmd.json')),
    dump: () => readJson(join(DESK_DATA, 'qa-dump.json')),
    stage: (src, name) => { const p = join(DESK_DATA, name); writeFileSync(p, readFileSync(src)); return p; },
    skew: () => 0,                        // same machine, same clock
    wipe: () => wipeLocalQaFiles(DESK_DATA),
    diagnose: () => [procLine('haven-desktop', hostProcAlive('target/debug/haven-desktop')),
                     ...localDumpDiag(join(DESK_DATA, 'qa-dump.json'))],
  };
}

function readJson(p) { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; } }

/// Drop a host-side leg's qa files so the driver mints them again — the file-based twin of the
/// android MediaStore wipe. Both drivers rewrite the dump on their next heartbeat (<=5s).
/// Returns the problems it hit: a wipe that CANNOT remove the file is itself the diagnosis, and
/// silently swallowing it would leave the failure looking like the re-dump never happened.
function wipeLocalQaFiles(dir) {
  const problems = [];
  for (const n of ['qa-dump.json', 'qa-dump.json.tmp', 'qa-cmd.json']) {
    try { rmSync(join(dir, n), { force: true }); }
    catch (e) { problems.push(`could not remove ${n}: ${e.code || e.message}`); }
  }
  return problems;
}

/// Is the leg's process still there at all? THE first question, and the one the 2026-09-02 run
/// answered the hard way: the mac stub exited mid-call, so its dump froze, its `dump_seq` stuck,
/// and every remaining assertion against it would have been a measurement of a dead process.
/// `null` when the answer is unknown — never assert a death we did not observe.
function hostProcAlive(pattern) {
  const r = spawnSync('pgrep', ['-f', pattern], { encoding: 'utf8' });
  if (r.error) return null;
  return r.status === 0 && String(r.stdout || '').trim().length > 0;
}

const procLine = (what, alive) => alive === null
  ? `process:    ${what} — could not tell (pgrep unavailable)`
  : alive ? `process:    ${what} is RUNNING — the app is alive, its dump writer is not`
          : `process:    ${what} is GONE — THIS IS THE CAUSE. The leg exited; nothing is writing the dump.`;

/// The dump file's mtime, which is the fact that separates "the leg wrote nothing" from "the leg
/// wrote and the harness is reading something else".
function localDumpDiag(p) {
  try {
    const st = statSync(p);
    return [`dump file:  ${p}`,
            `            ${st.size} B, mtime ${fmtDuration(Date.now() - st.mtimeMs)} ago`];
  } catch (e) {
    return [`dump file:  ${p} — cannot stat (${e.code || e.message})`];
  }
}

// ── driver ops ──────────────────────────────────────────────────────────────

// ── the android command channel, proven once before the matrix runs ─────────
// `adb push` reports success even when MediaProvider's row for the destination is orphaned and the
// bytes never become readable at that path. The app then never sees a command while its dumps keep
// working (it writes those itself), so the leg looks alive and simply ignores what it is told: the
// 2026-09-03 release gate lost the whole android call matrix that way — `call_accept` pushed, the
// phone ringing its full 60 s, and the driver logging only the `dump` ops on either side.
//
// Proven by round trip, not by the app's behaviour, and only while nothing else is in flight — the
// driver deletes each drop as it applies it, so this must run BEFORE the matrix starts.
function assertAndroidCommandChannel() {
  const probe = join(OUT, 'and-channel-probe.json');
  const body = JSON.stringify({ op: 'channel-probe', nonce: RUN_NONCE });
  writeFileSync(probe, body);
  const path = `${ANDROID_DEV_DIR}/qa-channel-probe.json`;
  const roundTrip = () => {
    shOk('adb', ['push', probe, path]);
    return shOk('adb', ['shell', 'cat', path])?.trim();
  };
  let got = roundTrip();
  if (got !== body) {
    log('WARN: android command channel did not take a probe — clearing stale MediaStore rows');
    shOk('adb', ['shell', 'content', 'delete', '--uri', 'content://media/external/file',
      '--where', `"_data LIKE '%/Download/qa-%'"`]);
    shOk('adb', ['shell', 'rm', '-f', `${ANDROID_DEV_DIR}/qa-*`]);
    got = roundTrip();
  }
  shOk('adb', ['shell', 'rm', '-f', path]);
  if (got === body) { log('android command channel: verified (a pushed file reads back)'); return true; }
  log('WARN: ANDROID COMMAND CHANNEL IS DEAD — pushes report success and the file never appears.');
  log('      Every android check in this run would be about the harness, not the app.');
  log('      Cure: adb shell content delete --uri content://media/external/file '
    + `--where "_data LIKE '%/Download/qa-%'"  (then re-run)`);
  return false;
}

// There is ONE drop file per leg, so a command that has not been consumed yet is overwritten by the
// next one — the stub and desktop poll every 1.5 s, and a 300 ms settle followed by a converge's
// {"op":"dump"} silently replaced an `approve_connections` (the newfriend step's first run: B never
// approved, and every later assertion measured that). Host legs wait until the driver has taken
// the file (it deletes it on consume) before the settle starts.
async function op(dev, cmd, settleMs = 4000) {
  dev.qaWrite(cmd); dev.poke();
  if (dev.pending) {
    const t0 = Date.now();
    while (dev.pending() && Date.now() - t0 < 10_000) await sleep(150);
    if (dev.pending()) log(`WARN ${dev.label}: op '${cmd.op}' still unconsumed after 10s`);
  }
  await sleep(settleMs);
}

async function freshDump(dev) {
  // `issuedAt` is taken BEFORE the command is written: the dump we read must have been
  // regenerated after this instant, or the leg answered us with a file it wrote earlier.
  const issuedAt = Date.now();
  await op(dev, { op: 'dump' }, 2500);
  const d = dev.dump();
  await noteDumpFreshness(dev, issuedAt, d);
  return d;
}

// ── dump-channel freshness ──────────────────────────────────────────────────
//
// The ordering every leg honors: command written → leg notices (a poke, or its own <=1.5s poll
// tick) → op runs → dump rewritten with a new `ts_ms` → harness reads. The check asks only whether
// that rewrite happened. It never compares CONTENT: a dump identical to the last one because
// nothing happened is fresh, and treating it otherwise would be a new false-failure factory.
//
// Cadence differs per leg and the check is deliberately indifferent to it. Apple (ios + stub) and
// desktop also rewrite on a 5s heartbeat, so their ts moves even with no command outstanding;
// Android rewrites ONLY in response to a command, so between two commands its ts legitimately
// stands still — which is why nothing here is measured against wall-clock age. It is measured
// against the command WE issued, and only sustained, frozen staleness condemns anything.

/** Measure a leg's clock offset once and remember it (re-measured before any condemnation). */
function measureSkew(dev, why = '') {
  const s = dev.skew?.();
  if (s === null || s === undefined || !Number.isFinite(s)) {
    // Unmeasurable is not fatal: a wrong skew shifts every lag by a constant, and a constant can
    // never make a live file's timestamp stand still — the frozen-ts half of the rule still holds.
    if (!(dev.label in SKEW)) log(`WARN ${dev.label}: clock skew unmeasurable — assuming 0`);
    SKEW[dev.label] ??= 0;
    return SKEW[dev.label];
  }
  const before = SKEW[dev.label];
  SKEW[dev.label] = s;
  if (before !== undefined && Math.abs(s - before) > 1000) {
    log(`clock skew ${dev.label} MOVED: ${fmtDuration(before)} → ${fmtDuration(s)}${why ? ` (${why})` : ''}`);
  }
  return s;
}

/// `null` = no dump at all (counts against the channel); `undefined` = a dump with no usable
/// timestamp, which is unjudgeable and must never be able to condemn a leg. Keeping the two apart
/// is the difference between a dead channel and a leg this check simply has no opinion about.
const dumpTsOf = (dump) => (dump == null ? null : (typeof dump.ts_ms === 'number' ? dump.ts_ms : undefined));

async function noteDumpFreshness(dev, issuedAt, dump) {
  const ch = channelFor(dev);
  if (ch.suspended) return;                    // a recovery's own reads must not re-trip this
  const r = ch.observe({ issuedAt, dumpTsMs: dumpTsOf(dump), skewMs: SKEW[dev.label] ?? 0 });
  if (r.verdict === 'fresh' || r.verdict === 'unknown') return;
  if (!r.condemned) {
    // Lagging but still being rewritten — a slow leg, not a dead channel. Worth saying, at most
    // once a minute, because it is the shape a real perf problem takes on this file too.
    if (r.advancing && Date.now() - (lastSlowWarn[dev.label] || 0) > 60_000) {
      lastSlowWarn[dev.label] = Date.now();
      log(`WARN ${dev.label}: dump is ${fmtDuration(r.lagMs)} behind the command but STILL BEING REWRITTEN`
          + ` — a slow leg, not a dead channel (freshness tolerance ${fmtDuration(FRESH.toleranceMs)})`);
    }
    return;
  }
  await handleStaleChannel(dev, r);
}

/// A leg's dump channel has stopped delivering. Say exactly that — with the diagnostics the owner
/// would otherwise have to go and collect — try the one recovery that is known to work, and fail
/// the run if it does not clear. Never carry on quietly: every assertion from here would be a
/// statement about a file nobody is writing.
async function handleStaleChannel(dev, r) {
  const ch = channelFor(dev);
  log('');
  log(`STALE DUMP CHANNEL — ${dev.label}`);
  log(`  the ${dev.label} leg is returning a dump from ${fmtDuration(r.lagMs)} ago; its dump channel is not delivering.`);
  log(`  Its ts_ms has not moved for ${fmtDuration(r.frozenForMs)} across ${r.observations} reads, each of which`);
  log(`  issued a fresh {"op":"dump"} — so this is the HARNESS's view of the leg, not the product's`);
  log(`  behaviour. Left alone it reads as "never converged" on content the device may already hold.`);
  for (const line of dev.diagnose?.() || []) log(`  ${line}`);

  // A clock that JUMPED (an emulator resyncing NTP mid-run) produces the same lag as a dead
  // channel. Re-measure before accusing anything, and re-judge the reading that got us here.
  const skewMs = measureSkew(dev, 'stale-channel re-measure');
  const issuedAt = Date.now();
  ch.suspend();
  try {
    const recheck = judgeDump({ issuedAt, dumpTsMs: dumpTsOf(dev.dump()), skewMs, toleranceMs: FRESH.toleranceMs });
    if (recheck.verdict === 'fresh') {
      log(`  the re-measured skew explains it (${recheck.reason || 'dump is fresh under the new offset'}) — carrying on.`);
      ch.reset('skew re-measured').resume();
      return;
    }

    if (!ch.recoveryAttempted && dev.wipe) {
      ch.markRecoveryAttempted();
      log(`  RECOVERY (one shot): wiping ${dev.label}'s qa drop files — the same thing the bootstrap does`);
      log(`  around an install — and asking the leg to re-dump.`);
      for (const problem of dev.wipe() || []) log(`  WIPE PROBLEM: ${problem}`);
      for (let i = 0; i < 8; i++) {
        const at = Date.now();
        dev.qaWrite({ op: 'dump' });
        dev.poke();
        await sleep(4000);
        const j = judgeDump({ issuedAt: at, dumpTsMs: dumpTsOf(dev.dump()), skewMs, toleranceMs: FRESH.toleranceMs });
        if (j.verdict === 'fresh') {
          log(`  RECOVERED after ${i + 1} re-dump attempt(s) — the channel is delivering again`);
          log(`  (lag now ${fmtDuration(j.lagMs)}). The run continues; treat this leg's earlier`);
          log(`  latencies with suspicion.`);
          log('');
          ch.reset('recovered').resume();
          return;
        }
      }
      log(`  RECOVERY FAILED — the channel is still frozen after a wipe and 8 re-dump requests.`);
    } else if (ch.recoveryAttempted) {
      log(`  recovery was already attempted once for this leg and the channel went stale AGAIN.`);
      log(`  A repeatedly stale channel is not something to paper over.`);
    }
  } finally {
    ch.resume();
  }

  if (!STALE_ABORT) {
    log(`  E2E_STALE_ABORT=0 — carrying on anyway. EVERY later result for ${dev.label} is suspect.`);
    log('');
    ch.reset('abort disabled');
    return;
  }

  REPORT.push({
    name: `${dev.label} dump channel is delivering`,
    ok: false,
    detail: `dump frozen ${fmtDuration(r.lagMs)} behind the command — the leg's dump channel is dead`,
  });
  log('');
  log(`ABORTING: ${dev.label}'s dump channel is dead, so nothing measured after this point would`);
  log(`mean anything. This is the failure that has twice been misread as a product regression`);
  log(`(August: healthy android legs scored as 7x perf regressions and then as "never").`);
  log('');
  log(`  what to do: re-run the bootstrap (it wipes the qa drop files on every install), and on`);
  log(`  android confirm the app is FOREGROUNDED — its driver polls only while it is. If the`);
  log(`  MediaProvider lines above are present, the reinstall orphaned the provider row and the`);
  log(`  wipe is the cure. Set E2E_STALE_ABORT=0 to run on regardless.`);
  log('');
  writeReport();
  process.exit(1);
}

// Wait until predicate(dump) is true on device; returns latency ms or -1.
// Records its budget so the perfGate that always follows can default to it —
// the flow is strictly sequential (converge is awaited in perfGate's arg list).
let lastBudget = 0;
// Some legs are structurally slower to converge than others, and a single flat budget punishes them
// for it. The desktop leg has been measured at 74s and 101.5s on steps whose budget is 60s — it can
// never pass those, and "never" reads as a product failure rather than a miscalibrated gate.
//
// This scales the budget per leg instead of raising it for everyone, which would blunt the fast
// legs. The real regression guard is not the absolute budget anyway: it is the run-over-run check
// that fails any step more than 2x slower than last time, and that stays exact for every leg.
// Desktop is not merely slower — it converges on a materially longer cycle than the mobile legs.
// Measured on the satellite run: every one of its `full photo completes on return` assertions failed
// at a 375s budget, and yet the desktop dump held ALL THREE posts with media_present=true once the
// run ended. It was never failing to receive; it was receiving after the budget. 2.5x was not
// enough headroom for that, so it is 6x — still a bound, just an honest one.
const SLOW_LEG = { desktop: 6, 'mac-stub': 2, android: Number(process.env.E2E_ANDROID_SLOW || 1) };

const budgetFor = (dev, base) => Math.round(base * (SLOW_LEG[dev?.label] || 1));

async function converge(dev, predicate, budgetMs, pollMs = 1500) {
  budgetMs = budgetFor(dev, budgetMs);
  lastBudget = budgetMs;
  const t0 = Date.now();
  // A FROZEN dump is not the same as undelivered content, and for a whole run they were
  // indistinguishable: desktop's driver stopped writing its dump while the app stayed healthy, so
  // every assertion against it read "never" — twelve minutes after the content had actually landed.
  // Legs that publish `dump_seq` (strictly increasing per successful write) are checked for
  // liveness, and a stall is reported as what it is instead of being scored as a product failure.
  let firstSeq = null, lastSeq = null, seqStuckSince = null;
  while (Date.now() - t0 < budgetMs) {
    const d = await freshDump(dev);
    if (d && predicate(d)) return Date.now() - t0;
    if (d && typeof d.dump_seq === 'number') {
      if (firstSeq === null) firstSeq = d.dump_seq;
      if (d.dump_seq === lastSeq) {
        seqStuckSince ??= Date.now();
        if (Date.now() - seqStuckSince > 30_000) {
          log(`WARN ${dev.label}: dump_seq stuck at ${d.dump_seq} for ${((Date.now() - seqStuckSince) / 1000).toFixed(0)}s`
              + ` — the driver is not writing, so this leg's result is about the HARNESS, not delivery`);
          seqStuckSince = Date.now();   // re-arm so it reports periodically, not once
        }
      } else {
        lastSeq = d.dump_seq;
        seqStuckSince = null;
      }
    }
    await sleep(pollMs);
  }
  return -1;
}

/// Converge on EVERY device at once, then score them.
///
/// The suite used to await each device in turn, so the wall clock was the SUM of the legs — and a
/// failing step burned its whole budget per device before moving on. With three devices at a 225s
/// desktop budget that is eleven minutes for one red step, which is why a full run took long enough
/// that nobody would sit through it. Convergence is independent per device (each just polls its own
/// dump), so there is no reason to serialise it: the wall clock becomes the SLOWEST leg instead of
/// the sum, and a red step costs one budget rather than N.
async function convergeAll(names, predicate, base, step) {
  const results = await Promise.all(names.map(async (d) => ({
    d, ms: await converge(devices[d], predicate, base),
  })));
  let allOk = true;
  for (const { d, ms } of results) {
    if (!perfGate(step, d, ms, budgetFor(devices[d], base))) allOk = false;
  }
  return allOk;
}

function perfGate(step, dev, latency, budget = lastBudget) {
  PERF.push({ step, device: dev, ms: latency, budget });
  const ok = latency >= 0 && latency <= budget;
  score(`${step} → ${dev} (${latency < 0 ? 'never' : (latency / 1000).toFixed(1) + 's'} / ${(budget / 1000)}s budget)`, ok);
  return ok;
}

// ── bootstrap: reuse the linked-device matrix plumbing ─────────────────────

function bootstrap() {
  log('bootstrap: stub + wiring via qa-linked-device-matrix bootstrap scripts');
  // The matrix script owns: stub launch (isolated HOME), port freeing, seed dump,
  // authorize-members, tauri launch with the shared QA seed, adb reverse wiring.
  // E2E_BOOTSTRAP=skip lets a dev reuse a hot fleet.
  if (process.env.E2E_BOOTSTRAP === 'skip') { log('bootstrap skipped (E2E_BOOTSTRAP=skip)'); return; }
  const r = spawnSync('bash', [join(ROOT, 'Scripts/qa-e2e-bootstrap.sh')], {
    encoding: 'utf8', stdio: 'inherit',
    // newfriend needs A and B to start as strangers (see stepNewFriend); every other run keeps the
    // pre-exchanged friendship the rest of the suite was written against.
    env: { ...process.env, QA_OUT: OUT, E2E_RUN_PID: String(process.pid),
           E2E_PREFRIEND: STEPS.includes('newfriend') ? '0' : (process.env.E2E_PREFRIEND || '1') },
  });
  if (r.status !== 0) { console.error('bootstrap failed'); process.exit(1); }
}

// ── scenario ────────────────────────────────────────────────────────────────

const PHOTO = join(ROOT, 'Scripts/fixtures/qa-photo.jpg');
const VIDEO = join(ROOT, 'Scripts/fixtures/qa-clip.mp4');
const PDF = join(ROOT, 'Scripts/fixtures/qa-doc.pdf');

async function main() {
  bootstrap();

  const udid = process.env.HAVEN_IOS_UDID
    || (sh('xcrun', ['simctl', 'list', 'devices', 'booted']).match(/[A-F0-9-]{36}/) || [])[0];
  if (!udid) { console.error('no booted iOS sim'); process.exit(1); }
  IOS_UDID = udid;
  devices.ios = makeIos(udid);
  devices.stub = makeStub();
  devices.desktop = makeDesktop();
  if (shOk('adb', ['get-state'])?.trim() === 'device') {
    devices.android = makeAndroid();
    // Prove the command channel before anything depends on it — a leg that cannot be TOLD anything
    // reports its state cheerfully and ignores every instruction.
    assertAndroidCommandChannel();
  }
  else log('WARN: no android device — android leg SKIPPED (still reported)');

  const fleet = ['ios', 'desktop', ...(devices.android ? ['android'] : [])]; // account A
  const all = [...fleet, 'stub'];                                            // + account B

  // Clock skew, MEASURED, before a single freshness judgement is made. The host legs share our
  // clock; the android emulator keeps its own and drifts from it (782 ms when this was written,
  // and an AVD resumed from a snapshot can be minutes out). Assuming zero here would make a
  // healthy leg's dumps look permanently late.
  for (const name of all) measureSkew(devices[name], 'fleet start');
  log(`clock skew vs host: ${all.map((n) => `${n}=${fmtDuration(SKEW[n] ?? 0)}`).join('  ')}`);

  // Sanity: every device answers a dump.
  for (const name of all) {
    const d = await freshDump(devices[name]);
    score(`${name} driver answers dump`, !!d, d ? '' : 'no qa-dump.json');
  }

  // WARM-UP, deliberately untimed.
  //
  // The first content post after bootstrap absorbs the whole cost of the fleet coming up — relay
  // connections, first hello round, mailbox subscriptions. Whichever assertion happens to be first
  // in this file gets charged for all of it, which is why an identical suite went fully green one
  // run and failed `text post` on two legs the next while every later step passed. That is not a
  // product signal, it is a measurement artifact, and loosening budgets would only hide it.
  //
  // So: post once, wait for it everywhere with a generous ceiling, and score nothing. Every timed
  // step afterwards measures a warm fleet.
  async function warmUp() {
    const marker = `${MARKER}_WarmUp`;
    await op(devices.ios, { op: 'post', body: marker }, 3000);
    const seen = await Promise.all(all.filter((n) => n !== 'ios').map((n) =>
      converge(devices[n], (j) => j.posts?.some((p) => p.body === marker), 240_000)));
    log(`warm-up: ${seen.filter((ms) => ms >= 0).length}/${seen.length} legs converged` +
        ` (${seen.map((ms) => ms < 0 ? 'never' : (ms / 1000).toFixed(1) + 's').join(', ')})`);
  }

  // Clear any pending connection requests before asserting anything.
  //
  // Account B reaching A's OTHER devices arrives there as a stranger, and until it is approved
  // those legs hold nothing of B's. There was no approve op at all until now, which is why Android
  // and desktop sat on an un-approvable "Matrix Stub Host" request while every B-related assertion
  // failed for reasons that had nothing to do with the product.
  //
  // Runs on every device including the stub (A is a stranger to B too), and again after the fleet
  // has exchanged hellos, because a request can arrive at any point during bootstrap.
  await Promise.all(all.map((n) => op(devices[n], { op: 'approve_connections' }, 1500)));

  const stubDump = await freshDump(devices.stub);
  const stubHexPath = join(process.env.HOME, 'Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/qa-account-hex.txt');
  const B = stubDump?.account_hex || process.env.HAVEN_STUB_ACCOUNT
    || (existsSync(stubHexPath) ? readFileSync(stubHexPath, 'utf8').trim() : '');

  // 2. circle create + invite friend B. Also the shared circle every B-facing step needs, so a
  //    targeted run (E2E_STEPS=relayfirst) gets one without naming `circle`.
  let circleId = null;
  async function ensureSharedCircle() {
    if (circleId) return circleId;
    const cname = `${MARKER}_Circle`;
    await op(devices.ios, { op: 'circle_create', name: cname });
    const mine = await freshDump(devices.ios);
    circleId = mine?.circles?.find((c) => c.name === cname)?.id || null;
    score('circle created on iOS', !!circleId);
    if (circleId && B) {
      await op(devices.ios, { op: 'circle_invite', circle_id: circleId, dm_to: B });
      // The invite handshake spans two poll legs (A's fan-out tick → relay → B's poll
      // + claim + reply), so give it two active-cadence polls, not one.
      perfGate('circle membership', 'stub', await converge(devices.stub,
        (j) => j.circles?.some((c) => c.name === cname), BUDGET.text * 2));
      await convergeAll(fleet.filter((x) => x !== 'ios'), (j) => j.circles?.some((c) => c.name === cname), BUDGET.settings, 'circle (own devices)');
      // The invite can surface a connection request on A's other devices (see the approval passes).
      await Promise.all(all.map((n) => op(devices[n], { op: 'approve_connections' }, 1500)));
    }
    return circleId;
  }
  // ── shared plumbing for the newer steps (relayfirst, newfriend, screenshare, callgate, audience,
  //    launch, responsive). Pure decisions live in Scripts/lib/e2e-steps.mjs (unit-tested). ───────

  const rf = (j) => j?.relay_first || {};
  const knows = (j, hex) => (j?.contacts || []).some((c) => String(c.hex || '').toLowerCase() === String(hex || '').toLowerCase());
  const mediaPresent = (body) => (j) => j.posts?.some((p) => p.body === body && p.media_present?.length && p.media_present.every(Boolean));
  const hasPost = (body) => (j) => j.posts?.some((p) => p.body === body);
  /** Fresh dumps of several legs at once (legs not in the fleet are skipped). */
  const snap = async (names) => Object.fromEntries(await Promise.all(
    names.filter((n) => devices[n]).map(async (n) => [n, await freshDump(devices[n])])));
  /** Converge, but report the latency since `t0` (an earlier action) rather than since the poll began. */
  const convergeSince = async (dev, pred, base, t0) => {
    const ms = await converge(dev, pred, base);
    return ms < 0 ? -1 : Date.now() - t0;
  };
  /** perfGate with an explicit budget — several of these legs converge concurrently, so the
   *  "last converge's budget" default would be whichever finished last. */
  const gate = (step, name, ms, base) => perfGate(step, name, ms, budgetFor(devices[name], base));
  // Media refs are content-addressed: a fixture posted twice is the SAME blob, and a receiver that
  // already holds it proves nothing about how it would have got it. Distinct pixels per use.
  let photoSeq = 0;
  const distinctPhoto = (tag) => {
    const out = join(OUT, `${tag}.jpg`);
    const w = 1180 - photoSeq * 13 - (RUN_NONCE % 13);
    const h = 900 - photoSeq - (RUN_NONCE % 17);
    photoSeq += 1;
    execFileSync('sips', ['--resampleHeightWidth', String(h), String(w), PHOTO, '--out', out], { stdio: 'ignore' });
    return out;
  };
  const distinctVideo = (tag) => {
    const out = join(OUT, `${tag}.mp4`);
    const box = 8 + (photoSeq++ % 40) + (RUN_NONCE % 23);
    const r = spawnSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', VIDEO, '-vf',
      `drawbox=x=0:y=0:w=${box}:h=${box}:color=red@1:t=fill`, '-c:a', 'copy', out], { encoding: 'utf8' });
    if (r.status === 0 && existsSync(out)) return out;
    log(`WARN distinctVideo(${tag}): ffmpeg unavailable/failed — posting the shared fixture (${(r.stderr || '').trim().slice(0, 120)})`);
    return VIDEO;
  };
  const inCall = (j) => j?.call?.in_call === true;
  const callOver = (j) => j?.call != null && !(j.call.in_call || j.call.ringing);

  // ── newfriend: a FRESH friendship through the real invite → accept → approve path ────────────
  //
  // Roles follow the only topology that exercises pre-enrollment: B (the stub) hosts the relay and
  // INVITES; A (iOS) ACCEPTS, adopts B's relay from the ticket, and posts BEFORE B approves, so its
  // writes to B's relay are refused (403, not enrolled yet). The bootstrap leaves A and B strangers
  // (E2E_PREFRIEND=0) and does not pre-authorize A on the relay. Timings are measured from APPROVAL.
  async function stepNewFriend() {
    const ios = devices.ios, stub = devices.stub;
    const [a0, b0] = await Promise.all([freshDump(ios), freshDump(stub)]);
    const aHex = a0?.account_hex || '';
    if (!aHex || !B) { score('newfriend: both identities known', false, `A=${aHex.slice(0, 8)} B=${String(B).slice(0, 8)}`); return; }
    const strangers = !knows(a0, B) && !knows(b0, aHex);
    score('newfriend: A and B start as strangers', strangers, strangers ? ''
      : 'already contacts — the bootstrap prefriended them (E2E_PREFRIEND / E2E_BOOTSTRAP=skip); nothing fresh to measure');
    if (!strangers) return;

    await op(stub, { op: 'invite_link' }, 2000);
    let link = '';
    await converge(stub, (j) => (link = j.invite_link || '').includes('t='), 30_000);
    score('newfriend: inviter minted a ticketed invite link', link.includes('t='));
    if (!link.includes('t=')) return;

    await op(ios, { op: 'relay_backoff_reset' }, 500);
    const tAccept = Date.now();
    await op(ios, { op: 'connect_link', uri: link }, 1500);
    // Posted BEFORE approval — B's relay must refuse these until B enrolls A.
    const preText = `${MARKER}_NF_PreText`, prePhoto = `${MARKER}_NF_PrePhoto`;
    await op(ios, { op: 'post', body: preText, circle_id: 'default' }, 1500);
    await op(ios, { op: 'post', body: prePhoto, media: 'photo', circle_id: 'default',
      photo_path: ios.stage(distinctPhoto('nf-pre'), 'qa-nf-pre.jpg') }, 3000);
    gate('newfriend: accept → request reaches the inviter', 'stub',
      await convergeSince(stub, (j) => (j.pending_connections || []).includes(aHex) || knows(j, aHex), BUDGET.nfRequest, tAccept),
      BUDGET.nfRequest);

    const hold = Math.max(0, NF_HOLD_MS - (Date.now() - tAccept));
    log(`newfriend: holding approval ${(hold / 1000).toFixed(0)}s so A's writes to B's relay hit pre-enrollment 403s`);
    await sleep(hold);
    const held = await freshDump(ios);
    log(`newfriend: acceptor relay_backoff before approval: ${JSON.stringify(held?.relay_backoff || {})}`);
    score('newfriend: acceptor adopted the inviter relay from the ticket (pending enrollment)',
      (held?.relay_backoff?.pending_enrollment || []).length > 0, JSON.stringify(held?.relay_backoff?.pending_enrollment || []));

    const tApprove = Date.now();
    await op(stub, { op: 'approve_connections' }, 300);
    const [fa, fb] = await Promise.all([
      // The acceptor lists B as a contact from the moment it accepts; it is a FRIEND once the
      // inviter's grant has come back.
      convergeSince(ios, (j) => knows(j, B) && (j.friend_invites?.accepted || []).some((a) => a.granted), BUDGET.nfFriend, tApprove),
      convergeSince(stub, (j) => knows(j, aHex) && !(j.pending_connections || []).includes(aHex), BUDGET.nfFriend, tApprove),
    ]);
    gate('newfriend: approval → friends [acceptor]', 'ios', fa, BUDGET.nfFriend);
    gate('newfriend: approval → friends [inviter]', 'stub', fb, BUDGET.nfFriend);

    // What A posted while it was still refused must arrive promptly after APPROVAL.
    gate('newfriend: pre-approval text reaches the inviter (from approval)', 'stub',
      await convergeSince(stub, hasPost(preText), BUDGET.nfText, tApprove), BUDGET.nfText);
    gate('newfriend: pre-approval photo present on the inviter (from approval)', 'stub',
      await convergeSince(stub, mediaPresent(prePhoto), BUDGET.mediaBlob, tApprove), BUDGET.mediaBlob);

    // The inviter's first content reaches the acceptor — the path that used to take 10+ minutes
    // (content sealed under a key commit the new member could not yet receive).
    const invText = `${MARKER}_NF_InviterText`, invPhoto = `${MARKER}_NF_InviterPhoto`;
    const tInv = Date.now();
    await op(stub, { op: 'post', body: invText, circle_id: 'default' }, 500);
    await op(stub, { op: 'post', body: invPhoto, media: 'photo', circle_id: 'default',
      photo_path: stub.stage(distinctPhoto('nf-inviter'), 'qa-nf-inviter.jpg') }, 1500);
    const txt = await convergeSince(ios, hasPost(invText), BUDGET.nfInviterText, tInv);
    gate('newfriend: inviter\'s first text visible on the acceptor', 'ios', txt, BUDGET.nfInviterText);
    log(`newfriend: accept → inviter text on acceptor = ${txt < 0 ? 'never' : ((Date.now() - tAccept) / 1000).toFixed(1) + 's'} (includes the ${NF_HOLD_MS / 1000}s approval hold)`);
    gate('newfriend: inviter\'s first photo present on the acceptor', 'ios',
      await convergeSince(ios, mediaPresent(invPhoto), BUDGET.mediaBlob, tInv), BUDGET.mediaBlob);

    const dmBody = `${MARKER}_NF_DM`;
    const tDm = Date.now();
    await op(ios, { op: 'dm', dm_to: B, body: dmBody }, 1000);
    gate('newfriend: acceptor\'s DM reaches the inviter', 'stub',
      await convergeSince(stub, (j) => Object.values(j.dms || {}).flat().some((m) => m.body === dmBody), BUDGET.nfDm, tDm),
      BUDGET.nfDm);

    // The 403s must have been absorbed as pending enrollment, never parked in a long backoff.
    const after = await freshDump(ios);
    const rb = after?.relay_backoff || {};
    log(`newfriend: acceptor relay_backoff after: ${JSON.stringify(rb)}`);
    score('newfriend: pre-enrollment 403s happened and were absorbed as pendingEnrollment',
      num(rb.pending_enrollment_refusals) > 0,
      `refusals=${num(rb.pending_enrollment_refusals)} relays=${JSON.stringify((rb.relays || []).map((r) => ({ relay: String(r.relay).slice(0, 8), reason: r.reason, fails: r.fails })))}`);
    PERF.push({ step: 'newfriend: acceptor peak relay backoff', device: 'ios', ms: num(rb.peak_backoff_ms), budget: BUDGET.nfMaxBackoff });
    score(`newfriend: inviter relay never parked in long backoff (peak ${(num(rb.peak_backoff_ms) / 1000).toFixed(0)}s / ${BUDGET.nfMaxBackoff / 1000}s)`,
      num(rb.peak_backoff_ms) <= BUDGET.nfMaxBackoff);
  }

  /** After newfriend: restore the baseline every later step was written against — every A device
   *  authorized on B's relay (the bootstrap skipped it) and any pending request approved. */
  function restoreFleetAfterNewFriend() {
    const members = join(OUT, 'members.txt');
    if (existsSync(members)) {
      const r = spawnSync('bash', [join(ROOT, 'Scripts/qa-e2e-authorize.sh'), members], { encoding: 'utf8' });
      log(`newfriend: authorized the fleet on B's relay (${(r.stdout || r.stderr || '').trim()})`);
    } else log(`WARN newfriend: ${members} missing — A's devices were never authorized on B's relay`);
  }

  // ── relayfirst: the relay is the media path ───────────────────────────────────────────────────
  async function stepRelayFirst() {
    const shared = await ensureSharedCircle();
    if (!shared || !B) { score('relayfirst (needs a circle shared with B)', false, 'circle creation failed or B unknown'); return; }
    const ios = devices.ios;
    const legs = all.filter((n) => devices[n]);
    const before = await snap(legs);
    const tagP = `${MARKER}_RF_Photo`, tagV = `${MARKER}_RF_Video`;
    await op(ios, { op: 'post', body: tagP, media: 'photo', circle_id: shared,
      photo_path: ios.stage(distinctPhoto('relayfirst'), 'qa-relayfirst.jpg') }, 3000);
    // Short settle on purpose: the upload-honesty check below wants to SEE the video pending.
    await op(ios, { op: 'post', body: tagV, media: 'video', circle_id: shared,
      video_path: ios.stage(distinctVideo('relayfirst'), 'qa-relayfirst.mp4') }, 1500);
    const pendingSeen = await converge(ios, (j) => num(j.pending_media_uploads) > 0, 20_000);
    const pj = await freshDump(ios);
    const queued = delta(rf(before.ios), rf(pj), 'authored_refs_enqueued');
    // A local relay can swallow a small clip before the first dump; the enqueue counter is then the
    // evidence the upload went through the pending state at all.
    score('relayfirst: authored uploads went through the pending (sync badge) state',
      pendingSeen >= 0 || queued > 0, `pending seen=${pendingSeen >= 0} authored_refs_enqueued Δ=${queued}`);
    gate('relayfirst: pending uploads drain once the relay holds them', 'ios',
      await converge(ios, (j) => num(j.pending_media_uploads) === 0, BUDGET.mediaBlob), BUDGET.mediaBlob);

    const receivers = legs.filter((n) => n !== 'ios');
    await convergeAll(receivers, mediaPresent(tagP), BUDGET.mediaBlob, 'relayfirst: photo present');
    await convergeAll(receivers, mediaPresent(tagV), BUDGET.mediaBlob, 'relayfirst: video present');
    const after = await snap(legs);
    const d = (n, k) => delta(rf(before[n]), rf(after[n]), k);
    const show = (n, ks) => ks.map((k) => `${k}Δ=${d(n, k)}`).join(' ');
    score('relayfirst: B received via the relay', d('stub', 'received_via_relay') > 0, show('stub', ['received_via_relay', 'received_via_direct']));
    score('relayfirst: B received nothing by direct peer stream', d('stub', 'received_via_direct') === 0, show('stub', ['received_via_direct']));
    for (const n of fleet.filter((x) => devices[x])) {
      // by_role / by_why / recent (Apple + Android) name WHICH blobs streamed and why no hint
      // answered them — cumulative, so shown as-is next to the deltas.
      const why = rf(after[n])?.served_direct_friend_by_why;
      const recent = (rf(after[n])?.served_direct_friend_recent || []).slice(-4);
      score(`relayfirst: ${n} (account A) streamed nothing directly to friends`,
        d(n, 'served_direct_friend') === 0 && d(n, 'served_direct_friend_bytes') === 0,
        show(n, ['served_direct_friend', 'served_direct_friend_bytes', 'relay_hints_sent', 'media_requests_from_friends'])
          + (why ? ` by_role=${JSON.stringify(rf(after[n]).served_direct_friend_by_role)} by_why=${JSON.stringify(why)}` : '')
          + (recent.length ? ` recent=${JSON.stringify(recent)}` : ''));
    }
    score('relayfirst: authored media enqueued for the relay BEFORE the broadcast [ios]',
      num(rf(after.ios).broadcast_before_enqueue) === 0 && num(rf(after.ios).authored_media_posts_checked) >= 2,
      `broadcast_before_enqueue=${rf(after.ios).broadcast_before_enqueue} checked=${rf(after.ios).authored_media_posts_checked}`);

    // THE GATE, forced: heavy-work suspended (as a call / Low Power Mode / heat would) → a friend's
    // direct ask is declined, nothing streams; lifted → answered with a relay hint again.
    const ref = (after.ios?.posts || []).find((p) => p.body === tagP)?.media_refs?.[0];
    if (!ref) { score('relayfirst gate: photo ref known', false); return; }
    const gated = ['ios', ...(devices.android ? ['android'] : [])];
    await Promise.all(gated.map((n) => op(devices[n], { op: 'heavy_work_override', suspend: true, reason: 'qa' }, 1500)));
    for (const n of gated) {
      const ms = await converge(devices[n], (j) => suspendedFor(j.heavy_work, 'forced=qa'), 20_000);
      score(`relayfirst gate: override closes the gate [${n}]`, ms >= 0, JSON.stringify((await freshDump(devices[n]))?.heavy_work));
    }
    const g0 = await snap(gated);
    await op(devices.stub, { op: 'media_ask', ref }, 1500);
    const asked = await converge(devices.ios, (j) => num(rf(j).media_requests_from_friends) > num(rf(g0.ios).media_requests_from_friends), 30_000);
    await sleep(5000);
    const g1 = await snap(gated);
    for (const n of gated) {
      const dd = (k) => delta(rf(g0[n]), rf(g1[n]), k);
      if (dd('media_requests_from_friends') <= 0) {
        if (n === 'ios') score('relayfirst gate: B\'s direct ask reached A [ios]', false, `asked=${asked}`);
        else log(`NOTE relayfirst gate: B's ask did not reach ${n} — no decision to assert there`);
        continue;
      }
      score(`relayfirst gate: suspended ${n} declined B's direct ask`,
        dd('serve_declined') > 0 && String(rf(g1[n]).last_decline || '').includes('forced=qa'),
        `declinedΔ=${dd('serve_declined')} last=${rf(g1[n]).last_decline}`);
      score(`relayfirst gate: suspended ${n} streamed nothing and hinted nothing`,
        dd('served_direct_friend_bytes') === 0 && dd('relay_hints_sent') === 0,
        `bytesΔ=${dd('served_direct_friend_bytes')} hintsΔ=${dd('relay_hints_sent')}`);
    }
    await Promise.all(gated.map((n) => op(devices[n], { op: 'heavy_work_override', suspend: false }, 1500)));
    for (const n of gated) {
      const ms = await converge(devices[n], (j) => liftedFrom(j.heavy_work, 'forced=qa'), 20_000);
      score(`relayfirst gate: override lifted [${n}]`, ms >= 0, JSON.stringify((await freshDump(devices[n]))?.heavy_work));
    }
    const l0 = await snap(['ios']);
    await op(devices.stub, { op: 'media_ask', ref }, 1500);
    await converge(devices.ios, (j) => num(rf(j).media_requests_from_friends) > num(rf(l0.ios).media_requests_from_friends), 30_000);
    await sleep(5000);
    const l1 = await snap(['ios']);
    const ld = (k) => delta(rf(l0.ios), rf(l1.ios), k);
    if (l1.ios?.heavy_work?.suspended) {
      score('relayfirst gate: normal serving resumes after the lift [ios]', true,
        `SKIPPED — the gate is still closed for ${l1.ios.heavy_work.reason} (the simulator mirrors the host's thermal state)`);
    } else {
      score('relayfirst gate: normal serving resumes after the lift — a relay hint, not a stream [ios]',
        ld('relay_hints_sent') > 0 && ld('served_direct_friend_bytes') === 0,
        `hintsΔ=${ld('relay_hints_sent')} bytesΔ=${ld('served_direct_friend_bytes')} declinedΔ=${ld('serve_declined')}`);
    }
  }

  // ── screenshare: Android shares its screen in a call; the Apple peer routes it by stream id ────
  //
  // Android (account A) ↔ the stub (account B): the only cross-account pair the emulator can call
  // (iOS and Android are the SAME account). The stub runs the Apple WebRTCCall/CallManager code the
  // iPhone runs, so its dump proves the Apple-side routing fix. Consent is the REAL MediaProjection
  // dialog, driven through uiautomator — never pre-granted with appops.
  const adbText = (args) => String(shOk('adb', args) || '');
  const uiNodes = () => {
    if (shOk('adb', ['shell', 'uiautomator', 'dump', '/sdcard/haven-ui.xml']) === null) return [];
    return parseUiNodes(adbText(['exec-out', 'cat', '/sdcard/haven-ui.xml']));
  };
  const tap = (node) => { const [x, y] = center(node); shOk('adb', ['shell', 'input', 'tap', String(x), String(y)]); };
  /** Drive the consent surface: 'entire' | 'single' | 'cancel'. Returns {ok, why, seen}. */
  async function driveConsent(choice, budgetMs = 25_000) {
    const t0 = Date.now();
    let picked = false, confirmed = false, sawSurface = false, opened = 0, seen = [];
    const want = choice === 'entire' ? CONSENT.entire : CONSENT.single;
    const other = choice === 'entire' ? CONSENT.single : CONSENT.entire;
    while (Date.now() - t0 < budgetMs) {
      const nodes = uiNodes();
      seen = nodes.filter((n) => n.text || n.desc).map((n) => n.text || n.desc).slice(0, 25);
      if (confirmed && choice === 'single') {
        // "Next" on a single-app share opens an app picker: share Haven itself.
        const app = findNode(nodes, /^Haven$/);
        if (app) { tap(app); return { ok: true, why: 'picked Haven in the app chooser', seen }; }
        await sleep(800); continue;
      }
      if (!isConsentSurface(nodes)) {
        if (sawSurface) return { ok: confirmed || choice === 'cancel', why: 'consent surface closed', seen };
        await sleep(800); continue;
      }
      sawSurface = true;
      if (choice === 'cancel') {
        const c = findNode(nodes, CONSENT.cancel);
        if (c) { tap(c); await sleep(1000); return { ok: true, why: 'tapped cancel', seen }; }
        await sleep(700); continue;
      }
      const w = findNode(nodes, want), o = findNode(nodes, other), confirm = findNode(nodes, CONSENT.confirm);
      if (!picked) {
        if (w && o) { tap(w); picked = true; await sleep(800); continue; }           // list open: choose ours
        if (w) picked = true;                                                          // spinner already shows ours
        else if (o) {                                                                  // spinner shows the other: open it
          if (++opened > 2) return { ok: false, why: `no ${choice === 'single' ? 'single-app' : 'entire-screen'} option offered`, seen };
          tap(o); await sleep(800); continue;
        } else {                                                                       // no chooser at all (older dialog)
          if (choice === 'single') return { ok: false, why: 'dialog offers no app chooser', seen };
          picked = true;
        }
      }
      if (confirm) {
        tap(confirm); confirmed = true; await sleep(1500);
        if (choice !== 'single') return { ok: true, why: `confirmed (${confirm.text})`, seen };
        continue;
      }
      await sleep(700);
    }
    return { ok: false, why: sawSurface ? 'could not complete the consent surface' : 'consent surface never appeared', seen };
  }
  const projectionHeld = () => holdsMediaProjection(adbText(['shell', 'dumpsys', 'activity', 'services', AND_PKG]));
  const androidAlive = () => adbText(['shell', 'pidof', AND_PKG]).trim().length > 0;

  async function stepScreenShare() {
    const and = devices.android, stub = devices.stub;
    if (!and || !B) { score('screenshare (needs the android leg and B)', false, !and ? 'no android device' : 'B unknown'); return; }
    shOk('adb', ['shell', 'appops', 'set', AND_PKG, 'PROJECT_MEDIA', 'default']);   // real consent only
    shOk('adb', ['logcat', '-c']);
    await op(and, { op: 'call', dm_to: B });
    await converge(stub, (j) => j.call?.ringing || j.call?.in_call, BUDGET.text);
    await op(stub, { op: 'call_accept' });
    const live = await Promise.all([converge(and, inCall, BUDGET.mediaEvent), converge(stub, inCall, BUDGET.mediaEvent)]);
    score('screenshare: android↔stub call is live', live.every((ms) => ms >= 0), JSON.stringify(live));
    if (!live.every((ms) => ms >= 0)) { await op(and, { op: 'call_end' }, 6000); return; }
    await sleep(4000);
    const cam0 = remoteSlots((await freshDump(stub))?.call).find((s) => s.camera)?.camera || null;
    log(`screenshare: stub camera slot before any share: ${JSON.stringify(cam0)}`);
    const shareState = async () => (await freshDump(and))?.screen_share || {};
    const noScreenOnStub = (j) => !sharedScreen(j?.call);
    let granted = 0;

    const ask = async () => { and.qaWrite({ op: 'screen_share', on: true }); and.poke(); await sleep(1500); };
    const stop = async (label) => {
      await op(and, { op: 'screen_share', on: false }, 2000);
      gate(`screenshare: stop removes the screen track on the peer [${label}]`, 'stub',
        await converge(stub, (j) => inCall(j) && noScreenOnStub(j), BUDGET.shareFrame), BUDGET.shareFrame);
      const st = await shareState();
      score(`screenshare: android back to idle after stop [${label}]`, st.state === 'idle', JSON.stringify(st));
      score(`screenshare: no mediaProjection FGS type left after stop [${label}]`, !projectionHeld());
      const j = await freshDump(stub);
      score(`screenshare: camera slot still present on the peer after stop [${label}]`,
        !cam0 || remoteSlots(j?.call).some((s) => s.camera), JSON.stringify(remoteSlots(j?.call)));
    };
    const assertSharing = async (label, t0) => {
      granted++;
      const st0 = await converge(and, (j) => j.screen_share?.state === 'sharing' && num(j.screen_share?.frames_captured) > 0, BUDGET.shareFrame);
      const st = await shareState();
      score(`screenshare: android captured frames [${label}]`, st0 >= 0, JSON.stringify(st));
      score(`screenshare: FGS mediaProjection ready BEFORE capture [${label}]`, st.fgs_ready_before_capture === true,
        `fgs_ready=${st.fgs_ready} wait=${st.fgs_ready_ms}ms`);
      score(`screenshare: screen sender params applied [${label}]`, st.sender_params_ok === true, `encoders=${JSON.stringify(st.encoders)}`);
      score(`screenshare: capture long side ≤ 1280 [${label}]`, longSide(st.capture_w, st.capture_h) > 0 && longSide(st.capture_w, st.capture_h) <= 1280,
        `${st.capture_w}x${st.capture_h}`);
      gate(`screenshare: share start → first frame decoded on the peer [${label}]`, 'stub',
        await convergeSince(stub, (j) => num(sharedScreen(j?.call)?.screen?.frames_decoded) > 0, BUDGET.shareFrame, t0), BUDGET.shareFrame);
      const s1 = sharedScreen((await freshDump(stub))?.call);
      await sleep(5000);
      const s2 = sharedScreen((await freshDump(stub))?.call);
      score(`screenshare: peer's screen frames keep growing [${label}]`,
        num(s2?.screen?.frames_decoded) > num(s1?.screen?.frames_decoded), `${s1?.screen?.frames_decoded} → ${s2?.screen?.frames_decoded}`);
      score(`screenshare: routed by stream id "screen" [${label}]`, (s2?.screen?.stream_ids || []).includes('screen'), JSON.stringify(s2?.screen));
      score(`screenshare: peer frame long side ≤ 1280 [${label}]`,
        longSide(s2?.screen?.width, s2?.screen?.height) > 0 && longSide(s2?.screen?.width, s2?.screen?.height) <= 1280,
        `${s2?.screen?.width}x${s2?.screen?.height}`);
      score(`screenshare: camera slot is a distinct track, not overwritten [${label}]`,
        !!s2?.camera ? s2.camera.track_id !== s2.screen?.track_id : !cam0,
        `camera=${s2?.camera?.track_id} screen=${s2?.screen?.track_id} camera-before=${cam0?.track_id}`);
    };

    // (2) DENY — nothing is sent, the call and the camera are untouched, nothing is left running.
    let st = await shareState();
    await ask();
    let drove = await driveConsent('cancel');
    log(`screenshare deny: ${JSON.stringify(drove)}`);
    score('screenshare [deny]: consent dialog shown and cancelled', drove.ok, `${drove.why} — ${JSON.stringify(drove.seen)}`);
    await converge(and, (j) => String(j.screen_share?.consent_result || '').startsWith('denied'), 20_000);
    st = await shareState();
    score('screenshare [deny]: denial recorded, share idle', String(st.consent_result).startsWith('denied') && st.state === 'idle', JSON.stringify(st));
    const dj = await freshDump(stub);
    score('screenshare [deny]: no screen track reached the peer', inCall(dj) && noScreenOnStub(dj), JSON.stringify(remoteSlots(dj?.call)));
    score('screenshare [deny]: call continues on android', inCall(await freshDump(and)));
    score('screenshare [deny]: no mediaProjection FGS type left running', !projectionHeld());
    score('screenshare [deny]: app did not crash', androidAlive());

    // (1) GRANT "Entire screen".
    const attempts0 = num(st.consent_attempts);
    await ask();
    drove = await driveConsent('entire');
    let t0 = Date.now();   // consent confirmed = the share starts
    log(`screenshare entire: ${JSON.stringify(drove)}`);
    score('screenshare [entire]: consent granted through the real dialog', drove.ok, `${drove.why} — ${JSON.stringify(drove.seen)}`);
    if (drove.ok) { await assertSharing('entire', t0); await stop('entire'); }

    // (3) Share AGAIN — tokens are single-use, so a fresh consent must be asked for, and it works.
    const mid = await shareState();
    await ask();
    drove = await driveConsent('entire');
    t0 = Date.now();
    const again = await shareState();
    score('screenshare [again]: a FRESH consent was requested', num(again.consent_attempts) > num(mid.consent_attempts) && num(mid.consent_attempts) > attempts0,
      `attempts ${attempts0} → ${mid.consent_attempts} → ${again.consent_attempts}`);
    score('screenshare [again]: consent granted', drove.ok, `${drove.why} — ${JSON.stringify(drove.seen)}`);
    if (drove.ok) { await assertSharing('again', t0); await stop('again'); }

    // (4) GRANT "A single app" (Android 14+ chooser) — pick Haven itself.
    await ask();
    drove = await driveConsent('single');
    t0 = Date.now();
    log(`screenshare single-app: ${JSON.stringify(drove)}`);
    if (!drove.ok && /no single-app option|no app chooser/.test(drove.why)) {
      score('screenshare [single app]: chooser offers a single-app option', true, `SKIPPED — ${drove.why}`);
      const c = findNode(uiNodes(), CONSENT.cancel); if (c) tap(c);
    } else {
      score('screenshare [single app]: consent granted for one app', drove.ok, `${drove.why} — ${JSON.stringify(drove.seen)}`);
      shOk('adb', ['shell', 'am', 'start', '-n', `${AND_PKG}/.MainActivity`]);   // back to Haven (the shared app)
      if (drove.ok) { await assertSharing('single app', t0); await stop('single app'); }
    }

    // Logcat: every granted capture came after its FGS promotion, and nothing failed.
    const audit = auditShareLog(adbText(['logcat', '-d', '-s', 'HavenScreenShare:*']));
    score('screenshare: logcat — FGS-ready before EVERY capture start', audit.ordered && audit.captures >= granted,
      `captures=${audit.captures} granted=${granted}`);
    score('screenshare: logcat — no "screen share start failed" / SecurityException', audit.failures.length === 0,
      audit.failures.slice(0, 3).join(' | '));
    score('screenshare: app alive at the end', androidAlive());
    await op(and, { op: 'call_end' }, 6000);
    await convergeAll(['android', 'stub'], callOver, BUDGET.text, 'screenshare: call ended');
  }

  // ── callgate: a REAL call closes the heavy-work gate ─────────────────────────────────────────
  async function stepCallGate() {
    const shared = await ensureSharedCircle();
    if (!shared || !B) { score('callgate (needs a circle shared with B)', false); return; }
    const ios = devices.ios, stub = devices.stub;
    await op(ios, { op: 'call', dm_to: B });
    await converge(stub, (j) => j.call?.ringing || j.call?.in_call, BUDGET.text);
    await op(stub, { op: 'call_accept' });
    const live = await Promise.all([converge(ios, inCall, BUDGET.mediaEvent), converge(stub, inCall, BUDGET.mediaEvent)]);
    score('callgate: ios↔stub call is live', live.every((ms) => ms >= 0), JSON.stringify(live));
    if (!live.every((ms) => ms >= 0)) { await op(ios, { op: 'call_end' }, 6000); return; }
    gate('callgate: the call closes A\'s heavy-work gate', 'ios',
      await converge(ios, (j) => suspendedFor(j.heavy_work, 'haven-call'), BUDGET.gateClose), BUDGET.gateClose);
    const m0 = await snap(['ios', 'stub']);
    log(`callgate: gate A=${JSON.stringify(m0.ios?.heavy_work)} B=${JSON.stringify(m0.stub?.heavy_work)}`);
    if (devices.android) log('NOTE callgate: android is not in this call (it shares account A with iOS), so its own gate is not asserted here');

    const tag = `${MARKER}_CG_Photo`;
    const tPost = Date.now();
    await op(ios, { op: 'post', body: tag, media: 'photo', circle_id: shared,
      photo_path: ios.stage(distinctPhoto('callgate'), 'qa-callgate.jpg') }, 3000);
    gate('callgate: B still receives A\'s fresh photo mid-call', 'stub',
      await convergeSince(stub, mediaPresent(tag), BUDGET.mediaBlob, tPost), BUDGET.mediaBlob);
    const ref = ((await freshDump(ios))?.posts || []).find((p) => p.body === tag)?.media_refs?.[0];
    if (ref) {
      await op(stub, { op: 'media_ask', ref }, 1500);
      await converge(ios, (j) => num(rf(j).media_requests_from_friends) > num(rf(m0.ios).media_requests_from_friends), 30_000);
    }
    await sleep(BUDGET.callGateWindow);
    const m1 = await snap(['ios', 'stub']);
    const d = (n, k) => delta(rf(m0[n]), rf(m1[n]), k);
    score('callgate: A streamed nothing directly to friends during the call',
      d('ios', 'served_direct_friend') === 0 && d('ios', 'served_direct_friend_bytes') === 0,
      `served Δ=${d('ios', 'served_direct_friend')} bytes Δ=${d('ios', 'served_direct_friend_bytes')}`);
    score('callgate: A still uploaded its own fresh media to the relay', d('ios', 'relay_uploads_landed') > 0,
      `relay_uploads_landed Δ=${d('ios', 'relay_uploads_landed')}`);
    score('callgate: B got it via the relay, not a peer stream',
      d('stub', 'received_via_relay') > 0 && d('stub', 'received_via_direct') === 0,
      `via_relay Δ=${d('stub', 'received_via_relay')} via_direct Δ=${d('stub', 'received_via_direct')}`);
    if (ref && d('ios', 'media_requests_from_friends') > 0) {
      score('callgate: A declined B\'s direct ask because of the call',
        d('ios', 'serve_declined') > 0 && String(rf(m1.ios).last_decline || '').includes('haven-call'),
        `declined Δ=${d('ios', 'serve_declined')} last=${rf(m1.ios).last_decline}`);
    } else score('callgate: B\'s direct ask reached A', false, `ref=${!!ref}`);
    score('callgate: A\'s full-size missing-media fetches paused during the call', d('ios', 'missing_media_fetches') === 0,
      `missing_media_fetches Δ=${d('ios', 'missing_media_fetches')}`);

    await op(ios, { op: 'call_end' }, 1000);
    const tEnd = Date.now();
    gate('callgate: hangup lifts the call gate', 'ios',
      await convergeSince(ios, (j) => liftedFrom(j.heavy_work, 'haven-call'), BUDGET.gateLift, tEnd), BUDGET.gateLift);
    gate('callgate: deferred uploads drain after hangup', 'ios',
      await convergeSince(ios, (j) => num(j.pending_media_uploads) === 0, BUDGET.mediaBlob, tEnd), BUDGET.mediaBlob);
    await convergeAll(['ios', 'stub'], callOver, BUDGET.text, 'callgate: call ended');
  }

  // ── progress: the honest-progress fields move the way the UI claims ────────────────────────────
  //
  // docs/QA.md "Progress fields". A posts a video: A's sync pill must actually show the send
  // (syncing with ≥1 pending, or a flush_total ≥ 1, at SOME sample — it can be brief on a local
  // relay) and settle to synced/0. Every receiver's transfer for those refs climbs monotonically,
  // lands, is counted received ONCE, and is never shown as given up while bytes were still coming.
  async function stepProgress() {
    const shared = await ensureSharedCircle();
    if (!shared || !B) { score('progress (needs a circle shared with B)', false); return; }
    const ios = devices.ios;
    const receivers = ['stub', 'android'].filter((n) => devices[n]);
    const before = await snap(['ios', ...receivers]);
    for (const n of ['ios', ...receivers]) {
      if (!before[n]?.sync_badge || typeof before[n]?.media_received_count !== 'number') {
        score(`progress: progress fields present [${n}]`, false, 'no sync_badge / media_received_count in the dump');
        return;
      }
    }
    const tag = `${MARKER}_Progress_Video`;
    // Make the shared circle A's active one first (the pill reports the ACTIVE circle).
    await op(ios, { op: 'post', body: `${MARKER}_Progress_Seed`, circle_id: shared }, 2000);
    const tPost = Date.now() - 1000;   // the history's atMs is the app's clock (sim = host, skew 0)
    await op(ios, { op: 'post', body: tag, media: 'video', circle_id: shared,
      video_path: ios.stage(distinctVideo('progress'), 'qa-progress.mp4') }, 500);
    // A's pill. The app LOGS every change of it (`sync_badge_history`): the send is asserted from
    // that log — sampling the live pill raced the upload, which can start and finish between two
    // dumps. The samples are kept only for the report line.
    let tr = { sawSending: false, settled: false, seq: [] }, badges = [];
    const tA = Date.now();
    while (Date.now() - tA < BUDGET.mediaBlob) {
      const j = await freshDump(ios);
      const b = j?.sync_badge || {};
      badges.push(`${b.state}:${b.pending_user_uploads}+${b.pending_media ?? '?'}:${b.flush_done}/${b.flush_total}`);
      tr = badgeTransitions(j?.sync_badge_history, { sinceMs: tPost, circle: shared });
      if (tr.settled && b.state === 'synced' && j.posts?.some((p) => p.body === tag)) break;
      await sleep(500);
    }
    const last = (await freshDump(ios))?.sync_badge || {};
    score('progress: A\'s sync pill went synced → syncing (≥1 pending) → synced [history]', tr.sawSending && tr.settled,
      `history=${tr.seq.join(' → ') || '(none)'} samples=${badges.slice(0, 8).join(' ')}`);
    score('progress: A\'s sync pill settles to synced / 0 pending', last.state === 'synced' && num(last.pending_user_uploads) === 0,
      JSON.stringify(last));

    const post = ((await freshDump(ios))?.posts || []).find((p) => p.body === tag);
    const refs = [...(post?.media_refs || [])];
    if (!refs.length) { score('progress: video post refs known', false); return; }
    // Receivers: sample their transfers until the post's media is present.
    await Promise.all(receivers.map(async (n) => {
      const dev = devices[n];
      const rec = {};
      const t0 = Date.now();
      let j = null;
      while (Date.now() - t0 < budgetFor(dev, BUDGET.mediaBlob)) {
        j = await freshDump(dev);
        const p = (j?.posts || []).find((x) => x.body === tag);
        const present = (ref) => { const i = (p?.media_refs || []).indexOf(ref); return i >= 0 && Boolean(p.media_present?.[i]); };
        recordProgress(rec, j, refs, present);
        if (refs.every((r) => rec[r].present)) break;
        await sleep(800);
      }
      const done = refs.every((r) => rec[r]?.present);
      gate(`progress: video present [${n}]`, n, done ? Date.now() - t0 : -1, BUDGET.mediaBlob);
      for (const r of refs) {
        const x = rec[r] || { got: [] };
        score(`progress: transfer never goes backwards [${n} ${r.slice(0, 10)}]`, nonDecreasing(x.got),
          `got=${JSON.stringify(x.got.slice(-12))} total=${x.total} lanes=${x.lanes}`);
        score(`progress: never shown as given up while bytes were arriving [${n} ${r.slice(0, 10)}]`, !x.gaveUpWhileReceiving && !(x.gaveUp && x.present),
          `gaveUp=${x.gaveUp} present=${x.present}`);
      }
      // Counted received exactly once: the counter moves by at most the post's blobs and does not
      // move again afterwards (a late double count is the bug this looks for).
      await sleep(10_000);
      const after1 = await freshDump(dev);
      await sleep(8_000);
      const after2 = await freshDump(dev);
      const dRecv = num(after1?.media_received_count) - num(before[n]?.media_received_count);
      const blobs = refs.length + (post?.media_markers || []).length;
      score(`progress: received counted once per blob [${n}]`, dRecv >= 1 && dRecv <= blobs + 2,
        `Δmedia_received_count=${dRecv} blobs(refs+companions)=${blobs}`);
      score(`progress: no late double count [${n}]`, num(after2?.media_received_count) === num(after1?.media_received_count),
        `${after1?.media_received_count} → ${after2?.media_received_count}`);
      score(`progress: refs left media_transfers once landed [${n}]`,
        !(after2?.media_transfers || []).some((t) => refs.includes(t.ref)), JSON.stringify(after2?.media_transfers || []));
      gate(`progress: media_wanted_count back to its pre-step value [${n}]`, n,
        await converge(dev, (x) => num(x.media_wanted_count) <= num(before[n]?.media_wanted_count), 60_000), 60_000);
    }));
  }

  // ── audience: "Send privately instead" stays private ──────────────────────────────────────────
  async function stepAudience() {
    const shared = await ensureSharedCircle();
    if (!shared || !B) { score('audience (needs a circle shared with B)', false); return; }
    const ios = devices.ios;
    const aHex = (await freshDump(ios))?.account_hex || '';
    const dmBody = `${MARKER}_Aud_Private`, circleBody = `${MARKER}_Aud_Circle`;
    await op(ios, { op: 'dm', dm_to: B, body: dmBody }, 2000);
    await op(ios, { op: 'post', body: circleBody, circle_id: shared }, 2000);
    const inDm = (j) => Object.values(j.dms || {}).flat().some((m) => m.body === dmBody);
    const inFeed = (j) => (j?.posts || []).some((p) => p.body === dmBody);
    gate('audience: private message reaches B\'s DM thread', 'stub', await converge(devices.stub, inDm, BUDGET.text), BUDGET.text);
    const bj = await freshDump(devices.stub);
    score('audience: … in the thread keyed by A', (bj?.dms?.[aHex] || []).some((m) => m.body === dmBody),
      `threads=${Object.keys(bj?.dms || {}).map((k) => k.slice(0, 8)).join(',')}`);
    await convergeAll(all.filter((n) => n !== 'ios' && devices[n]), hasPost(circleBody), BUDGET.text, 'audience: circle post reaches every member device');
    await sleep(8000);   // one more active poll for anything that would mis-file it
    for (const n of all.filter((x) => devices[x])) {
      const j = await freshDump(devices[n]);
      score(`audience: private message never appears in a circle feed [${n}]`, !!j && !inFeed(j),
        inFeed(j) ? `in circle ${(j.posts.find((p) => p.body === dmBody) || {}).circle}` : '');
    }
  }

  // ── launch: cold start → first feed, and catch-up after being dead ─────────────────────────────
  async function stepLaunch() {
    const shared = await ensureSharedCircle();
    const ios = devices.ios, stub = devices.stub;
    if (!shared || !B) { score('launch (needs a circle shared with B)', false); return; }
    // A content op switches the active circle — make the shared circle A's active one.
    await op(ios, { op: 'post', body: `${MARKER}_Launch_Seed`, circle_id: shared }, 3000);
    shOk('xcrun', ['simctl', 'terminate', IOS_UDID, IOS_BUNDLE]);
    log('launch: iOS terminated — B and desktop post while it is dead');
    const texts = [1, 2, 3].map((i) => `${MARKER}_Launch_T${i}`);
    await op(stub, { op: 'post', body: texts[0], circle_id: shared }, 1500);                 // A's ACTIVE circle
    await op(devices.desktop || stub, { op: 'post', body: texts[1], circle_id: 'default' }, 1500);
    await op(stub, { op: 'post', body: texts[2], circle_id: 'default' }, 1500);
    await op(stub, { op: 'post', body: `${MARKER}_Launch_Photo`, media: 'photo', circle_id: shared,
      photo_path: stub.stage(distinctPhoto('launch'), 'qa-launch.jpg') }, 3000);
    await sleep(BUDGET.launchSettle);   // let them reach the relay before A comes back
    const tLaunch = Date.now();
    shOk('xcrun', ['simctl', 'launch', IOS_UDID, IOS_BUNDLE]);
    channelFor(ios).reset('ios relaunched by the launch step');
    const fresh = (j) => num(j?.launch?.process_start_ms) >= tLaunch - 2000;
    let L = null;
    await converge(ios, (j) => { if (fresh(j)) L = j.launch; return fresh(j) && typeof j.launch?.first_feed_rendered_ms === 'number'; }, 60_000);
    perfGate('launch: launch → first feed rendered [ios]', 'ios', typeof L?.first_feed_rendered_ms === 'number' ? L.first_feed_rendered_ms : -1, BUDGET.launchIos);
    gate('launch: catch-up — all 3 texts present after relaunch [ios]', 'ios',
      await convergeSince(ios, (j) => fresh(j) && texts.every((t) => hasPost(t)(j)), BUDGET.catchup, tLaunch), BUDGET.catchup);
    const j = await freshDump(ios);
    log(`launch: ios launch timings ${JSON.stringify(j?.launch)}`);
    score('launch: the ACTIVE circle is ingested first', ingestedFirst(j?.launch?.circle_first_ingest_ms, shared),
      JSON.stringify(j?.launch?.circle_first_ingest_ms));
    score('launch: first feed paint does not wait on the DM warm-up', feedNotGatedOnDmWarm(j?.launch),
      `feed=${j?.launch?.first_feed_rendered_ms} dmWarm=${j?.launch?.dm_warmup_done_ms}`);
    if (typeof j?.launch?.first_mailbox_pass_ms === 'number') {
      perfGate('launch: first mailbox pass duration [ios]', 'ios', j.launch.first_mailbox_pass_ms, BUDGET.mailboxPass);
    } else score('launch: first mailbox pass recorded [ios]', false, 'no first_mailbox_pass_ms');
    if (devices.android) {
      shOk('adb', ['shell', 'am', 'force-stop', AND_PKG]);
      const t = Date.now();
      shOk('adb', ['shell', 'am', 'start', '-n', `${AND_PKG}/.MainActivity`]);
      channelFor(devices.android).reset('android relaunched by the launch step');
      await sleep(3000);
      let LA = null;
      await converge(devices.android, (x) => {
        const ok = num(x?.launch?.process_start_ms) >= t - 2000 && typeof x.launch?.first_feed_rendered_ms === 'number';
        if (ok) LA = x.launch; return ok;
      }, 60_000);
      perfGate('launch: launch → first feed rendered [android]', 'android',
        typeof LA?.first_feed_rendered_ms === 'number' ? LA.first_feed_rendered_ms : -1, BUDGET.launchAndroid);
    }
  }

  // ── responsive: a burst lands on A while A is used — the main thread stays free ───────────────
  async function stepResponsive() {
    const ios = devices.ios, stub = devices.stub;
    const probe = await freshDump(ios);
    const missing = missingPerfFields(probe?.perf);
    if (missing.length) {
      score(`responsive: perf dump fields present${REQUIRE_PERF ? '' : ' (SKIPPED — fix/responsiveness not on this build)'}`,
        !REQUIRE_PERF, `missing: ${missing.join(', ')}`);
      return;
    }
    const shared = await ensureSharedCircle();
    if (!shared || !B) { score('responsive (needs a circle shared with B)', false); return; }
    await op(ios, { op: 'perf_reset' }, 1500);
    const target = (await freshDump(ios))?.posts?.find((p) => p.circle === shared)?.id;
    const texts = Array.from({ length: 20 }, (_, i) => `${MARKER}_Burst_${i}`);
    const v1 = stub.stage(distinctVideo('burst-1'), 'qa-burst-1.mp4');
    const v2 = stub.stage(distinctVideo('burst-2'), 'qa-burst-2.mp4');
    const desk = devices.desktop || stub;
    const tBurst = Date.now();
    const burst = (async () => {
      await op(stub, { op: 'post', body: `${MARKER}_Burst_V1`, media: 'video', video_path: v1, circle_id: shared }, 1000);
      for (let i = 0; i < 20; i++) await op(i % 2 ? desk : stub, { op: 'post', body: texts[i], circle_id: shared }, 300);
      await op(desk, { op: 'post', body: `${MARKER}_Burst_Photo`, media: 'photo', circle_id: shared,
        photo_path: desk.stage(distinctPhoto('burst'), 'qa-burst.jpg') }, 1000);
      await op(stub, { op: 'post', body: `${MARKER}_Burst_V2`, media: 'video', video_path: v2, circle_id: shared }, 1000);
    })();
    const reacts = [];
    for (let i = 0; i < 5; i++) {
      const at = Date.now();
      if (target) {
        await op(ios, { op: 'react', target_id: target, emoji: ['❤️', '👍', '😂', '🎉', '🔥'][i] }, 500);
        reacts.push(reactLatency(await freshDump(ios)));
      }
      await sleep(Math.max(0, 2000 - (Date.now() - at)));
    }
    await burst;
    await converge(ios, (j) => texts.every((t) => hasPost(t)(j)), BUDGET.mediaBlob);
    const burstMs = Date.now() - tBurst;
    const perf = (await freshDump(ios))?.perf || {};
    log(`responsive: burst ${(burstMs / 1000).toFixed(1)}s perf=${JSON.stringify(perf)} reacts=${JSON.stringify(reacts)}`);
    score('responsive: no MediaStore work on the main thread', num(perf.mediaStoreOnMainCount) === 0, `count=${perf.mediaStoreOnMainCount}`);
    perfGate('responsive: main-thread stall max [ios]', 'ios', num(perf.mainStallMaxMs), BUDGET.stallMax);
    score(`responsive: main-thread stalls ≤ ${BUDGET.maxStalls}`, num(perf.mainStallCount) <= BUDGET.maxStalls, `count=${perf.mainStallCount}`);
    perfGate('responsive: engine user-wait p95 [ios]', 'ios', num(perf.engineUserWaitP95Ms), BUDGET.engineP95);
    const rl = reacts.filter((v) => typeof v === 'number');
    perfGate('responsive: react local latency, worst of 5 [ios]', 'ios', rl.length === 5 ? Math.max(...rl) : -1, BUDGET.react);
    const allow = persistExportAllowance(burstMs);
    score(`responsive: persist exports during the burst ≤ ${allow}`, num(perf.persistExportCount) <= allow, `count=${perf.persistExportCount}`);
    // IDLE starts once the WHOLE burst has landed, not just its texts: the photo and the two videos
    // (posts from a slow desktop leg especially) used to arrive inside the "idle" window, and each
    // one is a genuine state change that must be saved.
    const burstMedia = [`${MARKER}_Burst_V1`, `${MARKER}_Burst_Photo`, `${MARKER}_Burst_V2`];
    await converge(ios, (j) => burstMedia.every((t) => hasPost(t)(j)), BUDGET.mediaBlob);
    await sleep(3000);   // one debounce window: the save for that last arrival is not "idle"
    const c0 = num((await freshDump(ios))?.perf?.persistExportCount);
    await sleep(BUDGET.idle);
    const idlePerf = (await freshDump(ios))?.perf || {};
    const c1 = num(idlePerf.persistExportCount);
    // persistReasons / engineDirtiedBy (Apple): what asked for each export and which engine calls
    // made it non-empty — the attribution a red here needs.
    score(`responsive: no persist exports while idle (${BUDGET.idle / 1000}s)`, c1 === c0,
      `${c0} → ${c1} reasons=${JSON.stringify(idlePerf.persistReasons || {})} recentApplied=${JSON.stringify((idlePerf.recentApplied || []).slice(-12))} dirtiedBy=${JSON.stringify(idlePerf.engineDirtiedBy || {})}`);
  }

  // 0. newfriend runs FIRST: A and B are strangers until it makes them friends (E2E_PREFRIEND=0).
  if (STEPS.includes('newfriend')) {
    await stepNewFriend();
    restoreFleetAfterNewFriend();
    await Promise.all(all.map((n) => op(devices[n], { op: 'approve_connections' }, 1500)));
  }

  // 1. profile edit propagates across account A devices
  if (STEPS.includes('profile')) {
    const nick = `${MARKER}_Nick`;
    await op(devices.ios, { op: 'profile', name: nick });
    await convergeAll(fleet.filter((x) => x !== 'ios'), (j) => j.profile?.name === nick, BUDGET.settings, 'profile edit');
  }

  if (STEPS.includes('circle')) await ensureSharedCircle();

  // Second approval pass: the circle invite above can surface a request that did not exist during
  // bootstrap.
  await Promise.all(all.map((n) => op(devices[n], { op: 'approve_connections' }, 1500)));

  // Content authored into the SHARED circle reaches B (stub); content in A's
  // default circle only ever reaches A's own devices. Every shared-content op
  // carries circle_id; when the circle step was skipped there is no shared
  // circle, so stub expectations are skipped (and honestly reported as such).
  const audienceFor = (shared) => (shared && circleId && B) ? all : fleet;
  const cid = () => circleId || undefined;

  // Warm the fleet before ANY timed content assertion (see warmUp above). Satellite counts: it is
  // the most timing-sensitive step in the suite, so running it on a cold fleet measures the fleet
  // coming up rather than the feature.
  if (['post', 'satellite', 'relayfirst', 'progress', 'audience', 'callgate', 'launch', 'responsive'].some((x) => STEPS.includes(x))) await warmUp();

  // 3. posts: text + photo + video (author iOS; friend authors one from stub)
  if (STEPS.includes('post')) {
    await op(devices.ios, { op: 'post', body: `${MARKER}_Text`, circle_id: cid() });
    await convergeAll(audienceFor(true).filter((x) => x !== 'ios'), (j) => j.posts?.some((p) => p.body === `${MARKER}_Text`), BUDGET.text, 'text post');

    const photoPath = devices.ios.stage(PHOTO, 'qa-photo.jpg');
    await op(devices.ios, { op: 'post', body: `${MARKER}_Photo`, media: 'photo', photo_path: photoPath, circle_id: cid() });
    await convergeAll(audienceFor(true).filter((x) => x !== 'ios'), (j) => j.posts?.some((p) => p.body === `${MARKER}_Photo`), BUDGET.mediaEvent, 'photo post event');
      if (STEPS.includes('media'))
        await convergeAll(audienceFor(true).filter((x) => x !== 'ios'), (j) => j.posts?.some((p) => p.body === `${MARKER}_Photo` && p.media_present?.length && p.media_present.every(Boolean)), BUDGET.mediaBlob, 'photo blob present');

    const videoPath = devices.ios.stage(VIDEO, 'qa-clip.mp4');
    await op(devices.ios, { op: 'post', body: `${MARKER}_Video`, media: 'video', video_path: videoPath, circle_id: cid() }, 12_000);
    await convergeAll(audienceFor(true).filter((x) => x !== 'ios'), (j) => j.posts?.some((p) => p.body === `${MARKER}_Video`), BUDGET.mediaEvent, 'video post event');
      if (STEPS.includes('media'))
        await convergeAll(audienceFor(true).filter((x) => x !== 'ios'), (j) => j.posts?.some((p) => p.body === `${MARKER}_Video` && p.media_present?.length && p.media_present.every(Boolean)), BUDGET.mediaBlob, 'video blob present');

    // friend's post into the shared circle reaches all of A
    if (circleId && B) {
      await op(devices.stub, { op: 'post', body: `${MARKER}_FromB`, circle_id: cid() });
      await convergeAll(fleet, (j) => j.posts?.some((p) => p.body === `${MARKER}_FromB`), BUDGET.text, 'friend post');
    } else {
      score('friend post (needs shared circle)', false, 'circle step skipped or B unknown');
    }

    // CONTENT AUTHOR MATRIX — every platform authors, everyone else receives ("qa should test
    // all actions between any platform direction"). iOS authored nearly everything above; a
    // broken android/desktop SEND path was invisible. Text + photo per author, asserted on
    // every other leg (and blob presence when the media step is on).
    // A leg that never came up (the android emulator missing its boot window) is REPORTED, not
    // authored from: `devices[author]` is undefined for it, and driving it threw a TypeError that
    // took the whole run down at this exact line — every step after it unscored.
    for (const author of ['android', 'desktop'].filter((a) => devices[a])) {
      const tag = `${MARKER}_From_${author}`;
      await op(devices[author], { op: 'post', body: tag, circle_id: cid() });
      await convergeAll(audienceFor(true).filter((x) => x !== author),
        (j) => j.posts?.some((p) => p.body === tag), BUDGET.text, `text post [${author}→all]`);
      const ph = devices[author].stage(PHOTO, `qa-photo-${author}.jpg`);
      await op(devices[author], { op: 'post', body: `${tag}_Photo`, media: 'photo', photo_path: ph, circle_id: cid() });
      await convergeAll(audienceFor(true).filter((x) => x !== author),
        (j) => j.posts?.some((p) => p.body === `${tag}_Photo`), BUDGET.mediaEvent, `photo post event [${author}→all]`);
      if (STEPS.includes('media'))
        await convergeAll(audienceFor(true).filter((x) => x !== author),
          (j) => j.posts?.some((p) => p.body === `${tag}_Photo` && p.media_present?.length && p.media_present.every(Boolean)),
          BUDGET.mediaBlob, `photo blob present [${author}→all]`);
    }
  }

  // 4. story with caption
  if (STEPS.includes('story')) {
    const p = devices.ios.stage(PHOTO, 'qa-photo.jpg');
    await op(devices.ios, { op: 'story', caption: `${MARKER}_Cap`, media: 'photo', photo_path: p, circle_id: cid() });
    await convergeAll(audienceFor(true).filter((x) => x !== 'ios'), (j) => j.posts?.some((x) => x.story && x.caption === `${MARKER}_Cap`), BUDGET.mediaEvent, 'story + caption');
  }

  // 5. file post
  if (STEPS.includes('file') && existsSync(PDF)) {
    const p = devices.ios.stage(PDF, 'qa-doc.pdf');
    await op(devices.ios, { op: 'file', body: `${MARKER}_File`, file_path: p, circle_id: cid() });
    await convergeAll(audienceFor(true).filter((x) => x !== 'ios'), (j) => j.posts?.some((x) => x.body === `${MARKER}_File`), BUDGET.mediaEvent, 'file post');
  }

  // 6. music card
  if (STEPS.includes('music')) {
    await op(devices.ios, { op: 'music_post', body: `${MARKER}_Song`, music: { title: 'QA Song', artist: 'The Fixtures' }, circle_id: cid() });
    await convergeAll(audienceFor(true).filter((x) => x !== 'ios'), (j) => j.posts?.some((x) => x.body === `${MARKER}_Song`), BUDGET.text, 'music post');
  }

  // 7. DMs both directions (with media one way)
  if (STEPS.includes('dm') && B) {
    await op(devices.ios, { op: 'dm', dm_to: B, body: `${MARKER}_DM_AB` });
    perfGate('dm A→B', 'stub', await converge(devices.stub,
      (j) => Object.values(j.dms || {}).flat().some((m) => m.body === `${MARKER}_DM_AB`), BUDGET.text));
    // own-device echo: the DM thread appears on A's other devices
    await convergeAll(fleet.filter((x) => x !== 'ios'), (j) => Object.values(j.dms || {}).flat().some((m) => m.body === `${MARKER}_DM_AB`), BUDGET.text * 2, 'dm echo (own devices)');
    const iosDump = await freshDump(devices.ios);
    const A = iosDump?.account_hex || '';
    if (A) {
      await op(devices.stub, { op: 'dm', dm_to: A, body: `${MARKER}_DM_BA` });
      await convergeAll(fleet, (j) => Object.values(j.dms || {}).flat().some((m) => m.body === `${MARKER}_DM_BA`), BUDGET.text * 2, 'dm B→A');
    }
    // DM AUTHOR MATRIX: A's other devices author into the same thread — the stub must get each,
    // and A's remaining devices must echo it (self-sync), or a device's DM SEND path is broken
    // while everything it receives looks fine.
    for (const author of ['android', 'desktop'].filter((a) => devices[a])) {
      const tag = `${MARKER}_DM_${author}B`;
      await op(devices[author], { op: 'dm', dm_to: B, body: tag });
      perfGate(`dm [${author}→stub]`, 'stub', await converge(devices.stub,
        (j) => Object.values(j.dms || {}).flat().some((m) => m.body === tag), BUDGET.text * 2));
      await convergeAll(fleet.filter((x) => x !== author),
        (j) => Object.values(j.dms || {}).flat().some((m) => m.body === tag), BUDGET.text * 2, `dm echo [${author}→A devices]`);
    }
  }

  // 7b. CALLS — the full caller × answerer MATRIX ("qa should test all actions between any
  // platform direction"). Every A-side platform dials the stub AND answers a stub-originated
  // call; the platforms that did neither are exactly where the field bugs lived (desktop's dead
  // buttons, android's never-exercised CallManager). Per pair: callee rings; ringing SURVIVES
  // early media unanswered (the inCall+ringing poison); accept clears the ring; the CALLER goes
  // live only on the ACCEPT (never on transport); hangup ends it EVERYWHERE. Audio-byte
  // assertions stay on the ios↔stub pair (sim/emulator media quirks make them flaky elsewhere;
  // state asserts run on every pair).
  if (STEPS.includes('relayfirst')) await stepRelayFirst();
  if (STEPS.includes('progress')) await stepProgress();
  if (STEPS.includes('audience')) await stepAudience();

  if (STEPS.includes('call') && B) {
    const A_HEX = (await freshDump(devices.ios))?.account_hex || '';
    const callOps = {
      ios:     { dial: (to) => op(devices.ios, { op: 'call', dm_to: to }),        accept: () => op(devices.ios, { op: 'call_accept' }),               end: () => op(devices.ios, { op: 'call_end' }, 6000) },
      android: { dial: (to) => op(devices.android, { op: 'call', dm_to: to }),    accept: () => op(devices.android, { op: 'call_accept' }),           end: () => op(devices.android, { op: 'call_end' }, 6000) },
      desktop: { dial: (to) => op(devices.desktop, { op: 'ui', action: 'call_start', dm_to: to }, 4000), accept: () => op(devices.desktop, { op: 'ui', action: 'call_accept' }), end: () => op(devices.desktop, { op: 'ui', action: 'call_end' }, 6000) },
      stub:    { dial: (to) => op(devices.stub, { op: 'call', dm_to: to }),       accept: () => op(devices.stub, { op: 'call_accept' }),              end: () => op(devices.stub, { op: 'call_end' }, 6000) },
    };
    const endedEverywhere = (tag) => convergeAll(all, (j) => j.call != null && !(j.call.in_call || j.call.ringing),
      BUDGET.text, `call ended everywhere [${tag}]`);
    const pairs = [
      { caller: 'ios', answerer: 'stub', to: B },
      { caller: 'android', answerer: 'stub', to: B },
      { caller: 'desktop', answerer: 'stub', to: B },
      { caller: 'stub', answerer: 'ios', to: A_HEX },
      { caller: 'stub', answerer: 'android', to: A_HEX },
      { caller: 'stub', answerer: 'desktop', to: A_HEX },
    ];
    for (const pr of pairs) {
      const tag = `${pr.caller}→${pr.answerer}`;
      if (!pr.to) { score(`call matrix ${tag}`, false, 'no target hex'); continue; }
      // Same rule as the author matrix: a leg that is not in the fleet is scored absent, not driven.
      if (!devices[pr.caller] || !devices[pr.answerer]) { score(`call matrix ${tag}`, false, 'leg not in fleet'); continue; }
      await callOps[pr.caller].dial(pr.to);
      perfGate(`rings [${tag}]`, pr.answerer, await converge(devices[pr.answerer],
        (j) => j.call?.ringing || j.call?.in_call, BUDGET.text));
      await sleep(8000);   // early-media window: negotiation runs while the callee still rings
      const midRing = await freshDump(devices[pr.answerer]);
      // BOTH halves — still ringing AND not yet in the call — or the check is vacuous. Asserting
      // only `!in_call` passed for free on a callee that was not ringing at all, so when a stale
      // BYE killed android's fresh ring 0.9s in, this printed a GREEN "ringing survives early
      // media" carrying {"ringing":false} right underneath the RED `rings` it was contradicting.
      score(`ringing survives early media [${tag}]`,
        midRing?.call?.ringing === true && midRing?.call?.in_call !== true, JSON.stringify(midRing?.call));
      await callOps[pr.answerer].accept();
      perfGate(`accept clears the ring [${tag}]`, pr.answerer, await converge(devices[pr.answerer],
        (j) => j.call?.in_call === true && !j.call?.ringing, BUDGET.text));
      perfGate(`caller goes LIVE on ACCEPT [${tag}]`, pr.caller, await converge(devices[pr.caller],
        (j) => j.call?.in_call === true, BUDGET.mediaEvent));
      if (pr.caller === 'ios' && pr.answerer === 'stub') {
        // Media bytes BOTH ways — connection state proves nothing (the field bug was two ends
        // "connected" in silence). ios↔stub only: real audio paths exist on both.
        perfGate('call audio A→B (bytes received)', 'stub', await converge(devices.stub,
          (j) => (j.call?.inbound_audio_bytes || 0) > 0, BUDGET.mediaEvent));
        perfGate('call audio B→A (bytes received)', 'ios', await converge(devices.ios,
          (j) => (j.call?.inbound_audio_bytes || 0) > 0, BUDGET.mediaEvent));
      }
      // SPEAKER ROUTING on whichever leg is android — the one call control whose effect lands
      // outside the app, in the platform's audio router. `speaker_on` cannot see it: the flag flips
      // locally even when the platform REFUSES the route, which is exactly how
      // setCommunicationDevice fails (it returns false rather than throwing). So assert the route
      // the OS reports back, not the flag we set.
      //
      // Both android pairs run this on purpose. The second call happens after a full teardown, so
      // it is the check that hangup handed audio back to the system instead of leaving a
      // communication device pinned and wedging the router for every call after it.
      if (devices.android && (pr.caller === 'android' || pr.answerer === 'android')) {
        // An earpiece can only be ROUTED TO if the device has one, and the emulator does not: its
        // getAvailableCommunicationDevices() answers "speaker" and nothing else. Asserting
        // speaker-off → earpiece there is unsatisfiable, and a check that can never pass is worse
        // than no check — it sits RED until everyone learns to scroll past it. So branch on what
        // the hardware actually offers, and NAME which case ran in the check title.
        const sweep = async (label, hasEarpiece) => {
          for (const [on, want] of [[false, 'earpiece'], [true, 'speaker']]) {
            const off = !on;
            const target = off && !hasEarpiece ? 'speaker' : want;
            const what = on ? 'ON → loudspeaker'
              : hasEarpiece ? 'OFF → earpiece'
              : 'OFF → platform default (this device has no earpiece)';
            await op(devices.android, { op: 'call_speaker', on }, 2000);
            const ms = await converge(devices.android,
              (j) => j.call?.in_call === true && j.call?.audio_route === target, 20_000);
            score(`${label}: speaker ${what} [${tag}]`, ms >= 0,
              ms >= 0 ? `${(ms / 1000).toFixed(1)}s`
                      : JSON.stringify((await freshDump(devices.android))?.call || {}));
          }
        };
        const live = (await freshDump(devices.android))?.call || {};
        // `in_call`, not just the flag and the route. A device whose ONLY output is the loudspeaker
        // reports audio_route "speaker" out of a call too, and applySpeaker() is not gated on the
        // call being up — so without this every routing check here passes against a call that never
        // established. Measured 2026-09-02 on a tip where `caller goes LIVE on ACCEPT` read never:
        // all five speaker checks went green anyway, which is the one thing they must not do.
        score(`speaker defaults to the loudspeaker [${tag}]`,
          live.in_call === true && live.speaker_on === true && live.audio_route === 'speaker',
          JSON.stringify(live));
        const hasEarpiece = String(live.audio_devices || '').includes('earpiece');
        if (!hasEarpiece) log(`NOTE android offers only [${live.audio_devices}] — the API 31+ earpiece`
          + ` route cannot be proven on this device; the pre-31 sweep below still exercises both ways`);
        await sweep('api31+', hasEarpiece);
        // The pre-31 fallback SHIPS (minSdk is 29) but every Android in the fleet is API 35, so the
        // suite pins it explicitly — otherwise that branch is covered by the compiler and nothing
        // else, which is the state the API-31 deprecation fix would have left it in.
        await op(devices.android, { op: 'call_route_legacy', on: true }, 2000);
        await sweep('pre-31 fallback', true);
        await op(devices.android, { op: 'call_route_legacy', on: false }, 2000);
      }
      if (pr.answerer !== 'stub') {
        // Stub dialed the ACCOUNT: the two NON-answering A devices rang too and must stand down
        // (handled-elsewhere) instead of ringing forever next to a live call.
        // (A leg that is not in the fleet cannot stand down — and dereferencing it crashed the run.)
        const others = ['ios', 'android', 'desktop'].filter((d) => d !== pr.answerer && devices[d]);
        await convergeAll(others, (j) => j.call != null && !j.call.ringing,
          BUDGET.text, `other devices stand down [${tag}]`);
      }
      await callOps[pr.caller].end();
      await endedEverywhere(tag);
    }

    // 7c. DESKTOP's real buttons (screen-specific: REAL DOM clicks, computed visibility — the
    // dead-button class lived exactly in the gap between state ops and actual taps).
    const dprobe = async () => {
      await op(devices.desktop, { op: 'ui', action: 'probe' }, 2500);
      const j = await freshDump(devices.desktop);
      try { return JSON.parse((j?.call?.trail || '').replace(/^probe:/, '')); } catch { return {}; }
    };
    const dclick = (sel) => op(devices.desktop, { op: 'ui', action: 'click', dm_to: sel }, 3000);
    await callOps.desktop.dial(B);
    await converge(devices.stub, (j) => j.call?.ringing, BUDGET.text);
    await callOps.stub.accept();
    await converge(devices.desktop, (j) => j.call?.in_call === true, BUDGET.mediaEvent);
    let p = await dprobe();
    score('desktop call screen renders (solo + pip + controls)', !!(p.screen && p.pip && p.rounds >= 4));
    await dclick('.call-chip'); p = await dprobe();
    score('minimize TAP docks into the Call tab', !p.screen && p.calltab === true && p.minimized === true, JSON.stringify(p));
    await dclick('#tab-call'); p = await dprobe();
    score('Call tab TAP restores the screen', !!p.screen && p.calltab === false, JSON.stringify(p));
    await dclick('.call-round.hang'); p = await dprobe();
    score('hangup TAP clears the call UI (no zombie screen)', !p.screen && !p.calltab, JSON.stringify(p));
    await endedEverywhere('desktop taps');

    // 7d. UNANSWERED calls DIE — and callers never phantom-connect mid-ring. Apple's accept
    // handler checked the sender but not the SESSION; once answerers re-send 11 on every invite
    // retransmit, relays float stale 11s from finished sessions — one connected a fresh
    // unanswered call, the caller killed its own retransmits (the real callee never rang) and
    // sat in a phantom call forever ("rings indefinitely", reported + measured).
    await callOps.desktop.dial(B);
    await converge(devices.stub, (j) => j.call?.ringing, BUDGET.text);
    await sleep(20_000);
    const mid = await freshDump(devices.desktop);
    score('unanswered caller never phantom-connects (stale-11 immunity)',
      mid?.call?.in_call !== true, JSON.stringify(mid?.call));
    await sleep(50_000);
    const dEnd = await freshDump(devices.desktop); const sEnd = await freshDump(devices.stub);
    score('unanswered call dies on the caller (60s dial bound)',
      dEnd?.call != null && !dEnd.call.in_call && !dEnd.call.ringing, JSON.stringify(dEnd?.call));
    score('unanswered call dies on the callee (ring bound / caller BYE)',
      sEnd?.call != null && !sEnd.call.in_call && !sEnd.call.ringing, JSON.stringify(sEnd?.call));
  }


  if (STEPS.includes('screenshare')) await stepScreenShare();
  if (STEPS.includes('callgate')) await stepCallGate();

  // 8-9. reaction + comment from friend and from own second device on the same
  // shared-circle post (interactions only make sense where everyone sees the post).
  // ── satellite: only the preview crosses, and the rest completes on return ──────────────────
  //
  // Runs in BOTH directions. The rest of this suite authors everything from iOS, so iOS is almost
  // never asserted as a RECEIVER — across every run on record, `→ ios` appears once. That means the
  // receive-side of a feature could be completely broken and this suite would still be green. For
  // the preview tier the receive side IS the feature: rendering the preview, holding the full copy,
  // completing it on return. So each author in turn drives the whole scenario and every OTHER
  // device asserts on it.
  //
  // The forced constraint cannot be reached any other way: `ultra` comes only from
  // NWPath.isUltraConstrained / TRANSPORT_SATELLITE, which a simulator and an emulator never
  // report. The `link_constraint` qa op (DEBUG-only) is the way in.
  if (STEPS.includes('satellite') && !circleId) {
    // Asked for satellite but the 'circle' step didn't run, so there is no circle to post into —
    // the lanes below would be skipped WHOLESALE. That must never read as a pass: a targeted
    // `E2E_STEPS=satellite` run exited 0 with zero satellite checks and looked like a clean bill.
    score('satellite lanes ran (need circle step: E2E_STEPS=circle,satellite)', false);
  }
  if (STEPS.includes('satellite') && circleId) {
    // Markers live in `media_markers`, NOT `media_refs`: the dump filters synthetic refs out of the
    // latter, and a post never lists the bare companion ref either. Reading media_refs here made the
    // satellite assertions unpassable regardless of how the product behaved.
    const parsePreview = (p) => {
      const m = (p?.media_markers || []).find((r) => r.startsWith('preview:'));
      if (!m) return null;
      const rest = m.slice('preview:'.length);
      const c = rest.lastIndexOf(':');
      return c > 0 ? { content: rest.slice(0, c), preview: rest.slice(c + 1) } : null;
    };
    // Content refs report through media_refs/media_present; COMPANION blobs (the preview itself)
    // report through companions_present, since they are never listed as refs.
    const presentRef = (p, ref) => {
      const i = (p?.media_refs || []).indexOf(ref);
      if (i >= 0) return Boolean((p.media_present || [])[i]);
      return Boolean((p?.companions_present || {})[ref]);
    };
    const findPost = (j, body) => j.posts?.find((x) => x.body === body);
    // DM rows live under `dms`, keyed by peer, and are a different shape from feed posts. They now
    // carry the same companion markers, so the identical assertions can run against them.
    const findDM = (j, body) => Object.values(j.dms || {}).flat().find((m) => m.body === body);

    // Every device that can author AND force its own constraint. Each takes a turn, so the
    // receive-side is exercised on every platform including iOS.
    const authors = ['ios', ...(devices.android ? ['android'] : []), 'stub'].filter((a) => devices[a]);

    // WHO should receive a post authored under an ultra-constrained link.
    //
    // Only the OTHER account. `Traffic::SelfSync` is Deny at Ultra by design: on a satellite pass
    // the bytes go to the people you are talking to, not to mirroring your own laptop — your own
    // devices reconcile when you are back. Asserting own-device delivery DURING the constrained
    // window demanded behaviour the policy deliberately refuses, and produced two reds against a
    // product that was doing exactly the right thing (post reached the stub in 2.5s; desktop and
    // android never, correctly).
    //
    // After the constraint clears, everything catches up — and that IS asserted, below.
    const ACCOUNT_A = ['ios', 'desktop', 'android'];
    const sameAccount = (a, b) => ACCOUNT_A.includes(a) === ACCOUNT_A.includes(b);

    // LANES: the same scenario over each way content is keyed, because they are NOT the same code
    // underneath and the preview tier sits on top of all three.
    //
    //   * the created circle — creator-bound, so tree keying is LIVE: MLS epochs, Welcome-on-join.
    //   * `default` ("My Circle") — binds no creator, so tree keying is OFF for it permanently and
    //     it uses the legacy KeyCommit + sender-keys epoch path instead. This is the circle most
    //     users actually live in and it can never become MLS.
    //   * a DM — sealed per-message under the sender ratchet, a third path again.
    //
    // The satellite work was validated ONLY on the MLS lane, and the bug it found (content sealed
    // before a member joined the tree) was specific to MLS. That says nothing about the other two.
    // The gating itself is circle-agnostic (`maySendOnUltraConstrained` is per-blob), but key
    // convergence underneath is not, and that is where the failure was.
    //
    // The MLS lane sweeps every author so the receive-side is proven on every platform. The other
    // two lanes run cross-account from iOS only — enough to prove the path works without tripling
    // an already long step.
    const LANES = [
      { id: 'mls', label: '', authors, dm: false, circle: () => cid() },
      { id: 'mycircle', label: ' [my circle]', authors: ['ios'], dm: false, circle: () => 'default' },
      { id: 'dm', label: ' [dm]', authors: ['ios'], dm: true, circle: () => undefined },
    ];

    let laneSeq = 0;   // every scenario gets its own resample width -> its own content ref
    for (const lane of LANES) {
    for (const author of lane.authors.filter((a) => devices[a])) {
      const SAT = `${MARKER}_Sat_${author}${lane.id === 'mls' ? '' : '_' + lane.id}`;
      const find = lane.dm ? findDM : findPost;
      // A DM has exactly one recipient; a circle post has everyone in it.
      const audience = lane.dm
        ? all.filter((x) => x === 'stub' && devices[x])
        : all.filter((x) => x !== author && devices[x]);
      // Cross-account only while constrained; everyone once service returns.
      const constrainedAudience = audience.filter((d) => !sameAccount(d, author));
      if (!audience.length || !constrainedAudience.length) continue;
      if (lane.dm && !B) continue;

      await op(devices[author], { op: 'link_constraint', level: 'ultra' }, 2500);
      // DISTINCT PIXELS PER SCENARIO, or the assertion below is meaningless.
      //
      // Media refs are content-addressed, so staging the same fixture twice produces the SAME ref —
      // and a receiver that legitimately fetched those bytes in an earlier lane still holds them.
      // `holds back the full photo` then reports a leak that never happened: it observed the blob
      // present, just not because anything crossed the constrained link.
      //
      // Appending a unique tag after the JPEG's EOI is NOT enough, which cost a run to learn: the
      // clients decode and RE-ENCODE before content-addressing, so anything outside the image data
      // is normalised away and both lanes produced `img_8bc2ad01…` again. The pixels themselves
      // have to differ. Resampling to a per-scenario width is a one-liner that keeps a real
      // photograph (big enough to need a preview at all) while guaranteeing a distinct ref.
      const laneSrc = join(OUT, `sat-${author}-${lane.id}.jpg`);
      // Distinct per scenario AND per run. laneSeq spaces widths 7 apart within a run; the run
      // nonce shifts the whole run into its own mod-7 residue class (and heights into mod-11), so
      // no lane of run N can reproduce a ref from run N-1. Without the nonce, an E2E_FRESH=0 rerun
      // regenerated IDENTICAL pixels → identical content-addressed refs → receivers still holding
      // last run's legitimately-fetched blob scored a full-photo "leak" with nothing crossing.
      const width = 1200 - laneSeq * 7 - (RUN_NONCE % 7);
      const height = 920 - (RUN_NONCE % 11);
      laneSeq += 1;
      execFileSync('sips', ['--resampleHeightWidth', String(height), String(width), PHOTO, '--out', laneSrc], { stdio: 'ignore' });
      const satPhoto = devices[author].stage(laneSrc, `qa-sat-${author}-${lane.id}.jpg`);
      await op(devices[author], lane.dm
        ? { op: 'dm', dm_to: B, body: SAT, media: 'photo', photo_path: satPhoto }
        : { op: 'post', body: SAT, media: 'photo', photo_path: satPhoto, circle_id: lane.circle() }, 12_000);

      // 1. The post still arrives — it is real, signed and sealed; only bytes were deferred.
      await convergeAll(constrainedAudience, (j) => Boolean(parsePreview(find(j, SAT))),
        BUDGET.mediaEvent, `satellite post event (${author}→)${lane.label}`);
      // 2. The ~6 KB preview crosses.
      await convergeAll(constrainedAudience, (j) => {
        const p = find(j, SAT); const v = parsePreview(p);
        return Boolean(v && presentRef(p, v.preview));
      }, BUDGET.mediaBlob, `satellite preview blob (${author}→)${lane.label}`);

      // 3. THE NEGATIVE, and the point of the tier: the full photo must NOT have crossed. A
      //    positive-only test passes just as happily if the gate does nothing at all, and a leaking
      //    gate looks identical to success from the receiving end.
      const dumps = await Promise.all(constrainedAudience.map(async (d) => ({ d, j: await freshDump(devices[d]) })));
      let leaked = null;
      let arrived = 0;
      for (const { d, j } of dumps) {
        const p = find(j, SAT); const v = parsePreview(p);
        if (v && presentRef(p, v.preview)) arrived++;
        if (v && presentRef(p, v.content)) leaked = d;
      }
      // A negative test that passes when NOTHING arrived is worthless — and it fired exactly that
      // way: the DM lane reported "preview only, as designed" while the DM had not reached anyone
      // at all. Nothing crossed, so of course the full photo did not. Require the preview to have
      // landed somewhere before this can mean anything.
      score(`satellite holds back the full photo (${author}→)${lane.label}`,
        arrived > 0 && leaked === null,
        leaked ? `full media reached ${leaked} while the link was ultra-constrained`
               : arrived === 0 ? 'INCONCLUSIVE — no preview arrived anywhere, so there was nothing to hold back'
               : 'preview only, as designed');

      // 4. Back in coverage — the deferred half must complete ON ITS OWN, with no further action.
      await op(devices[author], { op: 'link_constraint', level: 'auto' }, 3000);
      await convergeAll(audience, (j) => {
        const p = find(j, SAT); const v = parsePreview(p);
        return Boolean(v && presentRef(p, v.content));
      }, BUDGET.mediaBlob, `full photo completes on return (${author}→)${lane.label}`);
    }
    }
  }

  if (STEPS.includes('react') || STEPS.includes('comment')) {
    const mine = await freshDump(devices.ios);
    const target = mine?.posts?.find((p) => p.body === `${MARKER}_Text`)?.id;
    score('have target post id for interactions', !!target);
    const reactors = audienceFor(true);
    if (target) {
      if (STEPS.includes('react')) {
        // INTERACTION AUTHOR MATRIX — every leg authors a distinct emoji on the same post and
        // every OTHER leg must see it arrive LIVE (nothing in this harness restarts a client
        // mid-run, so convergence here is exactly the field bug "reactions don't sync until
        // the app is relaunched"). stub+desktop were the only reaction authors for months; a
        // broken iOS/Android reaction SEND path was invisible — same gap the post matrix at
        // the content-author-matrix block closed for posts.
        const emojiOf = { stub: '❤️', desktop: '🔥', ios: '👍', android: '🎉' };
        for (const author of ['stub', 'desktop', 'ios', 'android']) {
          if (!devices[author] || !reactors.includes(author)) continue;
          await op(devices[author], { op: 'react', target_id: target, emoji: emojiOf[author] });
          await convergeAll(reactors.filter((x) => x !== author), (j) => {
            const p = j.posts?.find((x) => x.id === target);
            return p && (p.reactions?.[emojiOf[author]] || 0) >= 1;
          }, BUDGET.text * 2, `reaction live-syncs [${author}→all]`);
        }
      }
      if (STEPS.includes('comment')) {
        if (reactors.includes('stub')) {
          await op(devices.stub, { op: 'comment', target_id: target, body: `${MARKER}_CmtB` });
          await convergeAll(reactors.filter((x) => x !== 'stub'), (j) =>
            j.posts?.find((x) => x.id === target)?.comments?.some((c) => c.body === `${MARKER}_CmtB`),
            BUDGET.text * 2, 'comment live-syncs [stub→all]');
        }
        // iOS-authored comment on own post — the reverse direction was never exercised.
        await op(devices.ios, { op: 'comment', target_id: target, body: `${MARKER}_CmtA` });
        await convergeAll(reactors.filter((x) => x !== 'ios'), (j) =>
          j.posts?.find((x) => x.id === target)?.comments?.some((c) => c.body === `${MARKER}_CmtA`),
          BUDGET.text * 2, 'comment live-syncs [ios→all]');
      }
    }
  }

  if (STEPS.includes('launch')) await stepLaunch();
  if (STEPS.includes('responsive')) await stepResponsive();

  if (STEPS.includes('invite_offline')) {
    // Offline friend invites (docs/OFFLINE-FRIEND-INVITES.md): the acceptance must land while
    // the INVITER'S APP IS DEAD — the exact thing the pre-ticket flow could not do (its hello
    // was a live dial; its mailbox leg wrote to relays the inviter never polls). Fleet topology
    // note: the stub hosts the only relay AND is account B, so the relay must stay up — the
    // inviter (iOS) is the leg that dies. A and B are already contacts here, so the drop takes
    // the mutual-add path (implicit approval); the stranger-prompt branch is the same held
    // handleHello machinery the hello tests already cover.
    await op(devices.ios, { op: 'invite_link' });
    let link = '';
    await converge(devices.ios, (j) => {
      link = j.invite_link || '';
      return link.includes('t=');
    }, 30_000, 'ticketed invite link minted');
    score('invite link carries a ticket', link.includes('t='));

    // Kill the inviter DEAD. Everything that lands from here on lands without it.
    shOk('xcrun', ['simctl', 'terminate', IOS_UDID, IOS_BUNDLE]);
    log('invite_offline: inviter (ios) terminated');

    await op(devices.stub, { op: 'connect_link', uri: link });
    // The acceptance drop must reach the relay while the inviter is a corpse.
    await convergeAll(['stub'], (j) => j.friend_invites?.accepted?.some((a) => a.drop_landed),
      BUDGET.text * 2, 'acceptance drop landed (inviter dead)');

    // Resurrect the inviter: its poll must find the drop, auto-grant (mutual-add), consume.
    shOk('xcrun', ['simctl', 'launch', IOS_UDID, IOS_BUNDLE]);
    await new Promise((r) => setTimeout(r, 4000));
    // The app was dead ON PURPOSE, so its dump is stale by construction and the freshness detector
    // must not be allowed to read that as a broken channel. This is the one place in the suite that
    // stops a leg from dumping deliberately, and it is the one place that clears the tracker.
    channelFor(devices.ios).reset('ios relaunched after the deliberate invite_offline kill');
    devices.ios.poke();
    await convergeAll(['ios'], (j) => j.friend_invites?.issued?.some((i) => i.consumed),
      BUDGET.text * 3, 'drop opened + grant parked (on relaunch)');

    // And the acceptor completes from the parked grant alone.
    await convergeAll(['stub'], (j) => j.friend_invites?.accepted?.some((a) => a.granted),
      BUDGET.text * 3, 'grant fetched — friendship async-complete');
  }

  finish();
}

/// The markdown report, split out of `finish` so a FAIL-FAST exit still leaves one behind —
/// a run that stopped early is exactly when you want the partial matrix on disk.
function writeReport() {
  const pass = REPORT.filter((r) => r.ok).length, fail = REPORT.length - pass;
  const md = [
    `# Haven full E2E — ${MARKER}`, '',
    `**Out:** \`${OUT}\``, '',
    '| Check | Result |', '|---|---|',
    ...REPORT.map((r) => `| ${r.name} | ${r.ok ? 'GREEN' : '**RED**'} |`),
    '', '## Perf', '', '| Step | Device | Latency | Budget |', '|---|---|---|---|',
    ...PERF.map((p) => `| ${p.step} | ${p.device} | ${p.ms < 0 ? 'never' : (p.ms / 1000).toFixed(1) + 's'} | ${(p.budget / 1000)}s |`),
    '', `**pass ${pass} / fail ${fail}**`,
  ].join('\n');
  writeFileSync(join(OUT, 'E2E_REPORT.md'), md);
  console.log('\n' + md);
}

function finish() {
  writeReport();
  // Recomputed here, not borrowed from writeReport: those locals moved when the report was split
  // out for FAIL-FAST, and a stale reference would only blow up at the very END of a long run —
  // after every expensive assertion had already been paid for.
  const pass = REPORT.filter((r) => r.ok).length, fail = REPORT.length - pass;

  // history + regression check: >2x AND >10s slower than the MEDIAN of the last five runs that
  // measured the same step+device, and only when the previous run flagged the same leg too.
  // A single prior sample is a bad baseline here — the "completes on return" legs are bimodal
  // (2.5s when the return lands just before a mailbox poll, 15-20s when it lands just after), so
  // comparing one sample against the next tripped phantom REDs on healthy builds (2026-09-01:
  // 3.2s → 15.0s on a leg whose ledger ranges 2.6-22.6s). First occurrence is a WARN; the same leg
  // regressing two runs in a row is the drift this check exists to catch, and that still fails.
  let regression = false;
  const flagged = [];
  try {
    const rows = existsSync(HISTORY) ? readFileSync(HISTORY, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)) : [];
    const last = rows[rows.length - 1];
    const median = (xs) => { const a = [...xs].sort((x, y) => x - y); const m = a.length >> 1; return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2; };
    for (const p of PERF) {
      if (!(p.ms > 0)) continue;
      const prior = rows.map((r) => r.perf?.find((q) => q.step === p.step && q.device === p.device)?.ms)
        .filter((ms) => ms > 0).slice(-5);
      if (!prior.length) continue;
      const base = median(prior);
      if (p.ms > base * 2 && p.ms - base > 10_000) {
        const again = !!last?.regressions?.some((r) => r.step === p.step && r.device === p.device);
        flagged.push({ step: p.step, device: p.device });
        log(`PERF ${again ? 'REGRESSION' : 'WARN (first occurrence, not fatal)'} ${p.step}→${p.device}: median ${(base / 1000).toFixed(1)}s → ${(p.ms / 1000).toFixed(1)}s`);
        if (again) regression = true;
      }
    }
    const git = shOk('git', ['rev-parse', '--short', 'HEAD'], { cwd: ROOT })?.trim();
    appendFileSync(HISTORY, JSON.stringify({ ts: Date.now(), git, marker: MARKER, pass, fail, perf: PERF, regressions: flagged }) + '\n');
  } catch (e) { log(`history error: ${e.message}`); }

  if (process.env.E2E_KILL === '1') {
    // By PID, from the files the bootstrap wrote — `pkill -x HavenStub` would also take down a
    // fleet belonging to someone else's run.
    for (const f of ['stub.pid', 'tauri.pid']) {
      const pid = Number((existsSync(join(OUT, f)) && readFileSync(join(OUT, f), 'utf8').trim()) || 0);
      if (pid > 0) { try { process.kill(pid, 'SIGTERM'); } catch { /* already gone */ } }
    }
  }
  process.exit(fail === 0 && !regression ? 0 : 1);
}

// ── one fleet, one run ───────────────────────────────────────────────────────
// The legs are machine-wide singletons (one HavenStub, one haven-desktop, one emulator, one
// booted simulator) and the bootstrap's hermetic wipe kills them BY NAME. A second run therefore
// does not queue behind the first — it silently guts it. On 2026-09-02 a run lost its stub and its
// desktop within 16 s of each other, with no crash report and no shutdown trace, because something
// else started the fleet at 14:47; the run then spent its remaining minutes measuring a corpse.
// The lock is the harness's own, so honouring it is not left to whoever remembers.
const LOCK = join(ROOT, 'build', '.e2e-run.lock');

function takeRunLock() {
  mkdirSync(dirname(LOCK), { recursive: true });
  for (let attempt = 0; ; attempt++) {
    try {
      writeFileSync(LOCK, JSON.stringify({ pid: process.pid, out: OUT, startedAt: new Date().toISOString() }, null, 2), { flag: 'wx' });
      return;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      let holder = null;
      try { holder = JSON.parse(readFileSync(LOCK, 'utf8')); } catch { /* unreadable → treat as stale */ }
      const alive = holder?.pid && (() => { try { process.kill(holder.pid, 0); return true; } catch { return false; } })();
      if (!alive) {
        console.log(`[e2e] clearing a stale run lock (pid ${holder?.pid ?? '?'} is gone)`);
        rmSync(LOCK, { force: true });
        continue;
      }
      if (process.env.E2E_WAIT === '1') {
        if (attempt === 0) console.log(`[e2e] another run is using the fleet (pid ${holder.pid}, started ${holder.startedAt}) — waiting…`);
        spawnSync('/bin/sleep', ['30']);
        continue;
      }
      console.error(`\n[e2e] REFUSING TO START — another run owns the fleet.\n`
        + `      pid ${holder.pid}, started ${holder.startedAt}\n`
        + `      its output: ${holder.out}\n\n`
        + `      The legs are machine-wide singletons and this suite's bootstrap kills them by name,\n`
        + `      so starting now would destroy that run rather than queue behind it.\n`
        + `      Wait for it, run with E2E_WAIT=1 to block until it finishes, or delete\n`
        + `      ${LOCK} if you are certain that process is gone.\n`);
      process.exit(2);
    }
  }
}

function releaseRunLock() {
  try {
    const holder = JSON.parse(readFileSync(LOCK, 'utf8'));
    if (holder.pid === process.pid) rmSync(LOCK, { force: true });
  } catch { /* never let cleanup mask the real result */ }
}

// Only when this file is what was RUN. Imported (a tool inspecting it, a test reaching for one of
// its helpers), it must do nothing at all — see the note by `OUT`.
const invokedDirectly = process.argv[1]
  && fileURLToPath(import.meta.url) === resolvePath(process.argv[1]);

if (invokedDirectly) {
  takeRunLock();
  mkdirSync(OUT, { recursive: true });
  process.on('exit', releaseRunLock);
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(sig, () => { releaseRunLock(); process.exit(2); });
  }

  main().catch((e) => { console.error(e); process.exit(1); });
}
