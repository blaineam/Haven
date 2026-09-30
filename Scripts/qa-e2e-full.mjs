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
import { readFileSync, writeFileSync, existsSync, mkdirSync, appendFileSync, rmSync, statSync, readdirSync, openSync, closeSync, utimesSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { join, dirname, resolve as resolvePath } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ChannelFreshness, DumpStats, judgeDump, fmtDuration, FRESHNESS_DEFAULTS } from './lib/dump-freshness.mjs';
import {
  num, delta, parseUiNodes, findNode, center, CONSENT, isConsentSurface, holdsMediaProjection, auditShareLog,
  longSide, remoteSlots, sharedScreen, suspendedFor, liftedFrom, missingPerfFields, persistExportAllowance,
  reactLatency, ingestedFirst, feedNotGatedOnDmWarm, nonDecreasing, recordProgress, badgeTransitions,
} from './lib/e2e-steps.mjs';
import {
  portPlan, collisionVerdict, decodeComp, eventKeys, mailboxCircles, holdsMedia, misplacedCircles, keyDiff,
  stableCounts, tokenFingerprint, urlPort, attributionProblems, statsRow, statsCounter, knowsUrlPort, hitsBetween,
  herdVerdict, strangerIdentity, strangerAuth, isolationVerdict, inflightMedia, resurrected, freshMints,
} from './lib/multirelay.mjs';

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
const STEPS = (process.env.E2E_STEPS || 'newfriend,profile,circle,post,story,file,music,dm,relayfirst,progress,audience,call,screenshare,callgate,react,comment,media,satellite,launch,responsive,invite_offline,multirelay').split(',');

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
// Every adb call gets a ceiling. They are synchronous, so ONE hung `adb shell am start` (a wedged
// emulator — seen on the multirelay run: 6+ minutes, with two relays and a proxy idling behind it)
// froze the whole harness. A timed-out call returns null, which every adb caller already treats as
// "that leg is unhealthy", exactly like any other adb failure. `E2E_ADB_TIMEOUT_MS` overrides.
const ADB_TIMEOUT_MS = +(process.env.E2E_ADB_TIMEOUT_MS || 60_000);
function shOk(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', ...(cmd === 'adb' ? { timeout: ADB_TIMEOUT_MS } : {}), ...opts });
  if (r.error?.code === 'ETIMEDOUT') log(`WARN adb ${args.slice(0, 3).join(' ')} … hung ${ADB_TIMEOUT_MS / 1000}s — killed`);
  return r.status === 0 ? (r.stdout || '') : null;
}
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

// The android channel lives in the app's INTERNAL files dir — `files/qa/` under the debuggable
// build's data dir, reached with `run-as`. It used to be `/sdcard/Download`, where MediaProvider
// owns a row per file: after reinstalls (owner UID change) or over long runs those rows rotted,
// renames failed ("MediaProvider: Database update failed while renaming …qa-dump….json.tmp"), and
// the harness read frozen dumps (or none) while the app was healthy — killing whole runs. Nothing
// here touches shared storage any more.
const ANDROID_QA_DIR = 'files/qa';                                   // relative to the app's data dir
const ANDROID_QA_ABS = `/data/user/0/${AND_PKG}/${ANDROID_QA_DIR}`;  // what the app sees (staged media paths)
let andPushSeq = 0;

/// `adb exec-out run-as <pkg> cat files/qa/<name>` — the file's bytes, or null if unreadable.
/// exec-out is binary-clean (no pty CRLF mangling); a missing file answers non-zero → null.
function androidQaRead(name) {
  return shOk('adb', ['exec-out', `run-as ${AND_PKG} cat ${ANDROID_QA_DIR}/${name} 2>/dev/null`]);
}

/// Deliver a host file to `files/qa/<name>` atomically: push to a UNIQUE shell-owned tmp, run-as
/// copy it to `<name>.tmp` in the SAME dir, then `mv` (a rename — the driver sees the old file or
/// the whole new one, never half). The shell tmp is removed in the same round trip. Returns true on
/// success. `run-as` reading /data/local/tmp is what the bootstrap's seed staging has always used.
//
// A failed attempt is LOGGED WITH ITS CAUSE (exit status / signal / timeout + stderr) and retried:
// the 2026-09-30 gate lost its android leg to one bare "qaWrite 'dump' failed" with nothing saying
// why (it was a 60 s hang — the emulator's system_server wedged under an app CPU storm). A single
// hiccup must not RED a leg, and a persistent one must name itself.
const AND_QA_WRITE_ATTEMPTS = +(process.env.E2E_AND_QA_WRITE_ATTEMPTS || 3);
function adbAttempt(args) {
  const r = spawnSync('adb', args, { encoding: 'utf8', timeout: ADB_TIMEOUT_MS });
  if (r.status === 0 && !r.error) return null;
  const why = r.error?.code === 'ETIMEDOUT' ? `hung ${ADB_TIMEOUT_MS / 1000}s — killed`
    : r.error ? `${r.error.code || r.error.message}`
    : r.signal ? `killed by ${r.signal}` : `exit ${r.status}`;
  const err = String(r.stderr || r.stdout || '').trim().split('\n').slice(-2).join(' | ').slice(0, 200);
  return err ? `${why}: ${err}` : why;
}
function androidQaWrite(src, name) {
  const d = ANDROID_QA_DIR;
  for (let attempt = 1; attempt <= AND_QA_WRITE_ATTEMPTS; attempt++) {
    const tmp = `/data/local/tmp/haven-qa-${process.pid}-${++andPushSeq}-${name}`;
    // The in-dir tmp is unique per attempt too: a retry must not race a half-finished `cat` from a
    // killed attempt into the same `<name>.tmp`.
    const dtmp = `${d}/${name}.${process.pid}-${andPushSeq}.tmp`;
    const inner = `umask 077 && mkdir -p ${d} && cat ${tmp} > ${dtmp} && mv -f ${dtmp} ${d}/${name}`;
    const why = adbAttempt(['push', src, tmp])
      ?? adbAttempt(['shell', `run-as ${AND_PKG} sh -c '${inner}'; rc=$?; rm -f ${tmp}; run-as ${AND_PKG} rm -f ${dtmp}; exit $rc`]);
    if (why === null) {
      if (attempt > 1) log(`android qaWrite '${name}' landed on attempt ${attempt}`);
      return true;
    }
    log(`WARN android qaWrite '${name}' attempt ${attempt}/${AND_QA_WRITE_ATTEMPTS} failed — ${why}`);
    if (attempt < AND_QA_WRITE_ATTEMPTS) spawnSync('sleep', [String(attempt)]);
  }
  return false;
}

