// Haven desktop frontend. Talks to the Rust backend (which links the shared core) via
// Tauri `invoke`. No framework — small DOM helpers + per-view render functions, re-rendered
// when the backend emits `haven:changed`.

const TAURI = window.__TAURI__ || {};
const invoke = TAURI.core ? TAURI.core.invoke : async () => { throw new Error("Tauri not ready"); };
const listen = TAURI.event ? TAURI.event.listen : async () => {};

// Whose window chrome are we inside? Only macOS draws its own titlebar (`decorations: false`);
// Windows and Linux are handed their OS's real one by `apply_window_chrome`, so this decides
// exactly one thing: whether to draw the traffic lights.
//
// The UA is deliberate. It is the only SYNCHRONOUS signal — `plugin-os`'s `platform()` and a
// bespoke `invoke` are both an IPC round-trip, and the titlebar has to be right on the first paint
// or the controls visibly rearrange. The CSS defaults to NO traffic lights, so the worst this can
// do is show them a frame late on macOS; it can never flash them onto Windows.
const HOST_OS = /Windows|Win64|WOW64/i.test(navigator.userAgent) ? "windows"
  : /Macintosh|Mac OS X/i.test(navigator.userAgent) ? "macos"
  : "linux";
document.documentElement.dataset.os = HOST_OS;

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

/** `onClick` makes the toast an affordance rather than an announcement — used where the notification
 *  is ABOUT something openable (e.g. "your media is back", which should land you on the post). The
 *  handler is cleared on every toast, so a plain one can never inherit the last one's action. */
function toast(msg, onClick) {
  const t = $("#toast");
  t.textContent = msg;
  t.classList.add("show");
  t.onclick = onClick ? () => { t.classList.remove("show"); onClick(); } : null;
  t.style.cursor = onClick ? "pointer" : "";
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.remove("show"), onClick ? 6000 : 2200);
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
  // Anything presented over the feed silences what the feed was playing (iOS parity: a sheet or
  // cover stops the post soundtrack behind it). Runs BEFORE the overlay's own content is inserted,
  // so a story viewer's clip — created below — is untouched.
  pauseFeedMedia();
  const root = $("#modal-root");
  const backdrop = el("div", { class: "modal-backdrop", onclick: (e) => { if (e.target === backdrop) root.replaceChildren(); } }, node);
  node.classList.add("modal", "plain");
  root.replaceChildren(backdrop);
  return () => root.replaceChildren();
}
const closeModal = () => $("#modal-root").replaceChildren();

/** A sheet the Haven way — the port of `HavenMacSheet` (apple/HavenApp/Theme.swift). The brand
 *  gradient runs to the sheet's EXTREME edges (never a grey band above or below), the title sits
 *  inline with a glass close circle, and the footer holds the one prominent action. Esc closes,
 *  same as the Mac's `.keyboardShortcut(.cancelAction)`. */
function sheet(title, body, foot) {
  pauseFeedMedia();   // same as modal(): a sheet covers the feed, so the feed goes quiet behind it
  const root = $("#modal-root");
  const card = el("div", { class: "modal" },
    el("div", { class: "modal-head" },
      el("h2", {}, title),
      el("button", { class: "icon-btn glass", title: "Close", onclick: () => closeModal() }, icon("xmark")),
    ),
    el("div", { class: "modal-body" }, ...[body].flat().filter(Boolean)),
    foot ? el("div", { class: "modal-foot" }, foot) : null,
  );
  const backdrop = el("div", { class: "modal-backdrop", onclick: (e) => { if (e.target === backdrop) closeModal(); } }, card);
  root.replaceChildren(backdrop);
  return closeModal;
}
window.addEventListener("keydown", (e) => { if (e.key === "Escape") { closeModal(); closeMenu(); } });

// ---- icons -------------------------------------------------------------------------------
// Stroked glyphs shaped after the SF Symbols the macOS build names, so the two read as one app.
// `fill` entries are filled shapes (paperplane.fill, person.2.fill…) — the rest stroke.
const ICONS = {
  "chevron.down": { d: "M4 8l6 6 6-6" },
  "chevron.right": { d: "M9 5l7 7-7 7" },
  "person.2.fill": { fill: true, d: "M9 11.2a3.4 3.4 0 100-6.8 3.4 3.4 0 000 6.8zm7 .3a2.9 2.9 0 100-5.8 2.9 2.9 0 000 5.8zM9 12.8c-3 0-5.6 1.7-5.6 3.9v1.1a.8.8 0 00.8.8h9.6a.8.8 0 00.8-.8v-1.1c0-2.2-2.6-3.9-5.6-3.9zm7 .2c-.7 0-1.4.1-2 .3 1.2 1 1.9 2.2 1.9 3.4v1.9h4.3a.8.8 0 00.8-.8v-.9c0-2-2.3-3.9-5-3.9z" },
  // Stroked, not filled: the filled gear's teeth collapse into an unreadable blob at a 16px chip.
  "gearshape.fill": { w: 1.6, d: "M12 15a3 3 0 100-6 3 3 0 000 6z", extra: "M19.1 14.6a1.6 1.6 0 00.3 1.8l.1.1a1.9 1.9 0 11-2.7 2.7l-.1-.1a1.6 1.6 0 00-1.8-.3 1.6 1.6 0 00-1 1.5v.2a1.9 1.9 0 11-3.8 0v-.1a1.6 1.6 0 00-1-1.5 1.6 1.6 0 00-1.8.3l-.1.1a1.9 1.9 0 11-2.7-2.7l.1-.1a1.6 1.6 0 00.3-1.8 1.6 1.6 0 00-1.5-1h-.2a1.9 1.9 0 110-3.8h.1a1.6 1.6 0 001.5-1 1.6 1.6 0 00-.3-1.8l-.1-.1a1.9 1.9 0 112.7-2.7l.1.1a1.6 1.6 0 001.8.3h.1a1.6 1.6 0 001-1.5v-.2a1.9 1.9 0 113.8 0v.1a1.6 1.6 0 001 1.5 1.6 1.6 0 001.8-.3l.1-.1a1.9 1.9 0 112.7 2.7l-.1.1a1.6 1.6 0 00-.3 1.8v.1a1.6 1.6 0 001.5 1h.2a1.9 1.9 0 110 3.8h-.1a1.6 1.6 0 00-1.5 1z" },
  "paperplane.fill": { fill: true, d: "M3.2 11.3l16.4-7.2c.7-.3 1.4.4 1.1 1.1l-7.2 16.4c-.3.7-1.3.7-1.5-.1l-1.9-6.3-6.3-1.9c-.8-.2-.8-1.2-.1-1.5z" },
  "plus": { d: "M12 5v14M5 12h14", w: 2.4 },
  "xmark": { d: "M6 6l12 12M18 6L6 18", w: 2.2 },
  "camera.fill": { fill: true, d: "M9.4 4.5l-1.2 2H5a2 2 0 00-2 2v9a2 2 0 002 2h14a2 2 0 002-2v-9a2 2 0 00-2-2h-3.2l-1.2-2H9.4zM12 17.2a4.1 4.1 0 110-8.2 4.1 4.1 0 010 8.2z" },
  "ellipsis": { fill: true, d: "M6 10.2a1.8 1.8 0 100 3.6 1.8 1.8 0 000-3.6zm6 0a1.8 1.8 0 100 3.6 1.8 1.8 0 000-3.6zm6 0a1.8 1.8 0 100 3.6 1.8 1.8 0 000-3.6z" },
  "link": { d: "M9 15l6-6M11 6l1.5-1.5a3.5 3.5 0 015 5L17 11M13 18l-1.5 1.5a3.5 3.5 0 01-5-5L8 13" },
  "square.and.pencil": { d: "M20 10.5V19a2 2 0 01-2 2H6a2 2 0 01-2-2V7a2 2 0 012-2h8.5", extra: "M18.4 3.6a2 2 0 012.8 2.8L13 14.6l-3.6.9.9-3.6 8.1-8.3z" },
  "phone.fill": { fill: true, d: "M6.6 3.5c.6-.1 1.2.2 1.5.8l1.3 2.6c.3.6.2 1.3-.3 1.7l-1.2 1a12 12 0 005.5 5.5l1-1.2c.4-.5 1.1-.6 1.7-.3l2.6 1.3c.6.3.9.9.8 1.5l-.4 2.3c-.1.7-.7 1.2-1.4 1.2C9.9 20 4 14.1 3.1 5.3c0-.7.5-1.3 1.2-1.4l2.3-.4z" },
  "video.fill": { fill: true, d: "M3 7.5A2.5 2.5 0 015.5 5h7A2.5 2.5 0 0115 7.5v9a2.5 2.5 0 01-2.5 2.5h-7A2.5 2.5 0 013 16.5v-9zm14 2.3l3.3-2.2c.6-.4 1.4 0 1.4.8v7.2c0 .8-.8 1.2-1.4.8L17 14.2V9.8z" },
  "pencil.circle.fill": { fill: true, d: "M12 2a10 10 0 100 20 10 10 0 000-20zm3.9 6.1a1 1 0 010 1.4l-.9.9-2.4-2.4.9-.9a1 1 0 011.4 0l1 1zM8 13.6l3.6-3.6 2.4 2.4L10.4 16H8v-2.4z" },
  "paperclip": { d: "M20 11.5l-8.2 8.2a4.6 4.6 0 01-6.5-6.5l8.4-8.4a3.1 3.1 0 014.4 4.4l-8.4 8.4a1.5 1.5 0 01-2.2-2.2l7.7-7.7" },
  "antenna": { d: "M12 9.8a2.2 2.2 0 100 4.4 2.2 2.2 0 000-4.4M7.5 7.5a6 6 0 000 9M16.5 7.5a6 6 0 010 9M4.7 4.7a10 10 0 000 14.6M19.3 4.7a10 10 0 010 14.6" },
  "photo": { d: "M3 6a2 2 0 012-2h14a2 2 0 012 2v12a2 2 0 01-2 2H5a2 2 0 01-2-2V6zM3 16l5-5 4 4 3-3 6 6" },
  "folder": { d: "M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V7z" },
  "mic": { d: "M12 3a3 3 0 00-3 3v6a3 3 0 006 0V6a3 3 0 00-3-3zM5.5 11.5a6.5 6.5 0 0013 0M12 18v3" },
  "music.note": { d: "M9 18V5l11-2v13", w: 1.7, extra: "M9 18a2.5 2.5 0 11-5 0 2.5 2.5 0 015 0zM20 16a2.5 2.5 0 11-5 0 2.5 2.5 0 015 0z" },
  "mappin": { d: "M12 21s7-6.3 7-11a7 7 0 10-14 0c0 4.7 7 11 7 11z", extra: "M12 12.5a2.5 2.5 0 100-5 2.5 2.5 0 000 5z" },
  "timer": { d: "M12 21a8 8 0 100-16 8 8 0 000 16zM12 9v4l2.5 2M9 2h6" },
  "clock": { d: "M12 21a9 9 0 100-18 9 9 0 000 18zM12 7v5l3.5 2" },
  "eye": { d: "M2 12s3.6-6.5 10-6.5S22 12 22 12s-3.6 6.5-10 6.5S2 12 2 12z", extra: "M12 15a3 3 0 100-6 3 3 0 000 6z" },
  "eye.slash": { d: "M4 4l16 16M9.9 5.7A9.9 9.9 0 0112 5.5c6.4 0 10 6.5 10 6.5a17 17 0 01-3.5 4.2M6.4 7.6A16.6 16.6 0 002 12s3.6 6.5 10 6.5c1 0 1.9-.1 2.7-.4" },
  "speaker": { d: "M4 9.5h3.5L12 5.5v13L7.5 14.5H4v-5z", extra: "M16 9a4 4 0 010 6M18.8 6.5a8 8 0 010 11" },
  "speaker.slash": { d: "M4 9.5h3.5L12 5.5v13L7.5 14.5H4v-5z", extra: "M16.5 9.5l5 5M21.5 9.5l-5 5" },
  "square.and.arrow.up": { d: "M12 15V4M8.5 7.5L12 4l3.5 3.5M5 13v5a2 2 0 002 2h10a2 2 0 002-2v-5" },
  "flag": { d: "M5 21V4M5 5h11l-2 3.5L16 12H5" },
  "hand.raised.fill": { fill: true, d: "M12 2a1.4 1.4 0 00-1.4 1.4V11H9.9V4.6a1.4 1.4 0 10-2.8 0v8.9l-1.3-1.9a1.4 1.4 0 00-2.3 1.6l3 4.6A6 6 0 0017.6 20l1.8-3.4c.3-.5.4-1 .4-1.6V6.6a1.4 1.4 0 10-2.8 0V11h-.7V4.6a1.4 1.4 0 10-2.8 0V11h-.7V3.4A1.4 1.4 0 0012 2z" },
  "person.badge.plus": { d: "M11 12.5a4 4 0 100-8 4 4 0 000 8zM3.5 20a7.5 7.5 0 0112.2-5.8M18 14v6M15 17h6" },
  "sparkles": { fill: true, d: "M12 2.5l1.7 4.6 4.6 1.7-4.6 1.7L12 15.1l-1.7-4.6L5.7 8.8l4.6-1.7L12 2.5zM19 14l.9 2.4 2.4.9-2.4.9-.9 2.4-.9-2.4-2.4-.9 2.4-.9L19 14zM5.5 14.5l.7 1.9 1.9.7-1.9.7-.7 1.9-.7-1.9L2.9 17l1.9-.7.7-1.8z" },
  "laptop": { d: "M5 6a1 1 0 011-1h12a1 1 0 011 1v9H5V6zM2.5 18.5h19" },
  "icloud": { d: "M7 18.5h10.5a3.5 3.5 0 00.4-7A5.5 5.5 0 007.3 9.6 4.5 4.5 0 007 18.5z" },
  "internaldrive": { d: "M4 6a2 2 0 012-2h12a2 2 0 012 2v12a2 2 0 01-2 2H6a2 2 0 01-2-2V6z", extra: "M8 15.5h.01M4 12h16" },
  "wrench": { d: "M15.5 3.5a5 5 0 00-4.8 6.4L3.6 17l3.4 3.4 7.1-7.1a5 5 0 006.4-4.8l-3.1 3.1-2.8-.6-.6-2.8 3.1-3.1a5 5 0 00-1.6-.6z" },
  "arrow.counterclockwise": { d: "M4 4v6h6M4.6 14a8 8 0 103-8.5L4 10" },
  "moon": { d: "M20 14.5A8.5 8.5 0 019.5 4a8.5 8.5 0 1010.5 10.5z" },
  "checkmark": { d: "M4.5 12.5l5 5 10-11", w: 2.4 },
  "circle.dashed": { d: "M12 3.8a8.2 8.2 0 010 16.4 8.2 8.2 0 010-16.4", dash: "2.6 2.6" },
  "plus.circle": { d: "M12 21a9 9 0 100-18 9 9 0 000 18zM12 8.2v7.6M8.2 12h7.6" },
  "arrow.uturn.backward": { d: "M9 14l-5-5 5-5M4 9h9a6 6 0 010 12H8" },
  "lock.shield.fill": { fill: true, d: "M12 2L4 5v6.5c0 5 3.4 9.6 8 10.5 4.6-.9 8-5.5 8-10.5V5l-8-3zm0 6.2a2.3 2.3 0 012.3 2.3v1h.4a.8.8 0 01.8.8v3.4a.8.8 0 01-.8.8H9.3a.8.8 0 01-.8-.8v-3.4a.8.8 0 01.8-.8h.4v-1A2.3 2.3 0 0112 8.2zm0 1.4a.9.9 0 00-.9.9v1h1.8v-1a.9.9 0 00-.9-.9z" },
  "bell": { d: "M12 4a5.4 5.4 0 00-5.4 5.4v3.1L5 15.6a.8.8 0 00.7 1.2h12.6a.8.8 0 00.7-1.2l-1.6-3.1V9.4A5.4 5.4 0 0012 4zM10 19.2a2.1 2.1 0 004 0" },
};
/** One glyph as an <svg>. `cls` lands on the element so callers can size it. */
function icon(name, cls) {
  const spec = ICONS[name];
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  if (cls) svg.setAttribute("class", cls);
  if (!spec) return svg;
  svg.setAttribute("fill", spec.fill ? "currentColor" : "none");
  if (!spec.fill) {
    svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("stroke-width", String(spec.w || 1.7));
    svg.setAttribute("stroke-linecap", "round");
    svg.setAttribute("stroke-linejoin", "round");
  }
  for (const d of [spec.d, spec.extra].filter(Boolean)) {
    const p = document.createElementNS("http://www.w3.org/2000/svg", "path");
    p.setAttribute("d", d);
    if (spec.dash) p.setAttribute("stroke-dasharray", spec.dash);
    svg.append(p);
  }
  return svg;
}

// ---- anchored menu (SwiftUI `Menu`) ------------------------------------------------------
// The macOS build uses `Menu` for the circle switcher, the composer's `+`, and a post's `···`.
// A full modal for those was the wrong weight entirely — this pops a small panel at the control.
function closeMenu() { $("#menu-root").replaceChildren(); }
/** items: {label, icon, danger, head, sep, on} — `head` renders a section label, `sep` a rule. */
function popMenu(anchor, items, opts = {}) {
  const root = $("#menu-root");
  const menu = el("div", { class: "menu glass" });
  for (const it of items.filter(Boolean)) {
    if (it.sep) { menu.append(el("hr", {})); continue; }
    if (it.head) { menu.append(el("div", { class: "menu-head" }, it.head)); continue; }
    menu.append(el("button", { class: it.danger ? "danger" : "", onclick: () => { closeMenu(); it.on && it.on(); } },
      el("span", { class: "mi" }, it.icon ? icon(it.icon, "mi-svg") : ""),
      el("span", {}, it.label)));
  }
  const backdrop = el("div", { class: "menu-backdrop", onclick: closeMenu });
  root.replaceChildren(backdrop, menu);
  // Position under the anchor, flipped to stay on screen.
  const r = anchor.getBoundingClientRect();
  const mw = menu.offsetWidth, mh = menu.offsetHeight;
  let left = opts.align === "right" ? r.right - mw : r.left;
  left = Math.max(8, Math.min(left, window.innerWidth - mw - 8));
  let top = r.bottom + 6;
  if (top + mh > window.innerHeight - 8) top = Math.max(8, r.top - mh - 6);
  menu.style.left = left + "px";
  menu.style.top = top + "px";
}
// Menu SVGs inherit the row's color and need a concrete size.
const MENU_ICON_CSS = ".menu .mi-svg{width:15px;height:15px;display:block;margin:0 auto}";
document.head.append(el("style", {}, MENU_ICON_CSS));

// Human byte size (e.g. "1.2 GB"). Module-level so the media-cleanup screen, the evicted placeholder
// and the Storage card all format identically.
function fmtBytes(n) {
  if (!n) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0, v = n;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v >= 10 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}

// Decrypt + lazy-load a media ref into an <img>/<video>. When the bytes aren't on disk, distinguish
// two cases (iOS MissingMediaPlaceholder parity): a ref the user DELIBERATELY evicted (#3 cleanup /
// #4 limit sweep) renders a "Download N" affordance (re-fetch on tap — never auto-refetched, or the
// cleanup would silently undo itself); anything else is simply still syncing.
async function loadMedia(node, circleId, ref) {
  try {
    const url = await invoke("media_data_url", { circleId, reference: ref });
    if (url) { node.src = url; return; }
    const isVideo = isVideoRef(ref);
    // Which post this tile sits in, if any — read off the card rather than threaded through every
    // gallery/pager helper in between. Absent for a tile that isn't inside a post (a DM attachment,
    // a profile header), where the ask simply isn't offered rather than guessing at an author.
    const card = node.closest?.("[data-post]");
    const post = card ? { circleId, postId: card.dataset.post, authorShort: card.dataset.author, isMe: !!card.dataset.mine } : null;
    const bytes = await invoke("media_evicted_size", { reference: ref }).catch(() => null);
    if (bytes != null) node.replaceWith(evictedPlaceholder(circleId, ref, bytes, isVideo, post));
    else node.replaceWith(syncingPlaceholder(circleId, ref, isVideo));
  } catch (_) {}
}

// Honest still-syncing placeholder (iOS MissingMediaPlaceholder parity): the post's blurred
// `thumb:` companion behind the spinner when one is held (real shape and color instead of a grey
// box), "Still loading…" while the engine's sweeps fetch, and a terminal "Not available yet" +
// Retry once polling gives up — never a spinner that lies forever.
function syncingPlaceholder(circleId, ref, isVideo) {
  const box = el("div", { class: "media-evicted", style: "position:relative;overflow:hidden" });
  const t = ThumbIndex.thumbFor(ref);
  if (t) {
    invoke("media_data_url", { circleId, reference: t }).then((u) => {
      if (!u || !box.isConnected) return;
      box.prepend(el("img", {
        src: u,
        style: "position:absolute;inset:0;width:100%;height:100%;object-fit:cover;filter:blur(12px);opacity:.75;z-index:0",
      }));
    }).catch(() => {});
  }
  const front = el("div", { class: "col", style: "position:relative;z-index:1;align-items:center;gap:6px" });
  box.append(front);
  const waiting = () => front.replaceChildren(
    el("div", { class: "spinner" }),
    el("div", { class: "muted small" }, isVideo ? "Video still loading…" : "Still loading…"));
  const gone = () => front.replaceChildren(
    el("div", { class: "muted small" }, "Not available yet"),
    el("button", { class: "btn small", onclick: () => {
      invoke("media_download", { reference: ref }).catch(() => {});
      start();
    } }, "Retry"));
  let timer = null;
  const start = () => {
    waiting();
    let waited = 0;
    clearTimeout(timer);
    const tick = async () => {
      if (!box.isConnected) return;   // card re-rendered underneath us — stop polling
      const url = await invoke("media_data_url", { circleId, reference: ref }).catch(() => null);
      if (url) { const n = mediaNode(ref); box.replaceWith(n); loadMedia(n, circleId, ref); return; }
      waited += 2000;
      if (waited >= 45000) { gone(); return; }
      timer = setTimeout(tick, 2000);
    };
    timer = setTimeout(tick, 2000);
  };
  start();
  return box;
}

// The #3 placeholder for a deliberately-evicted blob: a tap re-fetches it (media_download clears the
// eviction first, then pulls it relay-first with a peer fallback). Spinner while pending; "No longer
// available" + Retry if it hasn't arrived after ~45s (relay/peers don't have it either).
function evictedPlaceholder(circleId, ref, bytes, isVideo, post) {
  const box = el("div", { class: "media-evicted" });
  // A relay's retention swept this, but the AUTHOR probably still has the original. Asking them is
  // the difference between "gone" and "gone from the relay". Nothing to ask for on your own post:
  // you ARE the author, so if the bytes are gone here they're gone everywhere.
  const askBack = async () => {
    await invoke("media_request_when_available", {
      reference: ref, circleId: post.circleId, postId: post.postId, authorShort: post.authorShort,
    }).catch(() => {});
    draw("gone");
  };
  const draw = async (mode) => {
    if (mode === "loading") {
      box.replaceChildren(el("div", { class: "spinner" }), el("div", { class: "muted small" }, "Downloading…"));
      return;
    }
    if (mode === "gone") {
      const wanted = await invoke("media_is_wanted", { reference: ref }).catch(() => false);
      box.replaceChildren(
        el("div", { class: "muted small" }, "No longer available"),
        el("button", { class: "btn small", onclick: () => start() }, "Retry"),
        wanted
          ? el("div", { class: "muted small" }, "🔔 We'll tell you when it's back")
          : post && !post.isMe
            ? el("button", { class: "btn small primary", onclick: askBack }, "Ask for it back")
            : null);
      return;
    }
    box.replaceChildren(
      el("button", { class: "btn small primary", onclick: () => start() },
        `⬇ Download ${fmtBytes(bytes)}`),
      el("div", { class: "muted small" }, "Removed to save space"));
  };
  const start = async () => {
    draw("loading");
    try { await invoke("media_download", { reference: ref }); } catch (_) {}
    // Poll for arrival; the engine emits haven:changed on success and re-renders the feed, but poll
    // as a fallback so this tile resolves even if the render is coalesced away.
    let waited = 0;
    const tick = async () => {
      const url = await invoke("media_data_url", { circleId, reference: ref }).catch(() => null);
      if (url) { const n = mediaNode(ref); box.replaceWith(n); loadMedia(n, circleId, ref); return; }
      waited += 1500;
      if (waited >= 45000) { draw("gone"); return; }
      setTimeout(tick, 1500);
    };
    setTimeout(tick, 1500);
  };
  draw("offer");
  return box;
}

// ---- app state -------------------------------------------------------------------------
const state = {
  view: "circle",
  node: "",
  inviteUri: "",
  inviteLink: "",
  profile: {},
  // An UNSENT draft staged for a thread we're about to open ("Message the author" on a post):
  // { id, text }, consumed once by renderThread's composer and then cleared.
  pendingDraft: null,
  activeCircle: "default",
  activeDm: null,
  attachments: [], // {ref, url, isVideo}
  // Media refs the CIRCLE flagged sensitive (see sensitiveGuard). Refreshed with each feed/thread
  // render, like reportsByTarget — a Set so the per-item check during render is free.
  sensitive: new Set(),
  // Device-local (Apple superDataSaver parity) — mute/skip autoplay when true.
  superDataSaver: false,
  videoSoundOn: false,
};

// ---- navigation ------------------------------------------------------------------------
// There are EXACTLY THREE destinations, and they are the macOS build's: Circle | Messages | You
// (apple/HavenApp/HavenApp.swift ▸ `main`'s TabView). Everything that used to be a sidebar item
// lives where macOS puts it instead:
//   • Stories → the stories tray at the TOP OF THE CIRCLE FEED (FeedView ▸ storiesTray)
//   • Connect → a SHEET off the manage-circle button / the pending banner (ContentView ▸ .sheet)
//   • Relay   → Settings ▸ Relays, off the You tab's gear (Settings.swift ▸ RelaysView)
function switchView(view) {
  state.view = view;
  $$(".tab").forEach((b) => b.classList.toggle("active", b.dataset.view === view));
  $$(".view").forEach((v) => v.classList.toggle("active", v.id === `view-${view}`));
  render();
}

async function render() {
  renderTitlebarTrailing();
  // The floating composer belongs to the Circle feed only; it is pinned to `.content`, so leaving
  // the tab has to take it down explicitly (renderFeed puts it back). Its 2.5s sync poll goes too,
  // or it keeps hitting the backend for a circle you're no longer looking at.
  if (state.view !== "circle") {
    $("#composer-slot").replaceChildren();
    if (state.syncTimer) { clearInterval(state.syncTimer); state.syncTimer = null; }
  }
  switch (state.view) {
    case "circle": return renderFeed();
    case "messages": return renderMessages();
    case "you": return renderYou();
  }
}

/** The toolbar's trailing slot is PER-TAB, exactly like macOS: the Circle tab carries the circle
 *  switcher + manage-circle button; the You tab carries the settings gear; Messages carries
 *  nothing. (macOS: `ToolbarItem(placement: .havenTrailing)` declared inside each tab's view.) */
function renderTitlebarTrailing() {
  const slot = $("#tb-right");
  if (!slot) return;
  if (state.view === "circle") {
    const pill = el("button", { class: "circle-pill glass tint-pink", onclick: () => circleMenu(pill) },
      icon("chevron.down", "chev"), el("span", { id: "tb-circle-name" }, state.activeCircleName || "My Circle"));
    slot.replaceChildren(pill,
      el("button", { class: "icon-btn glass tint-pink pink", title: "Manage circle", "aria-label": "Manage circle",
        onclick: () => circleSheet() }, icon("person.2.fill")));
  } else if (state.view === "you") {
    slot.replaceChildren(el("button", { class: "icon-btn glass", title: "Settings", "aria-label": "Settings",
      onclick: () => settingsSheet() }, icon("gearshape.fill")));
  } else if (state.view === "messages" && !state.activeDm) {
    // macOS `MessagesView`'s toolbar: a `square.and.pencil` glass chip that opens the contact picker.
    slot.replaceChildren(el("button", { class: "icon-btn glass", title: "New message", "aria-label": "New message",
      onclick: () => newMessageSheet() }, icon("square.and.pencil")));
  } else {
    slot.replaceChildren();
  }
}

/** The circle switcher menu — macOS `circlePicker`: the circles, then show/hide hidden posts,
 *  then "New circle…". */
async function circleMenu(anchor) {
  const circles = await invoke("circles").catch(() => []);
  const items = circles.map((c) => ({
    label: `${circleDisplayName(c.id, c.name)} (${c.member_count})`,
    icon: c.id === state.activeCircle ? "checkmark" : "circle.dashed",
    on: () => { state.activeCircle = c.id; renderFeed(); renderTitlebarTrailing(); },
  }));
  items.push({ sep: true });
  if (Hidden.ids.size) {
    items.push({
      label: Hidden.showHidden ? "Hide hidden posts" : `Show hidden posts (${Hidden.ids.size})`,
      icon: Hidden.showHidden ? "eye.slash" : "eye",
      on: () => { Hidden.toggle(); renderFeed(); },
    });
  }
  items.push({ label: "New circle…", icon: "plus.circle", on: newCircleDialog });
  popMenu(anchor, items, { align: "right" });
}

async function refreshBadges() {
  try {
    // The Circle tab carries pending connection requests, exactly like macOS — that's where the
    // banner that acts on them lives. (HavenApp.swift: `.badge(unseenCircle + pending.count)`.)
    const pend = await invoke("pending");
    const b = $("#badge-circle");
    b.textContent = pend.length;
    b.classList.toggle("show", pend.length > 0);
  } catch (_) {}
  try {
    // Messages badge = CONVERSATIONS with unread messages (per-thread read watermarks, iOS parity).
    // Opening the tab clears nothing — each thread clears as it's actually viewed.
    const dms = await invoke("dm_threads");
    const unread = dms.filter((t) => (t.unread || 0) > 0).length;
    const b = $("#badge-messages");
    b.textContent = unread;
    b.classList.toggle("show", unread > 0);
  } catch (_) {}
  try {
    // Bell badge = activity rows newer than the seen watermark (cleared by opening the panel —
    // on ANY of the user's devices, via the synced watermark).
    const a = await invoke("activity");
    const n = (a.rows || []).filter((r) => r.created_at > (a.seen_at || 0)).length;
    const b = $("#badge-bell");
    if (b) { b.textContent = n > 99 ? "99+" : n; b.classList.toggle("show", n > 0); }
  } catch (_) {}
}

// ---- Activity (the bell) -----------------------------------------------------------------
// The in-app notification list: who reacted / commented / voted / posted / messaged, newest-first,
// plus app-raised rows ("media is back"). Rows are styled like the Messages list; tapping one jumps
// through the same deep-link route table a pasted link uses. Opening marks everything seen
// (monotonic watermark, synced to your other devices via `setting:activitySeenAt`).
async function activityPanel() {
  const a = await invoke("activity").catch(() => ({ rows: [], seen_at: 0 }));
  const rows = a.rows || [], seenAt = a.seen_at || 0;
  invoke("mark_activity_seen").catch(() => {});
  const verb = (r) => {
    switch (r.kind) {
      case "react": return `Reacted ${r.emoji || "👍"}`;
      case "comment": return "Commented";
      case "vote": return "Voted";
      case "story": return "Shared a story";
      case "dm": return "Sent you a message";
      default: return "Posted";
    }
  };
  const list = el("div", { class: "thread-list" });
  if (!rows.length) {
    list.append(el("div", { class: "empty" },
      el("div", { class: "h" }, "Nothing yet"),
      el("div", {}, "Reactions, comments, new posts and messages land here.")));
  }
  // WINDOWED. An account that has been running a while accumulates thousands of activity rows, and
  // building a DOM node for every one of them froze the panel on open for what looked like a hang.
  // Render a page at a time; older rows cost nothing until asked for. Apple parity (ActivityView).
  const PAGE = 40;
  let shown = 0;
  const row = (r) => {
    const unread = r.created_at > seenAt;
    const title = r.kind === "app" ? (r.actor_name || "Haven") : `${r.actor_name || "Someone"} · ${verb(r)}`;
    return el("div", { class: "thread-item", onclick: async () => { closeModal(); if (r.link) await routeDeepLink(r.link); } },
      el("div", { class: "avatar" }, r.kind === "app" ? "🔔" : initials(r.actor_name || "?")),
      el("div", { style: "flex:1;min-width:0" },
        el("div", { class: "name" + (unread ? " unread" : "") }, title),
        el("div", { class: "preview" + (unread ? " unread" : ""), style: "white-space:nowrap;overflow:hidden;text-overflow:ellipsis" }, r.snippet || "")),
      el("div", { class: "muted small" }, relTime(r.created_at)),
    );
  };
  const more = el("button", { class: "btn small", onclick: () => showMore() }, "Show older");
  const showMore = () => {
    const next = rows.slice(shown, shown + PAGE);
    shown += next.length;
    for (const r of next) list.insertBefore(row(r), more);
    more.textContent = `Show older · ${rows.length - shown} left`;
    if (shown >= rows.length) more.remove();
  };
  if (rows.length) { list.append(more); showMore(); }
  sheet("Activity", list);
  refreshBadges();   // opening marked everything seen — clear the badge now, not on the next sync
}

/** Connection state for the feed's banner (macOS `banner` + `connectionText`) — a green dot and a
 *  plain sentence at the top of the feed. It is NOT chrome: there is no sidebar to pin it to. */
async function refreshStatus() {
  try {
    const s = await invoke("relay_status");
    state.status = s;
    const dot = $("#status-dot"), txt = $("#status-text");
    if (!dot || !txt) return;
    dot.classList.toggle("on", !!s.started);
    dot.classList.toggle("relay", !!s.hosting);
    txt.textContent = connectionText(s);
  } catch (_) {}
}

function connectionText(s) {
  if (!s || !s.started) return "Offline — posts sync when you reconnect";
  const paths = [];
  if (s.internet_active) paths.push("internet");
  if (s.hosting) paths.push("relaying here");
  if (!paths.length) return "Online — looking for your circle…";
  return "Connected · " + paths.join(" + ");
}

// ---- Deep links ------------------------------------------------------------------------
// Three shapes reach us, and they must be told apart BEFORE anything routes them:
//   https://wemiller.com/apps/haven/#p/<circleId>.<postId>   a shared post — the form we emit
//   haven://p/<circleId>/<postId>                            the same post, legacy scheme — parsed forever
//   https://wemiller.com/apps/haven/#<id>.<verify>           an invite (also haven://invite#<id>.<verify>)
// An invite's payload is ALSO `<a>.<b>` in the fragment, so an unguarded invite check swallows every
// post link — that exact bug is live in android/…/ShareInbox.kt:49. Hence: post marker first, always.
// Grammar mirrors apple/HavenApp/DeepLink.swift; see docs/LINK-SYSTEM.md ▸ "Post links".
//
// ⚠️ THE PAYLOAD RIDES IN THE #FRAGMENT — DO NOT "TIDY" IT INTO A PATH. ⚠️
// A browser never sends a fragment to the server, so wemiller.com's logs — and every CDN and proxy in
// between — see only `GET /apps/haven/`, never which post nor whose circle. A path form
// (`/apps/haven/p/<circle>/<post>`) would hand the host a readership map: reader IP × circle × post.
// That map is precisely what Haven exists not to create. The fragment IS the privacy property.
//
// The link is a pointer, not a capability: it carries no key. Only a device already in the circle can
// decrypt the post — everyone else gets "not found" from the core, link or no link.
// `path` MATCHES (every link form ever emitted starts here, including pre-`/open` ones already pasted
// into chat histories); `linkPath` is what we EMIT and the only path the mobile apps claim as a
// Universal Link / App Link — the rest of the site is marketing and must stay in the browser.
// See apple/HavenApp/ConnectView.swift ▸ HavenSite and docs/LINK-SYSTEM.md.
const HAVEN_SITE = { host: "wemiller.com", path: "/apps/haven", linkPath: "/apps/haven/open" };

