// APRS decoding: a port of Packages/APRSCore (the iPhone app's decoder), so both apps read radios the same way.
// Handles KISS framing, AX.25 UI frames, "SRC>DEST,PATH:info" text, plain and compressed positions,
// Mic-E, objects, items, raw NMEA and third-party wrapped packets.

export const latin1 = {
  bytes: (s) => Uint8Array.from(s, (c) => c.charCodeAt(0) & 0xff),
  string: (b) => { let s = ""; for (const x of b) s += String.fromCharCode(x); return s; },
};

const A = (c) => c.charCodeAt(0);
const isDigit = (b) => b >= 48 && b <= 57;
const isUpper = (b) => b >= 65 && b <= 90;

/** One packet as heard on the air. info is the raw info field as bytes. */
export function packet(source, destination, path, info) {
  return { source, destination, path: path || [], info: typeof info === "string" ? latin1.bytes(info) : Uint8Array.from(info) };
}

export function tnc2String(p) {
  return `${p.source}>${[p.destination, ...p.path].join(",")}:${latin1.string(p.info)}`;
}

// ---- TNC2 text ----

export const TNC2 = {
  decode(line) {
    // Strip control characters at the ends, like the Swift version.
    const trimmed = line.replace(/^[\x00-\x1f\x7f]+|[\x00-\x1f\x7f]+$/g, "");
    const gt = trimmed.indexOf(">");
    if (gt < 0) return null;
    const colon = trimmed.indexOf(":", gt);
    if (colon < 0) return null;
    // Some radios prefix lines with "[RX] " or a timestamp; the callsign is the last word before ">".
    const words = trimmed.slice(0, gt).split(/[ \]]/).filter(Boolean);
    const source = words.length ? words[words.length - 1] : "";
    const header = trimmed.slice(gt + 1, colon).split(",").filter((s) => s.length);
    if (!isCallsign(source) || !header.length) return null;
    const info = latin1.bytes(trimmed.slice(colon + 1));
    if (!info.length) return null;
    return packet(source, header[0], header.slice(1), info);
  },
};

function isCallsign(s) {
  return s.length >= 1 && s.length <= 12 && /^[\p{L}\p{N}-]+$/u.test(s);
}

// ---- KISS ----

export const KISS = {
  fend: 0xc0, fesc: 0xdb, tfend: 0xdc, tfesc: 0xdd,
  encode(frame, port = 0) {
    const out = [KISS.fend, (port & 0x0f) << 4];
    for (const b of frame) {
      if (b === KISS.fend) out.push(KISS.fesc, KISS.tfend);
      else if (b === KISS.fesc) out.push(KISS.fesc, KISS.tfesc);
      else out.push(b);
    }
    out.push(KISS.fend);
    return out;
  },
};

/** Reassembles KISS frames from a byte stream that may arrive in arbitrary chunks. */
export class KISSDecoder {
  constructor() { this.buffer = []; this.inFrame = false; this.escaping = false; }
  feed(bytes) {
    const frames = [];
    for (const b of bytes) {
      if (b === KISS.fend) {
        if (this.inFrame && this.buffer.length > 1 && (this.buffer[0] & 0x0f) === 0) frames.push(this.buffer.slice(1));
        this.buffer = []; this.inFrame = true; this.escaping = false;
        continue;
      }
      if (!this.inFrame) continue;
      if (this.escaping) {
        this.escaping = false;
        this.buffer.push(b === KISS.tfend ? KISS.fend : b === KISS.tfesc ? KISS.fesc : b);
      } else if (b === KISS.fesc) {
        this.escaping = true;
      } else {
        this.buffer.push(b);
      }
      if (this.buffer.length > 2048) { this.buffer = []; this.inFrame = false; }  // runaway frame
    }
    return frames;
  }
}

// ---- AX.25 ----

