#!/usr/bin/env node
// `soren run Haven apple-unit` — the macOS hosted unit tests (HavenMacUnitTests inside the isolated
// UI-test host) AND the line coverage they reach in apple/HavenApp + apple/Shared.
//
// Why a script rather than Soren's xcodebuild-test runner: the host is a sandboxed app, so Xcode's
// own coverage archive is unreadable to xcodebuild (App Data protection) and `xccov` reports nothing.
// The host instead flushes its in-memory profile (apple/HavenApp/CoverageHook.c, called by the test
// bundle's CoverageFlusher) to /private/tmp/haven-apple-unit-prof/host-<pid>.profraw. That buffer is
// padded past the end of the profile, which llvm-profdata rejects as a second, bad-magic profile — so
// this script truncates it to the length its header describes, merges it, and asks llvm-cov for the
// per-file line counts of the built host binary.
//
// Env: HAVEN_COV_SKIP_RUN=1 re-reads the last profile without running the tests;
//      HAVEN_COV_FILES=1 prints every file; HAVEN_COV_AREA=<substr,substr> prints those files only;
//      HAVEN_UNIT_DD=<dir> overrides the derived-data path; HAVEN_UNIT_ONLY=<-only-testing id> narrows the run.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dev = process.env.DEVELOPER_DIR || '/Applications/Xcode.app/Contents/Developer';
const llvm = `${dev}/Toolchains/XcodeDefault.xctoolchain/usr/bin`;
const profDir = process.env.HAVEN_COVERAGE_DIR || '/private/tmp/haven-apple-unit-prof';
const dd = process.env.HAVEN_UNIT_DD
  || (root.includes('/Documents/') ? '/tmp/soren-dd-haven-apple-unit'
      : `/tmp/soren-dd-haven-apple-unit-wt-${createHash('sha1').update(root).digest('hex').slice(0, 8)}`);
const env = { ...process.env, DEVELOPER_DIR: dev };

let testCode = 0;
if (!process.env.HAVEN_COV_SKIP_RUN) {
  rmSync(profDir, { recursive: true, force: true });
  mkdirSync(profDir, { recursive: true });
  const gen = spawnSync('xcodegen', ['generate'], { cwd: join(root, 'apple'), stdio: 'inherit', env });
  if (gen.status !== 0) process.exit(gen.status ?? 1);
  const only = process.env.HAVEN_UNIT_ONLY ? ['-only-testing:' + process.env.HAVEN_UNIT_ONLY] : [];
  const args = ['test', '-project', 'apple/Haven.xcodeproj', '-scheme', 'HavenMacUnitTests',
    '-destination', 'platform=macOS', 'DEVELOPMENT_TEAM=8ZVSPZYSVF', 'CODE_SIGN_STYLE=Automatic',
    '-derivedDataPath', dd, '-collect-test-diagnostics', 'never', '-enableCodeCoverage', 'YES',
    '-parallel-testing-enabled', 'NO', ...only];
  testCode = spawnSync('xcodebuild', args, { cwd: root, stdio: 'inherit', env }).status ?? 1;
}

// ── the profile: newest host-*.profraw, cut to the length its header describes ───────────────────
const raws = existsSync(profDir)
  ? readdirSync(profDir).filter((f) => f.endsWith('.profraw')).map((f) => join(profDir, f))
      .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)
  : [];
if (!raws.length) { console.error(`apple-unit-cov: no profile in ${profDir} (did the test bundle finish?)`); process.exit(testCode || 2); }
const buf = readFileSync(raws[0]);
const u64 = (i) => Number(buf.readBigUInt64LE(i * 8));
// Raw profile header (version >= 9): 0 magic, 1 version, 2 binaryIds, 3 numData, 4 padBeforeCounters,
// 5 numCounters, 6 padAfterCounters, 7 numBitmapBytes, 8 padAfterBitmap, 9 namesSize, … 13 numVTables, 14 vnamesSize.
if (buf.length < 128 || u64(1) < 9) { console.error('apple-unit-cov: unrecognised profile header'); process.exit(testCode || 2); }
const align8 = (n) => (n + 7) & ~7;
const profLen = 128 + u64(2) + u64(3) * 64 + u64(4) + u64(5) * 8 + u64(6) + u64(7) + u64(8)
  + u64(13) * 24 + align8(u64(9)) + align8(u64(14));
if (profLen > buf.length) { console.error(`apple-unit-cov: profile truncated (${buf.length} < ${profLen})`); process.exit(testCode || 2); }
const work = join(dirname(profDir), 'haven-apple-unit-cov');
mkdirSync(work, { recursive: true });
const trimmed = join(work, 'host.profraw');
writeFileSync(trimmed, buf.subarray(0, profLen));
const profdata = join(work, 'host.profdata');
const merge = spawnSync(`${llvm}/llvm-profdata`, ['merge', '-sparse', trimmed, '-o', profdata], { encoding: 'utf8', env });
if (merge.status !== 0) { console.error(merge.stderr); process.exit(testCode || merge.status || 2); }