const DeepLink = {
  /** The shareable link for a post — the ONE form we emit (the `haven://` shape stays read-only, so it
   *  can die out). Mirrors apple/HavenApp/DeepLink.swift ▸ postURL, and round-trips through `post()`
   *  below. Payload in the #fragment — read the banner above before touching this. */
  postLink(circleId, postId) {
    return `https://${HAVEN_SITE.host}${HAVEN_SITE.linkPath}/#p/${this._token(circleId)}.${this._token(postId)}`;
  },
  /** Percent-encode one fragment token with Apple's charset (DeepLink.swift ▸ fragmentToken):
   *  unreserved MINUS `.` and `/`, so our two delimiters stay unambiguous whatever an id contains — a
   *  DM circle id is `dm:<a>-<b>`, and a `.` in either token would split the pair in the wrong place.
   *  encodeURIComponent leaves `.!*'()` alone, hence the second pass. */
  _token(s) {
    return encodeURIComponent(String(s)).replace(/[.!*'()]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
  },
  /** → {circleId, postId} for EITHER post form, else null (invites and everything else fall through). */
  post(raw) {
    let u;
    try { u = new URL((raw || "").trim()); } catch (_) { return null; }
    if (u.protocol === "haven:") {
      // haven://p/<circle>/<post> — "p" parses as the host, the two ids as the path.
      if (u.hostname !== "p") return null;
      const parts = u.pathname.split("/").filter(Boolean);
      return parts.length >= 2 ? this._decode(parts[0], parts[1]) : null;
    }
    if (u.protocol !== "https:") return null;
    if (u.hostname.toLowerCase() !== HAVEN_SITE.host || !u.pathname.startsWith(HAVEN_SITE.path)) return null;
    // `u.hash` keeps the RAW percent-encoding, so we decode exactly once — after splitting on the
    // delimiters. Apple encodes both tokens with a charset that EXCLUDES `.` and `/`
    // (DeepLink.swift ▸ fragmentToken), so the split is exact whatever an id contains.
    const frag = u.hash.replace(/^#/, "");
    if (!frag.startsWith("p/")) return null;
    const body = frag.slice(2);
    const dot = body.indexOf(".");
    return dot > 0 ? this._decode(body.slice(0, dot), body.slice(dot + 1)) : null;
  },
  _decode(c, p) {
    try {
      const circleId = decodeURIComponent(c), postId = decodeURIComponent(p);
      return circleId && postId ? { circleId, postId } : null;
    } catch (_) { return null; }   // malformed %-escape
  },
  /** haven://m/<circle>[/<message>] — a notification's tap-target for a DM: open that Messages
   *  thread. Mirrors Apple DeepLink.interactionLink. */
  message(raw) {
    const parts = this._havenParts(raw, "m");
    if (!parts) return null;
    try {
      return { circleId: decodeURIComponent(parts[0]), messageId: parts[1] ? decodeURIComponent(parts[1]) : null };
    } catch (_) { return null; }
  },
  /** haven://c/<circle> — switch to that circle's feed. */
  circle(raw) {
    const parts = this._havenParts(raw, "c");
    if (!parts) return null;
    try { return { circleId: decodeURIComponent(parts[0]) }; } catch (_) { return null; }
  },
  /** Path segments of a `haven://<host>/…` link, or null when it isn't one. */
  _havenParts(raw, host) {
    let u;
    try { u = new URL((raw || "").trim()); } catch (_) { return null; }
    if (u.protocol !== "haven:" || u.hostname !== host) return null;
    const parts = u.pathname.split("/").filter(Boolean);
    return parts.length ? parts : null;
  },
};

/** Route a link from the OS or the Connect paste box. Post links are discriminated FIRST, so one can
 *  never be mistaken for an invite. Returns "post" | "invite" | null (null = not a Haven link). */
async function routeDeepLink(raw) {
  const p = DeepLink.post(raw);
  if (p) { await openPostLink(p.circleId, p.postId); return "post"; }
  const m = DeepLink.message(raw);
  if (m) { await openDmThread(m.circleId); return "dm"; }
  const c = DeepLink.circle(raw);
  if (c) {
    const circles = await invoke("circles").catch(() => []);
    if (!circles.some((x) => x.id === c.circleId)) { toast("That link points at a circle you're not in."); return "circle"; }
    state.activeCircle = c.circleId;
    state.activeDm = null;
    switchView("circle");
    return "circle";
  }
  try { return (await invoke("connect_by_link", { uri: (raw || "").trim() })) ? "invite" : null; }
  catch (_) { return null; }
}

// Open a DM thread from a deep link (haven://m/…): resolve its display name from the thread list
// and land in Messages with the thread open — the same plumbing a row tap uses.
async function openDmThread(circleId) {
  const threads = await invoke("dm_threads").catch(() => []);
  const t = threads.find((x) => x.circle_id === circleId);
  if (!t) { toast("That conversation isn't on this device yet."); state.activeDm = null; switchView("messages"); return; }
  state.activeDm = { id: t.circle_id, name: t.name };
  switchView("messages");
}

// Open the post a link points at: switch to its circle, then surface that post in the feed. Desktop has
// no single-post view (iOS opens a PostLinkView sheet), so "surface" = scroll it into view and flash it.
// Every way this can fail says WHICH way it failed — a link that quietly does nothing reads as a broken
// app, and the post genuinely may not be here: the link is a pointer, not a key.
async function openPostLink(circleId, postId) {
  const circles = await invoke("circles").catch(() => []);
  if (!circles.some((c) => c.id === circleId)) { toast("That post is in a circle you're not in."); return; }
  state.activeCircle = circleId;
  state.activeDm = null;
  state.focusPost = null;
  const items = await invoke("feed", { circleId }).catch(() => []);
  const it = items.find((i) => i.id === postId);
  if (it && !it.unsent && !it.story) {
    if (Hidden.has(postId)) Hidden.showHidden = true;   // opening a link is an explicit ask — don't hide it
    state.focusPost = postId;
  }
  switchView("circle");   // land them in the right circle either way — but never pretend we found the post
  if (!it) toast("That post hasn't reached this device yet, or it isn't in this circle.");
  else if (it.unsent) toast("That post was unsent.");
  else if (it.story) toast("That link points at a story — open it under Stories.");
}

// Scroll a linked-to post into view and flash it once. Consumed on the first render: the feed re-renders
// on every haven:changed, and a sticky focus would keep yanking the scroll position back.
function focusPostCard(root, postId) {
  state.focusPost = null;
  const card = $$("[data-post]", root).find((n) => n.dataset.post === postId);
  if (!card) return;
  card.scrollIntoView({ behavior: "smooth", block: "center" });
  card.classList.add("focus-flash");
  setTimeout(() => card.classList.remove("focus-flash"), 1800);
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
  /** Adopt the engine's synced copy (`setting:pinnedDMs` — pinning on the phone pins here too).
   *  A device that pinned before this shipped seeds the engine once from its localStorage. */
  async load() {
    try {
      const synced = await invoke("pinned_dms");
      if (!Array.isArray(synced)) return;
      if (!synced.length && this.ids.length) {
        await invoke("set_pinned_dms", { ids: this.ids }).catch(() => {});
      } else {
        this.ids = synced;
        localStorage.setItem("haven-dm-pinned", JSON.stringify(this.ids));
      }
    } catch (_) {}   // engine not ready — the localStorage copy still renders
  },
  _save() {
    localStorage.setItem("haven-dm-pinned", JSON.stringify(this.ids));
    invoke("set_pinned_dms", { ids: this.ids }).catch(() => {});
  },
};

// ---- Relay nudge -----------------------------------------------------------------------
// Port of apple/HavenApp/RelayNudge.swift. A circle with a handful of people stops being a
// two-devices-both-online proposition: the more members, the less often everyone overlaps, and the
// longer a post waits on its author to come back. A relay is the fix (relay/README.md).
//
// The bar is deliberately conservative: >2 OTHER members AND the circle has no relay of its OWN. The
// all-circles DEFAULT relay does NOT satisfy it — the whole point is a mailbox somebody in THIS circle
// runs, and the default is a global setting the user may never revisit.
const RelayNudge = {
  KEY: "haven-relay-nudge-dismissed",
  /// Members beyond which a circle is "several people" rather than a pair — >2 OTHERS, i.e. at least
  /// four counting you. `member_count` is the circle's members excluding me, exactly like iOS
  /// `memberHexes` (both are core `Circle::members`), so the threshold ports across unchanged.
  THRESHOLD: 2,
  ids: new Set(JSON.parse(localStorage.getItem("haven-relay-nudge-dismissed") || "[]")),
  isDismissed(id) { return this.ids.has(id); },
  /// One-way and persisted, like iOS: nothing here ever un-dismisses, so we never nag twice.
  dismiss(id) { this.ids.add(id); localStorage.setItem(this.KEY, JSON.stringify([...this.ids])); },

  /// The single gate the feed needs (iOS `shouldShow(for:)`).
  async shouldShow(circleId, memberCount) {
    if (!circleId || this.isDismissed(circleId)) return false;
    if (!(memberCount > this.THRESHOLD)) return false;
    // This PC relaying — now, or armed to on every launch — already counts as the circle having one.
    // (`host_on_launch` is desktop's persisted opt-in, i.e. iOS `RelayHost.enabled`; `hosting` is
    // `serving`.)
    const st = await invoke("relay_status").catch(() => ({}));
    if (st.hosting) return false;
    const au = await invoke("autostart_status").catch(() => ({}));
    if (au.host_on_launch) return false;
    // ACTIVE + EXPLICITLY associated only — desktop's `circle_relays` is the per-circle override list
    // and excludes the inherited default (renderFeed's ⚙ dialog re-adds the default for display, we
    // must not), which is exactly the distinction this nudge exists to make. It DOES include
    // deactivated ones, so cross-check `relays()` for active — iOS `activeExplicitRelays(forCircle:)`.
    const explicit = await invoke("circle_relays", { circleId }).catch(() => []);
    if (!explicit.length) return true;
    const all = await invoke("relays").catch(() => []);
    return !explicit.some((h) => all.some((r) => r.node_hex === h && r.active));
  },
};

/// The nudge: a brand-gradient card at the top of the feed. Clicking it opens the walkthrough; the ✕
/// dismisses it for this circle for good. Returns null when the gate says no, so the call site is one line.
async function relayNudgeBanner(circleId, memberCount) {
  if (!(await RelayNudge.shouldShow(circleId, memberCount))) return null;
  const card = el("div", { class: "nudge-banner" },
    el("div", { class: "nudge-body", onclick: () => relayWalkthrough(circleId) },
      el("span", { class: "nudge-icon" }, "📡"),
      el("div", { style: "min-width:0" },
        el("div", { class: "nudge-title" }, "Give this circle a relay"),
        el("div", { class: "nudge-sub" }, "A few of you are here now — a relay holds your sealed posts so nobody has to be online at the same time."),
      ),
    ),
    el("button", { class: "nudge-x", title: "Dismiss", onclick: () => { RelayNudge.dismiss(circleId); card.remove(); } }, "✕"),
  );
  return card;
}

/// Why a relay helps, how to get one here, and the plain-language version of Haven's encryption.
/// Every claim is bounded by what this repo's code actually does — relay/README.md for what the relay
/// holds, core/p2pcore/src/crypto.rs + identity.rs for the primitives, and
/// core/p2pcore-ffi/src/lib.rs `purge_member_from_circle` for the rekey-on-removal. Desktop's hosting
/// story is a genuinely stronger one than the phones' (it survives reboot, and runs windowless), so
/// the "how" says that instead of iOS's "fine on a charger".
function relayWalkthrough(circleId) {
  const point = (icon, title, body) => el("div", { class: "nudge-point" },
    el("span", { class: "nudge-point-icon" }, icon),
    el("div", { style: "min-width:0" },
      el("div", { style: "font-weight:600" }, title),
      el("div", { class: "muted small", style: "margin-top:3px;white-space:pre-line" }, body)));
  const heading = (t) => el("div", { class: "muted small", style: "font-weight:600;margin-top:6px" }, t);

  modal(el("div", { style: "max-width:560px" },
    el("h2", {}, "Set up a relay"),
    el("div", { class: "col", style: "max-height:64vh;overflow:auto;gap:8px" },
      point("📥", "Nobody has to be online at once",
        "Posts upload sealed; friends pick them up next time they open Haven."),
      point("🖼️", "Photos and videos actually arrive",
        "Media comes from the relay, not the poster's device, so it lands even when they're offline."),
      point("🔀", "It routes around home routers",
        "When devices can't reach each other directly, the relay forwards sealed messages — no port forwarding."),
      point("🔒", "The relay can't read a thing",
        ["It only ever holds sealed blobs and a routing header — no content key ever goes near it. ",
         el("a", { href: "https://wemiller.com/apps/haven/docs/#relay-idea", target: "_blank", style: "color:var(--pink);text-decoration:underline" }, "Learn more")]),

      heading("How to set one up"),
      point("🖥️", "The easy way — this PC",
        "One click: this PC holds the circle's sealed mailbox — turn on the two Relay toggles to survive reboots."),
      point("⌨️", "Or with no window at all",
        "Prefer no window? Run haven-desktop --headless for relay-only."),
      point("📦", "Or a spare machine",
        "On a Mac, Linux box, or Raspberry Pi:\ncurl -fsSL https://wemiller.com/apps/haven/relay/install.sh | sh\n\nOn Windows, in PowerShell:\nirm https://wemiller.com/apps/haven/relay/install.ps1 | iex\n\nIt sets itself to start on every reboot; paste its node id under Relay to adopt it."),

      heading("What everyone in the circle can count on"),
      point("🔑", "Only the people you added can read it",
        "Everything you post is sealed on this PC to your circle's members. Remove someone and the circle's key rotates, so they can't read anything posted afterwards."),
      point("⚛️", "Encrypted for the long haul",
        ["Double-locked: today's proven encryption plus post-quantum. Keys never leave your devices. ",
         el("a", { href: "https://wemiller.com/apps/haven/docs/#encryption", target: "_blank", style: "color:var(--pink);text-decoration:underline" }, "Learn more")]),
    ),
    // wrap: three buttons don't fit the sheet on a narrow window, and a clipped "Not now" is a trap.
    el("div", { class: "row wrap", style: "margin-top:14px" },
      el("button", { class: "btn primary", onclick: async () => {
        try { await invoke("start_hosting"); toast("This PC is now the relay"); } catch (e) { toast("" + e); }
        $("#modal-root").replaceChildren();
        renderFeed();
      } }, "Use this PC as the relay"),
      el("button", { class: "btn ghost", onclick: () => relaySheet() }, "Add a relay I'm running →"),
      el("button", { class: "btn ghost", style: "margin-left:auto", onclick: () => $("#modal-root").replaceChildren() }, "Not now"),
    )));
}

// ---- Feed ------------------------------------------------------------------------------
// Posts the user hid from their own feed — local + per-device, never touches the circle/relay.
/**
 * What *I* call a circle. Purely local, exactly like a contact nickname: it never leaves this
 * machine, so renaming a circle for myself can't rename it for everyone else in it. The circle's
 * real name stays authoritative on the wire — this is resolved only at DISPLAY time, via
 * `circleDisplayName`, which every display site should go through so a renamed circle doesn't revert
 * wherever one was missed. An empty string clears it.
 *
 * Distinct from Rename in the manage sheet, which renames the circle for EVERYONE in it.
 * localStorage rather than Prefs on purpose: it is device-local and must never reach self-sync.
 */
const CircleNick = {
  map: JSON.parse(localStorage.getItem("haven-circle-nick") || "{}"),
  get(id) { return (this.map[id] || "").trim() || null; },
  set(id, v) {
    const t = (v || "").trim();
    if (t) this.map[id] = t; else delete this.map[id];
    localStorage.setItem("haven-circle-nick", JSON.stringify(this.map));
  },
};

/** The name to SHOW for a circle: my private nickname if I set one, else its real name. */
function circleDisplayName(id, real) {
  return CircleNick.get(id) || real || "My Circle";
}

const Hidden = {
  ids: new Set(JSON.parse(localStorage.getItem("haven-hidden") || "[]")),
  showHidden: false,
  has(id) { return this.ids.has(id); },
  hide(id) { this.ids.add(id); this._save(); },
  unhide(id) { this.ids.delete(id); this._save(); },
  toggle() { this.showHidden = !this.showHidden; },
  _save() { localStorage.setItem("haven-hidden", JSON.stringify([...this.ids])); },
};

/** The Circle feed. Column order is the macOS LazyVStack's, exactly:
 *    banner → pending requests → circle upgrade → relay nudge → STORIES TRAY → posts
 *  and the composer floats over the lot as a pill pinned to the bottom (FeedView ▸ composerBar). */
async function renderFeed() {
  const root = $("#view-circle");
  const circles = await invoke("circles");
  const active = circles.find((c) => c.id === state.activeCircle);
  if (!active) state.activeCircle = "default";
  // Through circleDisplayName: the header is a display site, so a circle I have privately renamed
  // reads the same here as it does in the switcher.
  state.activeCircleName = circleDisplayName(state.activeCircle, (active || {}).name);
  renderTitlebarTrailing();

  // macOS `banner`: a dot + one plain sentence. No sidebar footer to hide it in any more.
  const banner = el("div", { class: "feed-banner" },
    el("span", { class: "dot", id: "status-dot" }),
    el("span", { class: "txt", id: "status-text" }, connectionText(state.status)),
    el("div", { class: "spacer" }),
    // Global video mute — macOS puts this on the media itself; on a pointer-driven desktop feed a
    // single always-visible control beats a per-card overlay. Circular, like every other control.
    el("button", {
      class: "icon-btn glass", title: state.videoSoundOn ? "Mute all videos" : "Unmute all videos",
      onclick: async () => {
        state.videoSoundOn = !state.videoSoundOn;
        await invoke("set_video_sound", { on: state.videoSoundOn }).catch(() => {});
        syncFeedVideoSound();
        renderFeed();
      },
    }, icon(state.videoSoundOn ? "speaker" : "speaker.slash")),
  );

  const raw = await invoke("feed", { circleId: state.activeCircle });
  const items = raw
    // An unsent post is dropped from the LIST — a row of "This post was unsent" is clutter, not
    // content. postCard still renders the tombstone for a post reached directly (comments open).
    .filter((i) => !i.story && !i.unsent)
    .filter((i) => Hidden.showHidden || !Hidden.has(i.id));   // personal per-post hide (reversible)
  const storyItems = raw.filter((i) => i.story && !i.unsent);   // the tray's source (grouped by author)
  // Media any member flagged sensitive — must land before the cards build, since each tile decides
  // its own cover as it's created.
  await loadSensitive(state.activeCircle);
  // Reports filed by ANY member — the circle's shared moderation signal, grouped per post.
  const reportsByTarget = {};
  for (const r of await invoke("reports", { circleId: state.activeCircle }).catch(() => []))
    (reportsByTarget[r.target] ||= []).push(r);

  // Banner sources — fetched here (once) so they can fold into the change-signature below, then handed
  // straight to the banner builders so a real rebuild doesn't fetch them a second time.
  const pending = await invoke("pending").catch(() => []);
  const upgradeOffers = await invoke("pending_circle_upgrades", { circleId: state.activeCircle }).catch(() => []);
  const theirUpgrades = upgradeOffers.filter((o) => !o.mine);
  const canOfferUpgrade = theirUpgrades.length ? false
    : await invoke("can_offer_circle_upgrade", { circleId: state.activeCircle }).catch(() => false);

  // Feed render stability — the port of FeedView.swift ▸ refresh()'s guard. A refresh fired incidentally
  // during a scroll (a background sync's haven:changed, media backfill, a poster landing) usually
  // rebuilds an IDENTICAL feed; replacing the DOM anyway re-lays-out the list, nudges the scroll offset
  // (the "position jumps around before settling" on a fast fling) and restarts every video. So we hash
  // what actually drives the feed and leave the DOM untouched when nothing changed.
  const sig = JSON.stringify({
    c: state.activeCircle, name: state.activeCircleName,
    hidden: Hidden.showHidden, snd: state.videoSoundOn, status: connectionText(state.status),
    member: (active || {}).member_count || 0,
    pending: pending.length,
    upgrades: theirUpgrades.map((o) => o.new_circle_id).join(",") + "|" + (canOfferUpgrade ? 1 : 0),
    sens: [...state.sensitive].sort().join(","),
    items: items.map((i) => [i.id, i.body, (i.media || []).join("|"), i.unsent ? 1 : 0, i.edited ? 1 : 0,
      (i.reactions || []).map((r) => r.emoji + r.count + (r.mine ? "1" : "0")).join(","),
      (i.comments || []).map((c) => (c.author_name || "") + c.created_at + (c.body || "")).join("~"),
      i.music ? i.music.title + "·" + i.music.artist : "",
      (reportsByTarget[i.id] || []).length]),
    stories: storyItems.map((s) => [s.id, s.author_name, (s.media || []).join("|"), s.created_at]),
  });
  if (state.feedSig === sig && !state.focusPost && root.querySelector(".feed-list")) return;
  state.feedSig = sig;

  const list = el("div", { class: "feed-list" });
  list.append(banner);
  const pend = await pendingBanner(pending);
  if (pend) list.append(pend);
  const upgrade = await circleUpgradeBanner(state.activeCircle, upgradeOffers, canOfferUpgrade);
  if (upgrade) list.append(upgrade);
  const nudge = await relayNudgeBanner(state.activeCircle, (active || {}).member_count || 0);
  if (nudge) list.append(nudge);
  list.append(await storiesTray(storyItems));
  if (!items.length) {
    list.append(el("div", { class: "empty" },
      el("span", { class: "big" }, icon("sparkles", "empty-ic")),
      el("div", { class: "h" }, "Nothing here yet"),
      el("div", {}, "Share your first moment below. As your circle connects, their posts show up here too.")));
  }
  for (const it of items) list.append(postCard(it, state.activeCircle, reportsByTarget[it.id] || []));

  const composer = buildComposer(
    (body, music, muteVideo) => invoke("post", { circleId: state.activeCircle, body, media: withThumbMarkers(state.attachments), music, muteVideo }),
    "Share something…",
    {
      circleId: state.activeCircle,
      floating: true,
      onSchedule: (body, music, muteVideo, sendAtMs) => invoke("schedule_message", { kind: "post", circleId: state.activeCircle, body, media: withThumbMarkers(state.attachments), music, muteVideo, sendAtMs }),
    },
  );

  root.replaceChildren(el("div", { class: "col-wrap" }, list));
  $("#composer-slot").replaceChildren(composer);
  hydrateMedia(root, state.activeCircle);
  if (state.focusPost) focusPostCard(root, state.focusPost);   // arrived here from a post link
}

/** Pending connection requests — macOS `pendingBanner`: a brand-gradient card at the top of the
 *  feed that opens the Connect sheet. This is Connect's discovery path now that it isn't a tab. */
async function pendingBanner(prefetched) {
  const pending = prefetched || await invoke("pending").catch(() => []);
  if (!pending.length) return null;
  return el("div", { class: "nudge-banner", style: "cursor:pointer", onclick: () => connectSheet() },
    el("div", { class: "nudge-body" },
      el("span", { class: "nudge-icon" }, icon("person.badge.plus")),
      el("div", { style: "min-width:0" },
        el("div", { class: "nudge-title" }, pending.length === 1 ? "1 connection request" : `${pending.length} connection requests`),
        el("div", { class: "nudge-sub" }, "Click to review who wants to connect"),
      ),
    ),
    el("span", { class: "nudge-icon", style: "opacity:.85" }, icon("chevron.right")),
  );
}

// ---- Carrying an older circle onto one with a verified owner ---------------------------

/** Circles made before 1.0.7 have no owner — nothing recorded who created them, because until the
 *  group became shared it never mattered. Without an owner there's nobody a circle can check a
 *  removal against, so those circles keep the encryption they already have.
 *
 *  The way across is an offer: whoever made the circle offers a replacement whose id is tied to them,
 *  and each member decides whether to follow it. That decision is deliberately a person's, not the
 *  app's: the offer is signed, and we can prove it really came from whoever signed it and that the
 *  replacement is genuinely theirs — but nothing can prove they made the ORIGINAL circle, since it
 *  never had an owner to record. So we name who is asking and let the user choose. If two people both
 *  claim it, BOTH are rendered; the app picks neither. Returns null when there's nothing to say, so
 *  the call site is one line (mirrors relayNudgeBanner). */
async function circleUpgradeBanner(circleId, prefetchedOffers, prefetchedCanOffer) {
  const offers = prefetchedOffers || await invoke("pending_circle_upgrades", { circleId }).catch(() => []);
  // Offers from OTHER people — mine need no confirmation (I made the offer).
  const theirs = offers.filter((o) => !o.mine);
  if (theirs.length) {
    const wrap = el("div", { style: "display:flex; flex-direction:column; gap:8px" });
    for (const o of theirs) wrap.append(followUpgradeCard(circleId, o));
    return wrap;
  }
  const canOffer = prefetchedCanOffer !== undefined ? prefetchedCanOffer
    : await invoke("can_offer_circle_upgrade", { circleId }).catch(() => false);
  if (!canOffer) return null;
  return el("div", { class: "nudge-banner" },
    el("div", { class: "nudge-body", style: "cursor:default" },
      el("span", { class: "nudge-icon" }, icon("lock.shield.fill")),
      el("div", { style: "min-width:0" },
        el("div", { class: "nudge-title" }, "Upgrade this circle"),
        el("div", { class: "nudge-sub" }, "If you made this circle, give it a verified owner so removing someone cuts them off for good. Everyone here chooses whether to follow you."),
      ),
    ),
    el("button", {
      class: "pill-btn nudge-cta",
      onclick: async () => {
        const id = await invoke("upgrade_circle", { circleId }).catch(() => null);
        if (id) state.activeCircle = id;
        renderFeed();
      },
    }, "Upgrade"),
  );
}

/** Someone is asking us to follow their replacement. Names them, and says plainly what we can't
 *  vouch for — following is only ever this button, never automatic. */
function followUpgradeCard(circleId, o) {
  return el("div", { class: "nudge-banner" },
    el("div", { class: "nudge-body", style: "cursor:default" },
      el("span", { class: "nudge-icon" }, icon("person.2.fill")),
      el("div", { style: "min-width:0" },
        el("div", { class: "nudge-title" }, `${o.from_name} is upgrading “${o.name}”`),
        el("div", { class: "nudge-sub" }, "They say they made this circle. We can't check that, so only follow if that's right — whoever you follow will be able to remove people."),
      ),
    ),
    el("button", {
      class: "pill-btn nudge-cta",
      onclick: async () => {
        const ok = await invoke("accept_circle_upgrade", { circleId, newCircleId: o.new_circle_id }).catch(() => false);
        if (ok) state.activeCircle = o.new_circle_id;
        renderFeed();
      },
    }, "Follow"),
  );
}

/** STORIES — the tray at the TOP OF THE FEED, never a tab. Port of FeedView.swift ▸ storiesTray:
 *  a gradient-STROKED "Add" ring with a pink camera, then one gradient-filled circle per author with
 *  their name beneath. Each ring is an IDENTITY chip → it shows the sharer's PROFILE PICTURE, not the
 *  story's content (the content is what you see when you open it). Matches ContentView.swift /
 *  FeedView.swift, where feed rings carry the peer avatar while the "Your stories" GALLERY carries per
 *  story content thumbnails. Desktop peers broadcast no avatar, so a friend's identity chip is their
 *  initials disc — exactly what postCard shows for the same author. */
async function storiesTray(prefetched) {
  const tray = el("div", { class: "story-tray" });
  tray.append(el("button", { class: "story-ring add", title: "Add to your story", onclick: addStoryDialog },
    el("div", { class: "ring" }, el("div", {}, icon("camera.fill"))),
    el("div", { class: "nm" }, "Add")));
  const stories = (prefetched || await invoke("feed", { circleId: state.activeCircle }).catch(() => []))
    .filter((i) => i.story && !i.unsent)
    .map((s) => ({ ...s, _circle: state.activeCircle }));
  // The flat, author-grouped list the viewer pages through (macOS `groupedStoriesFlat`); each ring
  // opens straight at that person's first story, then a tap walks their run and on into the next.
  const { flat, starts } = groupStoriesFlat(stories);
  const me = state.profile && state.profile.name !== undefined ? state.profile
    : await invoke("get_profile").catch(() => ({}));
  // One ring per AUTHOR (first-seen order in the flat list).
  const seen = new Set();
  for (const it of flat) {
    const name = it.author_name || "?";
    if (seen.has(name)) continue;
    seen.add(name);
    const disc = el("div", {});
    if (it.is_me && me && me.avatar) disc.append(el("img", { src: me.avatar }));
    else if (it.is_me && me && me.emoji) disc.textContent = me.emoji;
    else disc.textContent = initials(name);   // identity chip — matches the author's postCard avatar
    tray.append(el("button", { class: "story-ring cover", onclick: () => viewStories(flat, starts.get(name) || 0) },
      el("div", { class: "ring" }, disc),
      el("div", { class: "nm" }, it.is_me ? "You" : name.split(" ")[0])));
  }
  return tray;
}

/** Group stories the way the viewer pages through them — the port of FeedStore.groupedStoriesFlat:
 *  group by author, each author's stories oldest→newest, authors ordered by whoever posted most
 *  recently. Returns the flat list plus `starts` (author → the flat index of their first story) so a
 *  tray ring can open straight at that person. */
function groupStoriesFlat(stories) {
  const groups = new Map();
  for (const s of stories) {
    const k = s.author_name || "?";
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(s);
  }
  const ordered = [...groups.entries()]
    .map(([author, items]) => ({ author, items: items.slice().sort((a, b) => Number(a.created_at) - Number(b.created_at)) }))
    .sort((a, b) => Number(b.items[b.items.length - 1].created_at) - Number(a.items[a.items.length - 1].created_at));
  const flat = [], starts = new Map();
  for (const g of ordered) { starts.set(g.author, flat.length); for (const it of g.items) flat.push(it); }
  return { flat, starts };
}

/** The composer — a floating glass PILL, not a card at the top. Port of FeedView.swift ▸
 *  composerBar: a pink `+` menu on the left, ONE glass field (fixed radius 20, NOT a capsule: a
 *  capsule's radius grows with height and clips into the text once the field wraps), and a round
 *  brand-gradient send button. There is deliberately NO band behind the row — each control carries
 *  its own surface and the feed scrolls under it.
 *
 *  `opts.floating` pins it to the bottom of the feed; the story composer reuses the same row
 *  inline inside its sheet. */
function buildComposer(onPost, placeholder = "Share something…", opts = {}) {
  const circleId = opts.circleId || state.activeCircle;
  let music = null;
  let muteVideo = false;
  const ta = el("textarea", { class: "composer-field glass", placeholder, rows: 1 });
  // Grow with the text up to the CSS max-height, then scroll — the macOS field is `axis: .vertical`.
  const autoGrow = () => { ta.style.height = "auto"; ta.style.height = Math.min(ta.scrollHeight, 132) + "px"; };
  ta.addEventListener("input", autoGrow);
  const previews = el("div", { class: "attach-preview" });
  const musicRow = el("div", {});
  const muteBtn = el("button", { class: "btn small ghost", style: "display:none", onclick: () => { muteVideo = !muteVideo; muteBtn.textContent = muteVideo ? "🔇 Video muted" : "🔊 Mute video"; muteBtn.classList.toggle("primary", muteVideo); } }, "🔊 Mute video");
  const drawPreviews = () => {
    previews.replaceChildren(...state.attachments.map((a, i) =>
      el("div", { class: "chip" },
        a.isAudio ? el("div", { style: "width:56px;height:56px;border-radius:10px;background:var(--panel2);display:flex;align-items:center;justify-content:center;font-size:22px" }, "🎙️")
          : a.isVideo ? el("video", { src: a.url, muted: "" }) : el("img", { src: a.url }),
        el("span", { class: "x", onclick: () => { state.attachments.splice(i, 1); drawPreviews(); } }, "×"),
      )));
    const hasVideo = state.attachments.some((a) => a.isVideo);
    muteBtn.style.display = hasVideo ? "" : "none";
    if (!hasVideo) { muteVideo = false; muteBtn.textContent = "🔊 Mute video"; muteBtn.classList.remove("primary"); }
  };
  const addAttachment = async (ref, isVideo, isAudio, thumbRef = null) => {
    const url = isAudio ? null : await invoke("media_data_url", { circleId, reference: ref }).catch(() => null);
    state.attachments.push({ ref, url, isVideo, isAudio, thumbRef });
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
    // `music` is private to the composer, and the story preview has to follow it (an attached song is
    // the story's soundtrack, so the clip mutes; removing it hands the clip its own audio back).
    if (opts.onMusicChange) opts.onMusicChange(music);
  };
  const fileInput = el("input", { type: "file", accept: "image/*,video/*", style: "display:none", onchange: (e) => handleFiles(e.target.files, drawPreviews) });

  // Delivery light for this circle (macOS `SyncStatusBadge`): green = it reached your relay or a
  // member, yellow = still syncing, red = only on this device. Green says nothing at all.
  const syncDot = el("span", { class: "dot" });
  const syncBadge = el("span", { class: "sync-badge glass hide" }, syncDot, el("span", {}, ""));
  const refreshSync = async () => {
    const s = await invoke("sync_status", { circleId }).catch(() => "synced");
    const label = syncBadge.lastChild;
    if (s === "local") { syncDot.style.background = "#EF4444"; label.textContent = "Device only"; syncBadge.classList.remove("hide"); }
    else if (s === "syncing") { syncDot.style.background = "#F59E0B"; label.textContent = "Syncing"; syncBadge.classList.remove("hide"); }
    else syncBadge.classList.add("hide");
  };
  if (state.syncTimer) clearInterval(state.syncTimer);   // only one composer at a time — no leak across re-renders
  refreshSync();
  state.syncTimer = setInterval(refreshSync, 2500);

  const send = async () => {
    const body = ta.value.trim();
    if (!body && !state.attachments.length && !music) return;
    await onPost(body, music, muteVideo);
    ta.value = ""; autoGrow();
    state.attachments = [];
    music = null;
    muteVideo = false;
    drawPreviews();
    drawMusic();
    toast("Posted");
  };
  // Enter sends, Shift+Enter is a newline — the desktop convention, and the field is a pill you
  // can't see a "Post" button next to at rest.
  ta.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); }
  });

  // The `+` menu — every attachment path the macOS composer's Menu holds, in its order.
  const plus = el("button", { class: "composer-plus", title: "Attach", "aria-label": "Attach" }, icon("plus"));
  plus.addEventListener("click", () => popMenu(plus, [
    { label: "Photo or Video", icon: "photo", on: () => fileInput.click() },
    { label: "Camera", icon: "camera.fill", on: async () => { const r = await cameraDialog(circleId); if (r) addAttachment(r.ref, r.isVideo, false); } },
    { label: "Voice", icon: "mic", on: async () => { const r = await recordVoice(circleId); if (r) addAttachment(r, false, true); } },
    { label: "Add a song", icon: "music.note", on: () => musicDialog((m) => { music = m; drawMusic(); }) },
    opts.onSchedule ? { sep: true } : null,
    opts.onSchedule ? { label: "Send later…", icon: "clock", on: () => {
      const body = ta.value.trim();
      if (!body && !state.attachments.length && !music) { toast("Write something first"); return; }
      scheduleDialog((ms) => {
        opts.onSchedule(body, music, muteVideo, ms);
        ta.value = ""; autoGrow(); state.attachments = []; music = null; muteVideo = false; drawPreviews(); drawMusic();
        toast("Scheduled");
      });
    } } : null,
  ]));

  const bar = el("div", { class: "composer" + (opts.floating ? " floating" : "") },
    el("div", { class: "composer-meta" }, syncBadge),
    previews,
    musicRow,
    el("div", { class: "row wrap", style: "gap:6px" }, muteBtn),
    el("div", { class: "composer-row" },
      plus,
      ta,
      el("button", { class: "composer-send", title: "Post", "aria-label": "Post", onclick: send }, icon("paperplane.fill")),
    ),
    fileInput,
  );
  return bar;
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

// ---- Sensitive content ------------------------------------------------------------------
// Apple runs the on-device analyzer (SensitiveContentAnalysis) and federates a SensitiveFlag to the
// circle so members whose platform has NO classifier can still blur — that's this. We author no
// flags (there's no SCA equivalent on Windows/Linux) but we HONOR every one we receive, otherwise a
// poster marks something sensitive on their iPhone and it lands full-frame on their friend's laptop.
// Behaviour + copy track apple/HavenApp/SensitiveContent.swift: frosted cover, "Sensitive Content" /
// "Tap to view", click reveals with a short fade and stays revealed for that render.
//
// The federated set is authoritative for EVERY ref in it, including your own posts — iOS's `scan`
// flag gates only whether the local analyzer runs, never whether a received flag blurs.
async function loadSensitive(circleId) {
  const refs = await invoke("sensitive_refs", { circleId }).catch(() => []);
  state.sensitive = new Set(refs);
}