export const AX25 = {
  decode(frame) {
    if (frame.length < 16) return null;
    const calls = [], repeated = [];
    let i = 0, last = false;
    while (!last) {
      if (i + 7 > frame.length || calls.length >= 10) return null;
      const a = decodeAddress(frame.slice(i, i + 7));
      if (!a) return null;
      calls.push(a.call); repeated.push(a.hBit); last = a.isLast;
      i += 7;
    }
    if (calls.length < 2 || i + 2 > frame.length) return null;
    const control = frame[i] & 0xef, pid = frame[i + 1];
    if (control !== 0x03 || pid !== 0xf0) return null;
    const path = calls.slice(2).map((c, k) => (repeated[k + 2] ? c + "*" : c));
    return packet(calls[1], calls[0], path, frame.slice(i + 2));
  },
  encode(p) {
    const all = [p.destination, p.source, ...p.path];
    const out = [];
    all.forEach((raw, index) => {
      let call = raw, rep = false;
      if (call.endsWith("*")) { call = call.slice(0, -1); rep = true; }
      const [base, ssidText] = call.split("-");
      const bb = latin1.bytes(base || "").slice(0, 6);
      const ssid = (parseInt(ssidText || "0", 10) || 0) & 0x0f;
      for (let k = 0; k < 6; k++) out.push(((k < bb.length ? bb[k] : 0x20) << 1) & 0xff);
      let s = 0x60 | (ssid << 1);
      if (index === all.length - 1) s |= 0x01;
      if (rep) s |= 0x80;
      out.push(s);
    });
    out.push(0x03, 0xf0, ...p.info);
    return out;
  },
};

function decodeAddress(b) {
  let call = "";
  for (let k = 0; k < 6; k++) {
    const c = b[k] >> 1;
    if (c === 0x20) continue;
    // Callsigns are letters and digits; anything else means this isn't really AX.25.
    if (!((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a))) return null;
    call += String.fromCharCode(c);
  }
  if (!call) return null;
  const ssid = (b[6] >> 1) & 0x0f;
  if (ssid) call += "-" + ssid;
  return { call, isLast: (b[6] & 1) === 1, hBit: (b[6] & 0x80) !== 0 };
}

// ---- Radio byte stream: KISS or text lines, whichever shows up first ----

export class RadioStreamDecoder {
  constructor() { this.mode = "unknown"; this.kiss = new KISSDecoder(); this.text = []; }
  feed(bytes) {
    if (this.mode === "unknown" && bytes.includes(KISS.fend)) { this.mode = "kiss"; this.text = []; }
    if (this.mode === "kiss") return this.kiss.feed(bytes).map((f) => AX25.decode(f)).filter(Boolean);
    this.text.push(...bytes);
    const out = [];
    let end;
    while ((end = this.text.findIndex((b) => b === 0x0a || b === 0x0d || b === 0x00)) >= 0) {
      const line = this.text.slice(0, end);
      this.text.splice(0, end + 1);
      const p = TNC2.decode(latin1.string(line));
      if (p) { this.mode = "text"; out.push(p); }
    }
    if (this.text.length > 4096) this.text = [];
    return out;
  }
  /** Call after the radio goes quiet; some radios send one packet per notification with no line ending. */
  flush() {
    if (this.mode === "kiss" || !this.text.length) return [];
    const p = TNC2.decode(latin1.string(this.text));
    this.text = [];
    if (p) { this.mode = "text"; return [p]; }
    return [];
  }
}

// ---- Positions ----

/** Returns { station, isObject, lat, lon, symbolTable, symbolCode, course, speedKnots, altitudeFeet, comment } or null. */
export function parseAPRS(p) {
  const info = p.info;
  if (!info.length) return null;
  const t = String.fromCharCode(info[0]);
  const report = (pos) => (pos ? { station: p.source, isObject: false, ...pos } : null);
  switch (t) {
    case "!": case "=": return report(parsePosition(info.slice(1)));
    case "/": case "@": return info.length > 8 ? report(parsePosition(info.slice(8))) : null;
    case ";": return parseObject(info);
    case ")": return parseItem(info);
    case "`": case "'": case "\x1c": case "\x1d": return report(parseMicE(p.destination, info));
    case "$": return report(parseNMEA(latin1.string(info)));
    case "}": {
      const inner = TNC2.decode(latin1.string(info.slice(1)));
      return inner ? parseAPRS(inner) : null;
    }
    default: {
      // A "!" position may start anywhere in the first 40 characters.
      const bang = info.slice(0, 40).indexOf(A("!"));
      return bang >= 0 ? report(parsePosition(info.slice(bang + 1))) : null;
    }
  }
}

function parsePosition(b) {
  if (!b.length) return null;
  return isDigit(b[0]) || b[0] === 32 ? parseUncompressed(b) : parseCompressed(b);
}

