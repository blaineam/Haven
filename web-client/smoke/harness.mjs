// Shared plumbing for the browser smokes: a static server for web-client/, a native peer process
// whose stdout lines can be awaited, and a Playwright Chromium.
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
// Playwright is a dev tool, not a dependency of this repo: resolve it from NODE_PATH or a global
// install (`playwright`, or `playwright-core` with its browser already downloaded).
let chromium;
for (const name of ["playwright", "playwright-core"]) {
  try {
    ({ chromium } = require(name));
    break;
  } catch {}
}
if (!chromium) {
  console.error("playwright not found — install it or point NODE_PATH at a node_modules that has it");
  process.exit(2);
}

/** The web-client/ directory (the bundle a relay serves, after build.sh). */
export const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm" };

/** Serve web-client/ on a loopback port; `/` is the smoke page. Returns `{ url, close }`. */
export async function serve() {
  const server = createServer(async (req, res) => {
    const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname));
    const file = path === "/" ? "/smoke/index.html" : path;
    try {
      const body = await readFile(join(root, file));
      res.writeHead(200, { "content-type": TYPES[file.slice(file.lastIndexOf("."))] ?? "application/octet-stream" });
      res.end(body);
    } catch {
      res.writeHead(404).end();
    }
  });
  await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
  return { url: `http://127.0.0.1:${server.address().port}/`, close: () => server.close() };
}

/** Start a native peer binary. `line(prefix)` resolves with the rest of the first stdout line that
 *  starts with `prefix` (already printed or yet to come); `lines` is everything printed so far. */
export function startPeer(bin, args = ["127.0.0.1:0"]) {
  const proc = spawn(bin, args, { stdio: ["pipe", "pipe", "inherit"] });
  const lines = [];
  const waiters = [];
  let buf = "";
  proc.stdout.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      lines.push(buf.slice(0, i));
      buf = buf.slice(i + 1);
      for (const w of [...waiters]) w();
    }
  });
  function line(prefix, ms = 30000) {
    return new Promise((ok, fail) => {
      const timer = setTimeout(() => fail(new Error(`native peer never printed ${prefix} (saw: ${lines.join(" | ")})`)), ms);
      const check = () => {
        const hit = lines.find((l) => l.startsWith(prefix));
        if (hit) {
          clearTimeout(timer);
          waiters.splice(waiters.indexOf(check), 1);
          ok(hit.slice(prefix.length));
        }
      };
      waiters.push(check);
      check();
    });
  }
  return { proc, lines, line, write: (s) => proc.stdin.write(s), kill: () => proc.kill() };
}

/** Open the smoke page in headless Chromium, with the wasm module loaded as `window.haven`. */
export async function openPage(url) {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  page.on("console", (m) => console.log(`   [page ${m.type()}] ${m.text()}`));
  page.on("pageerror", (e) => console.log(`   [page error] ${e.message}`));
  if (process.env.SMOKE_HTTP) {
    // Every relay request the page makes, with its outcome (for diagnosing a smoke).
    page.on("response", (r) => {
      const u = new URL(r.url());
      if (/^\/(k|l|t)\//.test(u.pathname)) console.log(`   [page http] ${r.request().method()} ${u.pathname.slice(0, 90)} -> ${r.status()}`);
    });
    page.on("requestfailed", (r) => console.log(`   [page http] ${r.method()} ${r.url().slice(0, 110)} FAILED ${r.failure()?.errorText}`));
  }
  await page.goto(url);
  await page.waitForFunction(() => window.havenReady === true, null, { timeout: 30000 });
  return { browser, page };
}

/** Run a smoke body; print PASS/FAIL, clean up, and exit with the right code. */
export async function run(usage, body, { peerArgs } = {}) {
  const bin = process.argv[2];
  if (!bin) {
    console.error(`usage: ${usage}`);
    process.exit(2);
  }
  const site = await serve();
  const peer = startPeer(bin, peerArgs);
  const cleanup = [];
  let failed = false;
  try {
    await body({ site, peer, step: (name) => console.log(`ok  ${name}`), onExit: (f) => cleanup.push(f) });
    if (process.env.SMOKE_DEBUG) console.log(peer.lines.filter((l) => !l.startsWith("TICKET=")).join("\n"));
    console.log("PASS");
  } catch (e) {
    failed = true;
    console.error(`FAIL ${e.message}`);
  } finally {
    for (const f of cleanup) await f();
    peer.kill();
    site.close();
  }
  process.exit(failed ? 1 : 0);
}
