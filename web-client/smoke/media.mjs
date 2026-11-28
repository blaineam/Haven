// The media half of the browser smoke (run from engine.mjs once the page is linked): what a person
// does with photos, videos, stories and songs, in a real browser, under the page's real security
// policy. Each check is something the web client got wrong in front of its owner on 2026-11-27.
import { CLIP_MP4, CLIP_WEBM } from "./clips.mjs";

const SONG_URL = "https://audio-ssl.itunes.apple.com/haven-smoke.wav";

/** A second of silence as a WAV file. */
function wav(seconds = 1) {
  const rate = 8000, n = rate * seconds, b = Buffer.alloc(44 + n, 128);
  b.write("RIFF", 0); b.writeUInt32LE(36 + n, 4); b.write("WAVEfmt ", 8);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(rate, 24); b.writeUInt32LE(rate, 28); b.writeUInt16LE(1, 32); b.writeUInt16LE(8, 34);
  b.write("data", 36); b.writeUInt32LE(n, 40);
  return b;
}

/** Before the page's scripts: note every policy violation and every attempt to play something,
 *  and answer Apple's two addresses here, so no run depends on them. */
export async function watchMedia(page) {
  await page.addInitScript(() => {
    window.__violations = [];
    window.__plays = [];
    document.addEventListener("securitypolicyviolation", (e) => window.__violations.push(`${e.violatedDirective} ${String(e.blockedURI).slice(0, 40)}`));
    const play = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function () {
      const entry = { src: this.src, el: this, state: "asked" };
      window.__plays.push(entry);
      const p = play.call(this);
      p?.then(() => { entry.state = "playing"; }, (e) => { entry.state = e.name; });
      return p;
    };
  });
  const cors = { "access-control-allow-origin": "*" };
  await page.route("https://itunes.apple.com/**", (route) => route.fulfill({
    headers: cors, contentType: "application/json",
    body: JSON.stringify({ results: [{ trackName: "Smoke Song", artistName: "The Harness", previewUrl: SONG_URL, trackViewUrl: "https://music.apple.com/us/album/x/1?i=2", artworkUrl100: "" }] }),
  }));
  await page.route(SONG_URL, (route) => route.fulfill({ headers: cors, contentType: "audio/wav", body: wav() }));
}

