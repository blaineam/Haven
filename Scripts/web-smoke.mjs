#!/usr/bin/env node
// The browser end to end, on this machine: build the web client and the native primary, then run
// web-client/smoke/engine.mjs (linking, posts and media both ways, storage at rest, and what a
// person does with photos, videos, stories and songs) in a real headless browser. What CI runs in
// .github/workflows/web-client.yml; the Soren suite `web-client-browser`.
//
//   node Scripts/web-smoke.mjs                 # Chromium
//   SMOKE_BROWSER=webkit node Scripts/web-smoke.mjs
//
// Needs: wasm-bindgen of the version core/Cargo.lock names (on PATH or in ~/.cargo/bin), a clang
// that targets wasm32 (Homebrew's llvm), and Playwright with its browser (NODE_PATH, a global
// install, or ~/.cache/haven-qa/node_modules). It never downloads anything.
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const browser = process.env.SMOKE_BROWSER || 'chromium';
const fail = (m) => { console.error(`✗ ${m}`); process.exit(1); };
const env = { ...process.env, PATH: `${join(homedir(), '.cargo/bin')}:${process.env.PATH}` };

const want = /name = "wasm-bindgen"\nversion = "([^"]+)"/.exec(readFileSync(join(root, 'core/Cargo.lock'), 'utf8'))?.[1];
const have = spawnSync('wasm-bindgen', ['--version'], { env, encoding: 'utf8' }).stdout?.split(' ')[1]?.trim();
if (have !== want) fail(`wasm-bindgen ${want} is needed (found ${have || 'none'}): cargo install wasm-bindgen-cli --version ${want} --locked`);
const llvm = ['/opt/homebrew/opt/llvm/bin', '/usr/local/opt/llvm/bin'].find((d) => existsSync(join(d, 'clang')));
if (llvm) { env.CC_wasm32_unknown_unknown ||= join(llvm, 'clang'); env.AR_wasm32_unknown_unknown ||= join(llvm, 'llvm-ar'); }

// Playwright is a dev tool, not a dependency of this repo.
const require = createRequire(import.meta.url);
let playwright = null;
const homes = [join(homedir(), '.cache/haven-qa/node_modules'), spawnSync('npm', ['root', '-g'], { encoding: 'utf8' }).stdout?.trim()];
for (const name of ['playwright', 'playwright-core', ...homes.filter(Boolean).map((h) => join(h, 'playwright'))]) {
  try {
    const at = require.resolve(name);
    playwright = require(at);
    // The smoke itself resolves Playwright through NODE_PATH.
    env.NODE_PATH = [env.NODE_PATH, at.slice(0, at.lastIndexOf('node_modules') + 'node_modules'.length)].filter(Boolean).join(':');
    break;
  } catch { /* next */ }
}
if (!playwright) fail('Playwright not found: set NODE_PATH, or put it in ~/.cache/haven-qa/node_modules');
// A Playwright newer than the browsers on this machine: use the newest Chromium already here.
// (WebKit has no such stand-in: its build has to match the Playwright that drives it.)
if (!process.env.SMOKE_EXECUTABLE && !existsSync(playwright[browser].executablePath())) {
  if (browser !== 'chromium') fail(`this Playwright's ${browser} is not installed (playwright install ${browser})`);
  const cache = join(homedir(), 'Library/Caches/ms-playwright');
  const shells = (existsSync(cache) ? readdirSync(cache) : [])
    .filter((d) => /^chromium_headless_shell-\d+$/.test(d))
    .sort((a, b) => Number(b.split('-')[1]) - Number(a.split('-')[1]));
  for (const d of shells) {
    const hit = readdirSync(join(cache, d)).map((p) => join(cache, d, p, 'chrome-headless-shell')).find(existsSync);
    if (hit) { env.SMOKE_EXECUTABLE = hit; break; }
  }
  if (!env.SMOKE_EXECUTABLE) fail('no Chromium for Playwright is installed (playwright install chromium)');
}

const run = (cmd, args, cwd = root) => execFileSync(cmd, args, { cwd, env, stdio: 'inherit' });
run('sh', ['web-client/build.sh']);
run('cargo', ['build', '-q', '-p', 'haven-client', '--features', 'test-util', '--example', 'web_primary_engine'], join(root, 'core'));
// The primary's own log is long; keep the steps and, on failure, the end of everything.
const res = spawnSync('node', ['web-client/smoke/engine.mjs', 'core/target/debug/examples/web_primary_engine'],
  { cwd: root, env, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, timeout: 15 * 60 * 1000 });
const out = `${res.stdout || ''}${res.stderr || ''}`;
const lines = out.split('\n');
console.log(lines.filter((l) => /^(ok |PASS|FAIL)/.test(l)).join('\n'));
if (res.status !== 0) {
  console.error(lines.slice(-80).join('\n'));
  fail(`browser smoke failed (${res.signal || `exit ${res.status}`})`);
}
const passed = lines.filter((l) => l.startsWith('ok ')).length;
console.log(`✓ ${passed} browser steps passed in ${browser}`);