function makeAndroid() {
  // Every adb interaction is best-effort: an emulator hiccup (adb restarts, a wedged shell) must
  // degrade this leg to RED checks, never crash the whole run.
  let iofails = 0;
  const note = (ok) => {
    if (!ok && ++iofails === 3) log('WARN: android adb failing repeatedly — leg will show RED');
    return ok;
  };
  const cmdPath = `${ANDROID_QA_DIR}/qa-cmd.json`;
  const dumpName = `qa-dump-${AND_PKG}.json`;
  return {
    label: 'android',
    qaWrite: (cmd) => {
      const tmp = join(OUT, 'and-cmd.json'); writeFileSync(tmp, JSON.stringify(cmd));
      if (!note(androidQaWrite(tmp, 'qa-cmd.json'))) log(`WARN android qaWrite '${cmd.op}' failed — this leg will read RED`);
    },
    poke: () => note(shOk('adb', ['shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', 'haven://qa']) !== null),
    // Like the host legs: the driver deletes the drop on consume, so "still there" means "not yet
    // taken" — and waiting for that keeps the NEXT command from overwriting an unconsumed one. An
    // adb failure answers "not pending" so a sick emulator cannot stall every op for 10s.
    pending: () => shOk('adb', ['shell', `run-as ${AND_PKG} test -f ${cmdPath} && echo y`])?.trim() === 'y',
    dump: () => readJsonText(androidQaRead(dumpName)),
    stage: (src, name) => { note(androidQaWrite(src, name)); return `${ANDROID_QA_ABS}/${name}`; },

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
    // Drop the dump + any half-staged drop so the driver mints them again on its next op.
    wipe: () => {
      const d = ANDROID_QA_DIR;
      // `*.tmp` covers every writer's per-attempt tmp names (QaFiles on the app side, androidQaWrite
      // here); the glob must expand INSIDE run-as — the shell user cannot list the app's dir.
      const out = shOk('adb', ['shell', `run-as ${AND_PKG} sh -c 'rm -f ${d}/${dumpName} ${cmdPath} ${d}/*.tmp' 2>&1`]);
      if (out === null) return ['adb shell run-as rm failed outright (app not installed / not debuggable?)'];
      // `rm -f` exits 0 even when the unlink is refused, so its OUTPUT is the only signal.
      return String(out).trim() ? [String(out).trim()] : [];
    },
    diagnose: () => {
      const out = [];
      // Two questions before anything else: is the app even running, and is it FOREGROUNDED?
      // QaDriver polls the drop file only between onResume and onPause, so a backgrounded
      // activity is a dead dump channel.
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
      const p = `${ANDROID_QA_DIR}/${dumpName}`;
      // Age computed ON THE DEVICE so neither clock skew nor date parsing can distort it.
      const st = shOk('adb', ['shell', `echo "$(run-as ${AND_PKG} stat -c "%s|%U|%Y" ${p})|$(date +%s)"`]);
      const [size, owner, mtime, now] = String(st || '').trim().split('|');
      if (mtime && now) {
        out.push(`dump file:  ${p}`);
        out.push(`            ${size} B, owner ${owner}, mtime ${fmtDuration((Number(now) - Number(mtime)) * 1000)} ago`);
      } else {
        out.push(`dump file:  ${p} — cannot stat (${String(st || '(adb failed)').trim().split('\n')[0]})`);
      }
      // The driver logs every failed dump write; surface the latest so the cause is in the report.
      const lg = shOk('adb', ['logcat', '-d', '-t', '4000', '-s', 'HavenQA']) || '';
      const hits = lg.split('\n').filter((l) => /qa-dump write failed|qa-cmd .* failed/.test(l));
      out.push(hits.length
        ? `logcat:     ${hits.length} HavenQA failure line(s); last: ${hits[hits.length - 1].trim().slice(0, 160)}`
        : 'logcat:     no HavenQA write/op failures in the last 4000 lines — look at whether the activity'
          + ' is foregrounded (the driver polls only while it is).');
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
    diagnose: () => [procLine('haven-desktop', hostProcAlive('target/qa/haven-desktop')),
                     ...localDumpDiag(join(DESK_DATA, 'qa-dump.json'))],
  };
}

function readJson(p) { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; } }
function readJsonText(t) { try { return t ? JSON.parse(t) : null; } catch { return null; } }

