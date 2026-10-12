#!/usr/bin/env node
// Scripts/desktop-cov.mjs — line coverage for the Tauri desktop client's OWN code, printed as
// `soren-coverage:` lines (docs/config.md, "Coverage from cmd suites").
//
//   Rust  desktop/src-tauri/src/*.rs  — `cargo test --lib` built with `-C instrument-coverage`, read by
//         llvm-cov (matching rustc's LLVM) (no cargo-llvm-cov installed). Counted: the crate's own non-test source. NOT
//         counted: the Rust core (its own suites measure it), any other path dependency, the test-only
//         modules (tests_*.rs, covtest_util.rs) and every `#[cfg(test)]` item inside a source file — an
//         inline test module is covered by definition and would inflate the number.
//   JS    desktop/ui/app.js           — node's built-in coverage over desktop/ui/ui.test.mjs and the
//         DOM-stub suites in desktop/ui-test/. strings.js (translation tables), vendor/ and the test
//         files themselves are excluded.
//
// Usage: node Scripts/desktop-cov.mjs [--rust-only|--js-only]
// Heavy (a full instrumented build of the crate): run it through `buildq`.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const crate = join(root, 'desktop/src-tauri');
const srcDir = join(crate, 'src');
const args = new Set(process.argv.slice(2));
const targets = [];
let rustFailed = 0;

const run = (cmd, argv, opts = {}) => {
  const r = spawnSync(cmd, argv, { encoding: 'utf8', maxBuffer: 1 << 29, ...opts });
  if (r.error) throw r.error;
  return r;
};

// ── cfg(test) ranges ─────────────────────────────────────────────────────────────────────────────
/** 1-based inclusive line ranges of every `#[cfg(test)]` item in `src` (module, fn, impl, use…). */
export function cfgTestRanges(src) {
  const lines = src.split('\n');
  const offsets = []; let o = 0;
  for (const l of lines) { offsets.push(o); o += l.length + 1; }
  const lineOf = (off) => { let lo = 0, hi = offsets.length - 1; while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (offsets[mid] <= off) lo = mid; else hi = mid - 1; } return lo + 1; };
  const ranges = [];
  const re = /^[ \t]*#\[cfg\(test\)\]/gm;
  let m;
  while ((m = re.exec(src))) {
    const start = m.index;
    let i = start + m[0].length, depth = 0, end = -1;
    while (i < src.length) {
      const c = src[i], n = src[i + 1];
      if (c === '/' && n === '/') { while (i < src.length && src[i] !== '\n') i++; continue; }
      if (c === '/' && n === '*') { const e = src.indexOf('*/', i + 2); i = e < 0 ? src.length : e + 2; continue; }
      if (c === 'r' && (n === '"' || n === '#')) {                      // raw string r#"…"#
        let j = i + 1, hashes = 0; while (src[j] === '#') { hashes++; j++; }
        if (src[j] === '"') { const close = '"' + '#'.repeat(hashes); const e = src.indexOf(close, j + 1); i = e < 0 ? src.length : e + close.length; continue; }
      }
      if (c === '"') { i++; while (i < src.length && src[i] !== '"') { if (src[i] === '\\') i++; i++; } i++; continue; }
      if (c === "'") {                                                   // char literal vs lifetime
        const m2 = /^'(?:\\.[^']*|[^\\'])'/.exec(src.slice(i, i + 12));
        if (m2) { i += m2[0].length; continue; }
      }
      if (c === '{') depth++;
      else if (c === '}') { depth--; if (depth === 0) { end = i; break; } }
      else if (c === ';' && depth === 0) { end = i; break; }
      i++;
    }
    if (end >= 0) ranges.push([lineOf(start), lineOf(end)]);
  }
  return ranges;
}

// ── Rust ──
/** llvm-profdata / llvm-cov must be new enough for the raw-profile format rustc's LLVM writes (Xcode's
 *  lags it, which fails with "raw profile version mismatch"). Prefer the rustup llvm-tools copy, then
 *  Homebrew's llvm, then Xcode's. */
