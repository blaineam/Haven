// The web client served by an ORDINARY WEB SITE, not by a relay.
//
// Same files, different host: web-client/dist-site (build.sh) on a plain static file server whose
// origin is not the relay's. Such a page starts out knowing no relay. It shows its code, a device
// that has the account answers it through a rendezvous relay, and from then on it talks to the
// circle's relay across origins — which is only possible because the relay answers a browser's
// preflight and marks its answers readable (core/haven-net/src/httprelay.rs).
//
//   web-client/build.sh
//   cargo build -p haven-client --features test-util --example web_primary_engine
//   node web-client/smoke/site.mjs core/target/debug/examples/web_primary_engine
//
// By default the site names the primary's own relay as its rendezvous (a site may do that: the
// `haven-rendezvous` meta tag), so the run is hermetic. SMOKE_RENDEZVOUS=public leaves the tag
// out, and the page then meets the primary on the public rendezvous relays the apps also fall
// back to. That is the path a real site-hosted page takes; it needs the internet, and for the
// page to reach the relay afterwards the relay must be on https (HAVEN_SMOKE_TUNNEL=1 — see the
// warning in web_primary_engine.rs before using it on a machine that hosts a real relay).
//
// Proves: the page says which site it trusts; it shows a code that names a relay it can be
// reached through although it was served by none; the primary's answer links it; nothing of a
// circle reaches it before it is linked; then posts travel each way, with every
// mailbox call crossing origins.
import { join } from "node:path";
import { openPage, root, serveSite, startPeer } from "./harness.mjs";

const bin = process.argv[2];
if (!bin) {
  console.error("usage: site.mjs <web_primary_engine binary>");
  process.exit(2);
}
const PUBLIC = process.env.SMOKE_RENDEZVOUS === "public";
const step = (s) => console.log(`ok  ${s}`);
const until = async (what, fn, ms = 90000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const v = await fn().catch(() => null);
    if (v) return v;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 200));
  }
};
const invoke = (page, name, args = {}) =>
  page.evaluate(([name, args]) => window.__TAURI__.core.invoke("engine_invoke", { name, args }), [name, args]).catch(() => null);

