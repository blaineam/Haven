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
// SMOKE_BROWSER=webkit runs the same smoke in Playwright's WebKit build (Safari's engine), which
// refuses things Chromium lets through. Default: chromium.
const BROWSER = process.env.SMOKE_BROWSER || "chromium";
let chromium;
for (const name of ["playwright", "playwright-core"]) {
  try {
    chromium = require(name)[BROWSER];
    if (chromium) break;
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

/** A plain file server for dist-site/. It is not a relay: no mailbox, no DERP, nothing but files.
 *  `rendezvous` is what the site's operator would have built in with HAVEN_SITE_RENDEZVOUS (empty:
 *  none, so the page meets its primary on the public rendezvous relays); `relay` is the relay the
 *  linked page will go on to use. */
export async function serveSite(rendezvous, relay) {
  const dir = join(root, "dist-site");
  const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".wasm": "application/wasm", ".svg": "image/svg+xml", ".png": "image/png", ".json": "application/json" };
  const server = createServer(async (req, res) => {
    let path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname));
    if (path.endsWith("/")) path += "index.html";
    try {
      let body = await readFile(join(dir, path));
      if (path === "/index.html") {
        let html = body.toString("utf8");
        if (rendezvous) {
          html = html.replace('<meta name="haven-host" content="site" />',
            `<meta name="haven-host" content="site" />\n    <meta name="haven-rendezvous" content="${rendezvous}" />`);
        }
        // The page's content policy lets it connect out over TLS only. A loopback relay is plain
        // http, so the harness (and only the harness) names it; a real page is never widened.
        if (relay.startsWith("http://")) {
          html = html.replace("connect-src 'self' https: wss:", `connect-src 'self' https: wss: ${relay} ${relay.replace(/^http/, "ws")}`);
        }
        body = Buffer.from(html);
      }
      res.writeHead(200, { "content-type": TYPES[path.slice(path.lastIndexOf("."))] ?? "application/octet-stream" });
      res.end(body);
    } catch {
      res.writeHead(404).end();
    }
  });
  await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
  return { url: `http://127.0.0.1:${server.address().port}`, close: () => server.close() };
}

/** Start a native peer binary. `line(prefix)` resolves with the rest of the first stdout line that
 *  starts with `prefix` (already printed or yet to come); `lines` is everything printed so far. */
export function startPeer(bin, args = ["127.0.0.1:0"], env = {}) {
  const proc = spawn(bin, args, { stdio: ["pipe", "pipe", "inherit"], env: { ...process.env, ...env } });
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

/** Playwright's WebKit on macOS sometimes never sends one of a page's requests, so `load` never
 *  fires: 3 of 20 loads of a plain page from a stock Node server, none in Chromium (2026-11-25,
 *  Playwright 1.60, macOS 27.2). Nothing of Haven's is involved, so a stalled navigation is asked
 *  for again. Only a navigation TIMEOUT is retried; every other failure is the test's to report. */
function retryStalledLoads(page, tries = 4, timeout = 15000) {
  const goto = page.goto.bind(page);
  let going = 0;
  page.goto = async (url, options = {}) => {
    going++;
    try {
      for (let n = 1; ; n++) {
        try {
          return await goto(url, { timeout, ...options });
        } catch (e) {
          if (BROWSER !== "webkit" || n >= tries || e.name !== "TimeoutError") throw e;
          console.log(`   (the page load stalled; asking again, ${n} of ${tries - 1})`);
        }
      }
    } finally {
      going--;
    }
  };
  if (BROWSER !== "webkit") return;
  // The same stall in a load the PAGE starts (it reloads itself while linking): the new page is
  // left without one of its own files for good. Seen as `strings.js` from the harness's own file
  // server, asked 3 s in and still unanswered 201 s later. Reload, as a person would.
  const waiting = new Map();
  let reloads = 0;
  page.on("request", (r) => {
    if (!["document", "script", "stylesheet"].includes(r.resourceType())) return;
    waiting.set(r, setTimeout(() => {
      if (going || page.isClosed() || ++reloads > 5) return;
      console.log(`   (a file of the page never arrived: ${new URL(r.url()).pathname}; reloading)`);
      page.reload({ timeout }).catch(() => {});
    }, timeout));
  });
  for (const done of ["requestfinished", "requestfailed"]) {
    page.on(done, (r) => { clearTimeout(waiting.get(r)); waiting.delete(r); });
  }
}

/** Open a page in headless Chromium and wait until `ready()` is true in it. */
export async function openPage(url, { ready = () => window.havenReady === true, before } = {}) {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  page.on("console", (m) => { if (process.env.SMOKE_CONSOLE || m.type() === "error") console.log(`   [page ${m.type()}] ${m.text()}`); });
  page.on("pageerror", (e) => console.log(`   [page error] ${e.message}`));
  if (process.env.SMOKE_HTTP) {
    // Every relay request the page makes, with its outcome (for diagnosing a smoke).
    page.on("response", (r) => {
      const u = new URL(r.url());
      if (/^\/(k|l|t)\//.test(u.pathname)) {
        const sent = r.request().postDataBuffer()?.length ?? 0;
        console.log(`   [page http] ${r.request().method()} ${u.host}${u.pathname.slice(0, 120)} body=${sent} -> ${r.status()}`);
      }
    });
  }
  if (process.env.SMOKE_PENDING) {
    // What the page has asked for and not been answered, printed if the run fails.
    const t0 = Date.now(), pending = new Map();
    page.on("request", (r) => pending.set(r, Date.now()));
    for (const done of ["requestfinished", "requestfailed"]) page.on(done, (r) => pending.delete(r));
    process.on("exit", (code) => {
      if (!code) return;
      for (const [r, at] of pending) {
        console.log(`   [pending] ${r.method()} ${r.resourceType()}${r.isNavigationRequest() ? " (navigation)" : ""} ${r.url().slice(0, 110)} asked ${((Date.now() - at) / 1000).toFixed(0)}s ago, at +${((at - t0) / 1000).toFixed(0)}s`);
      }
    });
  }
  if (before) await before(page);
  retryStalledLoads(page);
  await page.goto(url);
  await page.waitForFunction(ready, null, { timeout: 30000 });
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
