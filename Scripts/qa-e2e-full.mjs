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
const REPORT = [];
const PERF = [];
const HISTORY = join(ROOT, 'build', 'e2e-history.jsonl');
const STEPS = (process.env.E2E_STEPS || 'profile,circle,post,story,file,music,dm,react,comment,media').split(',');

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
function score(name, ok, detail = '') {
  REPORT.push({ name, ok, detail });
  log(`${ok ? 'GREEN' : 'RED  '} ${name}${detail ? ` — ${detail}` : ''}`);
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

function iosContainer(udid) {
  return sh('xcrun', ['simctl', 'get_app_container', udid, IOS_BUNDLE, 'data']).trim();
}

function makeIos(udid) {
  const as = join(iosContainer(udid), 'Library/Application Support');
  return {
    label: 'ios',
    qaWrite: (cmd) => writeFileSync(join(as, 'qa-cmd.json'), JSON.stringify(cmd)),
    poke: () => shOk('xcrun', ['simctl', 'openurl', udid, 'haven://qa?x=1']),
    dump: () => readJson(join(as, 'qa-dump.json')),
    stage: (src, name) => { const p = join(as, name); writeFileSync(p, readFileSync(src)); return p; },
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
async function converge(dev, predicate, budgetMs, pollMs = 3000) {
  lastBudget = budgetMs;
  const t0 = Date.now();
  while (Date.now() - t0 < budgetMs) {
    const d = await freshDump(dev);
    if (d && predicate(d)) return Date.now() - t0;
    await sleep(pollMs);
  }
  return -1;
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

  const stubDump = await freshDump(devices.stub);
  const stubHexPath = join(process.env.HOME, 'Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/qa-account-hex.txt');
  const B = stubDump?.account_hex || process.env.HAVEN_STUB_ACCOUNT
    || (existsSync(stubHexPath) ? readFileSync(stubHexPath, 'utf8').trim() : '');

  // 1. profile edit propagates across account A devices
  if (STEPS.includes('profile')) {
    const nick = `${MARKER}_Nick`;
    await op(devices.ios, { op: 'profile', name: nick });
    for (const d of fleet.filter((x) => x !== 'ios'))
      perfGate('profile edit', d, await converge(devices[d], (j) => j.profile?.name === nick, BUDGET.settings));
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
      for (const d of fleet.filter((x) => x !== 'ios'))
        perfGate('circle (own devices)', d, await converge(devices[d],
          (j) => j.circles?.some((c) => c.name === cname), BUDGET.settings));
    }
  }

  // Content authored into the SHARED circle reaches B (stub); content in A's
  // default circle only ever reaches A's own devices. Every shared-content op
  // carries circle_id; when the circle step was skipped there is no shared
  // circle, so stub expectations are skipped (and honestly reported as such).
  const audienceFor = (shared) => (shared && circleId && B) ? all : fleet;
  const cid = () => circleId || undefined;

  // 3. posts: text + photo + video (author iOS; friend authors one from stub)
  if (STEPS.includes('post')) {
    await op(devices.ios, { op: 'post', body: `${MARKER}_Text`, circle_id: cid() });
    for (const d of audienceFor(true).filter((x) => x !== 'ios'))
      perfGate('text post', d, await converge(devices[d],
        (j) => j.posts?.some((p) => p.body === `${MARKER}_Text`), BUDGET.text));

    const photoPath = devices.ios.stage(PHOTO, 'qa-photo.jpg');
    await op(devices.ios, { op: 'post', body: `${MARKER}_Photo`, media: 'photo', photo_path: photoPath, circle_id: cid() });
    for (const d of audienceFor(true).filter((x) => x !== 'ios')) {
      perfGate('photo post event', d, await converge(devices[d],
        (j) => j.posts?.some((p) => p.body === `${MARKER}_Photo`), BUDGET.mediaEvent));
      if (STEPS.includes('media'))
        perfGate('photo blob present', d, await converge(devices[d],
          (j) => j.posts?.some((p) => p.body === `${MARKER}_Photo` && p.media_present?.length && p.media_present.every(Boolean)), BUDGET.mediaBlob));
    }

    const videoPath = devices.ios.stage(VIDEO, 'qa-clip.mp4');
    await op(devices.ios, { op: 'post', body: `${MARKER}_Video`, media: 'video', video_path: videoPath, circle_id: cid() }, 12_000);
    for (const d of audienceFor(true).filter((x) => x !== 'ios')) {
      perfGate('video post event', d, await converge(devices[d],
        (j) => j.posts?.some((p) => p.body === `${MARKER}_Video`), BUDGET.mediaEvent));
      if (STEPS.includes('media'))
        perfGate('video blob present', d, await converge(devices[d],
          (j) => j.posts?.some((p) => p.body === `${MARKER}_Video` && p.media_present?.length && p.media_present.every(Boolean)), BUDGET.mediaBlob));
    }

    // friend's post into the shared circle reaches all of A
    if (circleId && B) {
      await op(devices.stub, { op: 'post', body: `${MARKER}_FromB`, circle_id: cid() });
      for (const d of fleet)
        perfGate('friend post', d, await converge(devices[d],
          (j) => j.posts?.some((p) => p.body === `${MARKER}_FromB`), BUDGET.text));
    } else {
      score('friend post (needs shared circle)', false, 'circle step skipped or B unknown');
    }
  }

  // 4. story with caption
  if (STEPS.includes('story')) {
    const p = devices.ios.stage(PHOTO, 'qa-photo.jpg');
    await op(devices.ios, { op: 'story', caption: `${MARKER}_Cap`, media: 'photo', photo_path: p, circle_id: cid() });
    for (const d of audienceFor(true).filter((x) => x !== 'ios'))
      perfGate('story + caption', d, await converge(devices[d],
        (j) => j.posts?.some((x) => x.story && x.caption === `${MARKER}_Cap`), BUDGET.mediaEvent));
  }

  // 5. file post
  if (STEPS.includes('file') && existsSync(PDF)) {
    const p = devices.ios.stage(PDF, 'qa-doc.pdf');
    await op(devices.ios, { op: 'file', body: `${MARKER}_File`, file_path: p, circle_id: cid() });
    for (const d of audienceFor(true).filter((x) => x !== 'ios'))
      perfGate('file post', d, await converge(devices[d],
        (j) => j.posts?.some((x) => x.body === `${MARKER}_File`), BUDGET.mediaEvent));
  }

  // 6. music card
  if (STEPS.includes('music')) {
    await op(devices.ios, { op: 'music_post', body: `${MARKER}_Song`, music: { title: 'QA Song', artist: 'The Fixtures' }, circle_id: cid() });
    for (const d of audienceFor(true).filter((x) => x !== 'ios'))
      perfGate('music post', d, await converge(devices[d],
        (j) => j.posts?.some((x) => x.body === `${MARKER}_Song`), BUDGET.text));
  }

  // 7. DMs both directions (with media one way)
  if (STEPS.includes('dm') && B) {
    await op(devices.ios, { op: 'dm', dm_to: B, body: `${MARKER}_DM_AB` });
    perfGate('dm A→B', 'stub', await converge(devices.stub,
      (j) => Object.values(j.dms || {}).flat().some((m) => m.body === `${MARKER}_DM_AB`), BUDGET.text));
    // own-device echo: the DM thread appears on A's other devices
    for (const d of fleet.filter((x) => x !== 'ios'))
      perfGate('dm echo (own devices)', d, await converge(devices[d],
        (j) => Object.values(j.dms || {}).flat().some((m) => m.body === `${MARKER}_DM_AB`), BUDGET.text * 2));
    const iosDump = await freshDump(devices.ios);
    const A = iosDump?.account_hex || '';
    if (A) {
      await op(devices.stub, { op: 'dm', dm_to: A, body: `${MARKER}_DM_BA` });
      for (const d of fleet)
        perfGate('dm B→A', d, await converge(devices[d],
          (j) => Object.values(j.dms || {}).flat().some((m) => m.body === `${MARKER}_DM_BA`), BUDGET.text * 2));
    }
  }

  // 8-9. reaction + comment from friend and from own second device on the same
  // shared-circle post (interactions only make sense where everyone sees the post).
  if (STEPS.includes('react') || STEPS.includes('comment')) {
    const mine = await freshDump(devices.ios);
    const target = mine?.posts?.find((p) => p.body === `${MARKER}_Text`)?.id;
    score('have target post id for interactions', !!target);
    const reactors = audienceFor(true);
    if (target) {
      if (STEPS.includes('react')) {
        if (reactors.includes('stub')) await op(devices.stub, { op: 'react', target_id: target, emoji: '❤️' });
        await op(devices.desktop, { op: 'react', target_id: target, emoji: '🔥' });
        for (const d of reactors)
          perfGate('reactions converge', d, await converge(devices[d], (j) => {
            const p = j.posts?.find((x) => x.id === target);
            return p && (reactors.includes('stub') ? (p.reactions?.['❤️'] || 0) >= 1 : true)
              && (p.reactions?.['🔥'] || 0) >= 1;
          }, BUDGET.text * 2));
      }
      if (STEPS.includes('comment') && reactors.includes('stub')) {
        await op(devices.stub, { op: 'comment', target_id: target, body: `${MARKER}_CmtB` });
        for (const d of reactors)
          perfGate('comment converges', d, await converge(devices[d], (j) =>
            j.posts?.find((x) => x.id === target)?.comments?.some((c) => c.body === `${MARKER}_CmtB`), BUDGET.text * 2));
      }
    }
  }

  finish();
}

function finish() {
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

  // history + regression check (>2x latency vs last green run of the same step+device)
  let regression = false;
  try {
    const rows = existsSync(HISTORY) ? readFileSync(HISTORY, 'utf8').trim().split('\n').map((l) => JSON.parse(l)) : [];
    const last = rows[rows.length - 1];
    if (last) for (const p of PERF) {
      const prev = last.perf?.find((q) => q.step === p.step && q.device === p.device);
      if (prev && prev.ms > 0 && p.ms > 0 && p.ms > prev.ms * 2 && p.ms - prev.ms > 10_000) {
        log(`PERF REGRESSION ${p.step}→${p.device}: ${(prev.ms / 1000).toFixed(1)}s → ${(p.ms / 1000).toFixed(1)}s`);
        regression = true;
      }
    }
    const git = shOk('git', ['rev-parse', '--short', 'HEAD'], { cwd: ROOT })?.trim();
    appendFileSync(HISTORY, JSON.stringify({ ts: Date.now(), git, marker: MARKER, pass, fail, perf: PERF }) + '\n');
  } catch (e) { log(`history error: ${e.message}`); }

  if (process.env.E2E_KILL === '1') {
    spawnSync('pkill', ['-x', 'HavenStub']); spawnSync('pkill', ['-f', 'target/debug/haven-desktop']);
  }
  process.exit(fail === 0 && !regression ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
