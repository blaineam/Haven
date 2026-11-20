// Haven's service worker: it exists for ONE thing — to show a notification when a push arrives
// while no Haven page is in front of the person.
//
// It has no `fetch` handler on purpose. It never serves, caches or rewrites a single request: the
// page always loads exactly what the relay serves now, and nothing of Haven's is kept here.
//
// A push carries NO content (push/worker.js sends an empty body), so there is nothing to decrypt
// and nothing to leak: the notification says only that something is waiting. Opening it loads the
// page, which fetches and decrypts through the circle's relay as it always does.
const WAITING = {
  en: "Something new is waiting for you.",
  ja: "新しいお知らせがあります。",
  de: "Etwas Neues wartet auf dich.",
  es: "Hay algo nuevo esperándote.",
  ko: "새로운 소식이 기다리고 있습니다.",
  pt: "Há algo novo esperando por você.",
  it: "C'è qualcosa di nuovo che ti aspetta.",
};

function waitingText(language) {
  const lang = String(language || "en").toLowerCase().split("-")[0];
  return WAITING[lang] || WAITING.en;
}

/** Is a Haven page already in front of the person? Then the page tells them itself. */
async function pageIsVisible() {
  const pages = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
  return pages.some((p) => p.visibilityState === "visible");
}

async function onPush() {
  if (await pageIsVisible()) return;
  // One notification, replaced in place: ten pushes are still one line, not ten.
  await self.registration.showNotification("Haven", {
    body: waitingText(self.navigator && self.navigator.language),
    tag: "haven",
    icon: "palette-icons/neutral.png",
  });
}

async function onClick() {
  const pages = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
  const open = pages.find((p) => p.url.startsWith(self.registration.scope));
  if (open) return open.focus();
  return self.clients.openWindow(self.registration.scope);
}

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("push", (e) => e.waitUntil(onPush()));
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  e.waitUntil(onClick());
});