/** The frosted cover for one flagged item. Clicking it reveals the media underneath. */
function sensitiveCover(onReveal) {
  const cover = el("div", { class: "sensitive-cover", title: "Sensitive Content" },
    el("div", { class: "sensitive-label" },
      icon("eye.slash"),
      el("div", { class: "t" }, "Sensitive Content"),
      el("div", { class: "s" }, "Tap to view")));
  cover.addEventListener("click", (e) => {
    // Don't let the reveal double as a play/▶ or the feed's double-tap-to-❤️.
    e.stopPropagation();
    e.preventDefault();
    cover.classList.add("revealed");
    onReveal();
    setTimeout(() => cover.remove(), 200);   // after the fade
  });
  return cover;
}

/** Blur `node` and cover `container` (which must be position:relative) if `ref` is flagged. */
function guardSensitiveIn(container, node, ref) {
  if (!state.sensitive.has(ref)) return;
  node.classList.add("sensitive-blur");
  container.append(sensitiveCover(() => node.classList.remove("sensitive-blur")));
}

/** Wrap a bare media node so it can carry its own cover — for the masonry grid and chat bubbles,
 *  where tiles aren't already inside a positioned page of their own. Returns what to append. */
function guardSensitive(node, ref) {
  if (!state.sensitive.has(ref)) return node;
  const wrap = el("div", { class: "sensitive-wrap" }, node);
  guardSensitiveIn(wrap, node, ref);
  return wrap;
}

// ---- Remembered media shapes ------------------------------------------------------------
// A ref's pixel size, learned the first time its bytes decode and kept on disk afterwards. This is
// the desktop half of the iOS "seed the card from a known width" fix (FeedView.swift's
// lastKnownMediaWidth / MediaStore.pixelSize): a page whose aspect isn't known until `load` fires
// lays out at a PLACEHOLDER shape first and then snaps to the real one, and that resize — once per
// card, as each card scrolls in — is what makes the feed jump up and down under the cursor.
// Knowing the shape before the bytes decode means the card is the right height on its FIRST layout.
//
// Tiny by construction ("w,h" per ref) and capped, so it can live in localStorage without growing
// without bound; the cap evicts oldest-first, and a miss simply costs one settle like before.
const MEDIA_SIZE_KEY = "haven.mediaSizes";
const MEDIA_SIZE_CAP = 800;
const mediaSizes = (() => {
  try { return new Map(Object.entries(JSON.parse(localStorage.getItem(MEDIA_SIZE_KEY) || "{}"))); }
  catch (_) { return new Map(); }
})();
let mediaSizeSaveTimer = null;
function persistMediaSizes() {
  // Coalesced: a feed render can learn a dozen shapes in a frame, and localStorage writes are sync.
  if (mediaSizeSaveTimer) return;
  mediaSizeSaveTimer = setTimeout(() => {
    mediaSizeSaveTimer = null;
    try {
      while (mediaSizes.size > MEDIA_SIZE_CAP) mediaSizes.delete(mediaSizes.keys().next().value);
      localStorage.setItem(MEDIA_SIZE_KEY, JSON.stringify(Object.fromEntries(mediaSizes)));
    } catch (_) {}   // quota/private-mode: the in-memory map still works for this session
  }, 1200);
}
/** The remembered aspect (w/h) for `ref`, or 0 when we've never seen it decode. */
function knownAspect(ref) {
  const v = mediaSizes.get(ref);
  if (!v) return 0;
  const [w, h] = String(v).split(",").map(Number);
  return w > 0 && h > 0 ? w / h : 0;
}
function rememberMediaSize(ref, w, h) {
  if (!(w > 0) || !(h > 0)) return;
  const next = `${Math.round(w)},${Math.round(h)}`;
  if (mediaSizes.get(ref) === next) return;
  mediaSizes.delete(ref);        // re-insert so the cap evicts least-recently-learned first
  mediaSizes.set(ref, next);
  persistMediaSizes();
}
/** Reserve a bare (non-paged) tile's box before its bytes decode, so it doesn't lay out at zero
 *  height and then shove everything below it down the instant the image lands.
 *
 *  Two mechanisms, because the two call sites size differently — passing the wrong one does nothing
 *  useful and can resize the box, so the caller says which:
 *   • "ratio" — the masonry grid, where CSS pins `width: 100%` and leaves height auto. `aspect-ratio`
 *     is all that's needed, and even the fallback ratio beats a zero-height box.
 *   • "intrinsic" — a chat bubble image, sized by its own pixels under a `max-width`. `aspect-ratio`
 *     does nothing there (an auto-width box with no intrinsic size is still zero wide), so the
 *     `width`/`height` ATTRIBUTES supply the missing intrinsic size and `max-width` scales it down
 *     proportionally — the standard no-layout-shift recipe. Images only: a <video> already has a
 *     default 300×150 intrinsic size, and overriding it here would resize bubbles rather than
 *     stabilise them. Unknown size: nothing reserved, exactly as before.
 *  Either way the real dimensions take over on load, and get remembered for next time. */
function reserveAspect(node, ref, mode = "ratio", fallback = 4 / 3) {
  if (node.tagName !== "IMG" && node.tagName !== "VIDEO") return node;
  const isVid = node.tagName === "VIDEO";
  const intrinsic = mode === "intrinsic";
  if (intrinsic && isVid) return node;
  const known = knownAspect(ref);
  const apply = (w, h) => {
    if (intrinsic) {
      node.setAttribute("width", String(Math.round(w)));
      node.setAttribute("height", String(Math.round(h)));
      node.style.height = "auto";
    } else {
      node.style.aspectRatio = String(w / h);
    }
  };
  const size = mediaSizes.get(ref);
  if (size) {
    const [w, h] = String(size).split(",").map(Number);
    if (w > 0 && h > 0) apply(w, h);
  } else if (!intrinsic) {
    node.style.aspectRatio = String(known || fallback);
  }
  node.addEventListener(isVid ? "loadedmetadata" : "load", () => {
    const w = isVid ? node.videoWidth : node.naturalWidth;
    const h = isVid ? node.videoHeight : node.naturalHeight;
    if (!w || !h) return;
    rememberMediaSize(ref, w, h);
    apply(w, h);
  }, { once: true });
  return node;
}

/** Modern img_/vid_/aud_/file_ prefixes (Apple/Android) plus legacy v:/a:/i:. */
function isVideoRef(ref) { return ref.startsWith("vid_") || ref.startsWith("v:"); }
function isAudioRef(ref) { return ref.startsWith("aud_") || ref.startsWith("a:"); }
function isFileRef(ref) { return ref.startsWith("file_"); }
/** Synthetic markers (poster:/orig:/geo:) and original companions — hide from carousels. */
function isSyntheticMedia(ref) {
  const i = ref.indexOf(":");
  return i > 1; // multi-char scheme: poster:, orig:, geo:, music:, …
}
function displayMediaRefs(media) {
  ThumbIndex.learn(media);
  const originals = new Set();
  const posterImages = new Set();
  const thumbImages = new Set();
  for (const r of media || []) {
    if (r.startsWith("orig:")) {
      const rest = r.slice(5);
      const c = rest.lastIndexOf(":");
      if (c > 0) originals.add(rest.slice(c + 1));
    }
    if (r.startsWith("poster:")) {
      const rest = r.slice(7);
      const c = rest.lastIndexOf(":");
      if (c > 0) posterImages.add(rest.slice(c + 1));
    }
    if (r.startsWith("thumb:")) {
      const rest = r.slice(6);
      const c = rest.lastIndexOf(":");
      if (c > 0) thumbImages.add(rest.slice(c + 1));
    }
  }
  // Poster stills ride with the video page (data-saver still + play) — not as their own slide.
  // Thumbs never render as slides at all: they back the loading placeholder, blurred.
  return (media || []).filter((r) => !isSyntheticMedia(r) && !originals.has(r) && !posterImages.has(r) && !thumbImages.has(r));
}

// ---- `thumb:` companions (MediaVariants parity) ------------------------------------------
// contentRef -> tiny thumbRef, learned from every media list that passes through displayMediaRefs,
// so a still-loading tile can paint its own blurred preview instead of a grey box.
const ThumbIndex = {
  map: new Map(),
  learn(media) {
    for (const r of media || []) {
      if (!r.startsWith("thumb:")) continue;
      const rest = r.slice(6), c = rest.lastIndexOf(":");
      if (c > 0) this.map.set(rest.slice(0, c), rest.slice(c + 1));
    }
  },
  thumbFor(ref) { return this.map.get(ref) || null; },
};

function mediaNode(ref, imgStyle) {
  // Videos start muted unless the global "play video sound" toggle is on (iOS parity); native controls
  // still let the user override per-video. data-video lets the toggle re-apply across all of them.
  // While a call is ringing/connecting/live — or while any capture UI is up — they render muted
  // regardless (call/capture audio priority).
  if (isVideoRef(ref)) return el("video", Object.assign({ "data-ref": ref, "data-video": "1", controls: "" }, state.videoSoundOn && !callAudioActive() && !captureUIOpen() && !state.superDataSaver ? {} : { muted: "" }));
  if (isAudioRef(ref)) return el("audio", { "data-ref": ref, controls: "", style: "width:100%;margin-top:6px;display:block" });
  if (isFileRef(ref)) return el("div", { class: "tag", "data-ref": ref, style: "padding:12px;margin-top:6px" }, "📎 Attachment");
  // decoding="async" keeps the decode off the thread that's scrolling: a data-URL image decodes
  // synchronously by default, and a multi-photo post paid every one of those decodes in one frame.
  return el("img", Object.assign({ "data-ref": ref, loading: "lazy", decoding: "async" }, imgStyle ? { style: imgStyle } : {}));
}

// ---- Media pages: the carousel + single-item pager --------------------------------------
// Ports the iOS feed's page model (apple/HavenApp/FeedView.swift): each item is fitted WHOLE inside
// a shared page shape, and a blurred, cropped copy of itself fills whatever the fit leaves over — so
// a letterboxed portrait reads as an extension of its own content instead of a flat black gap.
// Aspects come from the remembered pixel sizes (see mediaSizes) when we have them, so a page is the
// right shape on its FIRST layout pass; a ref we've never decoded still reports on load and settles
// once, exactly as before.

// One 9:16 clip must not squeeze a whole card into a narrow column, so a MIXED set's shared shape is
// clamped; the items that don't fit it letterbox against their own backdrop instead.
const PAGE_ASPECT_MIN = 0.8, PAGE_ASPECT_MAX = 1.91;

// The carousel's page shape. A uniform set keeps its exact aspect (nothing letterboxes); a MIXED set
// takes the TALLEST item's, so no page is ever cropped.
function carouselAspect(aspects) {
  const known = aspects.filter((a) => a > 0);
  if (!known.length) return 4 / 3;
  const tallest = Math.min(...known);
  // Uniform only once EVERY item has reported — a half-decoded set isn't known to be uniform yet.
  const uniform = known.length === aspects.length && known.every((a) => Math.abs(a - known[0]) < 0.06);
  return uniform ? tallest : Math.min(PAGE_ASPECT_MAX, Math.max(PAGE_ASPECT_MIN, tallest));
}

// Photos and videos share ONE backdrop path (iOS parity): the blurred still is always derived from
// the element the page is ALREADY drawing, never a second request that could fail or lag on its own.
// Downscaled to 64px — a 24px blur can't resolve more than that anyway, and blurring a tiny source
// makes the raster nearly free, where blurring a full-res bitmap is a real scroll-jank cost.
// (Never a second <video> either: that's a second decode of the same stream per post, and behind a
// blur this heavy a still and a moving copy are indistinguishable.)
// Returns null only when there's genuinely nothing to draw yet; images fall back to their own URL so
// a decorative layer degrades rather than vanishing.
function stillFrom(node) {
  const isVid = node.tagName === "VIDEO";
  const w = isVid ? node.videoWidth : node.naturalWidth;
  const h = isVid ? node.videoHeight : node.naturalHeight;
  if (!w || !h) return isVid ? null : (node.src || null);
  const scale = Math.min(1, 64 / Math.max(w, h));
  const c = el("canvas");
  c.width = Math.max(1, Math.round(w * scale));
  c.height = Math.max(1, Math.round(h * scale));
  try {
    c.getContext("2d").drawImage(node, 0, 0, c.width, c.height);
    return c.toDataURL("image/jpeg", 0.7);
  } catch (_) {
    return isVid ? null : (node.src || null);   // no decoded frame yet — retry on a later trigger
  }
}

// Posters, remembered per ref for the session. The feed re-renders WHOLE on every `haven:changed`,
// and without this each render re-ran the canvas draw for every photo and the whole seek-and-grab
// dance for every video — the same work, over and over, on the thread that's scrolling. A cached
// poster also means a video's backdrop is there on the first frame instead of after a seek.
const posterCache = new Map();
const POSTER_CACHE_CAP = 300;
function posterFor(ref, node) {
  const hit = posterCache.get(ref);
  if (hit) return hit;
  const still = stillFrom(node);
  // Only keep a REAL downscaled still. stillFrom falls back to an <img>'s own src when it can't draw
  // yet, and that's the full-size data URL — caching it would pin whole originals for the session.
  // A 64px JPEG is a couple of KB, so the length check separates the two cleanly.
  if (still && still.length <= 24000) {
    posterCache.set(ref, still);
    if (posterCache.size > POSTER_CACHE_CAP) posterCache.delete(posterCache.keys().next().value);
  }
  return still;
}

// Get a drawable frame out of a PAUSED video. Neither obvious event works: `loadeddata` promises
// decoded data, not a painted one (drawing there captures a BLACK rectangle — precisely the flat gap
// the backdrop exists to remove), and requestVideoFrameCallback needs the compositor, so it never
// fires while paused, which is every feed video before it's played. A seek forces the decoder to
// produce that exact frame and `seeked` fires once it's drawable, regardless of playback or
// visibility; we restore the head so the clip still starts from the beginning.
// `fn` returns true once it has its still. The seek is the primary path but isn't guaranteed (decode
// errors, odd codecs), so rVFC and `timeupdate` stay armed as later chances — a backdrop that shows
// up when the clip is finally played beats one that never shows up at all.
function onFirstFrame(v, fn) {
  const grab = () => { if (fn()) stop(); };
  const stop = () => {
    v.removeEventListener("seeked", grab);
    v.removeEventListener("timeupdate", grab);
  };
  v.addEventListener("seeked", grab);
  v.addEventListener("timeupdate", grab);
  if (v.requestVideoFrameCallback) v.requestVideoFrameCallback(grab);
  const seek = () => {
    // Restore the head on OUR seek, on a listener of its own: whichever trigger ends up producing the
    // still calls stop(), and if that happens first (a visible clip presents a frame before the seek
    // lands) a restore hung off the capture path would be torn down with it — parking the clip at 0.1.
    v.addEventListener("seeked", () => { v.currentTime = 0; }, { once: true });
    v.currentTime = Math.min(0.1, (v.duration || 1) / 4);
  };
  if (v.readyState >= 2) seek();
  else v.addEventListener("loadeddata", seek, { once: true });
}

// Attach a page's backdrop, but only on a REAL mismatch between the media and the shape the page
// actually rendered at (the 520px height cap can widen a page past the set's nominal aspect, and that
// widening is exactly what needs covering). Torn down when there's no gap — an always-on blurred
// layer is a compositing cost per post for nothing.
function applyBackdrop(p) {
  const pw = p.page.clientWidth, ph = p.page.clientHeight;
  const gap = p.aspect > 0 && pw > 0 && ph > 0 && Math.abs(p.aspect - pw / ph) > 0.02;
  if (!gap) {
    if (p.backdrop) { p.backdrop.remove(); p.backdrop = null; }
    return;
  }
  // The still is produced once (p.poster). A video's may not exist yet — a later trigger retries it.
  if (!p.poster || p.backdrop) return;
  p.backdrop = el("img", { class: "media-backdrop", src: p.poster, alt: "", "aria-hidden": "true" });
  p.page.prepend(p.backdrop);
}

// Build the fitted pages for `refs`. `onAspects` fires as items decode, so the caller can settle the
// shared shape. Backdrops re-evaluate on decode and whenever the card is resized.
function buildMediaPages(refs, container, onAspects) {
  const pages = refs.map((ref) => {
    const node = mediaNode(ref);
    const page = el("div", { class: "media-page" }, node);
    // .media-page is already position:relative + overflow:hidden — the cover goes straight in, over
    // both the fitted media and its backdrop (which is a blurred copy of the same flagged frame).
    guardSensitiveIn(page, node, ref);
    // Seeded from what we already know, so the page is the right shape BEFORE the bytes decode —
    // no post-load resize, which is the feed's scroll jump. A ref we've never seen starts at 0 and
    // settles on load exactly as it used to.
    return { ref, node, page, aspect: knownAspect(ref), poster: posterCache.get(ref) || null, backdrop: null };
  });
  const sync = () => pages.forEach(applyBackdrop);
  for (const p of pages) {
    const isVid = p.node.tagName === "VIDEO";
    // Shape comes from the metadata; a photo can give its still right away, a video only later.
    p.node.addEventListener(isVid ? "loadedmetadata" : "load", () => {
      const w = isVid ? p.node.videoWidth : p.node.naturalWidth;
      const h = isVid ? p.node.videoHeight : p.node.naturalHeight;
      if (w && h) { rememberMediaSize(p.ref, w, h); p.aspect = w / h; onAspects(pages.map((x) => x.aspect)); }
      if (!isVid && !p.poster) p.poster = posterFor(p.ref, p.node);
      sync();
    }, { once: true });
    // A remembered poster is already good — don't pay the seek dance again just to reproduce it.
    if (isVid && !p.poster) onFirstFrame(p.node, () => {
      if (!p.poster) p.poster = posterFor(p.ref, p.node);
      if (p.poster) sync();
      return !!p.poster;
    });
  }
  if (window.ResizeObserver) new ResizeObserver(sync).observe(container);
  return pages;
}

// A single item takes its OWN exact aspect (iOS parity — no clamp). Where the 520px cap bites, the
// page stays card-wide and the backdrop fills the sides: that's the portrait-photo case.
function mediaSingle(ref, container) {
  const [p] = buildMediaPages([ref], container, ([a]) => { p.page.style.aspectRatio = String(a || 4 / 3); });
  // The remembered shape when we have one, so this page never lays out at 4:3 and then snaps.
  p.page.style.aspectRatio = String(p.aspect || 4 / 3);
  container.append(p.page);
}

