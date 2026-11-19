// Browser-engine smoke: the shared client engine (core/haven-client — the code the desktop app
// runs) compiled to WebAssembly, in headless Chromium, against the same engine running natively as
// the account's primary device AND hosting the circle's relay
// (core/haven-client/examples/web_primary_engine.rs). The tab loads the web client from that
// relay's own front door, exactly as a member's browser would. Nothing is simulated in between.
//
//   web-client/build.sh
//   cargo build -p haven-client --example web_primary_engine
//   node web-client/smoke/engine.mjs core/target/debug/examples/web_primary_engine
//
// Proves: the relay serves the page; a fresh tab holds no identity; it links with a
// `haven-enroll:` ticket and the primary's approval; the linked state survives a reload
// (IndexedDB); a post travels EACH way and is attributed to the account on both devices.
import { openPage, root, run } from "./harness.mjs";

const until = async (what, fn, ms = 90000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 150));
  }
};

/** Start the app in the page (window.app / window.storage / window.events). */
const startApp = (page) =>
  page.evaluate(async () => {
    window.haven.setPushOff(true); // a throwaway identity must not touch the production push worker
    if (window.smokeLog) window.haven.setLogLevel(window.smokeLog);
    window.events = [];
    const { app, storage, needsOnboarding } = await window.havenStart((name, payload) => window.events.push([name, payload]));
    window.app = app;
    window.storage = storage;
    return needsOnboarding;
  });

await run(
  "engine.mjs <web_primary_engine binary>",
  async ({ peer, step, onExit }) => {
    const origin = await peer.line("ORIGIN=", 60000);
    const account = await peer.line("ACCOUNT=");
    const ticket = await peer.line("TICKET=");
    const { browser, page } = await openPage(`${origin}/app/`);
    onExit(() => browser.close());
    if (process.env.SMOKE_LOG) await page.evaluate((l) => (window.smokeLog = l), process.env.SMOKE_LOG);
    step(`the relay serves the web client at ${origin}/app/`);

    if (!(await startApp(page))) throw new Error("a fresh browser claims to already hold an identity");
    step("a fresh tab holds no identity");

    await page.evaluate(async (ticket) => {
      window.app.onboardLink(ticket);
      if (!(await window.app.boot())) throw new Error("boot found no identity after onboardLink");
    }, ticket);
    const linking = JSON.parse(await page.evaluate(() => window.app.status()));
    if (!linking.seedless || linking.linked || !linking.linking) throw new Error(`unexpected status while linking: ${JSON.stringify(linking)}`);
    step("tab booted the engine as a seedless device, waiting for approval");

    await peer.line("ENROLLED ", 90000);
    await until("haven:enrolled in the tab", () => page.evaluate(() => window.events.some(([n]) => n === "haven:enrolled")));
    step("primary approved; the tab accepted the grant");

    // The desktop app relaunches here; a tab flushes its storage and reloads.
    await page.evaluate(() => window.storage.flush());
    await page.reload();
    await page.waitForFunction(() => window.havenReady === true, null, { timeout: 30000 });
    if (process.env.SMOKE_LOG) await page.evaluate((l) => (window.smokeLog = l), process.env.SMOKE_LOG);
    if (await startApp(page)) throw new Error("the linked identity did not survive a reload");
    await page.evaluate(() => window.app.boot());
    const linked = JSON.parse(await page.evaluate(() => window.app.status()));
    if (!linked.seedless || !linked.linked) throw new Error(`not linked after reload: ${JSON.stringify(linked)}`);
    const tabAccount = await page.evaluate(() => window.app.accountIdHex());
    if (tabAccount !== account) throw new Error(`tab is on account ${tabAccount}, expected ${account}`);
    step("after a reload the tab is a linked device of the same account (state persisted)");

    const feed = () => page.evaluate(() => JSON.parse(window.app.feed("default")));

    // Tab → primary: authored by a device that holds no account key.
    await page.evaluate(() => window.app.post("default", "hello from the browser"));
    await until("the tab's post on the primary", () => peer.lines.includes("FEED me hello from the browser"));
    step("primary shows the tab's post, attributed to the account");

    // Primary → tab: needs the circle's current keys, which reach a new device through the relay
    // mailbox — reachable here because the relay served the page (same origin).
    peer.write("hello from the primary\n");
    const fromPrimary = await until("the primary's post in the tab", async () => (await feed()).find((p) => p.body === "hello from the primary"));
    if (!fromPrimary.isMe) throw new Error("the primary's post should read as this account's own in the tab");
    step("tab shows the primary's post (same account → isMe)");

    const bodies = (await feed()).map((p) => p.body);
    for (const body of ["hello from the primary", "hello from the browser"]) {
      if (!bodies.includes(body)) throw new Error(`tab feed is missing "${body}": ${JSON.stringify(bodies)}`);
    }
    step("both posts are in the tab's feed");
  },
  { peerArgs: [root] },
);
