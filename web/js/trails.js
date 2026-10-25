// Trail map import (KMZ, KML, GPX): a port of App/Maps/TrailImport.swift.
// Written without DOMParser so the same code runs in the browser and in the Node check (web/test).

/** @typedef {{ name: string, label: string, color: string|null, segments: number[][][], details: Object<string,string> }} Trail */

export async function importTrailFile(fileName, bytes) {
  const ext = fileName.toLowerCase().split(".").pop();
  let trails;
  if (ext === "kmz") {
    const files = await unzip(bytes);
    // A KMZ is a zip with one main KML (usually doc.kml) and sometimes more.
    const kmls = Object.keys(files).filter((k) => k.toLowerCase().endsWith(".kml")).sort();
    if (!kmls.length) throw new Error("That file doesn't contain any trail lines.");
    trails = kmls.flatMap((k) => parseKML(decodeText(files[k])));
  } else if (ext === "kml") {
    trails = parseKML(decodeText(bytes));
  } else if (ext === "gpx") {
    trails = parseGPX(decodeText(bytes));
  } else if (ext === "zip") {
    // Trails Heaven hands out a .zip that wraps the .kmz; look inside for it.
    const files = await unzip(bytes);
    const inner = Object.keys(files).find((k) => /\.(kmz|kml|gpx)$/i.test(k));
    if (!inner) throw new Error("That zip doesn't contain a KMZ, KML or GPX file.");
    return importTrailFile(inner, files[inner]);
  } else {
    throw new Error("Pick a KMZ, KML or GPX file.");
  }
  if (!trails.length) throw new Error("That file doesn't contain any trail lines.");
  return trails;
}

function decodeText(bytes) { return new TextDecoder("utf-8").decode(bytes); }

// ---- Labels and colors ----

const NUMBER_KEYS = ["trail_numb", "trail_num", "trailnum", "trail_no", "trailno", "trail_number", "trailnumber",
                     "number", "num", "ref", "trail_id", "trailid", "trail"];

function field(details, keys) {
  for (const key of keys) {
    const k = Object.keys(details).find((d) => d.toLowerCase() === key);
    const v = k && details[k].trim();
    if (v) return v;
  }
  return null;
}

/** The text drawn on the map: a trail-number field if the file has one, else the name. */
export function trailLabel(name, details) {
  for (const key of NUMBER_KEYS) {
    const k = Object.keys(details).find((d) => d.toLowerCase() === key);
    const v = k && details[k].trim();
    if (v && v.length <= 12) return v;
  }
  return name.trim();
}

/** A readable name, e.g. "Bearwallow 73" or the trail's own name when it has one. */
export function trailTitle(name, label, details) {
  const trimmed = name.trim();
  const system = field(details, ["trail_syst", "trail_system", "system"]);
  const own = field(details, ["trail_name", "trailname"]);
  if (own) return [system, own].filter(Boolean).join(" · ");
  if (trimmed && trimmed !== label) return trimmed;
  if (label) return [system, "Trail " + label].filter(Boolean).join(" ");
  return system || "Trail";
}

/** Standard trail difficulty colors, used when the file doesn't set one. */
export function difficultyColor(text) {
  const t = text.toLowerCase();
  if (t.includes("most difficult") || t.includes("extreme") || t.includes("expert") || t.includes("black")) return "#212121";
  if (t.includes("more difficult") || t.includes("moderate") || t.includes("intermediate") || t.includes("blue")) return "#1E63D6";
  if (t.includes("difficult") || t.includes("hard")) return "#212121";
  if (t.includes("easiest") || t.includes("easy") || t.includes("green")) return "#2E8B3A";
  return null;
}

export const trailSystem = (t) => field(t.details, ["trail_syst", "trail_system", "system"]) || "";
export const trailDifficulty = (t) => field(t.details, ["difficulty", "difficult", "rating", "class"]) || "";

// ---- KML ----

const unescapeXML = (s) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, "&");

/** Text content of an element body: CDATA kept as-is, everything else unescaped. */
function textOf(body) {
  if (body == null) return "";
  let out = "";
  const re = /<!\[CDATA\[([\s\S]*?)\]\]>/g;
  let last = 0, m;
  while ((m = re.exec(body))) { out += unescapeXML(body.slice(last, m.index)) + m[1]; last = re.lastIndex; }
  return (out + unescapeXML(body.slice(last))).trim();
}

// Tag names may carry a namespace prefix (kml:Placemark), so every pattern allows one.
const tagRe = (tag, flags = "gi") => new RegExp(`<(?:\\w+:)?${tag}\\b([^>]*)>([\\s\\S]*?)</(?:\\w+:)?${tag}>`, flags);
const first = (body, tag) => { const m = tagRe(tag, "i").exec(body); return m ? m[2] : null; };
const attr = (attrs, name) => { const m = new RegExp(`\\b${name}\\s*=\\s*["']([^"']*)["']`).exec(attrs); return m ? m[1] : null; };

/** KML colors are "aabbggrr". */
function kmlColor(s) {
  const h = s.trim();
  return h.length === 8 ? "#" + h.slice(6, 8) + h.slice(4, 6) + h.slice(2, 4) : null;
}

