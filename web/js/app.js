// Trail Tracker for the computer: the iPhone app's map, riders, offline maps, trail lines, navigation and radio,
// as a web app that installs from Edge or Chrome and works with no internet once maps are saved.

import { TNC2, parseAPRS, tnc2String, fmtLat, fmtLon } from "./aprs.js";
import { importTrailFile, trailSystem, trailDifficulty } from "./trails.js";
import { SOURCES, TRAIL_SYSTEMS, TileDownloader, tilesFor, boxAround, fmtBytes, savedFraction, deleteTiles, TILE_CACHE } from "./tiles.js";
import { TrailGraph, waysFromTrails, search as searchTrails, distance, bearing } from "./nav.js";
import { RadioLink } from "./radio.js";
import { dbGet, dbSet, load, save } from "./store.js";

const L = window.L;
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const PALETTE = ["#dc2626", "#2563eb", "#16a34a", "#ea580c", "#9333ea", "#db2777", "#0d9488", "#ca8a04", "#92400e", "#4f46e5"];
const STALE_MS = 10 * 60 * 1000;
const MAX_TRACK = 3000;

function fmtDist(m) {
  const mi = m / 1609.344;
  return mi < 0.2 ? Math.round(m * 3.28084).toLocaleString() + " ft" : (mi < 10 ? mi.toFixed(1) : Math.round(mi)) + " mi";
}
const compass = (d) => ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Math.floor(((d + 22.5) % 360) / 45)];
function ago(t) {
  const s = Math.round((Date.now() - t) / 1000);
  if (s < 5) return "just now";
  if (s < 60) return s + " sec ago";
  if (s < 3600) return Math.round(s / 60) + " min ago";
  if (s < 86400) return Math.round(s / 3600) + " hr ago";
  return new Date(t).toLocaleDateString();
}
const initials = (n) => { const w = n.trim().split(/\s+/); return (w.length >= 2 ? w[0][0] + w[1][0] : n.slice(0, 2)).toUpperCase(); };

let toastTimer = null;
function toast(text, ms = 4000) {
  const el = $("toast");
  el.textContent = text; el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.hidden = true), ms);
}

// ---------------------------------------------------------------- Settings

const settings = {
  useNet: load("useNet", true),
  style: load("style", "usgs-topo"),
  view: load("view", { lat: 37.83, lon: -81.83, zoom: 9 }),
  showTracks: load("showTracks", true),
  home: load("home", null),
  areas: load("areas", []),
  dl: load("dl", { topo: true, sat: false, zoom: 15 }),
  route: load("route", { avoidSingleTrack: true, avoidMostDifficult: false }),
  bt: load("bt", { all: false, extra: "" }),
  baud: load("baud", 9600),
};

// ---------------------------------------------------------------- Service worker (offline app + saved tiles)

let swReady = false;
async function startServiceWorker() {
  if (!("serviceWorker" in navigator) || location.protocol === "file:") return false;
  try {
    await navigator.serviceWorker.register("sw.js");
    await navigator.serviceWorker.ready;
    if (!navigator.serviceWorker.controller) {
      // First visit: wait for the worker to take over this page so map tiles go through it.
      await new Promise((ok) => {
        navigator.serviceWorker.addEventListener("controllerchange", ok, { once: true });
        setTimeout(ok, 4000);
      });
    }
    return !!navigator.serviceWorker.controller;
  } catch (e) {
    console.warn("Service worker failed", e);
    return false;
  }
}

// ---------------------------------------------------------------- Map

const map = L.map("map", { zoomControl: true, preferCanvas: true, minZoom: 4, maxZoom: 18, worldCopyJump: true })
  .setView([settings.view.lat, settings.view.lon], settings.view.zoom);
L.control.scale({ imperial: true, metric: false, position: "bottomleft" }).addTo(map);
map.attributionControl.setPrefix(false);
// Drawing order: trail lines, then rider tracks, then the route on top.
map.createPane("tracks").style.zIndex = 420;
map.createPane("route").style.zIndex = 430;
const trackRenderer = L.canvas({ pane: "tracks" });
const routeRenderer = L.canvas({ pane: "route" });

let tileLayer = null;
function tileURL() {
  if (swReady) return `tiles/${settings.style}/{z}/{x}/{y}?net=${settings.useNet ? 1 : 0}`;
  return SOURCES[settings.style].url;
}
function refreshTiles() {
  const url = tileURL();
  if (!tileLayer) {
    tileLayer = L.tileLayer(url, { maxZoom: 18, maxNativeZoom: 16, attribution: "Maps: USGS The National Map" }).addTo(map);
  } else {
    tileLayer.setUrl(url);
  }
}

document.querySelectorAll(".styles button").forEach((b) => {
  b.setAttribute("aria-checked", String(b.dataset.style === settings.style));
  b.onclick = () => {
    settings.style = b.dataset.style; save("style", settings.style);
    document.querySelectorAll(".styles button").forEach((o) => o.setAttribute("aria-checked", String(o === b)));
    refreshTiles();
  };
});

map.on("moveend", () => {
  const c = map.getCenter();
  save("view", { lat: c.lat, lon: c.lng, zoom: map.getZoom() });
  drawTrailLabels();
});

function updateOfflineBanner() {
  const b = $("offline-banner");
  if (!settings.useNet) { b.hidden = false; b.textContent = "Internet for maps is off: saved maps only"; }
  else if (!navigator.onLine) { b.hidden = false; b.textContent = "Offline: showing saved maps only"; }
  else b.hidden = true;
}
addEventListener("online", updateOfflineBanner);
addEventListener("offline", updateOfflineBanner);

// ---------------------------------------------------------------- Trail lines

let trails = [], trailSource = null, graph = null;
const trailLayer = L.layerGroup().addTo(map);
const labelLayer = L.layerGroup().addTo(map);
const trailRenderer = L.canvas({ padding: 0.3, tolerance: 6 });

function trailStyle(t) {
  const d = trailDifficulty(t).toLowerCase();
  const dash = d.includes("double") ? "8 4" : d.includes("single") ? "3 4" : null;
  return { color: t.color || "#8a5a2b", dash };
}

