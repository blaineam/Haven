// Haven desktop frontend. Talks to the Rust backend (which links the shared core) via
// Tauri `invoke`. No framework — small DOM helpers + per-view render functions, re-rendered
// when the backend emits `haven:changed`.

const TAURI = window.__TAURI__ || {};
const invoke = TAURI.core ? TAURI.core.invoke : async () => { throw new Error("Tauri not ready"); };
const listen = TAURI.event ? TAURI.event.listen : async () => {};

// ---- tiny helpers ----------------------------------------------------------------------
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
const el = (tag, props = {}, ...kids) => {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === "class") e.className = v;
    else if (k === "html") e.innerHTML = v;
    else if (k.startsWith("on") && typeof v === "function") e.addEventListener(k.slice(2), v);
    else if (v !== null && v !== undefined) e.setAttribute(k, v);
  }
  for (const kid of kids.flat()) {
    if (kid == null) continue;
    e.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  return e;
};
const esc = (s) => (s || "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function toast(msg) {
  const t = $("#toast");
  t.textContent = msg;
  t.classList.add("show");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.remove("show"), 2200);
}

function relTime(ms) {
  const n = Number(ms);
  if (!n) return "";
  const diff = Date.now() - n;
  const s = Math.floor(diff / 1000);
  if (s < 60) return "just now";
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h`;
  const d = Math.floor(h / 24);
  if (d < 7) return `${d}d`;
  return new Date(n).toLocaleDateString();
}

function initials(name) {
  const p = (name || "").trim().split(/\s+/);
  if (!p[0]) return "·";
  return (p[0][0] + (p[1] ? p[1][0] : "")).toUpperCase();
}

function modal(node) {
  const root = $("#modal-root");
  const backdrop = el("div", { class: "modal-backdrop", onclick: (e) => { if (e.target === backdrop) root.replaceChildren(); } }, node);
  node.classList.add("modal");
  root.replaceChildren(backdrop);
  return () => root.replaceChildren();
}

// Decrypt + lazy-load a media ref into an <img>/<video>.
async function loadMedia(node, circleId, ref) {
  try {
    const url = await invoke("media_data_url", { circleId, reference: ref });
    if (url) node.src = url;
    else node.replaceWith(el("div", { class: "tag" }, "media syncing…"));
  } catch (_) {}
}

// ---- app state -------------------------------------------------------------------------
const state = {
  view: "feed",
  node: "",
  inviteUri: "",
  inviteLink: "",
  profile: {},
  activeCircle: "default",
  activeDm: null,
  attachments: [], // {ref, url, isVideo}
};

// ---- navigation ------------------------------------------------------------------------
function switchView(view) {
  state.view = view;
  $$(".nav-btn").forEach((b) => b.classList.toggle("active", b.dataset.view === view));
  $$(".view").forEach((v) => v.classList.toggle("active", v.id === `view-${view}`));
  render();
}

async function render() {
  switch (state.view) {
    case "feed": return renderFeed();
    case "stories": return renderStories();
    case "messages": return renderMessages();
    case "connect": return renderConnect();
    case "relay": return renderRelay();
    case "you": return renderYou();
  }
}

async function refreshBadges() {
  try {
    const pend = await invoke("pending");
    const b = $("#badge-pending");
    b.textContent = pend.length;
    b.classList.toggle("show", pend.length > 0);
  } catch (_) {}
  try {
    const dms = await invoke("dm_threads");
    const b = $("#badge-messages");
    b.textContent = dms.length;
    b.classList.toggle("show", dms.length > 0);
  } catch (_) {}
}

async function refreshStatus() {
  try {
    const s = await invoke("relay_status");
    const dot = $("#status-dot");
    const txt = $("#status-text");
    dot.classList.toggle("on", s.started);
    dot.classList.toggle("relay", s.hosting);
    txt.textContent = s.hosting ? "relaying" : s.started ? (s.internet_active ? "connected" : "online") : "starting…";
  } catch (_) {}
}

// ---- Pinned conversations --------------------------------------------------------------
// Up to 6 pinned DM circle ids, kept at the top of the Messages list (iMessage-style). Order in the
// array is pin order; persisted so pins survive relaunch. Mirrors iOS `DMPinStore`.
const Pins = {
  MAX: 6,
  ids: JSON.parse(localStorage.getItem("haven-dm-pinned") || "[]"),
  has(id) { return this.ids.includes(id); },
  get full() { return this.ids.length >= this.MAX; },
  toggle(id) {
    const i = this.ids.indexOf(id);
    if (i >= 0) this.ids.splice(i, 1);
    else if (this.ids.length < this.MAX) this.ids.push(id);
    this._save();
  },
  remove(id) {
    const i = this.ids.indexOf(id);
    if (i >= 0) { this.ids.splice(i, 1); this._save(); }
  },
  _save() { localStorage.setItem("haven-dm-pinned", JSON.stringify(this.ids)); },
};

// ---- Feed ------------------------------------------------------------------------------
// Posts the user hid from their own feed — local + per-device, never touches the circle/relay.
const Hidden = {
  ids: new Set(JSON.parse(localStorage.getItem("haven-hidden") || "[]")),
  showHidden: false,
  has(id) { return this.ids.has(id); },
  hide(id) { this.ids.add(id); this._save(); },
  unhide(id) { this.ids.delete(id); this._save(); },
  toggle() { this.showHidden = !this.showHidden; },
  _save() { localStorage.setItem("haven-hidden", JSON.stringify([...this.ids])); },
};

async function renderFeed() {
  const root = $("#view-feed");
  const circles = await invoke("circles");
  if (!circles.find((c) => c.id === state.activeCircle)) state.activeCircle = "default";

  const head = el("div", { class: "view-head" },
    el("h1", {}, "Feed"),
    el("div", { class: "spacer" }),
    (() => {
      const sel = el("select", { style: "width:auto", onchange: (e) => { state.activeCircle = e.target.value; renderFeed(); } });
      for (const c of circles) sel.append(el("option", { value: c.id, selected: c.id === state.activeCircle || null }, `${c.name} (${c.member_count})`));
      return sel;
    })(),
    el("button", { class: "btn small", onclick: newCircleDialog }, "+ Circle"),
    el("button", { class: "btn small ghost", title: "Manage circle", onclick: () => manageCircleDialog(circles.find((c) => c.id === state.activeCircle)) }, "⚙︎"),
    Hidden.ids.size ? el("button", { class: "btn small ghost", title: "Show/hide hidden posts", onclick: () => { Hidden.toggle(); renderFeed(); } },
      Hidden.showHidden ? "🙈 Hide hidden" : `👁 Show hidden (${Hidden.ids.size})`) : null,
    el("button", { class: "btn small ghost", title: "Mute/unmute all videos", onclick: async () => {
      state.videoSoundOn = !state.videoSoundOn;
      await invoke("set_video_sound", { on: state.videoSoundOn }).catch(() => {});
      syncFeedVideoSound();
      renderFeed();
    } }, state.videoSoundOn ? "🔊" : "🔇"),
  );

  const composer = buildComposer(
    (body, music, muteVideo) => invoke("post", { circleId: state.activeCircle, body, media: state.attachments.map((a) => a.ref), music, muteVideo }),
    "Share something with your circle…",
    {
      circleId: state.activeCircle,
      onSchedule: (body, music, muteVideo, sendAtMs) => invoke("schedule_message", { kind: "post", circleId: state.activeCircle, body, media: state.attachments.map((a) => a.ref), music, muteVideo, sendAtMs }),
    },
  );

  const items = (await invoke("feed", { circleId: state.activeCircle }))
    .filter((i) => !i.story)
    .filter((i) => Hidden.showHidden || !Hidden.has(i.id));   // personal per-post hide (reversible)
  const list = el("div", {});
  if (!items.length) list.append(el("div", { class: "empty" }, "No posts yet. Say hello to your circle, or connect a friend."));
  for (const it of items) list.append(postCard(it, state.activeCircle));

  root.replaceChildren(head, composer, list);
  hydrateMedia(root, state.activeCircle);
}

function buildComposer(onPost, placeholder = "Share something with your circle…", opts = {}) {
  const circleId = opts.circleId || state.activeCircle;
  let music = null;
  let muteVideo = false;
  const ta = el("textarea", { placeholder });
  const previews = el("div", { class: "attach-preview" });
  const musicRow = el("div", {});
  const muteBtn = el("button", { class: "btn small ghost", style: "display:none", onclick: () => { muteVideo = !muteVideo; muteBtn.textContent = muteVideo ? "🔇 Video muted" : "🔊 Mute video"; muteBtn.classList.toggle("primary", muteVideo); } }, "🔊 Mute video");
  const drawPreviews = () => {
    previews.replaceChildren(...state.attachments.map((a, i) =>
      el("div", { class: "chip" },
        a.isAudio ? el("div", { style: "width:74px;height:74px;border-radius:11px;background:var(--panel2);display:flex;align-items:center;justify-content:center;font-size:26px" }, "🎙️")
          : a.isVideo ? el("video", { src: a.url, muted: "" }) : el("img", { src: a.url }),
        el("span", { class: "x", onclick: () => { state.attachments.splice(i, 1); drawPreviews(); } }, "×"),
      )));
    const hasVideo = state.attachments.some((a) => a.isVideo);
    muteBtn.style.display = hasVideo ? "" : "none";
    if (!hasVideo) { muteVideo = false; muteBtn.textContent = "🔊 Mute video"; muteBtn.classList.remove("primary"); }
  };
  const addAttachment = async (ref, isVideo, isAudio) => {
    const url = isAudio ? null : await invoke("media_data_url", { circleId, reference: ref }).catch(() => null);
    state.attachments.push({ ref, url, isVideo, isAudio });
    drawPreviews();
  };
  // Expose the active composer's attach fn so dropped files (handled globally) land here.
  state.composerAdd = addAttachment;
  state.composerCircle = circleId;
  const drawMusic = () => {
    musicRow.replaceChildren(music
      ? el("div", { class: "song-chip", style: "margin-top:0" },
          el("span", { class: "note" }, "🎵"),
          el("div", { style: "flex:1;min-width:0" }, el("strong", {}, music.title), " — ", music.artist),
          el("span", { class: "x", style: "position:static;cursor:pointer", onclick: () => { music = null; drawMusic(); } }, "×"))
      : null);
  };
  const fileInput = el("input", { type: "file", accept: "image/*,video/*", style: "display:none", onchange: (e) => handleFiles(e.target.files, drawPreviews) });
  // Reachability light: can this circle's posts actually reach offline members right now?
  const syncDot = el("span", { title: "Reachability", style: "width:9px;height:9px;border-radius:50%;display:inline-block;align-self:center;margin-right:4px;background:#22C55E" });
  const syncLabel = el("span", { class: "muted small", style: "align-self:center;margin-right:6px" }, "");
  const refreshSync = async () => {
    const s = await invoke("sync_status", { circleId }).catch(() => "synced");
    if (s === "local") { syncDot.style.background = "#EF4444"; syncLabel.textContent = "Device only"; }
    else if (s === "syncing") { syncDot.style.background = "#F59E0B"; syncLabel.textContent = "Syncing"; }
    else { syncDot.style.background = "#22C55E"; syncLabel.textContent = ""; }
  };
  if (state.syncTimer) clearInterval(state.syncTimer);   // only one composer at a time — no leak across re-renders
  refreshSync();
  state.syncTimer = setInterval(refreshSync, 2500);
  const card = el("div", { class: "card col" },
    ta,
    previews,
    musicRow,
    el("div", { class: "row wrap" },
      el("button", { class: "btn small ghost", onclick: () => fileInput.click() }, "📎 Photo / Video"),
      el("button", { class: "btn small ghost", onclick: async () => { const r = await cameraDialog(circleId); if (r) addAttachment(r.ref, r.isVideo, false); } }, "📷 Camera"),
      el("button", { class: "btn small ghost", onclick: async () => { const r = await recordVoice(circleId); if (r) addAttachment(r, false, true); } }, "🎙️ Voice"),
      el("button", { class: "btn small ghost", onclick: () => musicDialog((m) => { music = m; drawMusic(); }) }, "🎵 Music"),
      muteBtn,
      el("div", { class: "spacer", style: "flex:1" }),
      syncDot, syncLabel,
      opts.onSchedule ? el("button", { class: "btn small ghost", title: "Send later", onclick: () => {
        const body = ta.value.trim();
        if (!body && !state.attachments.length && !music) { toast("Write something first"); return; }
        scheduleDialog((ms) => {
          opts.onSchedule(body, music, muteVideo, ms);
          ta.value = ""; state.attachments = []; music = null; muteVideo = false; drawPreviews(); drawMusic();
          toast("Scheduled");
        });
      } }, "🕓") : null,
      el("button", {
        class: "btn primary", onclick: async () => {
          const body = ta.value.trim();
          if (!body && !state.attachments.length && !music) return;
          await onPost(body, music, muteVideo);
          ta.value = "";
          state.attachments = [];
          music = null;
          muteVideo = false;
          drawPreviews();
          drawMusic();
          toast("Posted");
        }
      }, "Post"),
    ),
    fileInput,
  );
  return card;
}

// Open a URL in the user's browser (Tauri opener plugin, falling back to window.open).
function openExternal(url) {
  try {
    if (TAURI.opener && TAURI.opener.openUrl) return TAURI.opener.openUrl(url);
    if (TAURI.shell && TAURI.shell.open) return TAURI.shell.open(url);
  } catch (_) {}
  window.open(url, "_blank");
}

// Attach a song as a portable music reference: paste a streaming link (Apple Music / Spotify /
// YouTube / etc.) + title + artist. Viewers tap the chip to open it in their own player — the
// portable model the Android/desktop redesign uses where there's no universal catalog API.
function musicDialog(onPick) {
  const link = el("input", { placeholder: "Paste a song link (Apple Music, Spotify, YouTube…)" });
  const title = el("input", { placeholder: "Title" });
  const artist = el("input", { placeholder: "Artist" });
  modal(el("div", {},
    el("h2", {}, "Attach a song"),
    el("div", { class: "col" },
      link, el("div", { class: "row" }, title, artist),
      el("div", { class: "muted small" }, "The link opens in your friend's own music app."),
      el("div", { class: "row", style: "justify-content:flex-end" },
        el("button", { class: "btn primary", onclick: () => {
          const catalog_id = link.value.trim();
          if (!catalog_id || !title.value.trim()) { toast("Add a link and a title"); return; }
          onPick({ catalog_id, title: title.value.trim(), artist: artist.value.trim() || "Unknown artist" });
          $("#modal-root").replaceChildren();
        } }, "Attach")))));
}

// Secret-message marker — byte-identical to iOS SecretMessages.marker ("\u{2}").
const SECRET_MARKER = "";
const isSecret = (b) => (b || "").startsWith(SECRET_MARKER);
const secretText = (b) => (isSecret(b) ? b.slice(1) : b);

function blobToBase64(blob) {
  return new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(r.result.split(",")[1]); r.onerror = rej; r.readAsDataURL(blob); });
}

// Render a media ref as the right element: video (v:), voice note (a:), or image.
// A shared location is a synthetic `geo:<lat>,<lon>,<label>` ref stuffed into a post's media array
// (iOS/Android parity). It isn't real media — rendering it through the image loader produced a
// forever-spinner tile. Parse it out and show a map link instead. Returns {lat, lon, label} or null.
function parseGeo(ref) {
  if (typeof ref !== "string" || !ref.startsWith("geo:")) return null;
  const rest = ref.slice(4);
  const comma1 = rest.indexOf(",");
  if (comma1 < 0) return null;
  const comma2 = rest.indexOf(",", comma1 + 1);
  const lat = parseFloat(rest.slice(0, comma1));
  const lon = parseFloat(rest.slice(comma1 + 1, comma2 < 0 ? rest.length : comma2));
  if (!isFinite(lat) || !isFinite(lon)) return null;
  const label = comma2 < 0 ? "" : rest.slice(comma2 + 1);
  return { lat, lon, label };
}

// Render a location ref as a tappable map chip (opens the OS maps / browser). Kept OUT of the photo
// grid so a photo+location post doesn't fall into the masonry path with a broken tile.
function geoChip(geo) {
  const text = geo.label && geo.label.trim() ? geo.label : `${geo.lat.toFixed(4)}, ${geo.lon.toFixed(4)}`;
  return el("button", {
    class: "song-chip",
    title: "Open in maps",
    onclick: () => openExternal(`https://www.openstreetmap.org/?mlat=${geo.lat}&mlon=${geo.lon}#map=15/${geo.lat}/${geo.lon}`),
  }, el("span", { class: "note" }, "📍"), el("strong", {}, text));
}

