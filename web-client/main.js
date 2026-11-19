// Entry point of the Haven web client. Served by a circle's relay under /app/ — the relay that
// served this page is, by construction, a relay this device can reach, so it is the node's first
// relay and (same-origin) its mailbox.
//
// No inline script anywhere: the relay sends a Content-Security-Policy that allows only this
// origin's own script and WebAssembly.
import init, * as haven from "./pkg/haven_web.js";
import { attachStorage, eraseStorage } from "./storage.js";

await init();

/** The relay front door this page came from (the path proxy's origin). */
const origin = location.origin;

/**
 * Load storage and create the app. `onEvent(name, payload)` receives the engine's UI events.
 * Returns `{ app, storage, needsOnboarding }`; call `app.boot()` (after `app.onboardLink(ticket)`
 * on a browser that holds no identity yet).
 */
export async function start(onEvent = () => {}) {
  const storage = await attachStorage(haven);
  const app = new haven.WebApp((name, json) => onEvent(name, JSON.parse(json)));
  app.setRelays([origin]);
  return { app, storage, needsOnboarding: app.needsOnboarding() };
}

// The UI is not built yet; until it is, the pieces are reachable for the smokes and the console.
window.haven = haven;
window.havenStart = start;
window.havenErase = eraseStorage;
window.havenReady = true;