function drawTrails() {
  trailLayer.clearLayers();
  for (const t of trails) {
    const st = trailStyle(t);
    const latlngs = t.segments.map((s) => s.map(([lon, lat]) => [lat, lon]));
    L.polyline(latlngs, { renderer: trailRenderer, color: "#fff", weight: 6, opacity: 0.75, interactive: false }).addTo(trailLayer);
    const line = L.polyline(latlngs, { renderer: trailRenderer, color: st.color, weight: 3.5, opacity: 0.95, dashArray: st.dash }).addTo(trailLayer);
    line.bindPopup(() => trailPopup(t));
  }
  drawTrailLabels();
}

function trailPopup(t) {
  const rows = [["System", trailSystem(t)], ["Difficulty", trailDifficulty(t)], ["Miles", t.details.Miles || t.details.miles]]
    .filter(([, v]) => v).map(([k, v]) => `<div><small>${esc(k)}</small> ${esc(v)}</div>`).join("");
  return `<b>${esc(t.name)}</b>${rows}`;
}

function drawTrailLabels() {
  labelLayer.clearLayers();
  if (!trails.length || map.getZoom() < 14) return;
  const bounds = map.getBounds().pad(0.1);
  const placed = [];
  for (const t of trails) {
    if (!t.label) continue;
    const seg = t.segments.reduce((a, b) => (b.length > a.length ? b : a));
    const [lon, lat] = seg[Math.floor(seg.length / 2)];
    if (!bounds.contains([lat, lon])) continue;
    const p = map.latLngToLayerPoint([lat, lon]);
    const w = 10 + String(t.label).length * 7, h = 18;
    const r = [p.x - w / 2, p.y - h / 2, w, h];
    if (placed.some((q) => r[0] < q[0] + q[2] + 4 && q[0] < r[0] + r[2] + 4 && r[1] < q[1] + q[3] + 4 && q[1] < r[1] + r[3] + 4)) continue;
    placed.push(r);
    const color = t.color || "#8a5a2b";
    L.marker([lat, lon], {
      icon: L.divIcon({ className: "", html: `<span class="trail-tag" style="background:${esc(color)}">${esc(t.label)}</span>`, iconSize: [0, 0] }),
      interactive: false, keyboard: false,
    }).addTo(labelLayer);
  }
}

function setTrails(list, source) {
  trails = list; trailSource = source; graph = null;
  drawTrails();
  $("trail-source").textContent = list.length ? `${list.length} trails from ${source}` : "No trail map imported.";
  $("trail-remove").hidden = !list.length;
  demo.attachTrails();
}

function getGraph() {
  if (!graph && trails.length) graph = new TrailGraph(waysFromTrails(trails, trailSystem, trailDifficulty));
  return graph;
}

$("trail-file").onchange = async (e) => {
  const file = e.target.files[0];
  e.target.value = "";
  if (!file) return;
  try {
    const list = await importTrailFile(file.name, new Uint8Array(await file.arrayBuffer()));
    await dbSet("trails", { source: file.name, trails: list });
    setTrails(list, file.name);
    const b = L.latLngBounds(list.flatMap((t) => t.segments.flatMap((s) => s.map(([lon, lat]) => [lat, lon]))));
    map.fitBounds(b, { padding: [30, 30] });
    toast(`Imported ${list.length} trails from ${file.name}`);
  } catch (err) {
    toast(err.message || "Couldn't read that file.");
  }
};
$("trail-remove").onclick = async () => {
  if (!confirm("Remove the imported trail lines from this computer?")) return;
  await dbSet("trails", undefined);
  setTrails([], null);
  clearRoute();
};

// Trailheads of the Hatfield-McCoy systems (Rockhouse and Braveheart share one).
const trailheadLayer = L.layerGroup().addTo(map);
for (const s of TRAIL_SYSTEMS) {
  if (s.name === "Braveheart") continue;
  const name = s.name === "Rockhouse" ? "Rockhouse / Braveheart" : s.name;
  L.marker([s.lat, s.lon], {
    icon: L.divIcon({ className: "", html: `<div class="trailhead"><i>P</i><span>${esc(name)} Trailhead</span></div>`, iconSize: [0, 0] }),
    title: `${name} Trailhead · ${s.trailhead}`, keyboard: false,
  }).addTo(trailheadLayer);
}

// ---------------------------------------------------------------- You (this computer's location, optional)

let you = null, youMarker = null, watchId = null;
$("btn-locate").onclick = () => {
  if (watchId != null) {
    navigator.geolocation.clearWatch(watchId); watchId = null; you = null;
    youMarker?.remove(); youMarker = null;
    $("btn-locate").setAttribute("aria-pressed", "false");
    renderRiders();
    return;
  }
  if (!navigator.geolocation) return toast("This browser can't tell where the computer is.");
  $("btn-locate").setAttribute("aria-pressed", "true");
  let first = true;
  watchId = navigator.geolocation.watchPosition((pos) => {
    you = { lat: pos.coords.latitude, lon: pos.coords.longitude };
    if (!youMarker) youMarker = L.marker([you.lat, you.lon], { icon: L.divIcon({ className: "", html: '<div class="you-dot"></div>', iconSize: [0, 0] }), interactive: false }).addTo(map);
    else youMarker.setLatLng([you.lat, you.lon]);
    if (first) { first = false; map.setView([you.lat, you.lon], Math.max(map.getZoom(), 13)); }
    renderRiders();
  }, (err) => {
    toast("Couldn't get this computer's location. In Windows, turn on Settings → Privacy & security → Location.");
    $("btn-locate").setAttribute("aria-pressed", "false");
    watchId = null;
  }, { enableHighAccuracy: true, maximumAge: 30000 });
};

// ---------------------------------------------------------------- Riders

const riders = new Map();   // callsign → rider
let selected = null;
const riderLayer = L.layerGroup().addTo(map);
const trackLayer = L.layerGroup().addTo(map);
const markers = new Map(), tracks = new Map();

const displayName = (r) => r.name || r.id;
const isStale = (r) => !r.heard || Date.now() - r.heard > STALE_MS;

