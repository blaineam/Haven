// A CALL between a browser and a REAL Haven app (its Swift or Kotlin call code), each way.
//
// The app is one account; a second account (the desktop engine, hosting nothing) becomes its
// contact by invite link and links a browser — served by the APP's relay — by the browser's own
// code. Then the browser calls the app's account and the app answers, and the app calls back and
// the browser answers. What this proves that the two-browser test cannot: the app seals its call
// frames to each DEVICE of the other account (a browser has no account key), and the app's WebRTC
// and the page's interoperate.
//
// Set up exactly as for phone.mjs (docs/QA.md "The browser against a real app"), then:
//
//   PHONE_ADB_PKG=com.blaineam.haven ORIGIN=http://127.0.0.1:18675 \
//     node web-client/smoke/phone-call.mjs <web_primary_engine binary>
//
// NOT hermetic: the app and the second account find each other by public discovery, so the
// simulator or emulator needs the internet (the QA fleet's Android emulator is kept in airplane
// mode: `adb shell cmd connectivity airplane-mode disable`).
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { startPeer } from "./harness.mjs";
import { configured, dump, qa, until, usage } from "./qachannel.mjs";

const { chromium } = createRequire(import.meta.url)("playwright");
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const bin = process.argv[2], ORIGIN = (process.env.ORIGIN || "").replace(/\/$/, "");
if (!configured || !ORIGIN || !bin) {
  console.error(`usage: ${usage}\n       ORIGIN=http://… node phone-call.mjs <web_primary_engine binary>`);
  process.exit(2);
}
const step = (s) => console.log(`ok  ${s}`);
const has = (peer, line) => peer.lines.some((l) => l.startsWith(line));

// The second account hosts nothing: once the two are contacts it uses the app's relay, like any
// member of a circle whose relay someone else runs.
const other = startPeer(bin, [join(root, "dist")], { HAVEN_SMOKE_GUEST: "1" });
const browser = await chromium.launch({
  args: ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream", "--autoplay-policy=no-user-gesture-required"],
});
const context = await browser.newContext({ permissions: ["camera", "microphone"] });
const page = await context.newPage();
const crashes = [];
page.on("pageerror", (e) => crashes.push(e.message));
page.on("console", (m) => { if (m.type() === "error" && m.text().includes("[haven panic]")) crashes.push(m.text()); });
const logs = [];
page.on("console", (m) => { if (process.env.SMOKE_DEBUG) logs.push(`${m.type()} ${m.text()}`); });
await page.addInitScript(() => {
  window.__HAVEN_HARNESS__ = { pushOff: true };
  const Real = window.RTCPeerConnection;
  window.__pcs = [];
  window.RTCPeerConnection = function (...a) {
    const pc = new Real(...a);
    window.__pcs.push(pc);
    pc.addEventListener("connectionstatechange", () => console.info(`[pc] connection ${pc.connectionState}`));
    pc.addEventListener("signalingstatechange", () => console.info(`[pc] signaling ${pc.signalingState}`));
    return pc;
  };
  window.RTCPeerConnection.prototype = Real.prototype;
});
const invoke = async (name, args = {}) => {
  try {
    return await page.evaluate(async ([n, a]) => window.__TAURI__.core.invoke("engine_invoke", { name: n, args: a }), [name, args]);
  } catch { return null; }
};
const emit = (payload) => page.evaluate((p) => window.__HAVEN_WEB__.emit("haven:qa-ui", p), payload);
const connected = () => page.evaluate(() => (window.__pcs || []).some((pc) => pc.connectionState === "connected"));
/** Bytes of media the page has received / sent over its connected peer connections. */
const media = () => page.evaluate(async () => {
  let got = 0, sent = 0;
  for (const pc of window.__pcs || []) {
    if (pc.connectionState !== "connected") continue;
    (await pc.getStats()).forEach((s) => {
      if (s.type === "inbound-rtp") got += s.bytesReceived || 0;
      if (s.type === "outbound-rtp") sent += s.bytesSent || 0;
    });
  }
  return { got, sent };
});
const inCallUi = () => page.evaluate(() => !!document.querySelector(".call-screen, .call-overlay"));
async function mediaFlows(what) {
  const m0 = await media();
  await until(what, async () => { const m = await media(); return m.got > m0.got + 2000 && m.sent > m0.sent + 2000; }, 60000);
}
async function bothIdle() {
  await until("the call to end on both sides", async () => !(await inCallUi()) && !(await dump()).call?.in_call && !(await dump()).call?.ringing, 60000);
}

