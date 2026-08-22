// Haven desktop frontend. Talks to the Rust backend (which links the shared core) via
// Tauri `invoke`. No framework — small DOM helpers + per-view render functions, re-rendered
// when the backend emits `haven:changed`.

const TAURI = window.__TAURI__ || {};
const invoke = TAURI.core ? TAURI.core.invoke : async () => { throw new Error("Tauri not ready"); };
const listen = TAURI.event ? TAURI.event.listen : async () => {};

// i18n — strings.js (a plain script loaded before this module) provides t()/tEn()/HAVEN_LANG.
// The fallbacks keep the app alive if strings.js ever fails to load: keys render as themselves.
const t = window.t || ((k) => k);
const tEn = window.tEn || ((k) => k);
const HAVEN_LANG = window.HAVEN_LANG || "en";

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

/** Short relative age — "now", "5m", "3h", "2d", "3w", "8mo", "2y". Apple parity
 *  (relativeTimeShort in FeedView.swift) and Android's the same.
 *
 *  This used to fall back to an absolute toLocaleDateString() after a week, which was tolerable
 *  when a feed only held recent posts and wrong the moment archive imports existed: every one of
 *  several hundred backdated posts printed a full date while the same post on a phone read "2y".
 *  The unit keeps getting coarser instead, and months roll over to years at twelve — "32mo" is a
 *  number nobody converts on sight. */
function relTime(ms) {
  const n = Number(ms);
  if (!n) return "";
  const s = Math.floor((Date.now() - n) / 1000);
  if (s < 60) return t("just_now");
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h`;
  const d = Math.floor(h / 24);
  if (d < 7) return `${d}d`;
  const w = Math.floor(d / 7);
  if (d < 30) return `${w}w`;
  const mo = Math.floor(d / 30);
  if (d < 365) return `${mo}mo`;
  return `${Math.floor(d / 365)}y`;
}

function initials(name) {
  const p = (name || "").trim().split(/\s+/);
  if (!p[0]) return "·";
  return (p[0][0] + (p[1] ? p[1][0] : "")).toUpperCase();
}

function modal(node, opts = {}) {
  setTimeout(() => Autoplay.schedule(), 0);   // an overlay covers the feed → it goes quiet
  // Anything presented over the feed silences what the feed was playing (iOS parity: a sheet or
  // cover stops the post soundtrack behind it). Runs BEFORE the overlay's own content is inserted,
  // so a story viewer's clip — created below — is untouched.
  pauseFeedMedia();
  const root = $("#modal-root");
  const backdrop = el("div", { class: "modal-backdrop", onclick: (e) => { if (e.target === backdrop) closeModal(); } }, node);
  node.classList.add("modal", "plain");
  // A VISIBLE way out. Every dialog built on modal() — edit post, the song picker, new circle, the
  // small confirmations — offered only Esc or a click on the backdrop, both of which are invisible
  // and neither of which is discoverable. `sheet()` has always had its glass close circle; this is
  // the same affordance, added once here so no dialog can be built without one.
  node.prepend(el("button", {
    class: "icon-btn glass modal-x", title: t("close"), "aria-label": t("close"),
    onclick: () => closeModal(),
  }, icon("xmark")));
  // A dialog opened OVER another (the song picker over the post editor) has to give the first one
  // back rather than clear the root, which took the editor — and everything typed into it — with it.
  state.modalOnClose = opts.onClose || null;
  root.replaceChildren(backdrop);
  return () => closeModal();
}
const closeModal = () => {
  setTimeout(() => Autoplay.schedule(), 0);   // the feed is visible again
  const back = state.modalOnClose;
  state.modalOnClose = null;
  if (back) back();                       // hand the covered dialog back
  else $("#modal-root").replaceChildren();
};

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
      el("button", { class: "icon-btn glass", title: t("close"), onclick: () => closeModal() }, icon("xmark")),
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
  // Leaves the app — drawn as a box the arrow exits, which reads at 13px where SF's in-square
  // version turns to mush. `icon()` returns an EMPTY svg for a name it doesn't know, so a missing
  // entry here is an invisible button, not a broken one.
  "arrow.up.forward.app": { d: "M14 4H6a2 2 0 00-2 2v12a2 2 0 002 2h12a2 2 0 002-2v-8", extra: "M14 10l6.5-6.5M15 3h6v6" },
  // "Keep on this device" — a pushpin, matching Apple's `pin` on the same action.
  "play.fill": { fill: true, d: "M8 5.4v13.2L19 12z" },
  "pause.fill": { fill: true, d: "M8 5h3.2v14H8zM12.8 5H16v14h-3.2z" },
  "pin": { d: "M9 4h6l-1 5 3 3v2h-5m0 0v5m0-5H7v-2l3-3-1-5" },
  // "Message …" in the post menu. `bubble.left` on Apple; the tail hangs left, which is what
  // distinguishes it from the reaction bubble.
  "bubble.left": { d: "M20 12a7 7 0 01-7 7H8l-4 3v-4.5A7 7 0 018 5h5a7 7 0 017 7z" },
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
  "envelope": { d: "M3.5 6a2 2 0 012-2h13a2 2 0 012 2v12a2 2 0 01-2 2h-13a2 2 0 01-2-2V6z", extra: "M3.5 7l8.5 6 8.5-6" },
  "lightbulb": { d: "M9.5 18h5M10.5 21h3M12 3a6 6 0 00-3.9 10.6c.7.6.9 1.4.9 2.4h6c0-1 .2-1.8.9-2.4A6 6 0 0012 3z" },
  "questionmark.circle": { d: "M12 21a9 9 0 100-18 9 9 0 000 18z", extra: "M9.6 9.2a2.5 2.5 0 114.2 1.8c-.8.7-1.8 1.3-1.8 2.5M12 16.8h.01" },
  "character.bubble": { d: "M4 6a2 2 0 012-2h12a2 2 0 012 2v8a2 2 0 01-2 2h-5l-4 4v-4H6a2 2 0 01-2-2V6z", extra: "M9.2 13l2.1-6h1.4l2.1 6M10 11h4" },
  "square.grid.2x2": { d: "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z" },
  "square.and.arrow.down": { d: "M12 3v12M7.5 10.5L12 15l4.5-4.5", extra: "M4 16v3a2 2 0 002 2h12a2 2 0 002-2v-3" },
  "exclamationmark.triangle": { d: "M10.3 4.2L2.8 17.3A2 2 0 004.5 20.3h15a2 2 0 001.7-3L13.7 4.2a2 2 0 00-3.4 0z", extra: "M12 9v4.5M12 17h.01" },
  "play.rectangle": { d: "M3 6a2 2 0 012-2h14a2 2 0 012 2v12a2 2 0 01-2 2H5a2 2 0 01-2-2V6z", extra: "M10 9l5 3-5 3V9z" },
  "calendar": { d: "M4 7a2 2 0 012-2h12a2 2 0 012 2v12a2 2 0 01-2 2H6a2 2 0 01-2-2V7z", extra: "M8 3v4M16 3v4M4 10h16" },
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
function closeMenu() { $("#menu-root").replaceChildren(); setTimeout(() => Autoplay.schedule(), 0); }
/** items: {label, icon, danger, head, sep, on} — `head` renders a section label, `sep` a rule. */
function popMenu(anchor, items, opts = {}) {
  setTimeout(() => Autoplay.schedule(), 0);
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
    // BACK TO A COMMAND, deliberately. A `havenmedia://` scheme handler streamed the bytes and
    // avoided base64 — and cost far more than it saved: the synchronous form runs on the UI thread
    // (a full AEAD open per tile froze the window at launch), and the ASYNCHRONOUS form finishes
    // after WebKit has cancelled the request, where responding to a stopped task throws an uncaught
    // ObjC exception and aborts the process. A command has neither failure mode: it already runs on
    // Tauri's thread pool, and a cancelled caller just drops the value.
    //
    // The original motivation has also mostly gone: imported stills are optimized now (~100KB
    // median rather than multi-megabyte originals), so the base64 copy this makes is a fraction of
    // what it used to be.
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
  const th = ThumbIndex.thumbFor(ref);
  if (th) {
    invoke("media_data_url", { circleId, reference: th }).then((u) => {
      if (!u || !box.isConnected) return;
      // SHARP, full opacity, nothing over it. The thumb IS the picture, just smaller — blurring it
      // behind a spinner made a post that was loading fine look broken. Apple/Android parity.
      // Sized exactly like the real fitted media (`.media-page > img`): auto/auto capped by the page
      // cap, so it keeps its own aspect and the box hugs it. IN FLOW, not absolutely positioned —
      // that is what gives the box a size at all.
      const pic = el("img", {
        src: u,
        style: "display:block;width:auto;height:auto;max-width:100%;max-height:var(--page-cap);z-index:0",
      });
      // GIVE THE BOX A SIZE OF ITS OWN before hiding the front layer.
      //
      // The picture is absolutely positioned (inset:0), so it contributes nothing to layout — the
      // spinner + "Still loading…" underneath it was the ONLY in-flow content. Hiding that left a
      // flex item with no content at all, which collapsed to its own padding: measured at 38x120,
      // 18px of padding either side and the 120px min-height. With `border-radius:16px` on a box
      // that narrow the result is a PILL, filled by a 36px-wide vertical sliver of the photo.
      //
      // So: fill the page's width, take the picture's own aspect, and drop the padding/min-height
      // that were only ever there to frame a spinner.
      box.style.padding = "0";
      box.style.minHeight = "0";
      box.style.border = "0";
      box.prepend(pic);
      front.style.display = "none";   // the picture is the status; no caption over it
    }).catch(() => {});
  }
  const front = el("div", { class: "col", style: "position:relative;z-index:1;align-items:center;gap:6px" });
  box.append(front);
  const waiting = () => front.replaceChildren(
    el("div", { class: "spinner" }),
    el("div", { class: "muted small" }, isVideo ? t("video_still_loading") : t("still_loading")));
  // `gone` is terminal and ACTIONABLE, so it always shows — even over a thumb. Re-show the front
  // layer the thumb hid: the difference between "on its way" (say nothing) and "you need to do
  // something" is the only thing chrome should be marking here.
  const showFront = () => { front.style.display = ""; };
  const gone = () => (showFront(), front.replaceChildren(
    el("div", { class: "muted small" }, t("not_available_yet")),
    el("button", { class: "btn small", onclick: () => {
      invoke("media_download", { reference: ref }).catch(() => {});
      start();
    } }, t("retry"))));
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
      box.replaceChildren(el("div", { class: "spinner" }), el("div", { class: "muted small" }, t("downloading")));
      return;
    }
    if (mode === "gone") {
      const wanted = await invoke("media_is_wanted", { reference: ref }).catch(() => false);
      box.replaceChildren(
        el("div", { class: "muted small" }, t("no_longer_available")),
        el("button", { class: "btn small", onclick: () => start() }, t("retry")),
        wanted
          ? el("div", { class: "muted small" }, "🔔 " + t("tell_when_back"))
          : post && !post.isMe
            ? el("button", { class: "btn small primary", onclick: askBack }, t("ask_for_it_back"))
            : null);
      return;
    }
    box.replaceChildren(
      el("button", { class: "btn small primary", onclick: () => start() },
        "⬇ " + t("download_size", fmtBytes(bytes))),
      el("div", { class: "muted small" }, t("removed_to_save_space")));
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
  // Leaving the feed has to silence it. `suspended()` knows the rule; nothing was asking it at the
  // moment the view changed, so the centred post kept playing under the new tab.
  Autoplay.schedule();
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
      icon("chevron.down", "chev"), el("span", { id: "tb-circle-name" }, state.activeCircleName || t("my_circle")));
    slot.replaceChildren(pill,
      el("button", { class: "icon-btn glass tint-pink pink", title: t("manage_circle"), "aria-label": t("manage_circle"),
        onclick: () => circleSheet() }, icon("person.2.fill")));
  } else if (state.view === "you") {
    slot.replaceChildren(el("button", { class: "icon-btn glass", title: t("settings"), "aria-label": t("settings"),
      onclick: () => settingsSheet() }, icon("gearshape.fill")));
  } else if (state.view === "messages" && !state.activeDm) {
    // macOS `MessagesView`'s toolbar: a `square.and.pencil` glass chip that opens the contact picker.
    slot.replaceChildren(el("button", { class: "icon-btn glass", title: t("new_message"), "aria-label": t("new_message"),
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
      label: Hidden.showHidden ? t("hide_hidden_posts") : t("show_hidden_posts", Hidden.ids.size),
      icon: Hidden.showHidden ? "eye.slash" : "eye",
      on: () => { Hidden.toggle(); renderFeed(); },
    });
  }
  items.push({ label: t("new_circle_menu"), icon: "plus.circle", on: newCircleDialog });
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
/** A `dm:` circle id encodes its participants as sorted node hexes joined by `-`, so 3+ hexes means
 *  a GROUP thread. Derived from the id alone so it needs no store lookup. Apple/Android parity. */
function isGroupDm(circleId) {
  const id = String(circleId || "");
  if (!id.startsWith("dm:")) return false;
  return id.slice(3).split("-").filter((p) => p.length === 64).length > 2;
}

async function activityPanel() {
  const a = await invoke("activity").catch(() => ({ rows: [], seen_at: 0 }));
  const rows = a.rows || [], seenAt = a.seen_at || 0;
  invoke("mark_activity_seen").catch(() => {});
  const verb = (r) => {
    switch (r.kind) {
      case "react": return t("reacted", r.emoji || "👍");
      case "comment": return t("commented");
      case "vote": return t("voted");
      case "story": return t("shared_a_story");
      // A `dm:` id encodes its participants as sorted node hexes joined by `-`, so 3+ means a GROUP
      // thread, where "sent you a message" is wrong — nobody sent it to you specifically.
      case "dm": return isGroupDm(r.circleId) ? t("messaged_the_group") : t("sent_you_a_message");
      default: return t("posted_verb");
    }
  };
  const list = el("div", { class: "thread-list" });
  if (!rows.length) {
    list.append(el("div", { class: "empty" },
      el("div", { class: "h" }, t("nothing_yet")),
      el("div", {}, t("activity_empty_sub"))));
  }
  // WINDOWED. An account that has been running a while accumulates thousands of activity rows, and
  // building a DOM node for every one of them froze the panel on open for what looked like a hang.
  // Render a page at a time; older rows cost nothing until asked for. Apple parity (ActivityView).
  const PAGE = 40;
  let shown = 0;
  const row = (r) => {
    const unread = r.created_at > seenAt;
    const title = r.kind === "app" ? (r.actor_name || "Haven") : `${r.actor_name || t("someone")} · ${verb(r)}`;
    return el("div", { class: "thread-item", onclick: async () => { closeModal(); if (r.link) await routeDeepLink(r.link); } },
      el("div", { class: "avatar" }, r.kind === "app" ? "🔔" : initials(r.actor_name || "?")),
      el("div", { style: "flex:1;min-width:0" },
        el("div", { class: "name" + (unread ? " unread" : "") }, title),
        el("div", { class: "preview" + (unread ? " unread" : ""), style: "white-space:nowrap;overflow:hidden;text-overflow:ellipsis" }, r.snippet || "")),
      el("div", { class: "muted small" }, relTime(r.created_at)),
    );
  };
  const more = el("button", { class: "btn small", onclick: () => showMore() }, t("show_older"));
  const showMore = () => {
    const next = rows.slice(shown, shown + PAGE);
    shown += next.length;
    for (const r of next) list.insertBefore(row(r), more);
    more.textContent = t("show_older_left", rows.length - shown);
    if (shown >= rows.length) more.remove();
  };
  if (rows.length) { list.append(more); showMore(); }
  sheet(t("activity"), list);
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
  if (!s || !s.started) return t("offline_posts_sync");
  const paths = [];
  if (s.internet_active) paths.push(t("internet"));
  if (s.hosting) paths.push(t("relaying_here"));
  if (!paths.length) return t("online_looking");
  return t("connected") + " · " + paths.join(" + ");
}

// ---- Deep links ------------------------------------------------------------------------
// Four shapes reach us, and they must be told apart BEFORE anything routes them:
//   https://wemiller.com/apps/haven/#p/<circleId>.<postId>   a shared post — the form we emit
//   https://wemiller.com/apps/haven/#s/<circleId>.<postId>   a shared story (DM reply pointer)
//   haven://p/<circleId>/<postId>                            the same post, legacy scheme — parsed forever
//   haven://s/<circleId>/<postId>                            the same story, on-device form
//   https://wemiller.com/apps/haven/#<id>.<verify>           an invite (also haven://invite#<id>.<verify>)
// An invite's payload is ALSO `<a>.<b>` in the fragment, so an unguarded invite check swallows every
// post link — that exact bug is live in android/…/ShareInbox.kt:49. Hence: post/story markers first.
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
  /** Shareable story pointer for a DM story-reply — `#s/<c>.<p>`, same privacy rules as posts. */
  storyLink(circleId, postId) {
    return `https://${HAVEN_SITE.host}${HAVEN_SITE.linkPath}/#s/${this._token(circleId)}.${this._token(postId)}`;
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
  /** → {circleId, postId} for either story form (`haven://s/…` or web `#s/…`). */
  story(raw) {
    let u;
    try { u = new URL((raw || "").trim()); } catch (_) { return null; }
    if (u.protocol === "haven:") {
      if (u.hostname !== "s") return null;
      const parts = u.pathname.split("/").filter(Boolean);
      return parts.length >= 2 ? this._decode(parts[0], parts[1]) : null;
    }
    if (u.protocol !== "https:") return null;
    if (u.hostname.toLowerCase() !== HAVEN_SITE.host || !u.pathname.startsWith(HAVEN_SITE.path)) return null;
    const frag = u.hash.replace(/^#/, "");
    if (!frag.startsWith("s/")) return null;
    const body = frag.slice(2);
    const dot = body.indexOf(".");
    return dot > 0 ? this._decode(body.slice(0, dot), body.slice(dot + 1)) : null;
  },
  /** First story pointer in free-form body text. */
  firstStoryIn(text) {
    const s = String(text || "");
    for (const token of s.split(/\s+/)) {
      const hit = this.story(token);
      if (hit) return { ...hit, raw: token };
    }
    const m = s.match(/https?:\/\/[^\s]+/) || s.match(/haven:\/\/s\/[^\s]+/);
    if (m) {
      const hit = this.story(m[0]);
      if (hit) return { ...hit, raw: m[0] };
    }
    return null;
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
  /**
   * Resolve story for a DM message: explicit deep link, else retroactive match for legacy
   * media-only story replies (resealed attach without a pointer).
   * liveStories: [{circleId, id, author_short, is_me, created_at, has_media}]
   * keptMine: [{id, createdAt}]
   */
  storyReplyTarget(msg, { peerHex, liveStories, keptMine }) {
    if (msg.unsent) return null;
    const hit = this.firstStoryIn(msg.body || "");
    if (hit) return { circleId: hit.circleId, postId: hit.postId, raw: hit.raw };
    return this._inferLegacyStoryReply(msg, peerHex, liveStories || [], keptMine || []);
  },
  _inferLegacyStoryReply(msg, peerHex, liveStories, keptMine) {
    const visual = displayMediaRefs(msg.media || []).filter((r) => !isAudioRef(r) && !String(r).startsWith("geo:"));
    if (visual.length !== 1) return null;
    const replyAt = Number(msg.created_at) || 0;
    const dayMs = 24 * 60 * 60 * 1000;
    const lookingForMine = !msg.is_me;
    const peer = (peerHex || "").toLowerCase();
    const peerShort = peer.slice(0, 12);
    const cands = [];
    for (const s of liveStories) {
      if (!s.has_media) continue;
      const created = Number(s.created_at) || 0;
      if (created > replyAt || replyAt - created > dayMs) continue;
      if (lookingForMine) {
        if (!s.is_me) continue;
      } else {
        const a = String(s.author_short || "").toLowerCase();
        const ok = (peerShort && (a.startsWith(peerShort) || peerShort.startsWith(a)))
          || (peer && (peer.startsWith(a) || a.startsWith(peer.slice(0, a.length))));
        if (!ok) continue;
      }
      cands.push({ circleId: s.circleId, postId: s.id, createdAt: created });
    }
    if (lookingForMine) {
      for (const k of keptMine) {
        const created = Number(k.createdAt || k.created_at) || 0;
        if (created > replyAt || replyAt - created > dayMs * 7) continue;
        cands.push({ circleId: "default", postId: k.id, createdAt: created });
      }
    }
    if (!cands.length) return null;
    cands.sort((a, b) => b.createdAt - a.createdAt);
    return { circleId: cands[0].circleId, postId: cands[0].postId, raw: null };
  },
};

/** Route a link from the OS or the Connect paste box. Post/story links are discriminated FIRST, so
 *  one can never be mistaken for an invite. Returns "post"|"story"|"invite"|…|null. */
async function routeDeepLink(raw) {
  const p = DeepLink.post(raw);
  if (p) { await openPostLink(p.circleId, p.postId); return "post"; }
  const s = DeepLink.story(raw);
  if (s) { await openStoryLink(s.circleId, s.postId); return "story"; }
  const m = DeepLink.message(raw);
  if (m) { await openDmThread(m.circleId); return "dm"; }
  const c = DeepLink.circle(raw);
  if (c) {
    const circles = await invoke("circles").catch(() => []);
    if (!circles.some((x) => x.id === c.circleId)) { toast(t("link_circle_not_in")); return "circle"; }
    state.activeCircle = c.circleId;
    state.activeDm = null;
    switchView("circle");
    return "circle";
  }
  try { return (await invoke("connect_by_link", { uri: (raw || "").trim() })) ? "invite" : null; }
  catch (_) { return null; }
}

/** Open a deep-linked story in the viewer (music, framing, progress) or show "Story expired". */
const STORY_LIFETIME_MS = 24 * 60 * 60 * 1000;
function isPastStoryWindow(createdAt) {
  const age = Date.now() - Number(createdAt || 0);
  return age > STORY_LIFETIME_MS;
}
async function openStoryLink(circleId, postId) {
  // Kept first (author deliberately held it past 24h).
  const kept = await invoke("kept_stories").catch(() => []);
  const k = (kept || []).find((x) => x.id === postId);
  if (k && (k.media || []).length) {
    const revived = {
      id: k.id, body: k.body || "", media: k.media || [], created_at: k.createdAt || k.created_at || 0,
      is_me: true, story: true, unsent: false, author_name: t("you"),
      music: k.musicCatalogId ? {
        catalog_id: k.musicCatalogId, title: k.musicTitle || "", artist: k.musicArtist || "",
        artwork_url: k.musicArtworkUrl || "", duration_ms: k.musicDurationMs || 0,
      } : null,
      _circle: circleId,
    };
    viewStories([revived], 0);
    return;
  }
  // Live stories — hard 24h window.
  let msgs = await invoke("messages", { circleId }).catch(() => []);
  let stories = (msgs || []).filter((i) => i.story && !i.unsent && (i.media || []).length
    && !isPastStoryWindow(i.created_at));
  let idx = stories.findIndex((i) => i.id === postId);
  if (idx >= 0) {
    stories.forEach((s) => { s._circle = s._circle || circleId; });
    viewStories(stories, idx);
    return;
  }
  // Expired (and not kept).
  const card = el("div", { class: "col", style: "align-items:center;padding:28px;min-width:min(88vw,360px);text-align:center" },
    el("div", { style: "font-size:36px" }, "⏱"),
    el("h2", { style: "margin:12px 0 6px" }, t("story_no_longer_available")),
    el("p", { class: "muted", style: "margin:0 0 16px" }, t("story_expired_body")),
    el("button", { class: "primary", onclick: () => closeModal() }, t("done")));
  modal(card);
}

// Open a DM thread from a deep link (haven://m/…): resolve its display name from the thread list
// and land in Messages with the thread open — the same plumbing a row tap uses.
async function openDmThread(circleId) {
  const threads = await invoke("dm_threads").catch(() => []);
  const t = threads.find((x) => x.circle_id === circleId);
  if (!t) { toast(t("convo_not_on_device")); state.activeDm = null; switchView("messages"); return; }
  state.activeDm = { id: t.circle_id, name: t.name };
  switchView("messages");
}

// Open the post a link points at: switch to its circle, then surface that post in the feed. Desktop has
// no single-post view (iOS opens a PostLinkView sheet), so "surface" = scroll it into view and flash it.
// Every way this can fail says WHICH way it failed — a link that quietly does nothing reads as a broken
// app, and the post genuinely may not be here: the link is a pointer, not a key.
async function openPostLink(circleId, postId) {
  const circles = await invoke("circles").catch(() => []);
  if (!circles.some((c) => c.id === circleId)) { toast(t("post_circle_not_in")); return; }
  state.activeCircle = circleId;
  state.activeDm = null;
  state.focusPost = null;
  const items = await invoke("feed", { circleId }).catch(() => []);
  // An id that names a COMMENT resolves to the post that CARRIES it (Apple `FeedStore.post`, Android
  // `PostLinkScreen`). Comments are not top-level feed items, so a reaction on / reply to one — which
  // the core allows on any event id — produced an activity row and a push that matched nothing here.
  const it = items.find((i) => i.id === postId)
    || items.find((i) => (i.comments || []).some((c) => c.id === postId));
  if (it && !it.unsent && !it.story) {
    if (Hidden.has(it.id)) Hidden.showHidden = true;   // opening a link is an explicit ask — don't hide it
    state.focusPost = it.id;
  }
  switchView("circle");   // land them in the right circle either way — but never pretend we found the post
  if (!it) toast(t("post_not_reached"));
  else if (it.unsent) toast(t("post_was_unsent"));
  else if (it.story) toast(t("link_points_story"));
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
        el("div", { class: "nudge-title" }, t("give_circle_relay")),
        el("div", { class: "nudge-sub" }, t("relay_nudge_sub")),
      ),
    ),
    el("button", { class: "nudge-x", title: t("dismiss"), onclick: () => { RelayNudge.dismiss(circleId); card.remove(); } }, "✕"),
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
    el("h2", {}, t("set_up_relay")),
    el("div", { class: "col", style: "max-height:64vh;overflow:auto;gap:8px" },
      point("📥", t("wt_nobody_online_t"),
        t("wt_nobody_online_b")),
      point("🖼️", t("wt_media_t"),
        t("wt_media_b")),
      point("🔀", t("wt_routes_t"),
        t("wt_routes_b")),
      point("🔒", t("wt_cant_read_t"),
        [t("wt_cant_read_b"),
         el("a", { href: "https://wemiller.com/apps/haven/docs/#relay-idea", target: "_blank", style: "color:var(--pink);text-decoration:underline" }, t("learn_more"))]),

      heading(t("wt_how_heading")),
      point("🖥️", t("wt_easy_t"),
        t("wt_easy_b")),
      point("⌨️", t("wt_headless_t"),
        t("wt_headless_b")),
      point("📦", t("wt_spare_t"),
        t("wt_spare_b")),

      heading(t("wt_counton_heading")),
      point("🔑", t("wt_only_t"),
        t("wt_only_b")),
      point("⚛️", t("wt_pq_t"),
        [t("wt_pq_b"),
         el("a", { href: "https://wemiller.com/apps/haven/docs/#encryption", target: "_blank", style: "color:var(--pink);text-decoration:underline" }, t("learn_more"))]),
    ),
    // wrap: three buttons don't fit the sheet on a narrow window, and a clipped "Not now" is a trap.
    el("div", { class: "row wrap", style: "margin-top:14px" },
      el("button", { class: "btn primary", onclick: async () => {
        try { await invoke("start_hosting"); toast(t("pc_now_relay")); } catch (e) { toast("" + e); }
        $("#modal-root").replaceChildren();
        renderFeed();
      } }, t("use_pc_as_relay")),
      el("button", { class: "btn ghost", onclick: () => relaySheet() }, t("add_relay_running")),
      el("button", { class: "btn ghost", style: "margin-left:auto", onclick: () => $("#modal-root").replaceChildren() }, t("not_now")),
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
  return CircleNick.get(id) || real || t("my_circle");
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
/// Repair an account imported into twice — once per app session, on the first feed that has posts.
/// A no-op when nothing is duplicated; the rule lives in Rust and is shared with iOS and Android.
let sweptDuplicates = false;
function sweepDuplicateImportsOnce() {
  if (sweptDuplicates || !(state.feedItems || []).length) return;
  sweptDuplicates = true;
  invoke("sweep_duplicate_imports", { circleId: state.activeCircle })
    .then((n) => { if (n > 0) renderFeed(); })
    .catch(() => {});
}

async function renderFeed() {
  const root = $("#view-circle");
  // Read BEFORE any await: this function rebuilds the scroller's contents wholesale, and the
  // position has to be captured while the old content is still there.
  const keepScroll = root.scrollTop;
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
      class: "icon-btn glass", "data-sound-toggle": "1",
      title: state.videoSoundOn ? t("mute_all_videos") : t("unmute_all_videos"),
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
  // Declared here rather than at the paginator below: the signature has to hash the same window
  // the paginator renders.
  const FEED_PAGE = 25;
  const sig = JSON.stringify({
    c: state.activeCircle, name: state.activeCircleName,
    hidden: Hidden.showHidden, snd: state.videoSoundOn, status: connectionText(state.status),
    member: (active || {}).member_count || 0,
    pending: pending.length,
    upgrades: theirUpgrades.map((o) => o.new_circle_id).join(",") + "|" + (canOfferUpgrade ? 1 : 0),
    sens: [...state.sensitive].sort().join(","),
    // ONLY THE ITEMS ACTUALLY ON SCREEN.
    //
    // Hashing the whole array meant an archive import busted the signature on every single post —
    // and those posts are BACKDATED, so they sort below everything visible and change nothing the
    // reader can see. The result was a full teardown and rebuild of the 25 on-screen cards, with
    // every image re-hydrated through the main-thread scheme handler, once per imported item. That
    // is the flashing.
    //
    // The tail is not ignored, it simply does not force a repaint: `state.feedItems` (refreshed
    // below whether or not the DOM is touched) is what the paginator reads, so scrolling reaches
    // everything that has landed.
    items: items.slice(0, Math.max(state.feedRendered || 0, FEED_PAGE)).map((i) => [i.id, i.body, (i.media || []).join("|"), i.unsent ? 1 : 0, i.edited ? 1 : 0,
      (i.reactions || []).map((r) => r.emoji + r.count + (r.mine ? "1" : "0")).join(","),
      (i.comments || []).map((c) => (c.author_name || "") + c.created_at + (c.body || "")).join("~"),
      i.music ? i.music.title + "·" + i.music.artist : "",
      (reportsByTarget[i.id] || []).length]),
    stories: storyItems.map((s) => [s.id, s.author_name, (s.media || []).join("|"), s.created_at]),
  });
  // Refreshed even on the early-out: the reader scrolls into these without a repaint.
  state.feedItems = items;
  if (state.feedSig === sig && !state.focusPost && root.querySelector(".feed-list")) {
    state.feedNudge?.();   // head unchanged, but a tail may have landed — append, never repaint
    return;
  }
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
      el("div", { class: "h" }, t("nothing_here_yet")),
      el("div", {}, t("feed_empty_sub"))));
  }
  // RENDER IN PAGES, not all at once.
  //
  // This built a card for every post in the circle, which was fine while a circle held a few dozen
  // and became the reason the window stopped responding once it held a few hundred: an archive
  // import turns a 20-post feed into a 372-post one, and each card carries its own media elements.
  // WebKit then has to lay out and paint the lot before anything can scroll. Apple's feed is a
  // LazyVStack and only ever builds what is visible; this is the same idea with the tools a webview
  // has.
  //
  // The sentinel appends the next page as it comes into view, so scrolling stays continuous and no
  // "show more" button is needed. rootMargin starts the work a screen early, so the next page is
  // usually already there by the time it would be reached.
  let rendered = 0;
  const sentinel = el("div", { style: "height:1px" });
  const renderPage = () => {
    // Reads state.feedItems, NOT the `items` captured when this feed was built: a refresh that
    // left the DOM alone still replaced that array, and the next page has to come from the fresh
    // one or posts that arrived mid-scroll are unreachable until something forces a rebuild.
    const all = state.feedItems || items;
    const next = all.slice(rendered, rendered + FEED_PAGE);
    rendered += next.length;
    state.feedRendered = rendered;      // the window the signature above hashes
    for (const it of next) {
      list.insertBefore(postCard(it, state.activeCircle, reportsByTarget[it.id] || []), sentinel);
    }
    sweepDuplicateImportsOnce();              // first page with posts → repair a doubled import
    hydrateMedia(list, state.activeCircle);   // only the cards just added resolve their refs
    Autoplay.track(list);
    Autoplay.schedule();                      // a new page may hold the centred post
    // STOP once everything is rendered. Dropping the old disconnect (so a late tail could still
    // page in) left the observer live with the sentinel pinned at the end of the list — each
    // appended page left it in view, so it fired again at once and walked the WHOLE feed in a
    // single burst. That is both "it isn't lazy loading" and a large part of the stall.
    // `feedNudge` re-arms it when a tail actually lands.
    if (rendered >= all.length) {
      feedObserver?.disconnect();
      // REACHED THE END OF WHAT WE HOLD → ask the authors for the page before it.
      //
      // Lazy history: adding someone no longer ships their whole backlog, so the tail of the feed is
      // the cue to fetch more, exactly the way media is fetched when a tile appears. Idempotent per
      // cursor on the Rust side, so paging to the end repeatedly does not re-ask.
      const oldest = all.length ? all[all.length - 1].createdAt : 0;
      if (oldest) invoke("request_older_history", { circleId: state.activeCircle, oldestCreatedAt: oldest }).catch(() => {});
    }
  };
  // Page in a tail that arrived AFTER this feed was built, without a teardown.
  //
  // The sentinel used to be removed and the observer disconnected once everything was rendered.
  // With the DOM now left alone for tail-only changes, that combination stranded them: a short
  // feed rendered fully, the observer went away, and the posts an import appended afterwards had
  // nothing left to page them in and nothing to force a rebuild either. The sentinel now stays,
  // and this runs the same "is it near the viewport" test its rootMargin does.
  state.feedNudge = () => {
    if ((state.feedItems || []).length <= rendered) return;
    // Items exist beyond what is rendered: re-arm the observer (disconnected when the list ran out)
    // and only page one in if the sentinel is genuinely near the viewport.
    if (feedObserver) feedObserver.observe(sentinel);
    if (sentinel.getBoundingClientRect().top < window.innerHeight + 800) renderPage();
  };
  let feedObserver = null;
  if (items.length) {
    list.append(sentinel);
    feedObserver = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) renderPage();
    }, { rootMargin: "800px 0px" });
    feedObserver.observe(sentinel);
    renderPage();
  }

  const composer = buildComposer(
    (body, music, muteVideo, retentionSecs) => invoke("post", { circleId: state.activeCircle, body, media: withThumbMarkers(state.attachments), music, muteVideo, retentionSecs }),
    t("share_something"),
    {
      circleId: state.activeCircle,
      floating: true,
      onSchedule: (body, music, muteVideo, sendAtMs) => invoke("schedule_message", { kind: "post", circleId: state.activeCircle, body, media: withThumbMarkers(state.attachments), music, muteVideo, sendAtMs }),
    },
  );

  root.replaceChildren(el("div", { class: "col-wrap" }, list));
  $("#composer-slot").replaceChildren(composer);
  hydrateMedia(root, state.activeCircle);
  // Put the reader back where they were. `.view` is the scroller and this function replaces its
  // entire contents, so without this every background refresh — a sync landing, and during an
  // import a nudge every couple of seconds — throws the reader back to the top. Pages have to be
  // built back up first: only the first 25 cards exist right after the rebuild, so a deep offset
  // would otherwise clamp to the bottom of a short list and read as a jump of its own.
  if (keepScroll > 0) {
    let guard = 0;
    while (root.scrollHeight < keepScroll + root.clientHeight && rendered < items.length && guard++ < 60) {
      renderPage();
    }
    root.scrollTop = keepScroll;
  }
  if (state.focusPost) focusPostCard(root, state.focusPost);   // arrived here from a post link
  Autoplay.schedule();
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
        el("div", { class: "nudge-title" }, pending.length === 1 ? t("connection_request_one") : t("connection_requests_many", pending.length)),
        el("div", { class: "nudge-sub" }, t("click_to_review")),
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
        el("div", { class: "nudge-title" }, t("upgrade_this_circle")),
        el("div", { class: "nudge-sub" }, t("upgrade_circle_sub")),
      ),
    ),
    el("button", {
      class: "pill-btn nudge-cta",
      onclick: async () => {
        const id = await invoke("upgrade_circle", { circleId }).catch(() => null);
        if (id) state.activeCircle = id;
        renderFeed();
      },
    }, t("upgrade")),
  );
}