function ingest(report) {
  let r = riders.get(report.station);
  if (!r) {
    const used = new Set([...riders.values()].map((x) => x.color));
    r = { id: report.station, name: "", color: PALETTE.find((c) => !used.has(c)) || PALETTE[riders.size % PALETTE.length], hidden: false, track: [] };
    riders.set(r.id, r);
  }
  Object.assign(r, { lat: report.lat, lon: report.lon, heard: Date.now(), course: report.course, speedKnots: report.speedKnots,
                     altitudeFeet: report.altitudeFeet ?? r.altitudeFeet, comment: report.comment });
  const last = r.track[r.track.length - 1];
  if (!last || distance(last, report) > 10) r.track.push({ lat: report.lat, lon: report.lon, t: Date.now() });
  if (r.track.length > MAX_TRACK) r.track.splice(0, r.track.length - MAX_TRACK);
  drawRider(r);
  scheduleRiderList();
  saveRidersSoon();
}

function riderIcon(r) {
  const stale = isStale(r) ? " stale" : "", sel = selected === r.id ? " sel" : "";
  return L.divIcon({
    className: "", iconSize: [0, 0],
    html: `<div class="rider-pin${stale}"><div class="pin${sel}" style="background:${esc(r.color)}"></div><div class="ini">${esc(initials(displayName(r)))}</div><div class="lbl">${esc(displayName(r))}</div></div>`,
  });
}

function drawRider(r) {
  let m = markers.get(r.id), tr = tracks.get(r.id);
  if (r.hidden || r.lat == null) {
    m?.remove(); tr?.remove(); markers.delete(r.id); tracks.delete(r.id);
    return;
  }
  if (!m) {
    m = L.marker([r.lat, r.lon], { icon: riderIcon(r), title: r.id, riseOnHover: true, zIndexOffset: 1000 }).addTo(riderLayer);
    m.on("click", () => select(selected === r.id ? null : r.id));
    markers.set(r.id, m);
  } else {
    m.setLatLng([r.lat, r.lon]); m.setIcon(riderIcon(r));
  }
  if (settings.showTracks && r.track.length > 1) {
    const pts = r.track.map((p) => [p.lat, p.lon]);
    if (!tr) { tr = L.polyline(pts, { renderer: trackRenderer, color: r.color, weight: 4, opacity: 0.8, interactive: false }).addTo(trackLayer); tracks.set(r.id, tr); }
    else tr.setLatLngs(pts);
    tr.setStyle({ color: r.color, opacity: isStale(r) ? 0.35 : 0.8 });
  } else if (tr) { tr.remove(); tracks.delete(r.id); }
}

let listTimer = null;
function scheduleRiderList() { if (!listTimer) listTimer = setTimeout(() => { listTimer = null; renderRiders(); }, 100); }

function renderRiders() {
  const list = $("riders");
  const sorted = [...riders.values()].sort((a, b) => (b.heard || 0) - (a.heard || 0));
  $("rider-count").textContent = sorted.length;
  $("riders-empty").hidden = sorted.length > 0;
  list.innerHTML = "";
  for (const r of sorted) {
    const el = document.createElement("button");
    el.className = "item rider" + (isStale(r) ? " stale" : "") + (selected === r.id ? " sel" : "") + (r.hidden ? " hidden-rider" : "");
    const mph = r.speedKnots ? ` · ${Math.round(r.speedKnots * 1.15078)} mph` : "";
    const where = you && r.lat != null ? `${fmtDist(distance(you, r))} ${compass(bearing(you, r))}` : r.altitudeFeet ? `${Math.round(r.altitudeFeet).toLocaleString()} ft` : "";
    el.innerHTML = `<div class="badge" style="background:${esc(r.color)}">${esc(initials(displayName(r)))}</div>
      <div style="min-width:0"><div class="nm">${esc(displayName(r))}</div><div class="call">${esc(r.id)}${mph}</div></div>
      <div class="right"><div class="dist">${esc(where)}</div><div class="ago">${r.heard ? ago(r.heard) : ""}</div></div>`;
    el.onclick = () => select(selected === r.id ? null : r.id);
    list.appendChild(el);
  }
  renderStatus();
}

function select(id) {
  const prev = selected;
  selected = id;
  for (const k of [prev, id]) { const r = k && riders.get(k); if (r) drawRider(r); }
  const editor = $("rider-editor");
  const r = id && riders.get(id);
  if (!r) { editor.innerHTML = ""; renderRiders(); return; }
  editor.innerHTML = `<div class="editor">
    <label>Name for ${esc(r.id)}<input id="ed-name" value="${esc(r.name)}" placeholder="e.g. Andy" maxlength="24"></label>
    <div class="swatches">${PALETTE.map((c) => `<button class="swatch${c === r.color ? " on" : ""}" style="background:${c}" data-c="${c}" aria-label="Color ${c}"></button>`).join("")}</div>
    ${r.comment ? `<small>Radio comment: ${esc(r.comment)}</small>` : ""}
    <div class="row" style="margin-top:0">
      <button class="btn" id="ed-show">Show on map</button>
      <button class="btn" id="ed-hide">${r.hidden ? "Show this rider" : "Hide from map"}</button>
      <button class="btn" id="ed-forget">Forget</button>
    </div></div>`;
  $("ed-name").oninput = (e) => { r.name = e.target.value; drawRider(r); scheduleRiderList(); saveRidersSoon(); };
  editor.querySelectorAll(".swatch").forEach((b) => (b.onclick = () => { r.color = b.dataset.c; drawRider(r); saveRidersSoon(); select(id); }));
  $("ed-show").onclick = () => r.lat != null && map.setView([r.lat, r.lon], Math.max(map.getZoom(), 15));
  $("ed-hide").onclick = () => { r.hidden = !r.hidden; drawRider(r); saveRidersSoon(); select(id); };
  $("ed-forget").onclick = () => {
    if (!confirm(`Forget ${displayName(r)}? They'll come back if their radio is heard again.`)) return;
    r.hidden = true; drawRider(r); riders.delete(r.id); saveRidersSoon(); select(null);
  };
  renderRiders();
}

$("btn-tracks").textContent = settings.showTracks ? "Hide trail lines" : "Show trail lines";
$("btn-tracks").onclick = () => {
  settings.showTracks = !settings.showTracks; save("showTracks", settings.showTracks);
  $("btn-tracks").textContent = settings.showTracks ? "Hide trail lines" : "Show trail lines";
  riders.forEach(drawRider);
};
$("btn-clear-tracks").onclick = () => { riders.forEach((r) => { r.track = r.lat != null ? [{ lat: r.lat, lon: r.lon, t: Date.now() }] : []; drawRider(r); }); saveRidersSoon(); };