/// Drop a host-side leg's qa files so the driver mints them again — the file-based twin of the
/// android run-as wipe. Both drivers rewrite the dump on their next heartbeat (<=5s).
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
// A leg that cannot be TOLD anything reports its state cheerfully and ignores every instruction
// (the 2026-09-03 release gate lost its whole android call matrix that way, back when the channel
// ran through /sdcard and MediaProvider). Prove the exact write path qaWrite uses by round trip —
// a probe NAME the driver never consumes, so this is safe while the app runs.
function assertAndroidCommandChannel() {
  const probe = join(OUT, 'and-channel-probe.json');
  const body = JSON.stringify({ op: 'channel-probe', nonce: RUN_NONCE });
  writeFileSync(probe, body);
  const wrote = androidQaWrite(probe, 'qa-channel-probe.json');
  const got = androidQaRead('qa-channel-probe.json')?.trim();
  shOk('adb', ['shell', `run-as ${AND_PKG} rm -f ${ANDROID_QA_DIR}/qa-channel-probe.json`]);
  if (wrote && got === body) { log(`android command channel: verified (run-as round trip through ${ANDROID_QA_DIR}/)`); return true; }
  log('WARN: ANDROID COMMAND CHANNEL IS DEAD — a run-as write into the app\'s files/qa/ did not read back.');
  log('      Every android check in this run would be about the harness, not the app.');
  log(`      Check: adb shell run-as ${AND_PKG} ls ${ANDROID_QA_DIR}  (the DEBUG build must be installed — run-as needs debuggable)`);
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

/// Per-leg dump-channel stats for the report (Scripts/lib/dump-freshness.mjs ▸ DumpStats).
const DUMP_STATS = new DumpStats();

async function noteDumpFreshness(dev, issuedAt, dump) {
  const ch = channelFor(dev);
  if (ch.suspended) return;                    // a recovery's own reads must not re-trip this
  const r = ch.observe({ issuedAt, dumpTsMs: dumpTsOf(dump), skewMs: SKEW[dev.label] ?? 0 });
  DUMP_STATS.note(dev.label, r);
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
  log(`  android confirm the app is FOREGROUNDED — its driver polls only while it is — and read the`);
  log(`  HavenQA logcat line above. Set E2E_STALE_ABORT=0 to run on regardless.`);
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

// ── multirelay fleet: headless `haven-relay` CLI instances + the counting proxy ─────────────
//
// Owned by this process and ONLY this process: every relay and the proxy are spawned here, their
// pids are recorded in OUT/, and teardown kills exactly those pids — never by name, because the
// user's own `haven-relay` (or another agent's) may be running on this Mac. Teardown runs from
// `finish()`, from FAIL-FAST exits and from the process `exit` hook, so no path leaves one behind.
const MR = { bin: '', procs: new Map(), proxy: null, preexisting: [] };

function mrPgrep() {
  const out = shOk('pgrep', ['-fl', 'haven-relay']) || '';
  return out.split('\n').map((l) => l.trim()).filter((l) => l && !/pgrep/.test(l));
}

/** Is anything LISTENING on this TCP port? (lsof; null = could not tell.) */
function mrPortBusy(port) {
  const r = spawnSync('lsof', ['-nP', `-iTCP:${port}`, '-sTCP:LISTEN', '-t'], { encoding: 'utf8' });
  if (r.error) return null;
  return String(r.stdout || '').trim().length > 0;
}

function mrBuild() {
  const log = join(OUT, 'relay-build.log');
  const r = spawnSync('cargo', ['build', '-p', 'haven-relay'], { cwd: join(ROOT, 'core'), encoding: 'utf8' });
  writeFileSync(log, `${r.stdout || ''}\n${r.stderr || ''}`);
  const bin = join(ROOT, 'core/target/debug/haven-relay');
  return r.status === 0 && existsSync(bin) ? bin : null;
}

/** `haven-relay id` for a seed — the node id the relay WILL have, known before it starts. */
function mrNodeId(dir, seed) {
  mkdirSync(dir, { recursive: true });
  return (shOk(MR.bin, ['id', '--data', dir], { env: { ...process.env, HAVEN_RELAY_SEED: seed } }) || '').trim();
}

function mrStartRelay(name, { dir, seed, link, internal, pub, peers = [], env = {}, bind = '127.0.0.1' }) {
  mkdirSync(dir, { recursive: true });
  const args = ['run', ...(link ? ['--link', link] : []), '--data', dir,
    '--http', `${bind}:${internal}`, '--http-url', `http://127.0.0.1:${pub}`,
    '--no-tunnel', '--no-derp', '--no-turn', '--no-proxy', ...peers.flatMap((p) => ['--peer', p])];
  const logPath = join(OUT, `relay-${name}.log`);
  const fd = openSync(logPath, 'a');
  const child = spawn(MR.bin, args, { env: { ...process.env, HAVEN_RELAY_SEED: seed, ...env }, stdio: ['ignore', fd, fd] });
  closeSync(fd);
  child.exitInfo = null;
  child.on('exit', (code, signal) => { child.exitInfo = { code, signal }; });
  MR.procs.set(name, child);
  writeFileSync(join(OUT, `relay-${name}.pid`), String(child.pid));
  log(`multirelay: started ${name} pid ${child.pid} (${bind}:${internal} → public :${pub})`);
  return child;
}

async function mrStopRelay(name, signal = 'SIGTERM') {
  const child = MR.procs.get(name);
  if (!child) return;
  if (child.exitInfo === null) {
    try { child.kill(signal); } catch { /* gone */ }
    for (let i = 0; i < 50 && child.exitInfo === null; i++) await sleep(100);
    if (child.exitInfo === null) { try { child.kill('SIGKILL'); } catch { /* gone */ } await sleep(300); }
  }
  MR.procs.delete(name);
  log(`multirelay: stopped ${name} (${JSON.stringify(child.exitInfo)})`);
}

/** Wait for a relay's interface.json written at/after `since`, naming `pub`. */
async function mrWaitInterface(dir, pub, since, timeoutMs = 45_000) {
  const p = join(dir, 'interface.json');
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    try {
      if (statSync(p).mtimeMs >= since - 1000) {
        const j = JSON.parse(readFileSync(p, 'utf8'));
        if ((j.urls || []).some((u) => u.endsWith(`:${pub}`))) return j;
      }
    } catch { /* not yet */ }
    await sleep(500);
  }
  return null;
}

async function mrProxyStart(control) {
  const logPath = join(OUT, 'relay-proxy.log');
  const fd = openSync(logPath, 'a');
  const child = spawn(process.execPath, [join(ROOT, 'Scripts/qa-relay-proxy.mjs'), '--control', String(control), '--parent', String(process.pid)],
    { stdio: ['ignore', fd, fd] });
  closeSync(fd);
  child.exitInfo = null;
  child.on('exit', (code, signal) => { child.exitInfo = { code, signal }; });
  MR.proxy = { child, control };
  writeFileSync(join(OUT, 'relay-proxy.pid'), String(child.pid));
  for (let i = 0; i < 40; i++) {
    if (await mrProxy('GET', '/stats').catch(() => null)) return true;
    await sleep(250);
  }
  return false;
}

async function mrProxy(method, path) {
  if (!MR.proxy) return null;
  const r = await fetch(`http://127.0.0.1:${MR.proxy.control}${path}`, { method });
  return r.json();
}

/** Every key a relay store holds: [{key, mtimeMs, size}] (store dir layout: blobstore.rs safe_path). */
function mrStoreKeys(root) {
  const out = [];
  const walk = (dir, parts) => {
    let ents = [];
    try { ents = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      if (e.name.startsWith('.')) continue;
      const p = join(dir, e.name);
      if (e.isDirectory()) walk(p, [...parts, decodeComp(e.name)]);
      else if (e.isFile() && !e.name.endsWith('.part')) {
        try { const st = statSync(p); out.push({ key: [...parts, decodeComp(e.name)].join('/'), mtimeMs: st.mtimeMs, size: st.size }); } catch { /* raced a GC */ }
      }
    }
  };
  walk(root, []);
  return out;
}

/** Synchronous, for the exit hook: SIGTERM everything this run started (and only that). */
function mrKillAll() {
  for (const [, child] of MR.procs) { if (child.exitInfo === null) { try { child.kill('SIGTERM'); } catch { /* gone */ } } }
  MR.procs.clear();
  if (MR.proxy?.child && MR.proxy.child.exitInfo === null) { try { MR.proxy.child.kill('SIGTERM'); } catch { /* gone */ } }
  MR.proxy = null;
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
  if (process.env.E2E_ANDROID === '0') {
    log('android leg SKIPPED by E2E_ANDROID=0 (emulator untouched)');
  } else if (shOk('adb', ['get-state'])?.trim() === 'device') {
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

  // ── multirelay: friends who each run their OWN relay interoperate without colliding ──────────
  //
  // Topology (docs/QA.md ▸ multirelay): R_A = a headless `haven-relay` CLI that ACCOUNT A operates
  // (started from A's own relay link, adopted through A's own "Connect a relay" paste, made A's
  // default); R_B = B's in-app relay (the stub, unchanged); R_C = a SECOND relay B operates, adopted
  // by B for the shared circle only. R_A and R_C sit behind the counting proxy (qa-relay-proxy.mjs)
  // because no relay logs anything — and a dead one can't count.
  //
  // Circles: C_S shared (A+B), C_A private to A, C_B private to B, C_R (A+B) used only to watch a
  // member removal revoke relay access.
  const MRB = {
    announce: +(process.env.E2E_MR_BUDGET_ANNOUNCE || 120_000),
    store: +(process.env.E2E_MR_BUDGET_STORE || 150_000),
    mesh: +(process.env.E2E_MR_BUDGET_MESH || 150_000),
    meshHost: +(process.env.E2E_MR_BUDGET_MESH_HOST || 420_000),
    enroll: +(process.env.E2E_MR_BUDGET_ENROLL || 150_000),
    revoke: +(process.env.E2E_MR_BUDGET_REVOKE || 150_000),
    reannounce: +(process.env.E2E_MR_BUDGET_REANNOUNCE || 360_000),
    token: +(process.env.E2E_MR_BUDGET_TOKEN || 360_000),
    down: +(process.env.E2E_MR_DOWN_MS || 120_000),
    maxDownPerMin: +(process.env.E2E_MR_DOWN_MAX_PER_MIN || 60),
    quiet: +(process.env.E2E_MR_QUIET_MS || 60_000),
    gcTtl: +(process.env.E2E_MR_GC_TTL_S || 60),
  };

  async function stepMultiRelay() {
    const ios = devices.ios, stub = devices.stub;
    const tag = (s) => `${MARKER}_MR_${s}`;
    const readersOfA = ['stub', ...(devices.android ? ['android'] : []), 'desktop'].filter((n) => devices[n]);
    let plan;
    try { plan = portPlan(+(process.env.E2E_MR_PORT_BASE || 8684)); } catch (e) { score('multirelay: port plan', false, e.message); return; }

    // ── 0. preflight: never touch a relay (or a port) this run did not start ──────────────────
    MR.preexisting = mrPgrep();
    log(`multirelay: pre-existing haven-relay processes (left alone): ${MR.preexisting.length ? MR.preexisting.join(' | ') : 'none'}`);
    const planPorts = [plan.ra.pub, plan.ra.internal, plan.rc.pub, plan.rc.internal, plan.ra2.pub, plan.ra2.internal, plan.control];
    const busy = planPorts.filter((p) => mrPortBusy(p));
    score('multirelay: the step\'s ports are free (nothing pre-existing is displaced)', busy.length === 0,
      busy.length ? `busy: ${busy.join(', ')} — set E2E_MR_PORT_BASE` : planPorts.join(','));
    if (busy.length) return;
    MR.bin = mrBuild();
    score('multirelay: haven-relay CLI built from this worktree', !!MR.bin, MR.bin || `see ${join(OUT, 'relay-build.log')}`);
    if (!MR.bin) return;
    if (!(await mrProxyStart(plan.control))) { score('multirelay: counting proxy up', false); return; }
    for (const r of ['ra', 'rc', 'ra2']) {
      const res = await mrProxy('POST', `/route?pub=${plan[r].pub}&upstream=${plan[r].internal}`);
      if (!res?.listening) { score(`multirelay: proxy listening on :${plan[r].pub}`, false, JSON.stringify(res)); return; }
    }
    if (devices.android) for (const r of ['ra', 'rc', 'ra2']) shOk('adb', ['reverse', `tcp:${plan[r].pub}`, `tcp:${plan[r].pub}`]);

    // ── 1. circles ─────────────────────────────────────────────────────────────────────────────
    const cS = await ensureSharedCircle();
    if (!cS || !B) { score('multirelay (needs a circle shared with B)', false); return; }
    const mkCircle = async (dev, name) => {
      await op(dev, { op: 'circle_create', name }, 2500);
      let id = null;
      await converge(dev, (j) => !!(id = j.circles?.find((c) => c.name === name)?.id), 30_000);
      return id;
    };
    const cA = await mkCircle(ios, tag('CircleA'));
    const cB = await mkCircle(stub, tag('CircleB'));
    const cR = await mkCircle(ios, tag('CircleRevoke'));
    score('multirelay: private + revoke circles created', !!(cA && cB && cR), JSON.stringify({ cA, cB, cR }));
    if (!cA || !cB || !cR) return;
    await op(ios, { op: 'circle_invite', circle_id: cR, dm_to: B });
    const cRMember = await converge(stub, (j) => j.circles?.some((c) => c.id === cR), BUDGET.text * 2);
    score('multirelay: B joined C_R', cRMember >= 0);
    const aDump0 = await freshDump(ios);
    const A = aDump0?.account_hex || '';

    // ── 2. the relays, from each operator's OWN relay link ─────────────────────────────────────
    await op(ios, { op: 'relay_link' }, 1500);
    let linkA = '', linkB = '';
    await converge(ios, (j) => (linkA = j.relay_link || '').startsWith('haven-relay://'), 30_000);
    await op(stub, { op: 'relay_link' }, 1500);
    await converge(stub, (j) => (linkB = j.relay_link || '').startsWith('haven-relay://'), 30_000);
    score('multirelay: both operators minted a relay link in-app', !!(linkA && linkB), `A=${linkA.length}B B=${linkB.length}B`);
    if (!linkA || !linkB) return;
    const RA = { name: 'ra', dir: join(OUT, 'relays/ra'), seed: randomBytes(32).toString('hex') };
    const RC = { name: 'rc', dir: join(OUT, 'relays/rc'), seed: randomBytes(32).toString('hex') };
    RA.node = mrNodeId(RA.dir, RA.seed); RC.node = mrNodeId(RC.dir, RC.seed);
    RA.store = join(RA.dir, 'store'); RC.store = join(RC.dir, 'store');
    let t0 = Date.now();
    // No `--peer` between them on purpose: friends don't hand-configure each other's relay ids.
    // Siblings come from the members (B's in-app host teaches every relay of a shared circle
    // about the others), which is the path that has to work.
    mrStartRelay('ra', { ...RA, link: linkA, internal: plan.ra.internal, pub: plan.ra.pub });
    mrStartRelay('rc', { ...RC, link: linkB, internal: plan.rc.internal, pub: plan.rc.pub });
    RA.iface = await mrWaitInterface(RA.dir, plan.ra.pub, t0);
    RC.iface = await mrWaitInterface(RC.dir, plan.rc.pub, t0);
    score('multirelay: R_A and R_C up (interface published)', !!(RA.iface && RC.iface),
      `R_A=${RA.iface?.node?.slice(0, 10)} R_C=${RC.iface?.node?.slice(0, 10)}`);
    if (!RA.iface || !RC.iface) return;
    RA.token = RA.iface.token; RC.token = RC.iface.token;
    const stubJ = await freshDump(stub);
    const RB = {
      name: 'rb', node: String(stubJ?.hosted_relay?.node || '').toLowerCase(),
      token: process.env.HAVEN_STUB_TOKEN || '8e17157a4fd8f6eeef1c3accdd9fc1de',
      store: join(process.env.HOME, 'Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/haven-relay-store'),
      port: num(stubJ?.hosted_relay?.httpPort) || 8674,
    };
    const rbRow = statsRow(stubJ, RB.node);
    score('multirelay: R_B (B\'s in-app relay) is hosting and its token is the one the fleet was wired with',
      !!RB.node && stubJ?.hosted_relay?.serving === true && (!rbRow?.tokenFp || rbRow.tokenFp === tokenFingerprint(RB.token)),
      JSON.stringify(stubJ?.hosted_relay));
    const ids = [RA.node, RB.node, RC.node], toks = [RA.token, RB.token, RC.token];
    const ports = [plan.ra.pub, RB.port, plan.rc.pub];
    score('multirelay: every relay has its own node id, token and port',
      new Set(ids).size === 3 && new Set(toks).size === 3 && new Set(ports).size === 3 && RA.iface.node === RA.node && RC.iface.node === RC.node,
      `ids=${ids.map((x) => x.slice(0, 8))} ports=${ports}`);

    // ── 2b. two relays on ONE port must fail loudly, never split the traffic ───────────────────
    for (const bind of ['0.0.0.0', '127.0.0.1']) {
      const name = `collide-${bind === '0.0.0.0' ? 'wild' : 'lo'}`;
      const dir = join(OUT, `relays/${name}`);
      const child = mrStartRelay(name, { dir, seed: randomBytes(32).toString('hex'), link: linkA, internal: plan.ra.internal, pub: plan.ra.pub, bind });
      for (let i = 0; i < 60 && child.exitInfo === null; i++) await sleep(250);
      const exited = child.exitInfo !== null;
      const output = (() => { try { return readFileSync(join(OUT, `relay-${name}.log`), 'utf8'); } catch { return ''; } })();
      const v = collisionVerdict({ exited, code: child.exitInfo?.code, output });
      score(`multirelay: a second relay on R_A's port (${bind}:${plan.ra.internal}) fails loudly`, v.ok, v.why);
      await mrStopRelay(name);
    }
    score('multirelay: R_A still up after the collision attempts', MR.procs.get('ra')?.exitInfo === null);

    // ── 3. adoption through the real paste flow ────────────────────────────────────────────────
    const ifaceJson = (r) => JSON.stringify({ node: r.iface.node, urls: r.iface.urls, token: r.iface.token });
    await op(ios, { op: 'add_relay', relay: ifaceJson(RA), circle_ids: [cA, cS, cR], default: true }, 3000);
    await op(stub, { op: 'add_relay', relay: ifaceJson(RC), circle_ids: [cS] }, 3000);
    const hasFor = (hex, cid) => (j) => (statsRow(j, hex)?.circles || []).includes(cid);
    gate('multirelay: A adopted R_A for C_A + C_S (as default)', 'ios',
      await converge(ios, (j) => hasFor(RA.node, cA)(j) && hasFor(RA.node, cS)(j) && statsRow(j, RA.node)?.isDefault === true, 30_000), 30_000);
    const tAnn = Date.now();
    gate('multirelay: B learns A\'s relay for C_S (announce)', 'stub',
      await convergeSince(stub, hasFor(RA.node, cS), MRB.announce, tAnn), MRB.announce);
    gate('multirelay: A learns B\'s second relay for C_S (announce)', 'ios',
      await convergeSince(ios, hasFor(RC.node, cS), MRB.announce, tAnn), MRB.announce);
    gate('multirelay: B enrolled on R_A for C_S (B\'s own signed LIST answers 200)', 'stub', await (async () => {
      const t = Date.now();
      while (Date.now() - t < budgetFor(stub, MRB.enroll)) {
        await op(stub, { op: 'relay_probe', relay: RA.node, method: 'LIST', key: `haven/mailbox/${cS}/` }, 2500);
        const j = await freshDump(stub);
        if (j?.relay_probe?.status === 200) return Date.now() - t;
        await sleep(3000);
      }
      return -1;
    })(), MRB.enroll);

    // ── 4. separation: each circle's content on the relays that circle uses, nowhere else ──────
    const before = await snap(['ios', ...readersOfA]);
    const post = async (dev, cid, body, photoTag) => {
      await op(dev, { op: 'post', body, circle_id: cid }, 1500);
      await op(dev, { op: 'post', body: `${body}_Photo`, media: 'photo', circle_id: cid,
        photo_path: dev.stage(distinctPhoto(photoTag), `qa-${photoTag}.jpg`) }, 3000);
    };
    await post(ios, cA, tag('A_Private'), 'mr-a-private');
    await post(stub, cB, tag('B_Private'), 'mr-b-private');
    await post(ios, cS, tag('A_Shared'), 'mr-a-shared');
    await post(stub, cS, tag('B_Shared'), 'mr-b-shared');
    const tPost = Date.now();
    const refOf = (j, body) => (j?.posts || []).find((p) => p.body === body)?.media_refs?.[0] || '';
    const aJ = await freshDump(ios), bJ = await freshDump(stub);
    const refs = { aPriv: refOf(aJ, `${tag('A_Private')}_Photo`), aShared: refOf(aJ, `${tag('A_Shared')}_Photo`),
      bPriv: refOf(bJ, `${tag('B_Private')}_Photo`), bShared: refOf(bJ, `${tag('B_Shared')}_Photo`) };
    score('multirelay: photo refs known', Object.values(refs).every(Boolean), JSON.stringify(refs));

    // Cross-relay reading, both directions.
    await convergeAll(['stub'], mediaPresent(`${tag('A_Shared')}_Photo`), BUDGET.mediaBlob, 'multirelay: A\'s shared photo readable by B');
    await convergeAll(['ios', ...(devices.android ? ['android'] : [])], mediaPresent(`${tag('B_Shared')}_Photo`), BUDGET.mediaBlob, 'multirelay: B\'s shared photo readable by A');
    // A's other devices learn that C_A now lives on R_A the way they learn any relay setting: through
    // self-sync, so they get the self-sync budget (the relay list, not the post, is the slow part).
    await convergeAll(readersOfA.filter((n) => n !== 'stub'), hasPost(tag('A_Private')), BUDGET.settings, 'multirelay: A\'s private post on A\'s other devices');

    const storeKeys = { ra: () => mrStoreKeys(RA.store).map((k) => k.key), rc: () => mrStoreKeys(RC.store).map((k) => k.key), rb: () => mrStoreKeys(RB.store).map((k) => k.key) };
    const waitStore = async (name, pred, budget) => {
      const t = Date.now();
      while (Date.now() - t < budget) { if (pred(storeKeys[name]())) return Date.now() - t; await sleep(2000); }
      return -1;
    };
    const record = (step, device, ms, budget) => { PERF.push({ step, device, ms, budget }); return ms >= 0 && ms <= budget; };
    const onStore = async (label, name, pred, budget) => {
      const ms = await waitStore(name, pred, budget);
      const ok = record(`multirelay: ${label}`, name, ms < 0 ? -1 : Date.now() - tPost, budget + (Date.now() - tPost - ms));
      score(`multirelay: ${label} (${ms < 0 ? 'never' : ((Date.now() - tPost) / 1000).toFixed(1) + 's since post'})`, ms >= 0);
      return ok;
    };
    await onStore('A\'s private circle lands on R_A', 'ra', (k) => eventKeys(k, cA).length > 0 && holdsMedia(k, refs.aPriv), MRB.store);
    await onStore('B\'s private circle lands on R_B', 'rb', (k) => eventKeys(k, cB).length > 0 && holdsMedia(k, refs.bPriv), MRB.store);
    await onStore('shared circle lands on R_A', 'ra', (k) => eventKeys(k, cS).length > 0 && holdsMedia(k, refs.aShared) && holdsMedia(k, refs.bShared), MRB.store);
    await onStore('shared circle lands on R_C', 'rc', (k) => eventKeys(k, cS).length > 0 && holdsMedia(k, refs.aShared) && holdsMedia(k, refs.bShared), MRB.mesh);
    await onStore('shared circle lands on R_B', 'rb', (k) => eventKeys(k, cS).length > 0 && holdsMedia(k, refs.aShared), MRB.meshHost);
    const keysNow = { ra: storeKeys.ra(), rc: storeKeys.rc(), rb: storeKeys.rb() };
    const misplaced = misplacedCircles(keysNow, { ra: [cB], rc: [cA, cB] });
    score('multirelay: no circle\'s mailbox on a relay nobody configured for it', misplaced.length === 0,
      misplaced.length ? JSON.stringify(misplaced) : `R_A circles=${[...mailboxCircles(keysNow.ra)].length} R_C=${[...mailboxCircles(keysNow.rc)].length}`);
    // Media scope (docs/RELAY-AND-DEPLOY.md ▸ Media scope): uploaders scope each ref to its circle,
    // so neither a client's upload nor mesh replication may put a private circle's media — blob,
    // windows or scope marker — on a FRIEND's relay: B's private photo on A's R_A, A's on B's R_B or
    // R_C. (B's private photo MAY sit on R_C: B operates it and B's relay link authorizes every one of
    // B's circles, so R_C serves C_B even though B's client only adopted it for C_S.) Checked here,
    // after the shared circle has meshed onto every relay (mesh passes HAVE run), and again after the
    // mesh section below.
    const mediaMisplaced = (k) => [
      ...(refs.bPriv && holdsMedia(k.ra, refs.bPriv) ? ['B private photo on R_A'] : []),
      ...(refs.aPriv && holdsMedia(k.rc, refs.aPriv) ? ['A private photo on R_C'] : []),
      ...(refs.aPriv && holdsMedia(k.rb, refs.aPriv) ? ['A private photo on R_B'] : []),
    ];
    const mediaMis = mediaMisplaced(keysNow);
    score('multirelay: no private circle\'s media on a friend\'s relay that doesn\'t serve it', mediaMis.length === 0,
      mediaMis.length ? mediaMis.join('; ') : 'B\'s private photo not on R_A; A\'s on neither R_B nor R_C');

    // Every client's relay list carries every relay it knows, each with ITS OWN token + URLs.
    const truth = {
      [RA.node]: { tokenFp: tokenFingerprint(RA.token), ports: [plan.ra.pub, plan.ra2.pub, plan.ra.internal, plan.ra2.internal] },
      [RC.node]: { tokenFp: tokenFingerprint(RC.token), ports: [plan.rc.pub, plan.rc.internal] },
      [RB.node]: { tokenFp: tokenFingerprint(RB.token), ports: [RB.port] },
    };
    // Desktop publishes no relay_stats (docs/QA.md: Apple + Android), so it is not judged here.
    const lists = await snap(['ios', 'stub', ...(devices.android ? ['android'] : [])]);
    for (const n of Object.keys(lists)) {
      const p = attributionProblems(lists[n]?.relay_stats, truth);
      score(`multirelay: relay list correctly attributed [${n}]`, Array.isArray(lists[n]?.relay_stats) && p.length === 0,
        Array.isArray(lists[n]?.relay_stats) ? (p.join('; ') || `${lists[n].relay_stats.length} relay(s)`) : 'no relay_stats in the dump');
    }
    score('multirelay: A\'s list holds BOTH its own relay and B\'s (the announce overwrote nothing)',
      !!statsRow(lists.ios, RA.node) && !!statsRow(lists.ios, RB.node) && !!statsRow(lists.ios, RC.node),
      (lists.ios?.relay_stats || []).map((r) => `${r.relay.slice(0, 8)}:${r.urls?.map(urlPort)}`).join(' '));
    score('multirelay: B\'s list holds R_A, R_B and R_C',
      !!statsRow(lists.stub, RA.node) && !!statsRow(lists.stub, RC.node) && !!statsRow(lists.stub, RB.node));

    // Relay-first: B read A's media from a relay A uses, nothing streamed peer to peer.
    const after = await snap(['ios', ...readersOfA]);
    const d = (n, k) => delta(rf(before[n]), rf(after[n]), k);
    const readDelta = (n, hex) => statsCounter(after[n], hex, 'getOk') - statsCounter(before[n], hex, 'getOk');
    score('multirelay: B fetched A\'s content from A\'s relays (R_A / R_C getOk grew)',
      readDelta('stub', RA.node) + readDelta('stub', RC.node) > 0,
      `R_A Δ${readDelta('stub', RA.node)} R_C Δ${readDelta('stub', RC.node)} R_B Δ${readDelta('stub', RB.node)}`);
    score('multirelay: A fetched B\'s content from B\'s relays (R_B / R_C getOk grew)',
      readDelta('ios', RB.node) + readDelta('ios', RC.node) > 0 || d('ios', 'received_via_relay') > 0,
      `R_B Δ${readDelta('ios', RB.node)} R_C Δ${readDelta('ios', RC.node)} R_A Δ${readDelta('ios', RA.node)} via_relay Δ${d('ios', 'received_via_relay')}`);
    score('multirelay: B received relay-first, never a direct stream', d('stub', 'received_via_relay') > 0 && d('stub', 'received_via_direct') === 0,
      `via_relay Δ${d('stub', 'received_via_relay')} via_direct Δ${d('stub', 'received_via_direct')}`);
    for (const n of ['ios', 'stub', ...(devices.android ? ['android'] : [])]) {
      score(`multirelay: ${n} streamed nothing directly to a friend`, d(n, 'served_direct_friend_bytes') === 0,
        `served_direct_friend_bytes Δ${d(n, 'served_direct_friend_bytes')}`);
    }
    score('multirelay: A\'s writes went to A\'s relay (putOk on R_A grew)', statsCounter(after.ios, RA.node, 'putOk') > statsCounter(before.ios, RA.node, 'putOk'));

    // ── 5. enrollment isolation ────────────────────────────────────────────────────────────────
    const stranger = strangerIdentity();
    const probe = async (port, method, key, auth) => {
      const path = method === 'LIST' ? `/l/${key}` : `/k/${key}`;
      try {
        const r = await fetch(`http://127.0.0.1:${port}${path}`, { method: method === 'LIST' ? 'GET' : method, headers: auth ? { Authorization: auth } : {},
          signal: AbortSignal.timeout(10_000) });
        return r.status;
      } catch (e) { return `ERR ${e.cause?.code || e.message}`; }
    };
    for (const [name, port, token] of [['R_A', plan.ra.pub, RA.token], ['R_B', RB.port, RB.token], ['R_C', plan.rc.pub, RC.token]]) {
      const listKey = `haven/mailbox/${cS}/`, mediaKey = `haven/media/${refs.aShared}`, putKey = `haven/mailbox/${cS}/qa-stranger-${RUN_NONCE}`;
      const results = [
        { name: 'unsigned GET', status: await probe(port, 'GET', mediaKey, null), expect: [401] },
        { name: 'wrong-token GET', status: await probe(port, 'GET', mediaKey, strangerAuth(stranger, 'not-the-token', 'GET', mediaKey)), expect: [401] },
        { name: 'stranger LIST', status: await probe(port, 'LIST', listKey, strangerAuth(stranger, token, 'GET', listKey)), expect: [403] },
        { name: 'stranger GET media', status: await probe(port, 'GET', mediaKey, strangerAuth(stranger, token, 'GET', mediaKey)), expect: [403] },
        { name: 'stranger PUT', status: await probe(port, 'PUT', putKey, strangerAuth(stranger, token, 'PUT', putKey)), expect: [403] },
      ];
      const v = isolationVerdict(results);
      score(`multirelay: a non-member gets 401/403 on ${name}`, v.ok, v.ok ? results.map((r) => `${r.name}=${r.status}`).join(' ') : v.bad.join('; '));
    }
    score('multirelay: nothing the stranger PUT reached any store',
      ![...storeKeys.ra(), ...storeKeys.rc(), ...storeKeys.rb()].some((k) => k.includes('qa-stranger-')));
    const devProbe = async (dev, relay, method, key, body = '') => {
      await op(dev, { op: 'relay_probe', relay, method, key, body }, 1000);
      let st = 0;
      await converge(dev, (j) => j.relay_probe?.key === key && j.relay_probe?.method === method && !j.relay_probe?.pending && (st = j.relay_probe.status) !== 0, 30_000);
      return st;
    };
    const ownKey = `haven/self/${A}/qa/probe-${RUN_NONCE}`;
    const own = await devProbe(ios, RA.node, 'PUT', ownKey, 'qa');
    score('multirelay: control — A may write its OWN self-sync lane on its relay', own === 200, `PUT ${ownKey.slice(0, 40)}… → ${own}`);
    const intoB = await devProbe(ios, RB.node, 'PUT', `haven/self/${B}/qa/probe-${RUN_NONCE}`, 'qa');
    score('multirelay: A cannot write into B\'s self-sync lane on B\'s relay', intoB === 403, `→ ${intoB}`);
    const listB = await devProbe(ios, RB.node, 'LIST', `haven/self/${B}/`);
    score('multirelay: A cannot enumerate B\'s self-sync lane on B\'s relay', listB === 403, `→ ${listB}`);

    // Removing a member revokes their access on the relay that serves that circle.
    const revokeProbe = async () => devProbe(stub, RA.node, 'LIST', `haven/mailbox/${cR}/`);
    let pre = 0;
    const tE = Date.now();
    while (Date.now() - tE < MRB.enroll && (pre = await revokeProbe()) !== 200) await sleep(3000);
    score('multirelay: B was enrolled on R_A for C_R before the removal', pre === 200, `LIST → ${pre}`);
    if (pre === 200) {
      await op(ios, { op: 'remove_member', circle_id: cR, dm_to: B }, 2000);
      const tRm = Date.now();
      let post = 0;
      while (Date.now() - tRm < MRB.revoke && (post = await revokeProbe()) !== 403) await sleep(5000);
      const ms = post === 403 ? Date.now() - tRm : -1;
      PERF.push({ step: 'multirelay: removal revokes relay access', device: 'ra', ms, budget: MRB.revoke });
      score('multirelay: removing B from C_R revokes B\'s access to C_R on R_A', post === 403,
        `B's LIST of C_R on R_A ${(MRB.revoke / 1000)}s after the removal → ${post}`);
    }

    // ── 6. mesh coordination ───────────────────────────────────────────────────────────────────
    // Sentinels under a circle no client uses: a FRESH one proves R_A pulls from R_C at all; a
    // STALE one (idle past the TTL on R_C) must never be pulled — that would be a resurrection.
    // Under C_S — the circle both relays serve. (A key under a circle neither serves is correctly
    // never replicated at all, so it could not prove anything about the mesh.)
    const sentinelCircle = cS;
    const sFresh = `haven/mailbox/${sentinelCircle}/${'f'.repeat(56)}${String(RUN_NONCE).slice(-8).padStart(8, '0')}`;
    const sStale = `haven/mailbox/${sentinelCircle}/${'0'.repeat(56)}${String(RUN_NONCE).slice(-8).padStart(8, '0')}`;
    for (const k of [sFresh, sStale]) {
      const p = join(RC.store, ...k.split('/'));
      mkdirSync(dirname(p), { recursive: true });
      writeFileSync(p, 'qa-sentinel');
    }
    const old = new Date(Date.now() - 31 * 24 * 3600 * 1000);
    utimesSync(join(RC.store, ...sStale.split('/')), old, old);
    const meshMs = await waitStore('ra', (k) => k.includes(sFresh), MRB.meshHost);
    gate('multirelay: mesh — R_A pulls a fresh key from its sibling R_C (siblings taught by a member)', 'ra', meshMs, MRB.meshHost);
    score('multirelay: mesh — an expired key on R_C is never pulled into R_A', !storeKeys.ra().includes(sStale),
      meshMs >= 0 ? 'one full mesh cycle ran (the fresh sentinel crossed)' : 'mesh never ran — this proves nothing');
    // Shared circle: R_A and R_C converge on the same event set (dual-write or mesh), no duplicates.
    // The stale sentinel is SUPPOSED to exist on R_C only (that is the check above), so it is not a
    // convergence miss.
    const liveEvents = (keys) => eventKeys(keys, cS).filter((k) => k !== sStale);
    const meshed = await waitStore('rc', (k) => keyDiff(liveEvents(storeKeys.ra()), liveEvents(k)).onlyA.length === 0
      && keyDiff(liveEvents(storeKeys.ra()), liveEvents(k)).onlyB.length === 0, MRB.mesh);
    const diff = keyDiff(liveEvents(storeKeys.ra()), liveEvents(storeKeys.rc()));
    gate('multirelay: mesh — R_A and R_C hold the same C_S events', 'rc', meshed, MRB.mesh);
    if (meshed < 0) log(`multirelay: C_S only on R_A ${diff.onlyA.length}, only on R_C ${diff.onlyB.length}`);
    {
      const later = mediaMisplaced({ ra: storeKeys.ra(), rc: storeKeys.rc(), rb: storeKeys.rb() });
      score('multirelay: still no private circle\'s media on a friend\'s relay (after the mesh checks)',
        later.length === 0, later.join('; '));
    }
    // LIST counts hold still over a quiet window (a re-seal that mints new keys would grow them).
    // A relay may still be catching up (a key its sibling already had arrives late) — that is mesh
    // convergence. What must never happen is a key that existed on NO relay when the window opened:
    // an envelope minted again with nothing posted (the re-seal regrowth this guards against).
    const counts = { ra: [], rc: [], rb: [] };
    const startUnion = [...new Set(Object.keys(counts).flatMap((n) => eventKeys(storeKeys[n](), cS)))];
    const minted = new Set();
    for (let i = 0; i < 4; i++) {
      for (const n of Object.keys(counts)) {
        const ev = eventKeys(storeKeys[n](), cS);
        counts[n].push(ev.length);
        for (const k of freshMints(startUnion, ev)) minted.add(`${n}:${k.slice(-12)}`);
      }
      if (i < 3) await sleep(MRB.quiet / 3);
    }
    for (const n of Object.keys(counts)) {
      const v = stableCounts(counts[n]);
      const mine = [...minted].filter((m) => m.startsWith(`${n}:`));
      score(`multirelay: no C_S envelope minted with nothing posted [${n}]`, mine.length === 0,
        `${v.why}${mine.length ? ` — new: ${mine.join(' ')}` : ''}`);
    }
    for (const n of ['ios', ...readersOfA]) {
      const j = await freshDump(devices[n]);
      const dup = [tag('A_Shared'), tag('B_Shared')].filter((b) => (j?.posts || []).filter((p) => p.body === b).length > 1);
      score(`multirelay: no duplicate posts [${n}]`, dup.length === 0, dup.join(','));
    }

    // ── 7. reliability ─────────────────────────────────────────────────────────────────────────
    // (a) B's in-app relay goes offline while A posts: A's post still reaches B (via R_A / R_C),
    //     and R_B backfills once it is back — without a duplicate on B.
    await op(stub, { op: 'host_relay', on: false }, 3000);
    const rbOff = await converge(stub, (j) => j.hosted_relay?.serving === false, 20_000);
    score('multirelay: R_B taken offline (B\'s host toggle)', rbOff >= 0);
    // "Stop hosting" must actually stop: within ~2 s the old port REFUSES connections. An answer
    // (401) is a relay still serving; a hang is a listener nobody accepts on — both are the leak
    // (members' warm iroh blob connections used to keep the Mac host's :8674 alive until the next
    // fabric rebind, `relay_host_stop.rs`).
    let offProbe;
    const tOffProbe = Date.now();
    do {
      offProbe = await probe(RB.port, 'GET', 'haven/media/x', null);
      if (offProbe === 'ERR ECONNREFUSED') break;
      await sleep(250);
    } while (Date.now() - tOffProbe < 2_500);
    score(`multirelay: nothing answers on R_B's port once hosting is off (:${RB.port})`, offProbe === 'ERR ECONNREFUSED',
      `unsigned GET → ${offProbe} after ${((Date.now() - tOffProbe) / 1000).toFixed(1)}s`);
    if (offProbe !== 'ERR ECONNREFUSED') {
      const pid = String(shOk('pgrep', ['-f', 'HavenStub\\.app']) || '').trim().split('\n')[0];
      if (pid) log(`multirelay: stub listeners with hosting OFF:\n${shOk('lsof', ['-nP', '-a', '-p', pid, '-iTCP', '-sTCP:LISTEN']) || '(lsof failed)'}`);
    }
    const offBody = tag('WhileRBOff');
    let tOff = Date.now();
    await op(ios, { op: 'post', body: offBody, circle_id: cS }, 1500);
    gate('multirelay: A\'s post reaches B while B\'s own relay is down', 'stub', await convergeSince(stub, hasPost(offBody), BUDGET.text, tOff), BUDGET.text);
    await op(stub, { op: 'host_relay', on: true }, 3000);
    const rbOn = await converge(stub, (j) => j.hosted_relay?.serving === true && num(j.hosted_relay?.httpPort) > 0, 60_000);
    const rbBack = (await freshDump(stub))?.hosted_relay;
    score('multirelay: R_B back online', rbOn >= 0, JSON.stringify(rbBack));
    // The toggle must not move the relay: members hold its URL, and a relay that comes back on a
    // random port strands every one of them until a re-announce reaches them.
    score(`multirelay: R_B comes back on the same port (:${RB.port})`, num(rbBack?.httpPort) === RB.port,
      `httpPort=${rbBack?.httpPort}`);
    const stubPid = String(shOk('pgrep', ['-f', 'HavenStub\\.app']) || '').trim().split('\n')[0];
    if (stubPid) log(`multirelay: stub listeners after the toggle:\n${shOk('lsof', ['-nP', '-a', '-p', stubPid, '-iTCP', '-sTCP:LISTEN']) || '(lsof failed)'}`);
    const offKeysOnRA = eventKeys(storeKeys.ra(), cS);
    const tBack = Date.now();
    const backfilled = await waitStore('rb', (k) => keyDiff(offKeysOnRA, eventKeys(k, cS)).onlyA.length === 0, MRB.meshHost);
    gate('multirelay: R_B backfilled what it missed while down', 'rb', backfilled < 0 ? -1 : Date.now() - tBack, MRB.meshHost);
    if (backfilled < 0) log(`multirelay: R_B still lacks ${keyDiff(offKeysOnRA, eventKeys(storeKeys.rb(), cS)).onlyA.length} C_S event(s) R_A holds`);
    score('multirelay: no duplicate of the while-down post on B',
      ((await freshDump(stub))?.posts || []).filter((p) => p.body === offBody).length === 1);

    // (b) R_A dies MID-TRANSFER. Its door is throttled so a reader downloading from it is caught in
    //     the act; readers must finish via another relay holding the blob (or after the restart),
    //     with progress that never goes backwards.
    await mrProxy('POST', `/throttle?pub=${plan.ra.pub}&bps=${+(process.env.E2E_MR_THROTTLE_BPS || 65_536)}`);
    const vidBody = tag('Video');
    const vidPath = (() => {
      const out = join(OUT, 'mr-video.mp4');
      // Noisy on purpose (resists the app's re-encode, so the blob stays megabytes), with a box at a
      // run-specific spot so the content ref is this run's own.
      const r = spawnSync('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30',
        '-vf', `noise=alls=70:allf=t,drawbox=x=${RUN_NONCE % 1200}:y=${RUN_NONCE % 640}:w=64:h=64:color=red@1:t=fill`,
        '-t', '8', '-c:v', 'libx264', '-b:v', '6M', '-pix_fmt', 'yuv420p', out], { encoding: 'utf8' });
      return r.status === 0 && existsSync(out) ? out : distinctVideo('mr-video');
    })();
    log(`multirelay: video fixture ${vidPath} (${statSync(vidPath).size} B)`);
    const b0 = await snap(readersOfA);
    await op(ios, { op: 'post', body: vidBody, media: 'video', circle_id: cS, video_path: ios.stage(vidPath, 'qa-mr-video.mp4') }, 3000);
    let vidRefs = [];
    await converge(ios, (j) => (vidRefs = (j.posts || []).find((p) => p.body === vidBody)?.media_refs || []).length > 0, 60_000);
    score('multirelay: video post refs known', vidRefs.length > 0, vidRefs.map((r) => r.slice(0, 10)).join(','));
    let caught = null;
    const tWatch = Date.now();
    while (Date.now() - tWatch < +(process.env.E2E_MR_CATCH_MS || 90_000) && vidRefs.length) {
      const st = await mrProxy('GET', '/stats');
      const f = vidRefs.flatMap((r) => inflightMedia(st, plan.ra.pub, r));
      if (f.length && f.some((x) => x.bytes > 0)) { caught = f; break; }
      await sleep(400);
    }
    const downAt = Date.now();
    await mrStopRelay('ra', 'SIGKILL');
    // Not catching a reader on R_A is not a failure of the product (the blob simply came from a
    // relay that answered first) — it is a SKIP of this sub-check, said so; the kill still happens
    // and everything after it is still asserted.
    score('multirelay: R_A killed while a reader was mid-download from it', true,
      caught ? `${caught.length} in-flight GET(s), ${caught.map((f) => `${f.bytes}B/${(f.ageMs / 1000).toFixed(1)}s`).join(' ')}`
        : `SKIPPED — no reader fetched the video from R_A within ${(+(process.env.E2E_MR_CATCH_MS || 90_000)) / 1000}s (it came from another relay first); R_A killed anyway`);
    await mrProxy('POST', `/throttle?pub=${plan.ra.pub}&bps=0`);
    // Readers finish (any relay), progress monotonic.
    await Promise.all(readersOfA.map(async (n) => {
      const dev = devices[n];
      const rec = {};
      const t = Date.now();
      let got = -1;
      while (Date.now() - t < budgetFor(dev, BUDGET.mediaBlob)) {
        const j = await freshDump(dev);
        const p = (j?.posts || []).find((x) => x.body === vidBody);
        const present = (ref) => { const i = (p?.media_refs || []).indexOf(ref); return i >= 0 && Boolean(p.media_present?.[i]); };
        recordProgress(rec, j, vidRefs, present);
        if (vidRefs.every((r) => rec[r].present)) { got = Date.now() - downAt; break; }
        await sleep(1000);
      }
      gate(`multirelay: video completes after R_A died [${n}]`, n, got, BUDGET.mediaBlob);
      for (const r of vidRefs) {
        const x = rec[r] || { got: [] };
        score(`multirelay: progress never goes backwards across the failover [${n} ${r.slice(0, 10)}]`,
          nonDecreasing(x.got) && !x.gaveUpWhileReceiving, `got=${JSON.stringify(x.got.slice(-10))} lanes=${x.lanes} gaveUpWhileReceiving=${x.gaveUpWhileReceiving}`);
      }
    }));
    score('multirelay: the video is held by a relay that is still up (R_C or R_B)',
      vidRefs.every((r) => holdsMedia(storeKeys.rc(), r) || holdsMedia(storeKeys.rb(), r)));
    void b0;

    // (c) No thundering herd against the dead relay.
    const herdEnd = downAt + MRB.down;
    while (Date.now() < herdEnd) await sleep(1000);
    const upAt = Date.now();
    const st1 = await mrProxy('GET', '/stats');
    const hv = herdVerdict(st1?.ports?.[plan.ra.pub]?.times || [], { downAt, upAt, maxPerMin: MRB.maxDownPerMin });
    PERF.push({ step: 'multirelay: requests/min against the dead relay', device: 'fleet', ms: Math.round(hv.perMin), budget: MRB.maxDownPerMin });
    score('multirelay: requests against the DEAD relay stay bounded and do not climb', hv.ok, hv.why);

    // (d) R_A comes back on a NEW port: clients learn it (self-published interface / re-announce)
    //     and are not left parked in backoff.
    t0 = Date.now();
    mrStartRelay('ra', { ...RA, internal: plan.ra2.internal, pub: plan.ra2.pub });
    const iface2 = await mrWaitInterface(RA.dir, plan.ra2.pub, t0);
    score('multirelay: R_A restarted on a new port with the same identity', iface2?.node === RA.node && iface2?.token === RA.token,
      JSON.stringify(iface2?.urls || []));
    const learn = await Promise.all(['ios', 'stub'].map(async (n) => {
      const ms = await convergeSince(devices[n], (j) => knowsUrlPort(j, RA.node, plan.ra2.pub), MRB.reannounce, t0);
      gate(`multirelay: learns R_A's new port [${n}]`, n, ms, MRB.reannounce);
      return ms;
    }));
    if (learn.some((ms) => ms >= 0)) {
      const tu = Date.now();
      await op(ios, { op: 'post', body: tag('AfterMove'), circle_id: cS }, 1500);
      gate('multirelay: A writes to R_A again at its new address (not parked in backoff)', 'ios', await convergeSince(ios,
        // Counters are summed over the relay's CURRENT urls — so once the new door is among them and
        // none of the old ones is, any putOk here landed at the new door.
        (j) => knowsUrlPort(j, RA.node, plan.ra2.pub) && !knowsUrlPort(j, RA.node, plan.ra.pub)
          && statsRow(j, RA.node)?.backoffRemainingMs === 0 && statsCounter(j, RA.node, 'putOk') > 0,
        BUDGET.text * 2, tu), BUDGET.text * 2);
      const st2 = await mrProxy('GET', '/stats');
      score('multirelay: the fleet is using R_A\'s new door', num(st2?.ports?.[plan.ra2.pub]?.hits) > 0, `hits on :${plan.ra2.pub} = ${st2?.ports?.[plan.ra2.pub]?.hits}`);
      await sleep(30_000);
      const st3 = await mrProxy('GET', '/stats');
      const late = hitsBetween(st3?.ports?.[plan.ra.pub]?.times || [], Date.now() - 30_000, Date.now());
      score('multirelay: the old door is abandoned once the new one is known', late <= 5, `${late} request(s) to :${plan.ra.pub} in the last 30s`);
    }

    // (e) Token rotation on R_C: clients recover the new token.
    await mrStopRelay('rc');
    const newTok = randomBytes(16).toString('hex');
    writeFileSync(join(RC.dir, 'http_token'), newTok);
    t0 = Date.now();
    mrStartRelay('rc', { ...RC, internal: plan.rc.internal, pub: plan.rc.pub });
    const ifaceC2 = await mrWaitInterface(RC.dir, plan.rc.pub, t0);
    score('multirelay: R_C restarted with a rotated token', ifaceC2?.token === newTok);
    for (const n of ['ios', 'stub']) {
      gate(`multirelay: recovers R_C's rotated token [${n}]`, n, await convergeSince(devices[n],
        (j) => statsRow(j, RC.node)?.tokenFp === tokenFingerprint(newTok), MRB.token, t0), MRB.token);
    }
    const rotBody = tag('AfterRotate');
    const rcBefore = eventKeys(storeKeys.rc(), cS).length;
    const tRot = Date.now();
    await op(stub, { op: 'post', body: rotBody, circle_id: cS }, 1500);
    gate('multirelay: B\'s post lands on R_C after the rotation', 'rc', await (async () => {
      const ms = await waitStore('rc', (k) => eventKeys(k, cS).length > rcBefore, MRB.store);
      return ms < 0 ? -1 : Date.now() - tRot;
    })(), MRB.store);
    gate('multirelay: …and reaches A', 'ios', await convergeSince(ios, hasPost(rotBody), BUDGET.text, tRot), BUDGET.text);

    // (f) A REAL sweep on R_C (QA GC clock, DEBUG relay only) deletes idle mailbox keys, and the
    //     sibling's mesh pull does not bring them back.
    await mrStopRelay('rc');
    const ttl = MRB.gcTtl;
    const idleBefore = mrStoreKeys(RC.store).filter((k) => k.key.startsWith('haven/mailbox/') && Date.now() - k.mtimeMs > ttl * 1000 + 5_000).map((k) => k.key);
    t0 = Date.now();
    mrStartRelay('rc', { ...RC, internal: plan.rc.internal, pub: plan.rc.pub,
      env: { HAVEN_RELAY_QA_MAILBOX_TTL_SECS: String(ttl), HAVEN_RELAY_QA_GC_GRACE_SECS: '0', HAVEN_RELAY_QA_GC_INTERVAL_SECS: '5' } });
    await mrWaitInterface(RC.dir, plan.rc.pub, t0);
    // Swept = gone, or re-stamped after the restart by a client's refresh-repair PUT/TOUCH.
    const swept = await (async () => {
      const t = Date.now();
      while (Date.now() - t < 60_000) {
        const have = new Map(mrStoreKeys(RC.store).map((k) => [k.key, k.mtimeMs]));
        if (idleBefore.length && idleBefore.every((k) => !have.has(k) || have.get(k) >= t0)) return Date.now() - t;
        await sleep(2000);
      }
      return -1;
    })();
    score(`multirelay: the QA GC clock sweeps R_C's idle mailbox keys (${idleBefore.length} older than ${ttl}s)`, idleBefore.length > 0 && swept >= 0,
      `swept after ${swept} ms; stale sentinel gone=${!storeKeys.rc().includes(sStale)}`);
    // For two mesh cycles in both directions, no swept key may sit on R_C OLDER than the TTL — that
    // can only be a sibling handing back a key it should have treated as expired (the sweep, every
    // 5s, would otherwise have removed it). Fresh re-PUTs by clients are legitimate repair.
    const obs = [];
    const tObs = Date.now();
    while (Date.now() - tObs < 75_000) {
      for (const k of mrStoreKeys(RC.store)) if (idleBefore.includes(k.key)) obs.push({ key: k.key, ageMs: Date.now() - k.mtimeMs });
      await sleep(2500);
    }
    const res = resurrected(obs, { ttlS: ttl });
    score('multirelay: no swept key was resurrected by the sibling\'s mesh pull', res.length === 0,
      `${new Set(obs.map((o) => o.key)).size} swept key(s) seen again (all fresh re-PUTs unless listed): ${res.slice(0, 3).map((o) => `${o.key.slice(-12)}@${(o.ageMs / 1000).toFixed(0)}s`).join(' ')}`);
    log(`multirelay: done — relays ${[...MR.procs.keys()].join(',')} are stopped in teardown`);
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
  if (['post', 'satellite', 'relayfirst', 'progress', 'audience', 'callgate', 'launch', 'responsive', 'multirelay'].some((x) => STEPS.includes(x))) await warmUp();

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

  // LAST on purpose: it makes A's own relay A's default and takes relays down on purpose, which no
  // step written against the single-relay fleet should have to absorb.
  if (STEPS.includes('multirelay')) {
    try { await stepMultiRelay(); }
    catch (e) { score('multirelay: step ran to completion', false, String(e?.stack || e).split('\n').slice(0, 3).join(' | ')); }
    finally { for (const name of [...MR.procs.keys()]) await mrStopRelay(name); mrKillAll(); }
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
    '', '## Dump channel', '',
    '_command issued → freshly written dump (skew-corrected); stale/unreadable are reads that were not_', '',
    '| Leg | Reads | Fresh | Stale | Unreadable | p50 | p95 | max |', '|---|---|---|---|---|---|---|---|',
    ...DUMP_STATS.summary().map((x) => `| ${x.label} | ${x.reads} | ${x.fresh} (${x.prior} prior) | ${x.stale}`
      + ` | ${x.unreadable} | ${fmtDuration(x.p50)} | ${fmtDuration(x.p95)} | ${fmtDuration(x.max)} |`),
    '', `**pass ${pass} / fail ${fail}**`,
  ].join('\n');
  writeFileSync(join(OUT, 'E2E_REPORT.md'), md);
  console.log('\n' + md);
}

function finish() {
  mrKillAll();   // the multirelay step's relays + proxy, by pid (never by name)
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
  process.on('exit', mrKillAll);   // FAIL-FAST / abort / crash: the relays this run started go too
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(sig, () => { releaseRunLock(); process.exit(2); });
  }

  main().catch((e) => { console.error(e); process.exit(1); });
}