function parseUncompressed(b) {
  if (b.length < 19) return null;
  const lat = latitude(b.slice(0, 8)), lon = longitude(b.slice(9, 18));
  if (lat == null || lon == null) return null;
  const pos = { lat, lon, symbolTable: String.fromCharCode(b[8]), symbolCode: String.fromCharCode(b[18]),
                course: null, speedKnots: null, altitudeFeet: null, comment: "" };
  let rest = b.slice(19);
  const cs = latin1.string(rest.slice(0, 7));
  if (rest.length >= 7 && rest[3] === A("/") && /^\d{3}\/\d{3}$/.test(cs)) {
    const course = +cs.slice(0, 3), speed = +cs.slice(4, 7);
    if (course >= 1 && course <= 360) pos.course = course % 360;
    pos.speedKnots = speed;
    rest = rest.slice(7);
  }
  applyComment(latin1.string(rest), pos);
  return pos;
}

function parseCompressed(b) {
  if (b.length < 13) return null;
  const table = b[0];
  if (!(table === A("/") || table === A("\\") || isUpper(table) || (table >= A("a") && table <= A("j")))) return null;
  const y = base91(b.slice(1, 5)), x = base91(b.slice(5, 9));
  if (y == null || x == null) return null;
  const lat = 90 - y / 380926, lon = -180 + x / 190463;
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
  const pos = { lat, lon, symbolTable: String.fromCharCode(table), symbolCode: String.fromCharCode(b[9]),
                course: null, speedKnots: null, altitudeFeet: null, comment: "" };
  const c = b[10], s = b[11], t = b[12];
  if (c !== 32 && c >= 33 && s >= 33 && t >= 33) {
    const cv = c - 33, sv = s - 33;
    if ((((t - 33) >> 3) & 0x03) === 2) pos.altitudeFeet = Math.pow(1.002, cv * 91 + sv);
    else if (cv >= 0 && cv <= 89) { pos.course = cv * 4; pos.speedKnots = Math.pow(1.08, sv) - 1; }
  }
  applyComment(latin1.string(b.slice(13)), pos);
  return pos;
}

function parseObject(b) {
  if (b.length <= 18 || b[10] !== A("*")) return null;  // "_" means the object was killed
  const name = latin1.string(b.slice(1, 10)).trim();
  const pos = parsePosition(b.slice(18));
  return pos && name ? { station: name, isObject: true, ...pos } : null;
}

function parseItem(b) {
  let end = -1;
  for (let i = 1; i < Math.min(11, b.length); i++) if (b[i] === A("!") || b[i] === A("_")) { end = i; break; }
  if (end < 0 || b[end] !== A("!")) return null;
  const name = latin1.string(b.slice(1, end)).trim();
  const pos = parsePosition(b.slice(end + 1));
  return pos && name ? { station: name, isObject: true, ...pos } : null;
}

function parseMicE(destination, info) {
  const dest = latin1.bytes(destination.split("-")[0] || "").slice(0, 6);
  if (dest.length !== 6 || info.length < 9) return null;
  const digits = [];
  for (const ch of dest) {
    if (ch >= A("0") && ch <= A("9")) digits.push(ch - A("0"));
    else if (ch >= A("A") && ch <= A("J")) digits.push(ch - A("A"));
    else if (ch >= A("P") && ch <= A("Y")) digits.push(ch - A("P"));
    else if (ch === A("K") || ch === A("L") || ch === A("Z")) digits.push(0);  // position ambiguity
    else return null;
  }
  const latDeg = digits[0] * 10 + digits[1];
  const latMin = digits[2] * 10 + digits[3] + (digits[4] * 10 + digits[5]) / 100;
  if (latDeg > 90 || latMin >= 60) return null;
  const pz = (c) => c >= A("P") && c <= A("Z");
  const north = pz(dest[3]), lonOffset = pz(dest[4]), west = pz(dest[5]);

  let lonDeg = info[1] - 28;
  if (lonOffset) lonDeg += 100;
  if (lonDeg >= 180 && lonDeg <= 189) lonDeg -= 80;
  if (lonDeg >= 190 && lonDeg <= 199) lonDeg -= 190;
  let lonMin = info[2] - 28;
  if (lonMin >= 60) lonMin -= 60;
  const lonHundredths = info[3] - 28;
  if (lonDeg < 0 || lonDeg > 180 || lonMin < 0 || lonMin >= 60 || lonHundredths < 0 || lonHundredths >= 100) return null;

  const sp = info[4] - 28, dc = info[5] - 28, se = info[6] - 28;
  let speed = sp * 10 + Math.floor(dc / 10);
  let course = (dc % 10) * 100 + se;
  if (speed >= 800) speed -= 800;
  if (course >= 400) course -= 400;

  const pos = {
    lat: (latDeg + latMin / 60) * (north ? 1 : -1),
    lon: (lonDeg + (lonMin + lonHundredths / 100) / 60) * (west ? -1 : 1),
    symbolTable: String.fromCharCode(info[8]), symbolCode: String.fromCharCode(info[7]),
    course: course >= 1 && course <= 360 ? course % 360 : null, speedKnots: speed, altitudeFeet: null, comment: "",
  };
  let rest = info.slice(9);
  // Optional base-91 altitude: three chars followed by "}" (meters, offset by 10000).
  const brace = rest.slice(0, 5).indexOf(A("}"));
  if (brace >= 3) {
    const meters = base91(rest.slice(brace - 3, brace));
    if (meters != null) { pos.altitudeFeet = (meters - 10000) * 3.28084; rest = rest.slice(brace + 1); }
  }
  applyComment(latin1.string(rest), pos);
  return pos;
}