$("btn-fit").onclick = fitEveryone;
function fitEveryone() {
  const pts = [...riders.values()].filter((r) => !r.hidden && r.lat != null).map((r) => [r.lat, r.lon]);
  if (you) pts.push([you.lat, you.lon]);
  if (!pts.length) return toast("No one to show yet.");
  if (pts.length === 1) map.setView(pts[0], Math.max(map.getZoom(), 15));
  else map.fitBounds(pts, { padding: [60, 60], maxZoom: 16 });
}

let saveTimer = null;
function saveRidersSoon() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => dbSet("riders", [...riders.values()]).catch(() => {}), 2000);
}

setInterval(() => { riders.forEach(drawRider); renderRiders(); }, 15000);

// ---------------------------------------------------------------- Packets in (radio or demo)

const logEl = $("log");
function logLine(html) {
  const li = document.createElement("li");
  li.innerHTML = `${new Date().toLocaleTimeString([], { hour: "numeric", minute: "2-digit", second: "2-digit" })} ${html}`;
  logEl.prepend(li);
  while (logEl.children.length > 300) logEl.lastChild.remove();
}
$("log-copy").onclick = async () => {
  const text = [...logEl.children].reverse().map((li) => li.textContent).join("\n");
  try { await navigator.clipboard.writeText(text); toast("Log copied. Paste it into a message to share it."); } catch (e) { toast("Couldn't copy the log."); }
};

function onPacket(p, fromDemo = false) {
  const line = tnc2String(p);
  const gt = line.indexOf(">");
  logLine(`<b>${esc(line.slice(0, gt))}</b>${esc(line.slice(gt))}`);
  const report = parseAPRS(p);
  if (report) ingest(report);
  if (!fromDemo) lastRadioPacket = Date.now();
}
let lastRadioPacket = 0;

function renderStatus() {
  const recent = [...riders.values()].filter((r) => !isStale(r)).length;
  let text, on = false;
  if (radio.state.startsWith("Connected")) { text = `${radio.state} · ${recent} heard recently`; on = true; }
  else if (demo.running) { text = `Demo radio · ${recent} heard recently`; on = true; }
  else text = radio.state === "Not connected" ? "Radio not connected" : radio.state;
  $("status-text").textContent = text;
  document.querySelector(".dot").classList.toggle("on", on);
}

// ---------------------------------------------------------------- Demo riders

const demo = {
  running: false, timer: null, tick: 0,
  fakes: [
    { call: "DEMO-1", trail: "12", mps: 9, cLat: 37.616, cLon: -81.866, r: 0.012, speed: 0.05 },
    { call: "DEMO-2", trail: "46", mps: 7, cLat: 37.622, cLon: -81.858, r: 0.016, speed: 0.035 },
    { call: "DEMO-3", trail: "44", mps: 11, cLat: 37.605, cLon: -81.875, r: 0.009, speed: 0.07 },
  ],
  attachTrails() {
    const rock = trails.filter((t) => trailSystem(t) === "Rockhouse");
    for (const f of this.fakes) {
      const t = rock.find((x) => String(x.label) === f.trail);
      if (!t) { f.path = null; continue; }
      const seg = t.segments.reduce((a, b) => (b.length > a.length ? b : a));
      const cum = [0];
      for (let k = 1; k < seg.length; k++) cum.push(cum[k - 1] + distance({ lat: seg[k - 1][1], lon: seg[k - 1][0] }, { lat: seg[k][1], lon: seg[k][0] }));
      f.path = { pts: seg, cum, total: cum[cum.length - 1] };
      f.start = f.start ?? Math.random() * f.path.total;
    }
  },
  position(f, i) {
    if (f.path) {
      // Drive back and forth along the trail.
      const L2 = f.path.total;
      let d = (f.start + this.tick * f.mps * 3) % (2 * L2);
      const back = d > L2; if (back) d = 2 * L2 - d;
      const { pts, cum } = f.path;
      let k = 1; while (k < pts.length - 1 && cum[k] < d) k++;
      const a = pts[k - 1], b = pts[k], u = Math.min(1, Math.max(0, (d - cum[k - 1]) / (cum[k] - cum[k - 1] || 1)));
      const from = { lat: a[1], lon: a[0] }, to = { lat: b[1], lon: b[0] };
      const course = Math.round(back ? bearing(to, from) : bearing(from, to)) || 360;
      return { lat: a[1] + (b[1] - a[1]) * u, lon: a[0] + (b[0] - a[0]) * u, course, knots: Math.round(f.mps * 1.944) };
    }
    const ang = this.tick * f.speed + i * 2;
    return { lat: f.cLat + f.r * Math.sin(ang), lon: f.cLon + f.r * 1.3 * Math.cos(ang),
             course: Math.max(1, ((Math.round((ang + Math.PI / 2) * 180 / Math.PI) % 360) + 360) % 360), knots: 12 + i * 3 };
  },
  send() {
    this.tick++;
    this.fakes.forEach((f, i) => {
      const { lat, lon, course, knots } = this.position(f, i);
      const line = `${f.call}>APRS,WIDE1-1:!${fmtLat(lat)}/${fmtLon(lon)}j${String(Math.max(1, course % 361)).padStart(3, "0")}/${String(knots).padStart(3, "0")}Demo rider`;
      const p = TNC2.decode(line);
      if (p) onPacket(p, true);
    });
  },
  start() {
    if (this.running) return;
    this.running = true;
    this.attachTrails();
    this.send();
    this.timer = setInterval(() => this.send(), 3000);
    renderStatus();
  },
  stop() { clearInterval(this.timer); this.running = false; renderStatus(); },
};

$("demo").onchange = (e) => {
  if (e.target.checked) {
    demo.start();
    map.setView([37.615, -81.868], 14);
    if (!trails.length) toast("Demo riders are driving loops. Import the trail map (Maps tab) to see them follow real Rockhouse trails.", 6000);
  } else {
    demo.stop();
    if (confirm("Remove the demo riders from the list?")) {
      for (const id of [...riders.keys()]) if (id.startsWith("DEMO-")) { const r = riders.get(id); r.hidden = true; drawRider(r); riders.delete(id); }
      saveRidersSoon(); select(null);
    }
  }
};

// ---------------------------------------------------------------- Radio