function mediaNode(ref, imgStyle) {
  // Videos start muted unless the global "play video sound" toggle is on (iOS parity); native controls
  // still let the user override per-video. data-video lets the toggle re-apply across all of them.
  // While a call is ringing/connecting/live they render muted regardless (call audio priority).
  if (ref.startsWith("v:")) return el("video", Object.assign({ "data-ref": ref, "data-video": "1", controls: "" }, state.videoSoundOn && !callAudioActive() ? {} : { muted: "" }));
  if (ref.startsWith("a:")) return el("audio", { "data-ref": ref, controls: "", style: "width:100%;margin-top:6px;display:block" });
  return el("img", Object.assign({ "data-ref": ref, loading: "lazy" }, imgStyle ? { style: imgStyle } : {}));
}

// A concealed secret bubble: tap to reveal, auto-conceals after 5s. (Webviews can't truly block
// screenshots like iOS/Android, so this is conceal-on-idle only — documented best-effort.)
function secretBubble(body, isMe) {
  const text = secretText(body);
  const wrap = el("div", { class: "chat-bubble secret" + (isMe ? " me" : "") });
  let revealed = false, t;
  const draw = () => {
    wrap.replaceChildren(revealed
      ? el("span", {}, text)
      : el("span", { class: "muted" }, "🔒 Tap to reveal"));
  };
  wrap.addEventListener("click", () => {
    revealed = !revealed; draw();
    clearTimeout(t);
    if (revealed) t = setTimeout(() => { revealed = false; draw(); }, 5000);
  });
  draw();
  return wrap;
}

// Record a voice note → returns an `a:` media ref (or null if cancelled).
function recordVoice(circleId) {
  return new Promise((resolve) => {
    let recorder, chunks = [], stream, timer, secs = 0, done = false;
    const timeEl = el("div", { style: "font-size:30px;text-align:center;margin:6px 0" }, "0:00");
    const status = el("div", { class: "muted small", style: "text-align:center" }, "Tap record to start");
    const recBtn = el("button", { class: "btn primary" }, "● Record");
    const stopBtn = el("button", { class: "btn danger", style: "display:none" }, "■ Stop & attach");
    const finish = (ref) => { if (done) return; done = true; clearInterval(timer); if (stream) stream.getTracks().forEach((t) => t.stop()); $("#modal-root").replaceChildren(); resolve(ref); };
    recBtn.onclick = async () => {
      try { stream = await navigator.mediaDevices.getUserMedia({ audio: true }); }
      catch (e) { toast("Mic unavailable: " + e); return; }
      recorder = new MediaRecorder(stream);
      recorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
      recorder.onstop = async () => {
        const blob = new Blob(chunks, { type: recorder.mimeType || "audio/webm" });
        try { const ref = await invoke("add_audio", { circleId, dataBase64: await blobToBase64(blob) }); finish(ref); }
        catch (e) { toast("Couldn't save: " + e); finish(null); }
      };
      recorder.start();
      recBtn.style.display = "none"; stopBtn.style.display = ""; status.textContent = "Recording…";
      timer = setInterval(() => { secs++; timeEl.textContent = `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, "0")}`; }, 1000);
    };
    stopBtn.onclick = () => { if (recorder && recorder.state !== "inactive") recorder.stop(); };
    modal(el("div", {}, el("h2", {}, "🎙️ Voice message"), timeEl, status,
      el("div", { class: "row", style: "justify-content:center;margin-top:12px" }, recBtn, stopBtn,
        el("button", { class: "btn ghost", onclick: () => finish(null) }, "Cancel"))));
  });
}

// The 6 Haven capture filters (parity with iOS MediaFilters), as CSS filter strings.
const CAMERA_FILTERS = [
  { name: "Original", css: "" },
  { name: "Warmth", css: "sepia(0.25) saturate(1.35) hue-rotate(-10deg) brightness(1.03)" },
  { name: "Cool", css: "saturate(1.1) hue-rotate(14deg) brightness(1.05)" },
  { name: "Sepia", css: "sepia(0.7) contrast(1.05)" },
  { name: "Noir", css: "grayscale(1) contrast(1.25) brightness(1.05)" },
  { name: "Vivid", css: "saturate(1.7) contrast(1.12)" },
];

// In-app camera: live preview, a filter strip, photo capture (filter baked into the JPEG) and
// short video recording. Returns {ref, isVideo} or null.
function cameraDialog(circleId) {
  return new Promise((resolve) => {
    let stream, recorder, chunks = [], recording = false, done = false, filter = CAMERA_FILTERS[0], rafId, recStream;
    const video = el("video", { autoplay: "", muted: "", playsinline: "", style: "width:100%;border-radius:14px;background:#000;max-height:48vh" });
    const strip = el("div", { class: "row wrap", style: "gap:6px;margin-top:8px" });
    const setFilter = (f) => { filter = f; video.style.filter = f.css; [...strip.children].forEach((b) => b.classList.toggle("primary", b.textContent === f.name)); };
    CAMERA_FILTERS.forEach((f) => strip.append(el("button", { class: "btn small", onclick: () => setFilter(f) }, f.name)));
    const finish = (out) => { if (done) return; done = true; if (rafId) cancelAnimationFrame(rafId); if (recStream) recStream.getTracks().forEach((t) => t.stop()); if (stream) stream.getTracks().forEach((t) => t.stop()); $("#modal-root").replaceChildren(); resolve(out); };
    const shoot = el("button", { class: "btn primary", onclick: async () => {
      const c = document.createElement("canvas"); c.width = video.videoWidth || 1280; c.height = video.videoHeight || 720;
      const ctx = c.getContext("2d"); ctx.filter = filter.css || "none"; ctx.drawImage(video, 0, 0, c.width, c.height);
      const b64 = c.toDataURL("image/jpeg", 0.85).split(",")[1];
      try { const ref = await invoke("add_media", { circleId, dataBase64: b64, isVideo: false }); finish({ ref, isVideo: false }); }
      catch (e) { toast("Capture failed: " + e); }
    } }, "📸 Capture");
    const recBtn = el("button", { class: "btn", onclick: () => {
      if (!recording) {
        // Record a *filtered* canvas (the selected filter is drawn into every frame) plus the
        // mic audio, so the chosen filter is baked into the saved video — not just the preview.
        const c = document.createElement("canvas");
        c.width = video.videoWidth || 1280; c.height = video.videoHeight || 720;
        const ctx = c.getContext("2d");
        const draw = () => { ctx.filter = filter.css || "none"; ctx.drawImage(video, 0, 0, c.width, c.height); rafId = requestAnimationFrame(draw); };
        draw();
        recStream = c.captureStream(30);
        stream.getAudioTracks().forEach((t) => recStream.addTrack(t)); // mix in the mic
        chunks = []; recorder = new MediaRecorder(recStream);
        recorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
        recorder.onstop = async () => {
          if (rafId) cancelAnimationFrame(rafId);
          const blob = new Blob(chunks, { type: recorder.mimeType || "video/webm" });
          try { const ref = await invoke("add_media", { circleId, dataBase64: await blobToBase64(blob), isVideo: true }); finish({ ref, isVideo: true }); }
          catch (e) { toast("Save failed: " + e); }
        };
        recorder.start(); recording = true; recBtn.textContent = "■ Stop"; recBtn.classList.add("danger");
      } else { recorder.stop(); }
    } }, "🎥 Record");
    modal(el("div", {}, el("h2", {}, "📷 Camera"), video, strip,
      el("div", { class: "row", style: "margin-top:12px" }, shoot, recBtn, el("div", { class: "spacer", style: "flex:1" }),
        el("button", { class: "btn ghost", onclick: () => finish(null) }, "Close"))));
    navigator.mediaDevices.getUserMedia({ video: { facingMode: "user" }, audio: true })
      .then((s) => { stream = s; video.srcObject = s; setFilter(CAMERA_FILTERS[0]); })
      .catch((e) => { toast("Camera unavailable: " + e); finish(null); });
  });
}