/** Someone is asking us to follow their replacement. Names them, and says plainly what we can't
 *  vouch for — following is only ever this button, never automatic. */
function followUpgradeCard(circleId, o) {
  return el("div", { class: "nudge-banner" },
    el("div", { class: "nudge-body", style: "cursor:default" },
      el("span", { class: "nudge-icon" }, icon("person.2.fill")),
      el("div", { style: "min-width:0" },
        el("div", { class: "nudge-title" }, t("is_upgrading", o.from_name, o.name)),
        el("div", { class: "nudge-sub" }, t("follow_upgrade_sub")),
      ),
    ),
    el("button", {
      class: "pill-btn nudge-cta",
      onclick: async () => {
        const ok = await invoke("accept_circle_upgrade", { circleId, newCircleId: o.new_circle_id }).catch(() => false);
        if (ok) state.activeCircle = o.new_circle_id;
        renderFeed();
      },
    }, t("follow")),
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
  tray.append(el("button", { class: "story-ring add", title: t("add_to_your_story"), onclick: addStoryDialog },
    el("div", { class: "ring" }, el("div", {}, icon("camera.fill"))),
    el("div", { class: "nm" }, t("add"))));
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
      el("div", { class: "nm" }, it.is_me ? t("you") : name.split(" ")[0])));
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
function buildComposer(onPost, placeholder = t("share_something"), opts = {}) {
  const circleId = opts.circleId || state.activeCircle;
  let music = null;
  let muteVideo = false;
  // Disappearing messages. Desktop had no way to SET one — the engine dropped a hard-coded `None`
  // into every post/DM — while Apple and Android both offered it, so the same account could author a
  // disappearing post on a phone and not on a laptop. Same durations as Apple's "Disappears after…".
  let retentionSecs = null;
  const ta = el("textarea", { class: "composer-field glass", placeholder, rows: 1 });
  // Grow with the text up to the CSS max-height, then scroll — the macOS field is `axis: .vertical`.
  const autoGrow = () => { ta.style.height = "auto"; ta.style.height = Math.min(ta.scrollHeight, 132) + "px"; };
  ta.addEventListener("input", autoGrow);
  const previews = el("div", { class: "attach-preview" });
  const musicRow = el("div", {});
  const retentionRow = el("div", {});
  const retentionLabel = (secs) => secs < 3600 ? `${Math.round(secs / 60)}m`
    : secs < 86400 ? `${Math.round(secs / 3600)}h`
    : secs < 604800 ? `${Math.round(secs / 86400)}d` : `${Math.round(secs / 604800)}w`;
  const drawRetention = () => {
    retentionRow.replaceChildren(retentionSecs
      ? el("div", { class: "song-chip", style: "margin-top:0" },
          el("span", { class: "note" }, "\u23F1"),
          el("div", { style: "flex:1;min-width:0" }, t("disappears_label", retentionLabel(retentionSecs))),
          el("span", { class: "x", style: "position:static;cursor:pointer",
                       onclick: () => { retentionSecs = null; drawRetention(); } }, "\u00D7"))
      : null);
  };
  const muteBtn = el("button", { class: "btn small ghost", style: "display:none", onclick: () => { muteVideo = !muteVideo; muteBtn.textContent = muteVideo ? t("video_muted") : t("mute_video"); muteBtn.classList.toggle("primary", muteVideo); } }, t("mute_video"));
  const drawPreviews = () => {
    previews.replaceChildren(...state.attachments.map((a, i) =>
      el("div", { class: "chip" },
        a.isAudio ? el("div", { style: "width:56px;height:56px;border-radius:10px;background:var(--panel2);display:flex;align-items:center;justify-content:center;font-size:22px" }, "🎙️")
          : a.isVideo ? el("video", { src: a.url, muted: "" }) : el("img", { src: a.url }),
        el("span", { class: "x", onclick: () => { state.attachments.splice(i, 1); drawPreviews(); } }, "×"),
      )));
    const hasVideo = state.attachments.some((a) => a.isVideo);
    muteBtn.style.display = hasVideo ? "" : "none";
    if (!hasVideo) { muteVideo = false; muteBtn.textContent = t("mute_video"); muteBtn.classList.remove("primary"); }
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
    if (s === "local") { syncDot.style.background = "#EF4444"; label.textContent = t("device_only"); syncBadge.classList.remove("hide"); }
    else if (s === "syncing") { syncDot.style.background = "#F59E0B"; label.textContent = t("syncing"); syncBadge.classList.remove("hide"); }
    else syncBadge.classList.add("hide");
  };
  if (state.syncTimer) clearInterval(state.syncTimer);   // only one composer at a time — no leak across re-renders
  refreshSync();
  state.syncTimer = setInterval(refreshSync, 2500);

  const send = async () => {
    const body = ta.value.trim();
    if (!body && !state.attachments.length && !music) return;
    await onPost(body, music, muteVideo, retentionSecs);
    ta.value = ""; autoGrow();
    state.attachments = [];
    music = null;
    muteVideo = false;
    // Retention is per-message here, matching Apple's composer (its DM sheet is the sticky one).
    retentionSecs = null;
    drawPreviews();
    drawMusic();
    drawRetention();
    toast(t("posted_toast"));
  };
  // Enter sends, Shift+Enter is a newline — the desktop convention, and the field is a pill you
  // can't see a "Post" button next to at rest.
  ta.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); }
  });

  // The `+` menu — every attachment path the macOS composer's Menu holds, in its order.
  const plus = el("button", { class: "composer-plus", title: t("attach"), "aria-label": t("attach") }, icon("plus"));
  plus.addEventListener("click", () => popMenu(plus, [
    { label: t("photo_or_video"), icon: "photo", on: () => fileInput.click() },
    { label: t("camera"), icon: "camera.fill", on: async () => { const r = await cameraDialog(circleId); if (r) addAttachment(r.ref, r.isVideo, false); } },
    { label: t("voice"), icon: "mic", on: async () => { const r = await recordVoice(circleId); if (r) addAttachment(r, false, true); } },
    // The caption is read WHEN THE PICKER OPENS, not when this menu was built — the user usually
    // types the post first and reaches for a song after.
    { label: t("add_a_song"), icon: "music.note", on: () => musicDialog((m) => { music = m; drawMusic(); },
      { caption: () => ta.value }) },
    { sep: true },
    { label: t("disappears_after"), icon: "timer", on: () => popMenu(plus, [
      { label: t("off"), on: () => { retentionSecs = null; drawRetention(); } },
      { label: t("one_hour"), on: () => { retentionSecs = 3600; drawRetention(); } },
      { label: t("one_day"), on: () => { retentionSecs = 86400; drawRetention(); } },
      { label: t("one_week"), on: () => { retentionSecs = 604800; drawRetention(); } },
    ]) },
    opts.onSchedule ? { sep: true } : null,
    opts.onSchedule ? { label: t("send_later"), icon: "clock", on: () => {
      const body = ta.value.trim();
      if (!body && !state.attachments.length && !music) { toast(t("write_something_first")); return; }
      scheduleDialog((ms) => {
        opts.onSchedule(body, music, muteVideo, ms);
        ta.value = ""; autoGrow(); state.attachments = []; music = null; muteVideo = false; drawPreviews(); drawMusic();
        toast(t("scheduled_toast"));
      });
    } } : null,
  ]));

  const bar = el("div", { class: "composer" + (opts.floating ? " floating" : "") },
    el("div", { class: "composer-meta" }, syncBadge),
    previews,
    musicRow,
    retentionRow,
    el("div", { class: "row wrap", style: "gap:6px" }, muteBtn),
    el("div", { class: "composer-row" },
      plus,
      ta,
      el("button", { class: "composer-send", title: t("post_btn"), "aria-label": t("post_btn"), onclick: send }, icon("paperplane.fill")),
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

/** SONG PICKER — search the catalog, or take a suggestion based on what the post says.
 *
 *  This used to be three text boxes: paste a link, type a title, type an artist. Meanwhile
 *  `songsuggest.rs` had carried a full iTunes-backed search AND a caption-driven suggester since
 *  the importer needed one — none of it exposed to the frontend. Apple and Android both have real
 *  pickers; this is the wiring that was never done, not a new capability.
 *
 *  `ctx` supplies what the suggestions are FOR: `{ caption, createdAt, genre }`. Without it the tab
 *  is still offered (the composer's field may be empty when the picker opens) and simply leans on
 *  the date. Same source on every platform — the free, unauthenticated iTunes Search API — so a
 *  song attached here is the same TrackRef a phone would attach.
 */
function musicDialog(onPick, ctx = {}) {
  let tab = "search";
  let preview = null;                       // one <audio> at a time; auditioning is a comparison
  let playingUrl = null;
  const results = el("div", { class: "col", style: "gap:6px;max-height:46vh;overflow-y:auto" });
  const input = el("input", { placeholder: t("search_songs"), style: "flex:1" });
  const searchRow = el("div", { class: "row", style: "gap:8px" }, input);
  const tabs = el("div", { class: "picker-tabs" });

  const stopPreview = () => { if (preview) { preview.pause(); preview = null; } playingUrl = null; };

  // Every row registers how to redraw its own glyph, so starting one preview visibly stops the last.
  const syncs = [];
  const syncAll = () => syncs.forEach((f) => f());

  const toggle = (url) => {
    if (playingUrl === url) return stopPreview(), syncAll();
    stopPreview();
    playingUrl = url;
    preview = new Audio(url);
    preview.addEventListener("ended", () => { playingUrl = null; preview = null; syncAll(); });
    preview.play().catch(() => { playingUrl = null; preview = null; syncAll(); });
    syncAll();
  };

  const row = (trk) => {
    // THE ART IS THE BUTTON. Auditioning used to mean attaching the song first — every listen was a
    // commitment the user then had to undo. Tapping the cover plays the 30 seconds iTunes gives,
    // tapping again stops, and starting another stops the first.
    const art = el("span", { class: "song-art-btn", title: trk.preview_url ? t("preview") : "" });
    if (trk.artwork_url) art.append(el("img", { src: trk.artwork_url, class: "song-art", loading: "lazy", decoding: "async", alt: "" }));
    else art.append(el("span", { class: "note" }, icon("music.note")));
    if (trk.preview_url) {
      const glyph = el("span", { class: "song-art-glyph" });
      const sync = () => {
        const on = playingUrl === trk.preview_url;
        glyph.replaceChildren(icon(on ? "pause.fill" : "play.fill"));
        // Hover reveals the glyph; PLAYING pins it, since it is the only mark of which row you hear.
        glyph.style.opacity = on ? "1" : "";
      };
      sync(); syncs.push(sync);
      art.append(glyph);
      art.classList.add("playable");
      art.addEventListener("click", (e) => { e.stopPropagation(); toggle(trk.preview_url); });
    }
    return el("button", { class: "song-chip glass", style: "width:100%;text-align:left;cursor:pointer",
      onclick: () => {
        stopPreview();
        onPick({ catalog_id: trk.catalog_id, title: trk.title, artist: trk.artist,
                 artwork_url: trk.artwork_url || "", duration_ms: trk.duration_ms || 0 });
        closeModal();   // hands the post editor back, rather than clearing it
      } },
      art,
      el("span", { style: "flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" },
        el("strong", {}, trk.title), trk.artist ? " · " + trk.artist : ""));
  };

  const show = (list, emptyKey) => {
    syncs.length = 0;
    results.replaceChildren();
    if (!list.length) { results.append(el("div", { class: "muted small", style: "padding:10px" }, t(emptyKey))); return; }
    list.forEach((trk) => results.append(row(trk)));
  };

  const busy = () => results.replaceChildren(el("div", { class: "row", style: "gap:8px;padding:10px" },
    el("div", { class: "spinner" }), el("span", { class: "muted small" }, t("searching"))));

  let seq = 0;                              // late responses must not overwrite a newer query
  const runSearch = async () => {
    const q = input.value.trim();
    if (!q) { results.replaceChildren(); return; }
    const mine = ++seq;
    busy();
    const hits = await invoke("music_search", { query: q, limit: 25 }).catch(() => []);
    if (mine === seq) show(hits, "no_songs_found");
  };
  const runSuggest = async () => {
    const mine = ++seq;
    busy();
    const hits = await invoke("music_suggestions", {
      caption: (typeof ctx.caption === "function" ? ctx.caption() : ctx.caption) || "",
      genre: ctx.genre || null,
      createdAtMs: ctx.createdAt || null,
      limit: 12,
    }).catch(() => []);
    if (mine === seq) show(hits, "no_suggestions");
  };

  const drawTabs = () => {
    tabs.replaceChildren(
      el("button", { class: "tab" + (tab === "search" ? " active" : ""), onclick: () => { tab = "search"; drawTabs(); searchRow.style.display = ""; runSearch(); } }, t("search")),
      el("button", { class: "tab" + (tab === "suggest" ? " active" : ""), onclick: () => { tab = "suggest"; drawTabs(); searchRow.style.display = "none"; runSuggest(); } }, t("suggested")),
    );
  };
  drawTabs();

  let debounce;
  input.addEventListener("input", () => { clearTimeout(debounce); debounce = setTimeout(runSearch, 300); });
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); clearTimeout(debounce); runSearch(); } });

  // Restore, don't clear: opened from the post editor, closing has to return there with the
  // selection applied — not drop the user back to the feed with their edit thrown away.
  const root0 = $("#modal-root");
  const covered = Array.from(root0.childNodes);
  const close = modal(el("div", {},
    el("h2", {}, t("attach_a_song")),
    tabs, searchRow, results,
    el("div", { class: "muted small", style: "margin-top:8px" }, t("song_picker_hint"))),
    covered.length ? { onClose: () => { stopPreview(); root0.replaceChildren(...covered); } } : {});
  // Auditioning must not outlive the dialog.
  const root = $("#modal-root");
  new MutationObserver(() => { if (!root.contains(results)) stopPreview(); }).observe(root, { childList: true, subtree: true });
  setTimeout(() => input.focus(), 30);
  return close;
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
    title: t("open_in_maps"),
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
  const cover = el("div", { class: "sensitive-cover", title: t("sensitive_content") },
    el("div", { class: "sensitive-label" },
      icon("eye.slash"),
      el("div", { class: "t" }, t("sensitive_content")),
      el("div", { class: "s" }, t("tap_to_view"))));
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
  PosterIndex.learn(media);
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
    if (r.startsWith("preview:")) {
      const rest = r.slice(8);
      const c = rest.lastIndexOf(":");
      if (c > 0) thumbImages.add(rest.slice(c + 1));
    }
  }
  // Poster stills ride with the video page (data-saver still + play) — not as their own slide.
  // Thumbs and 512px previews never render as slides at all: they back the loading placeholder,
  // blurred. Without excluding the preview a satellite post would draw the same picture twice —
  // small, then full — the moment the real bytes landed.
  return (media || []).filter((r) => !isSyntheticMedia(r) && !originals.has(r) && !posterImages.has(r) && !thumbImages.has(r));
}

// ---- `thumb:` companions (MediaVariants parity) ------------------------------------------
// contentRef -> tiny thumbRef, learned from every media list that passes through displayMediaRefs,
// so a still-loading tile can paint its own blurred preview instead of a grey box.
const ThumbIndex = {
  map: new Map(),
  /// Content refs for which the entry in `map` is a 512px preview rather than a thumb, so a later
  /// `thumb:` marker for the same content cannot downgrade it.
  previews: new Set(),
  learn(media) {
    for (const r of media || []) {
      if (r.startsWith("thumb:")) {
        const rest = r.slice(6), c = rest.lastIndexOf(":");
        // Do not clobber a preview already learned for this content: the 512px AVIF is twice the
        // thumb's resolution at a quarter of its bytes, and on a constrained link it may be the
        // only companion that arrived.
        if (c > 0 && !this.previews.has(rest.slice(0, c))) this.map.set(rest.slice(0, c), rest.slice(c + 1));
      } else if (r.startsWith("preview:")) {
        const rest = r.slice(8), c = rest.lastIndexOf(":");
        if (c > 0) { this.previews.add(rest.slice(0, c)); this.map.set(rest.slice(0, c), rest.slice(c + 1)); }
      }
    }
  },
  thumbFor(ref) { return this.map.get(ref) || null; },
};

/** videoRef -> its poster STILL, learned from every media list that passes through
 *  displayMediaRefs — the same trick ThumbIndex plays, and for the same reason: the marker is
 *  stripped before the carousel sees it, so anything wanting a PICTURE of a video (rather than the
 *  video) has no way back to it otherwise. */
const PosterIndex = {
  map: new Map(),
  learn(media) {
    for (const r of media || []) {
      if (!r.startsWith("poster:")) continue;
      const rest = r.slice(7), c = rest.lastIndexOf(":");
      if (c > 0) this.map.set(rest.slice(0, c), rest.slice(c + 1));
    }
  },
  posterFor(ref) { return this.map.get(ref) || null; },
};

/** The poster STILL that rides with `videoRef`, from the same media array — `poster:<video>:<image>`.
 *  displayMediaRefs strips these from the carousel, so anywhere that wants a picture of a video
 *  rather than the video itself (story rings, tiles) has to read it back out. */
function posterRefFor(media, videoRef) {
  for (const r of media || []) {
    if (!r.startsWith("poster:")) continue;
    const rest = r.slice(7), c = rest.lastIndexOf(":");
    if (c > 0 && rest.slice(0, c) === videoRef) return rest.slice(c + 1);
  }
  return null;
}

// The bottom strip of a video that belongs to its scrub bar rather than to the carousel. Matches
// the native control's own height, so the line the reader feels is the line they can see.
const SCRUB_ZONE_PX = 44;

/** A VISIBLE mute control on the clip itself, as every other platform has.
 *
 *  Tapping the video was supposed to be this, iOS-style, but a <video> with native `controls` hands
 *  its clicks to the control layer — so the tap never arrived and there was no other way to turn a
 *  post's sound on. Until a song post was unmuted, every clip stayed silent with no visible reason.
 *
 *  Sound is a GLOBAL setting here (as on Apple, where unmuting one post unmutes the feed), so this
 *  button reflects and drives that — except on a post whose song owns the audio, where it ducks to
 *  the clip instead.
 */
function videoSoundButton(video) {
  const btn = el("button", { class: "icon-btn glass media-sound" });
  const sync = () => {
    const on = !video.muted;
    btn.title = on ? t("mute_all_videos") : t("unmute_all_videos");
    btn.replaceChildren(icon(on ? "speaker" : "speaker.slash"));
  };
  btn.addEventListener("click", async (e) => {
    e.stopPropagation();
    e.preventDefault();
    if (video.muted) {
      if (!Autoplay.duck(video)) await Autoplay.enableSound(video);
    } else {
      state.videoSoundOn = false;
      await invoke("set_video_sound", { on: false }).catch(() => {});
      syncFeedVideoSound();
    }
    sync();
  });
  video.addEventListener("volumechange", sync);
  sync();
  return btn;
}

function mediaNode(ref, imgStyle) {
  // Videos start muted unless the global "play video sound" toggle is on (iOS parity); native controls
  // still let the user override per-video. data-video lets the toggle re-apply across all of them.
  // While a call is ringing/connecting/live — or while any capture UI is up — they render muted
  // regardless (call/capture audio priority).
  if (isVideoRef(ref)) {
    const v = el("video", Object.assign({ "data-ref": ref, "data-video": "1", controls: "" },
      state.videoSoundOn && !callAudioActive() && !captureUIOpen() && !state.superDataSaver ? {} : { muted: "" }));
    // TAP A MUTED CLIP TO HEAR IT. When a song owns the post the clip plays silent, and the tap is
    // how the reader says "this one instead" — the song ducks out and the clip's own audio takes
    // over. The video itself is the target, exactly as on iOS, so there is no extra control.
    v.addEventListener("click", () => {
      if (!v.muted) return;
      // A song post DUCKS to the clip. A post without one has nothing to duck from, and `duck`
      // returned false there — so tapping a muted video on an ordinary post did nothing at all,
      // while its controls showed full volume (the element is MUTED; the slider reads `volume`,
      // which never moved). Turn the sound on instead, which is what a tap plainly means.
      if (Autoplay.duck(v)) return;
      Autoplay.enableSound(v);
    });
    // The native controls carry their own mute button. Without this the coordinator re-asserted
    // `muted` on the next scroll and silently undid it a frame later.
    v.addEventListener("volumechange", () => {
      if (adoptingSound || v.muted || state.videoSoundOn) return;
      Autoplay.enableSound(v);
    });
    // SCRUBBING vs PAGING. The bottom strip of a video is its scrub bar; the carousel is a
    // scroll-snap track, so a horizontal drag anywhere over the clip pages the carousel instead of
    // seeking — the control is there and cannot be used. A drag that STARTS low belongs to the
    // video (iOS draws the same line), so the track stops scrolling for the length of that gesture.
    v.addEventListener("pointerdown", (e) => {
      const track = v.closest(".track");
      if (!track) return;
      const r = v.getBoundingClientRect();
      if (e.clientY < r.bottom - SCRUB_ZONE_PX) return;   // high enough → let the carousel page
      track.style.overflowX = "hidden";
      const release = () => {
        track.style.overflowX = "";
        window.removeEventListener("pointerup", release);
        window.removeEventListener("pointercancel", release);
      };
      window.addEventListener("pointerup", release);
      window.addEventListener("pointercancel", release);
    });
    return v;
  }
  if (isAudioRef(ref)) return el("audio", { "data-ref": ref, controls: "", style: "width:100%;margin-top:6px;display:block" });
  if (isFileRef(ref)) return el("div", { class: "tag", "data-ref": ref, style: "padding:12px;margin-top:6px" }, "📎 " + t("attachment_chip"));
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
  if (p.backdrop) return;
  // The SAME image, blurred and cropped to fill — not a canvas-derived still.
  //
  // That still was produced by drawing the decoded image to a canvas on the MAIN thread, once per
  // photo, and whenever it failed or had not run yet the page letterboxed onto flat black instead
  // of extending. A second <img> at the same data URL reuses the bytes the webview already holds,
  // and it can never be missing — which is what a blur extension has to be to read as deliberate
  // rather than as a fault.
  // NEVER an <img> pointed at video bytes: that sends WebKit down RemoteImageDecoderAVF, a
  // synchronous AVFoundation decode that never completes for a video stream and wedges the web
  // process — a hung window at 0% CPU, a wait rather than a loop.
  //
  // A photo can therefore use its own URL, and a video needs a picture of itself. Two sources, in
  // order: the still grabbed off the first decoded frame (may not exist yet, or at all — the seek
  // dance is best-effort), then the POSTER COMPANION the media array already carries. Relying on
  // the frame grab alone is why video had no extension while photos did.
  const isVideo = p.node.tagName === "VIDEO";
  const src = p.poster || (isVideo ? null : (p.node.currentSrc || p.node.src));
  if (src) {
    p.backdrop = el("img", { class: "media-backdrop", src, alt: "", "aria-hidden": "true" });
    p.page.prepend(p.backdrop);
    return;
  }
  if (!isVideo) return;
  const posterRef = PosterIndex.posterFor(p.ref);
  if (!posterRef || p.backdropPending) return;
  p.backdropPending = true;
  const img = el("img", { class: "media-backdrop", alt: "", "aria-hidden": "true" });
  invoke("media_data_url", { circleId: state.activeCircle, reference: posterRef })
    .then((url) => {
      // The page may have been rebuilt while this resolved; adding to a detached node is harmless
      // but pointless, and a second backdrop would stack.
      if (!url || p.backdrop || !p.page.isConnected) return;
      img.src = url;
      p.backdrop = img;
      p.page.prepend(img);
    })
    .catch(() => {})
    .finally(() => { p.backdropPending = false; });
}

// Build the fitted pages for `refs`. `onAspects` fires as items decode, so the caller can settle the
// shared shape. Backdrops re-evaluate on decode and whenever the card is resized.
function buildMediaPages(refs, container, onAspects) {
  const pages = refs.map((ref) => {
    const node = mediaNode(ref);
    const page = el("div", { class: "media-page" }, node);
    if (node.tagName === "VIDEO") page.append(videoSoundButton(node));
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
      // UPSCALE A CLIP SMALLER THAN ITS PAGE. Media is sized by its own pixels, so a low-resolution
      // item sat at natural size with the blurred backdrop filling all four sides — right by the
      // rules, odd to look at, and only visible on the few items whose stored size is below the
      // card width.
      //
      // Done here rather than in CSS on purpose: filling the page unconditionally would put a
      // page-sized box under every video, and in the height-capped portrait case a <video> paints
      // its own opaque black into the unfilled part, covering the very backdrop this exists to
      // show. Only the genuinely-too-small case is changed.
      const pw = p.page.clientWidth, ph = p.page.clientHeight;
      if (pw > 0 && ph > 0 && w < pw && h < ph) {
        p.node.style.width = "100%";
        p.node.style.height = "100%";
        p.node.style.objectFit = "contain";
      }
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
  let revealed = false, tm;
  const draw = () => {
    wrap.replaceChildren(revealed
      ? el("span", {}, text)
      : el("span", { class: "muted" }, t("tap_to_reveal")));
  };
  wrap.addEventListener("click", () => {
    revealed = !revealed; draw();
    clearTimeout(tm);
    if (revealed) tm = setTimeout(() => { revealed = false; draw(); }, 5000);
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
// Set while the importer is driving these helpers. A refusal is per-FILE, and an archive holds
// hundreds — toasting each one would bury the screen in notices about photos the user never picked
// and cannot act on. The import's own reporting (skipped counts) is the right channel for that.
let mediaQuiet = false;

function mediaSourceAllowed(sizeBytes, isVideo, label) {
  const cap = isVideo ? MEDIA_TARGETS.MAX_SOURCE_BYTES_VIDEO : MEDIA_TARGETS.MAX_SOURCE_BYTES_STILL;
  if (sizeBytes > cap) {
    if (!mediaQuiet) toast(t("file_too_large", label || t("that_file"), fmtMB(sizeBytes), isVideo ? t("videos_word") : t("photos_word"), fmtMB(cap)));
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
    const status = el("div", { class: "muted small", style: "text-align:center" }, t("tap_record_to_start"));
    const recBtn = el("button", { class: "btn primary" }, t("record_btn"));
    const stopBtn = el("button", { class: "btn danger", style: "display:none" }, t("stop_attach"));
    const finish = (ref) => { if (done) return; done = true; clearInterval(timer); if (stream) stream.getTracks().forEach((t) => t.stop()); releaseCapture(); $("#modal-root").replaceChildren(); resolve(ref); };
    recBtn.onclick = async () => {
      // Channel count is PRESERVED, capped at stereo (Apple's rule) — asking for `channelCount: 2`
      // as a max lets a mono mic stay mono rather than being upmixed to a wasteful stereo stream.
      try { stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: { ideal: 1, max: MEDIA_TARGETS.AUDIO_MAX_CHANNELS } } }); }
      catch (e) { toast(t("mic_unavailable", e)); return; }
      recorder = new MediaRecorder(stream, { audioBitsPerSecond: MEDIA_TARGETS.AUDIO_BITRATE_BPS });
      recorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
      recorder.onstop = async () => {
        const blob = new Blob(chunks, { type: recorder.mimeType || "audio/webm" });
        try { const ref = await invoke("add_audio", { circleId, dataBase64: await blobToBase64(blob) }); finish(ref); }
        catch (e) { toast(t("couldnt_save", e)); finish(null); }
      };
      recorder.start();
      recBtn.style.display = "none"; stopBtn.style.display = ""; status.textContent = t("recording");
      timer = setInterval(() => {
        secs++; timeEl.textContent = `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, "0")}`;
        // Length cap: stop AT the limit rather than refusing after the fact — the user keeps what
        // they recorded, and nothing over the cap is ever sealed.
        if (secs >= MEDIA_TARGETS.MAX_DURATION_SEC && recorder && recorder.state !== "inactive") {
          toast(t("voice_note_cap", MEDIA_TARGETS.MAX_DURATION_SEC / 60));
          recorder.stop();
        }
      }, 1000);
    };
    stopBtn.onclick = () => { if (recorder && recorder.state !== "inactive") recorder.stop(); };
    modal(el("div", {}, el("h2", {}, t("voice_message")), timeEl, status,
      el("div", { class: "row", style: "justify-content:center;margin-top:12px" }, recBtn, stopBtn,
        el("button", { class: "btn ghost", onclick: () => finish(null) }, t("cancel")))));
  });
}

// The 6 Haven capture filters (parity with iOS MediaFilters), as CSS filter strings.
const CAMERA_FILTERS = [
  { name: t("filter_original"), css: "" },
  { name: t("filter_warmth"), css: "sepia(0.25) saturate(1.35) hue-rotate(-10deg) brightness(1.03)" },
  { name: t("filter_cool"), css: "saturate(1.1) hue-rotate(14deg) brightness(1.05)" },
  { name: t("filter_sepia"), css: "sepia(0.7) contrast(1.05)" },
  { name: t("filter_noir"), css: "grayscale(1) contrast(1.25) brightness(1.05)" },
  { name: t("filter_vivid"), css: "saturate(1.7) contrast(1.12)" },
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
      catch (e) { toast(t("capture_failed", e)); }
    } }, t("capture_btn"));
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
            toast(t("clip_cap", MEDIA_TARGETS.MAX_DURATION_SEC / 60));
            recorder.stop();
          }
        }, MEDIA_TARGETS.MAX_DURATION_SEC * 1000);
        recorder.onstop = async () => {
          if (recTimer) { clearTimeout(recTimer); recTimer = null; }
          if (rafId) cancelAnimationFrame(rafId);
          const blob = new Blob(chunks, { type: recorder.mimeType || "video/webm" });
          try { const ref = await invoke("add_media", { circleId, dataBase64: await blobToBase64(blob), isVideo: true }); finish({ ref, isVideo: true }); }
          catch (e) { toast(t("save_failed", e)); }
        };
        recorder.start(); recording = true; recBtn.textContent = t("stop_btn"); recBtn.classList.add("danger");
      } else { recorder.stop(); }
    } }, t("record_video_btn"));
    modal(el("div", {}, el("h2", {}, t("camera_title")), video, strip,
      el("div", { class: "row", style: "margin-top:12px" }, shoot, recBtn, el("div", { class: "spacer", style: "flex:1" }),
        el("button", { class: "btn ghost", onclick: () => finish(null) }, t("close")))));
    navigator.mediaDevices.getUserMedia({ video: { facingMode: "user" }, audio: true })
      .then((s) => { stream = s; video.srcObject = s; setFilter(CAMERA_FILTERS[0]); })
      .catch((e) => { toast(t("camera_unavailable", e)); finish(null); });
  });
}