const radio = new RadioLink({
  onPacket: (p) => onPacket(p),
  onLog: (text) => logLine(esc(text)),
  onState: (s) => {
    $("radio-state").textContent = s;
    const connected = s.startsWith("Connected");
    $("radio-disconnect").hidden = !connected;
    renderStatus();
    renderChannels();
  },
});

function renderChannels() {
  const sec = $("channels-section"), box = $("channels");
  sec.hidden = !radio.channels.length;
  box.innerHTML = "";
  const all = document.createElement("label");
  all.innerHTML = `<input type="radio" name="listen" value=""${radio.listenOnlyTo ? "" : " checked"}><span>Listen to everything</span><span></span>`;
  box.appendChild(all);
  for (const c of radio.channels) {
    const el = document.createElement("label");
    el.innerHTML = `<input type="radio" name="listen" value="${esc(c.id)}"${radio.listenOnlyTo === c.id ? " checked" : ""}>
      <span>${esc(c.id.length > 13 ? c.id.slice(0, 8) + "…" : c.id)} <span class="props">${esc(c.props)}</span></span><span>${c.bytes} B</span>`;
    box.appendChild(el);
  }
  box.querySelectorAll("input").forEach((i) => (i.onchange = () => { radio.listenOnlyTo = i.value || null; }));
}
setInterval(() => { if (radio.channels.length) renderChannels(); }, 3000);

$("bt-all").checked = settings.bt.all;
$("bt-extra").value = settings.bt.extra;
$("bt-all").onchange = (e) => { settings.bt.all = e.target.checked; save("bt", settings.bt); };
$("bt-extra").onchange = (e) => { settings.bt.extra = e.target.value.trim(); save("bt", settings.bt); };
$("serial-baud").value = String(settings.baud);
$("serial-baud").onchange = (e) => { settings.baud = +e.target.value; save("baud", settings.baud); };

$("bt-connect").onclick = async () => {
  if (!RadioLink.bluetoothAvailable) return toast("Bluetooth needs Microsoft Edge or Google Chrome on this computer.");
  try {
    const extra = settings.bt.extra ? settings.bt.extra.split(/[\s,]+/).filter(Boolean) : [];
    await radio.connectBluetooth(extra, settings.bt.all);
  } catch (e) {
    if (e.name !== "NotFoundError") toast(`Couldn't connect: ${e.message}. Is the ODmaster app closed and the radio's Bluetooth on?`, 7000);
    radio.setState("Not connected");
  }
};
$("serial-connect").onclick = async () => {
  if (!RadioLink.serialAvailable) return toast("COM ports need Microsoft Edge or Google Chrome on this computer.");
  try { await radio.connectSerial(settings.baud); } catch (e) { if (e.name !== "NotFoundError") toast(`Couldn't open the port: ${e.message}`); }
};
$("radio-disconnect").onclick = () => radio.disconnect();
$("radio-support").textContent = RadioLink.bluetoothAvailable
  ? "On the radio: Bluetooth on, BT Mode Receiver, and close the ODmaster app (one connection at a time). Bluetooth… picks the name ending in (BLE). COM port… is for the plain TD-H9 name after pairing it in Windows Settings."
  : "Bluetooth and COM ports work in Microsoft Edge or Google Chrome. Open Trail Tracker in Edge to connect a radio.";

// ---------------------------------------------------------------- Offline maps

const downloader = new TileDownloader();
const areaLayer = L.layerGroup();
let homePick = null;  // { name, lat, lon }

function dlSources() { return [$("o-topo").checked && "usgs-topo", $("o-sat").checked && "usgs-imagery"].filter(Boolean); }
function dlZoom() { return +$("o-zoom").value; }
function estimate(keys, sources) {
  const bytes = sources.reduce((t, s) => t + keys.size * SOURCES[s].bytes, 0);
  return sources.length ? `${(keys.size * sources.length).toLocaleString()} tiles · ${fmtBytes(bytes)}` : "Pick a map";
}

$("o-net").checked = settings.useNet;
$("o-net").onchange = (e) => { settings.useNet = e.target.checked; save("useNet", settings.useNet); refreshTiles(); updateOfflineBanner(); };
$("o-topo").checked = settings.dl.topo; $("o-sat").checked = settings.dl.sat; $("o-zoom").value = String(settings.dl.zoom);
["o-topo", "o-sat", "o-zoom"].forEach((id) => $(id).addEventListener("change", () => {
  settings.dl = { topo: $("o-topo").checked, sat: $("o-sat").checked, zoom: dlZoom() }; save("dl", settings.dl);
  updateEstimates();
}));

function hmtKeys(z) { const keys = new Set(); TRAIL_SYSTEMS.forEach((s) => tilesFor(s.box, z, keys)); return keys; }
function homeBox() { return homePick ? boxAround(homePick.lat, homePick.lon, +$("home-miles").value) : null; }

function updateEstimates() {
  const src = dlSources(), z = dlZoom();
  $("hmt-size").textContent = estimate(hmtKeys(z), src);
  if (homePick) {
    const keys = tilesFor(homeBox(), z);
    $("home-size").textContent = estimate(keys, src) + (keys.size * src.length > 150000 ? " · that's a lot; try less detail" : "");
  }
  $("hmt-go").disabled = $("home-go").disabled = !src.length || downloader.busy;
  drawAreas();
}
$("home-miles").onchange = updateEstimates;

function drawAreas() {
  areaLayer.clearLayers();
  const style = (saved) => ({ color: saved ? "#2f7d32" : "#c2410c", weight: 1.5, dashArray: saved ? null : "6 4", fillOpacity: saved ? 0.08 : 0.04, interactive: false });
  for (const s of TRAIL_SYSTEMS) {
    const saved = settings.areas.some((a) => a.id === s.id);
    L.rectangle([[s.box.s, s.box.w], [s.box.n, s.box.e]], style(saved)).addTo(areaLayer);
  }
  for (const a of settings.areas) if (!a.id.startsWith("hmt-")) L.rectangle([[a.box.s, a.box.w], [a.box.n, a.box.e]], style(true)).addTo(areaLayer);
  const hb = homeBox();
  if (hb) L.rectangle([[hb.s, hb.w], [hb.n, hb.e]], { ...style(false), color: "#2563eb" }).addTo(areaLayer);
}