const peer = startPeer(bin, [join(root, "dist")]);
const cleanup = [() => peer.kill()];
const diagnose = [];
let failed = false;
try {
  const relay = await peer.line("ORIGIN=", 180000);
  const account = await peer.line("ACCOUNT=");
  if (relay.startsWith("https://")) {
    await until("the tunnel's hostname to resolve and answer", async () => {
      try { return (await fetch(`${relay}/_haven`)).ok; } catch { return false; }
    }, 180000);
  }
  const site = await serveSite(PUBLIC ? "" : relay, relay);
  cleanup.push(() => site.close());
  if (new URL(site.url).origin === new URL(relay).origin) throw new Error("the site and the relay share an origin");

  // Every mailbox call the page makes, and where it went.
  const calls = [];
  const dotted = new Set();
  const { browser, page } = await openPage(`${site.url}/`, {
    ready: () => !!window.__HAVEN_WEB__,
    before: async (page) => {
      await page.addInitScript((log) => { window.__HAVEN_HARNESS__ = { pushOff: true, log }; }, process.env.SMOKE_LOG || "");
      // Safari refuses TLS to a host written with a trailing dot ("relay.example.com."), which
      // is how the public relays are named. Chromium does not mind, so check the names here.
      page.on("request", (r) => {
        try { if (new URL(r.url()).hostname.endsWith(".")) dotted.add(new URL(r.url()).hostname); } catch {}
      });
      page.on("websocket", (ws) => {
        try { if (new URL(ws.url()).hostname.endsWith(".")) dotted.add(new URL(ws.url()).hostname); } catch {}
      });
      page.on("response", (r) => {
        const u = new URL(r.url());
        if (/^\/(k|l|n|t)\//.test(u.pathname)) calls.push({ origin: u.origin, method: r.request().method(), status: r.status(), path: decodeURIComponent(u.pathname) });
      });
    },
  });
  cleanup.push(() => browser.close());
  const pageLog = [];
  page.on("console", (m) => { pageLog.push(`[${m.type()}] ${m.text()}`.slice(0, 300)); });
  diagnose.push(async () => `page: ${JSON.stringify({
    url: page.url(),
    onboarding: await page.evaluate(() => window.__HAVEN_WEB__?.app()?.needsOnboarding?.()).catch(() => "?"),
    status: await invoke(page, "seedless_status"),
    me: await invoke(page, "my_node_hex"),
    calls: calls.slice(-10),
    crashes,
  })}\npage console (last 40):\n  ${pageLog.slice(-40).join("\n  ")}`);
  const crashes = [];
  // While the page is being torn down (a reload, or erasing itself), WebKit reports each fetch it
  // cancels as an uncaught "…due to access control checks". Those are not crashes of a running
  // page, so errors are not counted between `leaving = true` and the next page being ready.
  let leaving = false;
  // The same report can arrive after the next page is up, for the one request that is always
  // in flight (the node publishing its address, best effort); that one is ignored by name.
  const tornDown = (m) => /dns\.iroh\.link\/pkarr\/\S+ due to access control checks/.test(m);
  page.on("pageerror", (e) => { if (!leaving && !tornDown(e.message)) crashes.push(e.message); });
  page.on("console", (m) => { if (m.type() === "error" && m.text().includes("[haven panic]")) crashes.push(m.text()); });
  await page.evaluate(() => window.__HAVEN_WEB__.ready);
  step(`a plain web site serves the client at ${site.url}/ (the relay is ${relay})`);

  const host = new URL(site.url).host;
  const note = await until("the trust note", () => page.evaluate(() => document.querySelector("#web-trust-note")?.textContent || null), 30000);
  if (!note.includes(host)) throw new Error(`the page does not say which site it trusts: ${note}`);
  if (/new to haven/i.test(await page.evaluate(() => document.body.innerText))) throw new Error("a browser was offered account creation");
  step("the link screen names the site it was served by as something the person is trusting");

  const code = await until("the page's own code", () => page.evaluate(() => document.querySelector("#pair-copy")?.dataset.code || null), 90000);
  if (!code.startsWith("haven-pair:")) throw new Error(`not a device code: ${code.slice(0, 40)}`);
  if (!(await page.evaluate(() => !!document.querySelector("#pair-qr svg")))) throw new Error("the code is not shown as a QR");
  // Shown is not the same as scannable: an icon-sized code passes the line above.
  const qrSide = await page.evaluate(() => document.querySelector("#pair-qr svg").getBoundingClientRect().width);
  if (qrSide < 200) throw new Error(`the code is drawn ${qrSide}px wide, too small for a camera`);
  step(`a page that no relay served still shows a code (${PUBLIC ? "reachable through a public rendezvous relay" : "reachable through the relay its site names"})`);

  await page.locator('input[type="checkbox"]').first().check();
  // What the account already holds before this browser exists: its history, and a picture older
  // than every circle key the browser will be handed.
  peer.write("!oldimg from before this browser\n");
  await peer.line("OLD ready=true", 180000);
  for (let i = 1; i <= 3; i++) peer.write(`before the link ${i}\n`);
  await until("the primary's posts from before the link", async () => peer.lines.includes("FEED me before the link 3"));
  // A person does not scan the instant the code appears. SMOKE_PAIR_DELAY_MS leaves the page
  // showing its code for that long first, as it sits while someone finds their phone.
  if (process.env.SMOKE_PAIR_DELAY_MS) await new Promise((r) => setTimeout(r, Number(process.env.SMOKE_PAIR_DELAY_MS)));
  // The page can have its code up before the primary's own node has finished starting; a
  // primary that is still offline says so, and is asked again. So is one that dialed and did not
  // get through: the person would scan again. A dial that was REFUSED without being tried
  // ("dial backoff") is the bug this guards against, and any other refusal is a failure.
  let refusal = null;
  for (let asked = 0, seen = 0; !peer.lines.includes("PAIRED"); ) {
    const fails = peer.lines.filter((l) => l.startsWith("PAIRFAIL"));
    if (fails.length > seen) {
      seen = fails.length;
      if (!/offline|could not reach/.test(fails[seen - 1]) || /dial backoff/.test(fails[seen - 1]) || seen > 20) { refusal = fails[seen - 1]; break; }
    }
    if (asked === seen) { peer.write(`!pair ${code}\n`); asked++; }
    await new Promise((r) => setTimeout(r, 1000));
  }
  if (refusal) throw new Error(`the primary could not answer the code: ${refusal}`);
  await until("the browser to be linked", async () => {
    const s = await invoke(page, "seedless_status");
    return s && s.linked && (await invoke(page, "my_node_hex")) === account;
  }, 180000);
  step("the primary answered the code and the browser is a linked device of its account");

  const feed = async () => (await invoke(page, "feed", { circleId: "" })) || [];
  // History is handed over by the account's other device, newest first. The mailbox as it stood
  // at linking is NOT downloaded: on a real account that is thousands of envelopes in no order.
  await until("the posts from before the link, handed over by the primary", async () => {
    const bodies = (await feed()).map((p) => p.body);
    return [1, 2, 3].every((i) => bodies.includes(`before the link ${i}`));
  }, 240000);
  const handed = await until("the primary's history pages", async () => {
    const h = await invoke(page, "history_status");
    return h.received >= 3 && ["receiving", "paused", "done"].includes(h.state) ? h : null;
  }, 240000);
  // The relay here lists newest arrival first, so the page reads what is recent from it directly.
  if (!calls.some((c) => c.path.startsWith("/n/haven/mailbox/") && c.status === 200)) throw new Error(`the mailbox was not listed newest first: ${JSON.stringify(calls.filter((c) => /^\/[ln]\//.test(c.path)).slice(0, 6))}`);
  const backlogGets = calls.filter((c) => c.method === "GET" && c.path.startsWith("/k/haven/mailbox/") && !c.path.includes("/__"));
  console.log(`  (mailbox envelopes fetched so far: ${backlogGets.length}; hand-off: ${JSON.stringify(handed)})`);
  step("history from before the link is handed over by the account's other device, not dug out of the mailbox");

  const first = await until("the circle's standing", () => invoke(page, "circle_web_access", { circleId: "" }), 60000);
  if (!first.this_is_web || first.can_sign) throw new Error(`a linked browser must be a marked web device that cannot sign: ${JSON.stringify(first)}`);
  peer.write("posted with nobody asked\n");
  await until("the primary to have posted", async () => peer.lines.includes("FEED me posted with nobody asked"));
  await until("that post in the browser", async () => (await feed()).some((p) => p.body === "posted with nobody asked"), 180000);
  step("linking is the only approval: the page reads the circle from its relay with nobody asked");

  // That old picture was sealed before the browser existed, under a circle key rotated away six
  // times (DECISIONS D27). The primary reads the end of the blob from the relay and sends the
  // browser its key; the picture then crosses origins from the relay like any other.
  const old = await until("the old post on the page", async () => (await feed()).find((p) => p.body === "from before this browser" && p.media?.length), 180000);
  await until("the old picture, loaded from the relay with its own key", async () => {
    await invoke(page, "media_want", { circleId: "", references: old.media });
    return invoke(page, "media_present", { reference: old.media[0] });
  }, 180000);
  step("a picture older than every key the browser was given loads, with the key its phone sent for it");

  await invoke(page, "post", { circleId: "", body: "hello from a page on a web site", media: [] });
  await until("the page's post on the primary", async () => peer.lines.includes("FEED me hello from a page on a web site"), 180000);
  step("the primary shows the page's post");

  // Pictures each way. They are fetched and sent as larger blobs than a post, and from a web site
  // every one of those calls crosses origins too.
  const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
  peer.write("!img picture from the primary\n");
  const pic = await until("the primary's picture post on the page", async () => (await feed()).find((p) => p.body === "picture from the primary" && p.media?.length), 180000);
  const dataUrl = await until("the primary's picture bytes on the page", () => invoke(page, "media_data_url", { circleId: "", reference: pic.media[0] }), 180000);
  if (!dataUrl.endsWith(PNG)) throw new Error(`the page opened different bytes: ${dataUrl.slice(0, 60)}…`);
  await until("the picture drawn in the feed", () => page.evaluate(() => [...document.querySelectorAll(".post-media img")].some((i) => i.complete && i.naturalWidth > 0)), 60000);
  const ref = await invoke(page, "add_media", { circleId: "", dataBase64: PNG, isVideo: false });
  await invoke(page, "post", { circleId: "", body: "picture from the page", media: [ref] });
  await until("the page's picture on the primary", async () => peer.lines.includes("FEED me picture from the page [media 1]"), 180000);
  step("pictures travel each way and the page draws the one it received");

  // Nothing is downloaded until it is on screen. A picture is posted and then buried under more
  // than a page of newer posts: it arrives as a post, and its bytes stay on the relay until the
  // reader scrolls down to it.
  // The posts reach the page in whatever order the mailbox gives them, so for a moment the picture
  // can be among the newest the page holds. The feed is kept off screen until all of them are in:
  // what is tested is a picture UNDER a page of newer posts, not one that was briefly on top.
  const hide = await page.addStyleTag({ content: ".feed-list { display: none !important; }" });
  peer.write("!newimg picture far down the feed\n");
  for (let i = 1; i <= 32; i++) peer.write(`newer post ${i}\n`);
  const buried = await until("all of them on the page", async () => {
    const f = await feed();
    const newer = f.filter((p) => /^newer post \d+$/.test(p.body)).length;
    return newer === 32 ? f.find((p) => p.body === "picture far down the feed" && p.media?.length) : null;
  }, 240000);
  await page.waitForTimeout(3000);    // the page repaints for the last arrivals
  await hide.evaluate((n) => n.remove());
  await page.waitForTimeout(15000);   // several passes of the engine's background media sweep
  if (await invoke(page, "media_present", { reference: buried.media[0] })) throw new Error("the page downloaded media nobody had scrolled to");
  // To THAT post: older posts lie under it (the history from before the link), so the bottom of
  // the feed is somewhere past it. Until the feed has drawn its card, scroll on to draw more.
  await until("the picture once the reader scrolls down to it", async () => {
    await page.evaluate((body) => {
      const card = [...document.querySelectorAll("[data-post]")].find((c) => c.textContent.includes(body));
      if (card) return card.scrollIntoView({ block: "center" });
      for (const v of document.querySelectorAll(".view")) v.scrollTop = v.scrollHeight;
      window.scrollTo(0, document.body.scrollHeight);
    }, "picture far down the feed");
    return invoke(page, "media_present", { reference: buried.media[0] });
  }, 120000);
  step("media is fetched when the reader scrolls to it, not before");

  // The mailbox is the relay's, never the site's, and the browser was allowed to read it.
  const relayOrigin = new URL(relay).origin;
  const toRelay = calls.filter((c) => c.origin === relayOrigin);
  if (!toRelay.some((c) => c.status === 200)) throw new Error(`no mailbox call to the relay succeeded: ${JSON.stringify(calls.slice(-12))}`);
  if (calls.some((c) => c.origin === new URL(site.url).origin)) throw new Error("the page used the web site as a mailbox");
  step(`${toRelay.length} mailbox calls crossed from the site's origin to the relay's`);

  // A relay behind a free tunnel is given a new address every time it restarts, and HTTPS is the
  // only way a browser reaches a mailbox. With every address it holds dead, the page asks the
  // relay's NODE where it is now: found by its id, dialed through a public rendezvous relay.
  // (Only with real rendezvous relays: a hermetic run has nothing to find the node through.)
  if (PUBLIC) {
    // The relay an app hosts in-process publishes no address document (the stand-alone relay
    // does), so here the node's ANSWER is the proof: it was found, dialed and asked, and it
    // answered this member. A node that could not be reached logs "could not be asked".
    const answers = () => pageLog.filter((l) => /relay interface .*learned \d+ url\(s\) over iroh|relay \w+: its node publishes no address/.test(l)).length;
    const before = answers();
    await page.route(`${relayOrigin}/**`, (route) => route.abort());
    await until("the relay's node to answer the page", async () => answers() > before, 420000);
    await page.unroute(`${relayOrigin}/**`);
    peer.write("after the relay was found again\n");
    await until("a post made after the relay was found again", async () => (await feed()).some((p) => p.body === "after the relay was found again"), 240000);
    step("a page whose relay stopped answering reaches the relay's node to ask where it is, and carries on");
  }

  // Coming back to the site: still linked ("this is my computer"), still no relay of its own.
  await page.evaluate(() => window.__HAVEN_WEB__.flush());
  leaving = true;
  await page.goto(`${site.url}/`);
  await page.waitForFunction(() => !!window.__HAVEN_WEB__, null, { timeout: 30000 });
  await page.evaluate(() => window.__HAVEN_WEB__.ready);
  leaving = false;
  if (await page.evaluate(() => window.__HAVEN_WEB__.app().needsOnboarding())) throw new Error("the link did not survive leaving the page");
  peer.write("after coming back\n");
  await until("a post made after the page came back", async () => (await feed()).some((p) => p.body === "after coming back"), 180000);
  step("the link survives leaving and coming back, and the circle keeps arriving");

  // Removed from the account on another device: the page must not sit on what it had. It
  // forgets everything, says why, and is back on its link screen with a fresh code.
  leaving = true;
  peer.write("!revoke web\n");
  if ((await peer.line("REVOKED ")) !== "1") throw new Error("the primary did not find exactly one browser to remove");
  await until("the removed page to return to its link screen", () => page.evaluate(() => !!document.querySelector("#web-removed-note") && !!document.querySelector("#pair-copy")?.dataset.code), 120000);
  if (!(await page.evaluate(() => window.__HAVEN_WEB__.app().needsOnboarding()))) throw new Error("a removed browser still holds a link");
  await page.goto(`${site.url}/`);
  await page.waitForFunction(() => !!window.__HAVEN_WEB__, null, { timeout: 30000 });
  await page.evaluate(() => window.__HAVEN_WEB__.ready);
  if (!(await page.evaluate(() => window.__HAVEN_WEB__.app().needsOnboarding()))) throw new Error("a removed browser was linked again after a reload");
  leaving = false;
  step("a browser removed from the account erases itself, says why, and offers to link again");

  if (dotted.size) throw new Error(`the page asked for hosts Safari will not connect to: ${[...dotted].join(", ")}`);
  if (crashes.length) throw new Error(`the page crashed: ${crashes.join(" | ")}`);
  console.log("PASS");
} catch (e) {
  failed = true;
  console.error(`FAIL ${e.message}`);
  // What each side last knew, so a failure on a machine nobody is watching can be read.
  console.error("primary said:\n  " + peer.lines.filter((l) => !l.startsWith("TICKET")).slice(-25).join("\n  "));
  for (const f of diagnose) { try { console.error(await f()); } catch (err) { console.error(`(diagnosis failed: ${err.message})`); } }
} finally {
  for (const f of cleanup.reverse()) { try { await f(); } catch {} }
  process.exit(failed ? 1 : 0);
}