// Pick a future time → returns epoch ms (or null).
function scheduleDialog(onPick) {
  const input = el("input", { type: "datetime-local" });
  const d = new Date(Date.now() + 3600_000); // default +1h
  const pad = (n) => String(n).padStart(2, "0");
  input.value = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
  modal(el("div", {}, el("h2", {}, "🕓 Schedule"),
    el("div", { class: "muted small" }, "Haven has no server, so a scheduled message sends while this app is running at that time."),
    input,
    el("div", { class: "row", style: "justify-content:flex-end;margin-top:12px" },
      el("button", { class: "btn primary", onclick: () => { const ms = new Date(input.value).getTime(); if (!ms || ms < Date.now()) { toast("Pick a future time"); return; } onPick(ms); $("#modal-root").replaceChildren(); } }, "Schedule"))));
}

async function handleFiles(files, after) {
  for (const f of files) {
    const isVideo = f.type.startsWith("video");
    try {
      const b64 = isVideo ? await fileToBase64(f) : await imageToJpegBase64(f);
      const ref = await invoke("add_media", { circleId: state.activeCircle, dataBase64: b64, isVideo });
      const url = await invoke("media_data_url", { circleId: state.activeCircle, reference: ref });
      state.attachments.push({ ref, url, isVideo });
      after();
    } catch (e) { toast("Couldn't attach: " + e); }
  }
}

function fileToBase64(file) {
  return new Promise((res, rej) => {
    const r = new FileReader();
    r.onload = () => res(r.result.split(",")[1]);
    r.onerror = rej;
    r.readAsDataURL(file);
  });
}

function imageToJpegBase64(file, maxDim = 2048, quality = 0.82) {
  return new Promise((res, rej) => {
    const img = new Image();
    img.onload = () => {
      const scale = Math.min(1, maxDim / Math.max(img.width, img.height));
      const c = el("canvas");
      c.width = Math.round(img.width * scale);
      c.height = Math.round(img.height * scale);
      c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
      res(c.toDataURL("image/jpeg", quality).split(",")[1]);
      URL.revokeObjectURL(img.src);
    };
    img.onerror = rej;
    img.src = URL.createObjectURL(file);
  });
}

function postCard(it, circleId) {
  const head = el("div", { class: "post-head" },
    el("div", { class: "avatar" }, initials(it.author_name)),
    el("div", {},
      el("div", { class: "name" }, it.author_name),
      el("div", { class: "muted small" }, relTime(it.created_at) + (it.edited ? " · edited" : "")),
    ),
    el("button", { class: "kebab menu-btn", onclick: (e) => postMenu(e, it, circleId) }, "⋯"),
  );

  const body = it.unsent
    ? el("div", { class: "post-body muted" }, "🚫 This post was unsent")
    : el("div", { class: "post-body" }, it.body);

  const mediaRefs = it.media || [];
  const audioRefs = mediaRefs.filter((r) => r.startsWith("a:"));
  // A `geo:` location ref is NOT real media — split it out so it renders as a map chip above the grid
  // instead of a broken spinner tile (and so a photo+location post doesn't fall into the masonry path).
  const geo = mediaRefs.map(parseGeo).find(Boolean) || null;
  const visualRefs = mediaRefs.filter((r) => !r.startsWith("a:") && !r.startsWith("geo:"));
  const mediaCount = visualRefs.length;
  const media = el("div", { class: "post-media" + (mediaCount > 1 ? " masonry" : mediaCount === 1 ? " single" : ""), style: "position:relative" });
  for (const ref of visualRefs) media.append(mediaNode(ref));
  const audio = el("div", {});
  for (const ref of audioRefs) audio.append(mediaNode(ref));
  // Double-tap a photo to ❤️ it (Instagram-style), like the iOS gesture.
  if (mediaCount && !it.unsent) {
    media.addEventListener("dblclick", () => {
      const burst = el("div", { class: "heart-burst" }, "❤️");
      media.append(burst);
      requestAnimationFrame(() => burst.classList.add("go"));
      setTimeout(() => burst.remove(), 950);
      if (!hasMine(it.reactions, "❤️")) invoke("react", { circleId, target: it.id, emoji: "❤️" });
    });
  }

  const song = it.music ? el("a", {
    class: "song-chip",
    title: it.music.catalog_id && /^https?:/.test(it.music.catalog_id) ? "Open in your music app" : null,
    onclick: () => { if (it.music.catalog_id && /^https?:/.test(it.music.catalog_id)) openExternal(it.music.catalog_id); },
  }, el("span", { class: "note" }, "🎵"), el("strong", {}, it.music.title), " — ", it.music.artist) : null;

  const actions = el("div", { class: "post-actions" });
  const heart = el("button", { class: "react-pill" + (hasMine(it.reactions, "❤️") ? " mine" : ""), onclick: () => toggleReact(circleId, it.id, "❤️", it.reactions) }, "❤️", reactCount(it.reactions, "❤️"));
  actions.append(heart);
  for (const r of it.reactions || []) {
    if (r.emoji === "❤️") continue;
    actions.append(el("span", { class: "react-pill" + (r.mine ? " mine" : ""), onclick: () => toggleReact(circleId, it.id, r.emoji, it.reactions) }, r.emoji, " ", String(r.count)));
  }
  actions.append(el("button", { class: "react-pill", onclick: (e) => emojiPicker(e, circleId, it.id) }, "＋"));
  const cmtBtn = el("button", { class: "btn small ghost" }, `💬 ${(it.comments || []).length}`);
  actions.append(cmtBtn);

  const comments = el("div", { class: "comments" });
  for (const c of it.comments || []) {
    comments.append(el("div", { class: "comment" },
      el("div", { class: "avatar", style: "width:26px;height:26px;font-size:11px" }, initials(c.author_name)),
      el("div", { class: "bubble" }, el("div", { class: "small muted" }, c.author_name + " · " + relTime(c.created_at)), el("div", {}, c.body)),
    ));
  }
  const cin = el("input", { placeholder: "Add a comment…", onkeydown: async (e) => { if (e.key === "Enter" && e.target.value.trim()) { await invoke("comment", { circleId, target: it.id, body: e.target.value.trim() }); e.target.value = ""; } } });
  comments.append(el("div", { class: "row" }, cin));
  cmtBtn.addEventListener("click", () => comments.classList.toggle("show"));

  const geoNode = geo ? geoChip(geo) : null;
  return el("div", { class: "card post" }, head, body, media.children.length ? media : null, geoNode, audio.children.length ? audio : null, song, actions, comments);
}

const hasMine = (rs, e) => (rs || []).some((r) => r.emoji === e && r.mine);
const reactCount = (rs, e) => { const r = (rs || []).find((x) => x.emoji === e); return r ? " " + r.count : ""; };

async function toggleReact(circleId, target, emoji, reactions) {
  const mine = hasMine(reactions, emoji);
  await invoke(mine ? "unreact" : "react", { circleId, target, emoji });
}

function emojiPicker(e, circleId, target) {
  const choices = ["👍", "😂", "🔥", "😮", "😢", "🎉", "💜", "👏"];
  const m = el("div", {}, el("h2", {}, "React"),
    el("div", { class: "row wrap" }, ...choices.map((c) =>
      el("button", { class: "btn", style: "font-size:22px", onclick: async () => { await invoke("react", { circleId, target, emoji: c }); $("#modal-root").replaceChildren(); } }, c))));
  modal(m);
}

function postMenu(e, it, circleId) {
  const isHidden = Hidden.has(it.id);
  const m = el("div", {}, el("h2", {}, "Post"),
    el("div", { class: "col" },
      it.is_me ? el("button", { class: "btn", onclick: () => { $("#modal-root").replaceChildren(); editPostDialog(it, circleId); } }, "✏️ Edit") : null,
      it.is_me ? el("button", { class: "btn danger", onclick: async () => { await invoke("unsend_post", { circleId, target: it.id }); $("#modal-root").replaceChildren(); toast("Unsent"); } }, "🚫 Unsend") : null,
      // Hide any post from my own feed (reversible via "Show hidden").
      el("button", { class: "btn", onclick: () => { isHidden ? Hidden.unhide(it.id) : Hidden.hide(it.id); $("#modal-root").replaceChildren(); renderFeed(); } },
        isHidden ? "👁 Unhide" : "🙈 Hide post"),
    ));
  modal(m);
}

function editPostDialog(it, circleId) {
  const ta = el("textarea", {}, );
  ta.value = it.body;
  modal(el("div", {}, el("h2", {}, "Edit post"), ta,
    el("div", { class: "row", style: "margin-top:12px;justify-content:flex-end" },
      el("button", { class: "btn primary", onclick: async () => { await invoke("edit_post", { circleId, target: it.id, body: ta.value.trim() }); $("#modal-root").replaceChildren(); } }, "Save"))));
}

function newCircleDialog() {
  const inp = el("input", { placeholder: "Circle name (e.g. Family)" });
  modal(el("div", {}, el("h2", {}, "New circle"), inp,
    el("div", { class: "row", style: "margin-top:12px;justify-content:flex-end" },
      el("button", { class: "btn primary", onclick: async () => { if (inp.value.trim()) { state.activeCircle = await invoke("create_circle", { name: inp.value.trim() }); } $("#modal-root").replaceChildren(); renderFeed(); } }, "Create"))));
}

async function manageCircleDialog(circle) {
  if (!circle) return;
  const isDefault = circle.id === "default";
  const nameInp = el("input", { value: circle.name });
  const contacts = await invoke("contacts").catch(() => []);
  const memberList = el("div", { class: "col" });
  if (!contacts.length) memberList.append(el("div", { class: "muted small" }, "No contacts yet — connect a friend first."));
  for (const c of contacts) {
    memberList.append(el("div", { class: "list-item" },
      el("div", { class: "avatar", style: "width:30px;height:30px;font-size:12px" }, initials(c.name)),
      el("div", { style: "flex:1" }, c.name),
      el("button", { class: "btn small", onclick: async (e) => {
        try { await invoke("add_to_circle", { circleId: circle.id, contactIdHex: c.id_hex }); e.target.textContent = "Added ✓"; e.target.disabled = true; toast(`Added ${c.name}`); }
        catch (err) { toast("Couldn't add: " + err); }
      } }, "Add"),
      // Removing works for the DEFAULT circle ("My Circle") too: the engine writes the authoritative
      // removal tombstone AND purges them, so they can't auto-rejoin on their next handshake/self-sync.
      // (Previously hidden for default, which is why a removed member silently rejoined.)
      el("button", { class: "btn small ghost", title: isDefault ? "Remove from My Circle" : "Remove from this circle", onclick: async (e) => {
        try { await invoke("remove_from_circle", { circleId: circle.id, contactIdHex: c.id_hex }); e.target.textContent = "Removed ✓"; e.target.disabled = true; toast(`Removed ${c.name}`); renderFeed(); }
        catch (err) { toast("Couldn't remove: " + err); }
      } }, "Remove")));
  }
  // Per-circle relay override: pick which CONFIGURED relays this circle uses, beyond the all-circles
  // default. No inline relay configuration here — that lives under Relays (the ⚙ → "Manage relays" link).
  const allRelays = (await invoke("relays").catch(() => [])).filter((r) => r.active);
  const explicit = new Set(await invoke("circle_relays", { circleId: circle.id }).catch(() => []));
  const relaySection = el("div", { class: "col" });
  if (!allRelays.length) {
    relaySection.append(el("div", { class: "muted small" }, "No relays configured yet."));
  } else {
    for (const r of allRelays) {
      const on = explicit.has(r.node_hex) || r.is_default;
      const chk = el("input", { type: "checkbox", style: "width:auto" }); chk.checked = on; chk.disabled = r.is_default;
      chk.onchange = async () => { try { await invoke("set_circle_relay", { nodeHex: r.node_hex, circleId: circle.id, on: chk.checked }); toast("Updated"); } catch (e) { toast("" + e); chk.checked = !chk.checked; } };
      relaySection.append(el("label", { class: "row", style: "gap:8px;align-items:center" }, chk,
        el("span", { style: "flex:1" }, r.name + (r.is_default ? " — default (all circles)" : "") + (r.is_s3 ? " · S3" : ""))));
    }
  }
  relaySection.append(el("button", { class: "btn small ghost", style: "align-self:flex-start", onclick: () => { $("#modal-root").replaceChildren(); switchView("relay"); } }, "Manage relays →"));

  modal(el("div", {},
    el("h2", {}, "Manage circle"),
    el("div", { class: "col" },
      el("label", { class: "muted small" }, "Name"),
      el("div", { class: "row" }, nameInp,
        el("button", { class: "btn", onclick: async () => { const n = nameInp.value.trim(); if (n && n !== circle.name) { await invoke("rename_circle", { id: circle.id, name: n }); toast("Renamed"); $("#modal-root").replaceChildren(); renderFeed(); } } }, "Rename")),
      el("label", { class: "muted small", style: "margin-top:6px" }, "Relays for this circle"),
      el("div", { class: "muted small" }, "Choose which configured relays this circle uses, overriding the default. The default relay (if set) always applies — change it under Relays."),
      relaySection,
      el("label", { class: "muted small", style: "margin-top:6px" }, "Members"),
      memberList,
      isDefault ? null : el("button", { class: "btn danger", style: "margin-top:6px", onclick: async () => {
        await invoke("leave_circle", { id: circle.id }); state.activeCircle = "default"; $("#modal-root").replaceChildren(); toast("Left circle"); renderFeed();
      } }, "Leave this circle"),
    )));
}

