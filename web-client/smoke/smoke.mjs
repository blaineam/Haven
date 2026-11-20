// Browser-transport smoke: a relay-only Haven node in headless Chromium against the real native
// wire (core/haven-net/examples/web_peer.rs — a circle DERP plus one ordinary Haven node).
//
//   web-client/build.sh
//   cargo build -p haven-net --example web_peer
//   node web-client/smoke/smoke.mjs core/target/debug/examples/web_peer
//
// Proves, in a real browser: the engine's self-test passes in wasm; the tab registers on the
// circle's relay; the tab can DIAL a native node and get its echo; a native node can DIAL the tab.
import { openPage, run } from "./harness.mjs";

await run("smoke.mjs <web_peer binary>", async ({ site, peer, step, onExit }) => {
  const derp = await peer.line("DERP=");
  const nativeId = await peer.line("NODE=");

  const { browser, page } = await openPage(site.url);
  onExit(() => browser.close());

  if (!(await page.evaluate(() => window.haven.engineSelfTest()))) throw new Error("engine self-test failed in the browser");
  step("engine self-test passes in wasm");

  const header = await page.evaluate(() => {
    const seed = window.haven.generateDeviceSeed();
    return window.haven.httpAuthHeader(seed, "tok", "GET", "haven/x", new Uint8Array());
  });
  if (!/^Haven [0-9a-f]{64}\.\d+\.[0-9a-f]{32}\.[0-9a-f]{64}\.[0-9a-f]{128}$/.test(header)) throw new Error(`bad auth header: ${header}`);
  step("signed mailbox header is well-formed");

  const webId = await page.evaluate(async (derp) => {
    window.inbox = [];
    const seed = window.haven.generateDeviceSeed();
    window.node = await window.haven.WebNode.spawn(seed, derp, (from, bytes) => {
      window.inbox.push({ from, text: new TextDecoder().decode(bytes) });
    });
    await window.node.online();
    return window.node.nodeIdHex();
  }, derp);
  step(`browser node online via ${derp} as ${webId.slice(0, 12)}…`);

  // Native dials the tab FIRST — before the tab has ever dialed out — so this is a true inbound.
  peer.write(webId + "\n");
  await page.waitForFunction(() => window.inbox.some((m) => m.text === "hello-from-native"), null, { timeout: 30000 });
  const inboundFrom = await page.evaluate(() => window.inbox.find((m) => m.text === "hello-from-native").from);
  if (inboundFrom !== nativeId) throw new Error(`inbound frame attributed to ${inboundFrom}, expected ${nativeId}`);
  await peer.line("DIALED ");
  step("native node dialed the tab; sender id authenticated");

  await page.evaluate(async (id) => {
    await window.node.sendToNode(id, new TextEncoder().encode("hello-from-browser"));
  }, nativeId);
  await page.waitForFunction(() => window.inbox.some((m) => m.text === "echo:hello-from-browser"), null, { timeout: 30000 });
  const got = await peer.line(`RECV from=${webId}`);
  if (!got.includes("bytes=18")) throw new Error(`native saw unexpected frame: ${got}`);
  step("tab → native frame delivered and echoed back");

  // A second tab-side node dialing OUT cold (no prior connection in either direction).
  const echoed = await page.evaluate(async ([derp, id]) => {
    const inbox = [];
    const n = await window.haven.WebNode.spawn(window.haven.generateDeviceSeed(), derp, (from, bytes) => inbox.push(new TextDecoder().decode(bytes)));
    await n.online();
    await n.sendToNode(id, new TextEncoder().encode("cold-dial"));
    for (let i = 0; i < 300 && !inbox.includes("echo:cold-dial"); i++) await new Promise((r) => setTimeout(r, 100));
    await n.close();
    return inbox;
  }, [derp, nativeId]);
  if (!echoed.includes("echo:cold-dial")) throw new Error(`cold dial got no echo: ${JSON.stringify(echoed)}`);
  step("tab cold-dialed a native node through the relay");

  const big = await page.evaluate(async (id) => {
    const payload = new Uint8Array(2 * 1024 * 1024);
    for (let i = 0; i < payload.length; i++) payload[i] = i % 251;
    const before = window.inbox.length;
    await window.node.sendToNode(id, payload);
    for (let i = 0; i < 600 && window.inbox.length === before; i++) await new Promise((r) => setTimeout(r, 100));
    return window.inbox.length - before;
  }, nativeId);
  if (big !== 1) throw new Error("2 MiB frame was not echoed");
  await peer.line(`RECV from=${webId} bytes=2097152`);
  step("2 MiB frame round-trips");
});