export async function mediaChecks({ page, invoke, until, step }) {
  const add = (dataBase64, isVideo) => invoke(page, "add_media", { circleId: "", dataBase64, isVideo });
  const post = (body, media, music = null) => invoke(page, "post", { circleId: "", body, media, music });
  /** A distinct picture per call, drawn by the browser itself. */
  const picture = (n) => page.evaluate((n) => {
    const c = document.createElement("canvas");
    c.width = 320; c.height = 240;
    const g = c.getContext("2d");
    g.fillStyle = `hsl(${(n * 47) % 360} 70% 45%)`; g.fillRect(0, 0, 320, 240);
    g.fillStyle = "#fff"; g.font = "80px sans-serif"; g.fillText(String(n), 130, 150);
    return c.toDataURL("image/jpeg", 0.8).split(",")[1];
  }, n);
  const pictures = async (from, count) => {
    const refs = [];
    for (let i = 0; i < count; i++) refs.push(await add(await picture(from + i), false));
    return refs;
  };
  /** In the page: the post card on the visible tab whose text holds `body`. */
  const inCard = (body, fn, arg) => page.evaluate(([body, fn, arg]) => {
    const card = [...document.querySelectorAll("#view-you [data-post]")].find((c) => c.innerText.includes(body));
    if (!card) return null;
    card.scrollIntoView({ block: "center" });
    return (0, eval)(fn)(card, arg);
  }, [body, fn.toString(), arg]);
  await page.locator('.tab[data-view="you"]').click();

  // ── Video and voice notes ───────────────────────────────────────────────────────────────────
  const h264 = await page.evaluate(() => !!document.createElement("video").canPlayType('video/mp4; codecs="avc1.42E01E"'));
  const clip = await add(h264 ? CLIP_MP4 : CLIP_WEBM, true);
  await post("a clip in the browser", [clip]);
  await until("the clip to be playable", () => inCard("a clip in the browser", (card) => {
    const v = card.querySelector("video");
    return v && v.src.startsWith("blob:") && v.videoWidth === 96 && !v.error ? v.src : null;
  }));
  step("a video plays from a blob: URL under the page's policy (a data: URL is refused)");

  const note = await invoke(page, "add_audio", { circleId: "", dataBase64: wav(2).toString("base64") });
  await post("a voice note in the browser", [note]);
  await until("the voice note to be playable", () => inCard("a voice note in the browser", (card) => {
    const a = card.querySelector("audio");
    return a && a.src.startsWith("blob:") && a.duration > 1.5 ? true : null;
  }));
  step("a voice note loads and knows its length");

  // ── Carousel: buttons, and its place survives a redraw ──────────────────────────────────────
  await post("three photos", await pictures(1, 3));
  const onDot = () => inCard("three photos", (card) => [...card.querySelectorAll(".carousel-dots i")].findIndex((d) => d.classList.contains("on")));
  await until("the carousel", async () => (await onDot()) === 0);
  await inCard("three photos", (card) => card.querySelector(".carousel-arrow.next").click());
  await until("the second photo", async () => (await onDot()) === 1);
  await post("something else arrives", []);
  await until("the redraw", () => page.evaluate(() => document.querySelector("#view-you").innerText.includes("something else arrives")));
  await page.waitForTimeout(600);
  if ((await onDot()) !== 1) throw new Error(`a redraw moved the carousel to photo ${(await onDot()) + 1}`);
  step("a carousel pages by its buttons and stays on its photo when the page redraws");

  // ── The grid opens a full-window viewer ─────────────────────────────────────────────────────
  await post("eleven photos", await pictures(20, 11));
  await until("the grid's third tile", () => inCard("eleven photos", (card) => card.querySelectorAll(".post-media.masonry img[src]").length >= 3 || null));
  await inCard("eleven photos", (card) => card.querySelectorAll(".post-media.masonry img")[2].click());
  const counter = () => page.evaluate(() => document.querySelector(".media-viewer .viewer-count")?.textContent || null);
  await until("the viewer on the third photo", async () => (await counter()) === "3 / 11");
  await until("that photo, large", () => page.evaluate(() => {
    const img = document.querySelectorAll(".media-viewer .viewer-slide")[2]?.querySelector("img");
    return img && img.naturalWidth === 320 && img.getBoundingClientRect().width > 200 ? true : null;
  }));
  await page.keyboard.press("ArrowRight");
  await until("the fourth photo", async () => (await counter()) === "4 / 11");
  await page.evaluate(() => { const t = document.querySelector(".viewer-track"); t.scrollLeft = 6 * t.clientWidth; });
  await until("a scroll (a swipe) to move the viewer", async () => (await counter()) === "7 / 11");
  await page.keyboard.press("Escape");
  await until("the viewer to close", () => page.evaluate(() => !document.querySelector(".media-viewer") || null));
  step("a grid tile opens a full-window viewer that pages by keys and by swiping, and closes");

  // ── Stories: media loads; a trackpad swipe and a mouse drag both move ───────────────────────
  for (const ref of await pictures(50, 3)) await invoke(page, "post_story", { body: "", media: ref });
  await page.locator("#view-you .card .story-ring.cover").first().waitFor({ timeout: 30000 });
  await until("three story rings with pictures", () => page.evaluate(() => document.querySelectorAll("#view-you .card .story-ring.cover img[src]").length >= 3 || null));
  await page.evaluate(() => { document.querySelector("#view-you").scrollTop = 0; });
  await page.locator("#view-you .card .story-ring.cover").first().click();
  const at = () => page.evaluate(() => document.querySelectorAll(".story-progress .seg.on").length);
  await until("the story's picture", () => page.evaluate(() => (document.querySelector(".story-canvas img[data-ref]")?.naturalWidth === 320) || null));
  const first = await at();
  await page.evaluate(() => document.querySelector(".story-stage").dispatchEvent(new WheelEvent("wheel", { deltaX: 200, bubbles: true, cancelable: true })));
  await until("a trackpad swipe to move one story", async () => (await at()) === first + 1);
  await page.waitForTimeout(400); // the swipe's momentum has died down
  const box = await page.locator(".story-canvas").boundingBox();
  const y = box.y + box.height * 0.45;
  await page.mouse.move(box.x + box.width * 0.25, y);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width * 0.8, y, { steps: 8 });
  await page.mouse.up();
  await until("a mouse drag to move back", async () => (await at()) === first);
  await page.keyboard.press("Escape");
  step("stories show their media and move by trackpad swipe and by mouse drag");

  // ── A post's song ───────────────────────────────────────────────────────────────────────────
  await post("a post with a song", await pictures(70, 1), { catalog_id: "", title: "Smoke Song", artist: "The Harness" });
  await until("the song's chip", () => inCard("a post with a song", (card) => !!card.querySelector(".song-sound") || null));
  await page.waitForTimeout(500);
  const heard = () => page.evaluate((url) => window.__plays.some((p) => p.src === url && p.state === "playing" && !p.el.paused), SONG_URL);
  if (await heard()) throw new Error("a song played before sound was turned on");
  await inCard("a post with a song", (card) => card.querySelector(".song-sound").click());
  await until("the song to play once sound is on", async () => {
    await inCard("a post with a song", () => true); // keep it centred
    return (await heard()) || null;
  }, 30000);
  await inCard("a post with a song", (card) => card.querySelector(".song-sound").click());
  await until("the song to stop with sound off", async () => !(await heard()) || null, 15000);
  step("a post's song plays when sound is turned on, from Apple's preview, and stops with it");

  const violations = await page.evaluate(() => window.__violations);
  if (violations.length) throw new Error(`the page's security policy refused: ${[...new Set(violations)].join(" | ")}`);
  step("nothing on the page was refused by its security policy");
}
