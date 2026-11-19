// Browser-session smoke: link a tab as a SEEDLESS device of a real account and exchange sealed
// circle events with that account's primary device, over the app wire (frames 28/29/1) through a
// circle DERP. Native side: core/haven-ffi/examples/web_primary.rs — the real engine on a real node.
//
//   web-client/build.sh
//   cargo build -p haven_ffi --example web_primary
//   node web-client/smoke/session.mjs core/target/debug/examples/web_primary
import { openPage, run, startPeer } from "./harness.mjs";

await run("session.mjs <web_primary binary>", async ({ site, peer, step, onExit }) => {
  const derp = await peer.line("DERP=");
  const account = await peer.line("ACCOUNT=");
  const ticket = await peer.line("TICKET=");
  const { browser, page } = await openPage(site.url);
  onExit(() => browser.close());

  const deviceId = await page.evaluate(async (derp) => {
    window.changes = 0;
    window.session = await window.haven.WebSession.start(window.haven.generateDeviceSeed(), derp, () => window.changes++);
    return window.session.deviceIdHex();
  }, derp);
  if (await page.evaluate(() => window.session.isLinked())) throw new Error("a fresh tab claims to be linked");
  step(`tab online as device ${deviceId.slice(0, 12)}…, unlinked`);

  const linkedAccount = await page.evaluate(([ticket]) => window.session.link(ticket, "Smoke Chromium"), [ticket]);
  if (linkedAccount !== account) throw new Error(`linked to ${linkedAccount}, expected account ${account}`);
  if ((await peer.line("ENROLLED ")) !== deviceId) throw new Error("primary enrolled a different device id");
  step("tab linked as a seedless device; grant verified in the browser; account id matches");

  // Primary → tab: the primary posts after enrolling and hands over its sync bundle.
  await peer.line("SENT");
  await page.waitForFunction(() => JSON.parse(window.session.feed("default")).some((p) => p.body === "hello from the primary"), null, { timeout: 30000 });
  const fromPrimary = await page.evaluate(() => JSON.parse(window.session.feed("default")).find((p) => p.body === "hello from the primary"));
  if (!fromPrimary.isMe) throw new Error("the primary's post should read as this account's own in the tab");
  step("tab opened the primary's sealed post (same account → isMe)");

  // Tab → primary: authored by a device that holds no account key, attributed to the account.
  await page.evaluate(() => window.session.post("default", "hello from the browser"));
  const deadline = Date.now() + 30000;
  while (!peer.lines.includes("FEED me hello from the browser")) {
    if (Date.now() > deadline) throw new Error(`primary never showed the tab's post (saw: ${peer.lines.slice(-12).join(" | ")})`);
    await new Promise((r) => setTimeout(r, 100));
  }
  step("primary opened the tab's sealed post, attributed to the account");

  const feed = await page.evaluate(() => JSON.parse(window.session.feed("default")).map((p) => p.body));
  for (const body of ["hello from the primary", "hello from the browser"]) {
    if (!feed.includes(body)) throw new Error(`tab feed is missing "${body}": ${JSON.stringify(feed)}`);
  }
  step("both posts are in the tab's feed");

  // Negative: a grant with one flipped byte must not link a tab. Anyone who can reach a linking
  // node can send it frame 29, so a bad one is ignored and the tab keeps waiting, unlinked.
  const bad = startPeer(process.argv[2], ["127.0.0.1:0", "tamper"]);
  onExit(() => bad.kill());
  const badDerp = await bad.line("DERP=");
  const badTicket = await bad.line("TICKET=");
  await page.evaluate(async ([derp, ticket]) => {
    window.victim = await window.haven.WebSession.start(window.haven.generateDeviceSeed(), derp, () => {});
    window.victimLinked = null;
    window.victim.link(ticket, "Smoke victim").then(() => (window.victimLinked = true), () => (window.victimLinked = false));
  }, [badDerp, badTicket]);
  await bad.line("TAMPERED-GRANT-SENT ");
  await new Promise((r) => setTimeout(r, 2000));
  const victim = await page.evaluate(() => ({ settled: window.victimLinked, linked: window.victim.isLinked() }));
  if (victim.linked || victim.settled === true) throw new Error(`a tampered grant linked the tab: ${JSON.stringify(victim)}`);
  step("a tampered grant is refused; the tab stays unlinked");
});
