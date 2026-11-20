// A REAL push, end to end: a linked browser turns on "Notify me when Haven is closed", the push
// worker rings it through the browser vendor's real push service, and the service worker shows
// the notification.
//
//   node web-client/smoke/push.mjs <web_primary_engine binary>
//
// Everything of Haven's is local. The worker is `push/worker.js` itself, run in this process: the
// page's requests to the production worker's address are intercepted and answered by it, so
// nothing is ever sent to the deployed worker, and it signs with a key pair made here and thrown
// away. What is NOT local is the browser's push service — that is the point. This needs real
// Google Chrome (a test build of Chromium has no push service) and the internet, so it is run by
// hand and is not in CI. The push service is handed one empty request for a throwaway browser
// profile; nothing of anyone's is in it.
import { createRequire } from "node:module";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { startPeer } from "./harness.mjs";
import worker from "../../push/worker.js";

const { chromium } = createRequire(import.meta.url)("playwright");
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const bin = process.argv[2];
if (!bin) { console.error("usage: push.mjs <web_primary_engine binary>"); process.exit(2); }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, f, ms = 120000, every = 1000) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await f();
    if (v) return v;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(every);
  }
}
const step = (s) => console.log(`ok  ${s}`);

// The worker's world: an in-memory KV and a Web Push key pair that exists only for this run.
const kv = new Map();
const jwk = generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey.export({ format: "jwk" });
const env = {
  TOKENS: {
    async get(k, type) { const v = kv.get(k); return v == null ? null : type === "json" ? JSON.parse(v) : v; },
    async put(k, v) { kv.set(k, v); },
    async delete(k) { kv.delete(k); },
    async list() { return { keys: [], list_complete: true }; },
  },
  VAPID_PUBLIC_KEY: Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, "base64url"), Buffer.from(jwk.y, "base64url")]).toString("base64url"),
  VAPID_PRIVATE_KEY: jwk.d,
  VAPID_SUBJECT: "https://example.invalid/haven-push-smoke",
};
const WORKER = /^https:\/\/haven-push\.wemiller\.workers\.dev\//;
const calls = [];
const toWorker = async (path, body) => (await worker.fetch(new Request(`https://haven-push.wemiller.workers.dev${path}`, {
  method: "POST", headers: { "content-type": "application/json", "cf-connecting-ip": "127.0.0.1" }, body: JSON.stringify(body),
}), env));

