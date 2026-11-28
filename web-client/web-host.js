// The browser's stand-in for the desktop app's host (Tauri). The UI in app.js is the desktop
// frontend, unchanged; it talks to `window.__TAURI__`, and in a browser this file is that object:
// commands go to the engine compiled to WebAssembly (the same engine, the same command code),
// engine events come back through `listen`, and the handful of commands that belong to an
// application rather than the engine are answered here.
//
// A classic script, loaded before app.js, so the host object exists synchronously; everything
// asynchronous (loading the wasm, restoring storage, booting the engine) hides behind `ready`.
//
// No inline script anywhere: the relay serves this with a CSP that allows only this origin's own
// script and WebAssembly.
(function () {
  "use strict";

  // Who served this page. A circle's relay serves it under its own address, and then that relay
  // is, by construction, one this browser can reach. An ordinary web site can serve the very same
  // files (web-client/build.sh writes that variant to dist-site/, marked with the meta tag read
  // here); such a page starts out knowing no relay at all. It is reached for linking through a
  // rendezvous relay, the public ones the apps also fall back to unless the site names its own,
  // and learns the circle's relays from the account once it is linked.
  const meta = (name) => (document.querySelector(`meta[name="${name}"]`) || {}).content || "";
  const SITE_HOSTED = meta("haven-host") === "site";
  const RENDEZVOUS = meta("haven-rendezvous").split(",").map((u) => u.trim().replace(/\/+$/, "")).filter((u) => /^https?:\/\//.test(u));

  /** A browser is only ever a linked device; app.js reads this to offer nothing else. `site` is
   *  the host that served the page when that was not a relay — the page says so where it asks to
   *  be trusted. */
  window.__HAVEN_HOST__ = { web: true, site: SITE_HOSTED ? location.host : "" };

  // Safari refuses a secure connection to a host written as a fully qualified name with its
  // trailing dot ("relay.example.com."): "The server did not accept the certificate". The public
  // relays are named that way, and the engine learns such names from more places than its own
  // list (another device's published address, for one), so a page in Safari showed a code and
  // then could not reach the phone that answered it. Chromium and Firefox do not mind. Every
  // connection the page opens goes through WebSocket or fetch, so the dot is dropped here, in
  // the one place none can get past. The dotless name is the same server.
  const undot = (url) => {
    try {
      const u = new URL(url, location.href);
      if (!u.hostname.endsWith(".") || u.hostname.length < 2) return url;
      u.hostname = u.hostname.slice(0, -1);
      return u.href;
    } catch (_) { return url; }
  };
  window.__HAVEN_UNDOT__ = undot;   // for the tests
  const NativeWebSocket = window.WebSocket;
  if (NativeWebSocket) {
    const Patched = function WebSocket(url, protocols) {
      return protocols === undefined ? new NativeWebSocket(undot(String(url))) : new NativeWebSocket(undot(String(url)), protocols);
    };
    Patched.prototype = NativeWebSocket.prototype;
    for (const k of ["CONNECTING", "OPEN", "CLOSING", "CLOSED"]) Patched[k] = NativeWebSocket[k];
    window.WebSocket = Patched;
  }
  const nativeFetch = window.fetch.bind(window);
  window.fetch = (input, init) => {
    if (typeof input === "string" || input instanceof URL) return nativeFetch(undot(String(input)), init);
    if (input instanceof Request) {
      const fixed = undot(input.url);
      if (fixed !== input.url) return nativeFetch(new Request(fixed, input), init);
    }
    return nativeFetch(input, init);
  };

  const listeners = new Map(); // event name → Set<fn>
  function emit(name, payload) {
    const set = listeners.get(name);
    if (!set) return;
    for (const fn of [...set]) {
      try { fn({ event: name, payload }); } catch (e) { console.error("haven listener failed:", e); }
    }
  }

  /** "Firefox on Windows" — from the user agent, best effort; only ever a label. */
  function describeBrowser() {
    const ua = navigator.userAgent || "";
    const browser = /Edg\//.test(ua) ? "Edge" : /OPR\//.test(ua) ? "Opera" : /Firefox\//.test(ua) ? "Firefox"
      : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "Browser";
    const os = /Windows/.test(ua) ? "Windows" : /Android/.test(ua) ? "Android" : /iPhone|iPad|iPod/.test(ua) ? "iOS"
      : /Mac OS X/.test(ua) ? "Mac" : /CrOS/.test(ua) ? "ChromeOS" : /Linux/.test(ua) ? "Linux" : "";
    return os ? `${browser} on ${os}` : browser;
  }

  let haven, app, storage, storageModule;
  const ready = (async () => {
    haven = await import("./pkg/haven_web.js");
    await haven.default();
    // A harness driving throwaway identities asks, before any script runs, that this page never
    // call the push worker.
    if (window.__HAVEN_HARNESS__ && window.__HAVEN_HARNESS__.pushOff) haven.setPushOff(true);
    if (window.__HAVEN_HARNESS__ && window.__HAVEN_HARNESS__.log) haven.setLogLevel(window.__HAVEN_HARNESS__.log);
    storageModule = await import("./storage.js");
    // Continue whatever this browser already has ("my computer", or this tab's own session);
    // a browser that has not linked yet stores nothing until the person chooses, when linking.
    const mode = await storageModule.resumeMode();
    if (mode) storage = await storageModule.attachStorage(haven, { mode });
    app = new haven.WebApp((name, json) => emit(name, JSON.parse(json)));
    // The relay that served this page is, by construction, one this device can reach. A page
    // from a web site has none of its own: only the rendezvous relays its host named, if any.
    app.setRelays(SITE_HOSTED ? RENDEZVOUS : [location.origin]);
    // What the person approving this browser will read on their other device.
    app.setDeviceLabel(describeBrowser());
    if (!app.needsOnboarding()) {
      await app.boot();
      pushRenew();   // not awaited: the page does not wait on the push worker
    }
  })();
  ready.catch((e) => console.error("Haven failed to start:", e));

  /** Persist everything, then start over — what the desktop app does by relaunching. */
  async function relaunch() {
    if (storage) await storage.flush();
    location.reload();
  }

  /** Unlink this browser: nothing of Haven's is left in it. */
  async function eraseEverything() {
    forgetPlayable();
    await pushDisable().catch(() => {});   // an unlinked browser must not go on being rung
    if (storage) storage.stop();
    storage = null;
    await storageModule.eraseStorage();
  }

  // ── Web Push: a notification when no Haven tab is open ─────────────────────────────────────
  // Off unless the person turns it on, and only in a browser they chose to stay linked in: a
  // borrowed computer must not keep ringing for them after the tab is closed. What arrives is a
  // doorbell with no content (push/worker.js); `sw.js` turns it into "something is waiting".
  const engineCall = async (name, args = {}) => JSON.parse(await app.invoke(name, JSON.stringify(args)));
  const pushSupported = () => window.isSecureContext && "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
  const pushRegistration = () => navigator.serviceWorker.getRegistration("./");
  async function pushSubscription() {
    const reg = pushSupported() ? await pushRegistration() : null;
    return reg ? reg.pushManager.getSubscription() : null;
  }
  function keyBytes(b64url) {
    const bin = atob(b64url.replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(bin, (c) => c.charCodeAt(0));
  }
  const sameKey = (a, b) => !!a && a.byteLength === b.length && new Uint8Array(a).every((v, i) => v === b[i]);

  /** Where this browser stands: { supported, kept, permission, enabled }. */
  async function pushStatus() {
    const kept = !!storage && storage.mode === "persist";
    if (!pushSupported()) return { supported: false, kept, permission: "unsupported", enabled: false };
    return { supported: true, kept, permission: Notification.permission, enabled: !!(await pushSubscription()) };
  }

  async function pushEnable() {
    if (!pushSupported()) throw "unsupported";
    if (!storage || storage.mode !== "persist") throw "session";
    const key = await engineCall("web_push_key");
    if (!key) throw "unavailable";
    if ((await Notification.requestPermission()) !== "granted") throw "blocked";
    const reg = await navigator.serviceWorker.register("sw.js", { scope: "./" });
    await navigator.serviceWorker.ready;
    const want = keyBytes(key);
    let sub = await reg.pushManager.getSubscription();
    // A subscription made for another key (the worker's key changed) cannot be rung: replace it.
    if (sub && !sameKey(sub.options.applicationServerKey, want)) { await sub.unsubscribe(); sub = null; }
    if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: want });
    try {
      await engineCall("web_push_register", { endpoint: sub.endpoint });
    } catch (e) {
      await sub.unsubscribe().catch(() => {});   // never leave a subscription nobody will ring
      throw e;
    }
  }

  /** Stop: the push service forgets this browser, and the worker drops the endpoint the next time
   *  it tries it. Nothing of the service worker is left behind. */
  async function pushDisable() {
    if (!pushSupported()) return;
    const reg = await pushRegistration();
    if (!reg) return;
    const sub = await reg.pushManager.getSubscription();
    if (sub) await sub.unsubscribe().catch(() => {});
    await reg.unregister().catch(() => {});
  }

  /** On every visit: a registration lapses after about thirty days, and the push service may have
   *  replaced the endpoint. Quiet — a failure here is retried on the next visit. */
  async function pushRenew() {
    try {
      const sub = await pushSubscription();
      if (!sub) return;
      if (!storage || storage.mode !== "persist") return pushDisable();
      await engineCall("web_push_register", { endpoint: sub.endpoint });
    } catch (_) { /* next visit */ }
  }

  // ── Video and voice notes ──────────────────────────────────────────────────────────────────
  // The engine hands the page media as a `data:` URL. This page's security policy lets a picture
  // be one and a video or sound not (and Safari plays a long `data:` video badly even where it is
  // allowed), so those are handed over as `blob:` URLs here instead, made once per blob.
  const PLAYABLE = /^(vid_|v:|aud_|a:)/;
  const PLAYABLE_BUDGET_BYTES = 192 * 1024 * 1024;
  const playable = new Map(); // reference → { url, bytes }, oldest use first

  /** The container the bytes really are: clips composed on a computer are WebM under a `vid_` name. */
  function playableType(bytes, reference) {
    const video = /^(vid_|v:)/.test(reference);
    const at = (i, text) => [...text].every((c, j) => bytes[i + j] === c.charCodeAt(0));
    if (bytes[0] === 0x1a && bytes[1] === 0x45 && bytes[2] === 0xdf && bytes[3] === 0xa3) return video ? "video/webm" : "audio/webm";
    if (at(4, "ftyp")) return video ? "video/mp4" : "audio/mp4";
    if (at(0, "OggS")) return video ? "video/ogg" : "audio/ogg";
    if (at(0, "RIFF")) return "audio/wav";
    if (at(0, "ID3") || (bytes[0] === 0xff && (bytes[1] & 0xe0) === 0xe0)) return "audio/mpeg";
    return video ? "video/mp4" : "audio/mp4";
  }

  const urlInUse = (url) => [...document.querySelectorAll("video, audio, source")].some((m) => m.getAttribute("src") === url);

  function playableUrl(circleId, reference) {
    let hit = playable.get(reference);
    if (hit) { playable.delete(reference); playable.set(reference, hit); return hit.url; }
    const bytes = app.mediaBytes(circleId || "default", reference);
    if (!bytes) return null;
    hit = { url: URL.createObjectURL(new Blob([bytes], { type: playableType(bytes, reference) })), bytes: bytes.length };
    playable.set(reference, hit);
    // Keep the tab small: drop the longest-unused ones that nothing on the page is playing.
    let total = [...playable.values()].reduce((n, e) => n + e.bytes, 0);
    for (const [ref, e] of playable) {
      if (total <= PLAYABLE_BUDGET_BYTES) break;
      if (ref === reference || urlInUse(e.url)) continue;
      URL.revokeObjectURL(e.url);
      playable.delete(ref);
      total -= e.bytes;
    }
    return hit.url;
  }

  function forgetPlayable() {
    for (const e of playable.values()) URL.revokeObjectURL(e.url);
    playable.clear();
  }

  // ── Songs ──────────────────────────────────────────────────────────────────────────────────
  // A post names its song, never a clip of it. The desktop app looks the 30-second preview up in
  // Apple's public iTunes Search API (src-tauri songsuggest.rs); so does this page. Same request,
  // same answer shape; no cookies and no referrer go with it.
  async function itunes(path) {
    const res = await fetch(`https://itunes.apple.com/${path}`, { credentials: "omit", referrerPolicy: "no-referrer" });
    if (!res.ok) return [];
    const body = await res.json();
    return (body.results || []).filter((t) => t.previewUrl).map((t) => ({
      catalog_id: t.trackViewUrl || "",
      title: t.trackName || "",
      artist: t.artistName || "",
      artwork_url: String(t.artworkUrl100 || "").replace("100x100", "300x300"),
      duration_ms: t.trackTimeMillis || 0,
      preview_url: t.previewUrl,
      explicit: t.trackExplicitness === "explicit",
    }));
  }
  const songSearch = (q, limit) => itunes(`search?term=${encodeURIComponent(q)}&media=music&entity=song&limit=${limit}`);
  /** `commands::itunes_track_id`: the track number in an Apple music link. */
  function trackId(url) {
    if (!/music\.apple\.com|itunes\.apple\.com/.test(url || "")) return null;
    return (/[?&]i=(\d+)/.exec(url) || /\/id(\d+)[^/]*$/.exec(url) || [])[1] || null;
  }

  const NOT_IN_A_BROWSER = "not available in a browser";

  /** Commands that belong to the application, not the engine. */
  const host = {
    needs_onboarding: () => app.needsOnboarding(),
    demo_mode: () => false,
    take_deep_links: () => [],
    ui_log: ({ line }) => { console.log("ui:", line); },
    music_resolve: async ({ title, artist, catalogId }) => {
      try {
        // By number first, when the post's song carries its link: a text search can miss.
        const id = trackId(catalogId);
        const byId = id ? (await itunes(`lookup?id=${id}&entity=song`))[0] : null;
        return byId || (await songSearch(`${title || ""} ${artist || ""}`.trim(), 1))[0] || null;
      } catch (_) { return null; }
    },
    music_search: async ({ query, limit }) => {
      const q = String(query || "").trim();
      if (!q) return [];
      try { return (await songSearch(q, limit || 25)).filter((t) => !t.explicit); } catch (_) { return []; }
    },
    self_test: () => JSON.parse(haven.engineSelfTestReport()),
    // Linking: persist the ticket, then restart into the linking engine (it sends the request).
    // `remember` is the person's answer to "is this your computer?" — it decides, before the
    // first byte is written, whether this browser keeps the link or forgets it with the tab.
    onboard_link_seedless: async ({ ticket, remember }) => {
      if (!storage) storage = await storageModule.attachStorage(haven, { mode: remember ? "persist" : "session" });
      app.onboardLink(ticket);
      await relaunch();
    },
    // The grant landed: restart into the linked engine.
    finish_enroll: () => relaunch(),
    // Scan-to-link: show a code for a device that already has the account to scan. Nothing is
    // stored while it shows; the device key lives in memory until a device answers.
    // A page from a web site names its rendezvous relay instead (empty: whichever public one the
    // node settles on).
    pair_begin: () => app.pairBegin(SITE_HOSTED ? (RENDEZVOUS[0] || "") : location.origin),
    // A device answered (`haven:pair-offer`): NOW the person's "is this your computer?" answer
    // picks the storage, the linking state is written, and the page restarts into the linking
    // engine — the same end as pasting a ticket.
    pair_finish: async ({ remember }) => {
      if (!storage) storage = await storageModule.attachStorage(haven, { mode: remember ? "persist" : "session" });
      await app.pairFinish();
      await relaunch();
    },
    pair_stop: () => app.pairStop(),
    // Something too large to hold in a tab (app.js `WEB_SAVE_ONLY_BYTES`): fetch it once, give it
    // to the browser as a file, and let go of it. The relay cannot decrypt it, so the page must;
    // what the page must not do is keep it, or turn it into a player.
    media_save_to_disk: async ({ circleId, reference, video }) => {
      await engineCall("media_download", { reference });   // the person asked: the engine may fetch it
      const until = Date.now() + 20 * 60 * 1000;
      while (!(await engineCall("media_present", { reference }))) {
        if (Date.now() > until) throw "unavailable";
        await new Promise((r) => setTimeout(r, 2000));
      }
      try {
        const bytes = app.mediaBytes(circleId || "", reference);
        if (!bytes) throw "unavailable";
        const url = URL.createObjectURL(new Blob([bytes], { type: video ? "video/mp4" : "application/octet-stream" }));
        const a = document.createElement("a");
        a.href = url;
        a.download = `haven-${String(reference).replace(/[^A-Za-z0-9_-]/g, "").slice(-16)}${video ? ".mp4" : ""}`;
        a.rel = "noopener";
        document.body.append(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(url), 120000);
      } finally {
        // Back to a placeholder: nothing this size stays in the tab or in its storage.
        await engineCall("media_delete_selected", { refs: [reference] });
      }
    },
    // Notifications while no tab is open (Web Push). `web_push_set` rejects with one of
    // "unsupported" | "session" | "unavailable" | "blocked", or the worker's own refusal.
    web_push_status: () => pushStatus(),
    web_push_set: async ({ on }) => { await (on ? pushEnable() : pushDisable()); return pushStatus(); },
    // A browser never holds an account seed, so it can neither create nor adopt an account.
    onboard_create: () => { throw NOT_IN_A_BROWSER; },
    onboard_link: () => { throw NOT_IN_A_BROWSER; },
    switch_identity: () => { throw NOT_IN_A_BROWSER; },
    autostart_status: () => ({ login_item: false, host_on_launch: false }),
    set_autostart: () => { throw NOT_IN_A_BROWSER; },
  };

  async function invoke(cmd, args = {}) {
    await ready;
    if (cmd === "engine_invoke") {
      if (args.name === "media_data_url" && PLAYABLE.test(String(args.args?.reference || ""))) {
        return playableUrl(args.args.circleId, args.args.reference);
      }
      // Rejects with the string "unknown-command" for a name the engine does not have — the same
      // contract as the desktop host — and app.js then asks for it by its own name.
      const out = JSON.parse(await app.invoke(args.name, JSON.stringify(args.args ?? {})));
      // "Start over" must leave nothing behind in the browser either. (app.js reloads next.)
      if (args.name === "reset") await eraseEverything();
      return out;
    }
    const fn = host[cmd];
    if (!fn) throw `${cmd}: ${NOT_IN_A_BROWSER}`;
    return fn(args ?? {});
  }

  async function listen(name, fn) {
    if (!listeners.has(name)) listeners.set(name, new Set());
    listeners.get(name).add(fn);
    return () => listeners.get(name)?.delete(fn);
  }

  window.__TAURI__ = {
    core: { invoke },
    event: { listen },
    opener: { openUrl: (url) => { window.open(url, "_blank", "noopener,noreferrer"); } },
    app: { getVersion: async () => (await ready, haven.version()) },
  };

  // For the smokes and the console. `emit` hands the page one of its own UI events (the QA
  // channel the desktop app's test driver uses, e.g. `haven:qa-ui`) — only for a harness that
  // announced itself before any script ran.
  window.__HAVEN_WEB__ = { ready, flush: () => (storage ? storage.flush() : undefined), mode: () => (storage ? storage.mode : null), app: () => app, haven: () => haven };
  if (window.__HAVEN_HARNESS__) window.__HAVEN_WEB__.emit = emit;
})();
