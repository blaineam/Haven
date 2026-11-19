// Durable storage for the engine's files (identity, prefs, engine state, journals, media cache).
//
// The engine reads and writes an in-memory tree synchronously (`haven_client::fs`); this module is
// what makes that tree survive a reload. It loads every stored record into the tree before the
// engine boots, then writes the engine's changes through to IndexedDB — on a short timer, and when
// the page is hidden or closed.
//
// One object store, keyed by path: { data: Uint8Array, modified: ms }.

const DB_NAME = "haven";
const STORE = "files";

function open() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
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

/**
 * Attach durable storage to a loaded wasm module (`haven`): preload what is stored, then keep
 * persisting. Returns `{ flush, stop }`; `await flush()` before anything that must not lose a
 * write (a reload after linking).
 */
export async function attachStorage(haven, { intervalMs = 400 } = {}) {
  const db = await open();

  // Preload.
  await new Promise((resolve, reject) => {
    const req = db.transaction(STORE, "readonly").objectStore(STORE).openCursor();
    req.onerror = () => reject(req.error);
    req.onsuccess = () => {
      const cursor = req.result;
      if (!cursor) return resolve();
      haven.storagePreload(cursor.key, cursor.value.data, cursor.value.modified);
      cursor.continue();
    };
  });

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
        const tx = db.transaction(STORE, "readwrite");
        const store = tx.objectStore(STORE);
        const now = Date.now();
        for (const [path, data] of batch) {
          if (data === null) store.delete(path);
          else store.put({ data, modified: now }, path);
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
    flush,
    stop() {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", onHide);
      removeEventListener("pagehide", flush);
    },
  };
}

/** Erase everything this origin has stored for Haven (unlink this browser). */
export async function eraseStorage() {
  const db = await open();
  const tx = db.transaction(STORE, "readwrite");
  tx.objectStore(STORE).clear();
  await done(tx);
  db.close();
}
