// Browser-engine smoke: the shared client engine (core/haven-client — the code the desktop app
// runs) compiled to WebAssembly, in headless Chromium, against the same engine running natively as
// the account's primary device (core/haven-client/examples/web_primary_engine.rs), through a
// circle DERP. Nothing is simulated between them.
//
//   web-client/build.sh
//   cargo build -p haven-client --example web_primary_engine
//   node web-client/smoke/engine.mjs core/target/debug/examples/web_primary_engine
//
// Proves: a fresh tab has no identity; it links with a `haven-enroll:` ticket and the primary's
// approval; the linked state survives a page reload (IndexedDB); a post authored in the tab is
// opened by the primary and attributed to the account. (Primary → tab needs the relay mailbox — see
// the note at the end.)
import { openPage, run } from "./harness.mjs";

const until = async (what, fn, ms = 60000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 150));
  }
};

/** Load storage, create the app with the page's relay, and expose it as window.app. */
const startApp = (page, derp) =>
  page.evaluate(async (derp) => {
    window.events = [];
    window.haven.setPushOff(true); // a throwaway identity must not touch the production push worker
    window.storage = await window.attachStorage(window.haven);
    window.app = new window.haven.WebApp((name, json) => window.events.push([name, json]));
    window.app.setRelays([derp]);
    return window.app.needsOnboarding();
  }, derp);

await run("engine.mjs <web_primary_engine binary>", async ({ site, peer, step, onExit }) => {
  const derp = await peer.line("DERP=");
  const account = await peer.line("ACCOUNT=");
  const ticket = await peer.line("TICKET=");
  const { browser, page } = await openPage(site.url);
  onExit(() => browser.close());

  if (!(await startApp(page, derp))) throw new Error("a fresh browser claims to already hold an identity");
  step("a fresh tab holds no identity");

  await page.evaluate(async (ticket) => {
    window.app.onboardLink(ticket);
    if (!(await window.app.boot())) throw new Error("boot found no identity after onboardLink");
  }, ticket);
  const linking = JSON.parse(await page.evaluate(() => window.app.status()));
  if (!linking.seedless || linking.linked || !linking.linking) throw new Error(`unexpected status while linking: ${JSON.stringify(linking)}`);
  step("tab booted the engine as a seedless device, waiting for approval");

  await peer.line("ENROLLED ", 60000);
  await until("haven:enrolled in the tab", () => page.evaluate(() => window.events.some(([n]) => n === "haven:enrolled")));
  step("primary approved; the tab accepted the grant");

  // The desktop app relaunches here; a tab flushes its storage and reloads.
  await page.evaluate(() => window.storage.flush());
  await page.reload();
  await page.waitForFunction(() => window.havenReady === true, null, { timeout: 30000 });
  if (await startApp(page, derp)) throw new Error("the linked identity did not survive a reload");
  await page.evaluate(() => window.app.boot());
  const linked = JSON.parse(await page.evaluate(() => window.app.status()));
  if (!linked.seedless || !linked.linked) throw new Error(`not linked after reload: ${JSON.stringify(linked)}`);
  const tabAccount = await page.evaluate(() => window.app.accountIdHex());
  if (tabAccount !== account) throw new Error(`tab is on account ${tabAccount}, expected ${account}`);
  step("after a reload the tab is a linked device of the same account (state persisted)");

  // Tab → primary: authored by a device that holds no account key, delivered live through the
  // DERP, opened by the native engine and attributed to the account.
  await page.evaluate(() => window.app.post("default", "hello from the browser"));
  await until("the tab's post on the primary", () => peer.lines.includes("FEED me hello from the browser"));
  step("primary shows the tab's post, attributed to the account");

  // NOT YET COVERED — primary → tab. The tab receives the primary's frames, but a newly linked
  // device learns the circle's current keys through the relay MAILBOX (self-sync and the key
  // exchange ride it), and this smoke has a DERP but no mailbox: a page can only reach a relay's
  // mailbox same-origin, i.e. once the relay serves the page. That is the next piece
  // (docs/WEB-PARITY.md); this smoke then runs against a real relay and asserts both directions.
});
