// Map tiles: sources, tile math, download areas and the offline download manager.
// Tiles live in the browser's Cache Storage under this app's own address (tiles/<source>/<z>/<x>/<y>),
// and the service worker (sw.js) serves them from there, so the map works with no internet.

export const SOURCES = {
  "usgs-topo": { name: "Topo (USGS)", url: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}", bytes: 18000 },
  "usgs-imagery": { name: "Satellite + Topo (USGS)", url: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryTopo/MapServer/tile/{z}/{y}/{x}", bytes: 36000 },
};
export const TILE_CACHE = "tiles-v1";
export const MIN_DOWNLOAD_ZOOM = 10;

export const remoteURL = (source, z, x, y) => SOURCES[source].url.replace("{z}", z).replace("{x}", x).replace("{y}", y);
export const localURL = (source, z, x, y) => new URL(`tiles/${source}/${z}/${x}/${y}`, document.baseURI).href;

export const lon2x = (lon, z) => Math.floor((lon + 180) / 360 * 2 ** z);
export const lat2y = (lat, z) => { const r = lat * Math.PI / 180; return Math.floor((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * 2 ** z); };

/** Every tile key ("z/x/y") covering a box, from MIN_DOWNLOAD_ZOOM to maxZoom. */
export function tilesFor(box, maxZoom, into = new Set()) {
  for (let z = MIN_DOWNLOAD_ZOOM; z <= maxZoom; z++) {
    const x0 = lon2x(box.w, z), x1 = lon2x(box.e, z), y0 = lat2y(box.n, z), y1 = lat2y(box.s, z);
    for (let x = x0; x <= x1; x++) for (let y = y0; y <= y1; y++) into.add(`${z}/${x}/${y}`);
  }
  return into;
}

/** A box reaching `miles` from a point in every direction. */
export function boxAround(lat, lon, miles) {
  const dLat = miles / 69.05, dLon = miles / (69.17 * Math.cos(lat * Math.PI / 180));
  return { s: lat - dLat, n: lat + dLat, w: lon - dLon, e: lon + dLon };
}

export function fmtBytes(b) {
  return b >= 1e9 ? (b / 1e9).toFixed(1) + " GB" : b >= 1e6 ? Math.round(b / 1e6) + " MB" : Math.max(1, Math.round(b / 1e3)) + " KB";
}

/** The Hatfield-McCoy trail systems (same data as App/Maps/TrailSystems.swift). */
const MARGIN = 0.03;  // about two miles around the trails
export const TRAIL_SYSTEMS = [
  ["Rockhouse", "83 Rockhouse Creek Rd, Man", 37.72613, -81.88346, 37.62, 37.769, -81.996, -81.868],
  ["Braveheart", "83 Rockhouse Creek Rd, Man", 37.72613, -81.88346, 37.696, 37.73, -81.868, -81.805],
  ["Bearwallow", "247 Bearwallow Dr, Ethel", 37.86405, -81.93206, 37.84, 37.923, -82.062, -81.892],
  ["Devil Anse", "48 McCoy St, Matewan", 37.62139, -82.16805, 37.592, 37.69, -82.172, -81.996],
  ["Buffalo Mountain", "1472 Buffalo Mountain, Williamson", 37.69941, -82.20581, 37.647, 37.718, -82.286, -82.17],
  ["Pinnacle Creek", "2733 Pinnacle Rd, Pineville", 37.55587, -81.50792, 37.424, 37.572, -81.543, -81.341],
  ["Indian Ridge", "County Rd 17, Ashland", 37.41279, -81.35254, 37.386, 37.459, -81.428, -81.309],
  ["Warrior", "84 Silcox Ln, War", 37.30372, -81.69275, 37.299, 37.415, -81.672, -81.545],
  ["Pocahontas", "11110 Coal Heritage Rd, Bramwell (Coaldale)", 37.3645, -81.33435, 37.327, 37.388, -81.36, -81.282],
  ["Ivy Branch", "4260 Julian Rd, Julian", 38.16642, -81.87782, 38.166, 38.202, -81.897, -81.847],
  ["Big Coal River", "21868 Daniel Boone Pkwy, Peytona", 38.12862, -81.69154, 38.095, 38.135, -81.692, -81.648],
  ["Cabwaylingo", "39 Tick Ridge Rd, Wilsondale", 37.98705, -82.37298, 37.924, 38.014, -82.392, -82.332],
  ["Tornado", "7900 Smith Creek Rd, Tornado", 38.33815, -81.83351, 38.318, 38.338, -81.834, -81.816],
].map(([name, trailhead, lat, lon, minLat, maxLat, minLon, maxLon]) => ({
  id: "hmt-" + name.toLowerCase().replace(/\W+/g, "-"), name, trailhead, lat, lon,
  box: { s: Math.min(minLat, lat) - MARGIN, n: Math.max(maxLat, lat) + MARGIN, w: Math.min(minLon, lon) - MARGIN, e: Math.max(maxLon, lon) + MARGIN },
}));

/**
 * Downloads tiles into Cache Storage. Skips tiles already saved, runs a few requests at a time,
 * and reports progress. One job at a time.
 */
export class TileDownloader {
  constructor() { this.job = null; }

  get busy() { return !!this.job; }

  cancel() { if (this.job) this.job.cancelled = true; }

  /** keys: Set of "z/x/y"; sources: ["usgs-topo", ...]; onProgress({ done, total, saved, failed, source }) */
  async run(keys, sources, onProgress) {
    if (this.job) throw new Error("A download is already running.");
    const job = this.job = { cancelled: false };
    const cache = await caches.open(TILE_CACHE);
    const list = [];
    for (const s of sources) for (const k of keys) list.push([s, k]);
    const state = { done: 0, total: list.length, saved: 0, failed: 0, source: sources[0] };
    let next = 0, lastReport = 0;
    const report = (force) => {
      const now = Date.now();
      if (force || now - lastReport > 150) { lastReport = now; onProgress({ ...state }); }
    };
    const worker = async () => {
      while (!job.cancelled && next < list.length) {
        const [source, key] = list[next++];
        state.source = source;
        const [z, x, y] = key.split("/").map(Number);
        const local = localURL(source, z, x, y);
        try {
          if (!(await cache.match(local))) {
            let res = null;
            for (let attempt = 0; attempt < 3 && !res; attempt++) {
              try {
                const r = await fetch(remoteURL(source, z, x, y), { mode: "cors", credentials: "omit" });
                if (r.ok) res = r;
                else if (r.status === 404) break;  // the server has no tile there (e.g. open water)
              } catch (e) {
                await new Promise((ok) => setTimeout(ok, 800 * (attempt + 1)));
              }
            }
            if (res) { await cache.put(local, res); state.saved++; } else state.failed++;
          }
        } catch (e) {
          state.failed++;
          if (e && e.name === "QuotaExceededError") { job.cancelled = true; state.error = "The computer ran out of space for maps."; }
        }
        state.done++;
        report(false);
      }
    };
    try {
      await Promise.all(Array.from({ length: 6 }, worker));
    } finally {
      this.job = null;
    }
    state.cancelled = job.cancelled && !state.error;
    report(true);
    return state;
  }
}

/** How many of these tiles are already saved (checks a sample for big areas, so it's quick). */
export async function savedFraction(keys, sources) {
  const cache = await caches.open(TILE_CACHE);
  const all = [...keys];
  const step = Math.max(1, Math.floor(all.length / 150));
  let have = 0, checked = 0;
  for (const s of sources) {
    for (let i = 0; i < all.length; i += step) {
      const [z, x, y] = all[i].split("/").map(Number);
      if (await cache.match(localURL(s, z, x, y))) have++;
      checked++;
    }
  }
  return checked ? have / checked : 0;
}

/** Deletes the tiles of one area. Tiles shared with another saved area are kept. */
export async function deleteTiles(keys, keep, sources) {
  const cache = await caches.open(TILE_CACHE);
  for (const s of sources) for (const k of keys) {
    if (keep.has(k)) continue;
    const [z, x, y] = k.split("/").map(Number);
    await cache.delete(localURL(s, z, x, y));
  }
}
