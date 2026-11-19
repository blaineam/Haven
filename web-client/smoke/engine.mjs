// Web-client smoke: the real UI and the real engine, in headless Chromium, served by a real
// hosting relay.
//
// Native side (core/haven-client/examples/web_primary_engine.rs): an account's primary device
// running the shared client engine — the code the desktop app runs — hosting its circle's relay
// with web access on. Browser side: the bundle that relay serves under /app/ (web-client/dist —
// the desktop frontend, a host shim, and the same engine compiled to WebAssembly). Nothing is
// simulated in between.
//
//   web-client/build.sh
//   cargo build -p haven-client --example web_primary_engine
//   node web-client/smoke/engine.mjs core/target/debug/examples/web_primary_engine
//
// Proves: the relay serves the page; a fresh browser is offered linking and nothing else; pasting
// a `haven-enroll:` ticket and the primary's approval link it; the linked state survives the
// reload (IndexedDB); a post travels EACH way and is attributed to the account on both devices;
// and the post shows in the rendered feed.
//
// SMOKE_SHOTS=<dir> saves screenshots at phone, tablet and desktop widths.
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { openPage, root, run } from "./harness.mjs";

const until = async (what, fn, ms = 90000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const v = await fn().catch(() => null);
    if (v) return v;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 200));
  }
};

/** Call a UI command the way app.js does. */
const invoke = (page, name, args = {}) =>
  page.evaluate(([name, args]) => window.__TAURI__.core.invoke("engine_invoke", { name, args }), [name, args]);

/** Before the app's own scripts run: keep a throwaway identity off the production push worker. */
const quiet = (page) =>
  page.addInitScript((log) => { window.__HAVEN_HARNESS__ = { pushOff: true, log }; }, process.env.SMOKE_LOG || "");

const SIZES = { phone: [390, 844], tablet: [820, 1180], desktop: [1440, 900] };
async function shots(page, label) {
  const dir = process.env.SMOKE_SHOTS;
  if (!dir) return;
  mkdirSync(dir, { recursive: true });
  for (const [name, [width, height]] of Object.entries(SIZES)) {
    await page.setViewportSize({ width, height });
    await page.waitForTimeout(250);
    await page.screenshot({ path: join(dir, `${label}-${name}.png`) });
  }
  await page.setViewportSize({ width: SIZES.desktop[0], height: SIZES.desktop[1] });
}

await run(
  "engine.mjs <web_primary_engine binary>",
  async ({ peer, step, onExit }) => {
    const origin = await peer.line("ORIGIN=", 60000);
    const account = await peer.line("ACCOUNT=");
    const ticket = await peer.line("TICKET=");
    const { browser, page } = await openPage(`${origin}/app/`, { ready: () => !!window.__HAVEN_WEB__, before: quiet });
    onExit(() => browser.close());
    await page.evaluate(() => window.__HAVEN_WEB__.ready);
    step(`the relay serves the web client at ${origin}/app/`);

    // Onboarding: a browser is offered linking, and only linking.
    const code = page.locator("#onboard-overlay input.field-capsule, input.field-capsule").first();
    await code.waitFor({ timeout: 30000 });
    const offered = await page.evaluate(() => document.body.innerText);
    if (/new to haven/i.test(offered)) throw new Error("a browser was offered account creation");
    await shots(page, "1-link");
    step("a fresh browser shows the link screen (no create / move-account choices)");

    // A seed-style code must be refused, not sent anywhere.
    await code.fill("haven-seed:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    await page.locator("button.btn.primary").first().click();
    await page.waitForTimeout(600);
    if (!(await page.evaluate(() => window.__HAVEN_WEB__.app().needsOnboarding()))) throw new Error("a seed code created an identity in the browser");
    step("a seed code is refused in a browser");

    await code.fill(ticket);
    await page.locator("button.btn.primary").first().click();
    await peer.line("ENROLLED ", 90000);
    step("pasted the ticket; the primary approved");

    // The UI reloads itself on linking and again when the grant lands. The engine that RECEIVED the
    // grant already reports "linked" for the instant before that second reload, but it is still on
    // its placeholder account — so wait for an engine that is linked AND on the real account.
    const linked = await until("the linked engine after its reloads", async () => {
      const s = await invoke(page, "seedless_status");
      if (!s || !s.linked) return null;
      return (await invoke(page, "my_node_hex")) === account ? s : null;
    });
    if (!linked.seedless) throw new Error(`linked but not seedless: ${JSON.stringify(linked)}`);
    step("the browser is a linked, seedless device of the same account (state survived the reloads)");

    const feed = () => invoke(page, "feed", { circleId: "" });

    // Tab → primary.
    await invoke(page, "post", { circleId: "", body: "hello from the browser", media: [] });
    await until("the tab's post on the primary", async () => peer.lines.includes("FEED me hello from the browser"));
    step("primary shows the tab's post, attributed to the account");

    // Primary → tab (through the relay mailbox the page shares an origin with).
    peer.write("hello from the primary\n");
    const fromPrimary = await until("the primary's post in the tab", async () => (await feed()).find((p) => p.body === "hello from the primary"));
    if (!fromPrimary.is_me) throw new Error("the primary's post should read as this account's own in the tab");
    step("tab shows the primary's post (same account)");

    // Media, each way: sealed in one engine, stored on the relay, fetched and opened by the other.
    const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
    const ref = await invoke(page, "add_media", { circleId: "", dataBase64: PNG, isVideo: false });
    await invoke(page, "post", { circleId: "", body: "picture from the browser", media: [ref] });
    await until("the tab's picture on the primary", async () => peer.lines.includes("FEED me picture from the browser [media 1]"), 120000);
    step("primary fetched and opened a picture posted from the tab");

    peer.write("!img picture from the primary\n");
    const pic = await until("the primary's picture post in the tab", async () => (await feed()).find((p) => p.body === "picture from the primary"), 120000);
    const url = await until("the primary's picture bytes in the tab", () => invoke(page, "media_data_url", { circleId: "", reference: pic.media[0] }), 120000);
    if (!url.startsWith("data:image/png;base64,") || !url.endsWith(PNG)) throw new Error(`the tab opened different bytes: ${url.slice(0, 60)}…`);
    step("tab fetched and opened a picture posted from the primary (byte-identical)");

    // And the UI actually renders them.
    await until("both posts on screen", async () =>
      page.evaluate(() => ["hello from the primary", "hello from the browser"].every((b) => document.body.innerText.includes(b))));
    await shots(page, "2-you");
    step("both posts are rendered in the feed");

    // The other views, for the screenshots (and as a check that they render without an error).
    if (process.env.SMOKE_SHOTS) {
      for (const [view, label] of [["circle", "3-circle"], ["messages", "4-messages"]]) {
        await page.locator(`.tab[data-view="${view}"]`).click();
        await page.waitForTimeout(700);
        await shots(page, label);
      }
      await page.locator('.tab[data-view="you"]').click();
      await page.waitForTimeout(400);
      const gear = page.locator("#tb-right button").first();
      if (await gear.count()) {
        await gear.click();
        await page.waitForTimeout(700);
        await shots(page, "5-settings");
      }
    }
  },
  { peerArgs: [join(root, "dist")] },
);
