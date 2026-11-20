// CALLS between browsers and a REAL Haven app (its Swift or Kotlin call code).
//
// The app is one account. Two more accounts (the desktop engine, hosting nothing) become its
// contacts — and each other's — by invite link, and each links a browser, served by the APP's
// relay, by the browser's own code. Then:
//
//   1. a browser calls the app and the app answers: audio both ways;
//   2. video: the browser's camera reaches the app, and the app's camera reaches the browser;
//   3. a group call: the second browser is added mid-call, and the app and both browsers are all
//      connected to each other; one leaving leaves the other two talking;
//   4. hanging up in the browser ends it in the app;
//   5. the app calls back and the browser answers; hanging up in the app ends it in the browser.
//
// What this proves that the browser-only test cannot: the app seals its call frames to each
// DEVICE of the other account (a browser has no account key), and the app's WebRTC and the page's
// interoperate — audio, video, and a mesh of three.
//
// Set up exactly as for phone.mjs (docs/QA.md "The browser against a real app"), then:
//
//   PHONE_ADB_PKG=com.blaineam.haven ORIGIN=http://127.0.0.1:18675 \
//     node web-client/smoke/phone-call.mjs <web_primary_engine binary>
//
// NOT hermetic: the app and the other accounts find each other by public discovery, so the
// simulator or emulator needs the internet (the QA fleet's Android emulator is kept in airplane
// mode: `adb shell cmd connectivity airplane-mode disable`). PHONE_CALL_ONLY=1 runs steps 1, 4
// and 5 — the two-party test, without video or the third account. PHONE_INVITES=app|theirs picks
// whose invite link is taken (see below).
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
const TWO_PARTY = process.env.PHONE_CALL_ONLY === "1";
const INVITES = process.env.PHONE_INVITES || (process.env.PHONE_ADB_PKG ? "theirs" : "app");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const step = (s) => console.log(`ok  ${s}`);
const has = (peer, line) => peer.lines.some((l) => l.startsWith(line));
const webAllowed = (peer) => peer.lines.filter((l) => l.startsWith("WEBSTATE ")).pop() === "WEBSTATE allowed=true";

// The other accounts host nothing: once they are the app's contacts they use the app's relay,
// like any member of a circle whose relay someone else runs.
const other = startPeer(bin, [join(root, "dist")], { HAVEN_SMOKE_GUEST: "1" });
const third = TWO_PARTY ? null : startPeer(bin, [join(root, "dist")], { HAVEN_SMOKE_GUEST: "1" });
const accounts = third ? [other, third] : [other];
const browser = await chromium.launch({
  args: ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream", "--autoplay-policy=no-user-gesture-required"],
});
const browsers = [];

