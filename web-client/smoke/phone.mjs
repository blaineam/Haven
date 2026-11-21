// A REAL Haven app as the primary: link a browser to it by the browser's own code, and check
// per-circle consent and posts each way. The app is driven through its DEBUG QA channel
// (docs/QA.md "qa-cmd v2": a `qa-cmd.json` dropped into its Application Support, answered by a
// fresh `qa-dump.json`), so this exercises the app's own Swift/Kotlin code — the scan answer
// (frame 38), the confirmation, the web mark, the circle's web-access switch — not a stand-in.
//
// What has to be running first (see docs/QA.md "The browser against a real app"):
//   1. the app (DEBUG build, with a persistent account) in a simulator or emulator;
//   2. a `haven-relay run --link <the app's relay_link> --web-app web-client/dist …` it has
//      adopted as its default relay (`add_relay`), reachable from this machine at ORIGIN;
//   3. at least one post in the default circle (this script makes its own).
//
//   PHONE_QA_DIR="<app data container>/Library/Application Support" \
//   ORIGIN=http://127.0.0.1:18675 node web-client/smoke/phone.mjs
//
// The Android app keeps its QA channel in its own `files/qa/`, reached over adb with `run-as`:
//   PHONE_ADB_PKG=com.blaineam.haven ORIGIN=http://127.0.0.1:18675 node web-client/smoke/phone.mjs
// (`adb reverse tcp:<port> tcp:<port>` for each of the relay's ports first, so the address the
// browser's code names is the same place inside the emulator. ANDROID_SERIAL picks the device.)
//
// PHONE_SITE=1 serves the page from a plain web site instead of from the relay
// (web-client/dist-site), with no rendezvous relay named: the page and the app then meet on the
// public rendezvous relays, and the page learns the relay from the account. That is the whole
// "linked from a web site" path against the app's own code; it needs the internet.
//
// Needs Playwright (NODE_PATH may point at a node_modules that has it).
import { createRequire } from "node:module";
import { configured, dump, qa, until, usage } from "./qachannel.mjs";
import { serveSite } from "./harness.mjs";

const { chromium } = createRequire(import.meta.url)("playwright");
const ORIGIN = (process.env.ORIGIN || "").replace(/\/$/, "");
if (!configured || !ORIGIN) {
  console.error(`usage: ${usage}\n       ORIGIN=http://… node phone.mjs`);
  process.exit(2);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const step = (s) => console.log(`ok  ${s}`);

const browser = await chromium.launch();
const page = await browser.newPage();
const crashes = [];
page.on("pageerror", (e) => crashes.push(e.message));
page.on("console", (m) => { if (m.type() === "error" && m.text().includes("[haven panic]")) crashes.push(m.text()); });
await page.addInitScript(() => { window.__HAVEN_HARNESS__ = { pushOff: true }; });
// The page reloads while it links, so a call can land on a context that is going away.
const invoke = async (name, args = {}) => {
  try {
    return await page.evaluate(async ([n, a]) => window.__TAURI__.core.invoke("engine_invoke", { name: n, args: a }), [name, args]);
  } catch {
    return null;
  }
};

let site = null;
try {
  const mark = `from the phone ${Date.now()}`;
  await qa({ op: "post", body: mark });

  site = process.env.PHONE_SITE === "1" ? await serveSite("", ORIGIN) : null;
  await page.goto(site ? `${site.url}/` : `${ORIGIN}/app/`);
  if (site) step(`the page is served by a plain web site at ${site.url}, not by the relay`);
  await page.waitForFunction(() => !!window.__HAVEN_WEB__, null, { timeout: 30000 });
  await page.evaluate(() => window.__HAVEN_WEB__.ready);
  const code = await until("the browser's code", () => page.evaluate(() => document.querySelector("#pair-copy")?.dataset.code || null), 60000);
  step("the browser shows its code");

  await qa({ op: "pair_answer", code });
  const answered = await until("the app's answer", async () => (await dump()).pair_answer || null, 60000);
  if (answered !== "sent") throw new Error(`the app could not answer the code: ${answered}`);
  step(`the app answered the code (frame 38, through ${site ? "a public rendezvous relay" : "the relay the code names"})`);

  const name = await until("the link request in the app", async () => (await dump()).enroll_pending || null, 90000);
  if (!name.startsWith("🌐 ")) throw new Error(`the request is not marked as a web device: ${name}`);
  step(`the app raised its confirmation for "${name}" — marked as a browser`);
  await qa({ op: "enroll_confirm" });

  await until("the browser to be linked", async () => (await invoke("seedless_status"))?.linked, 180000);
  if ((await invoke("my_node_hex")) !== (await dump()).account_hex) throw new Error("the browser linked to a different account");
  step("the browser is a linked device of the app's account");

  const standing = await until("the circle's standing in the browser", () => invoke("circle_web_access", { circleId: "" }), 60000);
  if (!standing.this_is_web || standing.can_sign) throw new Error(`expected a marked web device that cannot sign: ${JSON.stringify(standing)}`);
  await until("the app's post in the browser", async () => ((await invoke("feed", { circleId: "" })) || []).some((p) => p.body === mark), 180000);
  step("the browser reads the app's post with nobody asked: linking was the only approval");

  const reply = `from the browser ${Date.now()}`;
  await invoke("post", { circleId: "", body: reply, media: [] });
  await until("the browser's post in the app", async () => JSON.stringify((await dump()).posts || []).includes(reply), 180000);
  step("the app shows the browser's post");

  if (crashes.length) throw new Error(`the page crashed: ${crashes.join(" | ")}`);
  console.log("PASS");
} catch (e) {
  console.error(`FAIL ${e.message}`);
  process.exitCode = 1;
} finally {
  if (site) site.close();
  await browser.close();
}