// Pick a future time → returns epoch ms (or null).
function scheduleDialog(onPick) {
  const input = el("input", { type: "datetime-local" });
  const d = new Date(Date.now() + 3600_000); // default +1h
  const pad = (n) => String(n).padStart(2, "0");
  input.value = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
  modal(el("div", {}, el("h2", {}, t("schedule_title")),
    el("div", { class: "muted small" }, t("schedule_hint")),
    input,
    el("div", { class: "row", style: "justify-content:flex-end;margin-top:12px" },
      el("button", { class: "btn primary", onclick: () => { const ms = new Date(input.value).getTime(); if (!ms || ms < Date.now()) { toast(t("pick_future_time")); return; } onPick(ms); $("#modal-root").replaceChildren(); } }, t("schedule_btn")))));
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
    if (!isVideo && !mediaQuiet) toast(t("couldnt_attach", e));
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
      const previewRef = isVideo ? null : await mintPreview(b64, state.activeCircle);
      state.attachments.push({ ref, url, isVideo, thumbRef, previewRef });
      after();
    } catch (e) { toast(t("couldnt_attach", e)); }
  }
}

// Mint the tiny (~256px, ≤32KB) `thumb:` companion for a photo at compose time: recipients render
// it blurred behind the loading placeholder long before the full bytes land. Returns the thumb's
// ref, or null when the encode can't get small enough (a "thumb" that isn't tiny is just waste) —
// the photo simply posts without one. Mirrors iOS MediaStore.mintThumbCompanion.
// Mint the 512px AVIF preview for a photo at compose time — the ONLY media small enough to cross a
// satellite link (docs/PREVIEW-TIER-DESIGN.md). Unlike the thumb above this cannot be done here:
// Chromium's canvas writes PNG, JPEG and WebP but not AVIF, so the encode happens in Rust and we
// just hand it the same sanitized bytes we are about to attach. Null simply means the photo posts
// without one. Mirrors iOS MediaStore.mintPreviewCompanion / Android LocalMedia.mintPreviewCompanion.
async function mintPreview(b64, circleId) {
  try {
    return await invoke("mint_preview", { circleId, dataBase64: b64 });
  } catch (_) { return null; }
}

async function mintThumb(b64, circleId) {
  try {
    if (b64.length * 0.75 < 64 * 1024) return null;   // already small — a thumb saves nothing
    // Off-thread first. This runs once per imported photo, so it is on the same hot path.
    try {
      const bin = atob(b64);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      const small = await ImgWorker.run(new Blob([bytes], { type: "image/jpeg" }),
        { mode: "thumb", maxDim: 256, quality: 0.6, maxBytes: 32 * 1024 });
      if (small) return await invoke("add_media", { circleId, dataBase64: small, isVideo: false });
    } catch (_) { /* fall through */ }
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

/** Is this clip bigger than what we would produce anyway? Reads dimensions and duration from the
 *  decoder's metadata — no frames decoded, no encoding — so the answer costs milliseconds against
 *  the seconds a needless re-encode costs. Null when the metadata cannot be read, which is treated
 *  as "re-encode it", since an unreadable clip is exactly the one worth normalising. */
function videoTargetProbe(file) {
  return new Promise((res) => {
    const url = URL.createObjectURL(file);
    const v = document.createElement("video");
    v.preload = "metadata";
    const done = (out) => { URL.revokeObjectURL(url); res(out); };
    v.addEventListener("loadedmetadata", () => {
      const long = Math.max(v.videoWidth || 0, v.videoHeight || 0);
      const bitrate = v.duration > 0 ? (file.size * 8) / v.duration : Infinity;
      done({
        // A slack factor, so a 1088px clip is not re-encoded to 1080 for a 1% saving that costs
        // its whole duration in main-thread time.
        oversized: long > MEDIA_TARGETS.VIDEO_LONG_EDGE * 1.05
          || bitrate > MEDIA_TARGETS.VIDEO_BITRATE_BPS * 1.5,
      });
    }, { once: true });
    v.addEventListener("error", () => done(null), { once: true });
    setTimeout(() => done(null), 8000);
    v.src = url;
  });
}

/** A POSTER STILL for an already-sealed clip, as bare base64 JPEG — or null.
 *
 *  Reads the sealed bytes back through `media_data_url` rather than being handed the clip, so a
 *  large reel never crosses the bridge (see igencode.rs). Seeking is what makes a frame drawable:
 *  `loadeddata` promises decoded data, not painted data, and drawing there yields a BLACK
 *  rectangle — the same trap `stillFrom` documents for feed backdrops. 0.1s rather than 0 because
 *  the very first frame of a phone video is often black while exposure settles.
 *
 *  Everything is torn down on the way out, including on failure: this runs once per imported video,
 *  and a leaked <video> holding a multi-megabyte object URL would accumulate across a whole run. */
async function posterFromVideoRef(circleId, ref) {
  const url = await invoke("media_data_url", { circleId, reference: ref }).catch(() => null);
  if (!url) return null;
  const v = el("video", { src: url, muted: "", playsinline: "", preload: "auto" });
  v.style.cssText = "position:fixed;left:-9999px;top:0;width:2px;height:2px";
  document.body.append(v);
  try {
    await new Promise((res, rej) => {
      const done = () => { v.removeEventListener("seeked", done); res(); };
      v.addEventListener("seeked", done);
      v.addEventListener("error", rej, { once: true });
      v.addEventListener("loadedmetadata", () => {
        // Clamp: a clip shorter than the seek target never fires `seeked` at all.
        v.currentTime = Math.min(0.1, Math.max(0, (v.duration || 0) - 0.05));
      }, { once: true });
      setTimeout(rej, 20000);   // a codec this WebView cannot decode simply yields no poster
    });
    const w = v.videoWidth, h = v.videoHeight;
    if (!w || !h) return null;
    const scale = Math.min(1, 1080 / Math.max(w, h));
    const c = document.createElement("canvas");
    c.width = Math.max(1, Math.round(w * scale));
    c.height = Math.max(1, Math.round(h * scale));
    c.getContext("2d").drawImage(v, 0, 0, c.width, c.height);
    return c.toDataURL("image/jpeg", 0.72).split(",")[1] || null;
  } catch (_) {
    return null;
  } finally {
    v.pause();
    v.removeAttribute("src");
    v.load();          // drops the decoder's hold on the data URL
    v.remove();
  }
}

/** The composed media array for a post/DM: attachment refs in order, then a `thumb:<ref>:<thumbRef>`
 *  pairing marker per photo that minted one (synthetic scheme — old clients simply ignore it). */
function withThumbMarkers(atts) {
  return [
    ...atts.map((a) => a.ref),
    ...atts.filter((a) => a.thumbRef).map((a) => `thumb:${a.ref}:${a.thumbRef}`),
    ...atts.filter((a) => a.previewRef).map((a) => `preview:${a.ref}:${a.previewRef}`),
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
      toast(t("video_cant_strip"));
      rej(new Error("MediaRecorder unavailable — refusing to post a video with possible location metadata"));
      return;
    }
    const url = URL.createObjectURL(file);
    const video = document.createElement("video");
    // MUTED, and that is now safe. Autoplay policy can refuse an unmuted element, and the previous
    // attempt fell back to muted — which silently reinstated the very bug it was fixing, because
    // `captureStream()` on a muted element carries no usable audio.
    //
    // So the audio no longer comes from the element at all: it is decoded from the SOURCE BYTES
    // (see below) and mixed into the recorder directly. Playback and capture are now independent,
    // which is what they should always have been.
    video.muted = true;
    video.playsInline = true;
    video.preload = "auto";
    let raf, rec, settled = false, audioCtx = null, audioBuffer = null, audioNode = null;
    const closeAudio = () => {
      if (audioNode) { try { audioNode.stop(); } catch (_) {} audioNode = null; }
      if (audioCtx) { try { audioCtx.close(); } catch (_) {} audioCtx = null; }
    };
    const fail = (e) => {
      if (settled) return; settled = true;
      closeAudio();
      if (raf) cancelAnimationFrame(raf);
      try { if (rec && rec.state !== "inactive") rec.stop(); } catch {}
      URL.revokeObjectURL(url);
      if (!mediaQuiet) toast(t("video_meta_failed"));
      rej(e instanceof Error ? e : new Error(String(e)));
    };
    // A refusal (as opposed to a failure) has its own message and, like `fail`, rejects — so the
    // caller never reaches `add_media` and no ref is minted for bytes that were never stored.
    const refuse = (msg) => {
      if (settled) return; settled = true;
      closeAudio();
      URL.revokeObjectURL(url);
      if (!mediaQuiet) toast(msg);
      rej(new Error(msg));
    };
    /** The clip's audio, decoded from the SOURCE BYTES. Independent of the element entirely: no
     *  autoplay policy, no muted-element captureStream quirk, no volume to get wrong. Returns false
     *  when there is nothing decodable, which is the normal answer for a genuinely silent clip. */
    const prepareAudio = async () => {
      try {
        const AC = window.AudioContext || window.webkitAudioContext;
        if (!AC) return false;
        audioCtx = new AC();
        const bytes = await file.arrayBuffer();
        audioBuffer = await audioCtx.decodeAudioData(bytes);
        return !!(audioBuffer && audioBuffer.duration > 0 && audioBuffer.numberOfChannels > 0);
      } catch (_) {
        audioBuffer = null;
        return false;
      }
    };
    /** Attach it to the recorder and start it in step with playback. */
    const startAudio = () => {
      if (!audioCtx || !audioBuffer) return;
      const dest = audioCtx.createMediaStreamDestination();
      audioNode = audioCtx.createBufferSource();
      audioNode.buffer = audioBuffer;
      audioNode.connect(dest);          // recorder only — never `ac.destination`, so it stays silent
      dest.stream.getAudioTracks().forEach((t) => capStream.addTrack(t));
      audioNode.start();
    };

    video.onerror = () => fail(new Error("video decode failed"));
    video.onloadedmetadata = () => {
      // Length cap, checked the moment the decoder knows the duration — before a single frame is
      // drawn, recorded or sealed.
      const dur = video.duration;
      if (Number.isFinite(dur) && dur > MEDIA_TARGETS.MAX_DURATION_SEC) {
        return refuse(t("video_too_long", Math.round(dur / 60), MEDIA_TARGETS.MAX_DURATION_SEC / 60));
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
        // CARRY THE AUDIO, through a Web Audio graph rather than the element's own stream.
        //
        // The element is the only source of the clip's audio, and reading it required the element
        // to be audible — which is why this used to mute it and then wonder where the sound went.
        // A MediaElementSource feeding a MediaStreamDestination gives the recorder a real track,
        // and because nothing is connected to `ac.destination` the user hears nothing: the audio
        // exists on the wire and never on the speakers.
        // The decoded audio is attached by `startAudio` below, once the recorder is about to run —
        // it has to start in step with playback, not before it.
        if (!capStream.getAudioTracks().length && !audioBuffer) {
          // No decodable audio (a silent clip, or a codec Web Audio would not take): the element
          // stream is the last resort, and a silent track is the honest outcome for a silent clip.
          const elStream = (video.captureStream && video.captureStream()) ||
            (video.mozCaptureStream && video.mozCaptureStream());
          if (elStream) elStream.getAudioTracks().forEach((t) => capStream.addTrack(t));
        }
      } catch (e) { return fail(e); }
      const chunks = [];
      try {
        // H.264 in MP4 is what every other Haven client expects, and WebKit's MediaRecorder can
        // produce it. Asking explicitly (rather than taking the platform default) means macOS
        // stops depending on an implementation detail; Chromium-backed WebViews support neither
        // type string and fall through to their own default, exactly as before.
        const want = ["video/mp4;codecs=h264,mp4a.40.2", "video/mp4"]
          .find((m) => { try { return MediaRecorder.isTypeSupported(m); } catch (_) { return false; } });
        rec = new MediaRecorder(capStream, Object.assign({
          videoBitsPerSecond: MEDIA_TARGETS.VIDEO_BITRATE_BPS,
          audioBitsPerSecond: MEDIA_TARGETS.VIDEO_AUDIO_BITRATE_BPS,
        }, want ? { mimeType: want } : {}));
      } catch (e) { return fail(e); }
      const stopDraw = () => { if (raf) cancelAnimationFrame(raf); raf = null; };
      rec.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
      rec.onstop = async () => {
        if (settled) return; settled = true;
        stopDraw();
        closeAudio();
        try {
          const blob = new Blob(chunks, { type: rec.mimeType || "video/webm" });
          const b64 = await blobToBase64(blob);
          URL.revokeObjectURL(url);
          res(b64);
        } catch (e) {
          // Every rejection out of here must have SAID something — the caller stays silent for
          // videos precisely because this function owns its own messaging.
          URL.revokeObjectURL(url);
          toast(t("video_finish_failed"));
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
      // An UNMUTED element can have playback refused by autoplay policy. Falling back to muted
      // costs this clip its audio, which is bad — but it is far better than the alternative of
      // failing the encode outright and losing the clip's optimization as well.
      startAudio();
      video.play().catch(fail);
    };
    prepareAudio().finally(() => { video.src = url; });
  });
}

// Re-encode a still to the STILL target. The canvas round-trip is also what drops EXIF/GPS — a
// canvas has no metadata to write back out, so the JPEG we emit is unconditionally clean.
// ---- Still encoding, off the main thread -------------------------------------------------
//
// One worker, one job at a time. Both callers are already sequential (a picker loop, and the
// importer, which blocks on each item), so a pool would add contention for no throughput — and a
// second decoder running against the first is what made the UI stutter in the first place.
//
// EVERY path here falls back to the main-thread version: an older WebView without OffscreenCanvas,
// a worker that fails to construct under CSP, a decode the worker cannot do. Slower is fine;
// refusing to attach a photo is not.
const ImgWorker = {
  w: null, seq: 0, waiting: new Map(), dead: false,
  get() {
    if (this.dead) return null;
    if (this.w) return this.w;
    try {
      if (typeof Worker === "undefined" || typeof OffscreenCanvas === "undefined") throw new Error("unsupported");
      this.w = new Worker("imgworker.js");
      this.w.onmessage = (e) => {
        const { id, ok, b64, err } = e.data || {};
        const slot = this.waiting.get(id);
        if (!slot) return;
        this.waiting.delete(id);
        ok ? slot.res(b64) : slot.rej(new Error(err || "encode failed"));
      };
      // A worker that dies takes every in-flight job with it; reject them rather than leaving the
      // import blocked on a promise that can never settle.
      this.w.onerror = () => {
        this.dead = true;
        for (const [, slot] of this.waiting) slot.rej(new Error("worker died"));
        this.waiting.clear();
        this.w = null;
      };
    } catch (_) {
      this.dead = true;
      return null;
    }
    return this.w;
  },
  async run(blob, opts) {
    const w = this.get();
    if (!w) return null;
    const buf = await blob.arrayBuffer();
    const id = ++this.seq;
    return new Promise((res, rej) => {
      this.waiting.set(id, { res, rej });
      // Transferred, not copied: the bytes leave this thread entirely.
      w.postMessage(Object.assign({ id, buf, type: blob.type }, opts), [buf]);
    });
  },
  /** Base64 in, base64 out — the importer's path, where the bytes arrive as a string and there is
   *  no reason for this thread to ever hold them as pixels. */
  runB64(b64, opts) {
    const w = this.get();
    if (!w) return Promise.resolve(null);
    const id = ++this.seq;
    return new Promise((res, rej) => {
      this.waiting.set(id, { res, rej });
      w.postMessage(Object.assign({ id, b64, type: "image/jpeg" }, opts));
    });
  },
};

async function imageToJpegBase64(file, maxDim = MEDIA_TARGETS.STILL_LONG_EDGE, quality = MEDIA_TARGETS.STILL_JPEG_QUALITY) {
  try {
    const b64 = await ImgWorker.run(file, { maxDim, quality });
    if (b64) return b64;
  } catch (_) { /* fall through to the main thread */ }
  return imageToJpegBase64OnMainThread(file, maxDim, quality);
}

function imageToJpegBase64OnMainThread(file, maxDim = MEDIA_TARGETS.STILL_LONG_EDGE, quality = MEDIA_TARGETS.STILL_JPEG_QUALITY) {
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
      this.lastWarning = t("couldnt_check_media", e);
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
      if (!room) { this.lastWarning = t("stopped_no_space"); break; }

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
        this.lastWarning = t("couldnt_reshare", e);
      }
    }

    const pct = before > 0 ? Math.max(0, 100 - Math.round((after * 100) / before)) : 0;
    this.lastSummary = !swapped
      ? t("nothing_smaller")
      : t("reoptimize_summary",
          swapped === 1 ? t("item_one") : t("items_many", swapped),
          reshared === 1 ? t("post_one") : t("posts_many", reshared),
          fmtBytes(before), fmtBytes(after), pct);
    if (this.cancelRequested) this.lastWarning = t("stopped");
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
    if (this.scanning) return t("checking_shared_media");
    if (this.running) return t("reoptimizing_of", Math.min(this.doneCount + 1, this.batchCount), this.batchCount);
    if (!this.candidates.length) return t("reoptimize_title");
    const n = Math.min(this.candidates.length, this.batchLimit);
    return t("shrink_reshare", n === 1 ? t("photo_one") : t("photos_many", n));
  },

  foundText() {
    const total = this.candidates.length;
    const batch = Math.min(total, this.batchLimit);
    const legacy = this.candidates.filter((c) => c.legacy_by_age).length;
    let s = t("found_text", total === 1 ? t("photo_one") : t("photos_many", total), fmtBytes(this.pendingBytes));
    if (legacy > 0) s += t("legacy_suffix", legacy);
    if (batch < total) s += t("batch_suffix", batch);
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
      const stop = el("button", { class: "btn danger small" }, this.cancelRequested ? t("stopping") : t("stop_after_this"));
      stop.disabled = this.cancelRequested;
      stop.onclick = () => this.cancel();
      kids.push(stop);
    }
    if (this.lastWarning) kids.push(el("div", { class: "small", style: "color:var(--warn,#c60)" }, "⚠️ " + this.lastWarning));
    if (this.lastSummary && !this.running) kids.push(el("div", { class: "small", style: "color:var(--ok,#2a7)" }, "✓ " + this.lastSummary));

    if (this.candidates.length && !this.running) {
      kids.push(el("div", { class: "muted small" }, this.foundText()));
    } else if (this.hasScanned && !busy && !this.lastSummary) {
      kids.push(el("div", { class: "muted small" }, "✓ " + t("all_photos_small")));
    }
    // The honest footnote. Silently omitting my own oversized videos would let a 1.2 GB library look
    // like it had nothing to gain — and this device genuinely cannot re-encode them without handing
    // the circle a clip Apple can't play.
    if (this.hasScanned && this.videos > 0) {
      kids.push(el("div", { class: "muted small" },
        t("videos_skipped", this.videos, fmtBytes(this.videoBytes))));
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

/**
 * "Where is this post actually stored?" — which relays hold each attachment, and how many.
 *
 * Grouped by RELAY, not by attachment: the per-attachment shape repeats an identical block once per
 * photo, and the one fact that matters — which relay is missing copies — has to be reassembled by
 * eye. Desktop had no answer to this at all; the ledger lived in the engine and the only route to it
 * was the log. Apple parity (`BackupDetailView`).
 */
async function backupDetailSheet(circleId, refs) {
  const res = await invoke("media_backup_rows", { circleId, refs }).catch(() => null);
  const rows = (res && res.rows) || [];
  const ownRelay = (res && res.ownRelay) || "";
  const total = refs.length;

  const label = (dest) => {
    const known = (state.relayNames || {})[dest];
    if (known) return known;
    if (dest.includes("/") || dest.includes(".")) return dest;   // s3-style destination
    return "Relay · " + dest.slice(0, 8) + "…";
  };
  const status = (have, isOwn) => {
    if (!have) return t("no_copy_yet");
    const count = have === total ? t("all_copies") : t("n_of_m", have, total);
    return isOwn ? t("on_this_device_suffix", count) : count;
  };

  // Nothing but our own in-process relay holds a full set — it looks backed up and is in fact
  // unreachable to everyone else.
  const remoteComplete = rows.some((r) => r.dest !== ownRelay && r.have === total);
  const ownHasAny = rows.some((r) => r.dest === ownRelay && r.have > 0);
  const stranded = ownHasAny && !remoteComplete;

  const list = rows.length
    ? rows.map((r) => {
        const isOwn = r.dest === ownRelay;
        const tone = !r.have ? "muted" : (isOwn || r.have !== total) ? "warn" : "ok";
        return el("div", { class: "row", style: "justify-content:space-between;padding:7px 0;gap:10px" },
          el("div", { class: "row", style: "gap:8px;min-width:0" },
            el("span", { class: "dot " + tone }),
            el("span", { style: "overflow:hidden;text-overflow:ellipsis;white-space:nowrap" }, label(r.dest))),
          el("span", { class: "muted small" }, status(r.have, isOwn)));
      })
    : [el("div", { class: "muted" }, t("not_on_any_relay"))];

  sheet(t("where_stored"), [
    el("div", { class: "muted small", style: "margin-bottom:6px" },
      total === 1 ? t("attachment_one") : t("attachments_many", total)),
    ...list,
    stranded
      ? el("div", { class: "muted small", style: "margin-top:10px;color:var(--amber,#F59E0B)" },
          t("stranded_warning"))
      : null,
  ]);
}

function postCard(it, circleId, reports = []) {
  // macOS `header`: avatar, name and relative time all on ONE line, `···` at the far right.
  const kebab = el("button", { class: "kebab", title: t("more"), "aria-label": t("more") }, icon("ellipsis"));
  kebab.addEventListener("click", () => postMenu(kebab, it, circleId));
  // "Where is this stored?" on your own posts with attachments — the same answer Apple's cloud
  // badge opens. Desktop showed nothing at all, so a post whose media never left this device looked
  // identical to one safely on a relay.
  const ownBlobs = (it.media || []).filter((r) => !isSyntheticMedia(r));
  const storedBtn = (it.is_me && !it.unsent && ownBlobs.length)
    ? el("button", { class: "icon-btn ghost small", title: t("where_stored"),
                     "aria-label": t("where_stored"),
                     onclick: () => backupDetailSheet(circleId, ownBlobs) }, icon("icloud"))
    : null;
  const head = el("div", { class: "post-head" },
    el("div", { class: "avatar", style: "width:34px;height:34px;font-size:14px" }, avatarContent(it.is_me, it.author_name)),
    el("span", { class: "name" }, it.author_name),
    el("span", { class: "when" }, relTime(it.created_at) + (it.edited ? t("edited_suffix") : "")),
    storedBtn,
    kebab,
  );

  // Another member reported this post → surface the circle's shared moderation signal with
  // per-viewer actions (hide / remove from circle / block). The reporter themselves never sees
  // it — reporting hid the post for them.
  const banner = !it.is_me && reports.length ? reportedBanner(it, circleId, reports) : null;

  const body = it.unsent
    ? el("div", { class: "post-body muted" }, t("post_unsent_tombstone"))
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
  //
  // Matches Apple's pill rather than being a bare link: cover art when the track carries any, the
  // title/artist, a speaker reflecting the global sound setting, and a SMALL dedicated button to
  // open the song. The open action is deliberately not the whole chip — on Apple that is explicitly
  // so a stray click mutes instead of yanking the user out to another app.
  const song = it.music ? (() => {
    const art = musicArtwork(it.music);
    const chip = el("div", { class: "song-chip glass tint-pink" });
    chip.append(art
      ? el("img", { src: art, class: "song-art", alt: "", loading: "lazy", decoding: "async" })
      : el("span", { class: "note" }, icon("music.note")));
    chip.append(el("span", { style: "flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" },
      el("strong", {}, it.music.title), it.music.artist ? " · " + it.music.artist : ""));
    // Sound toggle. Desktop does not play the song itself (see storySongChip), so this governs what
    // you can actually hear from a post — its video's audio — and the glyph says which way it is.
    const sound = el("button", {
      class: "song-sound",
      title: state.videoSoundOn ? t("mute_all_videos") : t("unmute_all_videos"),
      onclick: async (e) => {
        e.stopPropagation();
        state.videoSoundOn = !state.videoSoundOn;
        await invoke("set_video_sound", { on: state.videoSoundOn }).catch(() => {});
        syncFeedVideoSound();
        renderFeed();
      },
    }, icon(state.videoSoundOn ? "speaker" : "speaker.slash"));
    chip.append(sound);
    const url = musicLink(it.music);
    if (url) {
      chip.append(el("button", {
        class: "song-open",
        title: t("open_in_music_app"),
        onclick: (e) => { e.stopPropagation(); openExternal(url); },
      }, icon("arrow.up.forward.app")));
    }
    return chip;
  })() : null;

  // macOS `reactionsRow`: chips left (glass capsules, pink-tinted when they're yours, capped at
  // four so a post can't flood the row), quick-react emoji + `＋` pinned right.
  const actions = el("div", { class: "post-actions" });
  for (const r of cappedReactions(it.reactions, 4)) {
    actions.append(el("button", { class: "react-pill glass" + (r.mine ? " tint-pink mine" : ""), title: r.mine ? t("remove_reaction") : t("react"),
      onclick: () => toggleReact(circleId, it.id, r.emoji, it.reactions) },
      el("span", {}, r.emoji), el("span", { class: "n" }, String(r.count))));
  }
  const hiddenCount = Math.max(0, (it.reactions || []).length - cappedReactions(it.reactions, 4).length);
  if (hiddenCount > 0) actions.append(el("span", { class: "react-pill glass" }, el("span", { class: "n" }, "+" + hiddenCount)));

  const quick = el("div", { class: "quick" });
  for (const e of frequentEmoji(3)) quick.append(el("button", { title: t("react_emoji", e), onclick: () => quickReact(circleId, it.id, e, it.reactions) }, e));
  const more = el("button", { class: "more", title: t("more_reactions"), "aria-label": t("more_reactions") }, icon("plus.circle"));
  more.addEventListener("click", () => emojiPicker(more, circleId, it.id));
  quick.append(more);
  const cmtBtn = el("button", { title: t("comments") }, `💬 ${(it.comments || []).length}`);
  quick.append(cmtBtn);
  actions.append(quick);

  const comments = el("div", { class: "comments" });
  if ((it.comments || []).length) {
    const cl = el("div", { class: "comment-list" });
    for (const c of it.comments || []) {
      cl.append(el("div", { class: "comment" },
        el("div", { class: "avatar", style: "width:26px;height:26px;font-size:11px" }, avatarContent(c.is_me, c.author_name)),
        el("div", { class: "bubble" },
          el("div", { class: "row", style: "gap:6px" },
            el("span", { class: "who" + (c.is_me ? " me" : "") }, c.is_me ? t("you") : c.author_name),
            el("span", { class: "when muted small" }, relTime(c.created_at))),
          el("div", {}, c.body)),
      ));
    }
    comments.append(cl);
  }
  // Reply row: paperclip + pill field + circular pink send, straight from macOS `commentField`.
  const cin = el("input", { placeholder: t("add_a_reply"), onkeydown: (e) => { if (e.key === "Enter") sendComment(); } });
  const sendComment = async () => {
    const b = cin.value.trim();
    if (!b) return;
    await invoke("comment", { circleId, target: it.id, body: b });
    cin.value = "";
  };
  comments.append(el("div", { class: "reply-row" },
    el("button", { class: "icon-btn sm pink", title: t("attach"), onclick: () => toast(t("attach_reply_phone")) }, icon("paperclip")),
    cin,
    el("button", { class: "send-sm", title: t("send"), "aria-label": t("send_reply"), onclick: sendComment }, icon("paperplane.fill")),
  ));
  cmtBtn.addEventListener("click", () => comments.classList.toggle("show"));

  const geoNode = geo ? geoChip(geo) : null;
  // data-post is how a post link finds its card (focusPostCard) — ids can hold anything, so it's an
  // attribute lookup rather than an id selector that would need escaping.
  // data-author / data-mine ride alongside so a media tile that discovers its bytes are missing can
  // find out which post it belongs to and offer "Ask for it back" — the tile is several helpers deep
  // by then, and galleries and pagers have no business carrying a post id through.
  // data-song: the autoplay coordinator mutes a clip whose post carries a song, and it reaches the
  // <video> through this card rather than by threading the item down every gallery helper.
  return el("div", { class: "card post", "data-post": it.id, "data-author": it.author_short || "", "data-mine": it.is_me ? "1" : "", "data-song": (it.music || it.mute_video) ? "1" : "",
    "data-song-title": it.music ? it.music.title : "", "data-song-artist": it.music ? it.music.artist : "",
    "data-song-catalog": it.music ? (it.music.catalog_id || "") : "",
    "data-muted-by-author": it.mute_video ? "1" : "" }, head, banner, body, media.children.length ? media : null, geoNode, audio.children.length ? audio : null, song, actions, comments);
}

// ---- Reports (decentralized moderation) --------------------------------------------------
// Mirrors apple/HavenApp/ReportUI.swift: circles have no owner, so a report is sealed to the
// WHOLE circle and every member acts with the power they already hold. Only who-reported-whom
// and the category ever leave the circle (the backend's content-free ledger ping).

const REPORT_REASONS = [
  ["report_harassment", "🗯"],
  ["report_nudity", "🙈"],
  ["report_violence", "⚠️"],
  ["report_spam", "🛡"],
  ["report_other", "🚩"],
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
    toast(t("reported_toast"));
    renderFeed();
  } }, t("report"));
  const rows = REPORT_REASONS.map(([rk, icon]) => el("button", { class: "btn reason", onclick: (e) => {
    reason = tEn(rk);
    submit.disabled = false;
    $$(".reason", e.target.closest(".col")).forEach((b) => b.classList.toggle("primary", b === e.target.closest(".reason")));
  } }, `${icon} ${t(rk)}`));
  const note = el("textarea", { placeholder: t("report_note_ph"), rows: 2 });
  const blockBox = el("input", { type: "checkbox", onchange: (e) => { alsoBlock = e.target.checked; } });
  modal(el("div", {},
    el("h2", {}, t("report_post")),
    el("div", { class: "muted small", style: "margin-bottom:8px" }, t("whats_wrong")),
    el("div", { class: "col" }, ...rows),
    note,
    el("label", { class: "row", style: "margin-top:8px;gap:8px;cursor:pointer" }, blockBox, "✋ " + t("also_block", it.author_name)),
    el("div", { class: "muted small", style: "margin-top:10px" },
      t("report_hint")),
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
      el("div", { class: "small", style: "font-weight:600" }, t("reported_by", names)),
      el("div", { class: "small muted" }, reasons + (notes.length ? ` — “${notes[0]}”` : "")),
    ),
    el("button", { class: "btn small ghost", onclick: () => reportedActions(it, circleId, reports) }, t("act")),
  );
}

