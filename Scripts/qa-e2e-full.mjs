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
//   profile, circle_create, circle_invite, file, music_post, dump, mark_read.
import { execFileSync, spawnSync, spawn } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync, mkdirSync, appendFileSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = process.env.QA_OUT || join(ROOT, 'build', `e2e-${stamp()}`);
mkdirSync(OUT, { recursive: true });
const MARKER = `E2E_${stamp().replace(/-/g, '').slice(-6)}`;
const RUN_NONCE = Date.now();   // per-run fixture salt — see the satellite lane
const REPORT = [];
const PERF = [];
const HISTORY = join(ROOT, 'build', 'e2e-history.jsonl');
const STEPS = (process.env.E2E_STEPS || 'profile,circle,post,story,file,music,dm,call,react,comment,media,satellite,invite_offline').split(',');

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
};

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
    dump: () => readJson(join(dir(), 'qa-dump.json')),
    stage: (src, name) => { const p = join(dir(), name); writeFileSync(p, readFileSync(src)); return p; },
  };
}

function makeAndroid() {
  // Every adb interaction is best-effort: an emulator hiccup (sdcard I/O errors,
  // adb restarts) must degrade this leg to RED checks, never crash the whole run.
  const dev = '/sdcard/Download';
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
    },
    poke: () => guarded(['shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', 'haven://qa']),
    dump: () => {
      const tmp = join(OUT, 'and-dump.json');
      if (guarded(['pull', `${dev}/qa-dump-${AND_PKG}.json`, tmp]) === null) return null;
      return readJson(tmp);
    },
    stage: (src, name) => { guarded(['push', src, `${dev}/${name}`]); return `${dev}/${name}`; },
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
    dump: () => readJson(join(as, 'qa-dump.json')),
    stage: (src, name) => { const p = join(as, name); writeFileSync(p, readFileSync(src)); return p; },
  };
}

function makeDesktop() {
  return {
    label: 'desktop',
    qaWrite: (cmd) => writeFileSync(join(DESK_DATA, 'qa-cmd.json'), JSON.stringify(cmd)),
    poke: () => {},                       // desktop watches the file
    dump: () => readJson(join(DESK_DATA, 'qa-dump.json')),
    stage: (src, name) => { const p = join(DESK_DATA, name); writeFileSync(p, readFileSync(src)); return p; },
  };
}

function readJson(p) { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; } }

// ── driver ops ──────────────────────────────────────────────────────────────

async function op(dev, cmd, settleMs = 4000) {
  dev.qaWrite(cmd); dev.poke(); await sleep(settleMs);
}

async function freshDump(dev) {
  await op(dev, { op: 'dump' }, 2500);
  return dev.dump();
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
    encoding: 'utf8', env: { ...process.env, QA_OUT: OUT }, stdio: 'inherit',
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
  if (shOk('adb', ['get-state'])?.trim() === 'device') devices.android = makeAndroid();
  else log('WARN: no android device — android leg SKIPPED (still reported)');

  const fleet = ['ios', 'desktop', ...(devices.android ? ['android'] : [])]; // account A
  const all = [...fleet, 'stub'];                                            // + account B

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

  // 1. profile edit propagates across account A devices
  if (STEPS.includes('profile')) {
    const nick = `${MARKER}_Nick`;
    await op(devices.ios, { op: 'profile', name: nick });
    await convergeAll(fleet.filter((x) => x !== 'ios'), (j) => j.profile?.name === nick, BUDGET.settings, 'profile edit');
  }

  // 2. circle create + invite friend B
  let circleId = null;
  if (STEPS.includes('circle')) {
    const cname = `${MARKER}_Circle`;
    await op(devices.ios, { op: 'circle_create', name: cname });
    const mine = await freshDump(devices.ios);
    circleId = mine?.circles?.find((c) => c.name === cname)?.id;
    score('circle created on iOS', !!circleId);
    if (circleId && B) {
      await op(devices.ios, { op: 'circle_invite', circle_id: circleId, dm_to: B });
      // The invite handshake spans two poll legs (A's fan-out tick → relay → B's poll
      // + claim + reply), so give it two active-cadence polls, not one.
      perfGate('circle membership', 'stub', await converge(devices.stub,
        (j) => j.circles?.some((c) => c.name === cname), BUDGET.text * 2));
      await convergeAll(fleet.filter((x) => x !== 'ios'), (j) => j.circles?.some((c) => c.name === cname), BUDGET.settings, 'circle (own devices)');
    }
  }

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
  if (STEPS.includes('post') || STEPS.includes('satellite')) await warmUp();

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
            const ms = await converge(devices.android, (j) => j.call?.audio_route === target, 20_000);
            score(`${label}: speaker ${what} [${tag}]`, ms >= 0,
              ms >= 0 ? `${(ms / 1000).toFixed(1)}s`
                      : JSON.stringify((await freshDump(devices.android))?.call || {}));
          }
        };
        const live = (await freshDump(devices.android))?.call || {};
        score(`speaker defaults to the loudspeaker [${tag}]`,
          live.speaker_on === true && live.audio_route === 'speaker', JSON.stringify(live));
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
    spawnSync('pkill', ['-x', 'HavenStub']); spawnSync('pkill', ['-f', 'target/debug/haven-desktop']);
  }
  process.exit(fail === 0 && !regression ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