function renderSystems() {
  const box = $("systems");
  box.innerHTML = "";
  for (const s of TRAIL_SYSTEMS) {
    const a = settings.areas.find((x) => x.id === s.id);
    const el = document.createElement("button");
    el.className = "item";
    el.innerHTML = `<div style="min-width:0"><div class="nm">${esc(s.name)}</div><div class="sub">${esc(s.trailhead)}</div></div>
      <span class="pill${a ? " saved" : ""}">${a ? "Saved · z" + a.maxZoom : "Not saved"}</span>`;
    el.onclick = () => map.fitBounds([[s.box.s, s.box.w], [s.box.n, s.box.e]]);
    box.appendChild(el);
  }
}

function renderAreas() {
  const box = $("areas");
  box.innerHTML = "";
  const own = settings.areas.filter((a) => !a.id.startsWith("hmt-"));
  const hmt = settings.areas.filter((a) => a.id.startsWith("hmt-"));
  const rows = [...own];
  if (hmt.length) rows.push({ id: "hmt", name: `Hatfield-McCoy (${hmt.length} of 13 systems)`, group: hmt, maxZoom: Math.max(...hmt.map((a) => a.maxZoom)), sources: [...new Set(hmt.flatMap((a) => a.sources))] });
  if (!rows.length) box.innerHTML = '<p class="note" style="margin:0">Nothing saved yet.</p>';
  for (const a of rows) {
    const el = document.createElement("div");
    el.className = "item";
    const kinds = a.sources.map((s) => (s === "usgs-topo" ? "topo" : "satellite")).join(" + ");
    el.innerHTML = `<div style="min-width:0"><div class="nm">${esc(a.name)}</div><div class="sub">${esc(kinds)} · detail to zoom ${a.maxZoom}${a.failed ? ` · ${a.failed} tiles missing` : ""}</div></div>
      <button class="link">Delete</button>`;
    el.querySelector("div").onclick = () => {
      const b = a.group ? a.group.map((g) => g.box) : [a.box];
      map.fitBounds([[Math.min(...b.map((x) => x.s)), Math.min(...b.map((x) => x.w))], [Math.max(...b.map((x) => x.n)), Math.max(...b.map((x) => x.e))]]);
    };
    el.querySelector("button").onclick = () => removeArea(a);
    box.appendChild(el);
  }
  showStorage();
}

async function showStorage() {
  try {
    const est = await navigator.storage.estimate();
    $("storage").textContent = `Using ${fmtBytes(est.usage || 0)} on this computer.`;
  } catch (e) { $("storage").textContent = ""; }
}

async function removeArea(a) {
  if (!confirm(`Delete the saved maps for ${a.name}?`)) return;
  const remove = a.group ? a.group : [a];
  const ids = new Set(remove.map((x) => x.id));
  const keepAreas = settings.areas.filter((x) => !ids.has(x.id));
  const keep = new Set();
  keepAreas.forEach((x) => tilesFor(x.box, x.maxZoom, keep));
  const keys = new Set();
  remove.forEach((x) => tilesFor(x.box, x.maxZoom, keys));
  toast("Deleting…");
  await deleteTiles(keys, keep, Object.keys(SOURCES));
  settings.areas = keepAreas; save("areas", settings.areas);
  renderAreas(); renderSystems(); drawAreas();
  toast("Deleted.");
}

$("btn-clear-maps").onclick = async () => {
  if (!confirm("Delete every saved map from this computer? You'll need internet to see maps again.")) return;
  await caches.delete(TILE_CACHE);
  settings.areas = []; save("areas", settings.areas);
  renderAreas(); renderSystems(); drawAreas();
  toast("All saved maps deleted.");
};

async function download(areas, label) {
  if (!swReady) return toast("Saving maps needs the app opened from its web address in Edge or Chrome.");
  if (!navigator.onLine) return toast("Downloading maps needs internet.");
  if (!settings.useNet) return toast("Turn on \"Use internet for maps\" to download.");
  const sources = dlSources(), z = dlZoom();
  if (!sources.length) return;
  try { await navigator.storage.persist?.(); } catch (e) { /* not granted; maps may be cleared if the disk fills */ }
  const keys = new Set();
  areas.forEach((a) => tilesFor(a.box, z, keys));
  $("progress").hidden = false;
  updateEstimates();
  const names = { "usgs-topo": "Topo", "usgs-imagery": "Satellite" };
  const result = await downloader.run(keys, sources, (p) => {
    $("p-job").textContent = `${label} · ${names[p.source]}`;
    $("p-count").textContent = `${p.done.toLocaleString()} of ${p.total.toLocaleString()}`;
    $("p-bar").style.width = (p.total ? (p.done / p.total) * 100 : 100) + "%";
  });
  if (!result.cancelled) {
    for (const a of areas) {
      const prev = settings.areas.find((x) => x.id === a.id);
      const sameBox = prev && JSON.stringify(prev.box) === JSON.stringify(a.box);
      const merged = { ...a, maxZoom: Math.max(z, sameBox ? prev.maxZoom : 0),sources: [...new Set([...(prev?.sources || []), ...sources])], failed: result.failed, savedAt: Date.now() };
      settings.areas = settings.areas.filter((x) => x.id !== a.id).concat(merged);
    }
    save("areas", settings.areas);
  }
  $("p-job").textContent = result.error ? result.error : result.cancelled ? "Stopped" : result.failed ? `Done · ${result.failed} tiles couldn't be downloaded (try again to fill them in)` : `${label} saved`;
  renderAreas(); renderSystems(); updateEstimates();
}
$("p-cancel").onclick = () => downloader.cancel();

$("hmt-go").onclick = () => download(TRAIL_SYSTEMS.map((s) => ({ id: s.id, name: s.name, box: s.box })), "Hatfield-McCoy");
$("home-go").onclick = () => {
  if (!homePick) return;
  const miles = +$("home-miles").value;
  settings.home = { ...homePick, miles }; save("home", settings.home);
  download([{ id: "home", name: `Home: ${homePick.name} (${miles} mi)`, box: homeBox() }], "My area");
};

function pickHome(name, lat, lon) {
  homePick = { name, lat, lon };
  $("home-picked").hidden = false;
  $("home-name").textContent = name;
  $("home-results").innerHTML = "";
  updateEstimates();
  const b = homeBox();
  map.fitBounds([[b.s, b.w], [b.n, b.e]]);
}