function hydrateMedia(root, circleId) {
  $$("[data-ref]", root).forEach((node) => loadMedia(node, circleId, node.dataset.ref));
}

// ---- Stories ---------------------------------------------------------------------------
async function renderStories() {
  const root = $("#view-stories");
  const items = (await invoke("feed", { circleId: "default" })).filter((i) => i.story && !i.unsent);
  const tray = el("div", { class: "story-tray" });
  tray.append(el("div", { class: "story-ring", onclick: addStoryDialog },
    el("div", { class: "ring" }, el("div", {}, "＋")), el("div", { class: "small" }, "Add")));
  for (const it of items) {
    const inner = el("div", {});
    const firstReal = (it.media || []).find((r) => !r.startsWith("geo:") && !r.startsWith("a:"));
    if (firstReal) { const img = el("img", { "data-ref": firstReal }); inner.append(img); }
    else inner.append(document.createTextNode("✨"));
    tray.append(el("div", { class: "story-ring", onclick: () => viewStory(it) },
      el("div", { class: "ring" }, inner), el("div", { class: "small" }, it.author_name.split(" ")[0])));
  }
  root.replaceChildren(el("div", { class: "view-head" }, el("h1", {}, "Stories")), tray,
    items.length ? el("div", { class: "muted small" }, "Stories disappear after 24 hours.") : el("div", { class: "empty" }, "No active stories."));
  hydrateMedia(root, "default");
}


// ---- Story captions (cross-platform wire format) ----------------------------------------
// \u0001color,font,styleRaw,x,y,size,mediaScale,mediaOffX,mediaOffY\u0001text — positions/size
// normalized so a caption authored on any platform lands in the same spot at the same relative
// size. Tables mirror apple/HavenApp/StoryCaption.swift + Android StoryCaptions.kt exactly.
const StoryCaptions = {
  colors: ["#ffffff", "#000000", "#EC4899", "#8B5CF6", "#F59E0B", "#EF4444",
           "#F97316", "#22C55E", "#3B82F6", "#06B6D4", "#EAB308", "#10B981"],
  fonts: [
    "-apple-system, 'Segoe UI', Roboto, sans-serif|700",
    "Georgia, 'Times New Roman', serif|700",
    "'SF Pro Rounded', 'Comic Sans MS', cursive|800",
    "'SF Mono', Consolas, monospace|700",
    "-apple-system, 'Segoe UI', Roboto, sans-serif|900",
  ],
  lightIdx: [0, 9, 10, 11],   // white/cyan/yellow/mint → dark highlight text
  encode(caption, spec) {
    const t = (caption || "").trim();
    if (!t) return "";
    const f = (n, d) => Number(n).toFixed(d);
    return "\u0001" + [spec.color, spec.font, spec.style, f(spec.x, 3), f(spec.y, 3), f(spec.size, 3),
                        "1.000", "0.0000", "0.0000"].join(",") + "\u0001" + t;
  },
  decode(body) {
    const def = { color: 0, font: 0, style: 1, x: 0.5, y: 0.5, size: 1 };
    if (!body || body[0] !== "\u0001") return { text: body || "", spec: def };
    const sep = body.indexOf("\u0001", 1);
    if (sep < 0) return { text: body.slice(1), spec: def };
    const n = body.slice(1, sep).split(",");
    let style = parseInt(n[2], 10); if (Number.isNaN(style)) style = 1;
    if ((style === 0 || style === 1) && n.length === 6) style = style === 1 ? 4 : 1;  // legacy bit
    return { text: body.slice(sep + 1), spec: {
      color: parseInt(n[0], 10) || 0, font: parseInt(n[1], 10) || 0, style,
      x: parseFloat(n[3]) || 0.5, y: parseFloat(n[4]) || 0.5, size: parseFloat(n[5]) || 1,
    } };
  },
  // A styled, absolutely-positioned overlay for a media container (position:relative required).
  overlay(body) {
    const { text, spec } = this.decode(body);
    if (!text.trim()) return null;
    const c = this.colors[Math.min(Math.max(spec.color, 0), this.colors.length - 1)];
    const [family, weight] = this.fonts[Math.min(Math.max(spec.font, 0), this.fonts.length - 1)].split("|");
    const hl = spec.style === 4;
    const d = el("div", { class: "story-cap" }, text);
    d.style.cssText =
      "position:absolute;left:" + (spec.x * 100) + "%;top:" + (spec.y * 100) + "%;" +
      "transform:translate(-50%,-50%);max-width:86%;text-align:center;white-space:pre-wrap;" +
      "font-family:" + family + ";font-weight:" + weight + ";" +
      "font-size:calc(" + (spec.size * 5.5) + "cqh);line-height:1.25;pointer-events:none;";
    switch (spec.style) {
      case 0: d.style.color = c; d.style.textShadow = "0 0 4px rgba(0,0,0,.55)"; break;              // plain
      case 2: d.style.color = c; d.style.textShadow = "1.5px 2px 2px rgba(0,0,0,.85)"; break;        // shadow
      case 3: d.style.color = "#fff"; d.style.textShadow = "0 0 6px " + c + ",0 0 14px " + c + ",0 0 2px rgba(0,0,0,.3)"; break; // neon
      case 4: d.style.color = this.lightIdx.includes(spec.color) ? "#000" : "#fff";                  // highlight
              d.style.background = c; d.style.borderRadius = "8px"; d.style.padding = "3px 10px"; break;
      default: d.style.color = c; d.style.textShadow = "0 0 8px " + c + "e6,0 0 3px rgba(0,0,0,.35)"; // glow
    }
    return d;
  },
};

function addStoryDialog() {
  state.attachments = [];
  const composer = buildComposer(async (body, music) => {
    // Ship the cross-platform caption wire format (centered, default glow) so phones render
    // the caption styled + positioned instead of as plain text.
    const encoded = StoryCaptions.encode(body, { color: 0, font: 0, style: 1, x: 0.5, y: 0.85, size: 1 });
    await invoke("post_story", { body: encoded, media: state.attachments[0] ? state.attachments[0].ref : null, music });
  }, "Caption your story…", { circleId: "default" });
  modal(el("div", {}, el("h2", {}, "New story"), composer));
}

function viewStory(it) {
  const inner = el("div", { class: "col", style: "align-items:center" });
  const storyRef = (it.media || []).find((r) => !r.startsWith("geo:") && !r.startsWith("a:"));
  const cap = StoryCaptions.overlay(it.body);
  if (storyRef) {
    const m = storyRef.startsWith("v:") ? el("video", { "data-ref": storyRef, controls: "", autoplay: "" }) : el("img", { "data-ref": storyRef, style: "max-width:100%;border-radius:12px" });
    // container-query height units size the caption relative to the MEDIA, like the phones do.
    const wrap = el("div", { style: "position:relative;max-width:100%;container-type:size;display:inline-block" }, m);
    if (cap) wrap.append(cap);
    inner.append(wrap);
  } else if (cap) {
    const solo = el("div", { style: "position:relative;width:100%;min-height:200px;container-type:size" }, cap);
    inner.append(solo);
  }
  const storyGeo = (it.media || []).map(parseGeo).find(Boolean);
  if (storyGeo) inner.append(geoChip(storyGeo));
  const m = el("div", {}, el("h2", {}, it.author_name + "'s story"), inner);
  modal(m);
  hydrateMedia(m, "default");
}

// ---- Messages --------------------------------------------------------------------------
async function renderMessages() {
  const root = $("#view-messages");
  if (state.activeDm) return renderThread(root, state.activeDm);
  const threads = await invoke("dm_threads");
  const contacts = await invoke("contacts");
  // Backend already sorts most-recently-active first. Split pinned (in pin order) from the rest so the
  // pinned tiles ride the top of the list; both groups keep the recency order the backend gave us.
  const byId = new Map(threads.map((t) => [t.circle_id, t]));
  const pinned = Pins.ids.map((id) => byId.get(id)).filter(Boolean);
  const rest = threads.filter((t) => !Pins.has(t.circle_id));

  const openDm = (t) => { state.activeDm = { id: t.circle_id, name: t.name }; renderMessages(); };
  const del = async (t) => {
    if (!confirm(`Delete conversation with "${t.name}"? Its local messages are cleared.`)) return;
    Pins.remove(t.circle_id);
    await invoke("delete_conversation", { circleId: t.circle_id });
    renderMessages();
  };

  // Pinned grid (large avatars) above the list.
  const grid = el("div", { class: "pin-grid" });
  for (const t of pinned) {
    grid.append(el("div", { class: "pin-tile", onclick: () => openDm(t) },
      el("div", { class: "avatar big" }, initials(t.name)),
      el("div", { class: "pin-name" }, t.name)));
  }

  const threadRow = (t) => {
    const row = el("div", { class: "thread-item", onclick: () => openDm(t) },
      el("div", { class: "avatar" }, initials(t.name)),
      el("div", { style: "flex:1;min-width:0" }, el("div", { class: "name" }, t.name), el("div", { class: "muted small", style: "white-space:nowrap;overflow:hidden;text-overflow:ellipsis" }, t.last_body || "No messages yet")),
      el("div", { class: "muted small" }, relTime(t.last_at)),
      el("button", { class: "btn small ghost", title: Pins.has(t.circle_id) ? "Unpin" : "Pin", onclick: (e) => { e.stopPropagation(); if (!Pins.has(t.circle_id) && Pins.full) { toast("You can pin up to 6 conversations."); return; } Pins.toggle(t.circle_id); renderMessages(); } }, Pins.has(t.circle_id) ? "📌" : "📍"),
      el("button", { class: "btn small ghost danger", title: "Delete", onclick: (e) => { e.stopPropagation(); del(t); } }, "🗑"),
    );
    return row;
  };

  const list = el("div", { class: "thread-list" });
  if (pinned.length) list.append(grid);
  for (const t of rest) list.append(threadRow(t));
  if (!threads.length) list.append(el("div", { class: "empty" }, "No conversations yet. Start one from a contact below."));
  const cl = el("div", { class: "col" });
  for (const c of contacts) {
    cl.append(el("div", { class: "list-item" }, el("div", { class: "avatar" }, initials(c.name)), el("div", { style: "flex:1" }, c.name),
      el("button", { class: "btn small", onclick: async () => { const id = await invoke("start_dm", { contactIdHex: c.id_hex, contactName: c.name }); state.activeDm = { id, name: c.name }; renderMessages(); } }, "Message")));
  }
  root.replaceChildren(
    el("div", { class: "view-head" }, el("h1", {}, "Messages"),
      contacts.length >= 2 ? el("button", { class: "btn small ghost", style: "margin-left:auto", onclick: () => groupMessageDialog(contacts) }, "New group") : null),
    list,
    contacts.length ? el("h3", { class: "muted" }, "Start a chat") : null, cl);
}

/** Multi-select contacts to start a GROUP DM (2+ people). */
function groupMessageDialog(contacts) {
  const picked = new Set();
  const startBtn = el("button", { class: "btn", disabled: true, onclick: async () => {
    const members = contacts.filter((c) => picked.has(c.id_hex)).map((c) => [c.id_hex, c.name]);
    const id = await invoke("start_group_dm", { members });
    $("#modal-root").replaceChildren();
    state.activeDm = { id, name: members.map((m) => m[1]).join(", ") };
    switchView("messages"); renderMessages();
  } }, "Pick 2+");
  const sync = () => { startBtn.disabled = picked.size < 2; startBtn.textContent = picked.size >= 2 ? `Start (${picked.size})` : "Pick 2+"; };
  const rows = contacts.map((c) => el("label", { class: "list-item", style: "cursor:pointer" },
    el("input", { type: "checkbox", onchange: (e) => { e.target.checked ? picked.add(c.id_hex) : picked.delete(c.id_hex); sync(); } }),
    el("div", { class: "avatar", style: "width:30px;height:30px;font-size:12px" }, initials(c.name)),
    el("div", { style: "flex:1" }, c.name)));
  modal(el("div", {}, el("h2", {}, "New group message"),
    el("div", { class: "col", style: "max-height:360px;overflow:auto" }, ...rows),
    el("div", { class: "row", style: "margin-top:10px" }, startBtn)));
}

