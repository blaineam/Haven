// A CALL between two browsers: two accounts that are contacts on one relay, each with a browser
// linked to it (by the browser's own code), both in a circle that allows web devices. One browser
// calls, the other answers, and media flows — WebRTC in the page, signalling through the engine
// and the relay, exactly the desktop app's call code.
//
//   node web-client/smoke/call.mjs <web_primary_engine binary>
//
// NOT hermetic: the two native accounts find each other the way real ones do (public discovery),
// so this needs the internet and is not in CI. Chromium runs with fake camera and microphone.
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { startPeer } from "./harness.mjs";

const { chromium } = createRequire(import.meta.url)("playwright");
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const bin = process.argv[2];
if (!bin) { console.error("usage: call.mjs <web_primary_engine binary>"); process.exit(2); }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, f, ms = 120000) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await f();
    if (v) return v;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(1000);
  }
}
const step = (s) => console.log(`ok  ${s}`);
const has = (peer, line) => peer.lines.some((l) => l.startsWith(line));

let browsers = [];
const host = startPeer(bin, [join(root, "dist")]);
const guest = startPeer(bin, [join(root, "dist")], { HAVEN_SMOKE_GUEST: "1" });
const browser = await chromium.launch({
  args: ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream", "--autoplay-policy=no-user-gesture-required"],
});
let failed = false;

/** One browser: linked to `peer`'s account by its own code. */
async function linkedBrowser(origin, peer, label) {
  const context = await browser.newContext({ permissions: ["camera", "microphone"] });
  const page = await context.newPage();
  const crashes = [];
  page.on("pageerror", (e) => crashes.push(e.message));
  page.on("console", (m) => { if (m.type() === "error" && m.text().includes("[haven panic]")) crashes.push(m.text()); });
  const logs = [];
  page.on("console", (m) => { if (process.env.SMOKE_LOG) logs.push(m.text()); });
  await page.addInitScript((log) => {
    window.__HAVEN_HARNESS__ = { pushOff: true, log };
    // Keep every peer connection the page opens, so the test can look at them.
    const Real = window.RTCPeerConnection;
    window.__pcs = [];
    window.RTCPeerConnection = function (...a) { const pc = new Real(...a); window.__pcs.push(pc); return pc; };
    window.RTCPeerConnection.prototype = Real.prototype;
  }, process.env.SMOKE_LOG || "");
  const invoke = async (name, args = {}) => {
    try {
      return await page.evaluate(async ([n, a]) => window.__TAURI__.core.invoke("engine_invoke", { name: n, args: a }), [name, args]);
    } catch { return null; }
  };
  await page.goto(`${origin}/app/`);
  await page.waitForFunction(() => !!window.__HAVEN_WEB__, null, { timeout: 30000 });
  await page.evaluate(() => window.__HAVEN_WEB__.ready);
  const code = await until(`${label}'s code`, () => page.evaluate(() => document.querySelector("#pair-copy")?.dataset.code || null), 60000);
  const before = peer.lines.filter((l) => l === "PAIRED").length;
  peer.write(`!pair ${code}\n`);
  await until(`${label}'s account to answer the code`, () => peer.lines.filter((l) => l === "PAIRED").length > before, 60000);
  await until(`${label} to be linked`, async () => (await invoke("seedless_status"))?.linked, 180000);
  return { page, invoke, crashes, label, logs };
}