function reportedActions(it, circleId, reports) {
  const author = reports[0].author;   // FULL node hex, embedded by the reporter's core
  const m = el("div", {}, el("h2", {}, t("reported_post")),
    el("div", { class: "col" },
      el("button", { class: "btn", onclick: () => { Hidden.hide(it.id); $("#modal-root").replaceChildren(); renderFeed(); } }, "🙈 " + t("hide_for_me")),
      el("button", { class: "btn danger", onclick: async () => {
        if (!confirm(t("remove_confirm", it.author_name))) return;
        await invoke("remove_from_circle", { circleId, contactIdHex: author }).catch(() => {});
        $("#modal-root").replaceChildren();
        toast(t("removed_toast"));
        renderFeed();
      } }, "👋 " + t("remove_from_circle_btn", it.author_name)),
      el("button", { class: "btn danger", onclick: async () => {
        await invoke("block", { idHex: author }).catch(() => {});
        $("#modal-root").replaceChildren();
        toast(t("blocked_toast"));
        renderFeed();
      } }, "✋ " + t("block_person", it.author_name)),
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
    keepRefs.length ? { label: t("keep_on_device"), icon: "pin", on: async () => {
      try { await invoke("media_pin", { refs: keepRefs }); toast(t("kept_on_device")); }
      catch (e) { toast(t("couldnt_keep", e)); }
    } } : null,
    // Share a pointer to this post: the web form, so it crosses to iOS/Android and survives being
    // pasted into any chat app. It carries no key — only a device already in the circle can open it.
    { label: t("share_post"), icon: "square.and.arrow.up", on: async () => {
      try { await navigator.clipboard.writeText(DeepLink.postLink(circleId, it.id)); toast(t("link_copied")); }
      catch (e) { toast(t("couldnt_copy", e)); }
    } },
    it.is_me ? { label: t("edit"), icon: "pencil.circle.fill", on: () => editPostDialog(it, circleId) } : null,
    it.is_me ? { label: t("unsend"), icon: "arrow.uturn.backward", danger: true, on: async () => { await invoke("unsend_post", { circleId, target: it.id }); toast(t("unsent_toast")); } } : null,
    // Hide any post from my own feed (reversible via the circle menu's "Show hidden posts").
    { label: isHidden ? t("unhide") : t("hide"), icon: isHidden ? "eye" : "eye.slash",
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
      label: t("message_name", author.name), icon: "bubble.left",
      on: async () => {
        const t = await invoke("message_author",
          { authorShort: it.author_short, circleId, postId: it.id }).catch(() => null);
        if (!t || !t.dm) { toast(t("couldnt_open_message")); return; }
        // Consumed once by renderThread's composer — appended there, never assigned, so re-entering
        // a thread cannot discard something half-typed.
        if (t.draft) state.pendingDraft = { id: t.dm, text: t.draft };
        state.activeDm = { id: t.dm, name: t.name || author.name };
        switchView("messages");
      },
    },
    // Report to the whole circle (decentralized moderation — see reportDialog).
    it.is_me ? null : { label: t("report"), icon: "flag", danger: true, on: () => reportDialog(it, circleId) },
  ], { align: "right" });
}

/** FULL post editor — text, attachments, song and location. Apple parity: `EditPost.swift`.
 *
 *  Desktop's editor used to be a bare textarea that passed the post's media and music straight back
 *  untouched. That was deliberate and defensive (an edit REPLACES the arrays rather than merging, so
 *  omitting them deletes everyone's copies) but it left desktop unable to do things Apple has always
 *  offered: drop a photo from a post, add one, swap the song, or take the location off.
 *
 *  Companion markers are the sharp edge here. `thumb:`/`poster:`/`orig:` name their parent ref, so
 *  removing a photo without removing its markers leaves entries pointing at media the post no longer
 *  carries — `dropRef` is what keeps the array honest. */
function editPostDialog(it, circleId) {
  let media = [...(it.media || [])];
  let music = it.music || null;
  let muteVideo = !!it.mute_video;

  const ta = el("textarea", { class: "composer-field glass", rows: 3, style: "width:100%" });
  ta.value = it.body || "";
  const strip = el("div", { class: "attach-preview" });
  const musicRow = el("div", {});
  const fileInput = el("input", { type: "file", accept: "image/*,video/*", multiple: "", style: "display:none" });

  // A ref and everything that rides with it. Markers are `scheme:<parent>:<child>`, so both the
  // parent and any marker naming it go — and the child blob is dropped from the array too.
  const dropRef = (ref) => {
    const doomed = new Set([ref]);
    for (const r of media) {
      const i = r.indexOf(":");
      if (i <= 1) continue;                       // not a marker (a bare ref has no scheme)
      const rest = r.slice(i + 1), c = rest.lastIndexOf(":");
      if (c > 0 && rest.slice(0, c) === ref) { doomed.add(r); doomed.add(rest.slice(c + 1)); }
    }
    media = media.filter((r) => !doomed.has(r));
    draw();
  };

  const draw = () => {
    strip.replaceChildren();
    for (const ref of media) {
      const geo = parseGeo(ref);
      if (geo) {
        // The location is a synthetic `geo:` ref rather than a file, so it gets a chip — otherwise
        // there is no way to take a location back off a post.
        strip.append(el("div", { class: "chip", style: "width:auto;padding:0 8px" },
          el("span", { class: "muted small" }, "📍 " + (geo.label || t("location"))),
          el("span", { class: "x", onclick: () => dropRef(ref) }, "×")));
        continue;
      }
      if (isSyntheticMedia(ref)) continue;        // markers ride with their parent, never shown
      const node = isVideoRef(ref)
        ? el("video", { "data-ref": ref, muted: "" })
        : el("img", { "data-ref": ref });
      strip.append(el("div", { class: "chip" }, node, el("span", { class: "x", onclick: () => dropRef(ref) }, "×")));
    }
    hydrateMedia(strip, circleId);
    const hasVideo = media.some(isVideoRef);
    muteBtn.style.display = hasVideo && !music ? "" : "none";
    musicRow.replaceChildren(music
      ? el("div", { class: "song-chip", style: "margin-top:0" },
          el("span", { class: "note" }, icon("music.note")),
          el("div", { style: "flex:1;min-width:0" }, el("strong", {}, music.title), " — ", music.artist),
          el("span", { class: "x", style: "position:static;cursor:pointer",
                       onclick: () => { music = null; draw(); } }, "×"))
      : null);
  };

  const muteBtn = el("button", { class: "btn small ghost", style: "display:none", onclick: () => {
    muteVideo = !muteVideo;
    muteBtn.textContent = muteVideo ? t("video_muted") : t("mute_video");
    muteBtn.classList.toggle("primary", muteVideo);
  } }, muteVideo ? t("video_muted") : t("mute_video"));
  if (muteVideo) muteBtn.classList.add("primary");

  fileInput.addEventListener("change", async (e) => {
    for (const f of e.target.files) {
      const isVideo = f.type.startsWith("video");
      const b64 = await sanitizeMediaFile(f, isVideo);
      if (b64 === null) continue;
      try {
        const ref = await invoke("add_media", { circleId, dataBase64: b64, isVideo });
        media.push(ref);
        if (!isVideo) {
          const th = await mintThumb(b64, circleId);
          if (th) media.push(`thumb:${ref}:${th}`);
          const pv = await mintPreview(b64, circleId);
          if (pv) media.push(`preview:${ref}:${pv}`);
        }
        draw();
      } catch (err) { toast(t("couldnt_attach", err)); }
    }
    fileInput.value = "";
  });

  draw();
  modal(el("div", {}, el("h2", {}, t("edit_post")), ta, strip, musicRow,
    el("div", { class: "row wrap", style: "gap:8px;margin-top:10px" },
      el("button", { class: "btn", onclick: () => fileInput.click() }, icon("photo"), t("photo_or_video")),
      el("button", { class: "btn", onclick: () => musicDialog((m) => { music = m; draw(); },
        { caption: () => ta.value, createdAt: it.created_at }) },
        icon("music.note"), music ? t("change") : t("add_a_song")),
      muteBtn, fileInput),
    el("div", { class: "row", style: "margin-top:12px;justify-content:flex-end" },
      el("button", { class: "btn primary", onclick: async (e) => {
        // A failed edit used to close the dialog exactly like a successful one, so "save" could be
        // a silent no-op — which is what it looked like while an import held the engine busy.
        const btn = e.currentTarget;
        btn.disabled = true;
        try {
          await invoke("edit_post", {
            circleId, target: it.id, body: ta.value.trim(),
            media, music, muteVideo,
          });
          closeModal();
          toast(t("saved"));
        } catch (err) {
          btn.disabled = false;
          toast(t("couldnt_save", err));   // dialog STAYS open, with the edit intact
        }
      } }, t("save")))));
}

function newCircleDialog() {
  const inp = el("input", { placeholder: t("circle_name_ph") });
  modal(el("div", {}, el("h2", {}, t("new_circle")), inp,
    el("div", { class: "row", style: "margin-top:12px;justify-content:flex-end" },
      el("button", { class: "btn primary", onclick: async () => { if (inp.value.trim()) { state.activeCircle = await invoke("create_circle", { name: inp.value.trim() }); } $("#modal-root").replaceChildren(); renderFeed(); } }, t("create")))));
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
  const nickInp = el("input", { value: CircleNick.get(circle.id) || "", placeholder: t("your_name_for_circle_ph") });
  const contacts = await invoke("contacts").catch(() => []);
  // Switch-Flip 1.0.7 §2: the circle's current admin set (creator + delegated admins), so we can
  // label existing admins and only offer promotion to the rest.
  const admins = new Set(
    (await invoke("circle_admins", { circleId: circle.id }).catch(() => [])).map((h) => h.toLowerCase()),
  );
  const memberList = el("div", { class: "col" });
  if (!contacts.length) memberList.append(el("div", { class: "muted small" }, t("no_contacts_connect_first")));
  for (const c of contacts) {
    const isAdmin = admins.has((c.id_hex || "").toLowerCase());
    memberList.append(el("div", { class: "list-item" },
      el("div", { class: "avatar", style: "width:30px;height:30px;font-size:12px" }, initials(c.name)),
      el("div", { style: "flex:1" }, c.name),
      el("button", { class: "btn small", onclick: async (e) => {
        try { await invoke("add_to_circle", { circleId: circle.id, contactIdHex: c.id_hex }); e.target.textContent = t("added_check"); e.target.disabled = true; toast(t("added_name", c.name)); }
        catch (err) { toast(t("couldnt_add", err)); }
      } }, t("add")),
      // §2: promote a member to admin (creator/admin only — the engine refuses otherwise). Admins can
      // remove members from the encrypted group (MLS Remove), so this is a deliberate, per-member act.
      isAdmin
        ? el("span", { class: "muted small", title: t("circle_admin"), style: "align-self:center" }, t("admin_check"))
        : el("button", { class: "btn small ghost", title: t("make_admin_title"), onclick: async (e) => {
            try {
              const ok = await invoke("grant_circle_admin", { circleId: circle.id, adminHex: c.id_hex });
              if (ok) { e.target.textContent = t("admin_check"); e.target.disabled = true; toast(t("now_admin", c.name)); }
              else { toast(t("only_creator_promote")); }
            } catch (err) { toast(t("couldnt_promote", err)); }
          } }, t("make_admin")),
      // Removing works for the DEFAULT circle ("My Circle") too: the engine writes the authoritative
      // removal tombstone AND purges them, so they can't auto-rejoin on their next handshake/self-sync.
      // (Previously hidden for default, which is why a removed member silently rejoined.)
      el("button", { class: "btn small ghost", title: isDefault ? t("remove_from_my_circle") : t("remove_from_this_circle"), onclick: async (e) => {
        try { await invoke("remove_from_circle", { circleId: circle.id, contactIdHex: c.id_hex }); e.target.textContent = t("removed_check"); e.target.disabled = true; toast(t("removed_name", c.name)); renderFeed(); }
        catch (err) { toast(t("couldnt_remove", err)); }
      } }, t("remove"))));
  }
  // Per-circle relay override: pick which CONFIGURED relays this circle uses, beyond the all-circles
  // default. No inline relay configuration here — that lives under Relays (the ⚙ → "Manage relays" link).
  const allRelays = (await invoke("relays").catch(() => [])).filter((r) => r.active);
  const explicit = new Set(await invoke("circle_relays", { circleId: circle.id }).catch(() => []));
  const relaySection = el("div", { class: "col" });
  if (!allRelays.length) {
    relaySection.append(el("div", { class: "muted small" }, t("no_relays_configured")));
  } else {
    for (const r of allRelays) {
      const on = explicit.has(r.node_hex) || r.is_default;
      const chk = el("input", { type: "checkbox", style: "width:auto" }); chk.checked = on; chk.disabled = r.is_default;
      chk.onchange = async () => { try { await invoke("set_circle_relay", { nodeHex: r.node_hex, circleId: circle.id, on: chk.checked }); toast(t("updated_toast")); } catch (e) { toast("" + e); chk.checked = !chk.checked; } };
      relaySection.append(el("label", { class: "row", style: "gap:8px;align-items:center" }, chk,
        el("span", { style: "flex:1" }, r.name + (r.is_default ? t("default_all_circles_suffix") : "") + (r.is_s3 ? " · S3" : ""))));
    }
  }
  relaySection.append(el("button", { class: "btn small ghost", style: "align-self:flex-start", onclick: () => relaySheet() }, t("manage_relays_link")));

  // The circle's own name (nickname-resolved), not a hardcoded "My Circle" — this sheet manages
  // whichever circle is active.
  sheet(circleDisplayName(circle.id, circle.name), el("div", { class: "col" },
    // Connect's front door, now that it isn't a tab — the same prominent gradient pill macOS gives
    // it in YouView.actionsRow.
    el("button", { class: "btn primary wide", onclick: () => connectSheet() }, t("invite_someone")),
    el("label", { class: "muted small", style: "margin-top:6px" }, t("name_label")),
    el("div", { class: "row" }, nameInp,
      el("button", { class: "btn", onclick: async () => { const n = nameInp.value.trim(); if (n && n !== circle.name) { await invoke("rename_circle", { id: circle.id, name: n }); toast(t("renamed_toast")); closeModal(); renderFeed(); } } }, t("rename"))),
    el("div", { class: "muted small" }, t("circle_name_hint")),
    // A PRIVATE name, alongside the shared rename above. Renaming already renamed it for everyone in
    // the circle, which is not the same thing as wanting your own name for it.
    el("label", { class: "muted small", style: "margin-top:6px" }, t("your_name_label")),
    el("div", { class: "row" }, nickInp,
      el("button", { class: "btn", onclick: () => {
        CircleNick.set(circle.id, nickInp.value);
        toast(nickInp.value.trim() ? t("saved_only_you") : t("using_circles_own_name"));
        closeModal(); renderFeed(); renderTitlebarTrailing();
      } }, t("save"))),
    el("div", { class: "muted small" }, t("nickname_hint")),
    el("label", { class: "muted small", style: "margin-top:6px" }, t("relays_for_circle")),
    el("div", { class: "muted small" }, t("relays_for_circle_hint")),
    relaySection,
    el("label", { class: "muted small", style: "margin-top:6px" }, t("members_label")),
    memberList,
    isDefault ? null : el("button", { class: "btn danger", style: "margin-top:6px", onclick: async () => {
      await invoke("leave_circle", { id: circle.id }); state.activeCircle = "default"; closeModal(); toast(t("left_circle_toast")); renderFeed();
    } }, t("leave_this_circle")),
  ));
}

function hydrateMedia(root, circleId) {
  // Skip anything already resolved. A node keeps its data-ref after loading (the toggle and the
  // evicted/retry paths look it up), so a second hydrate over the same subtree would re-invoke
  // media_data_url for every tile it already has. That was harmless while a feed was hydrated once;
  // with the feed now rendering in pages it would re-resolve every earlier page on each new one —
  // O(n^2) IPC and decodes, which is precisely the cost paging exists to avoid.
  $$("[data-ref]", root).forEach((node) => {
    if (node.dataset.hydrated === "1") return;
    node.dataset.hydrated = "1";
    loadMedia(node, circleId, node.dataset.ref);
  });
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
  }, t("caption_your_story"), {
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
  const hint = el("div", { style: "position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:rgba(255,255,255,.5);font-size:12px;pointer-events:none" }, t("preview"));
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
      soundBtn.textContent = previewMusic ? t("song_plays") : on ? t("clip_sound_on") : t("clip_sound_off");
      soundBtn.disabled = !!previewMusic;
      soundBtn.title = previewMusic
        ? t("song_soundtrack_title")
        : t("hear_clip_title");
      soundBtn.classList.toggle("primary", on);
    }
  };
  const soundBtn = el("button", { class: "btn small ghost", style: "display:none",
    onclick: () => { previewSound = !previewSound; syncPreviewAudio(); } }, t("clip_sound_off"));
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
      el("button", { title: t("caption_color"), style:
        "width:20px;height:20px;border-radius:50%;padding:0;cursor:pointer;background:" + c +
        ";border:2px solid " + (i === spec.color ? "var(--text, #fff)" : "rgba(128,128,128,.35)"),
        onclick: () => { spec.color = i; drawSwatches(); renderCap(); } })));
  };
  drawSwatches();
  const STYLES = [t("style_plain"), t("style_glow"), t("style_shadow"), t("style_neon"), t("style_highlight")];   // wire styleRaw order
  const styleBtn = el("button", { class: "btn small ghost", title: t("caption_style"),
    onclick: () => { spec.style = (spec.style + 1) % STYLES.length; styleBtn.textContent = "Aa · " + STYLES[spec.style]; renderCap(); } },
    "Aa · " + STYLES[spec.style]);
  const fontBtn = el("button", { class: "btn small ghost", title: t("caption_font"),
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
  resetBtn = el("button", { class: "btn small ghost", style: "display:none", title: t("undo_framing_title"),
    onclick: () => {
      spec.mediaScale = 1; spec.mediaOffX = 0; spec.mediaOffY = 0; spec.mediaRotation = 0; mediaRotDeg = 0;
      applyMediaTransform();
    } }, t("reset_framing"));

  sheet(t("new_story"), el("div", { class: "col" },
    el("div", { class: "muted small" }, t("story_hint")),
    frame,
    // Spelled out because none of these are guessable: the modifiers ARE the discoverability.
    el("div", { class: "muted small", style: "text-align:center" },
      t("story_gestures_hint")),
    swatches,
    el("div", { class: "row", style: "gap:8px;align-items:center" },
      styleBtn, fontBtn, el("span", { class: "muted small" }, t("size_label")), sizeInp),
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
/** The artwork URL for a track, ignoring anything else riding in that field.
 *
 *  TrackRef has no field for a story's chosen section, so Apple encodes it into artwork_url as
 *  "start:<ms>" — and, since suggestions started carrying real artwork, as "start:<ms>;<url>". A URL
 *  can neither begin with "start:" nor contain an unescaped ";", so the split is unambiguous. Without
 *  this, a story song authored on an iPhone hands desktop a string that is not a URL and the chip
 *  renders no art at all.
 */
function musicArtwork(m) {
  const raw = (m && m.artwork_url) || "";
  if (!raw.startsWith("start:")) return raw;
  const semi = raw.indexOf(";");
  return semi > 0 ? raw.slice(semi + 1) : "";
}

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
    title: t("open_in_music_app"),
    onclick: (e) => { e.stopPropagation(); if (url) openExternal(url); },
  }, (() => { const a = musicArtwork(m);
       return a ? el("img", { src: a, class: "song-art", alt: "", loading: "lazy", decoding: "async" })
                : el("span", { class: "note" }, icon("music.note")); })(),
     el("span", { style: "flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" },
       el("strong", {}, m.title || t("unknown_song")), m.artist ? ` · ${m.artist}` : ""));
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
  const slot = el("div", { class: "col story-canvas", style: "align-items:center" });
  const hint = el("div", { class: "muted small", style: "text-align:center;margin-top:8px" },
    t("story_viewer_hint"));
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
    keepBtn.replaceChildren(on ? t("kept") : t("keep"));
    keepBtn.title = on ? t("kept_on_profile") : t("keep_on_profile");
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
    if (on === null) { toast(t("couldnt_update_keep")); return; }
    if (on) keptIds.add(it.id); else keptIds.delete(it.id);
    paintKeep();
  });
  // Reply privately — DM the author with a story deep link (tall crop in the thread; tap opens
  // this viewer). Not shown on your own story.
  const replyRow = el("div", { class: "row", style: "gap:8px;margin-top:10px;display:none" });
  const replyInput = el("input", {
    type: "text", class: "field", style: "flex:1",
    placeholder: t("story_reply_placeholder", ""),
  });
  const replySend = el("button", { class: "primary", style: "flex:0" }, t("send"));
  replyRow.append(replyInput, replySend);
  const paintReply = () => {
    const it = stories[index];
    if (!it || it.is_me) { replyRow.style.display = "none"; return; }
    replyRow.style.display = "";
    const name = it.author_name || t("friend");
    replyInput.placeholder = t("story_reply_placeholder", name);
  };
  replySend.addEventListener("click", async (e) => {
    e.stopPropagation();
    const it = stories[index];
    if (!it || it.is_me) return;
    const text = (replyInput.value || "").trim();
    if (!text) return;
    // Find the author's full hex among contacts so we can open/reuse a DM.
    const contacts = await invoke("contacts").catch(() => []);
    const short = (it.author_short || "").toString();
    const c = (contacts || []).find((x) =>
      (x.id_hex || "").startsWith(short) ||
      (x.name || "") === it.author_name);
    if (!c || !c.id_hex) { toast(t("story_reply_no_contact")); return; }
    const dmId = await invoke("start_dm", { contactIdHex: c.id_hex, contactName: c.name || it.author_name }).catch(() => null);
    if (!dmId) { toast(t("story_reply_failed")); return; }
    const circleId = it._circle || state.activeCircle || "default";
    const link = DeepLink.storyLink(circleId, it.id);
    const body = text + "\n" + link;
    await invoke("send_dm", { circleId: dmId, body, media: [], music: null, retentionSecs: null }).catch(() => null);
    replyInput.value = "";
    toast(t("story_sent_privately"));
  });
  const actions = el("div", { class: "row", style: "justify-content:center" }, keepBtn);
  // LAYERED OVER THE STORY, not stacked around it.
  //
  // Every other platform puts the story full-bleed and floats its chrome on top — Apple builds it
  // as a ZStack with the content ignoring the safe area and the controls in an `.overlay`. Desktop
  // laid the same pieces out in a COLUMN, so the progress bars, the name, the Keep button and the
  // reply field all sat outside the picture in a card. Same parts, wrong plane.
  const stage = el("div", { class: "story-stage" },
    slot,
    el("div", { class: "story-top" }, bars, title),
    el("div", { class: "story-bottom" }, actions, replyRow, hint));
  const card = el("div", { class: "story-shell" }, stage);
  const close = modal(card);
  // Which of these are already kept — one call for the whole session, refreshed locally on toggle.
  invoke("kept_stories").then((ks) => { keptIds = new Set((ks || []).map((k) => k.id)); paintKeep(); }).catch(() => {});

  const cleanup = () => {
    clearAdvance();
    stopSong();
    window.removeEventListener("keydown", onKey, true);
    mo.disconnect();
    // Closing the viewer must silence the clip that was on screen, for the same reason paging does:
    // tearing the modal down detaches the element without stopping it.
    slot.querySelectorAll("video").forEach((v) => {
      try { v.pause(); v.removeAttribute("src"); v.load(); } catch (_) {}
    });
  };
  const done = () => { close(); cleanup(); };

  const show = () => {
    const it = stories[index];
    title.textContent = t("whose_story", it.is_me ? t("you") : it.author_name);
    // One progress segment per story in THIS person's run, filled through the current one.
    let runStart = index; while (runStart > 0 && author(runStart - 1) === author(index)) runStart--;
    let runEnd = index; while (runEnd < stories.length - 1 && author(runEnd + 1) === author(index)) runEnd++;
    // WINDOWED. One segment per story is right for a normal run, and unreadable for a long one:
    // a profile holding 84 kept stories drew 84 segments across ~430px — about a pixel each, which
    // is why the bar looked missing rather than crowded. Beyond a couple of dozen it shows a window
    // around the current story instead, which is what Instagram does for the same reason.
    const runLen = runEnd - runStart + 1;
    const MAX_SEGS = 24;
    let from = runStart, count = runLen;
    if (runLen > MAX_SEGS) {
      count = MAX_SEGS;
      from = Math.min(Math.max(runStart, index - Math.floor(MAX_SEGS / 2)), runEnd - MAX_SEGS + 1);
    }
    bars.replaceChildren(...Array.from({ length: count }, (_, k) =>
      el("span", { class: "seg" + (from + k <= index ? " on" : "") })));
    // STOP the outgoing clip before dropping it. Detaching a <video> from the DOM does NOT stop
    // playback — the element keeps running (and keeps making noise) until it is paused and its
    // source released. Paging through a run of stories therefore left every clip already visited
    // still playing, which is why an import's worth of stories all sounded at once.
    slot.querySelectorAll("video").forEach((v) => {
      try { v.pause(); v.removeAttribute("src"); v.load(); } catch (_) {}
    });
    slot.replaceChildren(storyContentNode(it));
    hydrateMedia(slot, it._circle || state.activeCircle || "default");
    paintKeep();   // the pill belongs to the story on screen, not to the viewer
    paintReply();
    armAdvance();
    playStorySong(it);

  };

  // THE STORY'S SONG. Desktop showed the chip and never played it — the note on `storySongChip`
  // says a half-working player would be worse than none, which was true while there was no way to
  // resolve a TrackRef to something playable. `music_resolve` is that way, so the song plays here
  // as it does on every other platform: the clip is already force-muted when a song is attached
  // (see `songMuted`), so the song IS the story's audio rather than competing with it.
  //
  // The token guards the same race the feed player hit: resolving is a network round trip, stories
  // advance every few seconds, and two resolves finishing out of order would leave one playing with
  // nothing holding it.
  let songAudio = null, songToken = 0;
  const stopSong = () => {
    if (songAudio) { try { songAudio.pause(); songAudio.src = ""; } catch (_) {} songAudio = null; }
    songToken++;
  };
  const playStorySong = async (it) => {
    stopSong();
    const m = it && it.music;
    if (!m || !m.title || state.superDataSaver) return;
    const token = ++songToken;
    const key = m.title + "|" + (m.artist || "");
    let url = Autoplay.song.cache.get(key);      // shared with the feed: resolve each song once
    if (url === undefined) {
      const hit = await invoke("music_resolve", {
        title: m.title, artist: m.artist || "", catalogId: m.catalog_id || "",
      }).catch(() => null);
      url = (hit && hit.preview_url) || null;
      Autoplay.song.cache.set(key, url);
    }
    // The reader may have advanced while that resolved.
    if (!url || token !== songToken || !card.isConnected) return;
    songAudio = new Audio(url);
    songAudio.loop = true;
    songAudio.play().catch(() => { songAudio = null; });
  };

  // AUTO-ADVANCE. Desktop never had any: a story sat there until tapped, and a video story was
  // created with `loop`, so it played the same clip forever. Every other platform moves on by
  // itself — a still after a few seconds, a clip when it ends — which is what makes a run of
  // stories a run rather than a slideshow you have to click through.
  let advanceTimer = null;
  const STILL_MS = 5000;
  const clearAdvance = () => { if (advanceTimer) { clearTimeout(advanceTimer); advanceTimer = null; } };
  const armAdvance = () => {
    clearAdvance();
    const v = slot.querySelector("video");
    if (v) {
      // A clip runs to its own end. `loop` is dropped here rather than at creation so the story
      // EDITOR's preview, which shares that builder, keeps looping as it should.
      v.loop = false;
      v.addEventListener("ended", () => { if (card.isConnected) nextStory(); }, { once: true });
      // A clip that cannot report its end (unreadable duration) still must not strand the run.
      const ms = Number.isFinite(v.duration) && v.duration > 0 ? v.duration * 1000 + 500 : 15000;
      advanceTimer = setTimeout(() => { if (card.isConnected) nextStory(); }, ms);
      return;
    }
    advanceTimer = setTimeout(() => { if (card.isConnected) nextStory(); }, STILL_MS);
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

/** Tall portrait tile for a story deep link in a DM — tap opens the real story viewer. */
function storyReplyCard(circleId, postId) {
  const card = el("button", {
    class: "story-reply-card",
    type: "button",
    style: "width:128px;aspect-ratio:9/16;border-radius:14px;overflow:hidden;padding:0;border:1px solid color-mix(in srgb, var(--text) 10%, transparent);background:var(--card);cursor:pointer;position:relative;display:block",
    title: t("view_story"),
    onclick: () => openStoryLink(circleId, postId),
  });
  const thumb = el("div", {
    style: "position:absolute;inset:0;background:center/cover no-repeat #222;display:flex;align-items:center;justify-content:center;color:#fff;font-size:22px",
  }, "▶");
  card.append(thumb);
  (async () => {
    try {
      const kept = await invoke("kept_stories").catch(() => []);
      let it = null;
      const k = (kept || []).find((x) => x.id === postId);
      if (k && (k.media || []).length) {
        it = { media: k.media || [], body: k.body || "", created_at: k.createdAt || k.created_at };
      } else {
        let msgs = await invoke("messages", { circleId }).catch(() => []);
        it = (msgs || []).find((i) => i.id === postId && i.story && !i.unsent
          && !isPastStoryWindow(i.created_at));
      }
      if (!it) {
        card.onclick = null;
        card.style.cursor = "default";
        thumb.replaceChildren();
        thumb.append(
          el("div", { style: "padding:10px;text-align:center;font-size:12px;line-height:1.3;color:var(--muted,#888)" },
            el("div", { style: "font-size:18px;margin-bottom:6px" }, "⏱"),
            t("story_no_longer_available")));
        return;
      }
      const refs = displayMediaRefs(it.media || []);
      const ref = refs.find((r) => isVideoRef(r))
        ? (refs.find((r) => !isVideoRef(r) && !isAudioRef(r)) || refs[0])
        : refs[0];
      if (ref) {
        thumb.setAttribute("data-ref", ref);
        hydrateMedia(card, circleId);
      }
    } catch (_) { /* leave play affordance */ }
  })();
  return card;
}

function storyNoLongerAvailableCard() {
  return el("div", {
    style: "width:128px;aspect-ratio:9/16;border-radius:14px;background:var(--card);display:flex;align-items:center;justify-content:center;padding:10px;text-align:center;font-size:12px;line-height:1.3;color:var(--muted,#888);border:1px solid color-mix(in srgb, var(--text) 10%, transparent)",
  }, el("div", {},
    el("div", { style: "font-size:18px;margin-bottom:6px" }, "⏱"),
    t("story_no_longer_available")));
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

  const openDm = (th) => { state.activeDm = { id: th.circle_id, name: th.name }; renderMessages(); };
  const del = async (th) => {
    if (!confirm(t("delete_convo_confirm", th.name))) return;
    Pins.remove(th.circle_id);
    await invoke("delete_conversation", { circleId: th.circle_id });
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
  const threadRow = (th) => {
    const unread = th.unread || 0;
    // (`dm_threads` carries no unsent flag, and src-tauri isn't mine to change — the thread view
    // renders the "Message unsent" tombstone properly, which is where it matters.)
    const preview = isSecret(th.last_body) ? t("secret_message_preview") : (th.last_body || t("no_messages_yet"));
    const kebab = el("button", { class: "kebab", title: t("more"), "aria-label": t("more") }, icon("ellipsis"));
    kebab.addEventListener("click", (e) => {
      e.stopPropagation();
      popMenu(kebab, [
        Pins.has(th.circle_id)
          ? { label: t("unpin"), icon: "mappin", on: () => { Pins.toggle(th.circle_id); renderMessages(); } }
          : { label: t("pin"), icon: "mappin", on: () => { if (Pins.full) { toast(t("pin_limit")); return; } Pins.toggle(th.circle_id); renderMessages(); } },
        { label: t("delete"), icon: "eye.slash", danger: true, on: () => del(th) },
      ], { align: "right" });
    });
    return el("div", { class: "thread-item", onclick: () => openDm(th) },
      el("div", { class: "avatar" }, initials(th.name)),
      el("div", { style: "flex:1;min-width:0" },
        el("div", { class: "name" + (unread > 0 ? " unread" : "") }, th.name),
        el("div", { class: "preview" + (unread > 0 ? " unread" : ""), style: "white-space:nowrap;overflow:hidden;text-overflow:ellipsis" }, preview)),
      el("div", { class: "muted small" }, relTime(th.last_at)),
      unread > 0 ? unreadPill(unread) : null,
      kebab,
    );
  };

  const list = el("div", { class: "thread-list" });
  if (pinned.length) list.append(grid);
  for (const t of rest) list.append(threadRow(t));
  if (!threads.length) {
    list.append(el("div", { class: "empty" },
      el("div", { class: "h" }, t("no_messages_yet")),
      el("div", {}, t("messages_empty_sub"))));
  }
  root.replaceChildren(el("div", { class: "col-wrap" },
    el("div", { class: "view-head" }, el("h1", {}, t("messages"))),
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
  const startBtn = el("button", { class: "btn primary wide", disabled: true, onclick: start }, t("start"));
  const title = el("h2", {}, t("new_message"));
  const sync = () => {
    startBtn.disabled = picked.size === 0;
    startBtn.textContent = picked.size > 1 ? t("start_group") : t("start");
    title.textContent = picked.size > 1 ? t("new_group_n", picked.size) : t("new_message");
  };
  const col = el("div", { class: "col", style: "gap:2px" });
  if (!contacts.length) col.append(el("div", { class: "muted small" }, t("no_contacts_invite_first")));
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
  sheet(t("new_message"), col, startBtn);
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
  // Story inventory for retroactive legacy story-reply matching (media attach without deep link).
  let threadLiveStories = [];
  let threadKeptMine = [];
  let dmPeerHex = null;
  try {
    const circles = await invoke("circles").catch(() => []);
    for (const c of circles || []) {
      if (String(c.id || "").startsWith("dm:")) continue;
      const items = await invoke("messages", { circleId: c.id }).catch(() => []);
      for (const s of items || []) {
        if (!s.story || s.unsent) continue;
        threadLiveStories.push({
          circleId: c.id, id: s.id, author_short: s.author_short, is_me: s.is_me,
          created_at: s.created_at, has_media: (s.media || []).length > 0,
        });
      }
    }
    const kept = await invoke("kept_stories").catch(() => []);
    threadKeptMine = (kept || []).map((k) => ({ id: k.id, createdAt: k.createdAt || k.created_at }));
    if (!isGroup) {
      const contacts = await invoke("contacts").catch(() => []);
      const c = (contacts || []).find((x) => x.name === dm.name || x.name === meta?.name);
      if (c) dmPeerHex = c.id_hex;
    }
  } catch (_) {}
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

    // Story reply: explicit deep link OR retroactive match for legacy media-only attaches.
    // (liveStories/keptMine filled once per thread open — see below loop setup)
    const storyHit = (!m.unsent)
      ? DeepLink.storyReplyTarget(m, { peerHex: dmPeerHex, liveStories: threadLiveStories, keptMine: threadKeptMine })
      : null;
    let bodyText = m.body || "";
    if (storyHit && storyHit.raw) {
      bodyText = bodyText.replace(storyHit.raw, "").replace(/[ \t]{2,}/g, " ").replace(/\n{3,}/g, "\n\n").trim();
    }
    const storyVisualOnly = !storyHit && mediaEls.length === 1
      && displayMediaRefs(m.media || []).filter((r) => !isAudioRef(r) && !String(r).startsWith("geo:")).length === 1;

    // An unsent message is a TOMBSTONE, not a hidden row — macOS renders "Message unsent" in
    // italic on the secondary surface, so the thread still reads as a conversation.
    let bubble;
    if (m.unsent) bubble = el("div", { class: "chat-bubble tombstone" }, t("message_unsent"));
    else if (isSecret(m.body)) { bubble = secretBubble(m.body, m.is_me); if (mediaEls.length) bubble.append(...mediaEls); }
    else if (bodyText) bubble = el("div", { class: "chat-bubble" + (m.is_me ? " me" : "") }, bodyText);
    else bubble = null;

    const col = el("div", { class: "bubble-col" });
    // In a group DM, label each INCOMING message with who sent it.
    if (isGroup && !m.is_me && !m.unsent) col.append(el("div", { class: "chat-sender" }, m.author_name || t("someone")));
    if (storyHit) {
      col.append(storyReplyCard(storyHit.circleId, storyHit.postId));
    } else if (storyVisualOnly && isPastStoryWindow(m.created_at)) {
      // Legacy story reply whose event is gone — never keep the resealed media forever.
      col.append(storyNoLongerAvailableCard());
    } else if (storyVisualOnly) {
      // Young unmatched attach: tall crop until the story window passes.
      const wrap = el("div", { class: "bubble-media story-tall" });
      mediaEls.forEach((n) => {
        n.style.maxWidth = "128px";
        n.style.width = "128px";
        n.style.aspectRatio = "9/16";
        n.style.objectFit = "cover";
        n.style.borderRadius = "14px";
        wrap.append(n);
      });
      col.append(wrap);
    } else if (mediaEls.length && !isSecret(m.body)) {
      col.append(el("div", { class: "bubble-media" }, ...mediaEls));
    }
    if (m.music) {
      col.append(el("a", { class: "song-chip glass tint-pink", style: "margin-top:0;max-width:260px",
        title: t("open_in_music_app"),
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
        rr.append(el("button", { class: "msg-react" + (r.mine ? " mine" : ""), title: r.mine ? t("remove_reaction") : t("react"),
          onclick: () => invoke(r.mine ? "unreact" : "react", { circleId: dm.id, target: m.id, emoji: r.emoji }) },
          r.emoji + (r.count > 1 ? " " + r.count : "")));
      }
      col.append(rr);
    }
    const meta2 = el("div", { class: "chat-meta" }, relTime(m.created_at));
    if (m.edited && !m.unsent) meta2.append(el("span", {}, t("edited")));
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
          ...frequentEmoji(3).map((emo) => ({ label: t("react_emoji", emo), on: () => { EmojiStore.record(emo); invoke("react", { circleId: dm.id, target: m.id, emoji: emo }); } })),
          { label: t("more_reactions_menu"), icon: "plus.circle", on: () => emojiPicker(anchor, dm.id, m.id) },
          (m.is_me && m.body && !isSecret(m.body)) ? { sep: true } : null,
          (m.is_me && m.body && !isSecret(m.body)) ? { label: t("edit"), icon: "pencil.circle.fill", on: () => beginEdit(m) } : null,
          m.is_me ? { label: t("delete"), icon: "eye.slash", danger: true, on: () => invoke("unsend_post", { circleId: dm.id, target: m.id }) } : null,
        ]);
      });
    }
    chat.append(row);
  }

  const input = el("textarea", { class: "composer-field glass", placeholder: t("message_ph"), rows: 1 });
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
      el("span", { class: "muted small" }, t("editing_message")),
      el("div", { class: "spacer" }),
      el("button", { class: "pill-btn glass", onclick: () => { editingId = null; input.value = ""; autoGrow(); editBar.style.display = "none"; } }, t("cancel")),
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

  // Disappearing messages, STICKY for the conversation until turned Off — Apple's DM behaviour
  // (its feed composer resets per post; the thread does not). Desktop had no control at all.
  let dmRetentionSecs = null;
  const dmRetentionRow = el("div", {});
  const drawDmRetention = () => {
    dmRetentionRow.replaceChildren(dmRetentionSecs
      ? el("div", { class: "song-chip", style: "margin-top:0" },
          el("span", { class: "note" }, "\u23F1"),
          el("div", { style: "flex:1;min-width:0" },
            t("disappears_after_label", dmRetentionSecs < 3600 ? Math.round(dmRetentionSecs / 60) + "m"
              : dmRetentionSecs < 86400 ? Math.round(dmRetentionSecs / 3600) + "h"
              : dmRetentionSecs < 604800 ? Math.round(dmRetentionSecs / 86400) + "d"
              : Math.round(dmRetentionSecs / 604800) + "w")),
          el("span", { class: "x", style: "position:static;cursor:pointer",
                       onclick: () => { dmRetentionSecs = null; drawDmRetention(); } }, "\u00D7"))
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
      await invoke("send_dm", { circleId: dm.id, body: t ? (secretOn ? SECRET_MARKER + t : t) : "", media: [], music: pendingMusic, retentionSecs: dmRetentionSecs });
      pendingMusic = null; drawDmMusic();
    }
    input.value = ""; autoGrow();
  };
  input.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); sendText(); } });

  const setSecret = (on) => {
    secretOn = on;
    input.classList.toggle("tint-pink", on);
    input.placeholder = on ? t("secret_message_ph") : t("message_ph");
  };
  const plus = el("button", { class: "composer-plus", title: t("attach"), "aria-label": t("attach") }, icon("plus"));
  plus.addEventListener("click", () => popMenu(plus, [
    { label: t("photo_or_video"), icon: "photo", on: async () => { const r = await cameraDialog(dm.id); if (r) await invoke("send_dm", { circleId: dm.id, body: "", media: [r.ref], music: null, retentionSecs: dmRetentionSecs }); } },
    { label: t("voice_message_menu"), icon: "mic", on: async () => { const r = await recordVoice(dm.id); if (r) await invoke("send_dm", { circleId: dm.id, body: "", media: [r], music: null, retentionSecs: dmRetentionSecs }); } },
    // Attaches to the NEXT send rather than firing immediately — a song usually accompanies a
    // message, and the composer shows it as a removable chip until you hit send (same as the feed).
    { label: t("add_a_song"), icon: "music.note", on: () => musicDialog((m) => { pendingMusic = m; drawDmMusic(); }) },
    { label: secretOn ? t("secret_on") : t("send_secretly"), icon: "lock.shield.fill", on: () => setSecret(!secretOn) },
    { sep: true },
    { label: t("disappears_after"), icon: "timer", on: () => popMenu(plus, [
      { label: t("dont_disappear"), on: () => { dmRetentionSecs = null; drawDmRetention(); } },
      { label: t("after_1_hour"), on: () => { dmRetentionSecs = 3600; drawDmRetention(); } },
      { label: t("after_1_day"), on: () => { dmRetentionSecs = 86400; drawDmRetention(); } },
      { label: t("after_1_week"), on: () => { dmRetentionSecs = 604800; drawDmRetention(); } },
    ]) },
  ]));

  const partner = dm.id.replace("dm:", "").split("-").find((h) => h !== state.node) || "";
  const presence = el("div", { class: "dm-presence" }, relayReachable ? t("connected") : t("offline"));

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
      el("button", { class: "icon-btn glass", title: t("back"), "aria-label": t("back"), onclick: () => { state.activeDm = null; renderMessages(); } },
        icon("chevron.right", "flip")),
      el("div", { style: "min-width:0" },
        el("div", { class: "dm-name" }, dm.name),
        presence),
      el("div", { class: "spacer" }),
      partner ? el("button", { class: "icon-btn glass", title: t("audio_call"), "aria-label": t("audio_call"), onclick: () => callStart([partner], dm.name, false) }, icon("phone.fill")) : null,
      partner ? el("button", { class: "icon-btn glass", title: t("video_call"), "aria-label": t("video_call"), onclick: () => callStart([partner], dm.name, true) }, icon("video.fill")) : null,
    ),
    chat,
    // Unlike the feed's composer, the DM composer DOES carry a glass band (macOS:
    // `.havenGlass(in: Rectangle())`) — it's the floor of the thread, not a pill over a gradient.
    el("div", { class: "dm-composer glass" }, editBar, musicRow, dmRetentionRow,
      el("div", { class: "composer-row" }, plus, input,
        el("button", { class: "composer-send", title: t("send"), "aria-label": t("send"), onclick: sendText }, icon("paperplane.fill")))),
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
  try { qrBox.innerHTML = makeQrSvg(state.inviteUri); } catch (_) { qrBox.textContent = t("qr_unavailable"); }

  const mine = el("div", { class: "card col" },
    el("h3", {}, t("your_invite")),
    el("div", { class: "muted small" }, t("your_invite_hint")),
    // `wrap` on both rows, not just one: the QR is a fixed 200-odd px and the two Copy buttons are
    // nowrap pills, so on a narrow sheet the text column has to be allowed to drop BELOW the QR and
    // the buttons below each other. Without it they only had one way out — through the card's edge.
    el("div", { class: "row wrap", style: "align-items:flex-start" }, qrBox,
      el("div", { class: "col", style: "flex:1 1 260px" },
        el("div", { class: "mono" }, state.inviteUri),
        el("div", { class: "row wrap" },
          el("button", { class: "btn small", onclick: () => { navigator.clipboard.writeText(state.inviteUri); toast(t("invite_copied")); } }, t("copy_haven_link")),
          el("button", { class: "btn small", onclick: () => { navigator.clipboard.writeText(state.inviteLink); toast(t("web_link_copied")); } }, t("copy_web_link")),
        ),
      ),
    ),
  );

  const linkInput = el("input", { placeholder: t("paste_invite_ph") });
  const add = el("div", { class: "card col" },
    el("h3", {}, t("connect_friend")),
    // Pasted links go through routeDeepLink, so a post link opens the post instead of being fed to the
    // invite handshake — an invite's payload has the same `<a>.<b>` fragment shape, so only the `p/`
    // check tells them apart.
    el("div", { class: "row" }, linkInput, el("button", { class: "btn primary", onclick: async () => {
      const kind = await routeDeepLink(linkInput.value);
      if (kind === "invite") { toast(t("invite_sent")); linkInput.value = ""; }
      else if (kind === "post") linkInput.value = "";
      else toast(t("not_haven_link"));
    } }, t("connect"))),
    el("button", { class: "btn ghost small", onclick: startScan }, t("scan_qr_camera")),
  );

  const pend = el("div", { class: "card col" }, el("h3", {}, t("requests_n", pending.length)));
  if (!pending.length) pend.append(el("div", { class: "muted small" }, t("no_pending_requests")));
  for (const p of pending) {
    pend.append(el("div", { class: "pending-item" },
      el("div", { class: "row" }, el("div", { class: "avatar" }, initials(p.name)),
        el("div", { style: "flex:1" }, el("div", { class: "name" }, p.name), el("div", { class: "muted small mono" }, t("safety_prefix") + p.verify_hex.slice(0, 16))),
        el("button", { class: "btn small primary", onclick: async () => { await invoke("approve", { idHex: p.id_hex }); toast(t("connected")); } }, t("accept")),
        el("button", { class: "btn small ghost", onclick: async () => { await invoke("dismiss", { idHex: p.id_hex }); } }, t("ignore")),
      )));
  }

  const cl = el("div", { class: "card col" }, el("h3", {}, t("contacts_n", contacts.length)));
  if (!contacts.length) cl.append(el("div", { class: "muted small" }, t("no_contacts_yet")));
  for (const c of contacts) {
    cl.append(el("div", { class: "list-item" },
      el("div", { class: "avatar" }, initials(c.name)),
      el("div", { style: "flex:1" }, el("div", { class: "name" }, c.name), el("div", { class: "muted small mono" }, c.id_hex.slice(0, 16) + "…")),
      el("button", { class: "btn small", onclick: async () => { const id = await invoke("start_dm", { contactIdHex: c.id_hex, contactName: c.name }); state.activeDm = { id, name: c.name }; closeModal(); switchView("messages"); } }, t("message_btn")),
      (() => { const k = el("button", { class: "kebab" }, icon("ellipsis")); k.addEventListener("click", () => contactMenu(k, c)); return k; })(),
    ));
  }

  sheet(t("connect"), el("div", { class: "col", style: "gap:16px" }, mine, add, pend, cl));
}