async function renderThread(root, dm) {
  const msgs = await invoke("messages", { circleId: dm.id });
  // A group DM has more than one OTHER participant (member_count > 2) → each incoming message needs a
  // sender name so the group knows who said what (a 1:1 DM doesn't). The relay-reachability flag drives the
  // delivery checkmark (filled = store-and-forward reachable).
  const threads = await invoke("dm_threads");
  const meta = threads.find((t) => t.circle_id === dm.id);
  const isGroup = (meta?.member_count || 0) > 2;
  let relayReachable = false;
  try { const rs = await invoke("relay_status"); relayReachable = !!(rs.hosting || rs.relay_active || (rs.has_relay && rs.internet_active)); } catch (_) {}
  let secretOn = false;
  const chat = el("div", { class: "chat" });
  for (const m of msgs) {
    if (m.unsent) continue;
    // A `geo:` ref renders as a map chip, not media (otherwise a broken tile in the bubble).
    const mediaEls = (m.media || []).map((r) => { const g = parseGeo(r); return g ? geoChip(g) : mediaNode(r, "max-width:220px;border-radius:10px;display:block;margin-top:6px"); });
    const bubble = isSecret(m.body)
      ? secretBubble(m.body, m.is_me)
      : el("div", { class: "chat-bubble" }, m.body || "", ...mediaEls);
    if (isSecret(m.body) && mediaEls.length) bubble.append(...mediaEls);
    // In a group DM, label each INCOMING message with who sent it.
    const senderLabel = (isGroup && !m.is_me) ? el("div", { class: "chat-sender" }, m.author_name || "Someone") : null;
    // A timestamp + (for my own sent messages) a delivery checkmark under every bubble.
    const meta2 = el("div", { class: "chat-meta" }, relTime(m.created_at));
    if (m.is_me) meta2.append(el("span", { class: "chat-check" + (relayReachable ? " on" : "") }, relayReachable ? "✓✓" : "✓"));
    chat.append(el("div", { class: "bubble-row" + (m.is_me ? " me" : "") }, el("div", { class: "bubble-col" }, senderLabel, bubble, meta2)));
  }
  const sendText = async (input) => {
    const t = input.value.trim();
    if (!t) return;
    const body = secretOn ? SECRET_MARKER + t : t;
    await invoke("send_dm", { circleId: dm.id, body, media: [] });
    input.value = "";
  };
  const input = el("input", { placeholder: "Message…", onkeydown: async (e) => { if (e.key === "Enter") await sendText(e.target); } });
  const secretBtn = el("button", { class: "btn", title: "Send secretly", onclick: () => { secretOn = !secretOn; secretBtn.classList.toggle("primary", secretOn); input.placeholder = secretOn ? "Secret message…" : "Message…"; } }, "🔒");
  const voiceBtn = el("button", { class: "btn", title: "Voice message", onclick: async () => { const r = await recordVoice(dm.id); if (r) await invoke("send_dm", { circleId: dm.id, body: "", media: [r] }); } }, "🎙️");
  const partner = dm.id.replace("dm:", "").split("-").find((h) => h !== state.node) || "";
  root.replaceChildren(
    el("div", { class: "view-head" },
      el("button", { class: "btn small ghost", onclick: () => { state.activeDm = null; renderMessages(); } }, "← Back"),
      el("h1", {}, dm.name),
      el("div", { class: "spacer" }),
      partner ? el("button", { class: "btn small", title: "Audio call", onclick: () => callStart([partner], dm.name, false) }, "📞") : null,
      partner ? el("button", { class: "btn small", title: "Video call", onclick: () => callStart([partner], dm.name, true) }, "📹") : null,
    ),
    el("div", { class: "card" }, chat,
      el("div", { class: "chat-input" }, secretBtn, voiceBtn, input,
        el("button", { class: "btn primary", onclick: () => sendText(input) }, "Send"))),
  );
  hydrateMedia(root, dm.id);
  chat.scrollTop = chat.scrollHeight;
}

// ---- Connect ---------------------------------------------------------------------------
async function renderConnect() {
  const root = $("#view-connect");
  const pending = await invoke("pending");
  const contacts = await invoke("contacts");

  const qrBox = el("div", { class: "qr-box" });
  try { qrBox.innerHTML = makeQrSvg(state.inviteUri); } catch (_) { qrBox.textContent = "QR unavailable"; }

  const mine = el("div", { class: "card col" },
    el("h3", {}, "Your invite"),
    el("div", { class: "muted small" }, "Have a friend scan this, or send them the link. Verify the safety code matches on both devices."),
    el("div", { class: "row", style: "align-items:flex-start" }, qrBox,
      el("div", { class: "col", style: "flex:1" },
        el("div", { class: "mono" }, state.inviteUri),
        el("div", { class: "row" },
          el("button", { class: "btn small", onclick: () => { navigator.clipboard.writeText(state.inviteUri); toast("Invite copied"); } }, "Copy haven:// link"),
          el("button", { class: "btn small", onclick: () => { navigator.clipboard.writeText(state.inviteLink); toast("Web link copied"); } }, "Copy web link"),
        ),
      ),
    ),
  );

  const linkInput = el("input", { placeholder: "Paste a haven:// or https:// invite…" });
  const add = el("div", { class: "card col" },
    el("h3", {}, "Connect a friend"),
    el("div", { class: "row" }, linkInput, el("button", { class: "btn primary", onclick: async () => { if (await invoke("connect_by_link", { uri: linkInput.value.trim() })) { toast("Invite sent — they'll appear once they accept"); linkInput.value = ""; } else toast("That doesn't look like a Haven link"); } }, "Connect")),
    el("button", { class: "btn ghost small", onclick: startScan }, "📷 Scan a QR with your camera"),
  );

  const pend = el("div", { class: "card col" }, el("h3", {}, `Requests (${pending.length})`));
  if (!pending.length) pend.append(el("div", { class: "muted small" }, "No pending requests."));
  for (const p of pending) {
    pend.append(el("div", { class: "pending-item" },
      el("div", { class: "row" }, el("div", { class: "avatar" }, initials(p.name)),
        el("div", { style: "flex:1" }, el("div", { class: "name" }, p.name), el("div", { class: "muted small mono" }, "safety: " + p.verify_hex.slice(0, 16))),
        el("button", { class: "btn small primary", onclick: async () => { await invoke("approve", { idHex: p.id_hex }); toast("Connected"); } }, "Accept"),
        el("button", { class: "btn small ghost", onclick: async () => { await invoke("dismiss", { idHex: p.id_hex }); } }, "Ignore"),
      )));
  }

  const cl = el("div", { class: "card col" }, el("h3", {}, `Contacts (${contacts.length})`));
  if (!contacts.length) cl.append(el("div", { class: "muted small" }, "No contacts yet."));
  for (const c of contacts) {
    cl.append(el("div", { class: "list-item" },
      el("div", { class: "avatar" }, initials(c.name)),
      el("div", { style: "flex:1" }, el("div", { class: "name" }, c.name), el("div", { class: "muted small mono" }, c.id_hex.slice(0, 16) + "…")),
      el("button", { class: "btn small", onclick: async () => { const id = await invoke("start_dm", { contactIdHex: c.id_hex, contactName: c.name }); state.activeDm = { id, name: c.name }; switchView("messages"); } }, "Message"),
      el("button", { class: "kebab", onclick: () => contactMenu(c) }, "⋯"),
    ));
  }

  root.replaceChildren(el("div", { class: "view-head" }, el("h1", {}, "Connect")),
    el("div", { class: "grid2" }, el("div", {}, mine, add), el("div", {}, pend, cl)));
}

function contactMenu(c) {
  modal(el("div", {}, el("h2", {}, c.name),
    el("div", { class: "col" },
      el("button", { class: "btn danger", onclick: async () => { await invoke("block", { idHex: c.id_hex }); $("#modal-root").replaceChildren(); toast("Blocked"); renderConnect(); } }, "Block " + c.name),
    )));
}

function makeQrSvg(text) {
  const qr = qrcode(0, "M");
  qr.addData(text);
  qr.make();
  return qr.createSvgTag({ cellSize: 5, margin: 2 });
}

async function startScan() {
  const video = el("video", { id: "scan-video", autoplay: "", muted: "", playsinline: "" });
  const canvas = el("canvas", { style: "display:none" });
  const status = el("div", { class: "muted small" }, "Point your camera at a Haven QR code.");
  let stream, raf;
  const close = modal(el("div", {}, el("h2", {}, "Scan QR"), video, status, canvas,
    el("div", { class: "row", style: "margin-top:10px;justify-content:flex-end" }, el("button", { class: "btn", onclick: () => stop() }, "Close"))));
  const stop = () => { if (raf) cancelAnimationFrame(raf); if (stream) stream.getTracks().forEach((t) => t.stop()); close(); };
  try {
    stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } });
    video.srcObject = stream;
    const tick = () => {
      if (video.readyState === video.HAVE_ENOUGH_DATA) {
        canvas.width = video.videoWidth; canvas.height = video.videoHeight;
        const ctx = canvas.getContext("2d");
        ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
        const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
        const code = window.jsQR ? window.jsQR(img.data, img.width, img.height) : null;
        if (code && code.data) {
          stop();
          invoke("connect_by_link", { uri: code.data.trim() }).then((ok) => toast(ok ? "Invite sent!" : "Not a Haven QR"));
          return;
        }
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
  } catch (e) { status.textContent = "Camera unavailable: " + e; }
}