try {
  const origin = await host.line("ORIGIN=", 60000);
  const hostAccount = await host.line("ACCOUNT=");
  const guestAccount = await guest.line("ACCOUNT=");

  // The two accounts become contacts, by invite link.
  host.write("!invite\n");
  const invite = await host.line("INVITE=");
  guest.write(`!connect ${invite}\n`);
  await until("the two accounts to be contacts", () => has(host, `CONTACT ${guestAccount}`) && has(guest, `CONTACT ${hostAccount}`), 180000);
  step("two accounts are contacts (invite link, the real connection flow)");

  // Their circle allows web devices only when BOTH say so.
  host.write("!web on\n");
  guest.write("!web on\n");
  await until("both accounts to see the circle allow web devices", () => has(host, "WEBSTATE allowed=true") && has(guest, "WEBSTATE allowed=true"), 180000);
  step("both members agreed, so the circle allows web devices");

  // Each account links a browser, both served by the hosting account's relay.
  const a = await linkedBrowser(origin, host, "the host's browser");
  const b = await linkedBrowser(origin, guest, "the guest's browser");
  browsers = [a, b];
  step("each account linked a browser through the same relay");

  for (const [w, other] of [[a, guestAccount], [b, hostAccount]]) {
    await until(`${w.label} to know its account's contact`, async () => ((await w.invoke("contacts")) || []).some((c) => c.id_hex === other), 180000);
    await until(`${w.label} to be let into the circle`, async () => (await w.invoke("circle_web_access", { circleId: "" }))?.allowed, 180000);
  }
  step("both browsers know the other account and are let into the circle");

  // The host's browser calls the guest's account; the guest's browser answers.
  const emit = (w, payload) => w.page.evaluate((p) => window.__HAVEN_WEB__.emit("haven:qa-ui", p), payload);
  await emit(a, { action: "call_start", to: guestAccount });
  await until("the guest's browser to ring", () => b.page.evaluate(() => !!document.querySelector(".call-overlay")), 90000);
  step("the guest's browser rings (the invite was sealed to it, a device with no account key)");
  await b.page.locator(".call-overlay button.btn.primary").click();   // the real Accept button

  const connected = (w) => w.page.evaluate(() => (window.__pcs || []).some((pc) => pc.connectionState === "connected"));
  await until("the peer connection to connect in both browsers", async () => (await connected(a)) && (await connected(b)), 120000);
  step("the peer connection is up in both browsers");

  /** Bytes of media received over every connected peer connection in the page. */
  const received = (w) => w.page.evaluate(async () => {
    let n = 0;
    for (const pc of window.__pcs || []) {
      if (pc.connectionState !== "connected") continue;
      (await pc.getStats()).forEach((s) => { if (s.type === "inbound-rtp") n += s.bytesReceived || 0; });
    }
    return n;
  });
  const [a0, b0] = [await received(a), await received(b)];
  await until("media to flow both ways", async () => (await received(a)) > a0 + 2000 && (await received(b)) > b0 + 2000, 60000);
  step("audio flows both ways");

  await emit(a, { action: "call_end" });
  await until("the call to end in both browsers", async () =>
    !(await a.page.evaluate(() => !!document.querySelector(".call-screen, .call-overlay"))) && !(await b.page.evaluate(() => !!document.querySelector(".call-screen, .call-overlay"))), 60000);
  step("hanging up ends the call in both browsers");

  for (const w of [a, b]) if (w.crashes.length) throw new Error(`${w.label} crashed: ${w.crashes.join(" | ")}`);
  console.log("PASS");
} catch (e) {
  failed = true;
  console.error(`FAIL ${e.message}`);
  for (const w of browsers) {
    try {
      const st = await w.page.evaluate(() => ({ screen: !!document.querySelector(".call-screen"), pcs: (window.__pcs || []).map((p) => p.connectionState), toast: document.querySelector("#toast")?.textContent || "" }));
      console.error(`${w.label}:`, JSON.stringify(st));
      if (w.logs.length) console.error(w.logs.filter((l) => /call|invite|type=(1[0-9]|2[0-3])|refus|drop|unknown|not a|dial|fail/i.test(l)).slice(-25).join("\n"));
    } catch {}
  }
  if (process.env.SMOKE_DEBUG) {
    console.error("host:", host.lines.filter((l) => !/^(TICKET|INVITE)/.test(l)).slice(-25).join(" | "));
    console.error("guest:", guest.lines.filter((l) => !/^(TICKET|INVITE)/.test(l)).slice(-25).join(" | "));
  }
} finally {
  await browser.close();
  host.kill();
  guest.kill();
}
process.exit(failed ? 1 : 0);