function contactMenu(anchor, c) {
  popMenu(anchor, [
    { label: t("block_person", c.name), icon: "hand.raised.fill", danger: true,
      on: async () => { await invoke("block", { idHex: c.id_hex }); toast(t("blocked_toast")); connectSheet(); } },
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
  const status = el("div", { class: "muted small" }, t("point_camera_qr"));
  let stream, raf;
  // The scanner is a live viewfinder — same rule as the camera: the feed goes quiet behind it.
  const releaseCapture = beginCapture(() => stop());
  const close = modal(el("div", {}, el("h2", {}, t("scan_qr")), video, status, canvas,
    el("div", { class: "row", style: "margin-top:10px;justify-content:flex-end" }, el("button", { class: "btn", onclick: () => stop() }, t("close")))));
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
          invoke("connect_by_link", { uri: code.data.trim() }).then((ok) => toast(ok ? t("invite_sent_short") : t("not_haven_qr")));
          return;
        }
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
  } catch (e) { status.textContent = t("camera_unavailable", e); }
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
    ...[[7, t("days_7")], [30, t("days_30")], [90, t("days_90")], [365, t("year_1")], [0, t("no_limit")]]
      .map(([v, label]) => el("option", Object.assign({ value: String(v) }, v === cur.max_age_days ? { selected: "" } : {}), label)));
  const sizeSel = el("select", {},
    ...[[8 * GB, "8 GB"], [32 * GB, "32 GB"], [128 * GB, "128 GB"], [512 * GB, "512 GB"], [0, t("no_limit")]]
      .map(([v, label]) => el("option", Object.assign({ value: String(v) }, v === cur.max_bytes ? { selected: "" } : {}), label)));
  const apply = async () => {
    await invoke("set_relay_media_limits", {
      maxAgeDays: Number(ageSel.value), maxBytes: Number(sizeSel.value),
    }).catch((e) => toast("" + e));
    toast(hosting ? t("saved_applies_next") : t("saved"));
  };
  ageSel.onchange = apply;
  sizeSel.onchange = apply;
  return el("div", { class: "col", style: "margin-top:10px" },
    el("label", { class: "muted small" }, t("keep_media_for")), ageSel,
    el("label", { class: "muted small", style: "margin-top:6px" }, t("media_storage_limit")), sizeSel,
    el("div", { class: "muted small" }, hosting
      ? t("relay_limits_hint_hosting")
      : t("relay_limits_hint")),
  );
}
async function relaySheet() {
  const s = await invoke("relay_status");
  const pub = await invoke("relay_public_settings").catch(() => ({
    public_url: "", tunnel_token: "", auto_tunnel: true, front_door: "auto", derp_url: "",
  }));
  const adoptInput = el("input", { placeholder: t("adopt_ph") });
  // Three first-class modes — Manual stays correct if free/token Cloudflare paths go away.
  let frontDoor = pub.front_door || "auto";
  const urlInput = el("input", {
    value: pub.public_url || "",
    placeholder: "https://relay.example.com",
  });
  const derpInput = el("input", {
    value: pub.derp_url || "",
    placeholder: t("derp_ph"),
  });
  const tokenInput = el("input", {
    type: "password",
    value: pub.tunnel_token || "",
    placeholder: t("token_ph"),
    autocomplete: "off",
  });
  const modeBox = el("div", { class: "col", style: "gap:4px" });
  const modes = [
    ["auto", t("mode_auto_label"), t("mode_auto_hint")],
    ["bundled", t("mode_bundled_label"), t("mode_bundled_hint")],
    ["manual", t("mode_manual_label"), t("mode_manual_hint")],
  ];
  const derpLabel = el("label", { class: "muted small", style: "margin-top:6px" }, t("derp_label"));
  const syncModeUi = () => {
    tokenInput.disabled = frontDoor === "manual" || frontDoor === "auto";
    tokenInput.style.opacity = tokenInput.disabled ? "0.5" : "1";
    urlInput.placeholder = frontDoor === "auto"
      ? t("url_ph_auto")
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
        ? t("saved_restart_hosting")
        : t("saved"));
    } catch (e) { toast("" + e); }
  };
  const publicCard = el("div", { class: "card col" },
    el("h3", {}, t("public_front_door")),
    el("div", { class: "muted small" },
      t("front_door_hint")),
    modeBox,
    el("label", { class: "muted small", style: "margin-top:8px" }, t("media_public_url")),
    urlInput,
    derpLabel,
    derpInput,
    el("label", { class: "muted small", style: "margin-top:6px" }, t("tunnel_token_label")),
    tokenInput,
    el("button", { class: "btn small primary", style: "align-self:flex-start;margin-top:8px", onclick: savePublic }, t("save_front_door")),
    el("div", { class: "muted small" },
      t("front_door_sealed"),
      el("a", { href: "https://wemiller.com/apps/haven/docs/#front-door", target: "_blank", style: "color:var(--pink);text-decoration:underline" }, t("learn_more"))),
  );
  const liveTunnelCard = (() => {
    if (!s.hosting) return null;
    const media = s.live_media_url || "";
    const derp = s.live_derp_url || "";
    if (!media && !derp) return null;
    if (s.path_routed && media) {
      return el("div", { class: "card col" },
        el("h3", {}, t("live_tunnel")),
        el("div", { class: "ok-text" }, t("live_tunnel_path")),
        el("div", { class: "mono", style: "word-break:break-all" }, media),
        el("button", { class: "btn small", style: "align-self:flex-start", onclick: () => { navigator.clipboard.writeText(media); toast(t("url_copied")); } }, t("copy")),
      );
    }
    if (media && derp && media !== derp) {
      return el("div", { class: "card col" },
        el("h3", {}, t("live_tunnels_dual")),
        el("div", { class: "muted small" }, t("dual_hint")),
        el("div", { class: "muted small" }, t("media_label")),
        el("div", { class: "mono", style: "word-break:break-all" }, media),
        el("div", { class: "muted small", style: "margin-top:6px" }, t("derp_fabric")),
        el("div", { class: "mono", style: "word-break:break-all" }, derp),
      );
    }
    if (media) {
      return el("div", { class: "card col" },
        el("h3", {}, t("live_tunnel")),
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
    el("h3", {}, t("host_relay_pc")),
    el("div", { class: "muted small" }, t("host_relay_hint")),
    s.hosting
      ? el("div", { class: "col" },
          el("div", { class: "ok-text" }, t("relaying_status")),
          s.relay_link ? el("div", { class: "row wrap" }, el("div", { class: "mono", style: "flex:1 1 200px" }, s.relay_link), el("button", { class: "btn small", onclick: () => { navigator.clipboard.writeText(s.relay_link); toast(t("relay_id_copied")); } }, t("copy"))) : null,
          el("div", { class: "muted small" }, t("share_relay_id_hint")),
          el("button", { class: "btn danger small", onclick: async () => { await invoke("stop_hosting"); renderRelay(); } }, t("stop_hosting")),
        )
      : el("button", { class: "btn primary", onclick: async () => { try { await invoke("start_hosting"); toast(t("relay_started")); } catch (e) { toast("" + e); } renderRelay(); } }, t("start_hosting")),
    await relayLimitsSection(s.hosting),
  );
  // Configured relays (active + inactive). "Remove" DEACTIVATES (config survives); "Delete" erases.
  const relayList = await invoke("relays").catch(() => []);
  const adoptCard = el("div", { class: "card col" },
    el("h3", {}, t("configured_relays", relayList.length)),
    el("div", { class: "muted small" }, t("configured_relays_hint")),
  );
  for (const r of relayList) {
    const dotCls = !r.active ? "" : (r.reachable ? "on" : "");
    const statusTxt = !r.active ? t("deactivated_config_kept")
      : (r.is_s3 ? t("s3_saf") : (r.hosted ? t("this_pc") : (r.reachable ? t("reachable") : t("retrying"))));
    const actions = el("div", { class: "row", style: "gap:6px;flex-wrap:wrap" });
    if (r.active) {
      actions.append(el("button", { class: "btn small", title: t("deactivate_title"), onclick: async () => { await invoke("forget_relay", { nodeHex: r.node_hex }); toast(t("relay_deactivated")); renderRelay(); } }, t("deactivate")));
    } else {
      actions.append(el("button", { class: "btn small primary", onclick: async () => { await invoke("reactivate_relay", { nodeHex: r.node_hex }); toast(t("relay_reactivated")); renderRelay(); } }, t("reactivate")));
    }
    actions.append(r.is_default
      ? el("button", { class: "btn small ghost", title: t("unset_default_title"), onclick: async () => { await invoke("set_default_relay", { nodeHex: "" }); renderRelay(); } }, t("unset_default"))
      : el("button", { class: "btn small ghost", title: t("make_default_title"), onclick: async () => { await invoke("set_default_relay", { nodeHex: r.node_hex }); toast(t("default_relay_set")); renderRelay(); } }, t("make_default")));
    actions.append(el("button", { class: "btn small ghost", onclick: async () => {
      const n = prompt(t("relay_name_prompt"), r.name); if (n && n.trim()) { await invoke("rename_relay", { nodeHex: r.node_hex, name: n.trim() }); renderRelay(); }
    } }, t("rename")));
    actions.append(el("button", { class: "btn small danger", title: t("erase_title"), onclick: async () => { await invoke("erase_relay", { nodeHex: r.node_hex }); toast(t("relay_deleted")); renderRelay(); } }, t("delete")));
    adoptCard.append(el("div", { class: "list-item col", style: "align-items:stretch;gap:6px" },
      el("div", { class: "row", style: "gap:8px;align-items:center" },
        el("span", { class: "dot " + dotCls, title: statusTxt }),
        el("div", { style: "flex:1;min-width:0" },
          el("div", { class: "row", style: "gap:6px;align-items:center" },
            el("span", { style: "font-weight:600;overflow:hidden;text-overflow:ellipsis" }, r.name),
            r.is_default ? el("span", { class: "tag", title: t("default_for_all") }, t("star_default")) : null,
            r.is_s3 ? el("span", { class: "tag" }, "S3") : null,
            r.hosted ? el("span", { class: "tag" }, t("this_pc")) : null,
          ),
          el("div", { class: "mono small muted", style: "overflow:hidden;text-overflow:ellipsis" }, r.is_s3 ? r.node_hex : r.node_hex.slice(0, 20) + "…"),
          el("div", { class: "muted small" }, statusTxt),
        ),
      ),
      actions,
    ));
  }
  if (!relayList.length) adoptCard.append(el("div", { class: "muted small" }, t("no_relays_yet")));
  // Deleted relays — the undo for "Delete", which drops the entry, every circle association and the
  // default pick. A relay is a 64-character node id, not something anyone re-adds from memory.
  // Hidden entirely when there is nothing to recover. Apple/Android parity.
  const erased = await invoke("erased_relays").catch(() => []);
  if (erased.length) {
    const det = el("details", { class: "list-item col", style: "align-items:stretch;gap:6px" });
    det.append(el("summary", {}, t("deleted_relays", erased.length)));
    for (const rec of erased) {
      const e = rec.entry || {};
      det.append(el("div", { class: "row", style: "gap:8px;align-items:center" },
        el("div", { style: "flex:1;min-width:0" },
          el("div", { style: "overflow:hidden;text-overflow:ellipsis" }, e.name || (e.hex || "").slice(0, 12) + "…"),
          el("div", { class: "mono small muted" },
            (e.hex || "").slice(0, 20) + "…" + (rec.circles && rec.circles.length ? t("circles_count", rec.circles.length) : "")),
        ),
        el("button", { class: "btn small primary", onclick: async () => { await invoke("restore_erased_relay", { nodeHex: e.hex }); toast(t("relay_restored")); renderRelay(); } }, t("restore")),
        el("button", { class: "btn small", onclick: async () => { await invoke("drop_erased_relay", { nodeHex: e.hex }); renderRelay(); } }, t("forget")),
      ));
    }
    det.append(el("div", { class: "muted small" }, t("restore_hint")));
    adoptCard.append(det);
  }
  adoptCard.append(el("div", { class: "row" }, adoptInput, el("button", { class: "btn primary", onclick: async () => {
    const v = adoptInput.value.trim();
    const okBare = v.length === 64 && /^[0-9a-fA-F]+$/.test(v);
    const okJson = v.startsWith("{") && v.includes("node");
    if (okBare || okJson) {
      await invoke("adopt_relay", { nodeHex: v });
      toast(t("relay_added"));
      adoptInput.value = "";
      renderRelay();
    } else {
      toast(t("paste_node_id_error"));
    }
  } }, t("add_haven_relay"))));
  const au = await invoke("autostart_status").catch(() => ({ login_item: false, host_on_launch: false }));
  const loginChk = el("input", { type: "checkbox", style: "width:auto" }); loginChk.checked = au.login_item;
  const hostChk = el("input", { type: "checkbox", style: "width:auto" }); hostChk.checked = au.host_on_launch;
  const alwaysOn = el("div", { class: "card col" },
    el("h3", {}, t("always_on_relay")),
    el("div", { class: "muted small" }, t("always_on_hint")),
    el("label", { class: "row", style: "gap:8px" }, loginChk, el("span", {}, t("start_on_login"))),
    el("label", { class: "row", style: "gap:8px" }, hostChk, el("span", {}, t("host_on_launch"))),
    el("button", { class: "btn primary", style: "align-self:flex-start", onclick: async () => { try { await invoke("set_autostart", { loginItem: loginChk.checked, hostOnLaunch: hostChk.checked }); toast(t("saved")); renderRelay(); } catch (e) { toast("" + e); } } }, t("save")),
  );
  const headless = el("div", { class: "card col" },
    el("h3", {}, t("run_headless")),
    el("div", { class: "muted small html", html: t("headless_hint_html") }),
  );
  const s3 = await invoke("s3_status");
  const f = {
    name: el("input", { value: s3.configured ? ("S3 · " + s3.bucket) : "", placeholder: t("name_optional_ph") }),
    endpoint: el("input", { value: s3.endpoint || "", placeholder: t("endpoint_ph") }),
    region: el("input", { value: s3.region || "us-east-1", placeholder: t("region_ph"), style: "max-width:160px" }),
    bucket: el("input", { value: s3.bucket || "", placeholder: t("bucket_ph") }),
    access: el("input", { value: s3.access_key || "", placeholder: t("access_key_ph") }),
    secret: el("input", { type: "password", placeholder: s3.configured ? t("stored_keychain_ph") : t("secret_key_ph") }),
    prefix: el("input", { value: s3.prefix || "", placeholder: t("prefix_ph") }),
  };
  const s3default = el("input", { type: "checkbox", style: "width:auto" }); s3default.checked = true;
  const s3card = el("div", { class: "card col" },
    el("h3", {}, t("add_s3_title")),
    el("div", { class: "muted small" }, t("byo_bucket") + (s3.configured ? t("configured_prefix") + s3.bucket : t("not_configured"))),
    el("div", { class: "muted small", style: "border-left:3px solid var(--warn,#e0a020);padding-left:8px" },
      t("s3_warning")),
    f.name, f.endpoint, el("div", { class: "row" }, f.region, f.bucket), f.access, f.secret, f.prefix,
    el("label", { class: "row", style: "gap:8px" }, s3default, el("span", {}, t("make_default_all"))),
    el("div", { class: "row" },
      el("button", { class: "btn primary", onclick: async () => {
        try {
          await invoke("add_s3_relay", { endpoint: f.endpoint.value.trim(), region: f.region.value.trim(), bucket: f.bucket.value.trim(), accessKey: f.access.value.trim(), secretKey: f.secret.value, prefix: f.prefix.value.trim(), name: f.name.value.trim(), setDefault: s3default.checked });
          toast(t("s3_added")); renderRelay();
        } catch (e) { toast("" + e); }
      } }, s3.configured ? t("update_bucket") : t("add_s3_relay")),
      s3.configured ? el("button", { class: "btn danger small", onclick: async () => { await invoke("erase_relay", { nodeHex: "s3:" + s3.bucket }); await invoke("s3_clear"); toast(t("s3_removed")); renderRelay(); } }, t("remove")) : null,
    ),
  );
  sheet(t("relays"), el("div", { class: "col", style: "gap:16px" }, hostCard, liveTunnelCard, publicCard, alwaysOn, adoptCard, s3card, headless));
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

  const avatar = el("button", { class: "profile-avatar", title: t("edit_profile"), onclick: () => editProfileSheet(p) },
    el("div", { class: "disc" }, p.avatar ? el("img", { src: p.avatar }) : (p.emoji || initials(p.name))),
    el("span", { class: "pencil" }, icon("pencil.circle.fill")),
  );
  const head = el("div", { class: "profile-head" },
    avatar,
    el("div", { class: "profile-name" }, p.name || t("you")),
    p.bio ? el("div", { class: "profile-bio" }, p.bio) : null,
    p.link ? el("button", { class: "profile-link", onclick: () => openExternal(p.link) }, icon("link"), p.link) : null,
    (!p.bio && !p.link) ? el("div", { class: "profile-bio" }, t("profile_private_hint")) : null,
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
    author_name: t("you"),
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
      // A RING IS ALWAYS A STILL.
      //
      // displayMediaRefs deliberately drops poster stills ("they ride with the video page"), so for
      // a video story the first ref it returns is the CLIP. Handing that to the ring made a wall of
      // 56px circles each loading and playing its own video — every one of them decoding at once,
      // for a thumbnail. The poster companion is the right picture and is already in the media
      // array; the tiny `thumb:` is the fallback, and the placeholder glyph is the last resort.
      // Never a <video>.
      let cover = displayMediaRefs(s.media || []).find((r) => !r.startsWith("geo:") && !isAudioRef(r));
      if (cover && isVideoRef(cover)) cover = posterRefFor(s.media, cover) || ThumbIndex.thumbFor(cover);
      if (cover && !isVideoRef(cover)) inner.append(el("img", { "data-ref": cover }));
      else inner.append(icon("photo", "story-ph"));
      tray.append(el("button", { class: "story-ring cover", onclick: () => viewStories(gallery, idx) }, el("div", { class: "ring" }, inner)));
    });
    body.append(el("div", { class: "card" }, el("div", { class: "section-label" }, t("your_stories")), tray));
  }
  if (!myPosts.length) {
    body.append(el("div", { class: "card" }, el("div", { class: "empty", style: "padding:28px 10px" },
      el("div", { class: "h" }, t("your_posts_here")),
      el("div", {}, t("your_posts_sub")))));
  } else {
    // PAGED, exactly like the circle feed. This appended EVERY post — with an archive imported
    // that is hundreds of cards, each with its own media, built in one go: the reason this tab's
    // scrollbar was a sliver, the reason it was slow to open, and the reason scrolling stuttered
    // (the autoplay pass measures each card, and there were hundreds of them).
    const PAGE = 25;
    let shown = 0;
    const sentinel = el("div", { style: "height:1px" });
    let observer = null;
    const nextPage = () => {
      const next = myPosts.slice(shown, shown + PAGE);
      shown += next.length;
      for (const it of next) body.insertBefore(postCard(it, it._circle), sentinel);
      for (const c of circles) hydrateMedia(body, c.id);
      Autoplay.track(body);
      Autoplay.schedule();
      if (shown >= myPosts.length) observer?.disconnect();
    };
    body.append(sentinel);
    observer = new IntersectionObserver((es) => { if (es.some((e) => e.isIntersecting)) nextPage(); },
                                        { rootMargin: "800px 0px" });
    observer.observe(sentinel);
    nextPage();
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
  const name = el("input", { class: "pill-field", value: p.name || "", placeholder: t("your_name_ph") });
  const bio = el("textarea", { class: "field-soft", placeholder: t("bio_ph"), rows: 2 }); bio.value = p.bio || "";
  const link = el("input", { class: "field-capsule", value: p.link || "", placeholder: t("link_ph") });
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
    catch (_) { toast(t("not_an_image")); }
  } });

  const photoRow = el("div", { class: "row wrap", style: "justify-content:center" },
    el("button", { class: "btn small tint-pink", onclick: () => picker.click() }, avatar ? t("change_photo") : t("add_photo")),
    avatar ? el("button", { class: "btn small danger", onclick: async () => { avatar = ""; await save(); redraw(); renderYou(); } }, t("remove")) : null,
    picker,
  );

  const grid = el("div", { class: "emoji-grid" });
  for (const e of AVATAR_EMOJI) {
    grid.append(el("button", { class: "emoji-cell" + (emoji === e ? " on" : ""), onclick: async () => { emoji = e; await save(); redraw(); renderYou(); } }, e));
  }

  sheet(t("edit_profile"), el("div", { class: "edit-profile" },
    el("div", { class: "ep-avatar" }, avatar ? el("img", { src: avatar }) : el("span", {}, emoji)),
    photoRow,
    name,
    el("div", { class: "col", style: "gap:10px" }, bio, link),
    el("div", { class: "ep-caption" }, t("bio_hint")),
    el("div", { class: "ep-label" }, avatar ? t("emoji_if_remove") : t("pick_emoji")),
    grid,
  ), el("button", { class: "btn primary wide", onclick: async () => {
    await save();
    closeModal(); toast(t("profile_saved")); renderYou();
  } }, t("done")));
}