let failed = false;
try {
  const them = await other.line("ACCOUNT=", 60000);
  const app = (await dump()).account_hex;

  // Contacts, by invite link: the app scans the other account's.
  other.write("!invite\n");
  await qa({ op: "connect_link", uri: await other.line("INVITE=") });
  await until("the two accounts to be contacts", async () => {
    await qa({ op: "approve_connections" });
    return has(other, `CONTACT ${app}`) && JSON.stringify((await dump()).contacts || []).includes(them);
  }, 180000, 4000);
  step("the app and a second account are contacts (the app took the invite link)");

  // Their shared circle allows web devices only when both say so.
  other.write("!web on\n");
  await qa({ op: "web_access", circle_id: "default", allow: true });
  await until("both to see the circle allow web devices", async () => {
    await qa({ op: "web_access", circle_id: "default" });   // no `allow`: read the standing again
    return has(other, "WEBSTATE allowed=true") && (await dump()).web_access?.allowed === true;
  }, 180000, 4000);
  step("both members agreed, so the circle allows web devices");

  // The second account links a browser, served by the app's relay.
  await page.goto(`${ORIGIN}/app/`);
  await page.waitForFunction(() => !!window.__HAVEN_WEB__, null, { timeout: 30000 });
  await page.evaluate(() => window.__HAVEN_WEB__.ready);
  const code = await until("the browser's code", () => page.evaluate(() => document.querySelector("#pair-copy")?.dataset.code || null), 60000);
  other.write(`!pair ${code}\n`);
  await until("the second account to answer the code", () => has(other, "PAIRED"), 60000);
  await until("the browser to be linked", async () => (await invoke("seedless_status"))?.linked, 180000);
  await until("the browser to know the app's account", async () => ((await invoke("contacts")) || []).some((c) => c.id_hex === app), 180000);
  step("the second account's browser is linked through the app's relay and knows the app's account");

  // The browser calls the app.
  await emit({ action: "call_start", to: app });
  await until("the app to ring", async () => (await dump()).call?.ringing, 90000);
  step("the app rings for a call placed in a browser");
  await qa({ op: "call_accept" });
  await until("the call to connect", async () => (await connected()) && (await dump()).call?.in_call, 120000);
  await mediaFlows("audio to flow between the browser and the app");
  step("the app answered: connected, audio both ways");
  await emit({ action: "call_end" });
  await bothIdle();
  step("hanging up in the browser ends it in the app");

  // The app calls the browser's account: its invite must be sealed to the browser itself.
  await page.evaluate(() => { window.__pcs = []; });
  await qa({ op: "call", dm_to: them });
  await until("the browser to ring", () => page.evaluate(() => !!document.querySelector(".call-overlay")), 90000);
  step("the browser rings for a call placed in the app (sealed to a device with no account key)");
  await page.locator(".call-overlay button.btn.primary").click();
  await until("the call to connect", async () => (await connected()) && (await dump()).call?.in_call, 120000);
  await mediaFlows("audio to flow between the app and the browser");
  step("the browser answered: connected, audio both ways");
  await qa({ op: "call_end" });
  await bothIdle();
  step("hanging up in the app ends it in the browser");

  if (crashes.length) throw new Error(`the page crashed: ${crashes.join(" | ")}`);
  console.log("PASS");
} catch (e) {
  failed = true;
  console.error(`FAIL ${e.message}`);
  try {
    console.error("page:", JSON.stringify(await page.evaluate(() => ({ ui: !!document.querySelector(".call-screen, .call-overlay"), pcs: (window.__pcs || []).map((p) => p.connectionState), toast: document.querySelector("#toast")?.textContent || "" }))));
    console.error("app call:", JSON.stringify((await dump()).call));
  } catch {}
  if (process.env.SMOKE_DEBUG) console.error(logs.filter((l) => /\[pc\]|call|offer|answer|sdp|fail|hairpin/i.test(l)).slice(-40).join("\n"));
  if (process.env.SMOKE_DEBUG) console.error("other:", other.lines.filter((l) => !/^(TICKET|INVITE)/.test(l)).slice(-20).join(" | "));
} finally {
  await browser.close();
  other.kill();
}
process.exit(failed ? 1 : 0);
