// Durable storage for the engine's files (identity, prefs, engine state, journals, media cache).
//
// The engine reads and writes an in-memory tree synchronously (`haven_client::fs`); this module is
// what makes that tree survive a reload. It loads every stored record into the tree before the
// engine boots, then writes the engine's changes through to IndexedDB — on a short timer, and when
// the page is hidden or closed. Every record is encrypted (AES-GCM, the record's path as
// associated data), under a key that depends on the MODE the person chose when linking:
//
//   "persist" — "this is my computer". One database, `haven`. The key is a NON-EXTRACTABLE
//               WebCrypto key kept in that database: script can use it but never read it. This
//               keeps the stored bytes from being copied out and read elsewhere by script or by a
//               tool that only sees the records; it does NOT protect against someone with access
//               to this browser profile on this machine, who can simply open the page.
//
//   "session" — "a shared or public computer" (the default). A database with a random name whose
//               key lives only in this tab's sessionStorage. When the tab is closed the key is
//               gone and what is left on disk is unreadable; the database itself is deleted the
//               next time Haven is opened in this browser (and when the person unlinks). A reload
//               keeps the session, because linking needs two of them; any other arrival at the
//               page with a leftover session discards it.
//
// What neither mode can do is protect a session while it is open on a machine that is itself
// compromised (a keylogger, a malicious extension). See docs/WEB-PARITY.md.

const PERSIST_DB = "haven";
const FILES = "files";
const KEYS = "keys";
const MODE_KEY = "haven.web.mode";          // localStorage: "persist" once chosen
const SESSION_KEY = "haven.web.session";    // sessionStorage: { db, key (base64) }
const REGISTRY_KEY = "haven.web.sessions";  // localStorage: names of session databases ever made

const b64 = (bytes) => btoa(String.fromCharCode(...bytes));
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

function open(name) {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(name, 1);
    req.onupgradeneeded = () => {
      req.result.createObjectStore(FILES);
      req.result.createObjectStore(KEYS);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function done(tx) {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error ?? new Error("storage transaction aborted"));
  });
}

const request = (req) => new Promise((resolve, reject) => { req.onsuccess = () => resolve(req.result); req.onerror = () => reject(req.error); });

function deleteDatabase(name) {
  return new Promise((resolve) => {
    const req = indexedDB.deleteDatabase(name);
    req.onsuccess = req.onerror = req.onblocked = () => resolve();
  });
}

const registry = {
  read() { try { return JSON.parse(localStorage.getItem(REGISTRY_KEY) || "[]"); } catch { return []; } },
  write(names) { localStorage.setItem(REGISTRY_KEY, JSON.stringify(names)); },
  add(name) { const n = this.read(); if (!n.includes(name)) { n.push(name); this.write(n); } },
};

function readSession() {
  try {
    const s = JSON.parse(sessionStorage.getItem(SESSION_KEY) || "null");
    return s && typeof s.db === "string" && typeof s.key === "string" ? s : null;
  } catch { return null; }
}

/** Did this page load come from a reload (ours after linking, or the person's)? */
function arrivedByReload() {
  const nav = performance.getEntriesByType?.("navigation")?.[0];
  return nav ? nav.type === "reload" : false;
}

/**
 * Which storage this visit continues, if any: "persist", "session", or null (nothing stored —
 * the person has not linked this browser yet). Also the housekeeping every visit does: a session
 * left behind by a closed tab is discarded, and so is one this tab did not arrive at by reload.
 */
export async function resumeMode() {
  let session = readSession();
  if (session && !arrivedByReload()) {
    sessionStorage.removeItem(SESSION_KEY);
    session = null;
  }
  // Delete every session database that is not this tab's live one. Their keys are already gone.
  const keep = session ? session.db : null;
  const names = registry.read();
  for (const name of names) if (name !== keep) await deleteDatabase(name);
  registry.write(names.filter((n) => n === keep));

  if (session) return "session";
  return localStorage.getItem(MODE_KEY) === "persist" ? "persist" : null;
}