export function parseKML(xml) {
  // Shared styles (outside placemarks) and style maps that point at them.
  const withoutPlacemarks = xml.replace(tagRe("Placemark"), "");
  const styles = {}, styleMaps = {};
  for (const m of withoutPlacemarks.matchAll(tagRe("Style"))) {
    const id = attr(m[1], "id"), ls = first(m[2], "LineStyle"), c = ls && first(ls, "color");
    if (id && c) { const hex = kmlColor(textOf(c)); if (hex) styles[id] = hex; }
  }
  for (const m of withoutPlacemarks.matchAll(tagRe("StyleMap"))) {
    const id = attr(m[1], "id");
    for (const p of m[2].matchAll(tagRe("Pair"))) {
      if (textOf(first(p[2], "key")) === "normal") {
        const u = textOf(first(p[2], "styleUrl"));
        if (id && u) styleMaps[id] = u.replace(/^#/, "");
      }
    }
  }

  const trails = [];
  for (const pm of xml.matchAll(tagRe("Placemark"))) {
    const body = pm[2];
    const segments = [];
    for (const ls of body.matchAll(tagRe("LineString"))) {
      const coords = first(ls[2], "coordinates");
      if (!coords) continue;
      const pts = textOf(coords).split(/\s+/).map((pair) => {
        const parts = pair.split(",");
        const lon = parseFloat(parts[0]), lat = parseFloat(parts[1]);
        return parts.length >= 2 && isFinite(lon) && isFinite(lat) ? [lon, lat] : null;
      }).filter(Boolean);
      if (pts.length >= 2) segments.push(pts);
    }
    if (!segments.length) continue;

    // The placemark's own <name>, not one nested in its geometry or data.
    const name = textOf(first(body.replace(tagRe("(?:ExtendedData|MultiGeometry|LineString|Style)"), ""), "name"));
    const styleURL = textOf(first(body, "styleUrl"));
    const details = {};
    for (const d of body.matchAll(tagRe("Data"))) {
      const n = attr(d[1], "name");
      if (n) details[n] = textOf(first(d[2], "value"));
    }
    for (const d of body.matchAll(tagRe("SimpleData"))) {
      const n = attr(d[1], "name");
      if (n) details[n] = textOf(d[2]);
    }
    const description = textOf(first(body, "description"));
    // ArcGIS exports (like the Hatfield-McCoy KMZ) put the attributes in an HTML table in the description.
    if (description && /<td/i.test(description)) {
      for (const [k, v] of Object.entries(tableFields(description))) if (!(k in details)) details[k] = v;
    } else if (description) {
      details.description = description;
    }

    const label = trailLabel(name, details);
    const title = trailTitle(name, label, details);
    let color = difficultyColor([title, ...Object.values(details)].join(" "));
    if (styleURL) {
      const id = styleURL.replace(/^#/, "");
      if (styles[styleMaps[id] || id]) color = styles[styleMaps[id] || id];
    }
    trails.push({ name: title, label: label || title, color, segments, details });
  }
  return trails;
}

/** Reads <td>key</td><td>value</td> pairs. The first cell is a title row when the count is odd. */
export function tableFields(html) {
  const cells = [...html.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/gi)].map((m) =>
    m[1].replace(/<[^>]+>/g, "").replace(/&amp;/g, "&").replace(/&nbsp;/g, " ").trim());
  if (cells.length % 2 === 1) cells.shift();
  const out = {};
  for (let i = 0; i + 1 < cells.length; i += 2) if (cells[i]) out[cells[i]] = cells[i + 1];
  return out;
}

// ---- GPX ----

export function parseGPX(xml) {
  const trails = [];
  for (const kind of ["trk", "rte"]) {
    for (const m of xml.matchAll(tagRe(kind))) {
      const body = m[2];
      const name = textOf(first(body.replace(tagRe("(?:trkseg|rtept|trkpt)"), ""), "name"));
      const segs = [];
      const pointsIn = (s, tag) => [...s.matchAll(new RegExp(`<${tag}\\b([^>]*?)(?:/>|>)`, "gi"))].map((p) => {
        const lat = parseFloat(attr(p[1], "lat")), lon = parseFloat(attr(p[1], "lon"));
        return isFinite(lat) && isFinite(lon) ? [lon, lat] : null;
      }).filter(Boolean);
      if (kind === "trk") {
        for (const s of body.matchAll(tagRe("trkseg"))) { const pts = pointsIn(s[2], "trkpt"); if (pts.length >= 2) segs.push(pts); }
      } else {
        const pts = pointsIn(body, "rtept"); if (pts.length >= 2) segs.push(pts);
      }
      if (segs.length) {
        const title = name || "Trail";
        trails.push({ name: title, label: title, color: difficultyColor(title), segments: segs, details: {} });
      }
    }
  }
  return trails;
}

// ---- Minimal zip reader (KMZ files are zips). Uses the browser's built-in deflate decoder. ----

export async function unzip(bytes) {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  const u16 = (o) => b[o] | (b[o + 1] << 8);
  const u32 = (o) => (u16(o) | (u16(o + 2) << 16)) >>> 0;
  // End of central directory record, searched from the end (it may be followed by a comment).
  let eocd = -1;
  for (let i = b.length - 22; i >= Math.max(0, b.length - 65557); i--) {
    if (b[i] === 0x50 && b[i + 1] === 0x4b && b[i + 2] === 0x05 && b[i + 3] === 0x06) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error("Couldn't read that file.");
  const count = u16(eocd + 10);
  let p = u32(eocd + 16);
  const out = {};
  for (let n = 0; n < count; n++) {
    if (p + 46 > b.length || u32(p) !== 0x02014b50) break;
    const method = u16(p + 10), compSize = u32(p + 20);
    const nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32), local = u32(p + 42);
    const name = new TextDecoder().decode(b.subarray(p + 46, p + 46 + nameLen));
    p += 46 + nameLen + extraLen + commentLen;
    if (local + 30 > b.length || u32(local) !== 0x04034b50 || name.endsWith("/")) continue;
    const start = local + 30 + u16(local + 26) + u16(local + 28);
    const raw = b.subarray(start, start + compSize);
    if (method === 0) out[name] = raw.slice();
    else if (method === 8) out[name] = await inflateRaw(raw);
  }
  return out;
}

async function inflateRaw(raw) {
  const stream = new Blob([raw]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}