$("home-form").onsubmit = async (e) => {
  e.preventDefault();
  const q = $("home-q").value.trim();
  if (!q) return;
  // Typed coordinates work with no internet: "38.35, -81.63".
  const m = /^\s*(-?\d+(?:\.\d+)?)\s*[, ]\s*(-?\d+(?:\.\d+)?)\s*$/.exec(q);
  if (m) return pickHome(`${(+m[1]).toFixed(4)}, ${(+m[2]).toFixed(4)}`, +m[1], +m[2]);
  if (!settings.useNet || !navigator.onLine) return toast("Searching needs internet. You can type coordinates instead, like 38.35, -81.63.");
  const box = $("home-results");
  box.innerHTML = '<p class="note" style="margin:0">Searching…</p>';
  try {
    const res = await fetch(`https://nominatim.openstreetmap.org/search?format=jsonv2&limit=6&countrycodes=us&q=${encodeURIComponent(q)}`, { headers: { Accept: "application/json" } });
    const list = await res.json();
    box.innerHTML = list.length ? "" : '<p class="note" style="margin:0">Nothing found. Try a town and state, like "Logan, WV".</p>';
    for (const r of list) {
      const el = document.createElement("button");
      el.className = "item";
      const [head, ...rest] = r.display_name.split(", ");
      el.innerHTML = `<div style="min-width:0"><div class="nm">${esc(head)}</div><div class="sub">${esc(rest.join(", "))}</div></div>`;
      el.onclick = () => pickHome(r.display_name.split(", ").slice(0, 3).join(", "), +r.lat, +r.lon);
      box.appendChild(el);
    }
  } catch (err) {
    box.innerHTML = '<p class="note" style="margin:0">Search didn\'t work. Check the internet connection, or type coordinates.</p>';
  }
};
$("home-gps").onclick = () => {
  if (!navigator.geolocation) return toast("This browser can't tell where the computer is.");
  toast("Finding this computer…");
  navigator.geolocation.getCurrentPosition(
    (pos) => pickHome("This computer's location", pos.coords.latitude, pos.coords.longitude),
    () => toast("Couldn't get the location. In Windows, turn on Settings → Privacy & security → Location, or search instead."),
    { enableHighAccuracy: false, timeout: 15000 });
};
$("home-center").onclick = () => { const c = map.getCenter(); pickHome("Middle of the map", c.lat, c.lng); };
if (settings.home) {
  homePick = { name: settings.home.name, lat: settings.home.lat, lon: settings.home.lon };
  $("home-miles").value = String(settings.home.miles);
  $("home-picked").hidden = false; $("home-name").textContent = settings.home.name;
}

// ---------------------------------------------------------------- Navigation

const routeLayer = L.layerGroup().addTo(map);
let routeFrom = null, routeTo = null;
$("r-single").checked = settings.route.avoidSingleTrack;
$("r-hard").checked = settings.route.avoidMostDifficult;
["r-single", "r-hard"].forEach((id) => ($(id).onchange = () => {
  settings.route = { avoidSingleTrack: $("r-single").checked, avoidMostDifficult: $("r-hard").checked };
  save("route", settings.route);
  computeRoute();
}));
$("r-swap").onclick = () => { [routeFrom, routeTo] = [routeTo, routeFrom]; computeRoute(); };
$("r-clear").onclick = clearRoute;

function clearRoute() { routeFrom = routeTo = null; computeRoute(); }

function nearestTrailName(p) {
  const g = getGraph();
  const s = g && g.snap(p, { avoidSingleTrack: false, avoidMostDifficult: false }, 300);
  if (!s) return `${p.lat.toFixed(5)}, ${p.lon.toFixed(5)}`;
  const w = g.ways[g.edges[s.edge].way];
  return `${w.system ? w.system + " " : ""}Trail ${w.label}${s.d > 30 ? ` (${fmtDist(s.d)} away)` : ""}`;
}

function endMarker(p, kind) {
  return L.marker([p.lat, p.lon], { icon: L.divIcon({ className: "", html: `<div class="route-end ${kind}">${kind === "from" ? "A" : "B"}</div>`, iconSize: [0, 0] }), keyboard: false, draggable: true, zIndexOffset: 2000 })
    .on("dragend", (e) => { const ll = e.target.getLatLng(); if (kind === "from") routeFrom = { lat: ll.lat, lon: ll.lng }; else routeTo = { lat: ll.lat, lon: ll.lng }; computeRoute(); });
}