// ---- Feedback & Support (MillerKit parity: Feedback.swift / SupportSection.swift /
// TranslationFeedback.swift). Everything is a mailto: — no server, no account, and the user sees
// exactly what is being sent before it goes.
const SUPPORT_EMAIL = "blaine@wemiller.com";
let APP_VERSION = "1.3.1";
try {
  if (TAURI.app && TAURI.app.getVersion) TAURI.app.getVersion().then((v) => { if (v) APP_VERSION = v; }).catch(() => {});
} catch (_) {}

/** Native name of the running UI language — "Deutsch" reads far better than "de". */
function languageDisplayName(code) {
  try {
    const n = new Intl.DisplayNames([code], { type: "language" }).of(code);
    if (n) return n.charAt(0).toUpperCase() + n.slice(1);
  } catch (_) {}
  return code;
}

/** The diagnostics block that makes a report actionable without a round of
 *  "which version are you on?". Deliberately English — it's for the developer. */
function diagnosticsFooter() {
  return [
    "----------------",
    "Haven " + APP_VERSION + " (desktop, " + HOST_OS + ")",
    "System: " + (navigator.userAgent || navigator.platform || ""),
    "Locale: " + (navigator.language || "en"),
  ].join("\n");
}

function mailtoUrl(subject, body) {
  return "mailto:" + SUPPORT_EMAIL + "?subject=" + encodeURIComponent(subject) + "&body=" + encodeURIComponent(body);
}

/** Guided templates, mirroring MillerKit's Feedback.swift — "email me if you have a problem"
 *  reliably produces "it doesn't work"; a guided form reliably produces something reproducible. */
function feedbackMailto(kind) {
  const subject = "Haven — " + (kind === "bug" ? t("bug_report") : kind === "feature" ? t("feature_request") : t("question"));
  const body = (kind === "bug" ? t("fb_bug_template", "Haven")
    : kind === "feature" ? t("fb_feature_template", "Haven")
    : t("fb_question_template", "Haven")) + "\n\n" + diagnosticsFooter();
  return mailtoUrl(subject, body);
}

/** "This app reads badly in my language — let me help fix it." Offered only when the UI is NOT
 *  running in English, and it screens first: a translation fix is a conversation, and the gate
 *  sets that expectation honestly (MillerKit TranslationFeedback parity). */
function translationFeedbackSheet() {
  const code = HAVEN_LANG;
  const lang = languageDisplayName(code);
  let readsEnglish = false, willIterate = false;
  const screen = el("input", { placeholder: t("tf_screen_ph") });
  const current = el("textarea", { placeholder: t("tf_current_ph"), rows: 2 });
  const suggested = el("textarea", { placeholder: t("tf_suggested_ph", lang), rows: 2 });
  const notes = el("textarea", { placeholder: t("tf_notes_ph"), rows: 2 });
  const sendBtn = el("button", { class: "btn primary wide", disabled: true, onclick: () => {
    let body = t("tf_body_intro", lang, "Haven") + "\n";
    body += t("where_in_app") + "\n" + screen.value.trim() + "\n\n";
    body += t("says_now") + "\n" + current.value.trim() + "\n\n";
    body += t("should_say") + "\n" + suggested.value.trim() + "\n\n";
    if (notes.value.trim()) body += t("why_else") + "\n" + notes.value.trim() + "\n\n";
    body += t("tf_confirm_line");
    body += "\n\n" + diagnosticsFooter();
    body += "\n" + t("displaying") + " " + lang + " (" + code + ")";
    openExternal(mailtoUrl("Haven — Translation fix (" + code + ")", body));
    closeModal();
  } }, t("send_it"));
  const fields = el("div", { class: "col", style: "gap:8px;display:none" },
    el("div", { class: "muted small", style: "font-weight:600" }, t("what_needs_fixing")),
    screen, current, suggested, notes,
    el("div", { class: "set-foot" }, t("tf_send_foot")));
  const sync = () => {
    const open = readsEnglish && willIterate;
    fields.style.display = open ? "" : "none";
    sendBtn.style.display = open ? "" : "none";
    sendBtn.disabled = !(open && screen.value.trim() && suggested.value.trim());
  };
  screen.addEventListener("input", sync);
  suggested.addEventListener("input", sync);
  const gate = (label, set) => {
    const chk = el("input", { type: "checkbox", style: "width:auto" });
    chk.onchange = () => { set(chk.checked); sync(); };
    return el("label", { class: "set-row", style: "cursor:pointer" }, el("span", { style: "flex:1" }, label), chk);
  };
  sendBtn.style.display = "none";
  sheet(t("improve_translation", lang), el("div", { class: "col", style: "gap:10px" },
    el("div", { class: "muted small" }, t("tf_intro", lang)),
    el("div", { class: "muted small", style: "font-weight:600" }, t("before_we_start")),
    el("div", { class: "set-group" },
      gate(t("reads_english"), (v) => { readsEnglish = v; }),
      gate(t("will_iterate"), (v) => { willIterate = v; })),
    el("div", { class: "set-foot" }, t("tf_gate_foot")),
    fields,
  ), sendBtn);
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

  sheet(t("settings"), el("div", { class: "col", style: "gap:6px" },
    el("div", { class: "set-group" },
      el("div", { class: "set-row" },
        el("span", { class: "ri", style: "color:#34d399" }, icon("lock.shield.fill")),
        el("span", { style: "flex:1" },
          el("div", { style: "font-weight:600" }, t("circle_private_title")),
          el("div", { class: "muted small", style: "margin-top:2px" }, t("circle_private_sub"))))),

    // RELAY LIVES HERE — nowhere else in the chrome.
    group(row(t("relays"), "antenna", () => relaySheet())),
    foot(t("relays_foot")),

    group(row(t("blocked_people"), "hand.raised.fill", () => blockedSheet())),
    foot(t("blocked_foot")),

    group(row(t("identities"), "icloud", () => identitiesSheet())),
    foot(t("identities_foot")),

    group(row(t("devices"), "laptop", () => devicesSheet())),
    foot(t("devices_foot")),

    group(row(t("scheduled_messages"), "clock", () => scheduledSheet())),
    foot(t("scheduled_foot")),

    group(row(t("privacy_media"), "lock.shield.fill", () => privacyMediaSheet())),
    foot(t("privacy_media_foot")),

    // Feedback & Support — the MillerKit block, one row per guided template. The translation row
    // renders only when the UI is actually displaying one of the non-English languages.
    el("div", { class: "muted small", style: "font-weight:600;margin-top:4px" }, t("feedback_support")),
    group(
      row(t("report_issue"), "envelope", () => openExternal(feedbackMailto("bug"))),
      row(t("suggest_feature"), "lightbulb", () => openExternal(feedbackMailto("feature"))),
      row(t("ask_question"), "questionmark.circle", () => openExternal(feedbackMailto("question"))),
      HAVEN_LANG !== "en" ? row(t("improve_translation", languageDisplayName(HAVEN_LANG)), "character.bubble", () => translationFeedbackSheet()) : null,
      row(t("my_other_apps"), "square.grid.2x2", () => openExternal("https://wemiller.com/apps/"), { value: t("other_apps_sub") }),
    ),
    foot(t("support_foot")),

    // The Mac follows the system appearance and offers no toggle; desktop keeps one because
    // Tauri's webview doesn't always inherit the OS theme on Linux/Windows.
    group(row(t("appearance"), "moon", () => {
      const next = themeNow === "light" ? "dark" : "light";
      document.documentElement.dataset.theme = next;
      localStorage.setItem("haven-theme", next);
      settingsSheet();
    }, { value: themeNow === "light" ? t("light") : t("dark") })),

    group(row(t("import_from_instagram"), "square.and.arrow.down", () => instagramImportSheet())),
    foot(t("import_ig_foot")),

    group(row(t("advanced"), "wrench", () => advancedSheet())),
    foot(t("advanced_foot")),
  ));
}

// ---- Instagram archive import ------------------------------------------------------------------
//
// The guided "bring your Instagram posts over" flow. Apple parity:
// `apple/HavenApp/InstagramImportView.swift` + `ImportBanner.swift`.
//
// Shaped by the fact that the user cannot get their posts out on demand: they request an export,
// wait hours or days, and come back. So this WALKS — one step on screen at a time, each with a
// single action — rather than presenting the whole procedure as a page of prose. The settings
// Instagram asks for are shown as a checklist of value rows, not sentences, because that is how
// they will be read: glanced at while looking at Instagram's form on another screen.
//
// NOTHING here owns the import. The run lives on the Rust side (`igimport.rs`), on its own thread:
// closing this sheet does not stop it, quitting Haven does not lose it, and reopening the sheet
// simply re-reads `instagram_status`. That is the whole reason the progress screen's PRIMARY action
// is to leave rather than to wait.

const IG = {
  step: 0,
  includeStories: false,
  // Off by default — it attaches a GUESS, so it should be asked for, not assumed.
  matchSongs: false,
  status: null,
};

const IG_EXPORT_URL = "https://accountscenter.instagram.com/info_and_permissions/dyi/";

async function instagramImportSheet() {
  IG.status = await invoke("instagram_status").catch(() => null);
  // Land on the file step when there is nothing left to explain: a resumed or finished run has
  // already been through the walkthrough.
  if (IG.status && IG.status.phase !== "idle") IG.step = 2;
  drawInstagramSheet();
}

/** True while THIS sheet is the one on screen — so a progress event redraws it without resurrecting
 *  a sheet the user closed, and without stomping on some other sheet they opened since. */
const igSheetOpen = () => !!$("#modal-root").querySelector(".ig-sheet");

function drawInstagramSheet() {
  const s = IG.status || { phase: "idle" };
  const circleName = state.activeCircleName || circleDisplayName(state.activeCircle, "");
  let body;
  let foot = null;
  switch (s.phase) {
    case "previewing": [body, foot] = igPreview(s, circleName); break;
    case "importing":  body = igRunning(s); break;
    case "finished":   body = igFinished(s, circleName); break;
    case "failed":     body = igFailure(s); break;
    default:           body = igWalkthrough(s); break; // idle + reading
  }
  body.classList.add("ig-sheet");
  sheet(t("import_from_instagram"), body, foot);
}

// ---- Walkthrough (3 steps, one at a time) ----

function igWalkthrough(s) {
  const dots = el("div", { class: "ig-dots" },
    ...[0, 1, 2].map((i) => el("i", { class: "ig-dot" + (i === IG.step ? " on" : "") })));
  const next = (label) => el("button", {
    class: "btn", style: "width:100%;margin-top:6px",
    onclick: () => { IG.step += 1; drawInstagramSheet(); },
  }, label);

  let step;
  if (IG.step === 0) {
    step = igStep("square.and.arrow.down", t("ig_step1_title"), t("ig_step1_blurb"),
      el("button", { class: "btn primary", style: "width:100%", onclick: () => openExternal(IG_EXPORT_URL) }, t("ig_open_instagram")),
      el("div", { class: "muted small", style: "font-weight:600;align-self:flex-start;margin-top:4px" }, t("ig_pick_these")),
      el("div", { class: "set-group", style: "width:100%" },
        igSetting(t("ig_format"), "JSON", true),
        igSetting(t("ig_media_quality"), t("ig_high")),
        igSetting(t("ig_date_range"), t("ig_all_time")),
        igSetting(t("ig_include"), t("ig_include_value"))),
      el("div", { class: "ig-warn" }, icon("exclamationmark.triangle"), el("span", {}, t("ig_json_warning"))),
      next(t("ig_requested_it")));
  } else if (IG.step === 1) {
    step = igStep("clock", t("ig_step2_title"), t("ig_step2_blurb"),
      el("div", { class: "col", style: "gap:12px;width:100%;text-align:left" },
        igBullet(t("ig_step2_a")), igBullet(t("ig_step2_b")), igBullet(t("ig_step2_c"))),
      next(t("ig_have_the_file")));
  } else {
    const reading = s.phase === "reading";
    step = igStep("folder", t("ig_step3_title"), t("ig_step3_blurb"),
      el("button", {
        class: "btn primary", style: "width:100%", disabled: reading ? "" : null,
        onclick: () => pickInstagramArchive(),
      }, reading ? t("ig_reading") : t("ig_choose_file")),
      el("div", { class: "muted small" }, t("ig_filename_hint")));
  }
  return el("div", { class: "col", style: "gap:0" }, dots, step);
}

/** Shared step chrome: icon, title, one line of context, then the step's own content. */
function igStep(iconName, title, blurb, ...content) {
  return el("div", { class: "ig-step" },
    el("span", { class: "ig-step-icon" }, icon(iconName)),
    el("div", { class: "ig-step-title" }, title),
    el("div", { class: "ig-step-blurb" }, blurb),
    ...content);
}

function igSetting(label, value, critical) {
  return el("div", { class: "set-row" },
    el("span", { style: "flex:1" }, label),
    el("span", { class: critical ? "ig-critical" : "muted" }, value));
}

function igBullet(text) {
  return el("div", { class: "ig-bullet" }, el("i", {}), el("span", {}, text));
}

/** The .zip picker. Desktop has real paths — the backend opens the archive itself, so nothing is
 *  read into the WebView and a 1.28 GB file costs this process nothing. */
async function pickInstagramArchive() {
  const dlg = TAURI.dialog;
  if (!dlg || !dlg.open) { toast(t("ig_no_picker")); return; }
  let picked;
  try {
    picked = await dlg.open({ multiple: false, directory: false, filters: [{ name: "Zip", extensions: ["zip"] }] });
  } catch (e) { toast("" + e); return; }
  if (!picked) return;
  const path = typeof picked === "string" ? picked : (picked.path || picked);
  await invoke("instagram_read", { path }).catch((e) => toast("" + e));
}

// ---- Preview — nothing publishes until this is confirmed ----

function igPreview(s, circleName) {
  const a = s.summary || {};
  const rows = el("div", { class: "set-group" },
    igCount(t("ig_posts"), a.posts, "square.grid.2x2"),
    igCount(t("ig_reels"), a.reels, "play.rectangle"),
    igCount(t("ig_photos_videos"), a.mediaCount, "photo"),
    igCount(t("ig_size"), fmtBytes(a.totalBytes || 0), "internaldrive"),
    a.earliest && a.latest ? igCount(t("ig_spans"), `${igMonth(a.earliest)} – ${igMonth(a.latest)}`, "calendar") : null);

  const missing = a.missing
    ? el("div", { class: "col", style: "gap:4px" },
        el("div", { class: "ig-warn" }, icon("exclamationmark.triangle"), el("span", {}, t("ig_missing", a.missing))),
        el("div", { class: "set-foot" }, t("ig_missing_foot")))
    : null;

  const storiesBox = (a.stories || 0) > 0
    ? el("div", { class: "col", style: "gap:4px" },
        el("div", { class: "set-group" }, igToggle(t("ig_include_stories", a.stories), IG.includeStories, (on) => {
          IG.includeStories = on; drawInstagramSheet();
        })),
        el("div", { class: "set-foot" }, t("ig_stories_foot", circleName)))
    : null;

  const songsBox = el("div", { class: "col", style: "gap:4px" },
    el("div", { class: "set-group" }, igToggle(t("ig_suggest_songs"), IG.matchSongs, (on) => { IG.matchSongs = on; })),
    el("div", { class: "set-foot" }, t("ig_songs_foot")));

  const n = (a.items || 0) - (IG.includeStories ? 0 : (a.stories || 0));

  const body = el("div", { class: "col", style: "gap:14px" },
    el("div", { class: "muted small", style: "font-weight:600" }, t("ig_in_your_archive")),
    rows, missing, storiesBox, songsBox,
    el("div", { class: "set-foot" }, t("ig_import_foot", circleName)),
    el("button", { class: "btn", style: "align-self:flex-start", onclick: () => {
      IG.step = 2;   // straight back to the picker, not through the walkthrough again
      invoke("instagram_reset").catch(() => {});
    } }, t("ig_different_file")));

  const foot = el("button", { class: "btn primary", onclick: async () => {
    await invoke("instagram_run", {
      circleId: state.activeCircle,
      includeStories: IG.includeStories,
      matchSongs: IG.matchSongs,
    }).catch((e) => toast("" + e));
  } }, n === 1 ? t("ig_import_one") : t("ig_import_n", n));

  return [body, foot];
}

function igCount(label, value, iconName) {
  return el("div", { class: "set-row" },
    el("span", { class: "ri" }, icon(iconName)),
    el("span", { style: "flex:1" }, label),
    el("span", { class: "muted", style: "font-variant-numeric:tabular-nums" }, String(value == null ? "—" : value)));
}

function igToggle(label, on, onChange) {
  const chk = el("input", { type: "checkbox", style: "width:auto" });
  chk.checked = !!on;
  chk.onchange = () => onChange(chk.checked);
  return el("label", { class: "set-row", style: "cursor:pointer" },
    el("span", { style: "flex:1" }, label), chk);
}

function igMonth(ms) {
  return new Date(Number(ms)).toLocaleDateString(undefined, { year: "numeric", month: "short" });
}

// ---- Running / done / failed ----

/** Update the OPEN running sheet in place. Returns false when it isn't showing (caller redraws).
 *
 *  `sheet()` replaces the whole modal — backdrop, card and all — and the import emits a progress
 *  event for EVERY item, so redrawing the sheet per event tore down and rebuilt the overlay
 *  hundreds of times over a run. That is the flashing, and it is per-item rather than on the
 *  feed's 2s cadence, which is what distinguished it from the feed repaint fixed earlier.
 *  Three nodes actually change; only those are touched. */
function igUpdateRunning(s) {
  const root = $("#modal-root");
  const count = root.querySelector(".ig-big");
  const bar = root.querySelector(".ig-bar i");
  if (!count || !bar) return false;
  const total = Math.max(s.total || 1, 1);
  count.textContent = String(s.done || 0);
  bar.style.width = `${Math.round(((s.done || 0) / total) * 100)}%`;
  const of = root.querySelector(".ig-of");
  if (of) of.textContent = t("ig_of_n_imported", s.total || 0);
  return true;
}

function igRunning(s) {
  const total = Math.max(s.total || 1, 1);
  return el("div", { class: "col", style: "gap:14px;align-items:center;text-align:center;padding:12px 0" },
    el("div", { class: "ig-big" }, String(s.done || 0)),
    el("div", { class: "muted ig-of" }, t("ig_of_n_imported", s.total || 0)),
    el("div", { class: "ig-bar" }, el("i", { style: `width:${Math.round(((s.done || 0) / total) * 100)}%` })),
    el("div", { class: "muted small", style: "max-width:34ch" }, t("ig_encrypted_here")),
    // The import does not need this screen — it runs on its own thread, keeps going while Haven is
    // used normally, and resumes itself if the app is quit. So the primary action here is to LEAVE.
    el("button", { class: "btn primary", style: "min-width:220px", onclick: () => closeModal() }, t("ig_browse_while")),
    el("div", { class: "muted small" }, t("ig_can_close")),
    el("button", { class: "btn danger", onclick: () => {
      // Stop is destructive and easy to hit by accident next to a progress bar — it confirms.
      if (!confirm(t("ig_stop_confirm") + "\n\n" + t("ig_stop_body", s.done || 0))) return;
      invoke("instagram_cancel").catch(() => {});
    } }, t("ig_stop")));
}

function igFinished(s, circleName) {
  // A Stop is really a PAUSE: the backend keeps the checkpoint, so offer to carry on here rather
  // than making the user quit and relaunch to get the other resume door.
  const canResume = typeof s.resumeFrom === "number";
  return el("div", { class: "col", style: "gap:12px;align-items:center;text-align:center;padding:12px 0" },
    el("span", { class: "ig-done-icon" }, icon("checkmark")),
    el("div", { style: "font-size:19px;font-weight:700" }, t("ig_n_imported", s.imported || 0)),
    el("div", { class: "muted" }, t("ig_in_date_order", circleName)),
    (s.skipped || 0) > 0 ? el("div", { class: "muted small", style: "max-width:38ch" }, t("ig_n_skipped", s.skipped)) : null,
    canResume ? el("div", { class: "muted small", style: "max-width:38ch" }, t("ig_resuming", s.resumeFrom)) : null,
    canResume ? el("button", { class: "btn primary", style: "min-width:180px;margin-top:4px", onclick: () => {
      invoke("instagram_resume").catch((e) => toast("" + e));
    } }, t("ig_resume")) : null,
    el("button", { class: canResume ? "btn" : "btn primary", style: "min-width:180px;margin-top:4px", onclick: async () => {
      await invoke("instagram_reset").catch(() => {});
      closeModal();
    } }, t("done")));
}

function igFailure(s) {
  return el("div", { class: "col", style: "gap:12px;align-items:center;text-align:center;padding:12px 0" },
    el("span", { class: "ig-fail-icon" }, icon("exclamationmark.triangle")),
    el("div", { style: "max-width:44ch;line-height:1.5" }, s.message || ""),
    el("button", { class: "btn primary", style: "min-width:180px", onclick: () => {
      // Step FIRST: the reset emits, and that event is what redraws this sheet.
      IG.step = 2;
      invoke("instagram_reset").catch(() => {});
    } }, t("ig_try_another")));
}

// ---- The app-wide "still importing" pill ----
//
// An archive import takes a long time — hundreds of photos and videos, each sealed on this machine —
// and holding the user on a modal progress bar for all of it is the wrong trade twice over: they
// cannot use Haven, and they cannot watch the posts arriving, which is the whole point. So the run
// is independent of any view and this pill is what remains on screen: small, clickable to reopen the
// full sheet, and present wherever the user browses to — including after a relaunch, since the
// import resumes itself.

function renderImportPill(s) {
  const existing = $("#import-pill");
  if (!s || s.phase !== "importing") { if (existing) existing.remove(); return; }
  const total = Math.max(s.total || 1, 1);
  const pct = Math.round(((s.done || 0) / total) * 100);
  if (existing) {
    existing.querySelector(".ip-count").textContent = t("ig_x_of_y", s.done || 0, s.total || 0);
    existing.querySelector(".ip-ring i").style.width = `${pct}%`;
    return;
  }
  const pill = el("button", { class: "import-pill", id: "import-pill", onclick: () => instagramImportSheet() },
    el("span", { class: "ip-ring" }, el("i", { style: `width:${pct}%` })),
    el("span", { class: "col", style: "gap:1px;align-items:flex-start" },
      el("span", { class: "ip-title" }, t("ig_importing_banner")),
      el("span", { class: "ip-count" }, t("ig_x_of_y", s.done || 0, s.total || 0))),
    el("span", { class: "ip-chev" }, icon("chevron.right")));
  document.body.append(pill);
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
        toast(t("saved"));
      } catch (e) { toast("" + e); chk.checked = !chk.checked; }
    };
    return el("label", { class: "set-row", style: "cursor:pointer" },
      el("span", { style: "flex:1" }, label), chk);
  };

  const detailOpts = [
    ["full", t("full_previews")],
    ["private", t("name_type_only")],
    ["minimal", t("minimal")],
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
        toast(t("saved"));
      } catch (e) { toast("" + e); }
    };
    detailBox.append(el("label", { class: "row", style: "gap:8px;align-items:center;cursor:pointer" },
      radio, el("span", {}, label)));
  }

  sheet(t("privacy_media"), el("div", { class: "col", style: "gap:10px" },
    el("div", { class: "set-group" },
      toggle(t("also_send_original"), "send_original", prefs.send_original),
      toggle(t("super_data_saver"), "super_data_saver", prefs.super_data_saver)),
    el("div", { class: "set-foot" },
      t("privacy_toggles_foot")),
    el("div", { class: "muted small", style: "font-weight:600" }, t("notification_previews")),
    el("div", { class: "muted small" }, t("notification_previews_hint")),
    el("div", { class: "set-group" }, detailBox),
  ));
}

async function blockedSheet() {
  const blocked = await invoke("blocked").catch(() => []);
  const list = el("div", { class: "col" });
  if (!blocked.length) list.append(el("div", { class: "muted small" }, t("no_one_blocked")));
  for (const b of blocked) {
    list.append(el("div", { class: "list-item" },
      el("div", { class: "mono", style: "flex:1" }, b.slice(0, 24) + "…"),
      el("button", { class: "btn small", onclick: async () => { await invoke("unblock", { idHex: b }); blockedSheet(); } }, t("unblock"))));
  }
  sheet(t("blocked_people"), list);
}

async function scheduledSheet() {
  const sched = await invoke("scheduled").catch(() => []);
  const list = el("div", { class: "col" });
  if (!sched.length) list.append(el("div", { class: "muted small" }, t("nothing_scheduled")));
  for (const s of sched) {
    list.append(el("div", { class: "list-item" },
      el("div", { style: "flex:1;min-width:0" },
        el("div", {}, (s.kind === "dm" ? t("dm_label") + " · " : t("post_label") + " · ") + (s.body || (s.media_count ? t("attachments_count", s.media_count) : "—"))),
        el("div", { class: "muted small" }, t("sends_at", new Date(s.send_at_ms).toLocaleString()))),
      el("button", { class: "btn small danger", onclick: async () => { await invoke("cancel_scheduled", { id: s.id }); scheduledSheet(); } }, t("cancel"))));
  }
  sheet(t("scheduled_title"), list);
}

// ---- #1 Manage media: size-sorted cleanup screen ----------------------------------------
// Every cached photo/video/audio blob, largest first, each mapped to the post/DM it belongs to (or
// flagged Unused). Multi-select to free space; per-row "Keep on this device" pins a blob so no cleanup
// ever removes it. Deleting frees only the LOCAL bytes — the post stays and re-renders as a
// downloadable placeholder. Port of iOS MediaCleanupView.
async function manageMediaSheet() {
  const listWrap = el("div", { class: "col", style: "gap:8px" });
  const headEl = el("div", { class: "muted small" }, t("measuring"));
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
      btn.disabled = true; btn.textContent = t("removing");
      try {
        const freed = await invoke("media_delete_selected", { refs: [...selection] });
        toast(t("freed", fmtBytes(freed)));
      } catch (e) { toast(t("couldnt_remove", e)); }
      selection.clear();
      await reload();
    } }, t("remove_n_frees", selection.size, fmtBytes(selectedBytes())));
    footBar.append(btn);
  };

  const rowEl = (r) => {
    const selected = selection.has(r.reference);
    // Selection control (pinned rows are ineligible — a pin glyph instead of a checkbox).
    const toggle = r.is_pinned
      ? el("span", { class: "media-row-pin", title: t("kept_on_device") }, "📌")
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
    const sub = r.snippet ? r.snippet : (r.is_orphan ? t("not_linked_any_post") : "");
    const meta = el("div", { style: "flex:1;min-width:0" },
      el("div", { class: "name", style: "overflow:hidden;text-overflow:ellipsis;white-space:nowrap" }, r.circle_name),
      sub ? el("div", { class: "muted small", style: "overflow:hidden;text-overflow:ellipsis;white-space:nowrap" }, sub) : null,
      el("div", { class: "muted small mono" }, fmtBytes(r.bytes) + (r.is_pinned ? t("kept_suffix") : "")));
    const keep = el("button", { class: "btn small ghost", onclick: async () => {
      try {
        if (r.is_pinned) await invoke("media_unpin", { refs: [r.reference] });
        else await invoke("media_pin", { refs: [r.reference] });
        await reload();
      } catch (e) { toast("" + e); }
    } }, r.is_pinned ? t("unkeep") : t("keep"));
    return el("div", { class: "list-item", style: "gap:10px;align-items:center" }, toggle, thumb, meta, keep);
  };

  const reload = async () => {
    rows = await invoke("media_inventory").catch(() => []);
    for (const r of [...selection]) if (!rows.some((x) => x.reference === r)) selection.delete(r);
    listWrap.replaceChildren();
    if (!rows.length) {
      headEl.textContent = t("no_cached_media");
      listWrap.append(el("div", { class: "muted small", style: "padding:16px 0" }, t("nothing_stored_yet")));
    } else {
      const kept = pinnedBytes() > 0 ? t("kept_bytes", fmtBytes(pinnedBytes())) : "";
      headEl.textContent = t("items_summary", rows.length === 1 ? t("item_one") : t("items_many", rows.length), fmtBytes(totalBytes())) + kept;
      for (const r of rows) listWrap.append(rowEl(r));
    }
    renderFoot();
  };

  sheet(t("manage_media"),
    el("div", { class: "col", style: "gap:10px" },
      headEl,
      el("div", { class: "muted small" }, t("manage_media_hint")),
      listWrap),
    footBar);
  await reload();
}