/** A browser linked to `peer`'s account by its own code, through the app's relay. */
async function linkedBrowser(peer, label) {
  const context = await browser.newContext({ permissions: ["camera", "microphone"] });
  const page = await context.newPage();
  const w = { page, label, crashes: [], logs: [] };
  page.on("pageerror", (e) => w.crashes.push(e.message));
  page.on("console", (m) => {
    if (m.type() === "error" && m.text().includes("[haven panic]")) w.crashes.push(m.text());
    if (process.env.SMOKE_DEBUG) w.logs.push(`${m.type()} ${m.text()}`);
  });
  await page.addInitScript(() => {
    window.__HAVEN_HARNESS__ = { pushOff: true };
    const Real = window.RTCPeerConnection;
    window.__pcs = [];
    window.RTCPeerConnection = function (...a) {
      const pc = new Real(...a);
      window.__pcs.push(pc);
      pc.addEventListener("connectionstatechange", () => console.info(`[pc] connection ${pc.connectionState}`));
      return pc;
    };
    window.RTCPeerConnection.prototype = Real.prototype;
  });
  w.invoke = async (name, args = {}) => {
    try {
      return await page.evaluate(async ([n, a]) => window.__TAURI__.core.invoke("engine_invoke", { name: n, args: a }), [name, args]);
    } catch { return null; }
  };
  w.emit = (payload) => page.evaluate((p) => window.__HAVEN_WEB__.emit("haven:qa-ui", p), payload);
  w.links = () => page.evaluate(() => (window.__pcs || []).filter((pc) => pc.connectionState === "connected").length);
  /** Bytes of media the page has received / sent over its connected peer connections. */
  w.media = () => page.evaluate(async () => {
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
  /** Does the page show someone else's picture — a remote video that is not black? (A camera
   *  that is off still sends frames, black ones, so a frame count proves nothing.) */
  w.picture = () => page.evaluate(() => {
    for (const v of document.querySelectorAll(".call-stage video")) {
      if (v.closest(".call-pip") || !v.videoWidth) continue;
      const c = document.createElement("canvas");
      c.width = 32; c.height = 32;
      const g = c.getContext("2d");
      g.drawImage(v, 0, 0, 32, 32);
      const d = g.getImageData(0, 0, 32, 32).data;
      let sum = 0;
      for (let i = 0; i < d.length; i += 4) sum += d[i] + d[i + 1] + d[i + 2];
      if (sum / (d.length / 4) > 30) return true;
    }
    return false;
  });
  w.inCallUi = () => page.evaluate(() => !!document.querySelector(".call-screen, .call-overlay"));
  w.rings = () => page.evaluate(() => !!document.querySelector(".call-overlay"));
  w.accept = () => page.locator(".call-overlay button.btn.primary").click();
  w.control = (n) => page.locator(".call-controls .call-round").nth(n);   // mic, camera, screen, add
  browsers.push(w);

  await page.goto(`${ORIGIN}/app/`);
  await page.waitForFunction(() => !!window.__HAVEN_WEB__, null, { timeout: 30000 });
  await page.evaluate(() => window.__HAVEN_WEB__.ready);
  const code = await until(`${label}'s code`, () => page.evaluate(() => document.querySelector("#pair-copy")?.dataset.code || null), 60000);
  peer.write(`!pair ${code}\n`);
  await until(`${label}'s account to answer the code`, () => has(peer, "PAIRED"), 60000);
  await until(`${label} to be linked`, async () => (await w.invoke("seedless_status"))?.linked, 180000);
  return w;
}

async function mediaFlows(w, what) {
  const m0 = await w.media();
  await until(what, async () => { const m = await w.media(); return m.got > m0.got + 2000 && m.sent > m0.sent + 2000; }, 60000);
}
const appCall = async () => (await dump()).call || {};
async function allIdle() {
  await until("the call to end on every side", async () => {
    for (const w of browsers) if (await w.inCallUi()) return false;
    const c = await appCall();
    return !c.in_call && !c.ringing;
  }, 60000);
}

let failed = false;
try {
  const them = await other.line("ACCOUNT=", 60000);
  const thirdAccount = third ? await third.line("ACCOUNT=", 60000) : null;
  const app = (await dump()).account_hex;

  // Contacts, by invite link. Which side's invite is taken is a parameter, because the two
  // directions are different code in the app:
  //   theirs — the app takes each other account's invite (`connect_link`), the scanner's path;
  //   app    — the other accounts take the APP's invite and the app approves them, the ordinary
  //            "I host the circle and invite a friend" path. Its invite names the app's relay.
  // Android is tested with "theirs". The iPhone app is tested with "app": with "theirs" it does
  // not finish the exchange with an account that has no relay of its own inside this test's
  // patience (docs/WEB-PARITY.md) — which is about making friends, not about calls.
  const knows = (peer, ...ids) => ids.every((a) => has(peer, `CONTACT ${a}`));
  if (INVITES === "app") {
    await qa({ op: "invite_link" });
    const link = await until("the app's invite link", async () => (await dump()).invite_link || null, 30000);
    for (const p of accounts) p.write(`!connect ${link}\n`);
  } else {
    for (const p of accounts) {
      p.write("!invite\n");
      await qa({ op: "connect_link", uri: await p.line("INVITE=") });
    }
  }
  await until("the other accounts to be the app's contacts", async () => {
    await qa({ op: "approve_connections" });
    const mine = JSON.stringify((await dump()).contacts || []);
    return knows(other, app) && mine.includes(them) && (!third || (knows(third, app) && mine.includes(thirdAccount)));
  }, 240000, 4000);
  if (third) {
    // The two that host nothing connect to each other once both know the app's relay: an invite
    // made before that names no relay, and neither would have anywhere to leave its acceptance.
    await sleep(5000);
    const invites = () => other.lines.filter((l) => l.startsWith("INVITE="));
    const before = invites().length;
    other.write("!invite\n");
    const again = await until("a fresh invite", () => invites().length > before && invites().pop().slice(7), 30000, 500);
    third.write(`!connect ${again}\n`);
    await until("the other two accounts to be contacts of each other", () => knows(other, thirdAccount) && knows(third, them), 240000);
  }
  step(`${third ? "the app and two more accounts are all contacts of each other" : "the app and a second account are contacts"} (${INVITES === "app" ? "they took the app's invite and the app approved" : "the app took their invite"})`);

  // Their shared circle allows web devices only when every member says so.
  for (const p of accounts) p.write("!web on\n");
  await qa({ op: "web_access", circle_id: "default", allow: true });
  // An account's answer goes to the app's relay, which refuses it until the app has told the relay
  // about its new contact (seconds on Android, up to half a minute on iPhone). A refused write is
  // retried on the account's next sync, minutes later — so say it again instead of waiting.
  let asked = 0;
  await until("everyone to see the circle allow web devices", async () => {
    if (++asked % 5 === 0) for (const p of accounts) p.write("!web on\n");
    await qa({ op: "web_access", circle_id: "default" });   // no `allow`: read the standing again
    return accounts.every(webAllowed) && (await dump()).web_access?.allowed === true;
  }, 300000, 4000);
  step("every member agreed, so the circle allows web devices");

  // Each of the other accounts links a browser, served by the app's relay.
  const a = await linkedBrowser(other, "the first browser");
  const b = third ? await linkedBrowser(third, "the second browser") : null;
  for (const [w, ids] of b ? [[a, [app, thirdAccount]], [b, [app, them]]] : [[a, [app]]]) {
    await until(`${w.label} to know the accounts it will call`, async () => {
      const known = ((await w.invoke("contacts")) || []).map((c) => c.id_hex);
      return ids.every((x) => known.includes(x));
    }, 180000);
  }
  step("the browsers are linked through the app's relay and know the accounts they will call");

  // 1. The browser calls the app.
  await a.emit({ action: "call_start", to: app });
  await until("the app to ring", async () => (await appCall()).ringing, 90000);
  step("the app rings for a call placed in a browser");
  await qa({ op: "call_accept" });
  await until("the call to connect", async () => (await a.links()) === 1 && (await appCall()).in_call, 120000);
  await mediaFlows(a, "audio to flow between the browser and the app");
  step("the app answered: connected, audio both ways");

  if (!TWO_PARTY) {
    // 2. Video, each way. Calls start audio-only on every platform.
    if (await a.picture()) throw new Error("the browser shows the app's picture before the app's camera was turned on");
    await a.control(1).click();
    await until("the app to show the browser's camera", async () => ((await appCall()).remote_video_tracks || []).includes(them), 60000);
    step("the browser's camera, turned on mid-call, reaches the app");
    await qa({ op: "call_video", on: true });
    // An iOS simulator has no camera at all, so there the app's switch never comes on and there is
    // no picture to wait for. Said out loud, not counted as a pass.
    const camera = await until("the app's camera switch", async () => (await appCall()).video_on || null, 20000).catch(() => false);
    if (camera) {
      await until("the browser to show the app's camera", () => a.picture(), 90000);
      step("the app's camera reaches the browser");
    } else {
      console.log("skip  the app's camera reaching the browser — this device has no camera (a simulator)");
      await qa({ op: "call_video", on: false });
    }

    // 3. A third person, added mid-call with the browser's real "add" control: everyone meshes.
    await a.control(3).click();
    await a.page.locator(".modal .list-item button").first().click();   // the only contact not in the call
    await a.page.keyboard.press("Escape");
    await until("the second browser to ring", () => b.rings(), 90000);
    await b.accept();
    await until("the app and both browsers to be connected to each other", async () => {
      const c = await appCall();
      // Android reports each peer's ICE state; Apple reports what has arrived from each.
      const up = Object.values(c.peers || {}).filter((p) => (typeof p === "string" ? /connected|completed/.test(p) : (p.audio_bytes || 0) > 0)).length;
      return (await a.links()) === 2 && (await b.links()) === 2 && (c.participants || []).length === 2 && up >= 2;
    }, 150000, 3000);
    for (const w of [a, b]) {
      const m0 = await w.media();
      await until(`${w.label} to receive media in the group call`, async () => (await w.media()).got > m0.got + 4000, 60000);
    }
    step("a second browser added mid-call rings, answers, and the app and both browsers are all connected");

    await b.emit({ action: "call_end" });
    await until("the second browser to leave", async () => !(await b.inCallUi()) && (await a.links()) === 1 && ((await appCall()).participants || []).length === 1, 90000, 3000);
    if (!(await appCall()).in_call) throw new Error("one person leaving ended the call for the app");
    step("one browser leaving leaves the app and the other browser in the call");
  }

  // 4. Hanging up in the browser.
  await a.emit({ action: "call_end" });
  await allIdle();
  step("hanging up in the browser ends it in the app");

  // 5. The app calls the browser's account: its invite must be sealed to the browser itself.
  await a.page.evaluate(() => { window.__pcs = []; });
  await qa({ op: "call", dm_to: them });
  await until("the browser to ring", () => a.rings(), 90000);
  step("the browser rings for a call placed in the app (sealed to a device with no account key)");
  await a.accept();
  await until("the call to connect", async () => (await a.links()) === 1 && (await appCall()).in_call, 120000);
  await mediaFlows(a, "audio to flow between the app and the browser");
  step("the browser answered: connected, audio both ways");
  await qa({ op: "call_end" });
  await allIdle();
  step("hanging up in the app ends it in the browser");

  for (const w of browsers) if (w.crashes.length) throw new Error(`${w.label} crashed: ${w.crashes.join(" | ")}`);
  console.log("PASS");
} catch (e) {
  failed = true;
  console.error(`FAIL ${e.message}`);
  try {
    for (const w of browsers) {
      console.error(`${w.label}:`, JSON.stringify(await w.page.evaluate(() => ({ ui: !!document.querySelector(".call-screen, .call-overlay"), pcs: (window.__pcs || []).map((p) => p.connectionState), toast: document.querySelector("#toast")?.textContent || "" }))));
      if (process.env.SMOKE_DEBUG) console.error(w.logs.filter((l) => /\[pc\]|call|offer|answer|fail|hairpin/i.test(l)).slice(-25).join("\n"));
    }
    console.error("app call:", JSON.stringify(await appCall()));
  } catch {}
  if (process.env.SMOKE_DEBUG) {
    for (const p of accounts) console.error("account:", p.lines.filter((l) => !/^(TICKET|INVITE)/.test(l)).slice(-16).join(" | "));
  }
} finally {
  await browser.close();
  for (const p of accounts) p.kill();
}
process.exit(failed ? 1 : 0);