// ---- Relay -----------------------------------------------------------------------------
async function renderRelay() {
  const root = $("#view-relay");
  const s = await invoke("relay_status");
  const adoptInput = el("input", { placeholder: "Paste a relay node id (64 hex)…" });
  const hostCard = el("div", { class: "card col" },
    el("h3", {}, "Host the relay on this PC"),
    el("div", { class: "muted small" }, "Your circle's relay runs here so posts and media reach friends even when you're both offline. The relay never sees your content — everything is end-to-end sealed."),
    s.hosting
      ? el("div", { class: "col" },
          el("div", { class: "ok-text" }, "● Relaying"),
          s.relay_link ? el("div", { class: "row" }, el("div", { class: "mono", style: "flex:1" }, s.relay_link), el("button", { class: "btn small", onclick: () => { navigator.clipboard.writeText(s.relay_link); toast("Relay id copied"); } }, "Copy")) : null,
          el("div", { class: "muted small" }, "Share this id with your circle so they adopt the same relay."),
          el("button", { class: "btn danger small", onclick: async () => { await invoke("stop_hosting"); renderRelay(); } }, "Stop hosting"),
        )
      : el("button", { class: "btn primary", onclick: async () => { try { await invoke("start_hosting"); toast("Relay started"); } catch (e) { toast("" + e); } renderRelay(); } }, "Start hosting"),
  );
  // Configured relays (active + inactive). "Remove" DEACTIVATES (config survives); "Delete" erases.
  const relayList = await invoke("relays").catch(() => []);
  const adoptCard = el("div", { class: "card col" },
    el("h3", {}, `Configured relays (${relayList.length})`),
    el("div", { class: "muted small" }, "Add more than one for redundancy — posts and media are mirrored to every relay, and if one goes down Haven quietly uses the others. The default relay (★) is inherited by every circle that hasn't picked its own. Removing a relay DEACTIVATES it (its name + circle settings survive so you can turn it back on); an inactive relay unseen for a week is cleaned up automatically."),
  );
  for (const r of relayList) {
    const dotCls = !r.active ? "" : (r.reachable ? "on" : "");
    const statusTxt = !r.active ? "deactivated — config kept"
      : (r.is_s3 ? "S3 · store-and-forward" : (r.hosted ? "this PC" : (r.reachable ? "reachable" : "retrying…")));
    const actions = el("div", { class: "row", style: "gap:6px;flex-wrap:wrap" });
    if (r.active) {
      actions.append(el("button", { class: "btn small", title: "Stop using this relay (keeps config)", onclick: async () => { await invoke("forget_relay", { nodeHex: r.node_hex }); toast("Relay deactivated"); renderRelay(); } }, "Deactivate"));
    } else {
      actions.append(el("button", { class: "btn small primary", onclick: async () => { await invoke("reactivate_relay", { nodeHex: r.node_hex }); toast("Relay reactivated"); renderRelay(); } }, "Reactivate"));
    }
    actions.append(r.is_default
      ? el("button", { class: "btn small ghost", title: "Stop being the all-circles default", onclick: async () => { await invoke("set_default_relay", { nodeHex: "" }); renderRelay(); } }, "Unset default")
      : el("button", { class: "btn small ghost", title: "Use for every circle by default", onclick: async () => { await invoke("set_default_relay", { nodeHex: r.node_hex }); toast("Default relay set"); renderRelay(); } }, "Make default"));
    actions.append(el("button", { class: "btn small ghost", onclick: async () => {
      const n = prompt("Relay name", r.name); if (n && n.trim()) { await invoke("rename_relay", { nodeHex: r.node_hex, name: n.trim() }); renderRelay(); }
    } }, "Rename"));
    actions.append(el("button", { class: "btn small danger", title: "Erase config for good", onclick: async () => { await invoke("erase_relay", { nodeHex: r.node_hex }); toast("Relay deleted"); renderRelay(); } }, "Delete"));
    adoptCard.append(el("div", { class: "list-item col", style: "align-items:stretch;gap:6px" },
      el("div", { class: "row", style: "gap:8px;align-items:center" },
        el("span", { class: "dot " + dotCls, title: statusTxt }),
        el("div", { style: "flex:1;min-width:0" },
          el("div", { class: "row", style: "gap:6px;align-items:center" },
            el("span", { style: "font-weight:600;overflow:hidden;text-overflow:ellipsis" }, r.name),
            r.is_default ? el("span", { class: "tag", title: "Default for all circles" }, "★ default") : null,
            r.is_s3 ? el("span", { class: "tag" }, "S3") : null,
            r.hosted ? el("span", { class: "tag" }, "this PC") : null,
          ),
          el("div", { class: "mono small muted", style: "overflow:hidden;text-overflow:ellipsis" }, r.is_s3 ? r.node_hex : r.node_hex.slice(0, 20) + "…"),
          el("div", { class: "muted small" }, statusTxt),
        ),
      ),
      actions,
    ));
  }
  if (!relayList.length) adoptCard.append(el("div", { class: "muted small" }, "No relays yet — host one above, adopt a friend's, or add an S3 bucket below."));
  adoptCard.append(el("div", { class: "row" }, adoptInput, el("button", { class: "btn primary", onclick: async () => { if (adoptInput.value.trim().length === 64) { await invoke("adopt_relay", { nodeHex: adoptInput.value.trim() }); toast("Relay added"); adoptInput.value = ""; renderRelay(); } else toast("That's not a 64-hex node id"); } }, "Add Haven relay")));
  const au = await invoke("autostart_status").catch(() => ({ login_item: false, host_on_launch: false }));
  const loginChk = el("input", { type: "checkbox", style: "width:auto" }); loginChk.checked = au.login_item;
  const hostChk = el("input", { type: "checkbox", style: "width:auto" }); hostChk.checked = au.host_on_launch;
  const alwaysOn = el("div", { class: "card col" },
    el("h3", {}, "Always-on relay (survives reboot)"),
    el("div", { class: "muted small" }, "Have Haven start automatically when you log in and keep hosting your circle's relay — so this PC stays a relay across reboots, no terminal needed."),
    el("label", { class: "row", style: "gap:8px" }, loginChk, el("span", {}, "Start Haven when I log in")),
    el("label", { class: "row", style: "gap:8px" }, hostChk, el("span", {}, "Host the relay automatically on launch")),
    el("button", { class: "btn primary", style: "align-self:flex-start", onclick: async () => { try { await invoke("set_autostart", { loginItem: loginChk.checked, hostOnLaunch: hostChk.checked }); toast("Saved"); renderRelay(); } catch (e) { toast("" + e); } } }, "Save"),
  );
  const headless = el("div", { class: "card col" },
    el("h3", {}, "Run headless"),
    el("div", { class: "muted small html", html: "Prefer no window at all? Launch <span class='mono'>haven-desktop --headless</span> to run only the relay (and your scheduled-message dispatcher) as a small always-on server. Any official Haven app — iPhone, Mac, Windows, Linux — can also act as your relay in a pinch." }),
  );
  const s3 = await invoke("s3_status");
  const f = {
    name: el("input", { value: s3.configured ? ("S3 · " + s3.bucket) : "", placeholder: "Name (optional)" }),
    endpoint: el("input", { value: s3.endpoint || "", placeholder: "Endpoint, e.g. https://s3.us-east-1.amazonaws.com" }),
    region: el("input", { value: s3.region || "us-east-1", placeholder: "Region", style: "max-width:160px" }),
    bucket: el("input", { value: s3.bucket || "", placeholder: "Bucket name" }),
    access: el("input", { value: s3.access_key || "", placeholder: "Access key id" }),
    secret: el("input", { type: "password", placeholder: s3.configured ? "•••••• (stored in your keychain)" : "Secret access key" }),
    prefix: el("input", { value: s3.prefix || "", placeholder: "Key prefix (optional)" }),
  };
  const s3default = el("input", { type: "checkbox", style: "width:auto" }); s3default.checked = true;
  const s3card = el("div", { class: "card col" },
    el("h3", {}, "Add an S3 bucket as a relay (S3 / R2 / B2)"),
    el("div", { class: "muted small" }, "Bring your own bucket as a store-and-forward relay. " + (s3.configured ? "✓ Configured: " + s3.bucket : "Not configured.")),
    el("div", { class: "muted small", style: "border-left:3px solid var(--warn,#e0a020);padding-left:8px" },
      "⚠︎ Store-and-forward only: an S3 bucket holds sealed posts & media for offline delivery — it is NOT a live P2P relay (no realtime fan-out). The provider never sees plaintext; your secret stays in this device's keychain, never on any server. Works with AWS S3, Cloudflare R2, Backblaze B2, MinIO."),
    f.name, f.endpoint, el("div", { class: "row" }, f.region, f.bucket), f.access, f.secret, f.prefix,
    el("label", { class: "row", style: "gap:8px" }, s3default, el("span", {}, "Make the default for all circles")),
    el("div", { class: "row" },
      el("button", { class: "btn primary", onclick: async () => {
        try {
          await invoke("add_s3_relay", { endpoint: f.endpoint.value.trim(), region: f.region.value.trim(), bucket: f.bucket.value.trim(), accessKey: f.access.value.trim(), secretKey: f.secret.value, prefix: f.prefix.value.trim(), name: f.name.value.trim(), setDefault: s3default.checked });
          toast("S3 relay added"); renderRelay();
        } catch (e) { toast("" + e); }
      } }, s3.configured ? "Update bucket" : "Add S3 relay"),
      s3.configured ? el("button", { class: "btn danger small", onclick: async () => { await invoke("erase_relay", { nodeHex: "s3:" + s3.bucket }); await invoke("s3_clear"); toast("S3 relay removed"); renderRelay(); } }, "Remove") : null,
    ),
  );
  root.replaceChildren(el("div", { class: "view-head" }, el("h1", {}, "Relay")), hostCard, alwaysOn, adoptCard, s3card, headless);
}

// ---- You / Settings --------------------------------------------------------------------
async function renderYou() {
  const root = $("#view-you");
  const p = await invoke("get_profile");
  const blocked = await invoke("blocked");
  const roster = await invoke("device_roster").catch(() => ({ enabled: false, this_device_authorized: false, devices: [] }));
  const name = el("input", { value: p.name || "", placeholder: "Display name" });
  const emoji = el("input", { value: p.emoji || "", placeholder: "Emoji (optional)", maxlength: 4, style: "width:90px" });
  const bio = el("textarea", { placeholder: "One-line bio (optional)" }); bio.value = p.bio || "";
  const link = el("input", { value: p.link || "", placeholder: "A link to show (optional)" });

  const profileCard = el("div", { class: "card col" },
    el("h3", {}, "Your profile"),
    el("div", { class: "row" }, el("div", { class: "avatar lg" }, p.emoji || initials(p.name)), el("div", { class: "col", style: "flex:1" }, el("div", { class: "row" }, name, emoji))),
    bio, link,
    el("div", { class: "muted small mono" }, "id: " + state.node),
    el("button", { class: "btn primary", onclick: async () => { await invoke("set_profile", { name: name.value.trim(), bio: bio.value.trim(), link: link.value.trim(), emoji: emoji.value.trim(), avatar: p.avatar || "" }); toast("Profile saved & shared"); } }, "Save profile"),
  );

  const security = el("div", { class: "card col" },
    el("h3", {}, "Security"),
    el("div", { class: "muted small" }, "Run the on-device hybrid post-quantum self-test (Ed25519 + ML-DSA, X25519 + ML-KEM-768)."),
    el("button", { class: "btn", onclick: async () => { const r = await invoke("self_test"); modal(el("div", {}, el("h2", {}, r.all_ok ? "✅ All checks passed" : "⚠️ Some checks failed"), el("div", { class: "col small" }, line("Identity", r.identity_ok), line("Hybrid KEM", r.hybrid_kem_ok), line("Signatures", r.signature_ok), line("Reach-me link", r.link_ok)), el("p", { class: "muted small" }, r.summary))); } }, "Run self-test"),
  );

  const blockedCard = el("div", { class: "card col" }, el("h3", {}, `Blocked (${blocked.length})`));
  if (!blocked.length) blockedCard.append(el("div", { class: "muted small" }, "No one is blocked."));
  for (const b of blocked) blockedCard.append(el("div", { class: "list-item" }, el("div", { class: "mono", style: "flex:1" }, b.slice(0, 24) + "…"), el("button", { class: "btn small", onclick: async () => { await invoke("unblock", { idHex: b }); renderYou(); } }, "Unblock")));

  const danger = el("div", { class: "card col" },
    el("h3", {}, "Start over"),
    el("div", { class: "muted small" }, "Wipe this device's identity, contacts, circles and media. This cannot be undone."),
    el("button", { class: "btn danger", onclick: () => { modal(el("div", {}, el("h2", {}, "Start over?"), el("p", {}, "This permanently deletes your identity and all local data on this PC."), el("div", { class: "row", style: "justify-content:flex-end" }, el("button", { class: "btn ghost", onclick: () => $("#modal-root").replaceChildren() }, "Cancel"), el("button", { class: "btn danger", onclick: async () => { await invoke("reset"); location.reload(); } }, "Delete everything")))); } }, "Start over"),
  );

  // ---- identities ----
  const ids = await invoke("identities").catch(() => []);
  const idCard = el("div", { class: "card col" }, el("h3", {}, "Identities"),
    el("div", { class: "muted small" }, "Keep more than one identity on this PC and switch between them. Each has its own profile, circles and contacts."));
  for (const id of ids) {
    idCard.append(el("div", { class: "list-item" },
      el("div", { class: "avatar", style: "width:30px;height:30px;font-size:12px" }, initials(id.label)),
      el("div", { style: "flex:1;min-width:0" }, el("div", { class: "name" }, id.label, id.active ? el("span", { class: "tag", style: "margin-left:8px" }, "active") : null), el("div", { class: "muted small mono" }, id.node_hex.slice(0, 18) + "…")),
      id.active ? null : el("button", { class: "btn small primary", onclick: async () => { if (confirm(`Switch to "${id.label}"? Haven will relaunch.`)) await invoke("switch_identity", { nodeHex: id.node_hex }); } }, "Switch"),
      el("button", { class: "btn small ghost", title: "Rename", onclick: () => { const i = el("input", { value: id.label }); modal(el("div", {}, el("h2", {}, "Rename identity"), i, el("div", { class: "row", style: "justify-content:flex-end;margin-top:10px" }, el("button", { class: "btn primary", onclick: async () => { await invoke("rename_identity", { nodeHex: id.node_hex, label: i.value.trim() || id.label }); $("#modal-root").replaceChildren(); renderYou(); } }, "Save")))); } }, "✏︎"),
      id.active ? null : el("button", { class: "btn small danger", title: "Remove", onclick: async () => { if (confirm(`Remove "${id.label}" from this PC? Its local data is deleted.`)) { await invoke("remove_identity", { nodeHex: id.node_hex }); renderYou(); } } }, "🗑"),
    ));
  }
  idCard.append(el("div", { class: "row", style: "margin-top:6px" },
    el("button", { class: "btn small", onclick: () => { const i = el("input", { placeholder: "Label (e.g. Work)" }); modal(el("div", {}, el("h2", {}, "New identity"), i, el("div", { class: "row", style: "justify-content:flex-end;margin-top:10px" }, el("button", { class: "btn primary", onclick: async () => { await invoke("add_identity", { label: i.value.trim() || "New identity" }); $("#modal-root").replaceChildren(); renderYou(); toast("Identity created"); } }, "Create")))); } }, "+ New identity"),
    el("button", { class: "btn small ghost", onclick: () => { const lab = el("input", { placeholder: "Label" }); const seed = el("input", { placeholder: "Transfer code (haven-seed:…) or seed" }); modal(el("div", {}, el("h2", {}, "Link an existing identity"), lab, seed, el("div", { class: "row", style: "justify-content:flex-end;margin-top:10px" }, el("button", { class: "btn primary", onclick: async () => { try { await invoke("import_identity", { label: lab.value.trim() || "Imported", seedB64: seed.value.trim() }); $("#modal-root").replaceChildren(); renderYou(); toast("Imported"); } catch (e) { toast("Import failed: " + e); } } }, "Import")))); } }, "Import"),
  ));

  // ---- scheduled ----
  const sched = await invoke("scheduled").catch(() => []);
  const schedCard = el("div", { class: "card col" }, el("h3", {}, `Scheduled (${sched.length})`));
  if (!sched.length) schedCard.append(el("div", { class: "muted small" }, "Nothing scheduled. Use the 🕓 button in the composer to send later."));
  for (const s of sched) {
    schedCard.append(el("div", { class: "list-item" },
      el("div", { style: "flex:1;min-width:0" }, el("div", {}, (s.kind === "dm" ? "DM · " : "Post · ") + (s.body || (s.media_count ? `${s.media_count} attachment(s)` : "—"))), el("div", { class: "muted small" }, "sends " + new Date(s.send_at_ms).toLocaleString())),
      el("button", { class: "btn small danger", onclick: async () => { await invoke("cancel_scheduled", { id: s.id }); renderYou(); } }, "Cancel")));
  }

  // ---- Authorized devices (revocable multi-device roster — parity with iOS/Android) ----
  const roleTitle = roster.enabled ? "This is your primary device"
    : roster.this_device_authorized ? "This is a linked device" : "This device isn’t linked yet";
  const roleSub = roster.enabled ? "It holds your master key and authorizes or revokes your other devices."
    : roster.this_device_authorized ? "It acts on behalf of your primary device, which can revoke it at any time."
    : "Make it your primary, or link it to the device that already is.";
  const devicesCard = el("div", { class: "card col" },
    el("h3", {}, "Authorized devices"),
    el("div", {}, el("strong", {}, roleTitle)),
    el("div", { class: "muted small" }, roleSub));
  if (!roster.devices.length) devicesCard.append(el("div", { class: "muted small" }, "No devices linked yet."));
  for (const d of roster.devices) {
    devicesCard.append(el("div", { class: "list-item" },
      el("div", {}, d.is_primary ? "🔑" : "💻"),
      el("div", { style: "flex:1" }, el("div", { class: "name" }, d.name),
        el("div", { class: "muted small" }, d.is_primary ? "Master key" : d.is_this_device ? "This device" : "Linked device")),
      d.is_primary ? null : el("button", { class: "btn small danger", onclick: async () => {
        if (confirm(`Revoke “${d.name}”? It will no longer receive anything posted afterward.`)) { await invoke("revoke_device", { nodeHex: d.node_hex }); renderYou(); }
      } }, "Revoke")));
  }
  devicesCard.append(el("div", { class: "row", style: "margin-top:6px" },
    roster.enabled
      ? el("button", { class: "btn small danger", onclick: async () => { if (confirm("Stop this device acting as the primary?")) { await invoke("step_down_as_primary"); renderYou(); } } }, "This isn’t my primary")
      : el("button", { class: "btn small", onclick: async () => { await invoke("enable_device_roster"); renderYou(); toast("This is now your primary device"); } }, "Make this my primary"),
    roster.enabled ? null : el("button", { class: "btn small ghost", onclick: async () => { await invoke("request_device_enrollment"); toast("Asked your primary device to authorize this one"); } },
      roster.this_device_authorized ? "Re-sync from my primary" : "Make this a linked device")));

  root.replaceChildren(el("div", { class: "view-head" }, el("h1", {}, "You")), profileCard, idCard, devicesCard, schedCard, security, blockedCard, danger);
}

