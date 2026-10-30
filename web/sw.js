// Service worker: keeps the app itself and the saved map tiles available with no internet.
// - App files: served from the cache, refreshed in the background when online.
// - Map tiles (tiles/<source>/<z>/<x>/<y>): served from the tile cache. When a tile isn't saved and
//   "Use internet for maps" is on, it's fetched from USGS and saved. When it can't be had, a saved
//   lower-zoom tile is enlarged instead, so zooming in past the downloaded detail still shows a map.

const VERSION = "v1";
const APP_CACHE = "app-" + VERSION;
const TILE_CACHE = "tiles-v1";
const APP_FILES = [
  "./", "index.html", "app.css", "manifest.webmanifest", "icon.svg", "icon-192.png", "icon-512.png",
  "js/app.js", "js/aprs.js", "js/trails.js", "js/tiles.js", "js/nav.js", "js/radio.js", "js/store.js",
  "vendor/leaflet/leaflet.js", "vendor/leaflet/leaflet.css",
];
const SOURCES = {
  "usgs-topo": "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}",
  "usgs-imagery": "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryTopo/MapServer/tile/{z}/{y}/{x}",
};

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(APP_CACHE).then((c) => c.addAll(APP_FILES)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    for (const k of await caches.keys()) if (k.startsWith("app-") && k !== APP_CACHE) await caches.delete(k);
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.origin !== self.location.origin) return;
  const scope = new URL(self.registration.scope);
  const path = url.pathname.slice(scope.pathname.length);
  const m = /^tiles\/([\w-]+)\/(\d+)\/(\d+)\/(\d+)$/.exec(path);
  if (m) event.respondWith(tile(m[1], +m[2], +m[3], +m[4], url.searchParams.get("net") === "1"));
  else event.respondWith(appFile(event.request));
});

async function appFile(request) {
  const cache = await caches.open(APP_CACHE);
  const cached = await cache.match(request, { ignoreSearch: true });
  const fresh = fetch(request).then((res) => {
    if (res.ok) cache.put(request, res.clone());
    return res;
  }).catch(() => null);
  if (cached) return cached;
  return (await fresh) || new Response("Offline", { status: 503 });
}

const tileKey = (s, z, x, y) => new URL(`tiles/${s}/${z}/${x}/${y}`, self.registration.scope).href;

async function tile(source, z, x, y, useNet) {
  if (!SOURCES[source]) return new Response("", { status: 404 });
  const cache = await caches.open(TILE_CACHE);
  const key = tileKey(source, z, x, y);
  const hit = await cache.match(key);
  if (hit) return hit;
  if (useNet) {
    try {
      const res = await fetch(SOURCES[source].replace("{z}", z).replace("{x}", x).replace("{y}", y), { mode: "cors", credentials: "omit" });
      if (res.ok) {
        cache.put(key, res.clone()).catch(() => {});
        return res;
      }
    } catch (e) { /* offline: fall through to an enlarged saved tile */ }
  }
  return (await enlarged(cache, source, z, x, y)) || new Response("", { status: 404 });
}

/** Cuts the matching quarter (or smaller piece) out of a saved lower-zoom tile and scales it up. */
async function enlarged(cache, source, z, x, y) {
  if (typeof OffscreenCanvas === "undefined") return null;
  for (let up = 1; up <= 6 && z - up >= 0; up++) {
    const pz = z - up, px = x >> up, py = y >> up;
    const parent = await cache.match(tileKey(source, pz, px, py));
    if (!parent) continue;
    try {
      const img = await createImageBitmap(await parent.blob());
      const n = 1 << up, size = img.width / n;
      const sx = (x - (px << up)) * size, sy = (y - (py << up)) * size;
      const canvas = new OffscreenCanvas(256, 256);
      const ctx = canvas.getContext("2d");
      ctx.imageSmoothingQuality = "high";
      ctx.drawImage(img, sx, sy, size, size, 0, 0, 256, 256);
      const blob = await canvas.convertToBlob({ type: "image/jpeg", quality: 0.9 });
      return new Response(blob, { headers: { "Content-Type": "image/jpeg" } });
    } catch (e) {
      return null;
    }
  }
  return null;
}
