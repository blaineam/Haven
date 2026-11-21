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
    const origin = await peer.line("ORIGIN=", 180000);
    const account = await peer.line("ACCOUNT=");
    const ticket = await peer.line("TICKET=");
    // Through a real tunnel (HAVEN_SMOKE_TUNNEL=1) the hostname is minutes old at most: wait for
    // it to resolve and answer before pointing a browser at it.
    if (origin.startsWith("https://")) {
      await until("the tunnel's hostname to resolve and answer", async () => {
        try { return (await fetch(`${origin}/_haven`)).ok; } catch { return false; }
      }, 180000);
    }
    const { browser, page } = await openPage(`${origin}/app/`, { ready: () => !!window.__HAVEN_WEB__, before: quiet });
    onExit(() => browser.close());
    // An uncaught error in the page — above all a Rust panic in the engine, which surfaces as a
    // bare "unreachable" — fails the run, whatever else passed. (A panic kills only the task it
    // happened in, so everything after it can still look fine; that is how the engine's delayed
    // save went unnoticed while it crashed on every received post.)
    const crashes = [];
    page.on("pageerror", (e) => crashes.push(e.message));
    page.on("console", (m) => { if (m.type() === "error" && m.text().includes("[haven panic]")) crashes.push(m.text()); });
    const noCrashes = (where) => { if (crashes.length) throw new Error(`the page crashed (${where}): ${crashes.join(" | ")}`); };
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

    // ── A linked browser is a device like any other ───────────────────────────────────────────
    // Linking is the only approval: nobody has said anything about this circle, and the browser
    // reads it, including what was posted before it was linked. It still holds no account key.
    const access = () => invoke(page, "circle_web_access", { circleId: "" });
    const first = await access();
    if (!first.this_is_web) throw new Error("the browser's credential is not marked as a web device");
    if (first.can_sign) throw new Error("a browser can sign for the account");
    if (await invoke(page, "set_circle_web_access", { circleId: "", allow: false })) throw new Error("a browser signed a position for the account");
    peer.write("posted with nobody asked\n");
    await until("the primary to have posted", async () => peer.lines.includes("FEED me posted with nobody asked"));
    await page.locator('.tab[data-view="circle"]').click();
    await until("that post in the browser", async () => (await feed()).some((p) => p.body === "posted with nobody asked"), 120000);
    if (await page.locator("#cwa-blocked").count()) throw new Error("the page still says the circle is not shown in browsers");
    await shots(page, "1-reads");
    await page.locator('.tab[data-view="you"]').click();
    step("a linked browser reads its account's circle with nobody asked, and still cannot sign for the account");

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

    // Saving to the computer — what a browser does with a video too large to hold (the size rule
    // itself is unit-tested; here the real page hands real decrypted bytes to the browser as a
    // file, then lets go of them).
    const { readFileSync: readSaved } = await import("node:fs");
    const [download] = await Promise.all([
      page.waitForEvent("download", { timeout: 60000 }),
      page.evaluate((r) => window.__TAURI__.core.invoke("media_save_to_disk", { circleId: "", reference: r, video: false }), pic.media[0]),
    ]);
    if (readSaved(await download.path()).toString("base64") !== PNG) throw new Error("the saved file is not the picture that was posted");
    if (!/^haven-[A-Za-z0-9_-]+$/.test(download.suggestedFilename())) throw new Error(`odd file name: ${download.suggestedFilename()}`);
    if (await invoke(page, "media_present", { reference: pic.media[0] })) throw new Error("the saved blob is still held in the tab");
    if (!((await invoke(page, "media_evicted_size", { reference: pic.media[0] })) > 0)) throw new Error("the saved blob did not go back to being a placeholder");
    step("'Save to this computer' hands the decrypted file to the browser and keeps nothing in the tab");

    // A picture DROPPED onto the page lands in the composer (and the page stays where it is — a
    // browser navigates to a dropped file unless the drop is cancelled).
    const dropPicture = () => page.evaluate(async (b64) => {
      const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
      const dt = new DataTransfer();
      dt.items.add(new File([bytes], "dropped.png", { type: "image/png" }));
      const fire = (type) => {
        const e = new DragEvent(type, { dataTransfer: dt, bubbles: true, cancelable: true });
        document.body.dispatchEvent(e);
        return e.defaultPrevented;
      };
      return [fire("dragenter"), fire("dragover"), fire("drop")];
    }, PNG);
    const here = page.url();
    // With no composer on screen (the You tab) the drop is cancelled and nothing else happens.
    let cancelled = await dropPicture();
    if (!cancelled.every(Boolean)) throw new Error(`a file drag was not cancelled (${cancelled}) — the browser would leave the page`);
    // On the circle tab the composer is there, and the picture is attached to it.
    await page.locator('.tab[data-view="circle"]').click();
    await page.locator("textarea.composer-field").first().waitFor({ timeout: 30000 });
    cancelled = await dropPicture();
    if (!cancelled.every(Boolean)) throw new Error(`a file drag was not cancelled (${cancelled})`);
    await until("the dropped picture in the composer", () => page.evaluate(() => !!document.querySelector(".attach-preview .chip img")), 30000);
    if (page.url() !== here) throw new Error("the drop navigated the page away");
    await page.locator(".attach-preview .chip .x").first().click();
    await page.locator('.tab[data-view="you"]').click();
    step("a picture dropped on the page is attached to the composer; a drop never navigates away");

    // Give the engine's delayed save (3 s after a received post) time to run, then: no crash.
    await page.waitForTimeout(4000);
    noCrashes("after posts and pictures in both directions");
    step("the engine ran its delayed save in the page without a crash");

    // ── At rest, and after the tab is left ───────────────────────────────────────────────────
    await page.evaluate(() => window.__HAVEN_WEB__.flush());
    if ((await page.evaluate(() => window.__HAVEN_WEB__.mode())) !== "session") throw new Error("expected a session-mode store");
    const n = assertEncrypted(await rawStorage(page), account, "session mode");
    step(`everything stored is ciphertext (${n} records; no JSON keys, no account id)`);

    // Web Push is not offered in a browser the person did not choose to stay linked in: a
    // borrowed computer must not go on being rung after the tab is closed.
    const hostCall = (cmd, args = {}) => page.evaluate(([c, a]) => window.__TAURI__.core.invoke(c, a).then((v) => ({ ok: v }), (e) => ({ err: String(e) })), [cmd, args]);
    const borrowed = await hostCall("web_push_status");
    if (!borrowed.ok || borrowed.ok.kept || borrowed.ok.enabled) throw new Error(`web push in a session-only browser: ${JSON.stringify(borrowed)}`);
    if ((await hostCall("web_push_set", { on: true })).err !== "session") throw new Error("a session-only browser was allowed to turn web push on");
    step("a browser that will forget its link cannot be set to ring after the tab closes");

    // Leaving the page (anything but a reload) ends a shared-computer session for good.
    if (!process.env.SMOKE_SHOTS) {
      await page.goto(`${origin}/app/`);
      await page.waitForFunction(() => !!window.__HAVEN_WEB__, null, { timeout: 30000 });
      await page.evaluate(() => window.__HAVEN_WEB__.ready);
      if (!(await page.evaluate(() => window.__HAVEN_WEB__.app().needsOnboarding()))) throw new Error("a shared-computer session survived leaving the page");
      const left = await rawStorage(page);
      if (Object.keys(left).length !== 0) throw new Error(`session databases were left behind: ${Object.keys(left)}`);
      step("after leaving the page the browser holds no identity and no Haven database");

      // "This is my computer", linked the other way round: the BROWSER shows a code and the
      // device that has the account answers it (scan-to-link). The link then survives leaving
      // and coming back, and is encrypted at rest.
      const pairCode = await until("the browser's own code on the link screen",
        () => page.evaluate(() => document.querySelector("#pair-copy")?.dataset.code || null), 60000);
      if (!pairCode.startsWith("haven-pair:")) throw new Error(`not a device code: ${pairCode.slice(0, 40)}`);
      if (!(await page.evaluate(() => !!document.querySelector("#pair-qr svg")))) throw new Error("the code is not shown as a QR");
      // Shown is not the same as scannable: an icon-sized code passes the line above.
      const qrSide = await page.evaluate(() => document.querySelector("#pair-qr svg").getBoundingClientRect().width);
      if (qrSide < 200) throw new Error(`the code is drawn ${qrSide}px wide, too small for a camera`);
      if (Object.keys(await rawStorage(page)).length !== 0) throw new Error("showing a code stored something before anyone answered it");
      await shots(page, "0-code");
      step("an unlinked browser shows its own code (QR + text) and stores nothing while it waits");

      // A ticket that was NOT sent in answer to this code changes nothing (the browser takes one
      // frame, and only if it opens under the code on screen); a malformed code is refused.
      peer.write("!pair haven-pair:AAAA\n");
      await peer.line("PAIRFAIL");   // (never "PAIRED": that line has not been printed yet)
      if (peer.lines.includes("PAIRED")) throw new Error("a malformed code was accepted");

      await page.locator('input[type="checkbox"]').first().check();
      peer.write(`!pair ${pairCode}\n`);
      await until("the primary to answer the code", async () => {
        if (peer.lines.filter((l) => l.startsWith("PAIRFAIL")).length > 1) throw new Error(`the primary could not answer the code: ${peer.lines.filter((l) => l.startsWith("PAIRFAIL")).pop()}`);
        return peer.lines.includes("PAIRED");
      }, 60000);
      step("the primary answered the code; the browser took the offer and asked to link");
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

      // Web Push, as far as a harness can take it (this page is kept off the push worker, and a
      // headless browser has no push service): the relay serves the service worker, the browser
      // accepts it for /app/, and the switch says "not available" rather than pretending.
      const sw = await page.evaluate(async () => {
        const res = await fetch("sw.js");
        const reg = await navigator.serviceWorker.register("sw.js", { scope: "./" });
        return { type: res.headers.get("content-type"), scope: reg.scope };
      });
      if (!/javascript/.test(sw.type) || sw.scope !== `${origin}/app/`) throw new Error(`service worker: ${JSON.stringify(sw)}`);
      const mine = await hostCall("web_push_status");
      if (!mine.ok || !mine.ok.supported || !mine.ok.kept || mine.ok.enabled) throw new Error(`web push status: ${JSON.stringify(mine)}`);
      const refused = await hostCall("web_push_set", { on: true });
      if (refused.err !== "unavailable") throw new Error(`expected "unavailable" with the push worker off: ${JSON.stringify(refused)}`);
      if ((await hostCall("web_push_status")).ok.enabled) throw new Error("a refused switch left a subscription behind");
      step("the relay serves the service worker for /app/; with no push worker the switch says so and subscribes nothing");

      // Start over: nothing of Haven's is left in the browser.
      await invoke(page, "reset");
      await page.reload();
      await page.waitForFunction(() => !!window.__HAVEN_WEB__, null, { timeout: 30000 });
      await page.evaluate(() => window.__HAVEN_WEB__.ready);
      if (!(await page.evaluate(() => window.__HAVEN_WEB__.app().needsOnboarding()))) throw new Error("Start over left an identity behind");
      const after = await rawStorage(page);
      if (Object.keys(after).length !== 0) throw new Error(`Start over left databases behind: ${Object.keys(after)}`);
      const workers = await page.evaluate(async () => (await navigator.serviceWorker.getRegistrations()).length);
      if (workers !== 0) throw new Error("Start over left a service worker registered");
      step("Start over erases every Haven database in the browser, and its service worker");
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