const line = (label, ok) => el("div", { class: "row" }, el("span", { style: "flex:1" }, label), el("span", { class: ok ? "ok-text" : "warn-text" }, ok ? "✓ pass" : "✗ fail"));

// ---- WebRTC mesh calls -----------------------------------------------------------------
// Mirrors the iOS/Android CallManager: a call = sessionId + roster of node hexes; every
// participant opens one RTCPeerConnection to every other (full mesh, no SFU). 1:1 is a
// 2-person group. The lexicographically smaller hex offers (glare-free). SDP/ICE ride the
// sealed iroh channel via the call_signal command; media is DTLS-SRTP in the WebView.
const ICE_SERVERS = [{ urls: ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"] }];
const call = {
  session: "", me: "", name: "", roster: new Set(), pcs: new Map(),
  localStream: null, micOn: true, camOn: true,
  ringing: false, connecting: false, inCall: false, video: true,
  screenOn: false, screenStream: null, camTrack: null,
};

/** Call audio priority: true from the first ring/dial until teardown. */
function callAudioActive() { return call.ringing || call.connecting || call.inCall; }
/** Feed/DM <video> sound = the user's global toggle, overridden to MUTED while a call is
 *  ringing/connecting/live so post soundtracks never compete with call audio. Called on the
 *  global toggle, on every call state transition, and by mediaNode for newly-rendered videos. */
function syncFeedVideoSound() {
  document.querySelectorAll("video[data-video]").forEach((v) => { v.muted = callAudioActive() || !state.videoSoundOn; });
}

const invitees = () => [...call.roster].filter((h) => h !== call.me).sort();

async function callStart(others, name, video) {
  if (call.inCall || call.ringing || call.connecting) { others.forEach((o) => call.roster.add(o)); return; }
  call.me = state.node;
  call.session = `win-${call.me.slice(0, 8)}-${Date.now()}`;
  call.roster = new Set([...others, call.me]);
  call.name = name; call.video = video; call.connecting = true; call.camOn = video;
  syncFeedVideoSound();   // call audio owns the stage from the first dial
  await invoke("call_group_invite", { sessionId: call.session, groupName: name, roster: [...call.roster], to: invitees() });
  await startMesh();
  renderCallOverlay();
}

/** Add people to the IN-PROGRESS call: invite the newcomers and re-broadcast the updated roster so
 *  everyone (old + new) meshes together. */
async function addToCall(others) {
  if (!(call.inCall || call.connecting)) return;
  const fresh = others.filter((o) => o !== call.me && !call.roster.has(o));
  if (!fresh.length) return;
  fresh.forEach((o) => call.roster.add(o));
  await invoke("call_group_invite", { sessionId: call.session, groupName: call.name || "Haven call", roster: [...call.roster], to: invitees() });
  if (call.localStream) fresh.forEach(connectPeerIfNeeded);
  renderCallOverlay();
}

function addToCallDialog() {
  const addable = (state.contacts || []).filter((c) => !call.roster.has(c.id_hex));
  if (!addable.length) { toast("No one else to add"); return; }
  modal(el("div", {}, el("h2", {}, "Add to call"),
    el("div", { class: "col", style: "max-height:300px;overflow:auto" },
      ...addable.map((c) => el("div", { class: "list-item" },
        el("div", { class: "avatar", style: "width:30px;height:30px;font-size:12px" }, initials(c.name)),
        el("div", { style: "flex:1" }, c.name),
        el("button", { class: "btn small", onclick: async (e) => { await addToCall([c.id_hex]); e.target.textContent = "Added ✓"; e.target.disabled = true; } }, "Add"))))));
}

async function callAccept() {
  call.ringing = false; call.inCall = true;
  await invoke("call_accept", { sessionId: call.session, to: invitees() });
  await startMesh();
  invitees().forEach(connectPeerIfNeeded);
  renderCallOverlay();
}

async function callHangup() {
  await invoke("call_hangup", { to: invitees() });
  teardownCall();
}

async function startMesh() {
  if (call.localStream) return;
  try {
    call.localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: call.video });
  } catch (e) {
    toast("Mic/camera unavailable: " + e);
    call.localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false }).catch(() => null);
  }
  call.connecting = call.connecting && !call.inCall;
  invitees().forEach(connectPeerIfNeeded);
  renderCallOverlay();
}

function pcFor(peer) {
  if (call.pcs.has(peer)) return call.pcs.get(peer);
  const pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
  if (call.localStream) call.localStream.getTracks().forEach((t) => pc.addTrack(t, call.localStream));
  pc.onicecandidate = (e) => {
    if (e.candidate) invoke("call_signal", { kind: "ice", sessionId: call.session, to: peer, json: JSON.stringify({ c: e.candidate.candidate, m: e.candidate.sdpMLineIndex, i: e.candidate.sdpMid }) });
  };
  pc.ontrack = (e) => { call.remote = call.remote || {}; call.remote[peer] = e.streams[0]; renderCallOverlay(); };
  pc.onconnectionstatechange = () => { if (["failed", "closed", "disconnected"].includes(pc.connectionState)) {} };
  call.pcs.set(peer, pc);
  return pc;
}

async function connectPeerIfNeeded(peer) {
  const pc = pcFor(peer);
  if (call.me < peer && call.localStream) {
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    invoke("call_signal", { kind: "offer", sessionId: call.session, to: peer, json: JSON.stringify({ t: "offer", sdp: offer.sdp }) });
  }
}

async function onCallEvent(payload) {
  const c = payload || {};
  call.me = state.node;
  switch (c.kind) {
    case "groupInvite":
    case "invite": {
      const members = new Set([...(c.roster || []), c.from, call.me]);
      if (call.inCall || call.ringing || call.connecting) {
        if (call.session === c.sessionId) { members.forEach((m) => call.roster.add(m)); if (call.localStream) invitees().forEach(connectPeerIfNeeded); }
        return;
      }
      call.session = c.sessionId; call.roster = members; call.name = c.groupName || c.name || displayNameFor(c.from);
      call.ringing = true; call.video = true; syncFeedVideoSound(); renderCallOverlay();
      break;
    }
    case "accept": {
      if (!validSession(c.sessionId)) return;
      call.connecting = false; call.inCall = true; call.roster.add(c.from);
      await startMesh(); connectPeerIfNeeded(c.from); renderCallOverlay();
      break;
    }
    case "hangup": {
      const pc = call.pcs.get(c.from); if (pc) pc.close();
      call.pcs.delete(c.from); call.roster.delete(c.from);
      if (call.remote) delete call.remote[c.from];
      if (invitees().length === 0) teardownCall(); else renderCallOverlay();
      break;
    }
    case "offer": {
      if (!validSession(c.sessionId)) return;
      if (!call.localStream) await startMesh();
      const pc = pcFor(c.from);
      const { sdp } = JSON.parse(c.json);
      await pc.setRemoteDescription({ type: "offer", sdp });
      const answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      invoke("call_signal", { kind: "answer", sessionId: call.session, to: c.from, json: JSON.stringify({ t: "answer", sdp: answer.sdp }) });
      break;
    }
    case "answer": {
      if (!validSession(c.sessionId)) return;
      const pc = call.pcs.get(c.from); if (!pc) return;
      const { sdp } = JSON.parse(c.json);
      await pc.setRemoteDescription({ type: "answer", sdp });
      break;
    }
    case "ice": {
      if (!validSession(c.sessionId)) return;
      const pc = pcFor(c.from);
      const o = JSON.parse(c.json);
      try { await pc.addIceCandidate({ candidate: o.c, sdpMLineIndex: o.m, sdpMid: o.i }); } catch (_) {}
      break;
    }
  }
}

const validSession = (sid) => sid === call.session || !call.session;
function displayNameFor(hex) {
  const c = (state.contacts || []).find((x) => x.id_hex === hex);
  return c ? c.name : "Someone";
}

function teardownCall() {
  if (call.screenStream) { call.screenStream.getTracks().forEach((t) => t.stop()); call.screenStream = null; }
  call.screenOn = false; call.camTrack = null;
  call.pcs.forEach((pc) => pc.close()); call.pcs.clear();
  if (call.localStream) call.localStream.getTracks().forEach((t) => t.stop());
  call.localStream = null; call.remote = {};
  call.roster.clear(); call.session = ""; call.ringing = false; call.connecting = false; call.inCall = false;
  syncFeedVideoSound();   // restore the user's global video-sound choice now the call is over
  renderCallOverlay();
}

