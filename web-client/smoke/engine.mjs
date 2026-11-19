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
// reloads (IndexedDB); posts and pictures travel EACH way; the posts show in the rendered feed;
// everything stored is ciphertext; a shared-computer session is gone once the page is left; "this
// is my computer" survives, under a non-extractable key; and Start over erases it all.
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

/** Every stored Haven record in this browser, raw, per database: `{ db: [[path, record], …] }`. */
const rawStorage = (page) =>
  page.evaluate(async () => {
    const out = {};
    for (const { name } of await indexedDB.databases()) {
      if (!name || !name.startsWith("haven")) continue;
      const db = await new Promise((ok, no) => { const r = indexedDB.open(name); r.onsuccess = () => ok(r.result); r.onerror = () => no(r.error); });
      const rows = [];
      if (db.objectStoreNames.contains("files")) {
        await new Promise((ok, no) => {
          const req = db.transaction("files", "readonly").objectStore("files").openCursor();
          req.onerror = () => no(req.error);
          req.onsuccess = () => {
            const c = req.result;
            if (!c) return ok();
            const v = c.value;
            // Latin-1 view of the stored bytes, so the test can search them for plaintext.
            const bytes = new Uint8Array(v.data instanceof ArrayBuffer ? v.data : v.data?.buffer ?? []);
            let text = "";
            for (let i = 0; i < Math.min(bytes.length, 200000); i++) text += String.fromCharCode(bytes[i]);
            rows.push([c.key, { hasIv: v.iv instanceof Uint8Array && v.iv.length === 12, len: bytes.length, text }]);
            c.continue();
          };
        });
      }
      db.close();
      out[name] = rows;
    }
    return out;
  });

/** Records are ciphertext: none of the engine's plaintext (JSON keys, the account id) is in them. */
function assertEncrypted(dbs, account, what) {
  const rows = Object.values(dbs).flat();
  if (rows.length === 0) throw new Error(`${what}: nothing was stored`);
  for (const [path, rec] of rows) {
    if (!rec.hasIv) throw new Error(`${what}: ${path} is stored without a nonce (not encrypted)`);
    for (const needle of ['"relay_entries"', '"contacts"', "pending_ticket", account]) {
      if (rec.text.includes(needle)) throw new Error(`${what}: ${path} contains plaintext ${needle}`);
    }
  }
  return rows.length;
}

/** Fill the link screen and submit; `remember` ticks "this is my computer". */
async function linkWith(page, ticket, remember) {
  const code = page.locator("input.field-capsule").first();
  await code.waitFor({ timeout: 30000 });
  await code.fill(ticket);
  if (remember) await page.locator('input[type="checkbox"]').first().check();
  await page.locator("button.btn.primary").first().click();
}

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

    // Default: "this is my computer" is NOT ticked — a shared-computer session.
    if (await page.locator('input[type="checkbox"]').first().isChecked()) throw new Error("'this is my computer' is ticked by default");
    await linkWith(page, ticket, false);
    await peer.line("ENROLLED ", 90000);
    step("pasted the ticket (not my computer); the primary approved");

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

    // ── At rest, and after the tab is left ───────────────────────────────────────────────────
    await page.evaluate(() => window.__HAVEN_WEB__.flush());
    if ((await page.evaluate(() => window.__HAVEN_WEB__.mode())) !== "session") throw new Error("expected a session-mode store");
    const n = assertEncrypted(await rawStorage(page), account, "session mode");
    step(`everything stored is ciphertext (${n} records; no JSON keys, no account id)`);

    // Leaving the page (anything but a reload) ends a shared-computer session for good.
    if (!process.env.SMOKE_SHOTS) {
      await page.goto(`${origin}/app/`);
      await page.waitForFunction(() => !!window.__HAVEN_WEB__, null, { timeout: 30000 });
      await page.evaluate(() => window.__HAVEN_WEB__.ready);
      if (!(await page.evaluate(() => window.__HAVEN_WEB__.app().needsOnboarding()))) throw new Error("a shared-computer session survived leaving the page");
      const left = await rawStorage(page);
      if (Object.keys(left).length !== 0) throw new Error(`session databases were left behind: ${Object.keys(left)}`);
      step("after leaving the page the browser holds no identity and no Haven database");

      // "This is my computer": the link survives leaving and coming back, and is encrypted at rest.
      peer.write("!ticket\n");
      const ticket2 = await peer.line("TICKET2=");
      await linkWith(page, ticket2, true);
      await until("the remembered browser to be linked", async () => {
        const s = await invoke(page, "seedless_status");
        return s && s.linked && (await invoke(page, "my_node_hex")) === account;
      });
      await page.evaluate(() => window.__HAVEN_WEB__.flush());
      await page.goto(`${origin}/app/`);
      await page.waitForFunction(() => !!window.__HAVEN_WEB__, null, { timeout: 30000 });
      await page.evaluate(() => window.__HAVEN_WEB__.ready);
      if (await page.evaluate(() => window.__HAVEN_WEB__.app().needsOnboarding())) throw new Error("'this is my computer' did not survive leaving the page");
      if ((await page.evaluate(() => window.__HAVEN_WEB__.mode())) !== "persist") throw new Error("expected a persist-mode store");
      const kept = await rawStorage(page);
      if (Object.keys(kept).join() !== "haven") throw new Error(`expected only the 'haven' database, found ${Object.keys(kept)}`);
      assertEncrypted(kept, account, "persist mode");
      const extractable = await page.evaluate(async () => {
        const db = await new Promise((ok) => { const r = indexedDB.open("haven"); r.onsuccess = () => ok(r.result); });
        const key = await new Promise((ok) => { const r = db.transaction("keys").objectStore("keys").get("k1"); r.onsuccess = () => ok(r.result); });
        db.close();
        return key instanceof CryptoKey ? key.extractable : "not a CryptoKey";
      });
      if (extractable !== false) throw new Error(`the storage key must be a non-extractable CryptoKey (got ${extractable})`);
      step("'this is my computer' stays linked across visits; records are ciphertext under a non-extractable key");

      // Start over: nothing of Haven's is left in the browser.
      await invoke(page, "reset");
      await page.reload();
      await page.waitForFunction(() => !!window.__HAVEN_WEB__, null, { timeout: 30000 });
      await page.evaluate(() => window.__HAVEN_WEB__.ready);
      if (!(await page.evaluate(() => window.__HAVEN_WEB__.app().needsOnboarding()))) throw new Error("Start over left an identity behind");
      const after = await rawStorage(page);
      if (Object.keys(after).length !== 0) throw new Error(`Start over left databases behind: ${Object.keys(after)}`);
      step("Start over erases every Haven database in the browser");
    }

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