async function advancedSheet() {
  const security = el("div", { class: "card col" },
    el("h3", {}, t("security")),
    el("div", { class: "muted small" }, t("security_hint")),
    el("button", { class: "btn", onclick: async () => { const r = await invoke("self_test"); modal(el("div", {}, el("h2", {}, r.all_ok ? t("all_checks_passed") : t("some_checks_failed")), el("div", { class: "col small" }, line(t("identity_label"), r.identity_ok), line(t("hybrid_kem"), r.hybrid_kem_ok), line(t("signatures"), r.signature_ok), line(t("reach_me_link"), r.link_ok)), el("p", { class: "muted small" }, r.summary))); } }, t("run_self_test")),
  );

  const storage = el("div", { class: "card col" },
    el("h3", {}, t("storage")),
    el("div", { class: "muted small" }, t("storage_hint")),
    // #1 Manage media — the size-sorted cleanup screen, with the #2 pinned ("kept") count.
    (() => {
      const kept = el("span", { class: "muted small" }, "");
      invoke("media_pinned_count").then((n) => { if (n) kept.textContent = t("n_kept", n); }).catch(() => {});
      return el("button", { class: "btn", style: "display:flex;justify-content:space-between;align-items:center", onclick: () => manageMediaSheet() },
        el("span", {}, t("manage_media")), kept);
    })(),
    // #4 device-local age/size caps (default OFF). Changing either enforces immediately.
    (() => {
      const daysSel = el("select", { class: "pill-field" },
        el("option", { value: "0" }, t("never")),
        el("option", { value: "30" }, t("days_30")),
        el("option", { value: "90" }, t("days_90")),
        el("option", { value: "180" }, t("months_6")),
        el("option", { value: "365" }, t("year_1")));
      const gbSel = el("select", { class: "pill-field" },
        el("option", { value: "0" }, t("no_limit")),
        el("option", { value: "1" }, "1 GB"),
        el("option", { value: "2" }, "2 GB"),
        el("option", { value: "5" }, "5 GB"),
        el("option", { value: "10" }, "10 GB"),
        el("option", { value: "25" }, "25 GB"));
      invoke("get_media_limits").then((l) => {
        if (l) { daysSel.value = String(l.days || 0); gbSel.value = String(l.gb || 0); }
      }).catch(() => {});
      const save = async () => {
        try { await invoke("set_media_limits", { days: Number(daysSel.value), gb: Number(gbSel.value) }); toast(t("saved")); }
        catch (e) { toast("" + e); }
      };
      daysSel.onchange = save; gbSel.onchange = save;
      return el("div", { class: "col", style: "gap:6px" },
        el("label", { class: "row", style: "gap:8px;align-items:center" }, el("span", { style: "flex:1" }, t("delete_older_than")), daysSel),
        el("label", { class: "row", style: "gap:8px;align-items:center" }, el("span", { style: "flex:1" }, t("keep_under")), gbSel),
        el("div", { class: "muted small" }, t("auto_remove_hint")));
    })(),
    // Shrink what I've ALREADY shared, and re-share it, so the whole circle gets the smaller copy.
    // Sits beside "Clean up unused media" because the two are the only levers on media that is
    // already out there: this one makes it smaller for everybody, that one reclaims local bytes.
    Reoptimize.row(),
    // Clear only media nothing references anymore.
    (() => {
      const status = el("div", { class: "muted small" }, "");
      const btn = el("button", { class: "btn", onclick: async () => {
        btn.disabled = true; btn.textContent = t("cleaning_up");
        try {
          const r = await invoke("media_cleanup");
          status.textContent = !r || !r.files ? t("nothing_to_cleanup")
            : t("freed_across", fmtBytes(r.bytes), r.files === 1 ? t("file_one") : t("files_many", r.files));
        } catch (e) { status.textContent = t("cleanup_failed", e); }
        btn.disabled = false; btn.textContent = t("cleanup_unused");
      } }, t("cleanup_unused"));
      return el("div", { class: "col", style: "gap:6px" }, btn, status);
    })(),
  );

  const danger = el("div", { class: "card col" },
    el("h3", {}, t("start_over")),
    el("div", { class: "muted small" }, t("start_over_hint")),
    el("button", { class: "btn danger", onclick: () => { modal(el("div", {}, el("h2", {}, t("start_over_q")), el("p", {}, t("start_over_confirm")), el("div", { class: "row", style: "justify-content:flex-end" }, el("button", { class: "btn ghost", onclick: () => closeModal() }, t("cancel")), el("button", { class: "btn danger", onclick: async () => { await invoke("reset"); location.reload(); } }, t("delete_everything"))))); } }, t("start_over")),
  );

  const about = el("div", { class: "card col" },
    el("h3", {}, t("this_device")),
    el("div", { class: "muted small mono" }, "node id: " + state.node),
  );

  sheet(t("advanced"), el("div", { class: "col", style: "gap:16px" }, about, security, storage, danger));
}

async function identitiesSheet() {
  const ids = await invoke("identities").catch(() => []);
  const idCard = el("div", { class: "col" },
    el("div", { class: "muted small" }, t("identities_foot")));
  for (const id of ids) {
    idCard.append(el("div", { class: "list-item" },
      el("div", { class: "avatar", style: "width:30px;height:30px;font-size:12px" }, initials(id.label)),
      el("div", { style: "flex:1;min-width:0" }, el("div", { class: "name" }, id.label, id.active ? el("span", { class: "tag", style: "margin-left:8px" }, t("active_tag")) : null), el("div", { class: "muted small mono" }, id.node_hex.slice(0, 18) + "…")),
      id.active ? null : el("button", { class: "btn small primary", onclick: async () => { if (confirm(t("switch_identity_confirm", id.label))) await invoke("switch_identity", { nodeHex: id.node_hex }); } }, t("switch_btn")),
      el("button", { class: "btn small ghost", title: t("rename"), onclick: () => { const i = el("input", { value: id.label }); modal(el("div", {}, el("h2", {}, t("rename_identity")), i, el("div", { class: "row", style: "justify-content:flex-end;margin-top:10px" }, el("button", { class: "btn primary", onclick: async () => { await invoke("rename_identity", { nodeHex: id.node_hex, label: i.value.trim() || id.label }); identitiesSheet(); } }, t("save"))))); } }, t("rename")),
      id.active ? null : el("button", { class: "btn small danger", title: t("remove"), onclick: async () => { if (confirm(t("remove_identity_confirm", id.label))) { await invoke("remove_identity", { nodeHex: id.node_hex }); identitiesSheet(); } } }, t("remove")),
    ));
  }
  idCard.append(el("div", { class: "row wrap", style: "margin-top:6px" },
    el("button", { class: "btn small", onclick: () => { const i = el("input", { placeholder: t("label_work_ph") }); modal(el("div", {}, el("h2", {}, t("new_identity")), i, el("div", { class: "row", style: "justify-content:flex-end;margin-top:10px" }, el("button", { class: "btn primary", onclick: async () => { await invoke("add_identity", { label: i.value.trim() || t("new_identity") }); identitiesSheet(); toast(t("identity_created")); } }, t("create"))))); } }, t("new_identity_btn")),
    el("button", { class: "btn small ghost", onclick: () => { const lab = el("input", { placeholder: t("label_ph") }); const seed = el("input", { placeholder: t("transfer_code_ph") }); modal(el("div", {}, el("h2", {}, t("link_existing")), lab, seed, el("div", { class: "row", style: "justify-content:flex-end;margin-top:10px" }, el("button", { class: "btn primary", onclick: async () => { try { await invoke("import_identity", { label: lab.value.trim() || t("imported_label"), seedB64: seed.value.trim() }); identitiesSheet(); toast(t("imported_toast")); } catch (e) { toast(t("import_failed", e)); } } }, t("import"))))); } }, t("import")),
  ));
  sheet(t("identities"), idCard);
}

// ---- Authorized devices (revocable multi-device roster — parity with iOS/Android) ----
async function devicesSheet() {
  const roster = await invoke("device_roster").catch(() => ({ enabled: false, this_device_authorized: false, devices: [] }));
  const roleTitle = roster.enabled ? t("primary_device_title")
    : roster.this_device_authorized ? t("linked_device_title") : t("not_linked_title");
  const roleSub = roster.enabled ? t("primary_device_sub")
    : roster.this_device_authorized ? t("linked_device_sub")
    : t("not_linked_sub");
  const devicesCard = el("div", { class: "col" },
    el("div", {}, el("strong", {}, roleTitle)),
    el("div", { class: "muted small" }, roleSub));
  if (!roster.devices.length) devicesCard.append(el("div", { class: "muted small" }, t("no_devices_linked")));
  for (const d of roster.devices) {
    devicesCard.append(el("div", { class: "list-item" },
      el("div", {}, d.is_primary ? "🔑" : "💻"),
      el("div", { style: "flex:1" }, el("div", { class: "name" }, d.name),
        el("div", { class: "muted small" }, d.is_primary ? t("master_key") : d.is_this_device ? t("this_device") : t("linked_device"))),
      d.is_primary ? null : el("button", { class: "btn small danger", onclick: async () => {
        if (confirm(t("revoke_confirm", d.name))) { await invoke("revoke_device", { nodeHex: d.node_hex }); devicesSheet(); }
      } }, t("revoke"))));
  }
  devicesCard.append(el("div", { class: "row wrap", style: "margin-top:6px" },
    roster.enabled
      ? el("button", { class: "btn small danger", onclick: async () => { if (confirm(t("step_down_confirm"))) { await invoke("step_down_as_primary"); devicesSheet(); } } }, t("not_my_primary"))
      : el("button", { class: "btn small", onclick: async () => { await invoke("enable_device_roster"); devicesSheet(); toast(t("now_primary_toast")); } }, t("make_my_primary")),
    roster.enabled ? null : el("button", { class: "btn small ghost", onclick: async () => { await invoke("request_device_enrollment"); toast(t("asked_primary_toast")); } },
      roster.this_device_authorized ? t("resync_primary") : t("make_linked_device"))));

  // seed-drop S4: the SECURE link. Only a seed-holding primary can grant, so offer it once this
  // device is the primary. A new device scans/pastes the one-time code, gets its OWN key + a
  // revocable credential + a granted self-sync key — and NEVER the master seed.
  const seedless = await invoke("seedless_status").catch(() => ({ seedless: false }));
  if (roster.enabled && !seedless.seedless) {
    devicesCard.append(el("div", { class: "row wrap", style: "margin-top:6px" },
      el("button", { class: "btn small primary", onclick: () => enrollDeviceSheet() }, t("add_device_secure"))));
  }

  // Any pending link requests waiting on this primary's approval.
  const pending = await invoke("enroll_pending").catch(() => []);
  for (const p of pending) {
    devicesCard.append(el("div", { class: "list-item" },
      el("div", {}, "🔗"),
      el("div", { style: "flex:1" },
        el("div", { class: "name" }, p.name || t("new_device")),
        el("div", { class: "muted small" }, t("wants_to_link"))),
      el("button", { class: "btn small primary", onclick: async () => { try { await invoke("enroll_approve", { deviceHex: p.device_hex }); toast(t("device_approved")); } catch (e) { toast("" + e); } devicesSheet(); } }, t("approve")),
      el("button", { class: "btn small ghost", onclick: async () => { await invoke("enroll_reject", { deviceHex: p.device_hex }); devicesSheet(); } }, t("dismiss"))));
  }

  sheet(t("devices"), devicesCard);
}

/// PRIMARY: mint a one-time `haven-enroll:` ticket and show it as a QR + copyable string for the new
/// device to scan/paste. The confirm step happens back in the Devices sheet when the request arrives.
async function enrollDeviceSheet() {
  let ticket = "";
  try { ticket = await invoke("enroll_mint_ticket"); }
  catch (e) { toast(t("couldnt_create_link_code", e)); return; }
  const qrBox = el("div", { class: "qr-box" });
  try { qrBox.innerHTML = makeQrSvg(ticket); } catch (_) { qrBox.textContent = t("qr_unavailable"); }
  const body = el("div", { class: "col", style: "gap:12px;align-items:center;text-align:center" },
    el("div", { class: "muted small" }, t("enroll_hint")),
    qrBox,
    el("button", { class: "btn small", onclick: async () => { try { await navigator.clipboard.writeText(ticket); toast(t("link_code_copied")); } catch (_) { toast(t("copy_failed")); } } }, t("copy_link_code")),
    el("div", { class: "muted small", style: "word-break:break-all;opacity:0.7" }, ticket),
    el("div", { class: "muted small" }, t("enroll_approve_hint")));
  sheet(t("add_a_device"), body);
}

const line = (label, ok) => el("div", { class: "row" }, el("span", { style: "flex:1" }, label), el("span", { class: ok ? "ok-text" : "warn-text" }, ok ? t("pass") : t("fail")));

// ---- WebRTC mesh calls -----------------------------------------------------------------
// Mirrors the iOS/Android CallManager: a call = sessionId + roster of node hexes; every
// participant opens one RTCPeerConnection to every other (full mesh, no SFU). 1:1 is a
// 2-person group. The lexicographically smaller hex offers (glare-free). SDP/ICE ride the
// sealed iroh channel via the call_signal command; media is DTLS-SRTP in the WebView.
// Haven-first ICE — parity with Apple HavenFabric / Android FabricIcePolicy.
// Fabric (with or without TURN) → circle TURN/STUN if present, never Google; the WSS hairpin
// carries media when ICE cannot pair. No fabric → circle TURN + same-host STUN if publicly
// reachable, else Google STUN as the last resort. Signaling uses iroh/fabric DERP throughout.
const GOOGLE_STUN = ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"];

// Best-effort "is this turn:/stun: URL's host a private/unroutable address" check.
function hostLooksPrivate(url) {
  const host = String(url).split(":")[1] || "";
  const second = parseInt((host.split(".")[1] || ""), 10);
  return host.startsWith("10.") || host.startsWith("192.168.") || host.startsWith("127.") ||
    host.startsWith("169.254.") ||
    (host.startsWith("172.") && second >= 16 && second <= 31);
}