/** The database and key for a mode, creating them on first use. */
async function openMode(mode) {
  if (mode === "persist") {
    const db = await open(PERSIST_DB);
    let key = await request(db.transaction(KEYS, "readonly").objectStore(KEYS).get("k1"));
    if (!key) {
      key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false /* not extractable */, ["encrypt", "decrypt"]);
      const tx = db.transaction(KEYS, "readwrite");
      tx.objectStore(KEYS).put(key, "k1");
      await done(tx);
    }
    localStorage.setItem(MODE_KEY, "persist");
    return { db, key };
  }
  let session = readSession();
  if (!session) {
    const name = "haven-session-" + b64(crypto.getRandomValues(new Uint8Array(12))).replace(/[^A-Za-z0-9]/g, "");
    session = { db: name, key: b64(crypto.getRandomValues(new Uint8Array(32))) };
    registry.add(name);
    sessionStorage.setItem(SESSION_KEY, JSON.stringify(session));
  }
  const key = await crypto.subtle.importKey("raw", unb64(session.key), "AES-GCM", false, ["encrypt", "decrypt"]);
  return { db: await open(session.db), key };
}

const aad = (path) => new TextEncoder().encode(path);

/**
 * Attach durable storage to a loaded wasm module (`haven`) in `mode` ("persist" | "session"):
 * preload what is stored, then keep persisting. Returns `{ mode, flush, stop }`; `await flush()`
 * before anything that must not lose a write (a reload after linking).
 */
export async function attachStorage(haven, { mode, intervalMs = 400 } = {}) {
  if (mode !== "persist" && mode !== "session") throw new Error("attachStorage: mode must be 'persist' or 'session'");
  const { db, key } = await openMode(mode);

  // Preload: decrypt every record into the engine's tree. A record that does not open (a
  // different key, a damaged write) is skipped — it cannot be turned into anything else.
  const records = await new Promise((resolve, reject) => {
    const out = [];
    const req = db.transaction(FILES, "readonly").objectStore(FILES).openCursor();
    req.onerror = () => reject(req.error);
    req.onsuccess = () => {
      const cursor = req.result;
      if (!cursor) return resolve(out);
      out.push([cursor.key, cursor.value]);
      cursor.continue();
    };
  });
  for (const [path, rec] of records) {
    try {
      const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: rec.iv, additionalData: aad(path) }, key, rec.data);
      haven.storagePreload(path, new Uint8Array(plain), rec.modified);
    } catch (e) {
      console.error(`haven storage: ${path} did not open and was skipped`);
    }
  }

  // Write-behind. One flush at a time; a flush that fails keeps its changes for the next attempt.
  let pending = [];
  let running = Promise.resolve();
  function flush() {
    running = running.then(async () => {
      pending.push(...haven.storageTakeChanges());
      if (pending.length === 0) return;
      const batch = pending;
      pending = [];
      try {
        // Encrypt first (async), then write in one transaction (which must not span an await).
        const now = Date.now();
        const sealed = [];
        for (const [path, data] of batch) {
          if (data === null) { sealed.push([path, null]); continue; }
          const iv = crypto.getRandomValues(new Uint8Array(12));
          const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: aad(path) }, key, data);
          sealed.push([path, { iv, data: ct, modified: now }]);
        }
        const tx = db.transaction(FILES, "readwrite");
        const store = tx.objectStore(FILES);
        for (const [path, rec] of sealed) {
          if (rec === null) store.delete(path);
          else store.put(rec, path);
        }
        await done(tx);
      } catch (e) {
        pending = batch.concat(pending);
        throw e;
      }
    });
    return running.catch((e) => console.error("haven storage flush failed:", e));
  }

  const timer = setInterval(flush, intervalMs);
  const onHide = () => { if (document.visibilityState === "hidden") flush(); };
  document.addEventListener("visibilitychange", onHide);
  addEventListener("pagehide", flush);

  return {
    mode,
    flush,
    stop() {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", onHide);
      removeEventListener("pagehide", flush);
      db.close();
    },
  };
}

/** Erase everything this browser has stored for Haven, in every mode (unlink this browser). */
export async function eraseStorage() {
  const session = readSession();
  sessionStorage.removeItem(SESSION_KEY);
  localStorage.removeItem(MODE_KEY);
  const names = new Set(registry.read());
  if (session) names.add(session.db);
  for (const name of names) await deleteDatabase(name);
  registry.write([]);
  await deleteDatabase(PERSIST_DB);
}
