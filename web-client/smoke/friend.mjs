// A FRIEND'S posts in a linked browser: two accounts that are contacts, one of them with a
// browser linked to it. What the friend posted BEFORE the browser was linked, and what they post
// after, must both show in the browser, as on any other device of the account. (A browser used to
// show only its own account's posts: everybody else's are sealed by THEIR devices, to the devices
// they know of.)
//
//   node web-client/smoke/friend.mjs <web_primary_engine binary>
//
// NOT hermetic: the two native accounts find each other through public discovery, so this needs
// the internet. FRIEND_OFFLINE=1 stops the friend's app before the browser is linked: the
// browser must then get what the friend posted from its own account's devices.
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { startPeer } from "./harness.mjs";

const { chromium } = createRequire(import.meta.url)("playwright");
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const bin = process.argv[2];
if (!bin) { console.error("usage: friend.mjs <web_primary_engine binary>"); process.exit(2); }
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

const me = startPeer(bin, [join(root, "dist")]);
const friend = startPeer(bin, [join(root, "dist")], { HAVEN_SMOKE_GUEST: "1" });
const browser = await chromium.launch();
let failed = false;
try {
  const origin = await me.line("ORIGIN=", 60000);
  const myAccount = await me.line("ACCOUNT=");
  const friendAccount = await friend.line("ACCOUNT=");
  me.write("!invite\n");
  friend.write(`!connect ${await me.line("INVITE=")}\n`);
  await until("the two to be contacts", () => has(me, `CONTACT ${friendAccount}`) && has(friend, `CONTACT ${myAccount}`), 240000);
  step("two accounts are contacts");

  friend.write("from the friend, before the browser\n");
  await until("the friend's post on my app", () => me.lines.includes("FEED other from the friend, before the browser"), 180000);
  me.write("mine, before the browser\n");
  await until("my post on the friend's app", () => friend.lines.includes("FEED other mine, before the browser"), 180000);
  step("each reads the other's post on their apps");

  if (process.env.FRIEND_OFFLINE === "1") {
    friend.kill();
    await sleep(2000);
    step("the friend's app is closed before the browser is linked");
  }

  const page = await browser.newPage();
  const crashes = [];
  page.on("pageerror", (e) => crashes.push(e.message));
  await page.addInitScript((log) => { window.__HAVEN_HARNESS__ = { pushOff: true, log }; }, process.env.SMOKE_LOG || "");
  if (process.env.SMOKE_LOG) page.on("console", (m) => console.log(`   [page] ${m.text()}`.slice(0, 260)));
  const invoke = async (name, args = {}) => {
    try { return await page.evaluate(async ([n, a]) => window.__TAURI__.core.invoke("engine_invoke", { name: n, args: a }), [name, args]); } catch { return null; }
  };
  await page.goto(`${origin}/app/`);
  await page.waitForFunction(() => !!window.__HAVEN_WEB__, null, { timeout: 30000 });
  await page.evaluate(() => window.__HAVEN_WEB__.ready);
  const code = await until("the browser's code", () => page.evaluate(() => document.querySelector("#pair-copy")?.dataset.code || null), 60000);
  me.write(`!pair ${code}\n`);
  await until("my account to answer the code", () => me.lines.includes("PAIRED"), 60000);
  await until("the browser to be linked", async () => (await invoke("seedless_status"))?.linked, 180000);
  step("a browser is linked to my account");

  const feed = async () => (await invoke("feed", { circleId: "" })) || [];
  const shows = async (body) => (await feed()).some((p) => p.body === body);
  await until("my own earlier post in the browser", () => shows("mine, before the browser"), 180000);
  step("the browser shows my own earlier post");
  await until("the friend's EARLIER post in the browser", () => shows("from the friend, before the browser"), Number(process.env.FRIEND_WAIT_MS || 240000));
  step("the browser shows what the friend posted before it was linked");

  if (process.env.FRIEND_OFFLINE !== "1") {
    friend.write("from the friend, after the browser\n");
    await until("the friend's NEW post in the browser", () => shows("from the friend, after the browser"), 240000);
    step("the browser shows what the friend posts afterwards");
  }
  if (crashes.length) throw new Error(`the page crashed: ${crashes.join(" | ")}`);
  console.log("PASS");
} catch (e) {
  failed = true;
  console.error(`FAIL ${e.message}`);
  console.error("me said:\n  " + me.lines.filter((l) => !l.startsWith("TICKET")).slice(-12).join("\n  "));
  console.error("friend said:\n  " + friend.lines.filter((l) => !l.startsWith("TICKET")).slice(-12).join("\n  "));
} finally {
  try { await browser.close(); } catch {}
  me.kill(); friend.kill();
  process.exit(failed ? 1 : 0);
}