function toggleMic() { call.micOn = !call.micOn; if (call.localStream) call.localStream.getAudioTracks().forEach((t) => (t.enabled = call.micOn)); renderCallOverlay(); }
function toggleCam() { call.camOn = !call.camOn; if (call.localStream) call.localStream.getVideoTracks().forEach((t) => (t.enabled = call.camOn)); renderCallOverlay(); }

// Swap the outgoing video track on every peer connection without renegotiating (replaceTrack).
function replaceOutgoingVideo(track) {
  call.pcs.forEach((pc) => {
    const sender = pc.getSenders().find((s) => s.track && s.track.kind === "video");
    if (sender) sender.replaceTrack(track).catch(() => {});
  });
}

// Screen share: getDisplayMedia → on Wayland/SteamOS this goes through the xdg-desktop-portal
// ScreenCast picker (PipeWire). Replaces the camera track for everyone; stopping (or the OS
// "stop sharing") restores the camera.
async function toggleScreen() {
  if (!call.localStream) return;
  if (call.screenOn) { stopScreenShare(); renderCallOverlay(); return; }
  let display;
  try {
    display = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: false });
  } catch (e) { toast("Screen share unavailable: " + e); return; }
  const screenTrack = display.getVideoTracks()[0];
  if (!screenTrack) { toast("No screen selected"); return; }
  // Remember the camera track so we can swap back.
  call.camTrack = call.localStream.getVideoTracks()[0] || call.camTrack;
  call.screenStream = display;
  call.screenOn = true;
  replaceOutgoingVideo(screenTrack);
  // Show the shared screen in the local preview too.
  if (call.camTrack) { try { call.localStream.removeTrack(call.camTrack); } catch (_) {} }
  call.localStream.addTrack(screenTrack);
  screenTrack.onended = () => { stopScreenShare(); renderCallOverlay(); }; // OS "stop sharing"
  renderCallOverlay();
}

function stopScreenShare() {
  if (!call.screenOn) return;
  call.screenOn = false;
  if (call.screenStream) { call.screenStream.getTracks().forEach((t) => t.stop()); call.screenStream = null; }
  const back = call.camTrack && call.camTrack.readyState === "live" ? call.camTrack : null;
  replaceOutgoingVideo(back);
  if (call.localStream) {
    call.localStream.getVideoTracks().forEach((t) => { if (t.readyState !== "live") { try { call.localStream.removeTrack(t); } catch (_) {} } });
    if (back && !call.localStream.getVideoTracks().includes(back)) call.localStream.addTrack(back);
  }
}

function renderCallOverlay() {
  const root = $("#modal-root");
  if (!call.ringing && !call.connecting && !call.inCall) {
    if (root.querySelector(".call-overlay")) root.replaceChildren();
    return;
  }
  if (call.ringing) {
    root.replaceChildren(el("div", { class: "modal-backdrop" }, el("div", { class: "modal call-overlay", style: "text-align:center" },
      el("div", { class: "avatar lg", style: "margin:0 auto 12px" }, initials(call.name)),
      el("h2", {}, "Incoming call"), el("p", { class: "muted" }, call.name + " is calling…"),
      el("div", { class: "row", style: "justify-content:center;gap:16px;margin-top:14px" },
        el("button", { class: "btn danger", onclick: () => callHangup() }, "Decline"),
        el("button", { class: "btn primary", onclick: () => callAccept() }, "Accept"),
      ))));
    return;
  }
  // In-call / connecting: a video grid + controls.
  const grid = el("div", { class: "call-grid" });
  const localTile = el("div", { class: "call-tile" });
  const lv = el("video", { autoplay: "", muted: "", playsinline: "" });
  if (call.localStream) lv.srcObject = call.localStream;
  localTile.append(lv, el("span", { class: "call-name" }, "You" + (call.camOn ? "" : " (camera off)")));
  grid.append(localTile);
  for (const peer of invitees()) {
    const tile = el("div", { class: "call-tile" });
    const v = el("video", { autoplay: "", playsinline: "" });
    if (call.remote && call.remote[peer]) v.srcObject = call.remote[peer];
    tile.append(v, el("span", { class: "call-name" }, displayNameFor(peer)));
    grid.append(tile);
  }
  root.replaceChildren(el("div", { class: "modal-backdrop" }, el("div", { class: "call-overlay-full" },
    el("div", { class: "muted small", style: "text-align:center;margin-bottom:8px" }, call.connecting ? "Calling " + call.name + "…" : call.name),
    grid,
    el("div", { class: "call-controls" },
      el("button", { class: "btn " + (call.micOn ? "" : "danger"), onclick: toggleMic }, call.micOn ? "🎤 Mute" : "🔇 Unmute"),
      call.video ? el("button", { class: "btn " + (call.camOn ? "" : "danger"), onclick: toggleCam }, call.camOn ? "📹 Camera off" : "📷 Camera on") : null,
      el("button", { class: "btn " + (call.screenOn ? "primary" : ""), onclick: toggleScreen }, call.screenOn ? "🛑 Stop sharing" : "🖥️ Share screen"),
      el("button", { class: "btn", onclick: addToCallDialog }, "➕ Add"),
      el("button", { class: "btn danger", onclick: () => callHangup() }, "📞 Hang up"),
    ))));
}

// ---- boot ------------------------------------------------------------------------------
function initTheme() {
  const saved = localStorage.getItem("haven-theme");
  if (saved) document.documentElement.dataset.theme = saved;
  const btn = $("#theme-toggle");
  if (btn) btn.addEventListener("click", () => {
    const cur = document.documentElement.dataset.theme
      || (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
    const next = cur === "light" ? "dark" : "light";
    document.documentElement.dataset.theme = next;
    localStorage.setItem("haven-theme", next);
  });
}

// First-run welcome (parity with iOS/Android): on a fresh install the backend has NO identity or
// engine, so we must show this BEFORE calling any engine command. "Create" mints a new identity;
// "Link" adopts a transfer code from another device. Both relaunch the app into the normal flow.
function renderOnboarding() {
  const brandMark = el("div", { class: "brand-mark", style: "width:64px;height:64px;border-radius:20px" });
  brandMark.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" style="width:34px;height:34px">
      <circle cx="6" cy="7" r="1.6" fill="white"/><circle cx="18" cy="6" r="1.6" fill="white"/>
      <circle cx="12" cy="13" r="1.8" fill="white"/><circle cx="5" cy="17" r="1.6" fill="white"/>
      <circle cx="19" cy="17" r="1.6" fill="white"/>
      <path d="M6 7l6 6 6-7M12 13l-7 4M12 13l7 4" opacity="0.85"/></svg>`;

  const code = el("input", { placeholder: "haven-seed:…", style: "width:100%;margin-top:10px" });
  const linkBox = el("div", { class: "col", style: "display:none;width:100%;margin-top:14px;gap:8px" },
    el("div", { class: "muted small" }, "On your other device open You ▸ Link a new device, copy its transfer code, then paste it here."),
    code,
    el("button", { class: "btn primary", style: "width:100%", onclick: async () => {
      const c = code.value.trim();
      if (!c) { toast("Paste a transfer code first"); return; }
      try { await invoke("onboard_link", { code: c }); } // relaunches into the linked identity
      catch (e) { toast("Couldn't link: " + e); }
    } }, "Link this device"),
  );

  const card = el("div", { style: "max-width:420px;width:100%;display:flex;flex-direction:column;align-items:center;text-align:center;gap:6px" },
    brandMark,
    el("h1", { style: "font-size:34px;font-weight:800;margin:10px 0 0" }, "Haven"),
    el("p", { class: "muted", style: "margin:0 0 6px" }, "Your friends and your family. That's the whole product."),
    el("button", { class: "btn primary", style: "width:100%;margin-top:18px;padding:12px", onclick: async () => {
      try { await invoke("onboard_create"); } // relaunches into the new identity
      catch (e) { toast("Couldn't create: " + e); }
    } }, "Create my Haven"),
    el("button", { class: "btn ghost", style: "width:100%", onclick: () => { linkBox.style.display = "flex"; code.focus(); } }, "Already use Haven? Link this device"),
    linkBox,
    el("p", { class: "muted small", style: "margin-top:18px" }, "No phone number. No email. Your keys never leave this device."),
  );

  const overlay = el("div", { id: "onboard-overlay", style: "position:fixed;inset:0;z-index:9999;display:flex;align-items:center;justify-content:center;padding:32px;background:var(--bg, #0d0b1a)" }, card);
  document.body.append(overlay);
}

async function boot() {
  initTheme();
  // Fresh install → no identity/engine yet. Show the welcome screen and stop before touching any
  // engine command (which would error). onboard_create/onboard_link relaunch into the real app.
  try {
    if (await invoke("needs_onboarding")) { renderOnboarding(); return; }
  } catch (_) {}
  $$(".nav-btn").forEach((b) => b.addEventListener("click", () => switchView(b.dataset.view)));
  try {
    const b = await invoke("bootstrap");
    state.node = b.node_id_hex;
    state.inviteUri = b.invite_uri;
    state.inviteLink = b.invite_link;
    state.profile = b.profile;
    $("#nav-node").textContent = b.node_id_hex.slice(0, 10) + "…";
  } catch (e) {
    $("#nav-node").textContent = "core error";
    toast("Backend not ready: " + e);
  }
  await refreshStatus();
  await refreshBadges();
  await render();

  // First-run nudge to set a name.
  if (!state.profile.name) switchView("you");

  try { state.contacts = await invoke("contacts"); } catch (_) {}
  try { state.videoSoundOn = await invoke("video_sound_on"); } catch (_) { state.videoSoundOn = false; }
  listen("haven:changed", async () => {
    await refreshStatus(); await refreshBadges();
    try { state.contacts = await invoke("contacts"); } catch (_) {}
    // Don't yank the profile editor out from under the user mid-type on a background sync — re-rendering
    // the "you" view rebuilds its inputs and discards what they're typing.
    const ae = document.activeElement;
    if (state.view === "you" && ae && (ae.tagName === "INPUT" || ae.tagName === "TEXTAREA") && $("#view-you").contains(ae)) return;
    await render();
  });
  listen("haven:notify", (e) => { const p = e.payload || {}; toast(`${p.title}: ${p.body}`); });
  listen("haven:call", (e) => onCallEvent(e.payload));
  // Drag photos/videos from the file manager onto the window → attach to the active composer.
  const MEDIA_RE = { img: /\.(jpe?g|png|gif|heic|heif|webp|bmp|tiff?)$/i, vid: /\.(mp4|mov|m4v|webm|avi|mkv|3gp)$/i };
  listen("tauri://drag-enter", () => document.body.classList.add("drop-target"));
  listen("tauri://drag-leave", () => document.body.classList.remove("drop-target"));
  listen("tauri://drag-drop", async (e) => {
    document.body.classList.remove("drop-target");
    const paths = e.payload?.paths || [];
    if (!paths.length || typeof state.composerAdd !== "function") return;
    for (const p of paths) {
      const isVideo = MEDIA_RE.vid.test(p);
      if (!isVideo && !MEDIA_RE.img.test(p)) continue;   // skip non-media files
      try {
        const ref = await invoke("add_media_path", { circleId: state.composerCircle || state.activeCircle, path: p });
        await state.composerAdd(ref, isVideo, false);
      } catch (err) { console.error("drop ingest failed", p, err); toast("Couldn't attach that file"); }
    }
  });
  setInterval(refreshStatus, 5000);

  // Tell the backend whether the window is foregrounded (suppress notifications when it is).
  invoke("set_foreground", { fg: document.hasFocus() }).catch(() => {});
  window.addEventListener("focus", () => invoke("set_foreground", { fg: true }).catch(() => {}));
  window.addEventListener("blur", () => invoke("set_foreground", { fg: false }).catch(() => {}));
}

window.addEventListener("DOMContentLoaded", boot);

// macOS-style titlebar window controls (traffic lights). `withGlobalTauri` exposes the window API.
(() => {
  const w = window.__TAURI__?.window?.getCurrentWindow?.();
  if (!w) return; // not running under Tauri (e.g. the browser style gallery) — buttons are inert
  const on = (id, fn) => document.getElementById(id)?.addEventListener("click", fn);
  on("win-close", () => w.close());
  on("win-min", () => w.minimize());
  on("win-max", () => w.toggleMaximize());
})();