function llvmTool(name) {
  const sysroot = run('rustc', ['--print', 'sysroot']).stdout.trim();
  const host = /^host: (.+)$/m.exec(run('rustc', ['-vV']).stdout)?.[1];
  const candidates = [
    process.env.LLVM_BIN && join(process.env.LLVM_BIN, name),
    host && join(sysroot, 'lib/rustlib', host, 'bin', name),
    join('/opt/homebrew/opt/llvm/bin', name),
  ].filter(Boolean).filter((p) => existsSync(p));
  return candidates.length ? [candidates[0]] : ['xcrun', name];
}
function rustCoverage() {
  // A skip is only a skip when the tests themselves passed; otherwise the failure wins.
  const bail = (msg) => { console.log(msg); process.exit(rustFailed); };
  const tdir = join(crate, 'target/cov');
  const prof = join(tmpdir(), `haven-desktop-cov-${process.pid}`);
  rmSync(prof, { recursive: true, force: true }); mkdirSync(prof, { recursive: true });
  const env = {
    ...process.env,
    RUSTFLAGS: '-C instrument-coverage',
    CARGO_TARGET_DIR: tdir,
    LLVM_PROFILE_FILE: join(prof, 'cov-%p-%m.profraw'),
    HAVEN_NO_NET: '1',
  };
  const t = run('cargo', ['test', '--lib'], { cwd: crate, env });
  const all = t.stdout + '\n' + t.stderr;
  process.stdout.write(all.split('\n').filter((l) => /^test result|^test .* FAILED|panicked at|^error(\[|:)/.test(l)).join('\n') + '\n');
  // A failing test must not hide the coverage of everything that ran — but it still fails the suite.
  if (t.status !== 0) rustFailed = t.status || 1;
  const bin = /Running unittests .* \((.+haven_desktop_lib-[0-9a-f]+)\)/.exec(all)?.[1];
  const exe = bin ? resolve(crate, bin) : null;
  if (!exe || !existsSync(exe)) { bail('soren-skip: could not locate the instrumented test binary'); }
  const raws = readdirSync(prof).filter((f) => f.endsWith('.profraw')).map((f) => join(prof, f));
  if (!raws.length) { bail('soren-skip: the instrumented run produced no profile data'); }
  const merged = join(prof, 'merged.profdata');
  const [pdBin, ...pdPre] = llvmTool('llvm-profdata');
  const pm = run(pdBin, [...pdPre, 'merge', '-sparse', ...raws, '-o', merged]);
  if (pm.status !== 0) { bail('soren-skip: llvm-profdata failed: ' + pm.stderr.slice(0, 200)); }
  const [cvBin, ...cvPre] = llvmTool('llvm-cov');
  const ex = run(cvBin, [...cvPre, 'export', exe, `-instr-profile=${merged}`, '-format=lcov']);
  if (ex.status !== 0) { bail('soren-skip: llvm-cov failed: ' + ex.stderr.slice(0, 200)); }
  // DESKTOP_COV_LCOV=<path> keeps the raw lcov for digging into which functions are still dark.
  if (process.env.DESKTOP_COV_LCOV) writeFileSync(process.env.DESKTOP_COV_LCOV, ex.stdout);
  const files = new Map();                                              // path -> Map(line -> count)
  let cur = null;
  for (const l of ex.stdout.split('\n')) {
    if (l.startsWith('SF:')) { cur = l.slice(3); if (!files.has(cur)) files.set(cur, new Map()); }
    else if (l.startsWith('DA:') && cur) {
      const [ln, cnt] = l.slice(3).split(',').map(Number);
      const mm = files.get(cur); mm.set(ln, Math.max(mm.get(ln) ?? 0, cnt));
    }
  }
  let covered = 0, executable = 0; const perFile = [];
  for (const [path, lines] of files) {
    if (!path.startsWith(srcDir + '/')) continue;
    const name = path.slice(srcDir.length + 1);
    if (/^tests_.*\.rs$/.test(name) || name === 'covtest_util.rs') continue;
    const skip = cfgTestRanges(readFileSync(path, 'utf8'));
    let c = 0, e = 0;
    for (const [ln, cnt] of lines) {
      if (skip.some(([a, b]) => ln >= a && ln <= b)) continue;
      e++; if (cnt > 0) c++;
    }
    covered += c; executable += e; perFile.push([name, c, e]);
  }
  for (const [n, c, e] of perFile.sort((a, b) => (b[2] - b[1]) - (a[2] - a[1])).slice(0, 15)) console.log(`  ${n.padEnd(22)} ${c}/${e}  ${(100 * c / Math.max(e, 1)).toFixed(1)}%`);
  rmSync(prof, { recursive: true, force: true });
  targets.push({ name: 'desktop-rust', covered, executable });
}

// ── JS ───────────────────────────────────────────────────────────────────────────────────────────
function jsCoverage() {
  const out = join(tmpdir(), `haven-desktop-ui-${process.pid}.lcov`);
  const tests = ['desktop/ui/ui.test.mjs', ...readdirSync(join(root, 'desktop/ui-test')).filter((f) => f.endsWith('.test.mjs')).map((f) => 'desktop/ui-test/' + f)];
  const r = run('node', ['--test', '--experimental-test-coverage', '--test-reporter=lcov', `--test-reporter-destination=${out}`, '--test-reporter=spec', '--test-reporter-destination=stdout', ...tests], { cwd: root });
  const tail = r.stdout.split('\n').filter((l) => /^ℹ (tests|pass|fail)/.test(l)).join('\n');
  if (tail) console.log(tail);
  if (r.status !== 0) { console.log((r.stdout + r.stderr).split('\n').slice(-60).join('\n')); process.exit(r.status || 1); }
  const lcov = readFileSync(out, 'utf8'); rmSync(out, { force: true });
  // node reports a line as executable when it falls inside a function range, comments and blanks
  // included — which flatters the number. Count only lines that hold code.
  const appPath = join(root, 'desktop/ui/app.js');
  const src = readFileSync(appPath, 'utf8').split('\n');
  const isCode = (n) => { const t = (src[n - 1] ?? '').trim(); return t !== '' && !t.startsWith('//') && !t.startsWith('/*') && !t.startsWith('*') && !t.startsWith('*/'); };
  let sf = null, lf = 0, lh = 0;
  for (const l of lcov.split('\n')) {
    if (l.startsWith('SF:')) sf = l.slice(3);
    else if (l.startsWith('DA:') && sf && sf.endsWith('desktop/ui/app.js')) {
      const [ln, cnt] = l.slice(3).split(',').map(Number);
      if (!isCode(ln)) continue;
      lf++; if (cnt > 0) lh++;
    }
  }
  targets.push({ name: 'desktop-appjs', covered: lh, executable: lf });
}

function main() {
  if (!args.has('--js-only')) rustCoverage();
  if (!args.has('--rust-only')) jsCoverage();
  const covered = targets.reduce((a, t) => a + t.covered, 0), executable = targets.reduce((a, t) => a + t.executable, 0);
  for (const t of targets) console.log(`${t.name}: ${t.covered}/${t.executable} lines (${(100 * t.covered / Math.max(t.executable, 1)).toFixed(1)}%)`);
  console.log('soren-coverage: ' + JSON.stringify({ covered, executable, targets }));
  if (rustFailed) process.exit(rustFailed);
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