const bin = join(dd, 'Build/Products/Debug/HavenUITestHost.app/Contents/MacOS/HavenUITestHost');
if (!existsSync(bin)) { console.error(`apple-unit-cov: missing ${bin}`); process.exit(testCode || 2); }
const exp = spawnSync(`${llvm}/llvm-cov`, ['export', '-summary-only', `-instr-profile=${profdata}`, bin],
  { encoding: 'utf8', env, maxBuffer: 1 << 28 });
if (exp.status !== 0) { console.error(exp.stderr); process.exit(testCode || exp.status || 2); }

const targets = { 'apple/HavenApp': { covered: 0, executable: 0 }, 'apple/Shared': { covered: 0, executable: 0 } };
const files = [];
for (const f of JSON.parse(exp.stdout).data[0].files) {
  const rel = f.filename.includes('/apple/') ? 'apple/' + f.filename.split('/apple/').pop() : f.filename;
  const t = Object.keys(targets).find((k) => rel.startsWith(k + '/'));
  if (!t) continue;
  const { count, covered } = f.summary.lines;
  targets[t].covered += covered; targets[t].executable += count;
  files.push({ name: rel, covered, executable: count });
}
const show = process.env.HAVEN_COV_AREA ? process.env.HAVEN_COV_AREA.split(',') : null;
if (process.env.HAVEN_COV_FILES || show) {
  for (const f of files.filter((x) => !show || show.some((s) => x.name.includes(s)))
    .sort((a, b) => (b.executable - b.covered) - (a.executable - a.covered)))
    console.log(`${String(f.covered).padStart(5)}/${String(f.executable).padEnd(5)} ${(100 * f.covered / (f.executable || 1)).toFixed(1).padStart(5)}%  ${f.name}`);
}
const covered = files.reduce((s, f) => s + f.covered, 0), executable = files.reduce((s, f) => s + f.executable, 0);
console.log(`apple-unit-cov: ${covered}/${executable} lines (${(100 * covered / executable).toFixed(1)}%) hosted`);
console.log(`soren-coverage: ${JSON.stringify({ covered, executable,
  targets: Object.entries(targets).map(([name, v]) => ({ name: `${name} (hosted unit tests)`, ...v })) })}`);

// Per-line coverage for Hopps: it counts each source file once across suites (iOS, iPad, watch, macOS),
// which needs covered/executable line numbers per file like the xcodebuild suites leave in
// ~/.soren/lines/<project>/<suite>.json. Without this file the hosted figure is counted beside the
// union as a second copy of the same sources. Only the main checkout writes it (paths must match the
// other suites'); the headline figure never depends on it.
if (root.includes('/Documents/')) {
  try {
    const lc = spawnSync(`${llvm}/llvm-cov`, ['export', '-format=lcov', `-instr-profile=${profdata}`, bin],
      { encoding: 'utf8', env, maxBuffer: 1 << 30 });
    const ranges = (ns) => { const out = []; for (let i = 0; i < ns.length;) { let j = i; while (j + 1 < ns.length && ns[j + 1] === ns[j] + 1) j++; out.push(i === j ? `${ns[i]}` : `${ns[i]}-${ns[j]}`); i = j + 1; } return out.join(','); };
    const out = { endedAt: new Date().toISOString(), targets: {} };
    for (const rec of lc.stdout.split('end_of_record')) {
      const file = /^SF:(.+)$/m.exec(rec)?.[1];
      if (!file) continue;
      const rel = file.includes('/apple/') ? 'apple/' + file.split('/apple/').pop() : file;
      const t = Object.keys(targets).find((k) => rel.startsWith(k + '/'));
      if (!t) continue;
      const ex = [], cv = [];
      for (const m of rec.matchAll(/^DA:(\d+),(\d+)/gm)) { ex.push(Number(m[1])); if (Number(m[2]) > 0) cv.push(Number(m[1])); }
      if (!ex.length) continue;
      ex.sort((a, b) => a - b); cv.sort((a, b) => a - b);
      let h = ''; try { h = createHash('sha1').update(readFileSync(file)).digest('hex').slice(0, 12); } catch { /* gone */ }
      ((out.targets[`${t} (hosted unit tests)`] ||= { files: {} }).files)[file] = { h, e: ranges(ex), c: ranges(cv) };
    }
    const dest = join(process.env.SOREN_CONFIG_DIR || join(homedir(), '.soren'), 'lines', 'haven', 'apple-unit.json');
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, JSON.stringify(out));
  } catch { /* best effort */ }
}
process.exit(testCode);
