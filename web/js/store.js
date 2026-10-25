// Small saved-data helpers. Everything stays in this browser on this computer; nothing is sent anywhere.
// Big things (imported trails) go in IndexedDB; small settings in localStorage.

const DB_NAME = "trail-tracker";
let dbPromise = null;

function db() {
  if (!dbPromise) {
    dbPromise = new Promise((resolve, reject) => {
      const req = indexedDB.open(DB_NAME, 1);
      req.onupgradeneeded = () => req.result.createObjectStore("kv");
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }
  return dbPromise;
}

export async function dbGet(key) {
  const d = await db();
  return new Promise((resolve, reject) => {
    const req = d.transaction("kv").objectStore("kv").get(key);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export async function dbSet(key, value) {
  const d = await db();
  return new Promise((resolve, reject) => {
    const tx = d.transaction("kv", "readwrite");
    if (value === undefined) tx.objectStore("kv").delete(key); else tx.objectStore("kv").put(value, key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

export function load(key, fallback) {
  try {
    const v = localStorage.getItem("tt." + key);
    return v == null ? fallback : JSON.parse(v);
  } catch (e) {
    return fallback;
  }
}

export function save(key, value) {
  try { localStorage.setItem("tt." + key, JSON.stringify(value)); } catch (e) { /* storage full or blocked */ }
}
