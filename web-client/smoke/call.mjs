// CALLS between browsers: three accounts that are contacts on one relay, each with a browser
// linked to it (by the browser's own code), all in a circle that allows web devices. One browser
// calls, another answers, media flows, the camera and a shared screen get through, and a third
// person is added mid-call — WebRTC in the page, signalling through the engine
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
/** The circle's standing as the account last printed it (it flips as members join and answer). */
const webAllowed = (peer) => peer.lines.filter((l) => l.startsWith("WEBSTATE ")).pop() === "WEBSTATE allowed=true";

let browsers = [];
const host = startPeer(bin, [join(root, "dist")]);
const guest = startPeer(bin, [join(root, "dist")], { HAVEN_SMOKE_GUEST: "1" });
const third = startPeer(bin, [join(root, "dist")], { HAVEN_SMOKE_GUEST: "1" });
const browser = await chromium.launch({
  args: ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream", "--autoplay-policy=no-user-gesture-required",
    "--auto-select-desktop-capture-source=Entire screen"],
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
  const thirdAccount = await third.line("ACCOUNT=");

  // The three accounts become contacts of each other, by invite link.
  host.write("!invite\n");
  const invite = await host.line("INVITE=");
  guest.write(`!connect ${invite}\n`);
  third.write(`!connect ${invite}\n`);
  const knows = (peer, ...others) => others.every((o) => has(peer, `CONTACT ${o}`));
  // The two that host nothing connect to each other once both know the host's relay: an invite
  // made before that names no relay, and neither would have anywhere to leave its acceptance.
  await until("both to be the host's contacts", () => knows(host, guestAccount, thirdAccount) && knows(guest, hostAccount) && knows(third, hostAccount), 240000);
  await sleep(5000);
  guest.write("!invite\n");
  third.write(`!connect ${await guest.line("INVITE=")}\n`);
  await until("the three accounts to be contacts", () =>
    knows(host, guestAccount, thirdAccount) && knows(guest, hostAccount, thirdAccount) && knows(third, hostAccount, guestAccount), 240000);
  step("three accounts are contacts of each other (invite links, the real connection flow)");

  // Their circle allows web devices only when EVERY member says so.
  for (const p of [host, guest, third]) p.write("!web on\n");
  await until("every account to see the circle allow web devices", () => [host, guest, third].every(webAllowed), 240000);
  step("every member agreed, so the circle allows web devices");

  // Each account links a browser, both served by the hosting account's relay.
  const a = await linkedBrowser(origin, host, "the host's browser");
  const b = await linkedBrowser(origin, guest, "the guest's browser");
  const c = await linkedBrowser(origin, third, "the third browser");
  browsers = [a, b, c];
  step("each account linked a browser through the same relay");

  for (const [w, others] of [[a, [guestAccount, thirdAccount]], [b, [hostAccount, thirdAccount]], [c, [hostAccount, guestAccount]]]) {
    await until(`${w.label} to know its account's contacts`, async () => {
      const known = ((await w.invoke("contacts")) || []).map((x) => x.id_hex);
      return others.every((o) => known.includes(o));
    }, 180000);
    await until(`${w.label} to be let into the circle`, async () => (await w.invoke("circle_web_access", { circleId: "" }))?.allowed, 180000);
  }
  step("every browser knows the other accounts and is let into the circle");

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

  // VIDEO. Calls start audio-only; the host's browser turns its camera on with the real control.
  /** Video frames decoded over every connected peer connection in the page. */
  const frames = (w) => w.page.evaluate(async () => {
    let n = 0;
    for (const pc of window.__pcs || []) {
      if (pc.connectionState !== "connected") continue;
      (await pc.getStats()).forEach((s) => { if (s.type === "inbound-rtp" && s.kind === "video") n += s.framesDecoded || 0; });
    }
    return n;
  });
  /** What the page is sending as video: "camera", "screen", or "" for nothing live. */
  const sending = (w) => w.page.evaluate(() => {
    for (const pc of window.__pcs || []) {
      if (pc.connectionState !== "connected") continue;
      const t = pc.getSenders().map((s) => s.track).find((t) => t && t.kind === "video" && t.readyState === "live" && t.enabled);
      if (t) return t.getSettings().displaySurface ? "screen" : "camera";
    }
    return "";
  });
  const control = (w, n) => w.page.locator(".call-controls .call-round").nth(n);   // mic, camera, screen
  // A camera that is off still sends frames — black ones, at full rate — so "the picture arrived"
  // is judged by what the other page actually shows: a remote video that is not black.
  const picture = (w) => w.page.evaluate(() => {
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
  const rate = async (w) => {
    const f0 = await frames(w);
    await sleep(3000);
    return ((await frames(w)) - f0) / 3;
  };
  const flowing = (what, from, to) => until(what, async () => (await rate(to)) >= 8, 60000);
  if ((await picture(a)) || (await picture(b))) throw new Error("a browser shows the other's picture before any camera was turned on");
  await control(a, 1).click();
  await until("the host's browser to send its camera", async () => (await sending(a)) === "camera", 30000);
  await flowing("the guest's browser to decode the host's camera", a, b);
  await until("the guest's browser to show the host's picture", () => picture(b), 30000);
  if (await picture(a)) throw new Error("the host's browser shows the guest's picture, whose camera is still off");
  step("the camera turned on mid-call reaches the other browser (no new offer)");
  await control(b, 1).click();
  await until("the host's browser to show the guest's picture", () => picture(a), 60000);
  step("video flows both ways");

  // SCREEN SHARING replaces the camera for everyone; stopping brings the camera back.
  await control(a, 2).click();
  await until("the host's browser to send its screen", async () => (await sending(a)) === "screen", 30000);
  await flowing("the guest's browser to decode the shared screen", a, b);
  step("a shared screen reaches the other browser");
  await control(a, 2).click();
  await until("the host's browser to go back to its camera", async () => (await sending(a)) === "camera", 30000);
  await flowing("the guest's browser to decode the camera again", a, b);
  step("stopping the share brings the camera back");

  // A THIRD person, added to the call in progress with the real "add" control: everyone meshes.
  await control(a, 3).click();
  await a.page.locator(".modal .list-item button").first().click();   // the only contact not in the call
  await a.page.keyboard.press("Escape");
  await until("the third browser to ring", () => c.page.evaluate(() => !!document.querySelector(".call-overlay")), 90000);
  await c.page.locator(".call-overlay button.btn.primary").click();
  const links = (w) => w.page.evaluate(() => (window.__pcs || []).filter((pc) => pc.connectionState === "connected").length);
  await until("every browser to be connected to the other two", async () => (await links(a)) === 2 && (await links(b)) === 2 && (await links(c)) === 2, 120000);
  for (const w of [a, b, c]) {
    const r0 = await received(w);
    await until(`${w.label} to receive media in the group call`, async () => (await received(w)) > r0 + 4000, 60000);
  }
  await until("the group layout in the caller's browser", () => a.page.evaluate(() => document.querySelectorAll(".call-grid .call-tile").length === 2), 30000);
  step("a third person added mid-call rings, answers, and all three are connected to each other");

  // One person leaving does not end it for the other two.
  await emit(c, { action: "call_end" });
  await until("the third browser to leave", async () => !(await c.page.evaluate(() => !!document.querySelector(".call-screen, .call-overlay"))) && (await links(a)) === 1 && (await links(b)) === 1, 60000);
  if (!(await a.page.evaluate(() => !!document.querySelector(".call-screen")))) throw new Error("one person leaving ended the call for everyone");
  step("one person leaving leaves the other two in the call");

  await emit(a, { action: "call_end" });
  await until("the call to end in both browsers", async () =>
    !(await a.page.evaluate(() => !!document.querySelector(".call-screen, .call-overlay"))) && !(await b.page.evaluate(() => !!document.querySelector(".call-screen, .call-overlay"))), 60000);
  step("hanging up ends the call in both browsers");

  for (const w of [a, b, c]) if (w.crashes.length) throw new Error(`${w.label} crashed: ${w.crashes.join(" | ")}`);
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
  third.kill();
}
process.exit(failed ? 1 : 0);