function computeRoute() {
  routeLayer.clearLayers();
  $("r-from").textContent = routeFrom ? nearestTrailName(routeFrom) : "Not set";
  $("r-to").textContent = routeTo ? nearestTrailName(routeTo) : "Not set";
  const out = $("r-result");
  out.innerHTML = "";
  if (routeFrom) endMarker(routeFrom, "from").addTo(routeLayer);
  if (routeTo) endMarker(routeTo, "to").addTo(routeLayer);
  if (!routeFrom || !routeTo) return;
  const g = getGraph();
  if (!g) { out.innerHTML = '<p class="note">Import the trail map first (Maps tab → Trail lines).</p>'; return; }
  const r = g.route(routeFrom, routeTo, settings.route);
  if (!r) { out.innerHTML = '<p class="note">No route found on the trails. The two points may be on trail systems that don\'t connect, or more than 3 miles from a trail.</p>'; return; }
  const color = getComputedStyle(document.documentElement).getPropertyValue("--route").trim() || "#7c3aed";
  const ll = r.points.map((p) => [p.lat, p.lon]);
  const onTrail = ll.slice(1, -1);
  L.polyline(onTrail, { renderer: routeRenderer, color: "#fff", weight: 10, opacity: 0.9, interactive: false }).addTo(routeLayer);
  L.polyline(onTrail, { renderer: routeRenderer, color, weight: 6, opacity: 0.95, interactive: false }).addTo(routeLayer);
  L.polyline([ll[0], ll[1]], { renderer: routeRenderer, color, weight: 3, dashArray: "4 6", interactive: false }).addTo(routeLayer);
  L.polyline([ll[ll.length - 2], ll[ll.length - 1]], { renderer: routeRenderer, color, weight: 3, dashArray: "4 6", interactive: false }).addTo(routeLayer);
  const hours = r.length / 1609.344 / 10;
  const time = hours < 1 ? `${Math.max(1, Math.round(hours * 60))} min` : `${Math.floor(hours)} hr ${Math.round((hours % 1) * 60)} min`;
  const steps = r.steps.filter((s, i) => i === 0 || s.length >= 25);
  out.innerHTML = `<div class="summary">${fmtDist(r.length)} · about ${time} at 10 mph</div>
    ${r.leadIn > 50 || r.leadOut > 50 ? `<p class="note">Dashed parts are off the mapped trails (${fmtDist(r.leadIn + r.leadOut)}).</p>` : ""}
    <ol class="steps">${steps.map((s, i) => {
      const t = trails.find((x) => x.label === s.way.label && trailSystem(x) === s.way.system);
      return `<li data-i="${i}"><span><span class="sw" style="background:${esc(t?.color || "#8a5a2b")}"></span>${esc(s.turn)} <b>${esc(s.title)}</b>${s.way.difficulty ? ` <small>${esc(s.way.difficulty)}</small>` : ""}</span><span class="len">${fmtDist(s.length)}</span></li>`;
    }).join("")}
    <li><span>Arrive</span><span class="len"></span></li></ol>`;
  out.querySelectorAll("li[data-i]").forEach((li) => (li.onclick = () => { const s = steps[+li.dataset.i]; map.setView([s.point.lat, s.point.lon], Math.max(map.getZoom(), 15)); }));
  map.fitBounds(ll, { padding: [50, 50], maxZoom: 16 });
}

$("find-form").onsubmit = (e) => {
  e.preventDefault();
  const box = $("find-results");
  box.innerHTML = "";
  if (!trails.length) { box.innerHTML = '<p class="note" style="margin:0">Import the trail map first (Maps tab → Trail lines).</p>'; return; }
  const c = map.getCenter();
  const results = searchTrails($("find-q").value, trails, trailSystem, { lat: c.lat, lon: c.lng });
  if (!results.length) { box.innerHTML = '<p class="note" style="margin:0">No trail matches. Try a number like 73, or "Bearwallow 73".</p>'; return; }
  for (const r of results) {
    const el = document.createElement("div");
    el.className = "item";
    el.innerHTML = `<div style="min-width:0"><div class="nm">${esc(r.kind === "junction" ? "Junction of " + r.title : r.title)}</div><div class="sub">${esc(r.subtitle)}${r.kind === "trail" && trailDifficulty(r.trails[0]) ? " · " + esc(trailDifficulty(r.trails[0])) : ""}</div></div>
      <button class="link">Route here</button>`;
    el.querySelector("div").onclick = () => showResult(r);
    el.querySelector("button").onclick = () => { routeTo = { lat: r.lat, lon: r.lon }; if (!routeFrom && you) routeFrom = { ...you }; computeRoute(); if (!routeFrom) toast("Now right-click where you're starting and pick Route from here."); };
    box.appendChild(el);
  }
  showResult(results[0]);
};

let highlight = null;
function showResult(r) {
  highlight?.remove();
  highlight = L.layerGroup().addTo(map);
  for (const t of r.trails) L.polyline(t.segments.map((s) => s.map(([lon, lat]) => [lat, lon])), { renderer: routeRenderer, color: "#facc15", weight: 12, opacity: 0.55, interactive: false }).addTo(highlight);
  if (r.kind === "junction") { L.circleMarker([r.lat, r.lon], { radius: 10, color: "#facc15", weight: 4, fill: false }).addTo(highlight); map.setView([r.lat, r.lon], 16); }
  else map.fitBounds(r.trails[0].segments.flatMap((s) => s.map(([lon, lat]) => [lat, lon])), { padding: [60, 60], maxZoom: 16 });
  setTimeout(() => { highlight?.remove(); highlight = null; }, 8000);
}

// ---------------------------------------------------------------- Right-click menu

let ctxAt = null;
const ctx = $("ctxmenu");
function openMenu(latlng, point) {
  ctxAt = { lat: latlng.lat, lon: latlng.lng };
  ctx.hidden = false;
  const wrap = document.querySelector(".mapwrap").getBoundingClientRect();
  ctx.style.left = Math.min(point.x, wrap.width - 210) + "px";
  ctx.style.top = Math.min(point.y, wrap.height - 180) + "px";
  ctx.querySelector("button").focus();
}
map.on("contextmenu", (e) => openMenu(e.latlng, e.containerPoint));
map.on("click movestart", () => (ctx.hidden = true));
document.addEventListener("keydown", (e) => { if (e.key === "Escape") ctx.hidden = true; });
ctx.onclick = (e) => {
  const act = e.target.dataset.act;
  if (!act || !ctxAt) return;
  ctx.hidden = true;
  if (act === "from") { routeFrom = ctxAt; computeRoute(); showTab("route"); }
  if (act === "to") { routeTo = ctxAt; computeRoute(); showTab("route"); }
  if (act === "home") { showTab("maps"); pickHome(`${ctxAt.lat.toFixed(4)}, ${ctxAt.lon.toFixed(4)}`, ctxAt.lat, ctxAt.lon); $("home-picked").scrollIntoView({ block: "nearest" }); }
  if (act === "copy") navigator.clipboard?.writeText(`${ctxAt.lat.toFixed(6)}, ${ctxAt.lon.toFixed(6)}`).then(() => toast("Coordinates copied."), () => {});
};

// ---------------------------------------------------------------- Tabs

function showTab(name) {
  document.querySelectorAll(".tab").forEach((t) => t.setAttribute("aria-selected", String(t.dataset.tab === name)));
  document.querySelectorAll(".panel").forEach((p) => (p.hidden = p.id !== "panel-" + name));
  if (name === "maps") { areaLayer.addTo(map); updateEstimates(); renderAreas(); } else areaLayer.remove();
  save("tab", name);
}
document.querySelectorAll(".tab").forEach((t) => (t.onclick = () => showTab(t.dataset.tab)));

// ---------------------------------------------------------------- Start

(async () => {
  swReady = await startServiceWorker();
  refreshTiles();
  updateOfflineBanner();
  renderSystems();
  showTab(load("tab", "riders"));
  try {
    const saved = await dbGet("riders");
    for (const r of saved || []) { riders.set(r.id, r); drawRider(r); }
  } catch (e) { /* first run */ }
  renderRiders();
  try {
    const t = await dbGet("trails");
    if (t?.trails?.length) setTrails(t.trails, t.source);
  } catch (e) { /* none saved */ }
})();
