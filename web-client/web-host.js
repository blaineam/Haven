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

  /** A browser is only ever a linked device; app.js reads this to offer nothing else. */
  window.__HAVEN_HOST__ = { web: true };

  const listeners = new Map(); // event name → Set<fn>
  function emit(name, payload) {
    const set = listeners.get(name);
    if (!set) return;
    for (const fn of [...set]) {
      try { fn({ event: name, payload }); } catch (e) { console.error("haven listener failed:", e); }
    }
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
    // The relay that served this page is, by construction, one this device can reach.
    app.setRelays([location.origin]);
    if (!app.needsOnboarding()) await app.boot();
  })();
  ready.catch((e) => console.error("Haven failed to start:", e));

  /** Persist everything, then start over — what the desktop app does by relaunching. */
  async function relaunch() {
    if (storage) await storage.flush();
    location.reload();
  }

  /** Unlink this browser: nothing of Haven's is left in it. */
  async function eraseEverything() {
    if (storage) storage.stop();
    storage = null;
    await storageModule.eraseStorage();
  }

  const NOT_IN_A_BROWSER = "not available in a browser";

  /** Commands that belong to the application, not the engine. */
  const host = {
    needs_onboarding: () => app.needsOnboarding(),
    demo_mode: () => false,
    take_deep_links: () => [],
    ui_log: ({ line }) => { console.log("ui:", line); },
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

  // For the smokes and the console.
  window.__HAVEN_WEB__ = { ready, flush: () => (storage ? storage.flush() : undefined), mode: () => (storage ? storage.mode : null), app: () => app, haven: () => haven };
})();