const profile = mkdtempSync(join(tmpdir(), "haven-push-"));
const primary = startPeer(bin, [join(root, "dist")]);
let context, failed = false;
try {
  const origin = await primary.line("ORIGIN=", 60000);
  const account = await primary.line("ACCOUNT=");
  const ticket = await primary.line("TICKET=");

  context = await chromium.launchPersistentContext(profile, { channel: "chrome", headless: true, permissions: ["notifications"] });
  // The page believes it is talking to the deployed worker; it is talking to the one above.
  await context.route(WORKER, async (route) => {
    const req = route.request();
    calls.push(`${req.method()} ${new URL(req.url()).pathname}`);
    const res = await worker.fetch(new Request(req.url(), {
      method: req.method(),
      headers: { "content-type": "application/json", "cf-connecting-ip": "127.0.0.1" },
      body: ["GET", "HEAD", "OPTIONS"].includes(req.method()) ? undefined : req.postData(),
    }), env);
    await route.fulfill({ status: res.status, headers: Object.fromEntries(res.headers), body: await res.text() });
  });
  const page = context.pages()[0] || (await context.newPage());
  const crashes = [];
  page.on("pageerror", (e) => crashes.push(e.message));
  const host = (cmd, args = {}) => page.evaluate(([c, a]) => window.__TAURI__.core.invoke(c, a).then((v) => ({ ok: v }), (e) => ({ err: String(e) })), [cmd, args]);
  const engine = async (name, args = {}) => { try { return await page.evaluate(([n, a]) => window.__TAURI__.core.invoke("engine_invoke", { name: n, args: a }), [name, args]); } catch { return null; } };
  const loaded = async () => { await page.waitForFunction(() => !!window.__HAVEN_WEB__, null, { timeout: 30000 }); await page.evaluate(() => window.__HAVEN_WEB__.ready); };

  // Link this browser as one the person will keep ("this is my computer").
  await page.goto(`${origin}/app/`);
  await loaded();
  const code = page.locator("input.field-capsule").first();
  await code.waitFor({ timeout: 30000 });
  await code.fill(ticket);
  await page.locator('input[type="checkbox"]').first().check();
  await page.locator("button.btn.primary").first().click();
  await until("the browser to be linked", async () => (await engine("seedless_status"))?.linked && (await engine("my_node_hex")) === account, 180000);
  step("a real Chrome is linked as a browser the person keeps");

  // Turn it on, through the page's own switch code.
  const before = await host("web_push_status");
  if (!before.ok?.supported || !before.ok.kept || before.ok.enabled) throw new Error(`unexpected starting state: ${JSON.stringify(before)}`);
  const on = await host("web_push_set", { on: true });
  if (!on.ok?.enabled) throw new Error(`could not turn web push on: ${JSON.stringify(on)} (worker calls: ${calls.join(", ")})`);
  const filed = JSON.parse(kv.get(account) || "{}").tokens || [];
  if (filed.length !== 1 || filed[0].platform !== "web") throw new Error(`the worker did not file the browser under the account: ${JSON.stringify(filed)}`);
  const pushHost = new URL(filed[0].token).hostname;
  step(`the browser subscribed with the worker's key and was filed under its account (push service: ${pushHost})`);

  // Leave Haven: no page of it is open any more.
  await page.goto("about:blank");
  await sleep(1500);

  // Someone wakes the account, exactly as an app does.
  const sent = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => { const r = await realFetch(url, init); sent.push({ url: String(url), status: r.status, body: init?.body }); return r; };
  let res;
  try { res = await toWorker("/notify", { nodeId: account, ciphertext: "c2VhbGVk" }); } finally { globalThis.fetch = realFetch; }
  if (res.status !== 200 || sent.length !== 1) throw new Error(`notify: ${res.status}, ${sent.length} request(s) sent`);
  if (sent[0].body !== undefined) throw new Error("the push carried a body");
  if (sent[0].status < 200 || sent[0].status > 299) throw new Error(`the push service refused the push: ${sent[0].status}`);
  step(`the worker rang it with an empty push and the push service accepted it (${sent[0].status})`);

  // The service worker shows the notification with nothing open. Look at what it showed from a
  // page inside its scope (a script file is enough — and is not the app).
  const shown = await until("the notification", async () => {
    const probe = await context.newPage();
    try {
      await probe.goto(`${origin}/app/sw.js`);
      return await probe.evaluate(async () => {
        const reg = await navigator.serviceWorker.getRegistration("./");
        const list = reg ? await reg.getNotifications() : [];
        return list.length ? list.map((n) => ({ title: n.title, body: n.body, tag: n.tag })) : null;
      });
    } finally { await probe.close(); }
  }, 90000, 4000);
  if (shown.length !== 1 || shown[0].title !== "Haven" || shown[0].tag !== "haven" || !/waiting/i.test(shown[0].body)) {
    throw new Error(`unexpected notification: ${JSON.stringify(shown)}`);
  }
  step(`with no Haven page open, the browser showed: "${shown[0].title} — ${shown[0].body}"`);

  // Turning it off unsubscribes; the next ring finds the endpoint gone and the worker forgets it.
  await page.goto(`${origin}/app/`);
  await loaded();
  const off = await host("web_push_set", { on: false });
  if (off.ok?.enabled !== false) throw new Error(`could not turn web push off: ${JSON.stringify(off)}`);
  await until("the worker to forget the endpoint", async () => {
    await toWorker("/notify", { nodeId: account, ciphertext: "c2VhbGVk" });
    return !kv.has(account);
  }, 120000, 5000);
  step("switched off: the browser unsubscribed, and the worker dropped the endpoint the next time it tried it");

  if (crashes.length) throw new Error(`the page crashed: ${crashes.join(" | ")}`);
  console.log("PASS");
} catch (e) {
  failed = true;
  console.error(`FAIL ${e.message}`);
  if (process.env.SMOKE_DEBUG) console.error("worker calls:", calls.join(", "));
} finally {
  if (context) await context.close().catch(() => {});
  primary.kill();
  rmSync(profile, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