// A full-width scroll-snap pager for 2…10 items of ANY aspect. Mixed aspects no longer force the
// masonry — each page fits inside the shared shape and its backdrop masks the difference, which
// beats a 2-column grid for a handful of photos.
function mediaCarousel(refs, container) {
  const track = el("div", { class: "track" });
  const dots = el("div", { class: "carousel-dots" }, ...refs.map(() => el("i")));
  const pages = buildMediaPages(refs, container, (aspects) => {
    const a = String(carouselAspect(aspects));
    for (const p of pages) p.page.style.aspectRatio = a;
  });
  // Seed the shared shape from whatever we already remember about this set (carouselAspect ignores
  // the zeros), so a fully-remembered carousel opens at its final height instead of settling into it.
  const seeded = String(carouselAspect(pages.map((p) => p.aspect)));
  for (const p of pages) { p.page.style.aspectRatio = seeded; track.append(p.page); }
  dots.firstChild.classList.add("on");
  track.addEventListener("scroll", () => {
    const i = Math.round(track.scrollLeft / Math.max(1, track.clientWidth));
    [...dots.children].forEach((d, j) => d.classList.toggle("on", j === i));
  }, { passive: true });
  container.append(track, dots);
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

// ---- media encode targets --------------------------------------------------------------
//
// ONE source of truth for every number the media pipeline encodes to, mirroring the names the
// iOS/macOS encoder uses so the three platforms can be diffed by eye. Every call site below reads
// from here — no inline magic numbers.
//
// CODEC DIVERGENCE (deliberate, documented, NOT a bug to "fix" halfway):
//   Apple's target is H.264 in MP4 (faststart, rotation baked into pixels) with AAC audio.
//   Desktop has no encoder of its own: all processing happens in the WebView, and the only encoder
//   a WebView exposes is `MediaRecorder`, which emits VP8/VP9 (video) + Opus (audio) in WebM. There
//   is ZERO Rust-side transcode — `desktop/src-tauri` carries no ffmpeg/image/codec crate (only
//   sha2/hkdf/base64/reqwest), by design, so the desktop bundle stays small and license-clean.
//   Therefore desktop matches the DIMENSIONS, BITRATES, QUALITY and LIMITS exactly, and diverges on
//   CONTAINER + CODEC. Closing that gap means adding a real encoder to the Rust side (ffmpeg-next
//   or a pure-Rust H.264 encoder) and moving transcode out of the WebView entirely — a project, not
//   a patch. Until then the numbers below are the parity surface, and they are honest.
const MEDIA_TARGETS = {
  // Video: long edge 1920 (1080p), explicit bitrates. Container/codec diverge — see above.
  VIDEO_LONG_EDGE: 1920,
  VIDEO_BITRATE_BPS: 4_500_000,
  VIDEO_AUDIO_BITRATE_BPS: 128_000,
  // Stills: longest edge 1600, JPEG quality 0.62.
  STILL_LONG_EDGE: 1600,
  STILL_JPEG_QUALITY: 0.62,
  // Standalone audio (voice notes): 96 kbps, channels preserved up to stereo.
  AUDIO_BITRATE_BPS: 96_000,
  AUDIO_MAX_CHANNELS: 2,
  // Hard length cap. Refused at IMPORT — a refusal must never mint a media ref with no bytes
  // behind it, so every check below runs BEFORE `add_media` is invoked.
  MAX_DURATION_SEC: 900,               // 15 minutes
  // Source-size caps. Desktop has no equivalent on iOS (the OS picker bounds it there), but the
  // WebView re-encode holds the decoded frames plus the recorded chunks in memory, and the drop
  // path additionally base64s the source across the IPC boundary — an unbounded drop is an OOM.
  MAX_SOURCE_BYTES_VIDEO: 512 * 1024 * 1024,
  MAX_SOURCE_BYTES_STILL: 64 * 1024 * 1024,
};

/** Human-readable size for the refusal toasts. */
const fmtMB = (b) => (b >= 1024 * 1024 * 1024 ? (b / 1024 / 1024 / 1024).toFixed(1) + " GB" : Math.round(b / 1024 / 1024) + " MB");

/** Gate a source file BEFORE anything is sealed. Returns true to proceed; toasts and returns false
 *  to refuse. Size only — duration needs the decoder, so it's checked inside the video re-encode. */
function mediaSourceAllowed(sizeBytes, isVideo, label) {
  const cap = isVideo ? MEDIA_TARGETS.MAX_SOURCE_BYTES_VIDEO : MEDIA_TARGETS.MAX_SOURCE_BYTES_STILL;
  if (sizeBytes > cap) {
    toast(`${label || "That file"} is ${fmtMB(sizeBytes)} — Haven caps ${isVideo ? "videos" : "photos"} at ${fmtMB(cap)}, so it wasn't attached.`);
    return false;
  }
  return true;
}

// Record a voice note → returns an `a:` media ref (or null if cancelled).
function recordVoice(circleId) {
  return new Promise((resolve) => {
    let recorder, chunks = [], stream, timer, secs = 0, done = false;
    // A voice note is a capture too — a post clip playing into the mic is the same problem.
    const releaseCapture = beginCapture(() => finish(null));
    const timeEl = el("div", { style: "font-size:30px;text-align:center;margin:6px 0" }, "0:00");
    const status = el("div", { class: "muted small", style: "text-align:center" }, "Tap record to start");
    const recBtn = el("button", { class: "btn primary" }, "● Record");
    const stopBtn = el("button", { class: "btn danger", style: "display:none" }, "■ Stop & attach");
    const finish = (ref) => { if (done) return; done = true; clearInterval(timer); if (stream) stream.getTracks().forEach((t) => t.stop()); releaseCapture(); $("#modal-root").replaceChildren(); resolve(ref); };
    recBtn.onclick = async () => {
      // Channel count is PRESERVED, capped at stereo (Apple's rule) — asking for `channelCount: 2`
      // as a max lets a mono mic stay mono rather than being upmixed to a wasteful stereo stream.
      try { stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: { ideal: 1, max: MEDIA_TARGETS.AUDIO_MAX_CHANNELS } } }); }
      catch (e) { toast("Mic unavailable: " + e); return; }
      recorder = new MediaRecorder(stream, { audioBitsPerSecond: MEDIA_TARGETS.AUDIO_BITRATE_BPS });
      recorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
      recorder.onstop = async () => {
        const blob = new Blob(chunks, { type: recorder.mimeType || "audio/webm" });
        try { const ref = await invoke("add_audio", { circleId, dataBase64: await blobToBase64(blob) }); finish(ref); }
        catch (e) { toast("Couldn't save: " + e); finish(null); }
      };
      recorder.start();
      recBtn.style.display = "none"; stopBtn.style.display = ""; status.textContent = "Recording…";
      timer = setInterval(() => {
        secs++; timeEl.textContent = `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, "0")}`;
        // Length cap: stop AT the limit rather than refusing after the fact — the user keeps what
        // they recorded, and nothing over the cap is ever sealed.
        if (secs >= MEDIA_TARGETS.MAX_DURATION_SEC && recorder && recorder.state !== "inactive") {
          toast(`Voice notes are capped at ${MEDIA_TARGETS.MAX_DURATION_SEC / 60} minutes.`);
          recorder.stop();
        }
      }, 1000);
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
    let stream, recorder, chunks = [], recording = false, done = false, filter = CAMERA_FILTERS[0], rafId, recStream, recTimer;
    // The camera owns the audio while it's up: feed clips stop now and stay muted until it closes.
    // Dismissing with Escape / the backdrop routes back through finish(), so the tracks stop too.
    const releaseCapture = beginCapture(() => finish(null));
    const video = el("video", { autoplay: "", muted: "", playsinline: "", style: "width:100%;border-radius:14px;background:#000;max-height:48vh" });
    const strip = el("div", { class: "row wrap", style: "gap:6px;margin-top:8px" });
    const setFilter = (f) => { filter = f; video.style.filter = f.css; [...strip.children].forEach((b) => b.classList.toggle("primary", b.textContent === f.name)); };
    CAMERA_FILTERS.forEach((f) => strip.append(el("button", { class: "btn small", onclick: () => setFilter(f) }, f.name)));
    const finish = (out) => { if (done) return; done = true; if (rafId) cancelAnimationFrame(rafId); if (recTimer) clearTimeout(recTimer); if (recStream) recStream.getTracks().forEach((t) => t.stop()); if (stream) stream.getTracks().forEach((t) => t.stop()); releaseCapture(); $("#modal-root").replaceChildren(); resolve(out); };
    const shoot = el("button", { class: "btn primary", onclick: async () => {
      // Capture at the STILL target, not at the sensor's full resolution: the canvas is sized to the
      // downscaled dimensions and the filtered frame is drawn straight into it, so the one JPEG we
      // encode is already 1600px on its long edge (no full-res intermediate to throw away).
      const sw = video.videoWidth || 1280, sh = video.videoHeight || 720;
      const s = Math.min(1, MEDIA_TARGETS.STILL_LONG_EDGE / Math.max(sw, sh));
      const c = document.createElement("canvas");
      c.width = Math.max(1, Math.round(sw * s)); c.height = Math.max(1, Math.round(sh * s));
      const ctx = c.getContext("2d"); ctx.filter = filter.css || "none"; ctx.drawImage(video, 0, 0, c.width, c.height);
      const b64 = c.toDataURL("image/jpeg", MEDIA_TARGETS.STILL_JPEG_QUALITY).split(",")[1];
      try { const ref = await invoke("add_media", { circleId, dataBase64: b64, isVideo: false }); finish({ ref, isVideo: false }); }
      catch (e) { toast("Capture failed: " + e); }
    } }, "📸 Capture");
    const recBtn = el("button", { class: "btn", onclick: () => {
      if (!recording) {
        // Record a *filtered* canvas (the selected filter is drawn into every frame) plus the
        // mic audio, so the chosen filter is baked into the saved video — not just the preview.
        // The recording canvas is sized to the VIDEO target, so the downscale to 1080p happens in the
        // same pass that bakes the filter in — the recorder never sees a full-sensor frame.
        const sw = video.videoWidth || 1280, sh = video.videoHeight || 720;
        const s = Math.min(1, MEDIA_TARGETS.VIDEO_LONG_EDGE / Math.max(sw, sh));
        const c = document.createElement("canvas");
        c.width = Math.max(2, Math.round(sw * s) & ~1); c.height = Math.max(2, Math.round(sh * s) & ~1);
        const ctx = c.getContext("2d");
        const draw = () => { ctx.filter = filter.css || "none"; ctx.drawImage(video, 0, 0, c.width, c.height); rafId = requestAnimationFrame(draw); };
        draw();
        recStream = c.captureStream(30);
        stream.getAudioTracks().forEach((t) => recStream.addTrack(t)); // mix in the mic
        chunks = []; recorder = new MediaRecorder(recStream, {
          videoBitsPerSecond: MEDIA_TARGETS.VIDEO_BITRATE_BPS,
          audioBitsPerSecond: MEDIA_TARGETS.VIDEO_AUDIO_BITRATE_BPS,
        });
        recorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
        // Length cap: stop AT the limit. Nothing longer is ever encoded, so no ref can be minted
        // for a clip that would then have to be rejected.
        recTimer = setTimeout(() => {
          if (recorder && recorder.state !== "inactive") {
            toast(`Clips are capped at ${MEDIA_TARGETS.MAX_DURATION_SEC / 60} minutes.`);
            recorder.stop();
          }
        }, MEDIA_TARGETS.MAX_DURATION_SEC * 1000);
        recorder.onstop = async () => {
          if (recTimer) { clearTimeout(recTimer); recTimer = null; }
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

/**
 * THE one place a user-supplied file becomes bytes Haven will post. Every import path (file picker,
 * drag-and-drop) goes through here, so the size cap, the length cap and the metadata strip are
 * impossible to route around.
 *
 * Returns base64 of the sanitized bytes, or null if the file was REFUSED — in which case the caller
 * must not mint a ref. Refusals toast for themselves.
 *
 * Images: the canvas re-encode (STILL_LONG_EDGE / STILL_JPEG_QUALITY) drops all EXIF/GPS as a side
 * effect of going through a canvas. Videos: the RAW bytes used to be sent verbatim, which carried
 * the capture GPS (in the MP4 `©xyz`/`loci` userdata) to the whole circle — the desktop half of the
 * leak iOS/Android already close. We re-encode through a canvas + MediaRecorder (the same pipeline
 * the in-app camera uses), producing an entirely new container: no source metadata survives, and
 * it's downscaled to VIDEO_LONG_EDGE at the target bitrates in the same pass. If that re-encode
 * isn't possible in this webview we WARN and skip rather than silently ship a located original
 * (see optimizeVideoStrippingMetadata).
 */
async function sanitizeMediaFile(f, isVideo) {
  // Refuse OVERSIZE BEFORE anything is sealed. The duration cap is enforced the same way, inside
  // optimizeVideoStrippingMetadata, once the decoder reports it.
  if (!mediaSourceAllowed(f.size, isVideo, f.name)) return null;
  try {
    return isVideo ? await optimizeVideoStrippingMetadata(f) : await imageToJpegBase64(f);
  } catch (e) {
    // optimizeVideoStrippingMetadata already toasted its own reason for refusing/failing.
    if (!isVideo) toast("Couldn't attach: " + e);
    return null;
  }
}

async function handleFiles(files, after) {
  for (const f of files) {
    const isVideo = f.type.startsWith("video");
    const b64 = await sanitizeMediaFile(f, isVideo);
    if (b64 === null) continue;                    // refused — no ref, no attachment entry
    try {
      const ref = await invoke("add_media", { circleId: state.activeCircle, dataBase64: b64, isVideo });
      const url = await invoke("media_data_url", { circleId: state.activeCircle, reference: ref });
      const thumbRef = isVideo ? null : await mintThumb(b64, state.activeCircle);
      state.attachments.push({ ref, url, isVideo, thumbRef });
      after();
    } catch (e) { toast("Couldn't attach: " + e); }
  }
}

// Mint the tiny (~256px, ≤32KB) `thumb:` companion for a photo at compose time: recipients render
// it blurred behind the loading placeholder long before the full bytes land. Returns the thumb's
// ref, or null when the encode can't get small enough (a "thumb" that isn't tiny is just waste) —
// the photo simply posts without one. Mirrors iOS MediaStore.mintThumbCompanion.
async function mintThumb(b64, circleId) {
  try {
    if (b64.length * 0.75 < 64 * 1024) return null;   // already small — a thumb saves nothing
    const img = new Image();
    await new Promise((res, rej) => { img.onload = res; img.onerror = rej; img.src = "data:image/jpeg;base64," + b64; });
    if (!img.width || !img.height) return null;
    const scale = Math.min(1, 256 / Math.max(img.width, img.height));
    const c = document.createElement("canvas");
    c.width = Math.max(1, Math.round(img.width * scale));
    c.height = Math.max(1, Math.round(img.height * scale));
    c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
    let q = 0.6, data = c.toDataURL("image/jpeg", q);
    while (data.length * 0.75 > 32 * 1024 && q > 0.25) { q -= 0.15; data = c.toDataURL("image/jpeg", q); }
    if (data.length * 0.75 > 48 * 1024) return null;
    return await invoke("add_media", { circleId, dataBase64: data.split(",")[1], isVideo: false });
  } catch (_) { return null; }
}

/** The composed media array for a post/DM: attachment refs in order, then a `thumb:<ref>:<thumbRef>`
 *  pairing marker per photo that minted one (synthetic scheme — old clients simply ignore it). */
function withThumbMarkers(atts) {
  return [
    ...atts.map((a) => a.ref),
    ...atts.filter((a) => a.thumbRef).map((a) => `thumb:${a.ref}:${a.thumbRef}`),
  ];
}

// Re-encode a picked video to a metadata-free ≤1080p clip and return its base64. This is the desktop
// counterpart of iOS `MediaStore.optimizeVideo` / Android `transcodeVideo`: it plays the source into a
// canvas and captures that (plus the source audio track) with MediaRecorder, so the bytes we send are a
// BRAND-NEW container — the original's GPS/device/capture metadata cannot ride along. Downscales to
// MEDIA_TARGETS.VIDEO_LONG_EDGE and applies the target bitrates in the same pass.
//
// SECURITY: on any failure we REJECT the attachment (throw) instead of falling back to the raw file —
// the raw file is exactly the located original we must never post silently. The webviews desktop ships
// on (WebView2 on Windows, WebKitGTK on Linux) support MediaRecorder — it's the same API the camera
// dialog already relies on — but if it's unavailable the user is told, not leaked.
function optimizeVideoStrippingMetadata(file, maxDim = MEDIA_TARGETS.VIDEO_LONG_EDGE) {
  return new Promise((res, rej) => {
    if (typeof MediaRecorder === "undefined") {
      toast("This video can't be stripped of location data on this system, so it wasn't attached.");
      rej(new Error("MediaRecorder unavailable — refusing to post a video with possible location metadata"));
      return;
    }
    const url = URL.createObjectURL(file);
    const video = document.createElement("video");
    video.muted = true;            // let it autoplay through without audible playback
    video.playsInline = true;
    video.preload = "auto";
    let raf, rec, settled = false;
    const fail = (e) => {
      if (settled) return; settled = true;
      if (raf) cancelAnimationFrame(raf);
      try { if (rec && rec.state !== "inactive") rec.stop(); } catch {}
      URL.revokeObjectURL(url);
      toast("Couldn't process this video's metadata, so it wasn't attached.");
      rej(e instanceof Error ? e : new Error(String(e)));
    };
    // A refusal (as opposed to a failure) has its own message and, like `fail`, rejects — so the
    // caller never reaches `add_media` and no ref is minted for bytes that were never stored.
    const refuse = (msg) => {
      if (settled) return; settled = true;
      URL.revokeObjectURL(url);
      toast(msg);
      rej(new Error(msg));
    };
    video.onerror = () => fail(new Error("video decode failed"));
    video.onloadedmetadata = () => {
      // Length cap, checked the moment the decoder knows the duration — before a single frame is
      // drawn, recorded or sealed.
      const dur = video.duration;
      if (Number.isFinite(dur) && dur > MEDIA_TARGETS.MAX_DURATION_SEC) {
        return refuse(`That video is ${Math.round(dur / 60)} minutes — Haven caps videos at ${MEDIA_TARGETS.MAX_DURATION_SEC / 60}, so it wasn't attached.`);
      }
      const vw = video.videoWidth || 1280, vh = video.videoHeight || 720;
      const scale = Math.min(1, maxDim / Math.max(vw, vh));
      const w = Math.max(2, Math.round(vw * scale) & ~1);
      const h = Math.max(2, Math.round(vh * scale) & ~1);
      const c = document.createElement("canvas");
      c.width = w; c.height = h;
      const ctx = c.getContext("2d");
      let capStream;
      try {
        capStream = c.captureStream(30);
        // Carry the audio: capture the element's own stream and graft its audio tracks onto the canvas
        // stream. The re-mux drops the audio's metadata too (fresh container).
        const elStream = (video.captureStream && video.captureStream()) ||
          (video.mozCaptureStream && video.mozCaptureStream());
        if (elStream) elStream.getAudioTracks().forEach((t) => capStream.addTrack(t));
      } catch (e) { return fail(e); }
      const chunks = [];
      try {
        rec = new MediaRecorder(capStream, {
          videoBitsPerSecond: MEDIA_TARGETS.VIDEO_BITRATE_BPS,
          audioBitsPerSecond: MEDIA_TARGETS.VIDEO_AUDIO_BITRATE_BPS,
        });
      } catch (e) { return fail(e); }
      const stopDraw = () => { if (raf) cancelAnimationFrame(raf); raf = null; };
      rec.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
      rec.onstop = async () => {
        if (settled) return; settled = true;
        stopDraw();
        try {
          const blob = new Blob(chunks, { type: rec.mimeType || "video/webm" });
          const b64 = await blobToBase64(blob);
          URL.revokeObjectURL(url);
          res(b64);
        } catch (e) {
          // Every rejection out of here must have SAID something — the caller stays silent for
          // videos precisely because this function owns its own messaging.
          URL.revokeObjectURL(url);
          toast("Couldn't finish processing this video, so it wasn't attached.");
          rej(e);
        }
      };
      // Drive the canvas draw off requestVideoFrameCallback (fires per PRESENTED video frame) when
      // available — that's robust even if requestAnimationFrame is throttled (e.g. the window drops to
      // the background mid-encode), which would otherwise frame-starve the re-encode. Fall back to rAF.
      const drawFrame = () => ctx.drawImage(video, 0, 0, w, h);
      if (typeof video.requestVideoFrameCallback === "function") {
        const step = () => { if (settled) return; drawFrame(); video.requestVideoFrameCallback(step); };
        video.requestVideoFrameCallback(step);
      } else {
        const loop = () => { drawFrame(); raf = requestAnimationFrame(loop); };
        video.onplay = () => loop();
      }
      video.onended = () => { if (rec && rec.state !== "inactive") rec.stop(); };
      // Backstop for sources whose duration the decoder reports as NaN/Infinity (some streamed WebM):
      // the check above can't fire, so bound the capture in wall-clock time instead. The re-encode
      // runs at playback speed, so this is the same ceiling expressed the other way.
      const capTimer = setTimeout(() => { if (rec && rec.state !== "inactive") rec.stop(); },
                                  MEDIA_TARGETS.MAX_DURATION_SEC * 1000);
      rec.addEventListener("stop", () => clearTimeout(capTimer));
      try { rec.start(); } catch (e) { clearTimeout(capTimer); return fail(e); }
      video.play().catch(fail);
    };
    video.src = url;
  });
}

// Re-encode a still to the STILL target. The canvas round-trip is also what drops EXIF/GPS — a
// canvas has no metadata to write back out, so the JPEG we emit is unconditionally clean.
function imageToJpegBase64(file, maxDim = MEDIA_TARGETS.STILL_LONG_EDGE, quality = MEDIA_TARGETS.STILL_JPEG_QUALITY) {
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

// ---- re-optimize media I already shared ------------------------------------------------
//
// Design spec: `apple/HavenApp/MediaReoptimize.swift` (read its header first) and the desktop
// module header in `desktop/src-tauri/src/reoptimize.rs`. The one-paragraph version:
//
//   A media ref IS the sha-256 of the blob's plaintext, so re-encoding cannot happen in place — new
//   bytes are a new address. The mechanism is therefore an EDIT of the post carrying a full media
//   array with the new ref, keeping id/author/thread-position/original-timestamp so nothing reorders
//   and nobody is notified. Only MY OWN posts, because an Edit is signed by the author. The old blob
//   is NOT deleted (offline members still hold the pre-edit post naming it); the orphan sweep
//   retires it later, with its grace window.
//
// DESKTOP COVERS STILLS ONLY. The encoder here is the WebView, and MediaRecorder emits VP8/Opus in
// WebM. Re-encoding a video of mine — which on this device includes clips authored on my phone and
// synced here as H.264/MP4 — would replace media every member can play with media Apple cannot
// decode, and then EDIT the post so the broken copy is the only one anyone fetches. So video and
// audio are counted and reported, never rewritten. Full reasoning in the Rust module header.
//
// WHY THE LOOP IS HERE and not in Rust: the encoder is the canvas. Rust owns every DECISION (what
// is a candidate, whether an encode is a big enough win to adopt, what a post's Edit actually says);
// this file owns only the pixels and the progress bar.
const Reoptimize = {
  scanning: false,
  running: false,
  cancelRequested: false,
  hasScanned: false,
  candidates: [],
  videos: 0,
  videoBytes: 0,
  batchLimit: 25,
  doneCount: 0,
  batchCount: 0,
  lastSummary: null,
  lastWarning: null,
  _host: null,

  /// Measure my shared stills. Blocking in the backend (it decrypts each blob to probe it), which is
  /// exactly why nothing calls this on a timer — a button is the only caller, on both platforms.
  async scan() {
    if (this.scanning || this.running) return;
    this.scanning = true; this.lastWarning = null; this.draw();
    try {
      const r = await invoke("reoptimize_scan");
      this.candidates = (r && r.candidates) || [];
      this.videos = (r && r.videos_above_target) || 0;
      this.videoBytes = (r && r.video_bytes) || 0;
      if (r && r.batch_limit) this.batchLimit = r.batch_limit;
      this.hasScanned = true;
    } catch (e) {
      this.lastWarning = "Couldn't check your media: " + e;
    }
    this.scanning = false; this.draw();
  },

  cancel() { this.cancelRequested = true; this.draw(); },

  /// Re-encode up to `batchLimit` candidates, then re-share every post that named them.
  async run() {
    if (this.running || !this.candidates.length) return;
    this.running = true; this.cancelRequested = false;
    this.lastWarning = null; this.lastSummary = null; this.doneCount = 0;
    const batch = this.candidates.slice(0, this.batchLimit);
    this.batchCount = batch.length;
    let before = 0, after = 0;
    // old ref -> new ref, built across the WHOLE batch and applied in one pass afterwards, so a post
    // with three rewritten photos gets a single edit rather than three.
    const swap = {};
    this.draw();

    for (const c of batch) {
      if (this.cancelRequested) break;
      // Refuse to start an encode without room for the source and its output plus a margin. Filling
      // the disk in a loop is the other way a job like this ruins someone's day.
      let room = true;
      try { room = await invoke("reoptimize_headroom", { bytes: c.bytes }); } catch (_) {}
      if (!room) { this.lastWarning = "Stopped — not enough free space to re-encode safely."; break; }

      let newRef = null, newBytes = 0;
      try {
        const url = await invoke("media_data_url", { circleId: c.circle_id, reference: c.reference });
        if (url) {
          const b64 = await stillToJpegBase64FromSrc(url);
          newBytes = base64ByteLength(b64);
          // Rust decides whether this is a big enough win to adopt, and only writes the blob if it
          // is — so a rejected encode never mints a ref, and never needs deleting.
          newRef = await invoke("reoptimize_accept", { circleId: c.circle_id, reference: c.reference, dataBase64: b64 });
        }
      } catch (e) {
        newRef = null;
      }
      if (!newRef) {
        // A rejected encode was already recorded by the backend; a THROWN one (no bytes, decode
        // failure) was not. Recording twice is a no-op, so this is unconditional and simple.
        try { await invoke("reoptimize_skip", { reference: c.reference }); } catch (_) {}
        this.doneCount++; this.draw();
        continue;
      }
      before += c.bytes; after += newBytes;
      swap[c.reference] = newRef;
      this.doneCount++; this.draw();
    }

    // APPLY. Targets are re-read NOW rather than reused from the scan: minutes have passed, and a
    // post edited or retracted in the meantime must be edited against its current state, not a stale
    // copy that would silently revert the user's own change. (The backend re-reads them a second
    // time inside reoptimize_apply, which is the authoritative check — this pass only decides which
    // events to touch.)
    let reshared = 0;
    const swapped = Object.keys(swap).length;
    if (swapped) {
      try {
        for (const t of await invoke("reoptimize_targets")) {
          if (!t.media.some((r) => swap[r])) continue;
          // `map` preserves order and passes everything else through untouched — including synthetic
          // `geo:` location pins, which ride in the same array and carry no bytes.
          const media = t.media.map((r) => swap[r] || r);
          if (await invoke("reoptimize_apply", { circleId: t.circle_id, eventId: t.event_id, media })) reshared++;
        }
      } catch (e) {
        this.lastWarning = "Some posts couldn't be re-shared: " + e;
      }
    }

    const pct = before > 0 ? Math.max(0, 100 - Math.round((after * 100) / before)) : 0;
    this.lastSummary = !swapped
      ? "Nothing could be made smaller"
      : `${swapped} item${swapped === 1 ? "" : "s"} re-shared across ${reshared} post${reshared === 1 ? "" : "s"} · `
        + `${fmtBytes(before)} → ${fmtBytes(after)} (${pct}% smaller)`;
    if (this.cancelRequested) this.lastWarning = "Stopped.";
    this.running = false;
    // Re-scan so the remaining count is honest and anything just rewritten drops off the list —
    // nothing references the old ref any more, so it is no longer one of my shared items.
    //
    // But HOLD THE WARNING ACROSS IT. `scan()` clears `lastWarning` (a fresh measurement shouldn't
    // inherit a stale complaint), which means this trailing re-scan would otherwise wipe the two
    // messages this run most needs to deliver — "Stopped." and "not enough free space" — before the
    // user ever sees them. A warning that is only displayed for the duration of a re-scan is a
    // warning that was never shown. (Apple's `MediaReoptimizer.run` has the same ordering and the
    // same swallow; worth fixing there too.) A warning raised BY the re-scan wins, since that one
    // describes the state the user is looking at now.
    const raised = this.lastWarning;
    await this.scan();
    if (raised && !this.lastWarning) { this.lastWarning = raised; this.draw(); }
  },

  get pendingBytes() { return this.candidates.reduce((n, c) => n + c.bytes, 0); },

  title() {
    if (this.scanning) return "Checking your shared media…";
    if (this.running) return `Re-optimizing ${Math.min(this.doneCount + 1, this.batchCount)} of ${this.batchCount}…`;
    if (!this.candidates.length) return "Re-optimize media I already shared";
    const n = Math.min(this.candidates.length, this.batchLimit);
    return `Shrink & re-share ${n} photo${n === 1 ? "" : "s"}`;
  },

  foundText() {
    const total = this.candidates.length;
    const batch = Math.min(total, this.batchLimit);
    const legacy = this.candidates.filter((c) => c.legacy_by_age).length;
    let s = `${total} photo${total === 1 ? "" : "s"} · ${fmtBytes(this.pendingBytes)} currently on every member's device`;
    if (legacy > 0) s += ` · ${legacy} shared before Haven learned to compress`;
    if (batch < total) s += `. This run does the ${batch} largest; click again for the rest.`;
    return s;
  },

  /// Re-render in place. The row owns a single host element and repaints it, which is how the rest
  /// of this file handles live state without a framework.
  draw() {
    const host = this._host;
    if (!host || !host.isConnected) return;
    const busy = this.scanning || this.running;
    const kids = [];

    const btn = el("button", { class: "btn" + (this.candidates.length && !busy ? " primary" : ""),
      style: "display:flex;justify-content:space-between;align-items:center" },
      el("span", {}, this.title()), busy ? el("span", { class: "muted small" }, "…") : el("span", {}, ""));
    btn.disabled = busy;
    // TWO CLICKS BY DESIGN: the first measures and TELLS you what it found, the second commits. A
    // button that silently re-encoded a gigabyte and re-published a year of posts on one click would
    // be the wrong shape of thing entirely.
    btn.onclick = () => { if (!this.candidates.length) this.scan(); else this.run(); };
    kids.push(btn);

    if (this.running) {
      const stop = el("button", { class: "btn danger small" }, this.cancelRequested ? "Stopping…" : "Stop after this one");
      stop.disabled = this.cancelRequested;
      stop.onclick = () => this.cancel();
      kids.push(stop);
    }
    if (this.lastWarning) kids.push(el("div", { class: "small", style: "color:var(--warn,#c60)" }, "⚠️ " + this.lastWarning));
    if (this.lastSummary && !this.running) kids.push(el("div", { class: "small", style: "color:var(--ok,#2a7)" }, "✓ " + this.lastSummary));

    if (this.candidates.length && !this.running) {
      kids.push(el("div", { class: "muted small" }, this.foundText()));
    } else if (this.hasScanned && !busy && !this.lastSummary) {
      kids.push(el("div", { class: "muted small" }, "✓ Every photo you've shared is already as small as it can be."));
    }
    // The honest footnote. Silently omitting my own oversized videos would let a 1.2 GB library look
    // like it had nothing to gain — and this device genuinely cannot re-encode them without handing
    // the circle a clip Apple can't play.
    if (this.hasScanned && this.videos > 0) {
      kids.push(el("div", { class: "muted small" },
        `${this.videos} video${this.videos === 1 ? "" : "s"} and voice note${this.videos === 1 ? "" : "s"} of yours (${fmtBytes(this.videoBytes)}) skipped — `
        + "video re-encoding isn't available here; use Haven on your phone for those."));
    }
    host.replaceChildren(...kids);
  },

  /// Build (or rebuild) the Settings ▸ Storage row.
  row() {
    // Never leave a previous sheet's stale flags on screen; state that outlives the sheet is only
    // the scan RESULT, which the backend can reproduce anyway.
    if (!this.running && !this.scanning) { this.lastSummary = null; this.lastWarning = null; }
    this._host = el("div", { class: "col", style: "gap:6px" });
    this.draw();
    return this._host;
  },
};

/// Byte length of a base64 payload, without materialising it.
function base64ByteLength(b64) {
  if (!b64) return 0;
  let n = Math.floor((b64.length * 3) / 4);
  if (b64.endsWith("==")) n -= 2;
  else if (b64.endsWith("=")) n -= 1;
  return n;
}

/// Re-encode an already-decoded still (a `data:` URL from the store) to the STILL target.
///
/// Deliberately the SAME transform `imageToJpegBase64` applies to a newly-attached photo —
/// STILL_LONG_EDGE / STILL_JPEG_QUALITY, via a canvas — so a re-optimized photo is byte-for-byte the
/// kind of thing this client already posts, and so a change to the targets moves both at once. It
/// differs only in its input: a data URL rather than a File, because the source here is a blob we
/// already hold rather than something the user just picked.
function stillToJpegBase64FromSrc(src, maxDim = MEDIA_TARGETS.STILL_LONG_EDGE, quality = MEDIA_TARGETS.STILL_JPEG_QUALITY) {
  return new Promise((res, rej) => {
    const img = new Image();
    img.onload = () => {
      const scale = Math.min(1, maxDim / Math.max(img.width, img.height));
      const c = el("canvas");
      c.width = Math.max(1, Math.round(img.width * scale));
      c.height = Math.max(1, Math.round(img.height * scale));
      c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
      const out = c.toDataURL("image/jpeg", quality).split(",")[1];
      if (!out) rej(new Error("canvas produced no JPEG"));
      else res(out);
    };
    img.onerror = () => rej(new Error("couldn't decode the stored image"));
    img.src = src;
  });
}

function postCard(it, circleId, reports = []) {
  // macOS `header`: avatar, name and relative time all on ONE line, `···` at the far right.
  const kebab = el("button", { class: "kebab", title: "More", "aria-label": "More" }, icon("ellipsis"));
  kebab.addEventListener("click", () => postMenu(kebab, it, circleId));
  const head = el("div", { class: "post-head" },
    el("div", { class: "avatar", style: "width:34px;height:34px;font-size:14px" }, initials(it.author_name)),
    el("span", { class: "name" }, it.author_name),
    el("span", { class: "when" }, relTime(it.created_at) + (it.edited ? " · edited" : "")),
    kebab,
  );

  // Another member reported this post → surface the circle's shared moderation signal with
  // per-viewer actions (hide / remove from circle / block). The reporter themselves never sees
  // it — reporting hid the post for them.
  const banner = !it.is_me && reports.length ? reportedBanner(it, circleId, reports) : null;

  const body = it.unsent
    ? el("div", { class: "post-body muted" }, "🚫 This post was unsent")
    : el("div", { class: "post-body" }, it.body);

  const mediaRefs = it.media || [];
  const audioRefs = mediaRefs.filter((r) => isAudioRef(r));
  // A `geo:` location ref is NOT real media — split it out so it renders as a map chip above the grid
  // instead of a broken spinner tile (and so a photo+location post doesn't fall into the masonry path).
  const geo = mediaRefs.map(parseGeo).find(Boolean) || null;
  // Drop synthetic poster:/orig: markers + original companions (Apple MediaVariants.displayRefs).
  const visualRefs = displayMediaRefs(mediaRefs).filter((r) => !isAudioRef(r) && !r.startsWith("geo:"));
  const mediaCount = visualRefs.length;
  // 2…10 real items → the carousel (any aspect); a bigger set → the masonry grid. The count is of
  // VISUAL refs, never `it.media`: a location-only post has a non-empty media array and no visual
  // refs at all, and must render neither pager (a bare `<= 10` there is an empty grey box).
  const carousel = mediaCount >= 2 && mediaCount <= 10;
  const media = el("div", { class: "post-media" + (carousel ? " carousel" : mediaCount > 1 ? " masonry" : mediaCount === 1 ? " single" : ""), style: "position:relative" });
  if (carousel) mediaCarousel(visualRefs, media);
  else if (mediaCount === 1) mediaSingle(visualRefs[0], media);
  // The masonry column tiles are width-driven with `height: auto`, so an un-decoded one lays out at
  // ZERO height and then shoves the rest of the feed down as it lands. Reserve each tile's shape up
  // front from the remembered pixel size (iOS parity: the grid gets its aspect from the persisted
  // map rather than from a main-thread decode).
  else for (const ref of visualRefs) media.append(guardSensitive(reserveAspect(mediaNode(ref), ref), ref));
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

  // NowPlayingPill: a full-width pink-tinted glass capsule under the media.
  const song = it.music ? el("a", {
    class: "song-chip glass tint-pink",
    title: "Open in your music app",
    onclick: () => { const u = musicLink(it.music); if (u) openExternal(u); },
  }, el("span", { class: "note" }, icon("music.note")),
     el("span", { style: "flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" },
       el("strong", {}, it.music.title), " · ", it.music.artist)) : null;

  // macOS `reactionsRow`: chips left (glass capsules, pink-tinted when they're yours, capped at
  // four so a post can't flood the row), quick-react emoji + `＋` pinned right.
  const actions = el("div", { class: "post-actions" });
  for (const r of cappedReactions(it.reactions, 4)) {
    actions.append(el("button", { class: "react-pill glass" + (r.mine ? " tint-pink mine" : ""), title: r.mine ? "Remove your reaction" : "React",
      onclick: () => toggleReact(circleId, it.id, r.emoji, it.reactions) },
      el("span", {}, r.emoji), el("span", { class: "n" }, String(r.count))));
  }
  const hiddenCount = Math.max(0, (it.reactions || []).length - cappedReactions(it.reactions, 4).length);
  if (hiddenCount > 0) actions.append(el("span", { class: "react-pill glass" }, el("span", { class: "n" }, "+" + hiddenCount)));

  const quick = el("div", { class: "quick" });
  for (const e of frequentEmoji(3)) quick.append(el("button", { title: "React " + e, onclick: () => quickReact(circleId, it.id, e, it.reactions) }, e));
  const more = el("button", { class: "more", title: "More reactions", "aria-label": "More reactions" }, icon("plus.circle"));
  more.addEventListener("click", () => emojiPicker(more, circleId, it.id));
  quick.append(more);
  const cmtBtn = el("button", { title: "Comments" }, `💬 ${(it.comments || []).length}`);
  quick.append(cmtBtn);
  actions.append(quick);

  const comments = el("div", { class: "comments" });
  if ((it.comments || []).length) {
    const cl = el("div", { class: "comment-list" });
    for (const c of it.comments || []) {
      cl.append(el("div", { class: "comment" },
        el("div", { class: "avatar", style: "width:26px;height:26px;font-size:11px" }, initials(c.author_name)),
        el("div", { class: "bubble" },
          el("div", { class: "row", style: "gap:6px" },
            el("span", { class: "who" + (c.is_me ? " me" : "") }, c.is_me ? "You" : c.author_name),
            el("span", { class: "when muted small" }, relTime(c.created_at))),
          el("div", {}, c.body)),
      ));
    }
    comments.append(cl);
  }
  // Reply row: paperclip + pill field + circular pink send, straight from macOS `commentField`.
  const cin = el("input", { placeholder: "Add a reply…", onkeydown: (e) => { if (e.key === "Enter") sendComment(); } });
  const sendComment = async () => {
    const b = cin.value.trim();
    if (!b) return;
    await invoke("comment", { circleId, target: it.id, body: b });
    cin.value = "";
  };
  comments.append(el("div", { class: "reply-row" },
    el("button", { class: "icon-btn sm pink", title: "Attach", onclick: () => toast("Attach a photo to a reply from the phone apps for now") }, icon("paperclip")),
    cin,
    el("button", { class: "send-sm", title: "Send", "aria-label": "Send reply", onclick: sendComment }, icon("paperplane.fill")),
  ));
  cmtBtn.addEventListener("click", () => comments.classList.toggle("show"));

  const geoNode = geo ? geoChip(geo) : null;
  // data-post is how a post link finds its card (focusPostCard) — ids can hold anything, so it's an
  // attribute lookup rather than an id selector that would need escaping.
  // data-author / data-mine ride alongside so a media tile that discovers its bytes are missing can
  // find out which post it belongs to and offer "Ask for it back" — the tile is several helpers deep
  // by then, and galleries and pagers have no business carrying a post id through.
  return el("div", { class: "card post", "data-post": it.id, "data-author": it.author_short || "", "data-mine": it.is_me ? "1" : "" }, head, banner, body, media.children.length ? media : null, geoNode, audio.children.length ? audio : null, song, actions, comments);
}

// ---- Reports (decentralized moderation) --------------------------------------------------
// Mirrors apple/HavenApp/ReportUI.swift: circles have no owner, so a report is sealed to the
// WHOLE circle and every member acts with the power they already hold. Only who-reported-whom
// and the category ever leave the circle (the backend's content-free ledger ping).

const REPORT_REASONS = [
  ["Harassment or bullying", "🗯"],
  ["Nudity or sexual content", "🙈"],
  ["Violence or dangerous acts", "⚠️"],
  ["Spam or scam", "🛡"],
  ["Something else", "🚩"],
];

/// Pick a category, optionally add a circle-only note, optionally block the author in the same
/// motion. Submitting hides the post for the reporter instantly.
function reportDialog(it, circleId) {
  let reason = null;
  let alsoBlock = false;
  const submit = el("button", { class: "btn primary", disabled: true, onclick: async () => {
    const author = await invoke("report", { circleId, target: it.id, reason, comment: note.value.trim() }).catch(() => null);
    Hidden.hide(it.id);
    if (alsoBlock && author) await invoke("block", { idHex: author }).catch(() => {});
    $("#modal-root").replaceChildren();
    toast("Reported");
    renderFeed();
  } }, "Report");
  const rows = REPORT_REASONS.map(([r, icon]) => el("button", { class: "btn reason", onclick: (e) => {
    reason = r;
    submit.disabled = false;
    $$(".reason", e.target.closest(".col")).forEach((b) => b.classList.toggle("primary", b === e.target.closest(".reason")));
  } }, `${icon} ${r}`));
  const note = el("textarea", { placeholder: "Add a note for your circle (optional)", rows: 2 });
  const blockBox = el("input", { type: "checkbox", onchange: (e) => { alsoBlock = e.target.checked; } });
  modal(el("div", {},
    el("h2", {}, "Report post"),
    el("div", { class: "muted small", style: "margin-bottom:8px" }, "What's wrong with it?"),
    el("div", { class: "col" }, ...rows),
    note,
    el("label", { class: "row", style: "margin-top:8px;gap:8px;cursor:pointer" }, blockBox, `✋ Also block ${it.author_name}`),
    el("div", { class: "muted small", style: "margin-top:10px" },
      "Hides the post for you now; your circle sees the report. Nothing is ever logged."),
    el("div", { class: "row", style: "margin-top:12px;justify-content:flex-end" }, submit),
  ));
}

/// Banner on a post that OTHER members reported. Each viewer decides for themselves: hide it,
/// remove the author from their circle, or block.
function reportedBanner(it, circleId, reports) {
  const names = [...new Set(reports.map((r) => r.reporter_name))].sort().join(", ");
  const reasons = [...new Set(reports.map((r) => r.reason))].join(" · ");
  const notes = reports.map((r) => r.comment).filter(Boolean);
  return el("div", { class: "reported-banner" },
    el("span", {}, "🚩"),
    el("div", { style: "flex:1;min-width:0" },
      el("div", { class: "small", style: "font-weight:600" }, `Reported by ${names}`),
      el("div", { class: "small muted" }, reasons + (notes.length ? ` — “${notes[0]}”` : "")),
    ),
    el("button", { class: "btn small ghost", onclick: () => reportedActions(it, circleId, reports) }, "Act"),
  );
}

function reportedActions(it, circleId, reports) {
  const author = reports[0].author;   // FULL node hex, embedded by the reporter's core
  const m = el("div", {}, el("h2", {}, "Reported post"),
    el("div", { class: "col" },
      el("button", { class: "btn", onclick: () => { Hidden.hide(it.id); $("#modal-root").replaceChildren(); renderFeed(); } }, "🙈 Hide for me"),
      el("button", { class: "btn danger", onclick: async () => {
        if (!confirm(`Remove ${it.author_name} from this circle? Their posts leave your view of the circle and they can't rejoin through you.`)) return;
        await invoke("remove_from_circle", { circleId, contactIdHex: author }).catch(() => {});
        $("#modal-root").replaceChildren();
        toast("Removed");
        renderFeed();
      } }, `👋 Remove ${it.author_name} from circle`),
      el("button", { class: "btn danger", onclick: async () => {
        await invoke("block", { idHex: author }).catch(() => {});
        $("#modal-root").replaceChildren();
        toast("Blocked");
        renderFeed();
      } }, `✋ Block ${it.author_name}`),
    ));
  modal(m);
}

const hasMine = (rs, e) => (rs || []).some((r) => r.emoji === e && r.mine);
const reactCount = (rs, e) => { const r = (rs || []).find((x) => x.emoji === e); return r ? " " + r.count : ""; };

async function toggleReact(circleId, target, emoji, reactions) {
  const mine = hasMine(reactions, emoji);
  await invoke(mine ? "unreact" : "react", { circleId, target, emoji });
}
/** Tapping a quick-react glyph adds it (and remembers it) — it never removes, which is what the
 *  chips are for. Mirrors macOS `react(_:)` → EmojiStore.record. */
async function quickReact(circleId, target, emoji, reactions) {
  EmojiStore.record(emoji);
  if (!hasMine(reactions, emoji)) await invoke("react", { circleId, target, emoji });
}

/** The most-reacted `cap` chips, always keeping the user's own so they can untap it — sorted by
 *  count descending. Byte-for-byte the rule in FeedView.swift ▸ `cappedReactions`, so a post with
 *  many distinct emoji can't flood the row on either platform. */
function cappedReactions(reactions, cap) {
  const shown = [...(reactions || [])].sort((a, b) => b.count - a.count).slice(0, cap);
  const mine = (reactions || []).find((r) => r.mine);
  if (mine && !shown.some((r) => r.emoji === mine.emoji)) {
    if (shown.length >= cap) shown.pop();
    shown.push(mine);
  }
  return shown;
}

/** Your most-used reactions, persisted — the port of apple/HavenApp/Emoji.swift ▸ EmojiStore, so
 *  the quick-react row is yours rather than a fixed list. */
const EmojiStore = {
  KEY: "haven-emoji-freq",
  counts: JSON.parse(localStorage.getItem("haven-emoji-freq") || "{}"),
  record(e) { this.counts[e] = (this.counts[e] || 0) + 1; localStorage.setItem(this.KEY, JSON.stringify(this.counts)); },
};
const DEFAULT_EMOJI = ["❤️", "😂", "👍"];
function frequentEmoji(n) {
  const ranked = Object.entries(EmojiStore.counts).sort((a, b) => b[1] - a[1]).map(([e]) => e);
  for (const d of DEFAULT_EMOJI) if (!ranked.includes(d)) ranked.push(d);
  return ranked.slice(0, n);
}

const EMOJI_CHOICES = ["❤️", "👍", "😂", "🔥", "😮", "😢", "🎉", "💜", "👏", "😍", "🙌", "✨"];
/** The full picker, anchored at the `＋` (macOS `ReactionPicker`). */
function emojiPicker(anchor, circleId, target) {
  const root = $("#menu-root");
  const grid = el("div", { class: "menu glass", style: "min-width:0;padding:8px" },
    el("div", { style: "display:grid;grid-template-columns:repeat(6,1fr);gap:4px" },
      ...EMOJI_CHOICES.map((c) => el("button", {
        style: "font-size:19px;padding:6px;justify-content:center",
        onclick: async () => { closeMenu(); EmojiStore.record(c); await invoke("react", { circleId, target, emoji: c }); },
      }, c))));
  const backdrop = el("div", { class: "menu-backdrop", onclick: closeMenu });
  root.replaceChildren(backdrop, grid);
  const r = anchor.getBoundingClientRect();
  const gw = grid.offsetWidth, gh = grid.offsetHeight;
  grid.style.left = Math.max(8, Math.min(r.right - gw, window.innerWidth - gw - 8)) + "px";
  grid.style.top = (r.top - gh - 6 > 8 ? r.top - gh - 6 : r.bottom + 6) + "px";
}

/** The post's `···` menu — a popover at the glyph, matching macOS `header`'s Menu (not a modal). */
function postMenu(anchor, it, circleId) {
  const isHidden = Hidden.has(it.id);
  // #2 device pin: real, fetchable media refs only (a geo: location pin carries no bytes to keep).
  const keepRefs = (it.media || []).filter((r) => !r.startsWith("geo:"));
  // The post's author as a CONTACT — undefined when we don't hold them, which is what hides
  // "Message …": you can't DM someone you don't have.
  const author = authorContact(it.author_short);
  popMenu(anchor, [
    keepRefs.length ? { label: "Keep on this device", icon: "pin", on: async () => {
      try { await invoke("media_pin", { refs: keepRefs }); toast("Kept on this device"); }
      catch (e) { toast("Couldn't keep: " + e); }
    } } : null,
    // Share a pointer to this post: the web form, so it crosses to iOS/Android and survives being
    // pasted into any chat app. It carries no key — only a device already in the circle can open it.
    { label: "Share post", icon: "square.and.arrow.up", on: async () => {
      try { await navigator.clipboard.writeText(DeepLink.postLink(circleId, it.id)); toast("Link copied"); }
      catch (e) { toast("Couldn't copy: " + e); }
    } },
    it.is_me ? { label: "Edit", icon: "pencil.circle.fill", on: () => editPostDialog(it, circleId) } : null,
    it.is_me ? { label: "Unsend", icon: "arrow.uturn.backward", danger: true, on: async () => { await invoke("unsend_post", { circleId, target: it.id }); toast("Unsent"); } } : null,
    // Hide any post from my own feed (reversible via the circle menu's "Show hidden posts").
    { label: isHidden ? "Unhide" : "Hide", icon: isHidden ? "eye" : "eye.slash",
      on: () => { isHidden ? Hidden.unhide(it.id) : Hidden.hide(it.id); renderFeed(); } },
    // Reply to the AUTHOR privately: open (or reuse) the DM with them and STAGE an unsent draft
    // naming the post, with the thread open and the cursor waiting.
    //
    // It used to SEND the post's media into the conversation immediately — publishing something the
    // user had not written yet — and set `state.activeCircle` (the CIRCLE selector) to a `dm:` id,
    // which dropped them into the feed layout against a DM rather than opening the thread. It now
    // sends nothing, and staged text is the post's LINK, not its media: re-sealing a whole video
    // into the DM circle before anyone has decided to send anything is work that shouldn't happen,
    // and the link opens the real post (with its media) for anyone already in the circle.
    it.is_me || !author ? null : {
      label: `Message ${author.name}`, icon: "bubble.left",
      on: async () => {
        const t = await invoke("message_author",
          { authorShort: it.author_short, circleId, postId: it.id }).catch(() => null);
        if (!t || !t.dm) { toast("Couldn't open the message"); return; }
        // Consumed once by renderThread's composer — appended there, never assigned, so re-entering
        // a thread cannot discard something half-typed.
        if (t.draft) state.pendingDraft = { id: t.dm, text: t.draft };
        state.activeDm = { id: t.dm, name: t.name || author.name };
        switchView("messages");
      },
    },
    // Report to the whole circle (decentralized moderation — see reportDialog).
    it.is_me ? null : { label: "Report", icon: "flag", danger: true, on: () => reportDialog(it, circleId) },
  ], { align: "right" });
}

function editPostDialog(it, circleId) {
  const ta = el("textarea", {}, );
  ta.value = it.body;
  modal(el("div", {}, el("h2", {}, "Edit post"), ta,
    el("div", { class: "row", style: "margin-top:12px;justify-content:flex-end" },
      // media/music are passed back UNCHANGED: an edit replaces the arrays rather than merging, so
      // omitting them here deleted every photo and song off the post for the whole circle.
      el("button", { class: "btn primary", onclick: async () => { await invoke("edit_post", { circleId, target: it.id, body: ta.value.trim(), media: it.media || [], music: it.music || null }); $("#modal-root").replaceChildren(); } }, "Save"))));
}

function newCircleDialog() {
  const inp = el("input", { placeholder: "Circle name (e.g. Family)" });
  modal(el("div", {}, el("h2", {}, "New circle"), inp,
    el("div", { class: "row", style: "margin-top:12px;justify-content:flex-end" },
      el("button", { class: "btn primary", onclick: async () => { if (inp.value.trim()) { state.activeCircle = await invoke("create_circle", { name: inp.value.trim() }); } $("#modal-root").replaceChildren(); renderFeed(); } }, "Create"))));
}

/** The manage-circle SHEET behind the toolbar's people button — macOS `CircleView`, presented via
 *  `.sheet` from the Circle tab. This is also where Connect lives now that it isn't a tab: the
 *  prominent "Invite someone" action opens the Connect sheet (macOS `YouView.actionsRow` ▸
 *  `showConnect`). */
async function circleSheet() {
  const circles = await invoke("circles").catch(() => []);
  await manageCircleDialog(circles.find((c) => c.id === state.activeCircle));
}

async function manageCircleDialog(circle) {
  if (!circle) return;
  const isDefault = circle.id === "default";
  // The REAL name — this field renames the circle for everyone, so it must never be seeded with my
  // private nickname, which would silently push my name for it onto the whole circle on Rename.
  const nameInp = el("input", { value: circle.name });
  const nickInp = el("input", { value: CircleNick.get(circle.id) || "", placeholder: "Your name for this circle" });
  const contacts = await invoke("contacts").catch(() => []);
  // Switch-Flip 1.0.7 §2: the circle's current admin set (creator + delegated admins), so we can
  // label existing admins and only offer promotion to the rest.
  const admins = new Set(
    (await invoke("circle_admins", { circleId: circle.id }).catch(() => [])).map((h) => h.toLowerCase()),
  );
  const memberList = el("div", { class: "col" });
  if (!contacts.length) memberList.append(el("div", { class: "muted small" }, "No contacts yet — connect a friend first."));
  for (const c of contacts) {
    const isAdmin = admins.has((c.id_hex || "").toLowerCase());
    memberList.append(el("div", { class: "list-item" },
      el("div", { class: "avatar", style: "width:30px;height:30px;font-size:12px" }, initials(c.name)),
      el("div", { style: "flex:1" }, c.name),
      el("button", { class: "btn small", onclick: async (e) => {
        try { await invoke("add_to_circle", { circleId: circle.id, contactIdHex: c.id_hex }); e.target.textContent = "Added ✓"; e.target.disabled = true; toast(`Added ${c.name}`); }
        catch (err) { toast("Couldn't add: " + err); }
      } }, "Add"),
      // §2: promote a member to admin (creator/admin only — the engine refuses otherwise). Admins can
      // remove members from the encrypted group (MLS Remove), so this is a deliberate, per-member act.
      isAdmin
        ? el("span", { class: "muted small", title: "Circle admin", style: "align-self:center" }, "Admin ✓")
        : el("button", { class: "btn small ghost", title: "Make this member an admin (can remove members)", onclick: async (e) => {
            try {
              const ok = await invoke("grant_circle_admin", { circleId: circle.id, adminHex: c.id_hex });
              if (ok) { e.target.textContent = "Admin ✓"; e.target.disabled = true; toast(`${c.name} is now an admin`); }
              else { toast("Only the circle's creator or an admin can promote members"); }
            } catch (err) { toast("Couldn't promote: " + err); }
          } }, "Make admin"),
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
  relaySection.append(el("button", { class: "btn small ghost", style: "align-self:flex-start", onclick: () => relaySheet() }, "Manage relays →"));

  // The circle's own name (nickname-resolved), not a hardcoded "My Circle" — this sheet manages
  // whichever circle is active.
  sheet(circleDisplayName(circle.id, circle.name), el("div", { class: "col" },
    // Connect's front door, now that it isn't a tab — the same prominent gradient pill macOS gives
    // it in YouView.actionsRow.
    el("button", { class: "btn primary wide", onclick: () => connectSheet() }, "Invite someone to this circle"),
    el("label", { class: "muted small", style: "margin-top:6px" }, "Name"),
    el("div", { class: "row" }, nameInp,
      el("button", { class: "btn", onclick: async () => { const n = nameInp.value.trim(); if (n && n !== circle.name) { await invoke("rename_circle", { id: circle.id, name: n }); toast("Renamed"); closeModal(); renderFeed(); } } }, "Rename")),
    el("div", { class: "muted small" }, "What this circle is called for you and everyone in it."),
    // A PRIVATE name, alongside the shared rename above. Renaming already renamed it for everyone in
    // the circle, which is not the same thing as wanting your own name for it.
    el("label", { class: "muted small", style: "margin-top:6px" }, "Your name"),
    el("div", { class: "row" }, nickInp,
      el("button", { class: "btn", onclick: () => {
        CircleNick.set(circle.id, nickInp.value);
        toast(nickInp.value.trim() ? "Saved — only you see this" : "Using the circle's own name");
        closeModal(); renderFeed(); renderTitlebarTrailing();
      } }, "Save")),
    el("div", { class: "muted small" }, "Only you see this. It never reaches anyone else in the circle, and it doesn't change the circle's name for them. Leave it empty to use the circle's own name."),
    el("label", { class: "muted small", style: "margin-top:6px" }, "Relays for this circle"),
    el("div", { class: "muted small" }, "Pick which of your relays carry this circle — the default relay always applies."),
    relaySection,
    el("label", { class: "muted small", style: "margin-top:6px" }, "Members"),
    memberList,
    isDefault ? null : el("button", { class: "btn danger", style: "margin-top:6px", onclick: async () => {
      await invoke("leave_circle", { id: circle.id }); state.activeCircle = "default"; closeModal(); toast("Left circle"); renderFeed();
    } }, "Leave this circle"),
  ));
}

function hydrateMedia(root, circleId) {
  $$("[data-ref]", root).forEach((node) => loadMedia(node, circleId, node.dataset.ref));
}

// ---- Stories ---------------------------------------------------------------------------
// Stories have no view of their own: the tray lives at the TOP OF THE CIRCLE FEED (see
// `storiesTray`), exactly as it does on macOS. These two are what the tray opens.


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
    const num = (v, d) => (Number.isFinite(v) ? v : d);
    const scale = num(spec.mediaScale, 1), offX = num(spec.mediaOffX, 0);
    const offY = num(spec.mediaOffY, 0), rot = num(spec.mediaRotation, 0);
    // A reframed story is worth encoding even with NO caption — the framing IS authorship, and bailing
    // on empty text would silently throw away a zoom-out the author deliberately chose. Mirrors
    // StoryCaption.swift's `hasMediaTransform` guard and StoryCaptions.kt's `hasTransform`.
    if (!t && scale === 1 && offX === 0 && offY === 0 && rot === 0) return "";
    const f = (n, d) => Number(n).toFixed(d);
    return "\u0001" + [spec.color, spec.font, spec.style, f(spec.x, 3), f(spec.y, 3), f(spec.size, 3),
                        // Field WIDTHS are load-bearing, not cosmetic: Android and Apple both format
                        // this tail as "%.3f,%.3f,%.3f,%.3f,%.4f,%.4f,%.4f" (x,y,size,mediaScale at 3
                        // decimals, then the three at 4), so an untouched composer still emits the
                        // byte-identical identity tail it always did. mediaRotation is RADIANS (iOS
                        // authors it from a RotationGesture) and is the APPENDED 10th field — a client
                        // that only knows the 9-field form reads what it understands instead of
                        // failing the whole decode.
                        f(scale, 3), f(offX, 4), f(offY, 4), f(rot, 4)].join(",") + "\u0001" + t;
  },
  decode(body) {
    const def = { color: 0, font: 0, style: 1, x: 0.5, y: 0.5, size: 1, mediaScale: 1, mediaOffX: 0, mediaOffY: 0, mediaRotation: 0 };
    if (!body || body[0] !== "\u0001") return { text: body || "", spec: def };
    const sep = body.indexOf("\u0001", 1);
    if (sep < 0) return { text: body.slice(1), spec: def };
    const n = body.slice(1, sep).split(",");
    let style = parseInt(n[2], 10); if (Number.isNaN(style)) style = 1;
    if ((style === 0 || style === 1) && n.length === 6) style = style === 1 ? 4 : 1;  // legacy bit
    return { text: body.slice(sep + 1), spec: {
      color: parseInt(n[0], 10) || 0, font: parseInt(n[1], 10) || 0, style,
      x: parseFloat(n[3]) || 0.5, y: parseFloat(n[4]) || 0.5, size: parseFloat(n[5]) || 1,
      // Author's media framing (fields 6-8, the composer's zoom + pan). Absent on legacy/6-field
      // bodies → identity, so old stories render exactly as before.
      mediaScale: parseFloat(n[6]) || 1, mediaOffX: parseFloat(n[7]) || 0, mediaOffY: parseFloat(n[8]) || 0,
      // Rotation (RADIANS) is field 9, APPENDED after the 9-field form — a story from a client that
      // knows it decodes here, and one from a client that doesn't reads as rotation 0 rather than
      // failing to decode at all.
      mediaRotation: parseFloat(n[9]) || 0,
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
  // The author's spec rides the wire format, so phones render the caption styled + positioned.
  // y starts in the lower third — where the old hardcoded desktop caption sat.
  // mediaScale/mediaOffX/mediaOffY are NORMALIZED to the frame (offset ÷ frame size) and mediaRotation
  // is RADIANS, exactly as the phones author them — see StoryEditor.kt:454-475. They start at the
  // identity so an author who never touches a gesture encodes byte-for-byte what desktop always has.
  const spec = { color: 0, font: 0, style: 1, x: 0.5, y: 0.85, size: 1,
                 mediaScale: 1, mediaOffX: 0, mediaOffY: 0, mediaRotation: 0 };
  // Rotation is kept in DEGREES here because that is the unit the 90° snap is expressed in (Android
  // does the same and converts once at the wire boundary); spec.mediaRotation stays the radian
  // source of truth for encode + preview.
  let mediaRotDeg = 0;
  // Preview audio state. The clip is silent by default (a composer that blares the moment you attach
  // something is worse than one you have to unmute), and an attached song wins over it either way:
  // the song IS the story's soundtrack, so the clip's own track steps aside while one is attached and
  // comes back the moment it's removed. iOS parity — StoryCamera's preview sound toggle.
  let previewSound = false, previewMusic = null;
  const composer = buildComposer(async (body, music) => {
    const encoded = StoryCaptions.encode(body, spec);
    await invoke("post_story", { body: encoded, media: state.attachments[0] ? state.attachments[0].ref : null, music });
    closeModal();
  }, "Caption your story…", {
    circleId: state.activeCircle,
    onMusicChange: (m) => { previewMusic = m; syncPreviewAudio(); },
  });
  const ta = $("textarea", composer);

  // ── Live preview: a story frame rendered by the SAME overlay() the viewer uses, so what the
  //    author sees is exactly what ships. Drag anywhere on it to place the caption.
  const mediaLayer = el("div", { style: "position:absolute;inset:0" });
  // container-type on an inset:0 overlay, not the frame itself — same Chromium `contain: size`
  // trap storyContentNode documents.
  const capLayer = el("div", { style: "position:absolute;inset:0;container-type:size;pointer-events:none" });
  const hint = el("div", { style: "position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:rgba(255,255,255,.5);font-size:12px;pointer-events:none" }, "Preview");
  const frame = el("div", { style: "position:relative;width:min(200px,55vw);aspect-ratio:9/16;margin:0 auto;border-radius:12px;overflow:hidden;background:#000;cursor:grab;touch-action:none" },
    mediaLayer, hint, capLayer);
  const renderCap = () => {
    const c = StoryCaptions.overlay(StoryCaptions.encode(ta.value, spec));
    capLayer.replaceChildren(...(c ? [c] : []));
    hint.style.display = (ta.value.trim() || state.attachments.length) ? "none" : "";
  };
  // The clip LOOPS while the composer is open (iOS: "the canvas clip keeps looping") and its audio is
  // whatever syncPreviewAudio decides. Muted is also what lets autoplay start at all in both webviews.
  const syncPreviewAudio = () => {
    const v = $("video", mediaLayer);
    const on = previewSound && !previewMusic;
    if (v) {
      v.muted = !on;
      if (v.paused) v.play().catch(() => {});   // an unmute can pause it in a restrictive webview
    }
    if (soundBtn) {
      const hasVideo = !!v;
      soundBtn.style.display = hasVideo ? "" : "none";
      soundBtn.textContent = previewMusic ? "🎵 Song plays" : on ? "🔊 Clip sound on" : "🔇 Clip sound off";
      soundBtn.disabled = !!previewMusic;
      soundBtn.title = previewMusic
        ? "The attached song is this story's soundtrack — remove it to hear the clip"
        : "Hear the clip while you caption it";
      soundBtn.classList.toggle("primary", on);
    }
  };
  const soundBtn = el("button", { class: "btn small ghost", style: "display:none",
    onclick: () => { previewSound = !previewSound; syncPreviewAudio(); } }, "🔇 Clip sound off");
  let resetBtn = null;   // assigned below; applyMediaTransform only ever runs after that
  // The composer is the ONLY place the author sees their framing, so it applies the transform with the
  // same code path the viewer does (storyContentNode) — scale, THEN rotate, THEN translate. CSS applies
  // the LEFTMOST function outermost, which is why this reads reversed. If these two ever drift, a story
  // ships looking like something the author never composed.
  const applyMediaTransform = () => {
    const m = $("[data-story-media]", mediaLayer);
    if (m) m.style.transform =
      `translate(${spec.mediaOffX * 100}%, ${spec.mediaOffY * 100}%) `
      + `rotate(${mediaRotDeg}deg) scale(${spec.mediaScale})`;
    // Zoomed OUT below 1 the media deliberately stops short of filling the frame; the blurred backdrop
    // means the gap reads as composition rather than as black bars (bug). Same call the viewer makes.
    const bg = $("[data-story-bg]", mediaLayer);
    if (bg) bg.style.display = spec.mediaScale < 1 ? "" : "none";
    if (resetBtn) resetBtn.style.display =
      (spec.mediaScale !== 1 || spec.mediaOffX !== 0 || spec.mediaOffY !== 0 || mediaRotDeg !== 0) ? "" : "none";
  };
  const renderMedia = () => {
    const a = state.attachments[0];
    const fit = "position:absolute;inset:0;width:100%;height:100%;object-fit:cover";
    const kids = [];
    if (a && a.url) {
      // Photos only: a <video> backdrop would be a second decode of the same clip for a background
      // nobody looks at directly — the viewer skips it for the same reason.
      if (!a.isVideo) kids.push(el("img", { src: a.url, "data-story-bg": "1", "aria-hidden": "true",
        style: fit + ";display:none;filter:blur(28px);opacity:0.6;transform:scale(1.1);pointer-events:none" }));
      kids.push(a.isVideo
        ? el("video", { src: a.url, "data-story-media": "1", muted: "", autoplay: "", loop: "", playsinline: "", style: fit })
        : el("img", { src: a.url, "data-story-media": "1", style: fit }));
    }
    mediaLayer.replaceChildren(...kids);
    applyMediaTransform();   // a re-rendered element loses its inline transform — re-apply the framing
    syncPreviewAudio();   // a re-rendered clip starts muted — re-apply whatever the author chose
    renderCap();
  };
  ta.addEventListener("input", renderCap);
  // buildComposer owns attachment add/remove internally — the preview chips are the one signal
  // that fires on both paths, so mirror the frame off them.
  new MutationObserver(renderMedia).observe($(".attach-preview", composer), { childList: true });
  const placeCap = (e) => {
    const r = frame.getBoundingClientRect();
    spec.x = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width));
    spec.y = Math.min(1, Math.max(0, (e.clientY - r.top) / r.height));
    renderCap();
  };
  // ── Who owns which gesture on the frame ───────────────────────────────────────────────────────
  // The frame is one surface with two things to move, so the split is by MODIFIER, and the plain
  // verbs stay exactly where they already were:
  //   plain drag            → place the CAPTION   (unchanged — the documented affordance, no regression)
  //   Alt/Option drag       → PAN the media
  //   wheel                 → ZOOM   (trackpad pinch arrives as wheel + ctrlKey, so it lands here too)
  //   shift + wheel         → ROTATE
  // Everything the author can click (colors, style, size, reset) lives OUTSIDE this element on
  // purpose: a gesture handler on an ancestor swallows a control's own action.
  // No attachment means there is nothing to reframe — without this an author could zoom an empty
  // frame and ship a transform against media that does not exist.
  const hasMedia = () => !!(state.attachments[0] && state.attachments[0].url);
  const MEDIA_DRAG = (e) => e.altKey && hasMedia();
  let panFrom = null;
  frame.addEventListener("pointerdown", (e) => {
    frame.setPointerCapture(e.pointerId);
    if (MEDIA_DRAG(e)) { panFrom = { x: e.clientX, y: e.clientY }; return; }
    panFrom = null; placeCap(e);
  });
  frame.addEventListener("pointermove", (e) => {
    if (!(e.buttons & 1)) return;
    if (panFrom) {
      // Normalized to the frame, matching StoryEditor.kt:470-471 (offset px ÷ box size) — a pan
      // authored on a 200px desktop preview has to mean the same thing on a 1179px phone.
      const r = frame.getBoundingClientRect();
      spec.mediaOffX += (e.clientX - panFrom.x) / r.width;
      spec.mediaOffY += (e.clientY - panFrom.y) / r.height;
      panFrom = { x: e.clientX, y: e.clientY };
      applyMediaTransform();
      return;
    }
    placeCap(e);
  });
  frame.addEventListener("pointerup", () => { panFrom = null; });
  frame.addEventListener("pointercancel", () => { panFrom = null; });
  frame.addEventListener("wheel", (e) => {
    if (!hasMedia()) return;   // let the sheet scroll normally when there is nothing to zoom
    e.preventDefault();   // otherwise the sheet scrolls out from under the gesture
    // Trackpad momentum and a mouse notch land wildly different deltas here, so clamp the per-event
    // travel: without it one flick can slam straight into a clamp and the gesture feels broken.
    const d = Math.max(-60, Math.min(60, e.deltaY || e.deltaX || 0));
    if (!d) return;
    if (e.shiftKey) {
      const next = mediaRotDeg + d * 0.3;
      // Snap to level within a couple of degrees of a right angle, so "straight" is reachable
      // deliberately rather than by luck — StoryEditor.kt:153-157, same 2.5° tolerance.
      const off = ((next % 90) + 90) % 90;
      mediaRotDeg = (off < 2.5 || off > 87.5) ? Math.round(next / 90) * 90 : next;
      spec.mediaRotation = (mediaRotDeg * Math.PI) / 180;   // wire field is RADIANS
    } else {
      // Floor 0.25, not 1 — the whole point. Clamping at 1 would mean the media could only ever be
      // zoomed IN, so a tall or wide photo could never be pulled back to show WHOLE inside a
      // portrait story. Ceiling 5. Same range as StoryEditor.kt:151.
      spec.mediaScale = Math.min(5, Math.max(0.25, spec.mediaScale * Math.exp(-d * 0.0025)));
    }
    applyMediaTransform();
  }, { passive: false });

  // ── Styling controls — the wire palette/typography tables, index-for-index. ──
  const swatches = el("div", { class: "row wrap", style: "gap:6px;justify-content:center" });
  const drawSwatches = () => {
    swatches.replaceChildren(...StoryCaptions.colors.map((c, i) =>
      el("button", { title: "Caption color", style:
        "width:20px;height:20px;border-radius:50%;padding:0;cursor:pointer;background:" + c +
        ";border:2px solid " + (i === spec.color ? "var(--text, #fff)" : "rgba(128,128,128,.35)"),
        onclick: () => { spec.color = i; drawSwatches(); renderCap(); } })));
  };
  drawSwatches();
  const STYLES = ["Plain", "Glow", "Shadow", "Neon", "Highlight"];   // wire styleRaw order
  const styleBtn = el("button", { class: "btn small ghost", title: "Caption style",
    onclick: () => { spec.style = (spec.style + 1) % STYLES.length; styleBtn.textContent = "Aa · " + STYLES[spec.style]; renderCap(); } },
    "Aa · " + STYLES[spec.style]);
  const fontBtn = el("button", { class: "btn small ghost", title: "Caption font",
    onclick: () => { spec.font = (spec.font + 1) % StoryCaptions.fonts.length; syncFont(); renderCap(); } }, "Ag");
  const syncFont = () => {
    const [family, weight] = StoryCaptions.fonts[spec.font].split("|");
    fontBtn.style.fontFamily = family; fontBtn.style.fontWeight = weight;
  };
  syncFont();
  const sizeInp = el("input", { type: "range", min: "0.5", max: "2", step: "0.05", value: String(spec.size),
    style: "flex:1;min-width:70px", oninput: () => { spec.size = parseFloat(sizeInp.value) || 1; renderCap(); } });
  // Only shown once the author has actually reframed something — an escape hatch back to the identity
  // (which is also the only way to get back to encoding the exact legacy bytes). Lives outside `frame`
  // so the frame's gesture handlers can't swallow its click.
  resetBtn = el("button", { class: "btn small ghost", style: "display:none", title: "Undo zoom, pan and rotation",
    onclick: () => {
      spec.mediaScale = 1; spec.mediaOffX = 0; spec.mediaOffY = 0; spec.mediaRotation = 0; mediaRotDeg = 0;
      applyMediaTransform();
    } }, "↺ Reset framing");

  sheet("New story", el("div", { class: "col" },
    el("div", { class: "muted small" }, "Add a photo or video with the + button. Stories disappear after 24 hours."),
    frame,
    // Spelled out because none of these are guessable: the modifiers ARE the discoverability.
    el("div", { class: "muted small", style: "text-align:center" },
      "Drag to place the caption · scroll or pinch to zoom · shift-scroll to rotate · ⌥-drag to move the photo"),
    swatches,
    el("div", { class: "row", style: "gap:8px;align-items:center" },
      styleBtn, fontBtn, el("span", { class: "muted small" }, "Size"), sizeInp),
    el("div", { class: "row wrap", style: "gap:6px" }, soundBtn, resetBtn),
    composer));
  renderMedia();
}

/** Where a song chip points.
 *
 *  `catalog_id` is overloaded by author platform: iPhone sends an Apple Music CATALOG ID, the
 *  desktop composer pastes a streaming URL, and Android sends the iTunes store link. Chips that
 *  tested for `^https?:` and gave up otherwise were therefore DEAD on every iPhone-authored post —
 *  the majority of them. A catalog id we can't linkify falls back to a search for title + artist,
 *  which is what Android's "Listen on" menu already does. */
function musicLink(m) {
  if (!m) return null;
  if (m.catalog_id && /^https?:/.test(m.catalog_id)) return m.catalog_id;
  const q = encodeURIComponent(`${m.title || ""} ${m.artist || ""}`.trim());
  return q ? `https://music.apple.com/search?term=${q}` : null;
}

/** The song attached to a story, named over the story.
 *
 *  Desktop shows the song but does NOT play it, deliberately. Apple drives MPMusicPlayerController
 *  against the viewer's own Apple Music library and Android falls back to a 30s iTunes preview;
 *  desktop has neither a library to drive nor a licence to stream, and the only thing it could
 *  honestly play is nothing. A pill that names the track and opens it in the viewer's own player is
 *  the whole truth — a half-working player that sometimes made noise would be worse. */
function storySongChip(m) {
  const url = musicLink(m);
  return el("div", {
    class: "song-chip glass tint-pink",
    style: "margin-top:10px;max-width:min(420px,100%);cursor:pointer",
    title: "Open in your music app",
    onclick: (e) => { e.stopPropagation(); if (url) openExternal(url); },
  }, el("span", { class: "note" }, icon("music.note")),
     el("span", { style: "flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" },
       el("strong", {}, m.title || "Unknown song"), m.artist ? ` · ${m.artist}` : ""));
}

/** The rendered CONTENT of a single story — framed media (author zoom/pan preserved), the styled
 *  caption overlay, and a location chip — as a centered column. Shared by the story viewer so paging
 *  between stories only has to swap this node. Story videos autoplay muted (honouring the global sound
 *  toggle) and carry NO native controls, so a tap lands on the pager instead of the scrubber. */
function storyContentNode(it) {
  const inner = el("div", { class: "col", style: "align-items:center" });
  const storyRef = displayMediaRefs(it.media || []).find((r) => !r.startsWith("geo:") && !isAudioRef(r));
  const cap = StoryCaptions.overlay(it.body);
  const tf = StoryCaptions.decode(it.body).spec;
  if (storyRef) {
    // A story authored against a song is SILENT here: the author picked the song as the audio, so
    // the clip's own track is not what they meant anyone to hear, and the composer already mutes it
    // on all three clients. `mute_video` is the author saying so outright — it rode the wire unread
    // until now. Desktop can't play the song itself (see storySongChip), so the pill below is what
    // explains the silence.
    const songMuted = !!it.music || !!it.mute_video || !!state.superDataSaver;
    const m = isVideoRef(storyRef)
      ? el("video", Object.assign({ "data-ref": storyRef, "data-video": "1", autoplay: state.superDataSaver ? undefined : "", loop: "", playsinline: "",
          style: "max-width:100%;max-height:78vh;border-radius:12px;display:block", controls: state.superDataSaver ? "" : undefined },
          state.videoSoundOn && !callAudioActive() && !songMuted ? {} : { muted: "" }))
      : el("img", { "data-ref": storyRef, style: "max-width:100%;max-height:78vh;border-radius:12px;display:block" });
    // The caption's cqh units size it against the MEDIA, like the phones do — but `container-type:
    // size` applies `contain: size`, which tells the box to lay out as if it had NO contents. On the
    // wrapper itself that is fatal: an auto-sized inline-block collapses to 0x0, taking the image
    // with it, and the whole story viewer renders BLANK. WebKitGTK/WebKit tolerated it; Chromium —
    // i.e. WebView2, i.e. every Windows user — does not.
    // So the containment lives on an absolutely-positioned overlay INSTEAD: `inset: 0` takes its
    // size from the wrapper rather than from its contents, so `contain: size` costs nothing and cqh
    // still resolves to the media's height.
    const wrap = el("div", { style: "position:relative;max-width:100%;display:inline-block" }, m);
    // The author's framing (iOS Stories.swift:120-121: scaleEffect about center, then an UNSCALED
    // offset of offX×W/offY×H of the container). CSS `translate(...) scale(...)` composes the same
    // way — the leftmost translate is applied outside the scale — and the translate percentages
    // resolve against this element's layout box, which lays out at the wrapper/container's size.
    if (tf.mediaScale !== 1 || tf.mediaOffX !== 0 || tf.mediaOffY !== 0 || tf.mediaRotation !== 0) {
      // Scale → rotate → move, matching the phones' composer and viewer, so a story looks the same
      // wherever it's opened. CSS applies the LEFTMOST function outermost, which is why the order
      // here reads reversed: translate wraps rotate wraps scale.
      const deg = (tf.mediaRotation * 180) / Math.PI;
      m.style.transform = `translate(${tf.mediaOffX * 100}%, ${tf.mediaOffY * 100}%) rotate(${deg}deg) scale(${tf.mediaScale})`;
      // iOS clips the reframed media to the story frame (.clipped()); the wrapper takes over the
      // media's rounding so the scaled overflow doesn't square the corners.
      wrap.style.overflow = "hidden";
      wrap.style.borderRadius = "12px";
      // An author who zoomed OUT (scale below 1) deliberately stopped short of filling the frame so
      // the item shows WHOLE — it should sit over its own blurred colors, the same treatment a
      // landscape post gets in the feed, rather than over a flat gap.
      if (tf.mediaScale < 1 && !isVideoRef(storyRef)) {
        const bg = el("img", { "data-ref": storyRef, "aria-hidden": "true",
          style: "position:absolute;inset:0;width:100%;height:100%;object-fit:cover;"
               + "filter:blur(28px);opacity:0.6;transform:scale(1.1);z-index:-1;pointer-events:none" });
        wrap.prepend(bg);
      }
    }
    if (cap) wrap.append(el("div", { style: "position:absolute;inset:0;container-type:size;pointer-events:none" }, cap));
    inner.append(wrap);
  } else if (cap) {
    const solo = el("div", { style: "position:relative;width:100%;min-height:200px;container-type:size" }, cap);
    inner.append(solo);
  }
  const storyGeo = (it.media || []).map(parseGeo).find(Boolean);
  if (storyGeo) inner.append(geoChip(storyGeo));
  if (it.music) inner.append(storySongChip(it.music));
  return inner;
}

/** The story viewer — pages through a FLAT, author-grouped list (groupStoriesFlat). A CLICK advances
 *  one story (the left third steps back); ArrowDown/ArrowUp/Space do the same. A horizontal SWIPE —
 *  or the Left/Right arrow keys, the desktop equivalent — skips WHOLE users: past the rest of THIS
 *  person's stories to the next person's first (dismiss past the last), or back to the previous
 *  person. Port of iOS Stories.swift skipToNextUser / skipToPrevUser (users = runs of the same author
 *  in the flat list). A single item just shows that story. */
function viewStories(list, startIndex = 0) {
  const stories = (list || []).filter((it) =>
    displayMediaRefs(it.media || []).some((r) => !r.startsWith("geo:") && !isAudioRef(r)) || StoryCaptions.decode(it.body).text);
  if (!stories.length) return;
  let index = Math.max(0, Math.min(startIndex, stories.length - 1));
  const author = (i) => (stories[i] && stories[i].author_name) || "";

  const title = el("h2", { style: "margin:6px 0 0" });
  const bars = el("div", { class: "story-progress" });
  const slot = el("div", { class: "col", style: "align-items:center;min-width:min(88vw,420px)" });
  const hint = el("div", { class: "muted small", style: "text-align:center;margin-top:8px" },
    "Tap to advance · ← → skip person · swipe to skip");
  // KEEP — a TOGGLE that holds this story on MY PROFILE past the 24h window. It does NOT re-publish
  // it: turning a story into a permanent post puts it back in the circle feed as a new thing
  // everyone sees again, and wanting to hold on to something yourself is a different act from
  // sharing it twice. A kept story still leaves everyone's story row on schedule.
  //
  // Deliberately a SIBLING of `slot`, not a child: `slot` carries the pointerdown/pointerup drag
  // handlers, and a drag recogniser on an ancestor of a button swallows the button's click — the
  // control lights up on press and then does nothing. Nothing interactive belongs inside the
  // gesture layer.
  const keepBtn = el("button", { class: "chip", style: "display:none" });
  let keptIds = new Set();
  const paintKeep = () => {
    const it = stories[index];
    if (!it || !it.is_me) { keepBtn.style.display = "none"; return; }
    const on = keptIds.has(it.id);
    keepBtn.style.display = "";
    keepBtn.classList.toggle("tint-pink", on);
    // Label AND tint change: a control that looks identical whether or not it is on reads as a dead
    // button, which is exactly the complaint this replaced.
    // Label AND tint, no glyph: this icon set has no bookmark, and a missing glyph would render as
    // an empty box next to the word — worse than the word alone.
    keepBtn.replaceChildren(on ? "Kept" : "Keep");
    keepBtn.title = on ? "Kept on your profile" : "Keep on your profile";
  };
  keepBtn.addEventListener("click", async (e) => {
    e.stopPropagation();
    const it = stories[index];
    if (!it || !it.is_me) return;
    const entry = {
      id: it.id, body: it.body || "", media: it.media || [],
      createdAt: Number(it.created_at) || 0,
      musicCatalogId: it.music ? it.music.catalog_id : null,
      musicTitle: it.music ? it.music.title : null,
      musicArtist: it.music ? it.music.artist : null,
      musicArtworkUrl: it.music ? it.music.artwork_url : null,
      musicDurationMs: it.music ? Number(it.music.duration_ms) || 0 : null,
    };
    const on = await invoke("toggle_kept_story", { entry }).catch(() => null);
    if (on === null) { toast("Couldn't update Keep."); return; }
    if (on) keptIds.add(it.id); else keptIds.delete(it.id);
    paintKeep();
  });
  const actions = el("div", { class: "row", style: "justify-content:center;margin-top:8px" }, keepBtn);
  const card = el("div", { style: "min-width:min(88vw,420px)" }, bars, title, slot, actions, hint);
  const close = modal(card);
  // Which of these are already kept — one call for the whole session, refreshed locally on toggle.
  invoke("kept_stories").then((ks) => { keptIds = new Set((ks || []).map((k) => k.id)); paintKeep(); }).catch(() => {});

  const cleanup = () => { window.removeEventListener("keydown", onKey, true); mo.disconnect(); };
  const done = () => { close(); cleanup(); };

  const show = () => {
    const it = stories[index];
    title.textContent = (it.is_me ? "You" : it.author_name) + "'s story";
    // One progress segment per story in THIS person's run, filled through the current one.
    let runStart = index; while (runStart > 0 && author(runStart - 1) === author(index)) runStart--;
    let runEnd = index; while (runEnd < stories.length - 1 && author(runEnd + 1) === author(index)) runEnd++;
    bars.replaceChildren(...Array.from({ length: runEnd - runStart + 1 }, (_, k) =>
      el("span", { class: "seg" + (runStart + k <= index ? " on" : "") })));
    slot.replaceChildren(storyContentNode(it));
    hydrateMedia(slot, it._circle || state.activeCircle || "default");
    paintKeep();   // the pill belongs to the story on screen, not to the viewer
  };

  const nextStory = () => { if (index < stories.length - 1) { index++; show(); } else done(); };
  const prevStory = () => { if (index > 0) { index--; show(); } };
  // Swipe-left / ArrowRight: skip the rest of THIS person's run → the next person's first story (past
  // the last person, dismiss).
  const nextUser = () => {
    const cur = author(index);
    let j = index + 1; while (j < stories.length && author(j) === cur) j++;
    if (j < stories.length) { index = j; show(); } else done();
  };
  // Swipe-right / ArrowLeft: back to the start of this person's run if we're partway in, else the
  // previous person's first story.
  const prevUser = () => {
    const cur = author(index);
    let runStart = index; while (runStart > 0 && author(runStart - 1) === cur) runStart--;
    if (index > runStart) { index = runStart; show(); return; }
    if (runStart === 0) return;
    const prevAuthor = author(runStart - 1);
    let ps = runStart - 1; while (ps > 0 && author(ps - 1) === prevAuthor) ps--;
    index = ps; show();
  };

  const onKey = (e) => {
    if (!card.isConnected) return;
    if (e.key === "ArrowRight") { e.preventDefault(); nextUser(); }
    else if (e.key === "ArrowLeft") { e.preventDefault(); prevUser(); }
    else if (e.key === "ArrowDown" || e.key === " ") { e.preventDefault(); nextStory(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); prevStory(); }
  };
  window.addEventListener("keydown", onKey, true);

  // Pointer: a tap advances a story (left third steps back); a horizontal DRAG skips whole users
  // (drag left → next person, drag right → previous), and a downward drag dismisses — mirroring the
  // phones' gestures.
  let sx = 0, sy = 0, dragging = false;
  slot.addEventListener("pointerdown", (e) => { dragging = true; sx = e.clientX; sy = e.clientY; });
  slot.addEventListener("pointerup", (e) => {
    if (!dragging) return; dragging = false;
    const dx = e.clientX - sx, dy = e.clientY - sy;
    if (Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > 60) { dx < 0 ? nextUser() : prevUser(); return; }
    if (dy > 90 && Math.abs(dy) > Math.abs(dx)) { done(); return; }
    if (Math.abs(dx) < 10 && Math.abs(dy) < 10) {
      const r = slot.getBoundingClientRect();
      (e.clientX - r.left) < r.width * 0.33 ? prevStory() : nextStory();
    }
  });

  // Global Escape / a backdrop click empties #modal-root — tear our listeners down when that happens.
  const mo = new MutationObserver(() => { if (!card.isConnected) cleanup(); });
  mo.observe($("#modal-root"), { childList: true, subtree: true });

  show();
}

// ---- Messages --------------------------------------------------------------------------
async function renderMessages() {
  const root = $("#view-messages");
  renderTitlebarTrailing();   // the compose chip belongs to the LIST, not an open thread
  root.classList.toggle("thread-mode", !!state.activeDm);
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

  const unreadPill = (n) => el("span", { class: "unread-pill" }, n > 99 ? "99+" : String(n));

  // Pinned grid (large avatars) above the list. iMessage-style: the unread count rides the
  // pinned avatar's shoulder.
  const grid = el("div", { class: "pin-grid" });
  for (const t of pinned) {
    const unread = t.unread || 0;
    grid.append(el("div", { class: "pin-tile", onclick: () => openDm(t) },
      el("div", { class: "avatar-wrap" },
        el("div", { class: "avatar big" }, initials(t.name)),
        unread > 0 ? unreadPill(unread) : null),
      el("div", { class: "pin-name" + (unread > 0 ? " unread" : "") }, t.name)));
  }

  // One conversation row — macOS `rowLabel`: avatar, name (BOLD while unread), the most recent
  // message as a one-line preview, unread badge. The pin/delete verbs live in the row's `···`
  // menu (macOS `conversationMenu`), not as two permanently-visible emoji buttons.
  const threadRow = (t) => {
    const unread = t.unread || 0;
    // (`dm_threads` carries no unsent flag, and src-tauri isn't mine to change — the thread view
    // renders the "Message unsent" tombstone properly, which is where it matters.)
    const preview = isSecret(t.last_body) ? "🔒 Secret message" : (t.last_body || "No messages yet");
    const kebab = el("button", { class: "kebab", title: "More", "aria-label": "More" }, icon("ellipsis"));
    kebab.addEventListener("click", (e) => {
      e.stopPropagation();
      popMenu(kebab, [
        Pins.has(t.circle_id)
          ? { label: "Unpin", icon: "mappin", on: () => { Pins.toggle(t.circle_id); renderMessages(); } }
          : { label: "Pin", icon: "mappin", on: () => { if (Pins.full) { toast("You can pin up to 6 conversations."); return; } Pins.toggle(t.circle_id); renderMessages(); } },
        { label: "Delete", icon: "eye.slash", danger: true, on: () => del(t) },
      ], { align: "right" });
    });
    return el("div", { class: "thread-item", onclick: () => openDm(t) },
      el("div", { class: "avatar" }, initials(t.name)),
      el("div", { style: "flex:1;min-width:0" },
        el("div", { class: "name" + (unread > 0 ? " unread" : "") }, t.name),
        el("div", { class: "preview" + (unread > 0 ? " unread" : ""), style: "white-space:nowrap;overflow:hidden;text-overflow:ellipsis" }, preview)),
      el("div", { class: "muted small" }, relTime(t.last_at)),
      unread > 0 ? unreadPill(unread) : null,
      kebab,
    );
  };

  const list = el("div", { class: "thread-list" });
  if (pinned.length) list.append(grid);
  for (const t of rest) list.append(threadRow(t));
  if (!threads.length) {
    list.append(el("div", { class: "empty" },
      el("div", { class: "h" }, "No messages yet"),
      el("div", {}, "Use the compose button to start one.")));
  }
  root.replaceChildren(el("div", { class: "col-wrap" },
    el("div", { class: "view-head" }, el("h1", {}, "Messages")),
    list));
}

/** New message / new group — the port of `DMContactPicker`: tap contacts to select, one → a 1:1,
 *  several → a group DM, with the prominent gradient action in the sheet's footer. */
async function newMessageSheet() {
  const contacts = await invoke("contacts").catch(() => []);
  const picked = new Set();
  const start = async () => {
    const members = contacts.filter((c) => picked.has(c.id_hex)).map((c) => [c.id_hex, c.name]);
    if (!members.length) return;
    let id, name;
    if (members.length === 1) { id = await invoke("start_dm", { contactIdHex: members[0][0], contactName: members[0][1] }); name = members[0][1]; }
    else { id = await invoke("start_group_dm", { members }); name = members.map((m) => m[1]).join(", "); }
    closeModal();
    state.activeDm = { id, name };
    switchView("messages");
  };
  const startBtn = el("button", { class: "btn primary wide", disabled: true, onclick: start }, "Start");
  const title = el("h2", {}, "New message");
  const sync = () => {
    startBtn.disabled = picked.size === 0;
    startBtn.textContent = picked.size > 1 ? "Start group" : "Start";
    title.textContent = picked.size > 1 ? `New group · ${picked.size}` : "New message";
  };
  const col = el("div", { class: "col", style: "gap:2px" });
  if (!contacts.length) col.append(el("div", { class: "muted small" }, "No contacts yet — invite someone from your circle first."));
  for (const c of contacts) {
    const check = el("span", { class: "pick-check" }, icon("checkmark"));
    const row = el("div", { class: "list-item", style: "cursor:pointer" },
      el("div", { class: "avatar" }, initials(c.name)),
      el("div", { style: "flex:1" }, c.name),
      check);
    row.addEventListener("click", () => {
      picked.has(c.id_hex) ? picked.delete(c.id_hex) : picked.add(c.id_hex);
      row.classList.toggle("picked", picked.has(c.id_hex));
      sync();
    });
    col.append(row);
  }
  sheet("New message", col, startBtn);
  const h = $("#modal-root h2"); if (h) h.replaceWith(title);
}

async function renderThread(root, dm) {
  const msgs = await invoke("messages", { circleId: dm.id });
  await loadSensitive(dm.id);   // flags are per-circle, and a DM is a circle
  // A group DM has more than one OTHER participant (member_count > 2) → each incoming message needs a
  // sender name so the group knows who said what (a 1:1 DM doesn't). The relay-reachability flag drives the
  // delivery checkmark (filled = store-and-forward reachable).
  const threads = await invoke("dm_threads");
  const meta = threads.find((t) => t.circle_id === dm.id);
  const isGroup = (meta?.member_count || 0) > 2;
  let relayReachable = false;
  try { const rs = await invoke("relay_status"); relayReachable = !!(rs.hosting || rs.relay_active || (rs.has_relay && rs.internet_active)); } catch (_) {}
  let secretOn = false;
  let editingId = null;
  // The attachments of the message being edited. Held alongside the id because an edit REPLACES the
  // media array — sending the new text without these strips the photo off the message for both
  // people in the thread.
  let editingMedia = [];
  let editingMusic = null;
  const chat = el("div", { class: "chat" });
  for (const m of msgs) {
    // A `geo:` ref renders as a map chip, not media (otherwise a broken tile in the bubble).
    // displayMediaRefs is the ONE displayRefs-parity filter: markers, original companions,
    // poster stills AND `thumb:` companions all hidden (a thumb used to render as a second
    // tiny copy of the photo in the bubble).
    const dmVisible = new Set(displayMediaRefs(m.media || []));
    const mediaEls = (m.media || []).flatMap((r) => {
      const g = parseGeo(r);
      if (g) return [geoChip(g)];
      if (!dmVisible.has(r)) return [];
      // Same reservation as the feed grid: a bubble that grows when its photo lands drags the whole
      // thread down under the reader mid-scroll.
      return [guardSensitive(reserveAspect(mediaNode(r, "max-width:240px;border-radius:12px;display:block"), r, "intrinsic"), r)];
    });

    // An unsent message is a TOMBSTONE, not a hidden row — macOS renders "Message unsent" in
    // italic on the secondary surface, so the thread still reads as a conversation.
    let bubble;
    if (m.unsent) bubble = el("div", { class: "chat-bubble tombstone" }, "Message unsent");
    else if (isSecret(m.body)) { bubble = secretBubble(m.body, m.is_me); if (mediaEls.length) bubble.append(...mediaEls); }
    else if (m.body) bubble = el("div", { class: "chat-bubble" + (m.is_me ? " me" : "") }, m.body);
    else bubble = null;

    const col = el("div", { class: "bubble-col" });
    // In a group DM, label each INCOMING message with who sent it.
    if (isGroup && !m.is_me && !m.unsent) col.append(el("div", { class: "chat-sender" }, m.author_name || "Someone"));
    if (mediaEls.length && !isSecret(m.body)) col.append(el("div", { class: "bubble-media" }, ...mediaEls));
    if (m.music) {
      col.append(el("a", { class: "song-chip glass tint-pink", style: "margin-top:0;max-width:260px",
        title: "Open in your music app",
        onclick: () => { const u = musicLink(m.music); if (u) openExternal(u); } },
        el("span", { class: "note" }, icon("music.note")),
        el("span", { style: "flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" },
          el("strong", {}, m.music.title), " · ", m.music.artist)));
    }
    if (bubble) col.append(bubble);
    // Reaction chips ride UNDER the bubble — the count only shows past 1 (macOS `bubble`).
    if ((m.reactions || []).length) {
      const rr = el("div", { class: "bubble-reacts" });
      for (const r of m.reactions) {
        rr.append(el("button", { class: "msg-react" + (r.mine ? " mine" : ""), title: r.mine ? "Remove your reaction" : "React",
          onclick: () => invoke(r.mine ? "unreact" : "react", { circleId: dm.id, target: m.id, emoji: r.emoji }) },
          r.emoji + (r.count > 1 ? " " + r.count : "")));
      }
      col.append(rr);
    }
    const meta2 = el("div", { class: "chat-meta" }, relTime(m.created_at));
    if (m.edited && !m.unsent) meta2.append(el("span", {}, "edited"));
    // sent → checkmark; reachable on the circle's relay → filled (store-and-forward delivered)
    if (m.is_me && !m.unsent) meta2.append(el("span", { class: "chat-check" + (relayReachable ? " on" : "") }, relayReachable ? "✓✓" : "✓"));
    col.append(meta2);

    const row = el("div", { class: "bubble-row" + (m.is_me ? " me" : "") }, col);
    // Right-click a message: FLAT one-tap quick emoji (never a submenu — that bug was just fixed
    // on macOS), then the full picker, then edit/delete for my own.
    if (!m.unsent) {
      col.addEventListener("contextmenu", (e) => {
        e.preventDefault();
        const anchor = { getBoundingClientRect: () => ({ left: e.clientX, right: e.clientX, top: e.clientY, bottom: e.clientY }) };
        popMenu(anchor, [
          ...frequentEmoji(3).map((emo) => ({ label: "React " + emo, on: () => { EmojiStore.record(emo); invoke("react", { circleId: dm.id, target: m.id, emoji: emo }); } })),
          { label: "More reactions…", icon: "plus.circle", on: () => emojiPicker(anchor, dm.id, m.id) },
          (m.is_me && m.body && !isSecret(m.body)) ? { sep: true } : null,
          (m.is_me && m.body && !isSecret(m.body)) ? { label: "Edit", icon: "pencil.circle.fill", on: () => beginEdit(m) } : null,
          m.is_me ? { label: "Delete", icon: "eye.slash", danger: true, on: () => invoke("unsend_post", { circleId: dm.id, target: m.id }) } : null,
        ]);
      });
    }
    chat.append(row);
  }

  const input = el("textarea", { class: "composer-field glass", placeholder: "Message…", rows: 1 });
  const autoGrow = () => { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, 132) + "px"; };
  input.addEventListener("input", autoGrow);
  // A draft staged elsewhere ("Message the author" on a post) lands here, UNSENT. Appended rather
  // than assigned, so re-entering a thread can't discard something half-typed, and consumed once.
  if (state.pendingDraft && state.pendingDraft.id === dm.id) {
    const staged = state.pendingDraft.text;
    state.pendingDraft = null;
    input.value = input.value ? `${input.value}\n${staged}` : staged;
    setTimeout(() => { autoGrow(); input.focus(); }, 0);
  }
  const editBar = el("div", { class: "edit-bar", style: "display:none" });
  const beginEdit = (m) => {
    editingId = m.id;
    editingMedia = m.media || [];
    editingMusic = m.music || null;
    input.value = m.body; autoGrow(); input.focus();
    editBar.style.display = "";
    editBar.replaceChildren(
      el("span", { class: "muted small" }, "Editing message"),
      el("div", { class: "spacer" }),
      el("button", { class: "pill-btn glass", onclick: () => { editingId = null; input.value = ""; autoGrow(); editBar.style.display = "none"; } }, "Cancel"),
    );
  };
  // A song attached to the NEXT send, shown as a removable chip — same shape as the feed composer.
  let pendingMusic = null;
  const musicRow = el("div", {});
  const drawDmMusic = () => {
    musicRow.replaceChildren(pendingMusic
      ? el("div", { class: "song-chip", style: "margin-top:0" },
          el("span", { class: "note" }, "🎵"),
          el("div", { style: "flex:1;min-width:0" }, el("strong", {}, pendingMusic.title), " — ", pendingMusic.artist),
          el("span", { class: "x", style: "position:static;cursor:pointer", onclick: () => { pendingMusic = null; drawDmMusic(); } }, "×"))
      : null);
  };

  const sendText = async () => {
    const t = input.value.trim();
    // A song on its own is a valid message (the engine's guard allows it), so don't require text.
    if (!t && !pendingMusic) return;
    if (editingId) {   // saving an edit — carry the message's existing attachments through
      if (!t) return;
      await invoke("edit_post", { circleId: dm.id, target: editingId, body: t, media: editingMedia, music: editingMusic });
      editingId = null; editingMedia = []; editingMusic = null; editBar.style.display = "none";
    } else {
      await invoke("send_dm", { circleId: dm.id, body: t ? (secretOn ? SECRET_MARKER + t : t) : "", media: [], music: pendingMusic });
      pendingMusic = null; drawDmMusic();
    }
    input.value = ""; autoGrow();
  };
  input.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); sendText(); } });

  const setSecret = (on) => {
    secretOn = on;
    input.classList.toggle("tint-pink", on);
    input.placeholder = on ? "Secret message…" : "Message…";
  };
  const plus = el("button", { class: "composer-plus", title: "Attach", "aria-label": "Attach" }, icon("plus"));
  plus.addEventListener("click", () => popMenu(plus, [
    { label: "Photo or video", icon: "photo", on: async () => { const r = await cameraDialog(dm.id); if (r) await invoke("send_dm", { circleId: dm.id, body: "", media: [r.ref], music: null }); } },
    { label: "Voice message", icon: "mic", on: async () => { const r = await recordVoice(dm.id); if (r) await invoke("send_dm", { circleId: dm.id, body: "", media: [r], music: null }); } },
    // Attaches to the NEXT send rather than firing immediately — a song usually accompanies a
    // message, and the composer shows it as a removable chip until you hit send (same as the feed).
    { label: "Add a song", icon: "music.note", on: () => musicDialog((m) => { pendingMusic = m; drawDmMusic(); }) },
    { label: secretOn ? "Secret: on" : "Send secretly", icon: "lock.shield.fill", on: () => setSecret(!secretOn) },
  ]));

  const partner = dm.id.replace("dm:", "").split("-").find((h) => h !== state.node) || "";
  const presence = el("div", { class: "dm-presence" }, relayReachable ? "Connected" : "Offline");

  // `.col-wrap` is what every other view's root render puts here (the feed, the DM list, You), and
  // it is the ONE thing this one was missing: `.view` has NO horizontal padding of its own, so the
  // thread ran flush to both window edges — bubbles and composer touching the glass. col-wrap is the
  // 16px inset macOS gives the thread (`Messages.swift` ▸ `.padding(16)`) plus the same centred
  // column cap as the feed. The `#view-messages.thread-mode > .col-wrap` height rule below has been
  // waiting for it.
  root.replaceChildren(el("div", { class: "col-wrap" }, el("div", { class: "thread-wrap" },
    // macOS pins the DM header (name + presence) to the LEADING edge — the window's centred tabs
    // own the middle and a centred header shoved them around as the name's width changed.
    el("div", { class: "dm-head" },
      el("button", { class: "icon-btn glass", title: "Back", "aria-label": "Back", onclick: () => { state.activeDm = null; renderMessages(); } },
        icon("chevron.right", "flip")),
      el("div", { style: "min-width:0" },
        el("div", { class: "dm-name" }, dm.name),
        presence),
      el("div", { class: "spacer" }),
      partner ? el("button", { class: "icon-btn glass", title: "Audio call", "aria-label": "Audio call", onclick: () => callStart([partner], dm.name, false) }, icon("phone.fill")) : null,
      partner ? el("button", { class: "icon-btn glass", title: "Video call", "aria-label": "Video call", onclick: () => callStart([partner], dm.name, true) }, icon("video.fill")) : null,
    ),
    chat,
    // Unlike the feed's composer, the DM composer DOES carry a glass band (macOS:
    // `.havenGlass(in: Rectangle())`) — it's the floor of the thread, not a pill over a gradient.
    el("div", { class: "dm-composer glass" }, editBar, musicRow,
      el("div", { class: "composer-row" }, plus, input,
        el("button", { class: "composer-send", title: "Send", "aria-label": "Send", onclick: sendText }, icon("paperplane.fill")))),
  )));
  hydrateMedia(root, dm.id);
  chat.scrollTop = chat.scrollHeight;
  // The user is looking at this thread: advance its read watermark. renderThread re-runs on every
  // haven:changed, so messages arriving WHILE the thread is open are marked read too — backing out
  // never leaves a stale badge for a conversation the user just watched. (The command deliberately
  // doesn't emit haven:changed, so this can't render-loop.)
  invoke("mark_dm_read", { circleId: dm.id }).then(refreshBadges).catch(() => {});
}

// ---- Connect ---------------------------------------------------------------------------
/** CONNECT — a SHEET, not a tab. macOS presents `ConnectView` with `.sheet` from the circle's
 *  people button and from the pending-requests banner; both of those reach here. */
async function connectSheet() {
  const pending = await invoke("pending").catch(() => []);
  const contacts = await invoke("contacts").catch(() => []);

  const qrBox = el("div", { class: "qr-box" });
  try { qrBox.innerHTML = makeQrSvg(state.inviteUri); } catch (_) { qrBox.textContent = "QR unavailable"; }

  const mine = el("div", { class: "card col" },
    el("h3", {}, "Your invite"),
    el("div", { class: "muted small" }, "Have a friend scan this, or send them the link. Verify the safety code matches on both devices."),
    // `wrap` on both rows, not just one: the QR is a fixed 200-odd px and the two Copy buttons are
    // nowrap pills, so on a narrow sheet the text column has to be allowed to drop BELOW the QR and
    // the buttons below each other. Without it they only had one way out — through the card's edge.
    el("div", { class: "row wrap", style: "align-items:flex-start" }, qrBox,
      el("div", { class: "col", style: "flex:1 1 260px" },
        el("div", { class: "mono" }, state.inviteUri),
        el("div", { class: "row wrap" },
          el("button", { class: "btn small", onclick: () => { navigator.clipboard.writeText(state.inviteUri); toast("Invite copied"); } }, "Copy haven:// link"),
          el("button", { class: "btn small", onclick: () => { navigator.clipboard.writeText(state.inviteLink); toast("Web link copied"); } }, "Copy web link"),
        ),
      ),
    ),
  );

  const linkInput = el("input", { placeholder: "Paste a haven:// or https:// invite or post link…" });
  const add = el("div", { class: "card col" },
    el("h3", {}, "Connect a friend"),
    // Pasted links go through routeDeepLink, so a post link opens the post instead of being fed to the
    // invite handshake — an invite's payload has the same `<a>.<b>` fragment shape, so only the `p/`
    // check tells them apart.
    el("div", { class: "row" }, linkInput, el("button", { class: "btn primary", onclick: async () => {
      const kind = await routeDeepLink(linkInput.value);
      if (kind === "invite") { toast("Invite sent — they'll appear once they accept"); linkInput.value = ""; }
      else if (kind === "post") linkInput.value = "";
      else toast("That doesn't look like a Haven link");
    } }, "Connect")),
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
      el("button", { class: "btn small", onclick: async () => { const id = await invoke("start_dm", { contactIdHex: c.id_hex, contactName: c.name }); state.activeDm = { id, name: c.name }; closeModal(); switchView("messages"); } }, "Message"),
      (() => { const k = el("button", { class: "kebab" }, icon("ellipsis")); k.addEventListener("click", () => contactMenu(k, c)); return k; })(),
    ));
  }

  sheet("Connect", el("div", { class: "col", style: "gap:16px" }, mine, add, pend, cl));
}

function contactMenu(anchor, c) {
  popMenu(anchor, [
    { label: "Block " + c.name, icon: "hand.raised.fill", danger: true,
      on: async () => { await invoke("block", { idHex: c.id_hex }); toast("Blocked"); connectSheet(); } },
  ], { align: "right" });
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
  // The scanner is a live viewfinder — same rule as the camera: the feed goes quiet behind it.
  const releaseCapture = beginCapture(() => stop());
  const close = modal(el("div", {}, el("h2", {}, "Scan QR"), video, status, canvas,
    el("div", { class: "row", style: "margin-top:10px;justify-content:flex-end" }, el("button", { class: "btn", onclick: () => stop() }, "Close"))));
  const stop = () => { if (raf) cancelAnimationFrame(raf); if (stream) stream.getTracks().forEach((t) => t.stop()); releaseCapture(); close(); };
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
// RELAY IS NOT A TAB. macOS keeps it exactly one place — Settings ▸ Relays (Settings.swift's
// `NavigationLink { RelaysView() }`) — with the per-circle overrides under the circle's own
// settings. Desktop matches: the gear on the You tab → Relays, plus the "Manage relays →" link
// inside the circle sheet, plus the relay nudge's walkthrough. Nothing else.
const renderRelay = () => relaySheet();   // legacy call sites (the walkthrough) keep working

/**
 * How much of your circles' media this machine is willing to hold, and for how long. Volunteering a
 * PC shouldn't mean volunteering the whole disk, and until `attach_with_limits` the in-app relay had
 * no way to say otherwise — it always ran unlimited media.
 *
 * "No limit" is 0 for that dimension; with both set the sweep applies whichever frees space first.
 * The mailbox TTL is deliberately absent: undelivered messages are a delivery guarantee, not cache.
 */
async function relayLimitsSection(hosting) {
  const cur = await invoke("get_relay_media_limits").catch(() => ({ max_age_days: 30, max_bytes: 32 * 1024 ** 3 }));
  const GB = 1024 ** 3;
  const ageSel = el("select", {},
    ...[[7, "7 days"], [30, "30 days"], [90, "90 days"], [365, "1 year"], [0, "No limit"]]
      .map(([v, label]) => el("option", Object.assign({ value: String(v) }, v === cur.max_age_days ? { selected: "" } : {}), label)));
  const sizeSel = el("select", {},
    ...[[8 * GB, "8 GB"], [32 * GB, "32 GB"], [128 * GB, "128 GB"], [512 * GB, "512 GB"], [0, "No limit"]]
      .map(([v, label]) => el("option", Object.assign({ value: String(v) }, v === cur.max_bytes ? { selected: "" } : {}), label)));
  const apply = async () => {
    await invoke("set_relay_media_limits", {
      maxAgeDays: Number(ageSel.value), maxBytes: Number(sizeSel.value),
    }).catch((e) => toast("" + e));
    toast(hosting ? "Saved — applies next time the relay starts" : "Saved");
  };
  ageSel.onchange = apply;
  sizeSel.onchange = apply;
  return el("div", { class: "col", style: "margin-top:10px" },
    el("label", { class: "muted small" }, "Keep media for"), ageSel,
    el("label", { class: "muted small", style: "margin-top:6px" }, "Media storage limit"), sizeSel,
    el("div", { class: "muted small" }, hosting
      ? "Changes apply next time the relay starts — Stop hosting and start again to apply them now. Whichever limit is reached first wins: old media is swept on age, and the oldest goes first if the size cap is hit. Your circles' undelivered messages are never swept — only media."
      : "Whichever limit is reached first wins: old media is swept on age, and the oldest goes first if the size cap is hit. Your circles' undelivered messages are never swept — only media."),
  );
}
async function relaySheet() {
  const s = await invoke("relay_status");
  const pub = await invoke("relay_public_settings").catch(() => ({
    public_url: "", tunnel_token: "", auto_tunnel: true, front_door: "auto", derp_url: "",
  }));
  const adoptInput = el("input", { placeholder: "Paste node id (64 hex) or haven-relay interface JSON…" });
  // Three first-class modes — Manual stays correct if free/token Cloudflare paths go away.
  let frontDoor = pub.front_door || "auto";
  const urlInput = el("input", {
    value: pub.public_url || "",
    placeholder: "https://relay.example.com",
  });
  const derpInput = el("input", {
    value: pub.derp_url || "",
    placeholder: "optional — https://derp.example.com (sibling host for :3340)",
  });
  const tokenInput = el("input", {
    type: "password",
    value: pub.tunnel_token || "",
    placeholder: "Cloudflare tunnel install token",
    autocomplete: "off",
  });
  const modeBox = el("div", { class: "col", style: "gap:4px" });
  const modes = [
    ["auto", "Free trycloudflare", "A free temporary Cloudflare address — zero setup, but it changes every restart."],
    ["bundled", "Custom domain (Haven runs cloudflared)", "Your own domain: paste it plus a Cloudflare tunnel token, and Haven runs the tunnel for you."],
    ["manual", "Manual / external tunnel", "You run the tunnel or reverse proxy; Haven just announces its HTTPS address."],
  ];
  const derpLabel = el("label", { class: "muted small", style: "margin-top:6px" }, "DERP fabric URL (optional, distinct from media)");
  const syncModeUi = () => {
    tokenInput.disabled = frontDoor === "manual" || frontDoor === "auto";
    tokenInput.style.opacity = tokenInput.disabled ? "0.5" : "1";
    urlInput.placeholder = frontDoor === "auto"
      ? "optional stable media URL (switches to manual when set alone)"
      : "https://relay.example.com";
    // Dedicated DERP URL for named/manual dual-role; free auto prefers path proxy (one origin).
    const hideDerp = frontDoor === "auto";
    derpInput.style.display = hideDerp ? "none" : "";
    derpLabel.style.display = hideDerp ? "none" : "";
  };
  for (const [value, label, hint] of modes) {
    const radio = el("input", { type: "radio", name: "front-door", style: "width:auto" });
    radio.checked = frontDoor === value;
    radio.onchange = () => {
      if (!radio.checked) return;
      frontDoor = value;
      syncModeUi();
    };
    modeBox.append(
      el("label", { class: "col", style: "gap:2px;cursor:pointer;padding:4px 0" },
        el("div", { class: "row", style: "gap:8px;align-items:center" }, radio, el("span", { style: "font-weight:600" }, label)),
        el("div", { class: "muted small", style: "margin-left:24px" }, hint),
      ),
    );
  }
  syncModeUi();
  const savePublic = async () => {
    try {
      await invoke("set_relay_public_settings", {
        publicUrl: urlInput.value.trim(),
        tunnelToken: tokenInput.value.trim(),
        autoTunnel: frontDoor === "auto",
        frontDoor,
        derpUrl: derpInput.value.trim(),
      });
      toast(s.hosting
        ? "Saved — restart hosting to apply front-door settings"
        : "Saved");
    } catch (e) { toast("" + e); }
  };
  const publicCard = el("div", { class: "card col" },
    el("h3", {}, "Public HTTPS front door"),
    el("div", { class: "muted small" },
      "Friends off your LAN need HTTPS to the media port (8674) and (for circle-hosted NAT fabric) DERP on 3340. Blobs stay E2E-sealed — the front door only moves ciphertext."),
    modeBox,
    el("label", { class: "muted small", style: "margin-top:8px" }, "Media public URL"),
    urlInput,
    derpLabel,
    derpInput,
    el("label", { class: "muted small", style: "margin-top:6px" }, "Tunnel token (bundled mode only)"),
    tokenInput,
    el("button", { class: "btn small primary", style: "align-self:flex-start;margin-top:8px", onclick: savePublic }, "Save front door"),
    el("div", { class: "muted small" },
      "Whichever mode you pick, the front door only ever carries sealed data. ",
      el("a", { href: "https://wemiller.com/apps/haven/docs/#front-door", target: "_blank", style: "color:var(--pink);text-decoration:underline" }, "Learn more")),
  );
  const liveTunnelCard = (() => {
    if (!s.hosting) return null;
    const media = s.live_media_url || "";
    const derp = s.live_derp_url || "";
    if (!media && !derp) return null;
    if (s.path_routed && media) {
      return el("div", { class: "card col" },
        el("h3", {}, "Live Cloudflare tunnel"),
        el("div", { class: "ok-text" }, "One cloudflared → path proxy :8675 (media + DERP)"),
        el("div", { class: "mono", style: "word-break:break-all" }, media),
        el("button", { class: "btn small", style: "align-self:flex-start", onclick: () => { navigator.clipboard.writeText(media); toast("URL copied"); } }, "Copy"),
      );
    }
    if (media && derp && media !== derp) {
      return el("div", { class: "card col" },
        el("h3", {}, "Live Cloudflare tunnels (dual)"),
        el("div", { class: "muted small" }, "Path proxy off — two free trycloudflare origins (both visible):"),
        el("div", { class: "muted small" }, "Media"),
        el("div", { class: "mono", style: "word-break:break-all" }, media),
        el("div", { class: "muted small", style: "margin-top:6px" }, "DERP fabric"),
        el("div", { class: "mono", style: "word-break:break-all" }, derp),
      );
    }
    if (media) {
      return el("div", { class: "card col" },
        el("h3", {}, "Live Cloudflare tunnel"),
        el("div", { class: "mono", style: "word-break:break-all" }, media),
        derp && derp !== media
          ? el("div", { class: "col" },
              el("div", { class: "muted small" }, "DERP"),
              el("div", { class: "mono", style: "word-break:break-all" }, derp))
          : null,
      );
    }
    return null;
  })();
  const hostCard = el("div", { class: "card col" },
    el("h3", {}, "Host the relay on this PC"),
    el("div", { class: "muted small" }, "Your circle's relay runs here so posts and media reach friends even when you're both offline. The relay never sees your content — everything is end-to-end sealed."),
    s.hosting
      ? el("div", { class: "col" },
          el("div", { class: "ok-text" }, "● Relaying"),
          s.relay_link ? el("div", { class: "row wrap" }, el("div", { class: "mono", style: "flex:1 1 200px" }, s.relay_link), el("button", { class: "btn small", onclick: () => { navigator.clipboard.writeText(s.relay_link); toast("Relay id copied"); } }, "Copy")) : null,
          el("div", { class: "muted small" }, "Share this id with your circle so they adopt the same relay."),
          el("button", { class: "btn danger small", onclick: async () => { await invoke("stop_hosting"); renderRelay(); } }, "Stop hosting"),
        )
      : el("button", { class: "btn primary", onclick: async () => { try { await invoke("start_hosting"); toast("Relay started"); } catch (e) { toast("" + e); } renderRelay(); } }, "Start hosting"),
    await relayLimitsSection(s.hosting),
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
  // Deleted relays — the undo for "Delete", which drops the entry, every circle association and the
  // default pick. A relay is a 64-character node id, not something anyone re-adds from memory.
  // Hidden entirely when there is nothing to recover. Apple/Android parity.
  const erased = await invoke("erased_relays").catch(() => []);
  if (erased.length) {
    const det = el("details", { class: "list-item col", style: "align-items:stretch;gap:6px" });
    det.append(el("summary", {}, `Deleted relays · ${erased.length}`));
    for (const rec of erased) {
      const e = rec.entry || {};
      det.append(el("div", { class: "row", style: "gap:8px;align-items:center" },
        el("div", { style: "flex:1;min-width:0" },
          el("div", { style: "overflow:hidden;text-overflow:ellipsis" }, e.name || (e.hex || "").slice(0, 12) + "…"),
          el("div", { class: "mono small muted" },
            (e.hex || "").slice(0, 20) + "…" + (rec.circles && rec.circles.length ? ` · ${rec.circles.length} circle${rec.circles.length === 1 ? "" : "s"}` : "")),
        ),
        el("button", { class: "btn small primary", onclick: async () => { await invoke("restore_erased_relay", { nodeHex: e.hex }); toast("Relay restored"); renderRelay(); } }, "Restore"),
        el("button", { class: "btn small", onclick: async () => { await invoke("drop_erased_relay", { nodeHex: e.hex }); renderRelay(); } }, "Forget"),
      ));
    }
    det.append(el("div", { class: "muted small" }, "Restore puts a deleted relay back in the circles it served. Cleared after 30 days."));
    adoptCard.append(det);
  }
  adoptCard.append(el("div", { class: "row" }, adoptInput, el("button", { class: "btn primary", onclick: async () => {
    const v = adoptInput.value.trim();
    const okBare = v.length === 64 && /^[0-9a-fA-F]+$/.test(v);
    const okJson = v.startsWith("{") && v.includes("node");
    if (okBare || okJson) {
      await invoke("adopt_relay", { nodeHex: v });
      toast("Relay added");
      adoptInput.value = "";
      renderRelay();
    } else {
      toast("Paste a 64-hex node id or the JSON block from haven-relay");
    }
  } }, "Add Haven relay")));
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
    el("div", { class: "muted small html", html: "Prefer no window? Run <span class='mono'>haven-desktop --headless</span> for relay-only." }),
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
  sheet("Relays", el("div", { class: "col", style: "gap:16px" }, hostCard, liveTunnelCard, publicCard, alwaysOn, adoptCard, s3card, headless));
}

// ---- You / Settings --------------------------------------------------------------------
/** The You tab — macOS `YouView`, which is a PROFILE, not a pile of settings cards: a centred
 *  avatar with a gradient ring and a pencil affordance, your name, bio and link, then your own
 *  stories and your own posts. Everything administrative moved behind the toolbar gear
 *  (`settingsSheet`), which is exactly where macOS keeps it. */
async function renderYou() {
  const root = $("#view-you");
  const p = await invoke("get_profile").catch(() => ({}));
  state.profile = p;

  const avatar = el("button", { class: "profile-avatar", title: "Edit profile", onclick: () => editProfileSheet(p) },
    el("div", { class: "disc" }, p.avatar ? el("img", { src: p.avatar }) : (p.emoji || initials(p.name))),
    el("span", { class: "pencil" }, icon("pencil.circle.fill")),
  );
  const head = el("div", { class: "profile-head" },
    avatar,
    el("div", { class: "profile-name" }, p.name || "You"),
    p.bio ? el("div", { class: "profile-bio" }, p.bio) : null,
    p.link ? el("button", { class: "profile-link", onclick: () => openExternal(p.link) }, icon("link"), p.link) : null,
    (!p.bio && !p.link) ? el("div", { class: "profile-bio" }, "This is just for the people you choose.") : null,
  );

  // Your own posts and stories, across every circle — macOS `feed.myPosts` / `feed.myStories`.
  const circles = await invoke("circles").catch(() => []);
  const mine = [];
  for (const c of circles) {
    for (const i of await invoke("feed", { circleId: c.id }).catch(() => [])) {
      if (i.is_me && !i.unsent) mine.push({ ...i, _circle: c.id });
    }
  }
  mine.sort((a, b) => Number(b.created_at) - Number(a.created_at));
  const myPosts = mine.filter((i) => !i.story);
  // My stories for MY PROFILE: the live ones, PLUS any I chose to keep whose event has since been
  // purged. Kept stories are revived HERE and here only — the circle's story tray reads the live
  // feed, so a kept story still leaves everyone else's stories when its 24 hours are up. That is the
  // whole point of keeping one rather than re-posting it.
  //
  // While a story is still live the LIVE item wins, comments and reactions and all; the kept
  // snapshot is strictly the after.
  const liveStories = mine.filter((i) => i.story);
  const liveIds = new Set(liveStories.map((i) => i.id));
  const kept = await invoke("kept_stories").catch(() => []);
  const revived = kept.filter((k) => !liveIds.has(k.id) && (k.media || []).length).map((k) => ({
    id: k.id,
    author_name: "You",
    is_me: true,
    created_at: k.createdAt,
    body: k.body || "",
    media: k.media || [],
    music: k.musicCatalogId
      ? { catalog_id: k.musicCatalogId, title: k.musicTitle || "", artist: k.musicArtist || "",
          artwork_url: k.musicArtworkUrl || "", duration_ms: k.musicDurationMs || 0 }
      : null,
    edited: false, unsent: false, story: true, mute_video: false,
    comments: [], reactions: [], poll: null,
    // A revived snapshot has no event left, so its media resolves against the default circle keys.
    _circle: "default",
  }));
  const myStories = liveStories.concat(revived)
    .sort((a, b) => Number(b.created_at) - Number(a.created_at));

  const body = el("div", { class: "feed-list" }, head);
  if (myStories.length) {
    // A GALLERY of your own stories (not an identity ring) → each tile shows its OWN content
    // thumbnail (matching a profile page), and opens the viewer at that story. macOS ContentView ▸
    // YouView.
    const gallery = myStories.map((s) => ({ ...s, _circle: s._circle }));
    const tray = el("div", { class: "story-tray" });
    gallery.forEach((s, idx) => {
      const inner = el("div", {});
      const cover = displayMediaRefs(s.media || []).find((r) => !r.startsWith("geo:") && !isAudioRef(r));
      if (cover) inner.append(el("img", { "data-ref": cover }));
      else inner.append(icon("photo", "story-ph"));
      tray.append(el("button", { class: "story-ring cover", onclick: () => viewStories(gallery, idx) }, el("div", { class: "ring" }, inner)));
    });
    body.append(el("div", { class: "card" }, el("div", { class: "section-label" }, "Your stories"), tray));
  }
  if (!myPosts.length) {
    body.append(el("div", { class: "card" }, el("div", { class: "empty", style: "padding:28px 10px" },
      el("div", { class: "h" }, "Your posts show up here"),
      el("div", {}, "Everything you share lives here — and a copy stays on your device."))));
  } else {
    for (const it of myPosts) body.append(postCard(it, it._circle));
  }

  root.replaceChildren(el("div", { class: "col-wrap" }, body));
  for (const c of circles) hydrateMedia(root, c.id);   // refs resolve against their own circle's keys
}

/** The emoji palette, in macOS's order — `ProfileStore.avatarChoices` (Profile.swift:120). */
const AVATAR_EMOJI = ["🌿", "🌸", "🔥", "⭐️", "🦊", "🐢", "🌊", "🍯", "🎈", "🪴", "🦋", "🌙"];

/** Downscale a picked image to an avatar and return it as a `data:` URL.
 *
 *  The 192px cap and JPEG q0.7 are macOS's numbers (`ProfileStore.avatarBase64`), not invented ones —
 *  desktop stores the avatar LOCALLY today (see `editProfileSheet`), but producing the same pixels
 *  means the day the profile card carries a photo, this side already speaks it. */
function avatarDataUrl(file) {
  return new Promise((resolve, reject) => {
    const fr = new FileReader();
    fr.onerror = () => reject(new Error("read failed"));
    fr.onload = () => {
      const img = new Image();
      img.onerror = () => reject(new Error("not an image"));
      img.onload = () => {
        const s = Math.min(1, 192 / Math.max(img.width, img.height));
        const c = el("canvas");
        c.width = Math.max(1, Math.round(img.width * s));
        c.height = Math.max(1, Math.round(img.height * s));
        c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
        resolve(c.toDataURL("image/jpeg", 0.7));
      };
      img.src = fr.result;
    };
    fr.readAsDataURL(file);
  });
}

/** Edit profile — the port of macOS `EditProfileSheet` (Profile.swift:219-327), opened by the You
 *  tab's pencil. Same order and same grouping: avatar, photo buttons, name, bio + link, the caption
 *  that explains who sees them, then the emoji grid; Done sits in the sheet's FOOTER
 *  (`HavenMacSheet`'s footer + `BrandButtonStyle`).
 *
 *  Two deliberate differences from what was here before, both from reading the Mac:
 *   • the raw `id: <64 hex>` line is GONE. macOS never shows the node id on this sheet — it belongs
 *     to the identity switcher, and only as a 16-char prefix.
 *   • the avatar is real. Photo/emoji write through immediately (macOS does the same: only the text
 *     fields defer to Done), which is why the avatar buttons re-render the sheet in place.
 *
 *  NOTE: the avatar is stored in local prefs and is NOT broadcast — `set_profile` re-greets contacts
 *  with the name card, and neither the desktop `Contact` nor the profile card carries an avatar. So
 *  your circle still sees your initials. That gap is in the backend/wire, not here. */
function editProfileSheet(p) {
  const name = el("input", { class: "pill-field", value: p.name || "", placeholder: "Your name" });
  const bio = el("textarea", { class: "field-soft", placeholder: "Add a short bio", rows: 2 }); bio.value = p.bio || "";
  const link = el("input", { class: "field-capsule", value: p.link || "", placeholder: "Add a link (e.g. yoursite.com)" });
  let avatar = p.avatar || "";
  let emoji = p.emoji || "🌿";

  const save = (extra) => invoke("set_profile", {
    name: name.value.trim(), bio: bio.value.trim(), link: link.value.trim(), emoji, avatar, ...extra,
  });
  // Re-open with the current draft so a photo/emoji change repaints without discarding typed text.
  const redraw = () => editProfileSheet({ ...p, name: name.value, bio: bio.value, link: link.value, emoji, avatar });

  const picker = el("input", { type: "file", accept: "image/*", style: "display:none", onchange: async (e) => {
    const f = e.target.files[0];
    if (!f) return;
    try { avatar = await avatarDataUrl(f); await save(); redraw(); renderYou(); }
    catch (_) { toast("That file isn't an image Haven can read"); }
  } });

  const photoRow = el("div", { class: "row wrap", style: "justify-content:center" },
    el("button", { class: "btn small tint-pink", onclick: () => picker.click() }, avatar ? "Change photo" : "Add photo"),
    avatar ? el("button", { class: "btn small danger", onclick: async () => { avatar = ""; await save(); redraw(); renderYou(); } }, "Remove") : null,
    picker,
  );

  const grid = el("div", { class: "emoji-grid" });
  for (const e of AVATAR_EMOJI) {
    grid.append(el("button", { class: "emoji-cell" + (emoji === e ? " on" : ""), onclick: async () => { emoji = e; await save(); redraw(); renderYou(); } }, e));
  }

  sheet("Edit profile", el("div", { class: "edit-profile" },
    el("div", { class: "ep-avatar" }, avatar ? el("img", { src: avatar }) : el("span", {}, emoji)),
    photoRow,
    name,
    el("div", { class: "col", style: "gap:10px" }, bio, link),
    el("div", { class: "ep-caption" }, "Your bio and link show on your profile for the people in your circle."),
    el("div", { class: "ep-label" }, avatar ? "Emoji (used if you remove your photo)" : "Pick an emoji"),
    grid,
  ), el("button", { class: "btn primary wide", onclick: async () => {
    await save();
    closeModal(); toast("Profile saved & shared"); renderYou();
  } }, "Done"));
}

/** SETTINGS — the gear in the You tab's toolbar. Grouped rows in the macOS order
 *  (Settings.swift): privacy note, Relays, Blocked people, Identities, Devices, Advanced. This is
 *  the ONLY home for Relay now. */
async function settingsSheet() {
  const row = (label, iconName, on, opts = {}) => el("button", { class: "set-row", onclick: on },
    el("span", { class: "ri" }, icon(iconName)),
    el("span", { style: "flex:1" }, label),
    opts.value ? el("span", { class: "muted small" }, opts.value) : null,
    el("span", { class: "chev" }, icon("chevron.right")),
  );
  const group = (...kids) => el("div", { class: "set-group" }, ...kids.filter(Boolean));
  const foot = (t) => el("div", { class: "set-foot" }, t);

  const themeNow = document.documentElement.dataset.theme
    || (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");

  sheet("Settings", el("div", { class: "col", style: "gap:6px" },
    el("div", { class: "set-group" },
      el("div", { class: "set-row" },
        el("span", { class: "ri", style: "color:#34d399" }, icon("lock.shield.fill")),
        el("span", { style: "flex:1" },
          el("div", { style: "font-weight:600" }, "Your circle is private"),
          el("div", { class: "muted small", style: "margin-top:2px" }, "Everything you share is locked so only your people can see it. No ads, no tracking — ever.")))),

    // RELAY LIVES HERE — nowhere else in the chrome.
    group(row("Relays", "antenna", () => relaySheet())),
    foot("Manage where your circles' sealed posts & media live so they reach people who were offline. Add unlimited relays (a Haven node or your own S3 bucket), pick a default for every circle, and activate or deactivate each. Each circle can override the default in its own settings."),

    group(row("Blocked people", "hand.raised.fill", () => blockedSheet())),
    foot("People you've blocked can't see your posts or reach you. Unblock anyone here."),

    group(row("Identities", "icloud", () => identitiesSheet())),
    foot("Keep more than one identity on this PC and switch between them. Each has its own profile, circles and contacts."),

    group(row("Devices", "laptop", () => devicesSheet())),
    foot("Link your other devices — each gets its own revocable key, never your master key."),

    group(row("Scheduled messages", "clock", () => scheduledSheet())),
    foot("Posts and DMs waiting to send. Compose one with the + menu's “Send later…”."),

    group(row("Privacy & media", "lock.shield.fill", () => privacyMediaSheet())),
    foot("Notification lock-screen previews, super data saver, and whether to also send camera originals."),

    // The Mac follows the system appearance and offers no toggle; desktop keeps one because
    // Tauri's webview doesn't always inherit the OS theme on Linux/Windows.
    group(row("Appearance", "moon", () => {
      const next = themeNow === "light" ? "dark" : "light";
      document.documentElement.dataset.theme = next;
      localStorage.setItem("haven-theme", next);
      settingsSheet();
    }, { value: themeNow === "light" ? "Light" : "Dark" })),

    group(row("Advanced", "wrench", () => advancedSheet())),
    foot("Technical details, your identity, and starting over."),
  ));
}

/** Privacy + media prefs (Apple Settings / Android SettingsScreen parity). Device-local. */
async function privacyMediaSheet() {
  const prefs = await invoke("privacy_prefs").catch(() => ({
    notification_detail: "full", super_data_saver: false, send_original: false,
  }));
  state.superDataSaver = !!prefs.super_data_saver;

  const toggle = (label, key, on) => {
    const chk = el("input", { type: "checkbox", style: "width:auto" });
    chk.checked = !!on;
    chk.onchange = async () => {
      const body = { notificationDetail: null, superDataSaver: null, sendOriginal: null };
      if (key === "super_data_saver") body.superDataSaver = chk.checked;
      if (key === "send_original") body.sendOriginal = chk.checked;
      try {
        await invoke("set_privacy_prefs", body);
        if (key === "super_data_saver") state.superDataSaver = chk.checked;
        toast("Saved");
      } catch (e) { toast("" + e); chk.checked = !chk.checked; }
    };
    return el("label", { class: "set-row", style: "cursor:pointer" },
      el("span", { style: "flex:1" }, label), chk);
  };

  const detailOpts = [
    ["full", "Full previews"],
    ["private", "Name and type only"],
    ["minimal", "Minimal"],
  ];
  const detailBox = el("div", { class: "col", style: "gap:4px" });
  for (const [value, label] of detailOpts) {
    const radio = el("input", { type: "radio", name: "notif-detail", style: "width:auto" });
    radio.checked = (prefs.notification_detail || "full") === value;
    radio.onchange = async () => {
      if (!radio.checked) return;
      try {
        await invoke("set_privacy_prefs", {
          notificationDetail: value, superDataSaver: null, sendOriginal: null,
        });
        toast("Saved");
      } catch (e) { toast("" + e); }
    };
    detailBox.append(el("label", { class: "row", style: "gap:8px;align-items:center;cursor:pointer" },
      radio, el("span", {}, label)));
  }

  sheet("Privacy & media", el("div", { class: "col", style: "gap:10px" },
    el("div", { class: "set-group" },
      toggle("Also send original", "send_original", prefs.send_original),
      toggle("Super data saver", "super_data_saver", prefs.super_data_saver)),
    el("div", { class: "set-foot" },
      "Super data saver skips autoplay and prefers poster stills. “Also send original” keeps the camera file beside the optimized video."),
    el("div", { class: "muted small", style: "font-weight:600" }, "Notification previews"),
    el("div", { class: "muted small" }, "How much detail banners show on the lock screen (iOS/Android parity)."),
    el("div", { class: "set-group" }, detailBox),
  ));
}

async function blockedSheet() {
  const blocked = await invoke("blocked").catch(() => []);
  const list = el("div", { class: "col" });
  if (!blocked.length) list.append(el("div", { class: "muted small" }, "No one is blocked."));
  for (const b of blocked) {
    list.append(el("div", { class: "list-item" },
      el("div", { class: "mono", style: "flex:1" }, b.slice(0, 24) + "…"),
      el("button", { class: "btn small", onclick: async () => { await invoke("unblock", { idHex: b }); blockedSheet(); } }, "Unblock")));
  }
  sheet("Blocked people", list);
}

async function scheduledSheet() {
  const sched = await invoke("scheduled").catch(() => []);
  const list = el("div", { class: "col" });
  if (!sched.length) list.append(el("div", { class: "muted small" }, "Nothing scheduled. Use the composer's + menu ▸ “Send later…”."));
  for (const s of sched) {
    list.append(el("div", { class: "list-item" },
      el("div", { style: "flex:1;min-width:0" },
        el("div", {}, (s.kind === "dm" ? "DM · " : "Post · ") + (s.body || (s.media_count ? `${s.media_count} attachment(s)` : "—"))),
        el("div", { class: "muted small" }, "sends " + new Date(s.send_at_ms).toLocaleString())),
      el("button", { class: "btn small danger", onclick: async () => { await invoke("cancel_scheduled", { id: s.id }); scheduledSheet(); } }, "Cancel")));
  }
  sheet("Scheduled", list);
}

// ---- #1 Manage media: size-sorted cleanup screen ----------------------------------------
// Every cached photo/video/audio blob, largest first, each mapped to the post/DM it belongs to (or
// flagged Unused). Multi-select to free space; per-row "Keep on this device" pins a blob so no cleanup
// ever removes it. Deleting frees only the LOCAL bytes — the post stays and re-renders as a
// downloadable placeholder. Port of iOS MediaCleanupView.
async function manageMediaSheet() {
  const listWrap = el("div", { class: "col", style: "gap:8px" });
  const headEl = el("div", { class: "muted small" }, "Measuring…");
  const footBar = el("div", { class: "row", style: "gap:8px;align-items:center" });
  const selection = new Set();
  let rows = [];

  const totalBytes = () => rows.reduce((a, r) => a + r.bytes, 0);
  const pinnedBytes = () => rows.filter((r) => r.is_pinned).reduce((a, r) => a + r.bytes, 0);
  const selectedBytes = () => rows.filter((r) => selection.has(r.reference)).reduce((a, r) => a + r.bytes, 0);

  const kindIcon = (k) => k === "video" ? "🎬" : k === "audio" ? "🎵" : "🖼";

  const renderFoot = () => {
    footBar.replaceChildren();
    if (!selection.size) return;
    const btn = el("button", { class: "btn primary", onclick: async () => {
      btn.disabled = true; btn.textContent = "Removing…";
      try {
        const freed = await invoke("media_delete_selected", { refs: [...selection] });
        toast(`Freed ${fmtBytes(freed)}`);
      } catch (e) { toast("Couldn't remove: " + e); }
      selection.clear();
      await reload();
    } }, `Remove ${selection.size} · frees ${fmtBytes(selectedBytes())}`);
    footBar.append(btn);
  };

  const rowEl = (r) => {
    const selected = selection.has(r.reference);
    // Selection control (pinned rows are ineligible — a pin glyph instead of a checkbox).
    const toggle = r.is_pinned
      ? el("span", { class: "media-row-pin", title: "Kept on this device" }, "📌")
      : el("input", { type: "checkbox", style: "width:auto" });
    if (!r.is_pinned) {
      toggle.checked = selected;
      toggle.onchange = () => { if (toggle.checked) selection.add(r.reference); else selection.delete(r.reference); renderFoot(); };
    }
    // Thumbnail: images decode inline (load_any_circle handles the key); video/audio show a glyph.
    const thumb = el("div", { class: "media-row-thumb" }, el("span", {}, kindIcon(r.kind)));
    if (r.kind === "image") {
      const img = el("img", { style: "width:100%;height:100%;object-fit:cover;border-radius:6px" });
      invoke("media_data_url", { circleId: "", reference: r.reference })
        .then((u) => { if (u) thumb.replaceChildren(img), (img.src = u); })
        .catch(() => {});
    }
    const sub = r.snippet ? r.snippet : (r.is_orphan ? "Not linked to any post" : "");
    const meta = el("div", { style: "flex:1;min-width:0" },
      el("div", { class: "name", style: "overflow:hidden;text-overflow:ellipsis;white-space:nowrap" }, r.circle_name),
      sub ? el("div", { class: "muted small", style: "overflow:hidden;text-overflow:ellipsis;white-space:nowrap" }, sub) : null,
      el("div", { class: "muted small mono" }, fmtBytes(r.bytes) + (r.is_pinned ? " · Kept" : "")));
    const keep = el("button", { class: "btn small ghost", onclick: async () => {
      try {
        if (r.is_pinned) await invoke("media_unpin", { refs: [r.reference] });
        else await invoke("media_pin", { refs: [r.reference] });
        await reload();
      } catch (e) { toast("" + e); }
    } }, r.is_pinned ? "Unkeep" : "Keep");
    return el("div", { class: "list-item", style: "gap:10px;align-items:center" }, toggle, thumb, meta, keep);
  };

  const reload = async () => {
    rows = await invoke("media_inventory").catch(() => []);
    for (const r of [...selection]) if (!rows.some((x) => x.reference === r)) selection.delete(r);
    listWrap.replaceChildren();
    if (!rows.length) {
      headEl.textContent = "No cached media.";
      listWrap.append(el("div", { class: "muted small", style: "padding:16px 0" }, "Nothing stored on this device yet."));
    } else {
      const kept = pinnedBytes() > 0 ? ` · ${fmtBytes(pinnedBytes())} kept` : "";
      headEl.textContent = `${rows.length} item${rows.length === 1 ? "" : "s"} · ${fmtBytes(totalBytes())}${kept}`;
      for (const r of rows) listWrap.append(rowEl(r));
    }
    renderFoot();
  };

  sheet("Manage media",
    el("div", { class: "col", style: "gap:10px" },
      headEl,
      el("div", { class: "muted small" }, "Sorted by size. Removing an item frees only the copy on this device — the post stays and can be re-downloaded. “Keep” exempts an item from every cleanup."),
      listWrap),
    footBar);
  await reload();
}

async function advancedSheet() {
  const security = el("div", { class: "card col" },
    el("h3", {}, "Security"),
    el("div", { class: "muted small" }, "Run the on-device hybrid post-quantum self-test (Ed25519 + ML-DSA, X25519 + ML-KEM-768)."),
    el("button", { class: "btn", onclick: async () => { const r = await invoke("self_test"); modal(el("div", {}, el("h2", {}, r.all_ok ? "✅ All checks passed" : "⚠️ Some checks failed"), el("div", { class: "col small" }, line("Identity", r.identity_ok), line("Hybrid KEM", r.hybrid_kem_ok), line("Signatures", r.signature_ok), line("Reach-me link", r.link_ok)), el("p", { class: "muted small" }, r.summary))); } }, "Run self-test"),
  );

  const storage = el("div", { class: "card col" },
    el("h3", {}, "Storage"),
    el("div", { class: "muted small" }, "Photos and videos from your circles, cached on this device. Manage them by size, set automatic limits, or clear media nothing references."),
    // #1 Manage media — the size-sorted cleanup screen, with the #2 pinned ("kept") count.
    (() => {
      const kept = el("span", { class: "muted small" }, "");
      invoke("media_pinned_count").then((n) => { if (n) kept.textContent = `${n} kept`; }).catch(() => {});
      return el("button", { class: "btn", style: "display:flex;justify-content:space-between;align-items:center", onclick: () => manageMediaSheet() },
        el("span", {}, "Manage media"), kept);
    })(),
    // #4 device-local age/size caps (default OFF). Changing either enforces immediately.
    (() => {
      const daysSel = el("select", { class: "pill-field" },
        el("option", { value: "0" }, "Never"),
        el("option", { value: "30" }, "30 days"),
        el("option", { value: "90" }, "90 days"),
        el("option", { value: "180" }, "6 months"),
        el("option", { value: "365" }, "1 year"));
      const gbSel = el("select", { class: "pill-field" },
        el("option", { value: "0" }, "No limit"),
        el("option", { value: "1" }, "1 GB"),
        el("option", { value: "2" }, "2 GB"),
        el("option", { value: "5" }, "5 GB"),
        el("option", { value: "10" }, "10 GB"),
        el("option", { value: "25" }, "25 GB"));
      invoke("get_media_limits").then((l) => {
        if (l) { daysSel.value = String(l.days || 0); gbSel.value = String(l.gb || 0); }
      }).catch(() => {});
      const save = async () => {
        try { await invoke("set_media_limits", { days: Number(daysSel.value), gb: Number(gbSel.value) }); toast("Saved"); }
        catch (e) { toast("" + e); }
      };
      daysSel.onchange = save; gbSel.onchange = save;
      return el("div", { class: "col", style: "gap:6px" },
        el("label", { class: "row", style: "gap:8px;align-items:center" }, el("span", { style: "flex:1" }, "Delete local media older than"), daysSel),
        el("label", { class: "row", style: "gap:8px;align-items:center" }, el("span", { style: "flex:1" }, "Keep local media under"), gbSel),
        el("div", { class: "muted small" }, "Automatically remove old/excess cached media (oldest first) to stay under your caps — posts stay and re-download on demand. Kept items are never removed."));
    })(),
    // Shrink what I've ALREADY shared, and re-share it, so the whole circle gets the smaller copy.
    // Sits beside "Clean up unused media" because the two are the only levers on media that is
    // already out there: this one makes it smaller for everybody, that one reclaims local bytes.
    Reoptimize.row(),
    // Clear only media nothing references anymore.
    (() => {
      const status = el("div", { class: "muted small" }, "");
      const btn = el("button", { class: "btn", onclick: async () => {
        btn.disabled = true; btn.textContent = "Cleaning up…";
        try {
          const r = await invoke("media_cleanup");
          status.textContent = !r || !r.files ? "Nothing to clean up."
            : `Freed ${fmtBytes(r.bytes)} across ${r.files} file${r.files === 1 ? "" : "s"}.`;
        } catch (e) { status.textContent = "Cleanup failed: " + e; }
        btn.disabled = false; btn.textContent = "Clean up unused media";
      } }, "Clean up unused media");
      return el("div", { class: "col", style: "gap:6px" }, btn, status);
    })(),
  );

  const danger = el("div", { class: "card col" },
    el("h3", {}, "Start over"),
    el("div", { class: "muted small" }, "Wipe this device's identity, contacts, circles and media. This cannot be undone."),
    el("button", { class: "btn danger", onclick: () => { modal(el("div", {}, el("h2", {}, "Start over?"), el("p", {}, "This permanently deletes your identity and all local data on this PC."), el("div", { class: "row", style: "justify-content:flex-end" }, el("button", { class: "btn ghost", onclick: () => closeModal() }, "Cancel"), el("button", { class: "btn danger", onclick: async () => { await invoke("reset"); location.reload(); } }, "Delete everything")))); } }, "Start over"),
  );

  const about = el("div", { class: "card col" },
    el("h3", {}, "This device"),
    el("div", { class: "muted small mono" }, "node id: " + state.node),
  );

  sheet("Advanced", el("div", { class: "col", style: "gap:16px" }, about, security, storage, danger));
}

async function identitiesSheet() {
  const ids = await invoke("identities").catch(() => []);
  const idCard = el("div", { class: "col" },
    el("div", { class: "muted small" }, "Keep more than one identity on this PC and switch between them. Each has its own profile, circles and contacts."));
  for (const id of ids) {
    idCard.append(el("div", { class: "list-item" },
      el("div", { class: "avatar", style: "width:30px;height:30px;font-size:12px" }, initials(id.label)),
      el("div", { style: "flex:1;min-width:0" }, el("div", { class: "name" }, id.label, id.active ? el("span", { class: "tag", style: "margin-left:8px" }, "active") : null), el("div", { class: "muted small mono" }, id.node_hex.slice(0, 18) + "…")),
      id.active ? null : el("button", { class: "btn small primary", onclick: async () => { if (confirm(`Switch to "${id.label}"? Haven will relaunch.`)) await invoke("switch_identity", { nodeHex: id.node_hex }); } }, "Switch"),
      el("button", { class: "btn small ghost", title: "Rename", onclick: () => { const i = el("input", { value: id.label }); modal(el("div", {}, el("h2", {}, "Rename identity"), i, el("div", { class: "row", style: "justify-content:flex-end;margin-top:10px" }, el("button", { class: "btn primary", onclick: async () => { await invoke("rename_identity", { nodeHex: id.node_hex, label: i.value.trim() || id.label }); identitiesSheet(); } }, "Save")))); } }, "Rename"),
      id.active ? null : el("button", { class: "btn small danger", title: "Remove", onclick: async () => { if (confirm(`Remove "${id.label}" from this PC? Its local data is deleted.`)) { await invoke("remove_identity", { nodeHex: id.node_hex }); identitiesSheet(); } } }, "Remove"),
    ));
  }
  idCard.append(el("div", { class: "row wrap", style: "margin-top:6px" },
    el("button", { class: "btn small", onclick: () => { const i = el("input", { placeholder: "Label (e.g. Work)" }); modal(el("div", {}, el("h2", {}, "New identity"), i, el("div", { class: "row", style: "justify-content:flex-end;margin-top:10px" }, el("button", { class: "btn primary", onclick: async () => { await invoke("add_identity", { label: i.value.trim() || "New identity" }); identitiesSheet(); toast("Identity created"); } }, "Create")))); } }, "+ New identity"),
    el("button", { class: "btn small ghost", onclick: () => { const lab = el("input", { placeholder: "Label" }); const seed = el("input", { placeholder: "Transfer code (haven-seed:…) or seed" }); modal(el("div", {}, el("h2", {}, "Link an existing identity"), lab, seed, el("div", { class: "row", style: "justify-content:flex-end;margin-top:10px" }, el("button", { class: "btn primary", onclick: async () => { try { await invoke("import_identity", { label: lab.value.trim() || "Imported", seedB64: seed.value.trim() }); identitiesSheet(); toast("Imported"); } catch (e) { toast("Import failed: " + e); } } }, "Import")))); } }, "Import"),
  ));
  sheet("Identities", idCard);
}

// ---- Authorized devices (revocable multi-device roster — parity with iOS/Android) ----
async function devicesSheet() {
  const roster = await invoke("device_roster").catch(() => ({ enabled: false, this_device_authorized: false, devices: [] }));
  const roleTitle = roster.enabled ? "This is your primary device"
    : roster.this_device_authorized ? "This is a linked device" : "This device isn’t linked yet";
  const roleSub = roster.enabled ? "It holds your master key and authorizes or revokes your other devices."
    : roster.this_device_authorized ? "It holds a copy of your master key and syncs with your primary device, which can revoke it."
    : "Make it your primary, or link it to the device that already is.";
  const devicesCard = el("div", { class: "col" },
    el("div", {}, el("strong", {}, roleTitle)),
    el("div", { class: "muted small" }, roleSub));
  if (!roster.devices.length) devicesCard.append(el("div", { class: "muted small" }, "No devices linked yet."));
  for (const d of roster.devices) {
    devicesCard.append(el("div", { class: "list-item" },
      el("div", {}, d.is_primary ? "🔑" : "💻"),
      el("div", { style: "flex:1" }, el("div", { class: "name" }, d.name),
        el("div", { class: "muted small" }, d.is_primary ? "Master key" : d.is_this_device ? "This device" : "Linked device")),
      d.is_primary ? null : el("button", { class: "btn small danger", onclick: async () => {
        if (confirm(`Revoke “${d.name}”? Revoking stops it receiving what you post afterward — which cuts off a device that is simply lost or stolen. It can’t help if someone has extracted your master key from it: linked devices hold a copy of that key, and revoking doesn’t take it back. If that happened, the only remedy is to start a new identity.`)) { await invoke("revoke_device", { nodeHex: d.node_hex }); devicesSheet(); }
      } }, "Revoke")));
  }
  devicesCard.append(el("div", { class: "row wrap", style: "margin-top:6px" },
    roster.enabled
      ? el("button", { class: "btn small danger", onclick: async () => { if (confirm("Stop this device acting as the primary?")) { await invoke("step_down_as_primary"); devicesSheet(); } } }, "This isn’t my primary")
      : el("button", { class: "btn small", onclick: async () => { await invoke("enable_device_roster"); devicesSheet(); toast("This is now your primary device"); } }, "Make this my primary"),
    roster.enabled ? null : el("button", { class: "btn small ghost", onclick: async () => { await invoke("request_device_enrollment"); toast("Asked your primary device to authorize this one"); } },
      roster.this_device_authorized ? "Re-sync from my primary" : "Make this a linked device")));

  // seed-drop S4: the SECURE link. Only a seed-holding primary can grant, so offer it once this
  // device is the primary. A new device scans/pastes the one-time code, gets its OWN key + a
  // revocable credential + a granted self-sync key — and NEVER the master seed.
  const seedless = await invoke("seedless_status").catch(() => ({ seedless: false }));
  if (roster.enabled && !seedless.seedless) {
    devicesCard.append(el("div", { class: "row wrap", style: "margin-top:6px" },
      el("button", { class: "btn small primary", onclick: () => enrollDeviceSheet() }, "＋ Add a device (secure link)")));
  }

  // Any pending link requests waiting on this primary's approval.
  const pending = await invoke("enroll_pending").catch(() => []);
  for (const p of pending) {
    devicesCard.append(el("div", { class: "list-item" },
      el("div", {}, "🔗"),
      el("div", { style: "flex:1" },
        el("div", { class: "name" }, p.name || "New device"),
        el("div", { class: "muted small" }, "wants to link with a secure code")),
      el("button", { class: "btn small primary", onclick: async () => { try { await invoke("enroll_approve", { deviceHex: p.device_hex }); toast("Device approved — sending its keys"); } catch (e) { toast("" + e); } devicesSheet(); } }, "Approve"),
      el("button", { class: "btn small ghost", onclick: async () => { await invoke("enroll_reject", { deviceHex: p.device_hex }); devicesSheet(); } }, "Dismiss")));
  }

  sheet("Devices", devicesCard);
}

/// PRIMARY: mint a one-time `haven-enroll:` ticket and show it as a QR + copyable string for the new
/// device to scan/paste. The confirm step happens back in the Devices sheet when the request arrives.
async function enrollDeviceSheet() {
  let ticket = "";
  try { ticket = await invoke("enroll_mint_ticket"); }
  catch (e) { toast("Couldn't create a link code: " + e); return; }
  const qrBox = el("div", { class: "qr-box" });
  try { qrBox.innerHTML = makeQrSvg(ticket); } catch (_) { qrBox.textContent = "QR unavailable"; }
  const body = el("div", { class: "col", style: "gap:12px;align-items:center;text-align:center" },
    el("div", { class: "muted small" }, "On the new device choose “Link this as another of my devices” and scan this code (or paste the text). It's single-use and expires in about 10 minutes."),
    qrBox,
    el("button", { class: "btn small", onclick: async () => { try { await navigator.clipboard.writeText(ticket); toast("Link code copied"); } catch (_) { toast("Copy failed"); } } }, "Copy link code"),
    el("div", { class: "muted small", style: "word-break:break-all;opacity:0.7" }, ticket),
    el("div", { class: "muted small" }, "When the new device asks, come back to Devices and approve it."));
  sheet("Add a device", body);
}

const line = (label, ok) => el("div", { class: "row" }, el("span", { style: "flex:1" }, label), el("span", { class: ok ? "ok-text" : "warn-text" }, ok ? "✓ pass" : "✗ fail"));

// ---- WebRTC mesh calls -----------------------------------------------------------------
// Mirrors the iOS/Android CallManager: a call = sessionId + roster of node hexes; every
// participant opens one RTCPeerConnection to every other (full mesh, no SFU). 1:1 is a
// 2-person group. The lexicographically smaller hex offers (glare-free). SDP/ICE ride the
// sealed iroh channel via the call_signal command; media is DTLS-SRTP in the WebView.
// Haven-first ICE — parity with Apple HavenFabric / Android CallManager.
// Fabric + circle TURN → TURN only. Fabric without TURN → empty ICE (host + WSS hairpin;
// no Google STUN). No fabric → Google STUN as fallback only. Signaling uses iroh/fabric DERP.
function iceServers() {
  const derp = (window.__havenFabricDerp && window.__havenFabricDerp.length)
    ? window.__havenFabricDerp
    : [];
  const turn = window.__havenFabricTurn || {};
  const turnUrls = Array.isArray(turn.urls) ? turn.urls.filter(Boolean) : [];
  if (turnUrls.length > 0 && turn.user && turn.pass) {
    return [{
      urls: turnUrls,
      username: turn.user,
      credential: turn.pass,
    }];
  }
  if (derp.length > 0 || turnUrls.length > 0) {
    return []; // fabric on — never Google as first path
  }
  return [{ urls: ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"] }];
}

// ---- WebSocket call-media hairpin (path proxy /webrtc/hairpin) ----------------------------
// Free Cloudflare tunnels carry HTTPS + WebSocket, not UDP TURN. When the circle fabric has a
// public HTTPS origin (same host as DERP after path-proxy), open a WSS hairpin per peer so
// media can bipipe over TCP/TLS. Binary frames are opaque; v1 uses a tiny PCM audio bridge
// when WebRTC ICE fails for that peer.
function fabricPublicBase() {
  const derp = (window.__havenFabricDerp && window.__havenFabricDerp[0]) || "";
  const u = (derp || "").trim().replace(/\/$/, "");
  if (u.startsWith("https://") || u.startsWith("http://")) return u;
  return "";
}
function hairpinWsUrl() {
  const base = fabricPublicBase();
  if (!base) return "";
  try {
    const u = new URL(base);
    u.protocol = u.protocol === "https:" ? "wss:" : "ws:";
    u.pathname = "/webrtc/hairpin";
    u.search = "";
    u.hash = "";
    return u.toString();
  } catch (_) {
    return "";
  }
}
const hairpin = {
  /// peerHex → { ws, paired, usingMedia, audioCtx, processor, remoteGain, playQueue }
  byPeer: new Map(),
};
function closeHairpinAll() {
  for (const [, h] of hairpin.byPeer) {
    try { h.ws && h.ws.close(); } catch (_) {}
    try { h.processor && h.processor.disconnect(); } catch (_) {}
    try { h.audioCtx && h.audioCtx.close(); } catch (_) {}
  }
  hairpin.byPeer.clear();
}
function openHairpinForPeer(peer) {
  if (!call.session || !call.me || !peer || peer === call.me) return;
  if (hairpin.byPeer.has(peer)) return;
  const url = hairpinWsUrl();
  if (!url) return;
  let ws;
  try { ws = new WebSocket(url); } catch (e) {
    console.warn("hairpin open failed", e);
    return;
  }
  ws.binaryType = "arraybuffer";
  const slot = { ws, paired: false, usingMedia: false, audioCtx: null, processor: null, remoteGain: null };
  hairpin.byPeer.set(peer, slot);
  ws.onopen = () => {
    ws.send(JSON.stringify({
      v: 1,
      session: call.session,
      peer: call.me,
      remote: peer,
    }));
  };
  ws.onmessage = (ev) => {
    if (typeof ev.data === "string") {
      try {
        const j = JSON.parse(ev.data);
        if (j.paired || (j.ok && !j.waiting)) {
          slot.paired = true;
          console.info("hairpin paired", peer);
        }
        if (j.err) console.warn("hairpin", peer, j.err);
      } catch (_) {}
      return;
    }
    // Binary: PCM s16le mono 16kHz packets from peer (media fallback).
    if (slot.usingMedia && ev.data instanceof ArrayBuffer) {
      hairpinPlayPcm(slot, ev.data);
    }
  };
  ws.onclose = () => {
    if (hairpin.byPeer.get(peer) === slot) hairpin.byPeer.delete(peer);
  };
  ws.onerror = () => {};
}
function ensureHairpins() {
  invitees().forEach(openHairpinForPeer);
}
/** Start PCM media over hairpin for a peer whose WebRTC ICE failed. */
async function hairpinStartMedia(peer) {
  const slot = hairpin.byPeer.get(peer);
  if (!slot || !slot.paired || slot.usingMedia || !call.localStream) return;
  slot.usingMedia = true;
  try {
    const ctx = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 16000 });
    slot.audioCtx = ctx;
    const src = ctx.createMediaStreamSource(call.localStream);
    // ScriptProcessor is deprecated but widely available in Tauri webview; keep buffer small.
    const proc = ctx.createScriptProcessor(2048, 1, 1);
    slot.processor = proc;
    proc.onaudioprocess = (e) => {
      if (!slot.usingMedia || !slot.ws || slot.ws.readyState !== 1) return;
      const input = e.inputBuffer.getChannelData(0);
      const pcm = new Int16Array(input.length);
      for (let i = 0; i < input.length; i++) {
        const s = Math.max(-1, Math.min(1, input[i]));
        pcm[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
      }
      try { slot.ws.send(pcm.buffer); } catch (_) {}
    };
    src.connect(proc);
    proc.connect(ctx.destination); // keep processor alive (output is near-silent if we zero? we don't mute)
    // Avoid local echo: disconnect from destination, connect to a zero-gain node instead.
    proc.disconnect();
    const mute = ctx.createGain();
    mute.gain.value = 0;
    proc.connect(mute);
    mute.connect(ctx.destination);
    slot.remoteGain = ctx.createGain();
    slot.remoteGain.connect(ctx.destination);
    console.info("hairpin media fallback on", peer);
    toast("Call media via fabric tunnel (TCP hairpin)");
  } catch (e) {
    console.warn("hairpin media start failed", e);
    slot.usingMedia = false;
  }
}
function hairpinPlayPcm(slot, ab) {
  try {
    if (!slot.audioCtx || !slot.remoteGain) return;
    const pcm = new Int16Array(ab);
    if (!pcm.length) return;
    const f32 = new Float32Array(pcm.length);
    for (let i = 0; i < pcm.length; i++) f32[i] = pcm[i] / (pcm[i] < 0 ? 0x8000 : 0x7fff);
    const buf = slot.audioCtx.createBuffer(1, f32.length, 16000);
    buf.copyToChannel(f32, 0);
    const src = slot.audioCtx.createBufferSource();
    src.buffer = buf;
    src.connect(slot.remoteGain);
    src.start();
  } catch (_) {}
}

const call = {
  session: "", me: "", name: "", roster: new Set(), pcs: new Map(),
  localStream: null, micOn: true, camOn: true,
  /// Peers whose camera is OFF, per frame 22 — their tile shows an avatar instead of the frozen
  /// last frame their stopped track left behind. Cleared with the rest of the call state.
  camOff: {},
  ringing: false, connecting: false, inCall: false, video: true,
  screenOn: false, screenStream: null, camTrack: null,
  ringTimer: null, ended: new Map(),
};

// Callee-side bounded ring (iOS parity). The caller gives up dialing at ~30s, but its hangup
// (frame 12) is fire-and-forget — if it never arrives (caller offline, dropped frame), the
// incoming-call overlay would sit there forever. Ringing always ends after this timeout and the
// call is treated as missed.
const RING_TIMEOUT_MS = 60_000;
// How long an ended session's tombstone suppresses re-ringing. Just outlasts the caller's ~30s
// invite retransmit burst: declining mustn't re-ring when our hangup frame is lost, but a
// deliberate redial — or being re-added to a group call we left — rings normally afterwards.
const ENDED_TOMBSTONE_MS = 45_000;

/** Arm the bounded ring. Cleared by accept and by teardown (decline, hangup, end). */
function startRingTimeout() {
  clearTimeout(call.ringTimer);
  call.ringTimer = setTimeout(() => {
    if (!call.ringing || call.inCall) return;
    toast("Missed call" + (call.name ? " from " + call.name : ""));
    teardownCall();
  }, RING_TIMEOUT_MS);
}

/** Did a session end here recently enough that a fresh invite for it must be ignored? A caller
 *  retransmits the invite every 2.5s and relay hops can replay copies late — none of those may
 *  re-ring a session we've already left. */
function recentlyEnded(sid) {
  const at = call.ended.get(sid);
  return at != null && Date.now() - at < ENDED_TOMBSTONE_MS;
}

/** Call audio priority: true from the first ring/dial until teardown. */
function callAudioActive() { return call.ringing || call.connecting || call.inCall; }

// ---- Capture owns the audio ---------------------------------------------------------------
// How many capture surfaces (in-app camera, voice recorder, QR scanner) are on screen. While ANY is
// up, feed/DM media stays silent: a post's soundtrack playing behind a viewfinder is never wanted,
// and on a machine with one shared input it lands straight in the recording. Counted rather than a
// flag so a capture opened over another capture can't clear it early — the iOS `havenCameraUIOpen`
// counter, same reasoning.
let captureOpenCount = 0;
function captureUIOpen() { return captureOpenCount > 0; }
/** Bracket a capture surface. Returns the release fn, which every exit path calls (they all funnel
 *  through one `finish`/`stop`).
 *
 *  `onDismiss` is the safety net for the paths that DON'T funnel there: Escape and a backdrop click
 *  empty `#modal-root` directly, so a capture dialog can vanish without its own teardown ever
 *  running. Left alone that strands the count above zero and the feed stays muted for the rest of
 *  the session (and the camera light stays on) — so watch the root and tear down when it empties. */
function beginCapture(onDismiss) {
  captureOpenCount++;
  pauseFeedMedia();       // stop what's already playing, not just what renders next
  syncFeedVideoSound();
  let released = false;
  const mo = new MutationObserver(() => {
    if (released || $("#modal-root").childElementCount) return;
    if (onDismiss) onDismiss();   // runs the dialog's own teardown (stops the tracks), which releases
    else release();
  });
  mo.observe($("#modal-root"), { childList: true });
  function release() {
    if (released) return;   // finish() can be reached twice (user close + recorder stop)
    released = true;
    mo.disconnect();        // before the caller clears #modal-root, or we'd re-enter through it
    captureOpenCount = Math.max(0, captureOpenCount - 1);
    syncFeedVideoSound();
  }
  return release;
}

/** Silence whatever the feed/thread is currently playing. Anything that COVERS the feed calls this:
 *  a sheet or modal over a playing clip left its audio running behind the overlay, which is the
 *  desktop shape of the iOS "sheets and covers stop the post song behind them" fix. Only pauses —
 *  the element keeps its position, so dismissing the overlay leaves the clip where the user left it. */
// Deliberately scoped to `[data-video]` / `[data-ref]` — the feed's and thread's own media. The story
// composer's preview clip carries neither, so it is exempt: a preview the author asked for is not
// something an overlay or a capture should silence (iOS says the same with havenStoryPreviewActive).
function pauseFeedMedia() {
  document.querySelectorAll("video[data-video], audio[data-ref]").forEach((m) => {
    if (!m.paused) { try { m.pause(); } catch (_) {} }
  });
}

/** Feed/DM <video> sound = the user's global toggle, overridden to MUTED while a call is
 *  ringing/connecting/live, or while any capture UI is up, so post soundtracks never compete with
 *  call audio or bleed into a recording. Called on the global toggle, on every call state
 *  transition, when capture opens/closes, and by mediaNode for newly-rendered videos. */
function syncFeedVideoSound() {
  document.querySelectorAll("video[data-video]").forEach((v) => { v.muted = callAudioActive() || captureUIOpen() || !state.videoSoundOn; });
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
  clearTimeout(call.ringTimer); call.ringTimer = null;
  call.ringing = false; call.inCall = true;
  // Stop my OTHER devices ringing before they can join and take the audio. Every device of mine
  // rings (right), but nothing told the losers to stand down, so the one not answered on completed
  // signalling when the offer arrived and joined the mesh — audio jumping to whichever device was
  // touched last, and both of them choppy from competing.
  invoke("call_handled_elsewhere", { sessionId: call.session });
  await invoke("call_accept", { sessionId: call.session, to: invitees() });
  await startMesh();
  invitees().forEach(connectPeerIfNeeded);
  renderCallOverlay();
}

async function callHangup() {
  // Declining counts as handling it: silence my other devices too, or they keep ringing after I have
  // dismissed the call here.
  if (call.ringing && !call.inCall) invoke("call_handled_elsewhere", { sessionId: call.session });
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
  ensureHairpins(); // TCP/WSS media path through free CF path proxy (pairs while ICE runs)
  invitees().forEach(connectPeerIfNeeded);
  renderCallOverlay();
}

function pcFor(peer) {
  if (call.pcs.has(peer)) return call.pcs.get(peer);
  const pc = new RTCPeerConnection({ iceServers: iceServers() });
  if (call.localStream) call.localStream.getTracks().forEach((t) => pc.addTrack(t, call.localStream));
  pc.onicecandidate = (e) => {
    if (e.candidate) invoke("call_signal", { kind: "ice", sessionId: call.session, to: peer, json: JSON.stringify({ c: e.candidate.candidate, m: e.candidate.sdpMLineIndex, i: e.candidate.sdpMid }) });
  };
  pc.ontrack = (e) => { call.remote = call.remote || {}; call.remote[peer] = e.streams[0]; renderCallOverlay(); };
  pc.onconnectionstatechange = () => {
    const st = pc.connectionState;
    // When ICE cannot path, fall back to path-proxy WebSocket hairpin (works over free CF).
    if (st === "failed" || st === "disconnected") {
      openHairpinForPeer(peer);
      hairpinStartMedia(peer);
    }
  };
  call.pcs.set(peer, pc);
  return pc;
}

async function connectPeerIfNeeded(peer) {
  openHairpinForPeer(peer);
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
      // GLARE: we are ringing THEM while they are ringing US. Both sides used to swallow the other's
      // invite here (same session → merge the roster, different session → drop it), so two people who
      // called each other at the same moment both sat listening to ringback and NEITHER call ever
      // connected. They obviously both want this call — so connect it. Both ends run this identical
      // logic and must agree without another round trip: the session id is derived from the two hexes
      // in sorted order (offer/answer roles already follow the same smaller-hex rule). iOS parity.
      if (call.connecting && !call.inCall && call.session !== c.sessionId && call.roster.has(c.from)) {
        const a = (call.me || "").toLowerCase(), b = (c.from || "").toLowerCase();
        call.session = `glare:${a < b ? a : b}-${a < b ? b : a}`;
        members.forEach((m) => call.roster.add(m));
        call.connecting = false; call.inCall = true;
        clearTimeout(call.ringTimer); call.ringTimer = null;
        await invoke("call_accept", { sessionId: call.session, to: [c.from] }).catch(() => {});
        await startMesh(); connectPeerIfNeeded(c.from); renderCallOverlay();
        return;
      }
      if (call.inCall || call.ringing || call.connecting) {
        if (call.session === c.sessionId) { members.forEach((m) => call.roster.add(m)); if (call.localStream) invitees().forEach(connectPeerIfNeeded); }
        return;
      }
      if (recentlyEnded(c.sessionId)) return;   // we already left this session — retransmits can't re-ring
      call.session = c.sessionId; call.roster = members; call.name = c.groupName || c.name || displayNameFor(c.from);
      call.ringing = true; call.video = true; startRingTimeout(); syncFeedVideoSound(); renderCallOverlay();
      break;
    }
    case "accept": {
      if (!validSession(c.sessionId)) return;
      call.connecting = false; call.inCall = true; call.roster.add(c.from);
      await startMesh(); connectPeerIfNeeded(c.from); renderCallOverlay();
      break;
    }
    // Another of MY devices answered or declined this call. Deliberately narrow: it silences a call
    // this device is still RINGING — never one already answered here, so a late-arriving frame can't
    // hang up a conversation in progress — and only from my own account, which Rust proves from the
    // frame's signature before emitting this.
    case "handledElsewhere": {
      if (!call.ringing || call.inCall || c.sessionId !== call.session) return;
      teardownCall();   // tombstones the session, so a retransmitted invite can't re-ring us

      break;
    }
    // A peer's camera went on or off (frame 22). Their track stops producing frames either way, so
    // without this their tile holds the last frame it received and looks like a live, frozen person.
    case "camera": {
      if (!call.camOff) call.camOff = {};
      if (c.on) delete call.camOff[c.from]; else call.camOff[c.from] = true;
      renderCallOverlay();
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

/** The contact behind a feed item's SHORT (8-hex) author id, or undefined if we don't hold them.
 *  A post only carries the short id, so anything addressed to its author has to resolve it first. */
function authorContact(authorShort) {
  if (!authorShort) return undefined;
  return (state.contacts || []).find((c) => (c.id_hex || "").startsWith(authorShort));
}

function teardownCall() {
  // Remember the session so the caller's still-in-flight invite retransmits can't re-ring it.
  if (call.session) {
    call.ended.set(call.session, Date.now());
    if (call.ended.size > 50) {   // prune long-expired tombstones
      const now = Date.now();
      for (const [sid, at] of call.ended) if (now - at >= ENDED_TOMBSTONE_MS) call.ended.delete(sid);
    }
  }
  clearTimeout(call.ringTimer); call.ringTimer = null;
  closeHairpinAll();
  if (call.screenStream) { call.screenStream.getTracks().forEach((t) => t.stop()); call.screenStream = null; }
  call.screenOn = false; call.camTrack = null; call.camOff = {};
  call.pcs.forEach((pc) => pc.close()); call.pcs.clear();
  if (call.localStream) call.localStream.getTracks().forEach((t) => t.stop());
  call.localStream = null; call.remote = {};
  call.roster.clear(); call.session = ""; call.ringing = false; call.connecting = false; call.inCall = false;
  syncFeedVideoSound();   // restore the user's global video-sound choice now the call is over
  renderCallOverlay();
}

function toggleMic() { call.micOn = !call.micOn; if (call.localStream) call.localStream.getAudioTracks().forEach((t) => (t.enabled = call.micOn)); renderCallOverlay(); }
function toggleCam() {
  call.camOn = !call.camOn;
  if (call.localStream) call.localStream.getVideoTracks().forEach((t) => (t.enabled = call.camOn));
  // TELL the other participants (frame 22). Disabling the track locally stops sending frames, so
  // without this every peer is left staring at our frozen last frame instead of our avatar. iOS and
  // Android both send and handle this; desktop declared neither, so it was the odd one out.
  const peers = invitees();
  if (peers.length) {
    invoke("call_camera_state", { sessionId: call.session, on: call.camOn, to: peers }).catch(() => {});
  }
  renderCallOverlay();
}

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
    const camOff = !!(call.camOff && call.camOff[peer]);
    // Camera off (told to us by frame 22) → show their avatar, NOT the frozen last frame their
    // stopped track left behind.
    if (camOff) {
      tile.append(el("div", { class: "avatar big" }, initials(displayNameFor(peer))));
    } else {
      const v = el("video", { autoplay: "", playsinline: "" });
      if (call.remote && call.remote[peer]) v.srcObject = call.remote[peer];
      tile.append(v);
    }
    tile.append(el("span", { class: "call-name" }, displayNameFor(peer) + (camOff ? " (camera off)" : "")));
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
// The theme TOGGLE now lives in Settings ▸ Appearance (there is no sidebar footer to pin it to,
// and macOS has no such control at all — it follows the system). This just restores the choice.
function initTheme() {
  const saved = localStorage.getItem("haven-theme");
  if (saved) document.documentElement.dataset.theme = saved;
}

// First-run welcome (parity with iOS/Android): on a fresh install the backend has NO identity or
// engine, so we must show this BEFORE calling any engine command. "Create" mints a new identity;
// "Link" adopts a transfer code from another device. Both relaunch the app into the normal flow.
/// Terms acceptance, versioned — mirrors TermsStore (apple/HavenApp/TermsView.swift). Bump
/// TERMS_VERSION when the terms change materially and everyone re-agrees on next launch.
const TERMS_VERSION = 1;
const Terms = {
  KEY: "haven-terms-accepted-version",
  // In-memory mirror. localStorage is the RECORD, but it cannot be the only copy: if it fails or
  // isn't persisting, accept() writes nothing, boot() re-reads false, and the gate re-renders —
  // agree, gate, agree, gate, with no way into the app. A gate that can't be passed is worse than
  // no gate. Measured: the installed .deb had no localstorage/ dir and did exactly this.
  _mem: 0,
  accepted() {
    let v = this._mem;
    try { v = Math.max(v, Number(localStorage.getItem(this.KEY) || 0)); } catch (_) {}
    return v >= TERMS_VERSION;
  },
  accept() {
    this._mem = TERMS_VERSION;
    try { localStorage.setItem(this.KEY, String(TERMS_VERSION)); } catch (_) {}
  },
};

/// The profile the user typed during onboarding, held until there's an engine to receive it.
/// onboard_create restarts the process (a new identity means a new engine), so set_profile can't
/// be called inline — nothing is listening yet. Stash it, apply it on the next boot.
const PendingProfile = {
  KEY: "haven-pending-profile",
  _mem: null,
  stash(v) { this._mem = v; try { localStorage.setItem(this.KEY, JSON.stringify(v)); } catch (_) {} },
  take() {
    let raw = null;
    try { raw = localStorage.getItem(this.KEY); localStorage.removeItem(this.KEY); } catch (_) {}
    if (!raw) { const m = this._mem; this._mem = null; return m; }
    this._mem = null;
    try { return JSON.parse(raw); } catch (_) { return null; }
  },
};

/// The ground rules (App Review 1.2). Copy is TermsContent's, verbatim — apple/HavenApp/TermsView.swift.
function termsContent() {
  const rule = (icon, title, body) => el("div", { class: "row", style: "align-items:flex-start;gap:14px;text-align:left" },
    el("div", { style: "font-size:30px;line-height:1" }, icon),
    el("div", { class: "col", style: "gap:3px" },
      el("div", { style: "font-weight:600" }, title),
      el("div", { class: "muted small" }, body)));
  return el("div", { class: "col", style: "gap:18px;text-align:left" },
    el("h2", { style: "font-size:26px;font-weight:800;margin:0;text-align:center" }, "The ground rules"),
    el("p", { class: "muted small", style: "margin:0" },
      "Haven is yours and your people's — nobody else can see inside, so keeping it good is on all of us. There is zero tolerance for objectionable content or abusive behavior."),
    rule("🚫", "Never allowed", "Harassment or bullying, hate, threats or violence, sexual content involving minors, non-consensual intimate content, scams, impersonation, or anything illegal."),
    rule("🛡️", "Your circle enforces it", "Anyone can report a post — the whole circle sees the report and can hide it, remove the person, or block them instantly."),
    rule("📒", "Actions are on the record", "Reports and blocks are logged permanently — who acted against whom and the category, never the content itself. Repeated abuse costs an identity its service."),
    rule("💜", "You own what you share", "Everything is end-to-end encrypted, so only your circle sees it — and you're responsible for it."),
    el("a", { href: "https://github.com/blaineam/haven/blob/main/docs/TERMS.md", target: "_blank",
              class: "small", style: "text-align:center;text-decoration:underline;color:var(--pink)" },
       "Read the full terms of use"));
}

/// The standalone gate for identities that exist but never agreed (upgraders, linked devices).
/// Apple has the same thing at HavenApp.swift:268 — there is no other way in.
function renderTermsGate() {
  const card = el("div", { class: "col", style: "max-width:520px;width:100%;gap:20px" },
    el("div", { style: "max-height:60vh;overflow:auto" }, termsContent()),
    el("button", { class: "btn primary", style: "width:100%;padding:12px", onclick: () => {
      Terms.accept();
      document.getElementById("onboard-overlay")?.remove();
      boot();
    } }, "I agree"));
  document.body.appendChild(el("div", { id: "onboard-overlay", style: "position:fixed;inset:0;z-index:9999;display:flex;align-items:center;justify-content:center;padding:32px;background:var(--bg, #0d0b1a)" }, card));
}

/// Onboarding — the same four steps as iOS/macOS (OnboardingView.swift): welcome, who are you,
/// how it works, the ground rules. Desktop used to be a single "Create my Haven" button: no name,
/// no avatar, no explanation, and — the one that mattered — no terms at all, so a desktop user had
/// never agreed to the rules the whole moderation model assumes everyone signed up to.
function renderOnboarding() {
  let step = 0;
  let name = "";
  let emoji = "🌿";
  let avatar = "";
  let showLink = false;
  /// "add" (another device, both stay signed in) or "move" (migrate, this replaces the old one) —
  /// the two codes go in the same box, but the instructions for getting one differ, and so does
  /// what happens to the device you already have.
  let linkMode = "add";

  const brandMark = () => {
    const m = el("div", { style: "width:112px;height:112px;border-radius:56px;background:var(--grad);"
      + "display:flex;align-items:center;justify-content:center;box-shadow:0 10px 20px rgba(236,72,153,0.4)" });
    m.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" style="width:66px;height:66px">
      <circle cx="6" cy="7" r="1.6" fill="white"/><circle cx="18" cy="6" r="1.6" fill="white"/>
      <circle cx="12" cy="13" r="1.8" fill="white"/><circle cx="5" cy="17" r="1.6" fill="white"/>
      <circle cx="19" cy="17" r="1.6" fill="white"/>
      <path d="M6 7l6 6 6-7M12 13l-7 4M12 13l7 4" opacity="0.85"/></svg>`;
    return m;
  };

  const code = el("input", { class: "field-capsule", placeholder: "haven-enroll:… or haven-seed:…", style: "width:100%" });
  const linkBox = () => el("div", { class: "col", style: "width:100%;gap:8px" },
    el("div", { class: "muted small" }, linkMode === "move"
      ? "On the device you're replacing, open You ▸ Devices ▸ Advanced ▸ Transfer my identity and copy the transfer code. Paste it here. Your identity MOVES — finish setting up here before you retire that device."
      : "On your other device open You ▸ Devices ▸ Add a device (secure link) for a one-time code. Paste it here. Both devices stay signed in and stay in sync."),
    code,
    el("button", { class: "btn ghost small", style: "align-self:flex-start", onclick: () => { showLink = false; draw(); } }, "← Back"),
    el("button", { class: "btn primary", style: "width:100%", onclick: async () => {
      const c = code.value.trim();
      if (!c) { toast("Paste a link code first"); return; }
      // A linked device inherits an identity that already agreed elsewhere — but acceptance is
      // per-device local state, so record it here too rather than drop them on the gate.
      Terms.accept();
      try {
        // seed-drop S4: the new secure link (`haven-enroll:`) gives this device its OWN key +
        // credential + granted self-sync key and NEVER the master seed. The legacy `haven-seed:` /
        // raw-seed transfer still works (an old primary in the wild) via onboard_link.
        if (/^haven-enroll:/i.test(c)) await invoke("onboard_link_seedless", { ticket: c });
        else await invoke("onboard_link", { code: c });
      }
      catch (e) { toast("Couldn't link: " + e); }
    } }, linkMode === "move" ? "Move my account here" : "Add this device"));

  /// One onboarding path: what it's called, and — the part that actually prevents mistakes — what
  /// it does to the device you already have. A card, not a text link, so an alternative reads as a
  /// real choice rather than fine print.
  const choice = (title, subtitle, on) =>
    el("button", { class: "btn ghost", style: "width:100%;text-align:left;padding:14px", onclick: on },
      el("div", { class: "col", style: "gap:3px" },
        el("div", { style: "font-weight:600" }, title),
        el("div", { class: "muted small", style: "white-space:normal" }, subtitle)));

  // THREE paths, each named for what it DOES. This screen used to offer starting fresh as an
  // unlabelled "Get started" with linking as a small ghost button underneath — so the ADDITIVE
  // choice (another device) and the MIGRATING one (move the account) were not distinguished at all,
  // and nothing said what happens to the device you already have. That is the part people get wrong.
  // `linkMode` picks which text the shared paste box explains itself with; both codes have always
  // worked in it, but a box that mentions both is a box that answers neither question.
  const welcome = () => el("div", { class: "col", style: "align-items:center;gap:20px;text-align:center" },
    brandMark(),
    el("h1", { style: "font-size:34px;font-weight:800;margin:6px 0 0" }, "Welcome to Haven"),
    el("p", { class: "muted", style: "margin:0;white-space:pre-line" },
      "A private little place for the people you love.\nNo ads. No tracking. No strangers. Just your people."),
    showLink ? linkBox()
             : el("div", { class: "col", style: "width:100%;gap:10px" },
                 choice("I'm new to Haven",
                        "Create a brand-new identity on this PC.",
                        () => advance()),
                 choice("Add this as another of my devices",
                        "Use my existing Haven account here too. My other device stays signed in, and both stay in sync.",
                        () => { showLink = true; linkMode = "add"; draw(); }),
                 choice("Move my account to this device",
                        "Bring my identity over from another device using a transfer code. Use this when replacing a device, not when adding one.",
                        () => { showLink = true; linkMode = "move"; draw(); })));

  const pickName = () => {
    const field = el("input", { class: "pill-field", style: "text-align:center;font-size:18px", placeholder: "Your name or nickname", value: name,
                                oninput: (e) => { name = e.target.value; next.disabled = !name.trim(); next.style.opacity = name.trim() ? 1 : 0.5; } });
    const picker = el("input", { type: "file", accept: "image/*", style: "display:none", onchange: async (e) => {
      const f = e.target.files[0];
      if (!f) return;
      try { avatar = await avatarDataUrl(f); draw(); }
      catch (_) { toast("That file isn't an image Haven can read"); }
    } });
    const grid = el("div", { class: "emoji-grid" });
    for (const em of AVATAR_EMOJI) {
      grid.appendChild(el("button", { class: "emoji-cell" + (emoji === em ? " on" : ""), onclick: () => { emoji = em; draw(); } }, em));
    }
    return el("div", { class: "col", style: "align-items:center;gap:16px;text-align:center" },
      el("h2", { style: "font-size:26px;font-weight:800;margin:0;white-space:pre-line" }, "What should your\npeople call you?"),
      el("div", { class: "disc", style: "width:96px;height:96px;font-size:40px" },
         avatar ? el("img", { src: avatar }) : emoji),
      el("div", { class: "row", style: "justify-content:center;gap:8px" },
        el("button", { class: "btn small tint-pink", onclick: () => picker.click() }, avatar ? "Change photo" : "Add a photo"),
        avatar ? el("button", { class: "btn small danger", onclick: () => { avatar = ""; draw(); } }, "Remove") : null,
        picker),
      field,
      el("div", { class: "muted small" }, avatar ? "Emoji (shown if you remove your photo)" : "Or pick an emoji"),
      grid);
  };

  const howItWorks = () => {
    const point = (icon, title, body) => el("div", { class: "row", style: "align-items:flex-start;gap:14px;text-align:left" },
      el("div", { style: "font-size:30px;line-height:1" }, icon),
      el("div", { class: "col", style: "gap:3px" },
        el("div", { style: "font-weight:600" }, title),
        el("div", { class: "muted small" }, body)));
    return el("div", { class: "col", style: "gap:22px" },
      el("h2", { style: "font-size:26px;font-weight:800;margin:0;text-align:center" }, "How Haven works"),
      point("🔒", "Private by design", "Everything you share is locked so only the people in your circle can ever see it."),
      point("🚫", "No ads, no tracking", "There's no algorithm and no company watching. Haven doesn't collect anything about you."),
      point("🤝", "You choose your circle", "Nothing happens with strangers. You invite the people you want, one at a time."));
  };

  const next = el("button", { class: "btn primary", style: "width:100%;padding:12px" });

  const advance = async () => {
    if (step < 3) { step += 1; draw(); return; }
    // Agreeing IS the door in — same as iOS. Record acceptance and the typed profile BEFORE
    // onboard_create, which restarts the process out from under us.
    Terms.accept();
    PendingProfile.stash({ name: name.trim(), emoji, avatar });
    try { await invoke("onboard_create"); }
    catch (e) { toast("Couldn't create: " + e); }
  };
  next.onclick = advance;

  const body = el("div", { class: "col", style: "width:100%;gap:6px" });
  const dots = el("div", { class: "row", style: "justify-content:center;gap:7px;margin-top:4px" });

  function draw() {
    body.innerHTML = "";
    body.appendChild([welcome, pickName, howItWorks, () => el("div", { style: "max-height:52vh;overflow:auto" }, termsContent())][step]());
    // Step 0 now offers the three paths as explicit choices, so a generic "Get started" underneath
    // them would be a fourth, ambiguous door onto the same screen.
    next.style.display = step === 0 ? "none" : "";
    next.textContent = step === 3 ? "I agree — enter Haven" : "Continue";
    const needName = step === 1 && !name.trim();
    next.disabled = needName;
    next.style.opacity = needName ? 0.5 : 1;
    dots.innerHTML = "";
    for (let i = 0; i < 4; i++) dots.appendChild(el("div", { class: "dot" + (i === step ? " on" : "") }));
  }

  const card = el("div", { class: "col", style: "max-width:520px;width:100%;align-items:center;gap:14px" },
    body, next, dots,
    el("p", { class: "muted small", style: "margin-top:10px;text-align:center" },
      "No phone number. No email. Your keys never leave this device."));

  document.getElementById("onboard-overlay")?.remove();
  document.body.appendChild(el("div", { id: "onboard-overlay", style: "position:fixed;inset:0;z-index:9999;display:flex;align-items:center;justify-content:center;padding:32px;overflow:auto;background:var(--bg, #0d0b1a)" }, card));
  draw();
}

/// Seed-drop S4 linking screen: a seedless device that has scanned a `haven-enroll:` ticket but
/// hasn't been granted yet. The engine re-sends the frame-28 request on a loop; we sit here until
/// the primary approves (which fires `haven:enrolled` → relaunch into the fully-linked app).
function renderSeedlessLinking() {
  const spinner = el("div", { style: "font-size:40px" }, "🔗");
  const card = el("div", { class: "col", style: "max-width:460px;width:100%;align-items:center;gap:16px;text-align:center" },
    spinner,
    el("h1", { style: "font-size:26px;font-weight:800;margin:0" }, "Waiting for your other device"),
    el("p", { class: "muted", style: "margin:0" },
      "Open Haven on the device that has your account, go to You ▸ Devices, and approve this device. It'll get its own key — your master seed never leaves that device."),
    el("button", { class: "btn ghost small", onclick: () => location.reload() }, "Check again"));
  document.getElementById("onboard-overlay")?.remove();
  document.body.appendChild(el("div", { id: "onboard-overlay", style: "position:fixed;inset:0;z-index:9999;display:flex;align-items:center;justify-content:center;padding:32px;overflow:auto;background:var(--bg, #0d0b1a)" }, card));
  // The grant lands over iroh → the engine emits `haven:enrolled`; relaunch to rebuild seedless-linked.
  listen("haven:enrolled", async () => { try { await invoke("finish_enroll"); } catch (_) { location.reload(); } });
}

async function boot() {
  initTheme();
  // Fresh install → no identity/engine yet. Show the welcome screen and stop before touching any
  // engine command (which would error). onboard_create/onboard_link relaunch into the real app.
  try {
    if (await invoke("needs_onboarding")) { renderOnboarding(); return; }
  } catch (_) {}
  // Seed-drop S4: a seedless device still LINKING (scanned a ticket, no grant yet) sits on a
  // waiting screen until its primary approves. A fully-linked seedless device falls through as normal.
  try {
    const ss = await invoke("seedless_status");
    if (ss && ss.linking) { renderSeedlessLinking(); return; }
  } catch (_) {}
  // An identity exists. Two things onboarding couldn't do until now, because both need an engine:
  //
  // 1. The profile typed at onboarding. onboard_create restarts the process, so set_profile had
  //    nowhere to land at the time — this is the first moment it does.
  const pending = PendingProfile.take();
  if (pending && pending.name) {
    await invoke("set_profile", { name: pending.name, bio: "", link: "", emoji: pending.emoji || "🌿", avatar: pending.avatar || "" })
      .catch(() => PendingProfile.stash(pending));   // keep it for the next boot rather than lose the name
  }
  // 2. The ground rules, for identities that predate them — upgraders and linked devices never saw
  //    an onboarding flow. Same standalone gate as HavenApp.swift:268: there is no other way in.
  if (!Terms.accepted()) { renderTermsGate(); return; }
  // The demo cast starts PAST the relay nudge, exactly like the phones' seeders
  // (DemoSeed.swift ▸ `RelayNudgeStore.shared.dismiss`, DemoSeed.kt ▸ `RelayNudge.dismiss`). It's a
  // problem-state banner — "this circle has no relay yet" — and a seeded circle trips it purely
  // because the seeder never hosts, so it would head every screenshot with a complaint. Desktop
  // dismisses it HERE rather than in the seeder because this nudge's state is localStorage, which
  // the Rust side can't reach.
  if (await invoke("demo_mode").catch(() => false)) RelayNudge.dismiss("default");
  $$(".tab").forEach((b) => b.addEventListener("click", () => switchView(b.dataset.view)));
  // The activity bell: glyph + click target (the badge <i> already sits inside the button).
  const bell = $("#bell-btn");
  if (bell) {
    bell.prepend(icon("bell"));
    bell.addEventListener("click", () => activityPanel());
  }
  try {
    const b = await invoke("bootstrap");
    state.node = b.node_id_hex;
    state.inviteUri = b.invite_uri;
    state.inviteLink = b.invite_link;
    state.profile = b.profile;
  } catch (e) {
    toast("Backend not ready: " + e);
  }
  await Pins.load();   // adopt pins synced from the user's other devices before Messages renders
  await refreshStatus();
  await refreshBadges();
  await render();

  // First-run nudge to set a name.
  if (!state.profile.name) switchView("you");

  try { state.contacts = await invoke("contacts"); } catch (_) {}
  try { state.videoSoundOn = await invoke("video_sound_on"); } catch (_) { state.videoSoundOn = false; }
  try {
    const pp = await invoke("privacy_prefs");
    state.superDataSaver = !!(pp && pp.super_data_saver);
  } catch (_) { state.superDataSaver = false; }
  listen("haven:changed", async () => {
    await refreshStatus(); await refreshBadges();
    await Pins.load();   // a pin made on the phone lands via self-sync — reflect it live
    try { state.contacts = await invoke("contacts"); } catch (_) {}
    // Don't yank the profile editor out from under the user mid-type on a background sync — re-rendering
    // the "you" view rebuilds its inputs and discards what they're typing.
    const ae = document.activeElement;
    if (state.view === "you" && ae && (ae.tagName === "INPUT" || ae.tagName === "TEXTAREA") && $("#view-you").contains(ae)) return;
    await render();
  });
  // Haven fabric: circle-hosted DERP (+ TURN for WebRTC media; else STUN). Signaling uses fabric.
  // rebindPending: soft rebind in progress (Engine stops + restarts HavenNode onto Haven RelayMap).
  listen("haven-fabric", (e) => {
    const urls = (e.payload && e.payload.derpUrls) || [];
    window.__havenFabricDerp = Array.isArray(urls) ? urls : [];
    window.__havenFabricTurn = {
      urls: Array.isArray(e.payload && e.payload.turnUrls) ? e.payload.turnUrls : [],
      user: (e.payload && e.payload.turnUser) || "",
      pass: (e.payload && e.payload.turnPass) || "",
    };
    const pending = !!(e.payload && e.payload.rebindPending);
    if (pending && !window.__havenFabricRebindHinted) {
      window.__havenFabricRebindHinted = true;
      toast("Haven fabric ready — reconnecting this session onto circle DERP…");
    }
    if (!pending && window.__havenFabricRebindHinted && !window.__havenFabricRebindDone) {
      window.__havenFabricRebindDone = true;
      toast("Connected on Haven fabric (circle DERP)");
    }
  });
  // A notification carrying a deepLink is ABOUT something openable — make the toast take you there
  // rather than just announcing it. Routed through routeDeepLink, the same parser a pasted or
  // OS-delivered link uses, so there is one route table rather than a parallel one.
  listen("haven:notify", (e) => {
    const p = e.payload || {};
    if (p.deepLink) toast(`${p.title}: ${p.body}`, () => routeDeepLink(p.deepLink));
    else toast(`${p.title}: ${p.body}`);
  });
  // seed-drop S4: a new device asked THIS primary to link with a secure code. Nudge the user to the
  // Devices sheet, where the request shows an Approve/Dismiss row.
  listen("haven:enroll-request", (e) => { const p = e.payload || {}; toast(`“${p.name || "A device"}” wants to link — open You ▸ Devices to approve`); });
  // Deep links (`haven://…` from the OS). The backend QUEUES them and pings us rather than putting the
  // URL in the event, because a link that launched Haven arrives long before this webview has a
  // listener — so we drain once at boot too, or a cold-start link is silently dropped.
  const drainDeepLinks = async () => {
    for (const url of await invoke("take_deep_links").catch(() => [])) {
      const kind = await routeDeepLink(url);
      if (kind === "invite") toast("Invite sent — they'll appear once they accept");
      else if (!kind) toast("That doesn't look like a Haven link");
    }
  };
  listen("haven:deep-link", drainDeepLinks);
  drainDeepLinks();
  listen("haven:call", (e) => onCallEvent(e.payload));
  // Drag photos/videos from the file manager onto the window → attach to the active composer.
  //
  // A dropped file goes through the SAME `sanitizeMediaFile` pipeline as a picked one. It used to
  // call `add_media_path`, which sealed the file straight off disk — full resolution, and with the
  // capture EXIF/GPS still in it. That was the last metadata leak on desktop, and it only existed
  // because file→file sealing avoided pulling the bytes through this process.
  //
  // Closing it costs one memory hop: `read_media_file_b64` reads the file back into the WebView so
  // the canvas can re-encode it. That hop is bounded by MAX_SOURCE_BYTES_* (enforced in Rust too),
  // and it is the same hop the picker path has always paid on the way OUT — every re-encoded blob
  // already crosses this boundary as base64. Correctness over the allocation.
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
      const maxBytes = isVideo ? MEDIA_TARGETS.MAX_SOURCE_BYTES_VIDEO : MEDIA_TARGETS.MAX_SOURCE_BYTES_STILL;
      try {
        const got = await invoke("read_media_file_b64", { path: p, maxBytes });
        // Rebuild a File so the shared pipeline sees exactly what the picker hands it. The `type`
        // is only used for the isVideo split, which we already know from the extension.
        const bin = atob(got.data_base64);
        const buf = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
        const file = new File([buf], got.name, { type: isVideo ? "video/*" : "image/*" });
        const b64 = await sanitizeMediaFile(file, isVideo);
        if (b64 === null) continue;                      // refused — no ref, no attachment entry
        const circleId = state.composerCircle || state.activeCircle;
        const ref = await invoke("add_media", { circleId, dataBase64: b64, isVideo });
        const thumbRef = isVideo ? null : await mintThumb(b64, circleId);
        await state.composerAdd(ref, isVideo, false, thumbRef);
      } catch (err) {
        console.error("drop ingest failed", p, err);
        // The Rust side enforces the same size cap before it reads, so name that reason explicitly
        // rather than reporting it as a generic failure.
        toast(String(err).includes("too large")
          ? `That ${isVideo ? "video" : "photo"} is over Haven's ${fmtMB(maxBytes)} limit, so it wasn't attached.`
          : "Couldn't attach that file");
      }
    }
  });
  setInterval(refreshStatus, 5000);

  // Tell the backend whether the window is foregrounded (suppress notifications when it is).
  invoke("set_foreground", { fg: document.hasFocus() }).catch(() => {});
  window.addEventListener("focus", () => invoke("set_foreground", { fg: true }).catch(() => {}));
  window.addEventListener("blur", () => invoke("set_foreground", { fg: false }).catch(() => {}));
}

window.addEventListener("DOMContentLoaded", boot);

// The macOS traffic lights (hidden everywhere else — see `HOST_OS`). `withGlobalTauri` exposes the
// window API. Close goes through `close()` on purpose: the backend turns it into hide-to-tray.
(() => {
  const w = window.__TAURI__?.window?.getCurrentWindow?.();
  if (!w) return; // not running under Tauri (e.g. the browser style gallery) — buttons are inert
  const on = (id, fn) => document.getElementById(id)?.addEventListener("click", fn);
  on("win-close", () => w.close());
  on("win-min", () => w.minimize());
  on("win-max", () => w.toggleMaximize());
})();