function parseNMEA(sentence) {
  const f = sentence.split("*")[0].split(",");
  const kind = f[0] || "";
  if (kind.endsWith("RMC") && f.length >= 9 && f[2] === "A") {
    const lat = nmeaCoord(f[3], f[4], 2), lon = nmeaCoord(f[5], f[6], 3);
    if (lat != null && lon != null) {
      const course = f[8] === "" || isNaN(+f[8]) ? null : Math.round(+f[8]);
      const speed = f[7] === "" || isNaN(+f[7]) ? null : +f[7];
      return { lat, lon, symbolTable: "/", symbolCode: ">", course, speedKnots: speed, altitudeFeet: null, comment: "" };
    }
  }
  if (kind.endsWith("GGA") && f.length >= 10 && f[6] !== "0") {
    const lat = nmeaCoord(f[2], f[3], 2), lon = nmeaCoord(f[4], f[5], 3);
    if (lat != null && lon != null) {
      const alt = f[9] === "" || isNaN(+f[9]) ? null : +f[9] * 3.28084;
      return { lat, lon, symbolTable: "/", symbolCode: ">", course: null, speedKnots: null, altitudeFeet: alt, comment: "" };
    }
  }
  return null;
}

function nmeaCoord(value, hemi, degDigits) {
  if (!value || value.length <= degDigits) return null;
  const deg = +value.slice(0, degDigits), min = +value.slice(degDigits);
  if (isNaN(deg) || isNaN(min)) return null;
  const v = deg + min / 60;
  return hemi === "N" || hemi === "E" ? v : hemi === "S" || hemi === "W" ? -v : null;
}

function latitude(b) {
  // "DDMM.mmN", spaces allowed for position ambiguity.
  const s = latin1.string(b.map((x) => (x === 32 ? 48 : x)));
  const deg = +s.slice(0, 2), min = +s.slice(2, 7);
  if (s.length !== 8 || !/^\d{2}\d{2}\.\d{2}$/.test(s.slice(0, 7)) || deg > 90 || min >= 60) return null;
  return s[7] === "N" ? deg + min / 60 : s[7] === "S" ? -(deg + min / 60) : null;
}

function longitude(b) {
  // "DDDMM.mmW"
  const s = latin1.string(b.map((x) => (x === 32 ? 48 : x)));
  const deg = +s.slice(0, 3), min = +s.slice(3, 8);
  if (s.length !== 9 || !/^\d{3}\d{2}\.\d{2}$/.test(s.slice(0, 8)) || deg > 180 || min >= 60) return null;
  return s[8] === "E" ? deg + min / 60 : s[8] === "W" ? -(deg + min / 60) : null;
}

function applyComment(text, pos) {
  let comment = text;
  // Altitude in feet: "/A=001234" anywhere in the comment.
  const m = /\/A=(-?\d{5,6})/.exec(comment);
  if (m && m[1].length === 6) { pos.altitudeFeet = +m[1]; comment = comment.slice(0, m.index) + comment.slice(m.index + 9); }
  pos.comment = comment.trim();
}

function base91(b) {
  let v = 0;
  for (const c of b) { if (c < 33 || c > 124) return null; v = v * 91 + (c - 33); }
  return v;
}

/** "3741.20N" style text, used by the demo riders. */
export function fmtLat(v) { const a = Math.abs(v), d = Math.floor(a), m = (a - d) * 60; return String(d).padStart(2, "0") + m.toFixed(2).padStart(5, "0") + (v >= 0 ? "N" : "S"); }
export function fmtLon(v) { const a = Math.abs(v), d = Math.floor(a), m = (a - d) * 60; return String(d).padStart(3, "0") + m.toFixed(2).padStart(5, "0") + (v >= 0 ? "E" : "W"); }