function iceServers() {
  const turn = window.__havenFabricTurn || {};
  const turnUrls = Array.isArray(turn.urls) ? turn.urls.filter(Boolean) : [];
  const servers = [];
  let havePublicTurn = false;
  if (turnUrls.length > 0 && turn.user && turn.pass) {
    servers.push({ urls: turnUrls, username: turn.user, credential: turn.pass });
    // The circle TURN host doubles as a STUN server (same socket, no credentials) — srflx
    // candidates from our own infrastructure, no third party involved.
    const stun = turnUrls
      .map((u) => String(u).split(":").slice(1).join(":"))
      .filter(Boolean)
      .map((hostPort) => `stun:${hostPort}`);
    if (stun.length > 0) servers.push({ urls: stun });
    havePublicTurn = turnUrls.some((u) => !hostLooksPrivate(u));
  }
  // PUBLIC STUN IS A LAST RESORT, not a default companion — parity with Apple HavenFabric and
  // Android FabricIcePolicy. Google is reached for only when NO Haven relay is available to carry
  // this call. A configured fabric counts as available even with no TURN of its own, because the
  // relay's path proxy serves the WSS hairpin below (opened alongside ICE, taking over media on
  // `failed`) — so media has a route that never touches a third party.
  //
  // This narrows the previous rule, which appended Google whenever no PUBLICLY reachable TURN was
  // configured, including alongside a perfectly healthy fabric — disclosing every caller's address
  // to Google during ICE purely because the circle's relay had no TURN.
  //
  // The field failure that motivated the old rule is still covered: a relay advertising a
  // Docker-internal TURN host, with no fabric, is not an available relay, so the fallback still
  // applies. What is gone is the case where a working fabric was present all along.
  const haveFabric = Array.isArray(window.__havenFabricDerp) && window.__havenFabricDerp.length > 0;
  if (!haveFabric && !havePublicTurn) {
    servers.push({ urls: GOOGLE_STUN });
    console.info("ice: no Haven relay for this call — falling back to public STUN");
  }
  return servers;
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
    // Binary: a framed media packet from the peer (media fallback) — see unpackHairpin. Audio is
    // s16le mono 16 kHz once the header is off; video frames are dropped (no desktop decoder).
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
// ---- Active-speaker detection ----------------------------------------------------------------
// One `getStats()` walk per connection every second, then whoever is loudest wins — with the same
// 0.02 threshold and 2-poll debounce Apple and Android use, so a group call highlights the same
// person on every platform at the same moment. A 1:1 call skips entirely: with one remote peer
// there is nothing to disambiguate, so the highlight is not worth any stats traffic.
const SPEAKING_THRESHOLD = 0.02;
const SPEAKER_DEBOUNCE = 2;

function startSpeakerDetection() {
  if (call.speakerTimer) return;
  call.speakerTimer = setInterval(pollAudioLevels, 1000);
}

function stopSpeakerDetection() {
  if (call.speakerTimer) clearInterval(call.speakerTimer);
  call.speakerTimer = null;
  call.speakerStreak = {};
  call.activeSpeaker = null;
}

/**
 * Move the highlight by toggling a class on the tiles that already exist.
 *
 * NOT renderCallOverlay(): that does `replaceChildren` and builds fresh <video> elements with their
 * `srcObject` reassigned. The active speaker changes as often as people take turns talking — doing
 * a full rebuild for each change would tear down and re-attach every video in the call, which is a
 * black flash on every sentence. The highlight is one CSS class; it has no business re-rendering
 * anything.
 */
function paintActiveSpeaker() {
  document.querySelectorAll(".call-tile[data-peer]").forEach((tile) => {
    tile.classList.toggle("speaking", tile.dataset.peer === call.activeSpeaker);
  });
}

async function pollAudioLevels() {
  const entries = [...call.pcs.entries()];
  if (entries.length <= 1) {
    if (call.activeSpeaker !== null) { call.activeSpeaker = null; paintActiveSpeaker(); }
    call.speakerStreak = {};
    return;
  }
  let bestPeer = "", bestRemote = 0, myLevel = 0;
  await Promise.all(entries.map(async ([hex, pc]) => {
    const report = await pc.getStats().catch(() => null);
    if (!report) return;
    report.forEach((s) => {
      if (s.kind !== "audio" || typeof s.audioLevel !== "number") return;
      if (s.type === "inbound-rtp" && s.audioLevel > bestRemote) { bestRemote = s.audioLevel; bestPeer = hex; }
      if (s.type === "media-source" && s.audioLevel > myLevel) myLevel = s.audioLevel;
    });
  }));

  let candidate = null;
  if (myLevel >= SPEAKING_THRESHOLD && call.micOn && myLevel >= bestRemote) candidate = "";
  else if (bestRemote >= SPEAKING_THRESHOLD) candidate = bestPeer;

  if (candidate === null) {
    call.speakerStreak = {};
    if (call.activeSpeaker !== null) { call.activeSpeaker = null; paintActiveSpeaker(); }
    return;
  }
  const streak = (call.speakerStreak[candidate] || 0) + 1;
  call.speakerStreak = { [candidate]: streak };
  if (streak >= SPEAKER_DEBOUNCE && call.activeSpeaker !== candidate) {
    call.activeSpeaker = candidate;
    paintActiveSpeaker();
  }
}

// ---- Hairpin media frame format ------------------------------------------------------------
// `[type u8][seq u16 BE][ptsMs u32 BE]` then the payload — byte-for-byte Apple `CallMediaBridge`
// and Android `CallMediaBridge`, because all three relay through the SAME proxy socket and the
// proxy bipipes bytes without interpreting them.
//
// Desktop used to send and expect BARE PCM with no header at all. Against another desktop that
// happened to work; against Apple it failed in both directions and silently — Apple's `unpack`
// requires ≥7 bytes with a valid type in byte 0, so it dropped every desktop frame as malformed,
// while desktop played Apple's 7 header bytes as if they were audio samples. The hairpin is the
// fallback that rescues a call when ICE cannot pair, so this was a fallback that only ever worked
// between two desktops.
const HAIRPIN_AUDIO = 1;
const HAIRPIN_VIDEO_KEY = 2;
const HAIRPIN_VIDEO_DELTA = 3;
const HAIRPIN_HEADER_BYTES = 7;

function packHairpin(type, seq, ptsMs, payload) {
  const out = new Uint8Array(HAIRPIN_HEADER_BYTES + payload.byteLength);
  out[0] = type & 0xff;
  out[1] = (seq >> 8) & 0xff;
  out[2] = seq & 0xff;
  out[3] = (ptsMs >>> 24) & 0xff;
  out[4] = (ptsMs >>> 16) & 0xff;
  out[5] = (ptsMs >>> 8) & 0xff;
  out[6] = ptsMs & 0xff;
  out.set(payload, HAIRPIN_HEADER_BYTES);
  return out.buffer;
}

/** Returns {type, seq, payload:Uint8Array}, or null when the frame is not one of ours. */
function unpackHairpin(ab) {
  const d = new Uint8Array(ab);
  if (d.byteLength < HAIRPIN_HEADER_BYTES) return null;
  const type = d[0];
  if (type !== HAIRPIN_AUDIO && type !== HAIRPIN_VIDEO_KEY && type !== HAIRPIN_VIDEO_DELTA) return null;
  return {
    type,
    seq: (d[1] << 8) | d[2],
    payload: d.subarray(HAIRPIN_HEADER_BYTES),
  };
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
      slot.audioSeq = ((slot.audioSeq || 0) + 1) & 0xffff;
      try { slot.ws.send(packHairpin(HAIRPIN_AUDIO, slot.audioSeq, 0, new Uint8Array(pcm.buffer))); }
      catch (_) {}
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
    toast(t("call_media_hairpin"));
  } catch (e) {
    console.warn("hairpin media start failed", e);
    slot.usingMedia = false;
  }
}
function hairpinPlayPcm(slot, ab) {
  try {
    if (!slot.audioCtx || !slot.remoteGain) return;
    const parsed = unpackHairpin(ab);
    // Not one of ours (or a video frame this platform can't render) — drop it rather than playing
    // the bytes as audio. Desktop has no hairpin video decoder; the audio still carries the call.
    if (!parsed || parsed.type !== HAIRPIN_AUDIO) return;
    const pcm = new Int16Array(parsed.payload.buffer, parsed.payload.byteOffset, parsed.payload.byteLength >> 1);
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
  // camOn starts FALSE: calls are audio-only until the user turns the camera on (Apple/Android
  // parity). hasCamera is set once the stream is acquired — null until then, false only when the
  // device genuinely has no usable camera, which is the one case the control is hidden.
  localStream: null, micOn: true, camOn: false, hasCamera: null,
  // UI state: minimized = the call keeps running in a corner pill so the rest of Haven stays
  // browsable (iOS/macOS have had this shape from day one; desktop trapped you in the overlay).
  minimized: false,
  // Device routing. Persisted so the next call starts on the devices the user chose.
  audioIns: [], audioOuts: [],
  micDevice: localStorage.getItem("haven-mic-device") || "",
  spkDevice: localStorage.getItem("haven-spk-device") || "",
  /// Peers whose camera is OFF, per frame 22 — their tile shows an avatar instead of the frozen
  /// last frame their stopped track left behind. Cleared with the rest of the call state.
  camOff: {},
  ringing: false, connecting: false, inCall: false, video: true,
  /// Loudest participant right now (a peer hex, "" for me, null for nobody) plus the debounce
  /// counter behind it — see pollAudioLevels. Apple/Android parity.
  activeSpeaker: null, speakerStreak: {}, speakerTimer: null,
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
// MUST outlive the window in which an invite is still accepted (180s on iOS/Android — desktop has
// no age check at all, so it accepts any invite that arrives). At 45s the tombstone expired long
// before retransmits stopped, leaving ~135s in which a replayed invite for a call the user had
// already dismissed found nothing suppressing it and re-opened the call screen, repeatedly. A
// tombstone that does not outlive the thing it suppresses suppresses nothing.
const INVITE_MAX_AGE_MS = 180_000;
const ENDED_TOMBSTONE_MS = INVITE_MAX_AGE_MS + 30_000;

/** Arm the bounded ring. Cleared by accept and by teardown (decline, hangup, end). */
function startRingTimeout() {
  clearTimeout(call.ringTimer);
  call.ringTimer = setTimeout(() => {
    if (!call.ringing || call.inCall) return;
    toast(call.name ? t("missed_call_from", call.name) : t("missed_call"));
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

// Mirror the call's UI state down to Rust so the QA dump can report it. Desktop's call state lives
// only here in JS, so the Rust-built qa-dump could not see it — and the e2e call step asserts on ios
// and stub only. That blind spot let an established call ended on iOS strand THIS leg in a dead call
// while the suite reported green. Cheap and idempotent; safe to call on every transition.
function qaPushCallState() {
  try { invoke("qa_set_call_state", { ringing: !!call.ringing, inCall: !!call.inCall, session: call.session || "" }); } catch (_) {}
}

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
// ---- Autoplay: the post nearest the middle, and only that one --------------------------------
//
// Apple's rule, ported rather than reinvented: FeedView reports every post's centre through a
// preference key, takes `min(abs(centre - screenCentre))`, and hands that ONE id to
// AudioCoordinator. A single centred id is what guarantees one clip at a time — picking "whatever
// is visible" plays three at once on a tall window, which is the noise this avoids.
//
// SUPER DATA SAVER IS THE ONLY KILL SWITCH, matching Apple: it never autoplays anything and only
// loads the poster still. Everything else — the sound toggle, a call, a capture — controls whether
// the clip is AUDIBLE, not whether it moves.
// Set while WE are changing `muted`, so the volumechange listener above can tell the user's
// intent from our own bookkeeping — ducking unmutes one clip and must not be read as "sound on".
let adoptingSound = false;

const Autoplay = {
  current: null,
  suspended() {
    // A sheet, a story viewer, a live call or a recording all own the screen; the feed goes quiet
    // behind them exactly as `pauseFeedMedia` already does when they open.
    // A tab that is not the feed counts as covered: switching to Messages or Settings left the
    // centred post playing underneath, which is the same fault as an overlay not stopping it.
    return state.superDataSaver || callAudioActive() || captureUIOpen()
      || (state.view !== "circle" && state.view !== "you")
      || !!$("#modal-root").firstChild || !!$("#menu-root").firstChild || document.hidden;
  },
  /** rAF-coalesced: scroll fires far faster than layout can be read, and reading rects per event
   *  is what turns a smooth fling into a stutter. */
  scheduled: false,
  schedule() {
    if (this.scheduled) return;
    this.scheduled = true;
    requestAnimationFrame(() => { this.scheduled = false; this.apply(); });
  },
  apply() {
    // THE CENTRED POST, not the centred video.
    //
    // This scanned videos and bailed when there were none, so a PHOTO post carrying a song was
    // never the centre of anything — its song never started, and never stopped when scrolled past.
    // Apple picks the centred POST and then plays whatever that post has; this now does the same,
    // which is also why the video below is chosen through the card rather than beside it.
    // Only cards the viewport observer says are on screen. Measuring every card in the document
    // meant a forced layout per card per scroll frame — cheap with 25, ruinous with hundreds.
    const cards = this.onscreen.size
      ? [...this.onscreen]
      : document.querySelectorAll("#view-circle [data-post], #view-you [data-post]");
    const vids = document.querySelectorAll("#view-circle video[data-video], #view-you video[data-video]");
    if (this.suspended()) {
      vids.forEach((v) => { if (!v.paused) try { v.pause(); } catch (_) {} });
      this.current = null;
      this.centeredCard = null;
      this.song.sync(null);
      return;
    }
    const mid = window.innerHeight / 2;
    let card = null, bestDist = Infinity;
    for (const c of cards) {
      const r = c.getBoundingClientRect();
      if (r.bottom <= 0 || r.top >= window.innerHeight) continue;   // off screen entirely
      const d = Math.abs((r.top + r.bottom) / 2 - mid);
      if (d < bestDist) { bestDist = d; card = c; }
    }
    const best = card ? card.querySelector("video[data-video]") : null;
    for (const v of vids) {
      if (v === best) continue;
      if (!v.paused) try { v.pause(); } catch (_) {}
    }
    this.current = best;
    this.centeredCard = card;

    // A SONG OWNS THE POST'S AUDIO. When the card carries a chip its clip still plays — muted — and
    // the song is what you hear, matching Apple and matching what Stories already did here.
    // DUCKED: the reader chose this clip's own audio over the song. Sticky per post for the
    // session, so scrolling away and back does not quietly undo that.
    const postId = card ? card.dataset.post : null;
    const ducked = postId && this.ducked.has(postId);
    const hasSong = card ? card.dataset.song === "1" && !ducked : false;
    if (best) {
      best.muted = hasSong || callAudioActive() || captureUIOpen() || !state.videoSoundOn;
      best.loop = true;
      if (best.paused) best.play().catch(() => {});   // a refused autoplay is not an error
    }
    this.song.sync(hasSong ? card : null);
  },

  /** Posts whose clip the reader chose over the attached song. */
  ducked: new Set(),

  /** The post nearest the viewport centre — what "playing" is scoped to. */
  centeredCard: null,

  /** Cards currently on screen, maintained by an observer so `apply` never has to measure the
   *  whole document. Re-armed by `track` as each page of cards is built. */
  onscreen: new Set(),
  seen: null,
  track(root) {
    if (!this.seen) {
      this.seen = new IntersectionObserver((entries) => {
        for (const e of entries) {
          if (e.isIntersecting) this.onscreen.add(e.target); else this.onscreen.delete(e.target);
        }
        this.schedule();
      }, { rootMargin: "200px 0px" });
    }
    root.querySelectorAll?.("[data-post]").forEach((c) => this.seen.observe(c));
  },

  /** Unmute — globally, matching Apple, where unmuting one post unmutes the feed. Persisted, so it
   *  survives a relaunch the way the header toggle does. */
  async enableSound(video) {
    state.videoSoundOn = true;
    adoptingSound = true;
    try {
      await invoke("set_video_sound", { on: true }).catch(() => {});
      syncFeedVideoSound();
      if (video) video.muted = false;
    } finally { adoptingSound = false; }
  },

  /** Tapping a MUTED clip means "let me hear this one" — Apple's behaviour, and the reason the tap
   *  target is the video rather than a separate control. Only for a clip actually carrying audio and
   *  not muted by its author: for those two there is nothing to duck TO, and stopping the song would
   *  leave the post silent. */
  duck(video) {
    const card = video.closest("[data-post]");
    if (!card || card.dataset.song !== "1") return false;
    if (card.dataset.mutedByAuthor === "1") return false;
    if (!videoHasAudio(video)) return false;
    this.ducked.add(card.dataset.post);
    this.song.stop();
    adoptingSound = true;
    video.muted = false;
    adoptingSound = false;
    return true;
  },

  // The attached song itself. Desktop never played one in the feed — the chip was a link with a
  // sound toggle that governed the VIDEO — so "the song owns the audio" would have meant silence.
  // A TrackRef carries no preview URL (nothing about a preview belongs on a post), so it is resolved
  // by name and cached for the session, the same way Android's MusicSearch.resolve does it.
  song: {
    audio: null, postId: null, cache: new Map(), seq: 0,
    stop() {
      if (this.audio) {
        try { this.audio.pause(); this.audio.src = ""; } catch (_) {}
        this.audio = null;
      }
      this.postId = null;
      this.seq++;              // invalidate anything still resolving
    },
    async sync(card) {
      if (!card) return this.stop();
      const id = card.dataset.post;
      if (this.postId === id) return;            // already this post's song
      this.stop();
      if (!state.videoSoundOn && deviceLikelySilent()) return;
      const title = card.dataset.songTitle || "", artist = card.dataset.songArtist || "";
      if (!title) return;
      // THE TOKEN IS WHY THIS CANNOT STACK.
      //
      // Resolving a preview URL is a network round trip, and scrolling starts one per post. Two
      // could finish out of order, and the second `this.audio = new Audio(...)` overwrote the
      // first's handle WITHOUT stopping it — leaving a looping clip with nothing left to reference
      // it. That is the song that got stuck playing over everything, and every scroll past another
      // song added one more.
      //
      // `stop()` bumps the token, so a resolve that started before it can never assign.
      const token = ++this.seq;
      const key = title + "|" + artist;
      let url = this.cache.get(key);
      if (url === undefined) {
        const hit = await invoke("music_resolve", {
          title, artist, catalogId: card.dataset.songCatalog || "",
        }).catch(() => null);
        url = (hit && hit.preview_url) || null;
        this.cache.set(key, url);
      }
      if (!url || token !== this.seq || Autoplay.centeredCard !== card) return;
      this.stop();                               // belt and braces: never assign over a live one
      this.seq = token;                          // stop() bumped it; this request is still current
      this.postId = id;
      this.audio = new Audio(url);
      this.audio.loop = true;
      this.audio.play().catch(() => { this.stop(); });
    },
  },
};

/** Does this clip actually carry an audio track? Used to decide whether ducking has anywhere to go.
 *  `webkitAudioDecodedByteCount` is the only reliable read in this WebView; absent metadata is
 *  treated as "yes", so the ambiguous case still lets the reader hear the clip. */
function videoHasAudio(v) {
  if (typeof v.webkitAudioDecodedByteCount === "number") return v.webkitAudioDecodedByteCount > 0;
  if (typeof v.mozHasAudio === "boolean") return v.mozHasAudio;
  return true;
}

/** A WebView cannot read the system mute state, so this is deliberately conservative: it never
 *  claims the device is silent. The in-app toggle is the real control on desktop, and this exists
 *  so the rule reads the same on both platforms. */
function deviceLikelySilent() { return false; }
window.addEventListener("scroll", () => Autoplay.schedule(), true);
window.addEventListener("resize", () => Autoplay.schedule());
document.addEventListener("visibilitychange", () => Autoplay.schedule());

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
  // The header speaker has to agree. Sound can now be turned on by tapping a clip or by its own
  // native control, and re-rendering the whole feed just to repaint one glyph would restart every
  // video on the screen.
  document.querySelectorAll("[data-sound-toggle]").forEach((b) => {
    b.title = state.videoSoundOn ? t("mute_all_videos") : t("unmute_all_videos");
    b.replaceChildren(icon(state.videoSoundOn ? "speaker" : "speaker.slash"));
  });
}

const invitees = () => [...call.roster].filter((h) => h !== call.me).sort();

async function callStart(others, name, video) {
  if (call.inCall || call.ringing || call.connecting) { others.forEach((o) => call.roster.add(o)); return; }
  call.me = state.node;
  call.session = `win-${call.me.slice(0, 8)}-${Date.now()}`;
  call.roster = new Set([...others, call.me]);
  // Calls START audio-only on every platform. `call.video` still records that this was raised as a
  // video call (it drives whether the camera control is offered), but the camera itself begins off.
  call.name = name; call.video = video; call.connecting = true; call.camOn = false;
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
  if (!addable.length) { toast(t("no_one_to_add")); return; }
  modal(el("div", {}, el("h2", {}, t("add_to_call")),
    el("div", { class: "col", style: "max-height:300px;overflow:auto" },
      ...addable.map((c) => el("div", { class: "list-item" },
        el("div", { class: "avatar", style: "width:30px;height:30px;font-size:12px" }, initials(c.name)),
        el("div", { style: "flex:1" }, c.name),
        el("button", { class: "btn small", onclick: async (e) => { await addToCall([c.id_hex]); e.target.textContent = t("added_check"); e.target.disabled = true; } }, t("add")))))));
}

async function callAccept() {
  clearTimeout(call.ringTimer); call.ringTimer = null;
  call.ringing = false; call.inCall = true; qaPushCallState();
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
  await invoke("call_hangup", { to: invitees(), sessionId: call.session });
  teardownCall();
}

async function startMesh() {
  if (call.localStream) return;
  // Acquire audio AND video up front, then start the camera track DISABLED — a call begins
  // audio-only, matching Apple and Android.
  //
  // Two reasons it must be acquired rather than skipped. A track added later adds an m-line later,
  // and the re-offer carrying it can present its m-lines in a different order than was negotiated —
  // WebRTC rejects that outright and the peer connection dies (the "order of m-lines in subsequent
  // offer doesn't match" failure that was ending iOS↔Android calls). And the camera button here only
  // ever rendered when `call.video` was true, so simply defaulting to audio removed any way to turn
  // video on at all. Publishing the track disabled fixes both: the session shape is fixed for the
  // call's lifetime and enabling video is instant, with no renegotiation.
  try {
    call.localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: true });
  } catch (e) {
    // No camera (or refused) — audio still works; the camera button stays disabled.
    call.localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false }).catch(() => null);
    if (!call.localStream) toast(t("mic_unavailable", e));
  }
  if (call.localStream) {
    const vids = call.localStream.getVideoTracks();
    vids.forEach((t) => (t.enabled = !!call.camOn));
    call.hasCamera = vids.length > 0;
  }
  refreshAudioDevices().then(renderCallOverlay);   // labels exist now that permission is granted
  if (call.micDevice) applyMicDevice(call.micDevice);   // start on the user's chosen mic
  call.connecting = call.connecting && !call.inCall;
  ensureHairpins(); // TCP/WSS media path through free CF path proxy (pairs while ICE runs)
  invitees().forEach(connectPeerIfNeeded);
  // Announce the STARTING camera state. A disabled track does not stop sending — it sends black
  // frames — so a peer that is never told renders a black rectangle and assumes video is broken.
  {
    const peers = invitees();
    if (peers.length) {
      invoke("call_camera_state", { sessionId: call.session, on: !!call.camOn, to: peers }).catch(() => {});
    }
  }
  startSpeakerDetection();
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
        call.connecting = false; call.inCall = true; qaPushCallState();
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
      // Answering must not switch our own camera on — audio-only, like Apple. `video` only means
      // the call supports video, which is now always true because the track is always published.
      call.ringing = true; call.video = true; call.camOn = false; qaPushCallState();
      startRingTimeout(); syncFeedVideoSound(); renderCallOverlay();
      break;
    }
    case "accept": {
      if (!validSession(c.sessionId)) return;
      call.connecting = false; call.inCall = true; call.roster.add(c.from); qaPushCallState();
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
    // My account ENDED this session on another device (frame 35). Unlike handledElsewhere above,
    // this must also end a call this device has already ANSWERED — that guard is exactly why an
    // established call ended on the phone left this leg sitting in a dead call with no way out.
    // Still narrow: only my own account (the frame's signature is checked before it reaches here)
    // and only the session this device is actually in.
    case "endedElsewhere": {
      // Match the live session — or an EMPTY one (in-call with no session is the zombie state; when
      // my own account ends a session and this device cannot name its own, tear down).
      if (call.session && c.sessionId !== call.session) return;
      if (!(call.ringing || call.connecting || call.inCall)) return;
      teardownCall();
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
      // Gate on the session, like every other signal here already does. A retransmitted or
      // late-relayed BYE from an EARLIER call used to tear down whichever call was live when it
      // landed — an outgoing call whose screen appears and vanishes, or a connected call that hangs
      // itself up for no visible reason. Frames from older builds carry no session id; those still
      // apply, so this only ever tightens behaviour. iOS/Android parity.
      if (c.sessionId && !validSession(c.sessionId)) {
        console.warn("hangup ignored — session", c.sessionId, "is not ours", call.session);
        return;
      }
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

// NO SESSION MEANS NO NEGOTIATION — `|| !call.session` accepted any media signal while in no call,
// which let one late OFFER rebuild a zombie call the teardown frame could then never match. Android
// twin has the full account; same rule on every platform.
const validSession = (sid) => !!call.session && sid === call.session;
function displayNameFor(hex) {
  const c = (state.contacts || []).find((x) => x.id_hex === hex);
  return c ? c.name : t("someone");
}

/** The contact behind a feed item's SHORT (8-hex) author id, or undefined if we don't hold them.
 *  A post only carries the short id, so anything addressed to its author has to resolve it first. */
/** The disc contents for a post/comment author: their picture, else their emoji, else initials.
 *
 *  Every avatar in the feed was `initials(name)` unconditionally, so the emoji or photo you chose
 *  showed on the profile header and nowhere else — your own posts wore a letter.
 *
 *  Only MY OWN identity can be resolved here: ContactDto carries id/name/verify and no appearance
 *  at all, so a peer's chosen emoji is not something this client currently holds. Their posts keep
 *  initials until the roster carries it.
 */
function avatarContent(isMe, name) {
  if (isMe) {
    const p = state.profile || {};
    if (p.avatar) return el("img", { src: p.avatar, alt: "" });
    if (p.emoji) return p.emoji;
  }
  return initials(name);
}

function authorContact(authorShort) {
  if (!authorShort) return undefined;
  return (state.contacts || []).find((c) => (c.id_hex || "").startsWith(authorShort));
}

function teardownCall() {
  call.minimized = false;
  stopSpeakerDetection();
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
  call.roster.clear(); call.session = ""; call.ringing = false; call.connecting = false; call.inCall = false; qaPushCallState();
  syncFeedVideoSound();   // restore the user's global video-sound choice now the call is over
  renderCallOverlay();
}

function toggleMic() { call.micOn = !call.micOn; if (call.localStream) call.localStream.getAudioTracks().forEach((t) => (t.enabled = call.micOn)); renderCallOverlay(); }
async function toggleCam() {
  call.camOn = !call.camOn;
  // Stream came up audio-only (no camera at answer time, or it was busy)? Acquire video NOW and
  // publish it via replaceTrack/addTrack — turning the camera on mid-call must not need a re-call.
  if (call.camOn && call.localStream && call.localStream.getVideoTracks().length === 0) {
    try {
      const v = await navigator.mediaDevices.getUserMedia({ video: true });
      const track = v.getVideoTracks()[0];
      if (track) {
        call.localStream.addTrack(track);
        call.hasCamera = true;
        for (const pc of call.pcs.values()) {
          const sender = pc.getSenders().find((x) => x.track && x.track.kind === "video");
          if (sender) await sender.replaceTrack(track); else pc.addTrack(track, call.localStream);
        }
      }
    } catch (_) { call.camOn = false; call.hasCamera = false; }
  }
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
  } catch (e) { toast(t("screen_share_unavailable", e)); return; }
  const screenTrack = display.getVideoTracks()[0];
  if (!screenTrack) { toast(t("no_screen_selected")); return; }
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

/// Fill call.audioIns/audioOuts. Labels are only populated once mic permission is granted, so this
/// runs after the local stream is acquired and again on devicechange.
async function refreshAudioDevices() {
  try {
    const all = await navigator.mediaDevices.enumerateDevices();
    call.audioIns = all.filter((d) => d.kind === "audioinput");
    call.audioOuts = all.filter((d) => d.kind === "audiooutput");
  } catch (_) { call.audioIns = []; call.audioOuts = []; }
}
try { navigator.mediaDevices.addEventListener("devicechange", () => { refreshAudioDevices().then(renderCallOverlay); }); } catch (_) {}

/// Switch the microphone mid-call: capture the chosen device, swap the audio track into the local
/// stream and into every peer connection via replaceTrack (no renegotiation).
async function applyMicDevice(id) {
  call.micDevice = id; try { localStorage.setItem("haven-mic-device", id); } catch (_) {}
  try {
    const fresh = await navigator.mediaDevices.getUserMedia({ audio: id ? { deviceId: { exact: id } } : true });
    const track = fresh.getAudioTracks()[0];
    if (!track) return;
    track.enabled = call.micOn;
    if (call.localStream) {
      call.localStream.getAudioTracks().forEach((t) => { call.localStream.removeTrack(t); t.stop(); });
      call.localStream.addTrack(track);
    }
    for (const pc of call.pcs.values()) {
      const sender = pc.getSenders().find((x) => x.track && x.track.kind === "audio");
      if (sender) await sender.replaceTrack(track);
    }
  } catch (e) { toast(t("mic_unavailable", e)); }
}

/// Route call audio to the chosen output. setSinkId lives on media ELEMENTS, so it must be applied
/// to every element the overlay creates — applySink() is called on each at render time too.
function applySpeakerDevice(id) {
  call.spkDevice = id; try { localStorage.setItem("haven-spk-device", id); } catch (_) {}
  document.querySelectorAll(".call-tile video, .call-tile audio, .call-mini audio").forEach(applySink);
}
function applySink(elm) {
  if (call.spkDevice && elm.setSinkId) elm.setSinkId(call.spkDevice).catch(() => {});
}

/// One hidden <audio> per peer stream, ALWAYS. The camera-off tile used to render an avatar and no
/// media element at all — and WebRTC audio only plays through an attached element, so a peer who
/// turned their camera off went SILENT here. The video element (when shown) is muted so the pair
/// never double-plays.
function peerAudioEl(peer) {
  const a = el("audio", { autoplay: "" });
  if (call.remote && call.remote[peer]) a.srcObject = call.remote[peer];
  applySink(a);
  return a;
}

function deviceSelect(kind, list, current, onchange) {
  const sel = el("select", { class: "call-device", title: t(kind) });
  sel.append(el("option", { value: "" }, t(kind) + " · " + t("default_device")));
  for (const d of list) {
    const o = el("option", { value: d.deviceId }, d.label || d.deviceId.slice(0, 8));
    if (d.deviceId === current) o.selected = true;
    sel.append(o);
  }
  sel.onchange = () => onchange(sel.value);
  return sel;
}

/// The minimized pill: the call keeps running, the app stays usable. Audio for every peer keeps
/// playing through the hidden elements built here.
function renderMiniCall(root) {
  const who = call.name || invitees().map(displayNameFor).join(", ");
  const bar = el("div", { class: "call-mini" },
    el("span", { class: "call-mini-dot" }),
    el("span", { class: "call-mini-name" }, t("in_call_with", who)),
    el("button", { class: "btn sm " + (call.micOn ? "" : "danger"), onclick: () => { toggleMic(); } }, call.micOn ? t("mute") : t("unmute")),
    el("button", { class: "btn sm", onclick: () => { call.minimized = false; renderCallOverlay(); } }, t("expand_call")),
    el("button", { class: "btn sm danger", onclick: () => callHangup() }, t("hang_up")),
  );
  for (const peer of invitees()) bar.append(peerAudioEl(peer));
  root.replaceChildren(bar);
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
      el("h2", {}, t("incoming_call")), el("p", { class: "muted" }, t("is_calling", call.name)),
      el("div", { class: "row", style: "justify-content:center;gap:16px;margin-top:14px" },
        el("button", { class: "btn danger", onclick: () => callHangup() }, t("decline")),
        el("button", { class: "btn primary", onclick: () => callAccept() }, t("accept")),
      ))));
    return;
  }
  if (call.minimized) { renderMiniCall(root); return; }
  // In-call / connecting: a video grid + controls.
  const grid = el("div", { class: "call-grid" });
  const localTile = el("div", { class: "call-tile" });
  if (call.camOn && call.localStream) {
    const lv = el("video", { autoplay: "", muted: "", playsinline: "" });
    lv.srcObject = call.localStream;
    localTile.append(lv);
  } else {
    // Camera off → OUR avatar, matching how peers render us. A muted black <video> reads as broken.
    localTile.append(el("div", { class: "avatar big" }, initials(state.profile?.name || t("you"))));
  }
  localTile.append(el("span", { class: "call-name" }, t("you") + (call.camOn ? "" : t("camera_off_suffix"))));
  grid.append(localTile);
  for (const peer of invitees()) {
    // Who is talking, so a group call doesn't make you guess. Apple/Android parity.
    // `data-peer` lets paintActiveSpeaker() repaint this tile IN PLACE — see why below.
    const speaking = call.activeSpeaker === peer;
    const tile = el("div", { class: "call-tile" + (speaking ? " speaking" : ""), "data-peer": peer });
    const camOff = !!(call.camOff && call.camOff[peer]);
    // Camera off (told to us by frame 22) → show their avatar, NOT the frozen last frame their
    // stopped track left behind.
    if (camOff) {
      tile.append(el("div", { class: "avatar big" }, initials(displayNameFor(peer))));
    } else {
      // muted: audio plays through the ALWAYS-attached <audio> below, never twice.
      const v = el("video", { autoplay: "", playsinline: "", muted: "" });
      if (call.remote && call.remote[peer]) v.srcObject = call.remote[peer];
      applySink(v);
      tile.append(v);
    }
    tile.append(peerAudioEl(peer));
    tile.append(el("span", { class: "call-name" }, displayNameFor(peer) + (camOff ? t("camera_off_suffix") : "")));
    grid.append(tile);
  }
  root.replaceChildren(el("div", { class: "modal-backdrop" }, el("div", { class: "call-overlay-full" },
    el("div", { class: "call-topbar" },
      el("div", { class: "muted small" }, call.connecting ? t("calling_name", call.name) : call.name),
      el("button", { class: "btn sm", onclick: () => { call.minimized = true; renderCallOverlay(); } }, t("minimize_call")),
    ),
    grid,
    el("div", { class: "call-devices" },
      deviceSelect("mic_input", call.audioIns, call.micDevice, applyMicDevice),
      deviceSelect("speaker_output", call.audioOuts, call.spkDevice, applySpeakerDevice),
    ),
    el("div", { class: "call-controls" },
      el("button", { class: "btn " + (call.micOn ? "" : "danger"), onclick: toggleMic }, call.micOn ? t("mute") : t("unmute")),
      // Always offered — the track is published for every call, so video is always available. It was
      // gated on `call.video`, which meant an audio call could never become a video one.
      // Offered whenever a camera EXISTS. `hasCamera` is false when the stream came up audio-only —
      // which also happens when the camera was merely BUSY at answer time — and hiding the button
      // then left desktop with no way to ever turn video on (reported directly). enableCamera()
      // acquires the track on demand.
      (call.hasCamera === false && !call.audioIns.length && !call.camOn) ? null
        : el("button", { class: "btn " + (call.camOn ? "" : "danger"), onclick: toggleCam }, call.camOn ? t("camera_off_btn") : t("camera_on_btn")),
      el("button", { class: "btn " + (call.screenOn ? "primary" : ""), onclick: toggleScreen }, call.screenOn ? t("stop_sharing") : t("share_screen")),
      el("button", { class: "btn", onclick: addToCallDialog }, t("add_call_btn")),
      el("button", { class: "btn danger", onclick: () => callHangup() }, t("hang_up")),
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
    el("h2", { style: "font-size:26px;font-weight:800;margin:0;text-align:center" }, t("ground_rules")),
    el("p", { class: "muted small", style: "margin:0" },
      t("terms_intro")),
    rule("🚫", t("never_allowed_t"), t("never_allowed_b")),
    rule("🛡️", t("enforces_t"), t("enforces_b")),
    rule("📒", t("on_record_t"), t("on_record_b")),
    rule("💜", t("own_share_t"), t("own_share_b")),
    el("a", { href: "https://github.com/blaineam/haven/blob/main/docs/TERMS.md", target: "_blank",
              class: "small", style: "text-align:center;text-decoration:underline;color:var(--pink)" },
       t("read_full_terms")));
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
    } }, t("i_agree")));
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
      ? t("link_move_hint")
      : t("link_add_hint")),
    code,
    el("button", { class: "btn ghost small", style: "align-self:flex-start", onclick: () => { showLink = false; draw(); } }, t("back_arrow")),
    el("button", { class: "btn primary", style: "width:100%", onclick: async () => {
      const c = code.value.trim();
      if (!c) { toast(t("paste_link_code_first")); return; }
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
      catch (e) { toast(t("couldnt_link", e)); }
    } }, linkMode === "move" ? t("move_account_here") : t("add_this_device")));

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
    el("h1", { style: "font-size:34px;font-weight:800;margin:6px 0 0" }, t("welcome_haven")),
    el("p", { class: "muted", style: "margin:0;white-space:pre-line" },
      t("welcome_sub")),
    showLink ? linkBox()
             : el("div", { class: "col", style: "width:100%;gap:10px" },
                 choice(t("new_to_haven_t"),
                        t("new_to_haven_s"),
                        () => advance()),
                 choice(t("add_device_choice_t"),
                        t("add_device_choice_s"),
                        () => { showLink = true; linkMode = "add"; draw(); }),
                 choice(t("move_account_t"),
                        t("move_account_s"),
                        () => { showLink = true; linkMode = "move"; draw(); })));

  const pickName = () => {
    const field = el("input", { class: "pill-field", style: "text-align:center;font-size:18px", placeholder: t("name_nickname_ph"), value: name,
                                oninput: (e) => { name = e.target.value; next.disabled = !name.trim(); next.style.opacity = name.trim() ? 1 : 0.5; } });
    const picker = el("input", { type: "file", accept: "image/*", style: "display:none", onchange: async (e) => {
      const f = e.target.files[0];
      if (!f) return;
      try { avatar = await avatarDataUrl(f); draw(); }
      catch (_) { toast(t("not_an_image")); }
    } });
    const grid = el("div", { class: "emoji-grid" });
    for (const em of AVATAR_EMOJI) {
      grid.appendChild(el("button", { class: "emoji-cell" + (emoji === em ? " on" : ""), onclick: () => { emoji = em; draw(); } }, em));
    }
    return el("div", { class: "col", style: "align-items:center;gap:16px;text-align:center" },
      el("h2", { style: "font-size:26px;font-weight:800;margin:0;white-space:pre-line" }, t("what_call_you")),
      el("div", { class: "disc", style: "width:96px;height:96px;font-size:40px" },
         avatar ? el("img", { src: avatar }) : emoji),
      el("div", { class: "row", style: "justify-content:center;gap:8px" },
        el("button", { class: "btn small tint-pink", onclick: () => picker.click() }, avatar ? t("change_photo") : t("add_a_photo")),
        avatar ? el("button", { class: "btn small danger", onclick: () => { avatar = ""; draw(); } }, t("remove")) : null,
        picker),
      field,
      el("div", { class: "muted small" }, avatar ? t("emoji_if_remove_photo") : t("or_pick_emoji")),
      grid);
  };

  const howItWorks = () => {
    const point = (icon, title, body) => el("div", { class: "row", style: "align-items:flex-start;gap:14px;text-align:left" },
      el("div", { style: "font-size:30px;line-height:1" }, icon),
      el("div", { class: "col", style: "gap:3px" },
        el("div", { style: "font-weight:600" }, title),
        el("div", { class: "muted small" }, body)));
    return el("div", { class: "col", style: "gap:22px" },
      el("h2", { style: "font-size:26px;font-weight:800;margin:0;text-align:center" }, t("how_haven_works")),
      point("🔒", t("private_design_t"), t("private_design_b")),
      point("🚫", t("no_ads_t"), t("no_ads_b")),
      point("🤝", t("choose_circle_t"), t("choose_circle_b")));
  };

  const next = el("button", { class: "btn primary", style: "width:100%;padding:12px" });

  const advance = async () => {
    if (step < 3) { step += 1; draw(); return; }
    // Agreeing IS the door in — same as iOS. Record acceptance and the typed profile BEFORE
    // onboard_create, which restarts the process out from under us.
    Terms.accept();
    PendingProfile.stash({ name: name.trim(), emoji, avatar });
    try { await invoke("onboard_create"); }
    catch (e) { toast(t("couldnt_create", e)); }
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
    next.textContent = step === 3 ? t("i_agree_enter") : t("continue_btn");
    const needName = step === 1 && !name.trim();
    next.disabled = needName;
    next.style.opacity = needName ? 0.5 : 1;
    dots.innerHTML = "";
    for (let i = 0; i < 4; i++) dots.appendChild(el("div", { class: "dot" + (i === step ? " on" : "") }));
  }

  const card = el("div", { class: "col", style: "max-width:520px;width:100%;align-items:center;gap:14px" },
    body, next, dots,
    el("p", { class: "muted small", style: "margin-top:10px;text-align:center" },
      t("no_phone_email")));

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
    el("h1", { style: "font-size:26px;font-weight:800;margin:0" }, t("waiting_other_device")),
    el("p", { class: "muted", style: "margin:0" },
      t("seedless_hint")),
    el("button", { class: "btn ghost small", onclick: () => location.reload() }, t("check_again")));
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
    toast(t("backend_not_ready", e));
  }
  await Pins.load();   // adopt pins synced from the user's other devices before Messages renders
  await refreshStatus();
  await refreshBadges();
  await render();

  // First-run nudge to set a name — ONCE. This fired on every launch while the name was empty, so
  // an account that simply has no display name got dropped onto the profile tab every single time
  // instead of the feed it asked for.
  if (!state.profile.name && !localStorage.getItem("haven-named-nudged")) {
    localStorage.setItem("haven-named-nudged", "1");
    switchView("you");
  }

  try { state.contacts = await invoke("contacts"); } catch (_) {}
  try { state.videoSoundOn = await invoke("video_sound_on"); } catch (_) { state.videoSoundOn = false; }
  try {
    const pp = await invoke("privacy_prefs");
    state.superDataSaver = !!(pp && pp.super_data_saver);
  } catch (_) { state.superDataSaver = false; }
  // Coalesced, and never overlapping. `render()` starts with `invoke("feed")`, which re-opens EVERY
  // envelope in the circle — with a few hundred imported posts that is seconds of work, and the
  // engine emits this event from every sync pass, contact greet and media sweep. Firing a fresh
  // feed read on each one is why the window stalled every couple of seconds with nothing running.
  //
  // A trailing debounce collapses a burst into one read, and the in-flight flag stops a slow read
  // from being overtaken by the next — two concurrent decrypt passes over the same circle was the
  // worst case and the easiest to hit.
  let changePending = null, changeRunning = false;
  const onChanged = async () => {
    if (changeRunning) { changePending = changePending || setTimeout(fireChanged, 1200); return; }
    changeRunning = true;
    try { await applyChanged(); } finally { changeRunning = false; }
  };
  const fireChanged = () => { changePending = null; onChanged(); };
  listen("haven:changed", () => {
    if (changePending) return;                 // already scheduled — one read will cover both
    changePending = setTimeout(fireChanged, 400);
  });
  const applyChanged = async () => {
    // DURING AN IMPORT, refresh the feed and nothing else.
    //
    // The importer nudges roughly every two seconds so the feed visibly fills in. The full path
    // below re-renders the ENTIRE app — titlebar, tabs, the active view — behind four more
    // `invoke`s, and paying that ~180 times over a 372-item import is what made the window flash
    // and stutter for the whole run. None of those four can change because of an import: the posts
    // are mine, so no status, badge, pin or contact moves. The feed is the only thing that does.
    if (IG.status && IG.status.running) {
      if (state.view === "circle") await renderFeed();
      return; // any other view shows nothing an import changes; rebuilding it is pure flicker
    }
    await refreshStatus(); await refreshBadges();
    await Pins.load();   // a pin made on the phone lands via self-sync — reflect it live
    try { state.contacts = await invoke("contacts"); } catch (_) {}
    // Don't yank the profile editor out from under the user mid-type on a background sync — re-rendering
    // the "you" view rebuilds its inputs and discards what they're typing.
    const ae = document.activeElement;
    if (state.view === "you" && ae && (ae.tagName === "INPUT" || ae.tagName === "TEXTAREA") && $("#view-you").contains(ae)) return;
    await render();
  };
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
      toast(t("fabric_ready"));
    }
    if (!pending && window.__havenFabricRebindHinted && !window.__havenFabricRebindDone) {
      window.__havenFabricRebindDone = true;
      toast(t("fabric_connected"));
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
  listen("haven:enroll-request", (e) => { const p = e.payload || {}; toast(t("device_wants_link", p.name || t("new_device"))); });
  // Deep links (`haven://…` from the OS). The backend QUEUES them and pings us rather than putting the
  // URL in the event, because a link that launched Haven arrives long before this webview has a
  // listener — so we drain once at boot too, or a cold-start link is silently dropped.
  const drainDeepLinks = async () => {
    for (const url of await invoke("take_deep_links").catch(() => [])) {
      const kind = await routeDeepLink(url);
      if (kind === "invite") toast(t("invite_sent"));
      else if (!kind) toast(t("not_haven_link"));
    }
  };
  listen("haven:deep-link", drainDeepLinks);
  drainDeepLinks();
  // THE IMPORTER BORROWING THIS WEBVIEW'S ENCODER (see src-tauri/src/igencode.rs).
  //
  // The import thread has no codec — this process's only one is here — so it hands stills over to
  // be optimized and asks for a poster for each sealed clip. Both go through the SAME helpers the
  // composer uses, so imported media ends up indistinguishable from media posted by hand: the same
  // downscale, the same metadata-stripping re-encode, the same `thumb:`/`poster:` companions.
  //
  // Answering is mandatory. The import thread is blocked on a channel until this replies, and every
  // path below — refusal, decode failure, an exception — answers with `refs: null`, which tells it
  // to seal the raw archive bytes and carry on. Never leave the thread waiting on silence.
  listen("haven:ig-encode", async (e) => {
    const p = e.payload || {};
    const answer = (refs) => invoke("instagram_encoded", { job: p.job, refs: refs || null }).catch(() => {});
    try {
      if (p.kind === "image") {
        // STRING STRAIGHT TO THE WORKER. Decoding the base64 and building a File here was the last
        // per-item main-thread cost, proportional to the photo's size — which is exactly the hitch
        // felt as the importer moves between items. The worker does the decode now, so this thread
        // hands over a string and does nothing else.
        //
        // The size gate still runs first: base64 is 4 bytes per 3, so the source size is known
        // without decoding anything.
        const raw = p.dataBase64 || "";
        mediaQuiet = true;
        let b64 = null;
        try {
          if (mediaSourceAllowed(Math.floor(raw.length * 0.75), false, "import.jpg")) {
            b64 = await ImgWorker.runB64(raw, {
              maxDim: MEDIA_TARGETS.STILL_LONG_EDGE, quality: MEDIA_TARGETS.STILL_JPEG_QUALITY,
            }).catch(() => null);
            // Older WebView, or a decode the worker refused: fall back to the main-thread path
            // rather than importing the photo unoptimized.
            if (!b64) {
              const bin = atob(raw);
              const buf = new Uint8Array(bin.length);
              for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
              b64 = await sanitizeMediaFile(new File([buf], "import.jpg", { type: "image/jpeg" }), false);
            }
          }
        } finally { mediaQuiet = false; }
        if (!b64) return answer(null);                      // refused (oversize/unreadable) → raw
        const ref = await invoke("add_media", { circleId: p.circleId, dataBase64: b64, isVideo: false });
        const thumb = await mintThumb(b64, p.circleId);      // null when the photo is already tiny
        const preview = await mintPreview(b64, p.circleId);
        const out = [ref];
        if (thumb) out.push(`thumb:${ref}:${thumb}`);
        if (preview) out.push(`preview:${ref}:${preview}`);
        return answer(out);
      }
      if (p.kind === "video") {
        const bin = atob(p.dataBase64 || "");
        const buf = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
        const file = new File([buf], "import.mp4", { type: "video/mp4" });
        // ONLY RE-ENCODE WHAT IS ACTUALLY OVERSIZED.
        //
        // The re-encode plays the clip through a canvas in REAL TIME on the main thread — there is
        // no faster path in a WebView — so a 30-second reel is 30 seconds of sustained main-thread
        // work. Doing that to every clip is what made the window beachball for the length of an
        // import. And it is mostly wasted: an Instagram export is already Instagram's own re-encode
        // at ≤1080p, so the great majority of clips are within target before we touch them.
        //
        // Under target, answering null seals the original bytes and still mints a poster — the
        // fallback path was already built for the over-cap case. Over target, the work is real and
        // worth its cost.
        const probe = await videoTargetProbe(file);
        if (probe && !probe.oversized) return answer(null);
        mediaQuiet = true;
        let b64;
        try { b64 = await sanitizeMediaFile(file, true); } finally { mediaQuiet = false; }
        if (!b64) return answer(null);                      // too long/large or undecodable → raw
        const ref = await invoke("add_media", { circleId: p.circleId, dataBase64: b64, isVideo: true });
        // Poster from the OPTIMIZED clip, so the still matches the bytes members actually fetch.
        const still = await posterFromVideoRef(p.circleId, ref);
        if (!still) return answer([ref]);
        const pref = await invoke("add_media", { circleId: p.circleId, dataBase64: still, isVideo: false });
        return answer([ref, `poster:${ref}:${pref}`]);
      }
      if (p.kind === "poster") {
        const still = await posterFromVideoRef(p.circleId, p.ref);
        if (!still) return answer(null);
        const ref = await invoke("add_media", { circleId: p.circleId, dataBase64: still, isVideo: false });
        return answer([`poster:${p.ref}:${ref}`]);
      }
      answer(null);
    } catch (_) {
      answer(null);
    }
  });

  // Instagram archive import progress. The run lives in Rust and outlives every view, so the ONLY
  // thing the frontend does is reflect it: keep the floating pill current, and redraw the importer
  // sheet if that is what the user happens to be looking at.
  listen("haven:import", (e) => {
    const prevPhase = IG.status && IG.status.phase;
    IG.status = e.payload || null;
    renderImportPill(IG.status);
    if (!igSheetOpen()) return;
    // Progress ticks update the open sheet IN PLACE; only a phase change earns a rebuild.
    if (IG.status && IG.status.phase === "importing" && prevPhase === "importing"
        && igUpdateRunning(IG.status)) return;
    drawInstagramSheet();
  });
  // A resumed import (see igimport::resume_if_needed) starts before this webview exists, so the
  // first event can land with nobody listening — ask once at boot rather than showing nothing.
  invoke("instagram_status").then((s) => { IG.status = s; renderImportPill(s); }).catch(() => {});
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
          ? t("over_limit", isVideo ? t("video_word") : t("photo_word"), fmtMB(maxBytes))
          : t("couldnt_attach_file"));
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
