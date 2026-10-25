// Offline route finding over the imported trail lines: a graph with a node at every trail end and junction,
// shortest path by Dijkstra, and turn-by-turn steps. Same rules as the iPhone app's navigation.

const M_PER_DEG = 111320;
const JOIN = 15;      // meters: a trail end this close to another trail counts as joined to it
const CELL = 250;     // meters: spatial grid size

export const DEFAULT_OPTIONS = { avoidSingleTrack: true, avoidMostDifficult: false };

/** Cost per meter on a trail, or null when routes may not use it. */
export function weight(difficulty, opts) {
  const d = (difficulty || "").toLowerCase();
  // Hiking, horse and cabin/campground-guest trails are never open to ATVs/UTVs.
  if (d.includes("hiking") || d.includes("horse") || d.includes("guests only")) return null;
  if (opts.avoidSingleTrack && d.includes("single track")) return null;
  if (opts.avoidMostDifficult && d.includes("most")) return null;
  return 1;
}

export function distance(a, b) {
  const k = Math.cos((a.lat + b.lat) / 2 * Math.PI / 180);
  return Math.hypot((b.lon - a.lon) * M_PER_DEG * k, (b.lat - a.lat) * M_PER_DEG);
}

export function bearing(a, b) {
  const k = Math.cos((a.lat + b.lat) / 2 * Math.PI / 180);
  return (Math.atan2((b.lon - a.lon) * k, b.lat - a.lat) * 180 / Math.PI + 360) % 360;
}

/**
 * ways: [{ label, system, difficulty, points: [{lat, lon}] }]
 */
export class TrailGraph {
  constructor(ways) {
    this.ways = ways;
    const lats = ways.flatMap((w) => w.points.map((p) => p.lat));
    this.k = Math.cos((lats.length ? (Math.min(...lats.slice(0, 50000)) + Math.max(...lats.slice(0, 50000))) / 2 : 37.7) * Math.PI / 180);
    this.build();
  }

  xy(p) { return { x: p.lon * M_PER_DEG * this.k, y: p.lat * M_PER_DEG }; }
  geo(q) { return { lat: q.y / M_PER_DEG, lon: q.x / M_PER_DEG / this.k }; }

  build() {
    const ways = this.ways;
    const xys = ways.map((w) => w.points.map((p) => this.xy(p)));
    // Grid of line pieces, for "what's near here" lookups.
    const grid = new Map();
    const add = (gx, gy, v) => { const k = gx + "," + gy; let a = grid.get(k); if (!a) grid.set(k, (a = [])); a.push(v); };
    xys.forEach((pts, w) => {
      for (let i = 0; i + 1 < pts.length; i++) {
        const a = pts[i], b = pts[i + 1];
        const x0 = Math.floor((Math.min(a.x, b.x) - JOIN) / CELL), x1 = Math.floor((Math.max(a.x, b.x) + JOIN) / CELL);
        const y0 = Math.floor((Math.min(a.y, b.y) - JOIN) / CELL), y1 = Math.floor((Math.max(a.y, b.y) + JOIN) / CELL);
        for (let gx = x0; gx <= x1; gx++) for (let gy = y0; gy <= y1; gy++) add(gx, gy, [w, i]);
      }
    });

    // Split points along each way: its two ends, plus wherever another trail's end meets it.
    const splits = xys.map((pts) => [{ i: 0, t: 0, p: pts[0], id: -1 }, { i: pts.length - 2, t: 1, p: pts[pts.length - 1], id: -1 }]);
    const parent = [];
    const newId = () => { parent.push(parent.length); return parent.length - 1; };
    const find = (a) => { while (parent[a] !== a) { parent[a] = parent[parent[a]]; a = parent[a]; } return a; };
    const union = (a, b) => { a = find(a); b = find(b); if (a !== b) parent[b] = a; };
    splits.forEach((s) => s.forEach((sp) => (sp.id = newId())));

    xys.forEach((pts, w) => {
      [0, 1].forEach((end) => {
        const e = end ? pts[pts.length - 1] : pts[0];
        const endSplit = splits[w][end];
        const cands = grid.get(Math.floor(e.x / CELL) + "," + Math.floor(e.y / CELL)) || [];
        // Nearest point on each other way within JOIN meters.
        const best = new Map();
        for (const [ow, i] of cands) {
          if (ow === w) continue;
          const [d, t, q] = project(e, xys[ow][i], xys[ow][i + 1]);
          if (d <= JOIN && (!best.has(ow) || best.get(ow).d > d)) best.set(ow, { d, i, t, q });
        }
        for (const [ow, h] of best) {
          const sp = { i: h.i, t: h.t, p: h.q, id: newId() };
          splits[ow].push(sp);
          union(endSplit.id, sp.id);
        }
      });
    });

    // Nodes and edges.
    const nodeOf = new Map();
    this.nodes = []; this.edges = []; this.adj = [];
    const node = (sp) => {
      const r = find(sp.id);
      if (!nodeOf.has(r)) { nodeOf.set(r, this.nodes.length); this.nodes.push(this.geo(sp.p)); this.adj.push([]); }
      return nodeOf.get(r);
    };
    splits.forEach((list, w) => {
      list.sort((a, b) => a.i - b.i || a.t - b.t);
      const pts = xys[w];
      for (let s = 0; s + 1 < list.length; s++) {
        const A = list[s], B = list[s + 1];
        const line = [A.p];
        for (let v = A.i + 1; v <= B.i; v++) line.push(pts[v]);
        line.push(B.p);
        const cum = [0];
        for (let k = 1; k < line.length; k++) cum.push(cum[k - 1] + Math.hypot(line[k].x - line[k - 1].x, line[k].y - line[k - 1].y));
        const a = node(A), b = node(B);
        if (a === b && cum[cum.length - 1] < 1) continue;
        const id = this.edges.length;
        this.edges.push({ a, b, way: w, xy: line, cum, length: cum[cum.length - 1] });
        this.adj[a].push(id); if (b !== a) this.adj[b].push(id);
      }
    });

    // Grid of edge pieces for snapping clicked points onto the network.
    this.edgeGrid = new Map();
    this.edges.forEach((e, id) => {
      for (let i = 0; i + 1 < e.xy.length; i++) {
        const a = e.xy[i], b = e.xy[i + 1];
        for (let gx = Math.floor(Math.min(a.x, b.x) / CELL); gx <= Math.floor(Math.max(a.x, b.x) / CELL); gx++)
          for (let gy = Math.floor(Math.min(a.y, b.y) / CELL); gy <= Math.floor(Math.max(a.y, b.y) / CELL); gy++) {
            const k = gx + "," + gy; let arr = this.edgeGrid.get(k); if (!arr) this.edgeGrid.set(k, (arr = [])); arr.push([id, i]);
          }
      }
    });
  }

  /** Closest usable point on the network: { edge, along, d, point }. Looks up to `maxMeters` away. */
  snap(p, opts, maxMeters = 5000) {
    const q = this.xy(p);
    const gx = Math.floor(q.x / CELL), gy = Math.floor(q.y / CELL);
    let best = null;
    for (let r = 0; r * CELL <= maxMeters + CELL; r++) {
      for (let dx = -r; dx <= r; dx++) for (let dy = -r; dy <= r; dy++) {
        if (Math.max(Math.abs(dx), Math.abs(dy)) !== r) continue;
        for (const [id, i] of this.edgeGrid.get(gx + dx + "," + (gy + dy)) || []) {
          const e = this.edges[id];
          if (weight(this.ways[e.way].difficulty, opts) == null) continue;
          const [d, t, pt] = project(q, e.xy[i], e.xy[i + 1]);
          if (!best || d < best.d) best = { edge: id, along: e.cum[i] + t * (e.cum[i + 1] - e.cum[i]), d, point: this.geo(pt) };
        }
      }
      // Anything in a farther ring is at least (r * CELL) away.
      if (best && best.d <= r * CELL) break;
    }
    return best && best.d <= maxMeters ? best : null;
  }

  /** Shortest route between two points, or null. */
  route(from, to, opts = DEFAULT_OPTIONS) {
    const s = this.snap(from, opts), t = this.snap(to, opts);
    if (!s || !t) return null;
    const n = this.nodes.length;
    const dist = new Float64Array(n).fill(Infinity), prev = new Int32Array(n).fill(-1);
    const heap = new Heap();
    const se = this.edges[s.edge], sw = weight(this.ways[se.way].difficulty, opts);
    const relax0 = (node, cost) => { if (cost < dist[node]) { dist[node] = cost; heap.push(node, cost); } };
    relax0(se.a, s.along * sw);
    relax0(se.b, (se.length - s.along) * sw);
    while (heap.size) {
      const [u, du] = heap.pop();
      if (du > dist[u]) continue;
      for (const id of this.adj[u]) {
        const e = this.edges[id], w = weight(this.ways[e.way].difficulty, opts);
        if (w == null) continue;
        const v = e.a === u ? e.b : e.a, nd = du + e.length * w;
        if (nd < dist[v]) { dist[v] = nd; prev[v] = id; heap.push(v, nd); }
      }
    }
    const te = this.edges[t.edge], tw = weight(this.ways[te.way].difficulty, opts);
    // Options for reaching the end point: along the end edge from either of its nodes, or directly on a shared edge.
    let best = { cost: Infinity };
    if (dist[te.a] < Infinity) best = { cost: dist[te.a] + t.along * tw, via: te.a };
    if (dist[te.b] + (te.length - t.along) * tw < best.cost) best = { cost: dist[te.b] + (te.length - t.along) * tw, via: te.b };
    if (s.edge === t.edge && Math.abs(s.along - t.along) * sw <= best.cost) best = { cost: Math.abs(s.along - t.along) * sw, direct: true };
    if (best.cost === Infinity) return null;

    // Pieces of the route in travel order: [edgeId, fromAlong, toAlong].
    const pieces = [];
    if (best.direct) {
      pieces.push([s.edge, s.along, t.along]);
    } else {
      const chain = [];
      let u = best.via;
      while (prev[u] !== -1) {
        const id = prev[u], e = this.edges[id];
        const from = e.a === u ? e.b : e.a;
        chain.push([id, from === e.a ? 0 : e.length, from === e.a ? e.length : 0]);
        u = from;
      }
      chain.reverse();
      // u is now the node next to the start point.
      pieces.push([s.edge, s.along, u === se.a ? 0 : se.length]);
      pieces.push(...chain);
      pieces.push([t.edge, best.via === te.a ? 0 : te.length, t.along]);
    }
    return this.describe(from, to, s, t, pieces);
  }

  describe(from, to, s, t, pieces) {
    const points = [from, s.point];
    const steps = [];
    let total = distance(from, s.point);
    const leadIn = total;
    for (const [id, a, b] of pieces) {
      const e = this.edges[id], way = this.ways[e.way];
      const line = this.slice(e, a, b);
      if (line.length < 2) continue;
      const len = Math.abs(b - a);
      const head = line[0], next = line[Math.min(line.length - 1, 2)];
      const last = steps[steps.length - 1];
      if (last && last.way.label === way.label && last.way.system === way.system) {
        last.length += len;
      } else if (len > 0.5) {
        steps.push({ way, length: len, startsAt: total, point: head, inBearing: bearing(head, next) });
      }
      for (let i = 1; i < line.length; i++) points.push(line[i]);
      total += len;
      if (steps.length) steps[steps.length - 1].outBearing = bearing(line[Math.max(0, line.length - 3)], line[line.length - 1]);
    }
    points.push(to);
    const leadOut = distance(t.point, to);
    total += leadOut;
    steps.forEach((st, i) => {
      st.title = st.way.label ? (/^\d/.test(st.way.label) ? "Trail " + st.way.label : st.way.label) : (st.way.system ? st.way.system + " trail" : "Trail");
      st.turn = i === 0 ? "Start on" : turnWord(steps[i - 1].outBearing, st.inBearing);
    });
    return { points, steps, length: total, leadIn, leadOut };
  }

  /** Points along an edge between two distances (either direction). */
  slice(e, a, b) {
    const forward = b >= a, lo = Math.min(a, b), hi = Math.max(a, b);
    const at = (d) => {
      let i = 1; while (i < e.cum.length - 1 && e.cum[i] < d) i++;
      const seg = e.cum[i] - e.cum[i - 1] || 1, u = Math.max(0, Math.min(1, (d - e.cum[i - 1]) / seg));
      return { x: e.xy[i - 1].x + (e.xy[i].x - e.xy[i - 1].x) * u, y: e.xy[i - 1].y + (e.xy[i].y - e.xy[i - 1].y) * u };
    };
    const out = [at(lo)];
    for (let i = 0; i < e.cum.length; i++) if (e.cum[i] > lo && e.cum[i] < hi) out.push(e.xy[i]);
    out.push(at(hi));
    if (!forward) out.reverse();
    return out.map((q) => this.geo(q));
  }
}

function turnWord(inB, outB) {
  if (inB == null || outB == null) return "Continue on";
  const d = ((outB - inB + 540) % 360) - 180;
  const a = Math.abs(d);
  if (a < 30) return "Continue on";
  if (a < 60) return d > 0 ? "Bear right onto" : "Bear left onto";
  if (a < 140) return d > 0 ? "Turn right onto" : "Turn left onto";
  if (a < 170) return d > 0 ? "Sharp right onto" : "Sharp left onto";
  return "Turn around onto";
}

/** Distance from p to segment ab, the fraction along ab, and the closest point. */
function project(p, a, b) {
  const dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy;
  const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2));
  const q = { x: a.x + dx * t, y: a.y + dy * t };
  return [Math.hypot(p.x - q.x, p.y - q.y), t, q];
}

class Heap {
  constructor() { this.a = []; }
  get size() { return this.a.length; }
  push(v, k) {
    const a = this.a; a.push([v, k]);
    let i = a.length - 1;
    while (i > 0) { const p = (i - 1) >> 1; if (a[p][1] <= a[i][1]) break; [a[p], a[i]] = [a[i], a[p]]; i = p; }
  }
  pop() {
    const a = this.a, top = a[0], last = a.pop();
    if (a.length) {
      a[0] = last;
      let i = 0;
      for (;;) {
        const l = 2 * i + 1, r = l + 1;
        let m = i;
        if (l < a.length && a[l][1] < a[m][1]) m = l;
        if (r < a.length && a[r][1] < a[m][1]) m = r;
        if (m === i) break;
        [a[m], a[i]] = [a[i], a[m]]; i = m;
      }
    }
    return top;
  }
}

/** Ways for the graph from imported trails (each line of each trail is one way). */
export function waysFromTrails(trails, systemOf, difficultyOf) {
  const ways = [];
  for (const t of trails) {
    const system = systemOf(t), difficulty = difficultyOf(t);
    for (const seg of t.segments) ways.push({ label: t.label, system, difficulty, name: t.name, points: seg.map(([lon, lat]) => ({ lat, lon })) });
  }
  return ways;
}

/**
 * Finds trails by number or name ("73", "Bearwallow 73", "Rockhouse 12"), or a junction of two trails
 * ("73 & 12", "73 and 12"). Results are sorted by distance from `near`.
 */
export function search(query, trails, systemOf, near) {
  const q = query.trim().toLowerCase();
  if (!q) return [];
  const parts = q.split(/\s*(?:&|\band\b|\/|@)\s*/).filter(Boolean);
  const matchOne = (text) => {
    const words = text.split(/\s+/);
    const num = words.find((w) => /^\d+[a-z]?$/.test(w));
    const rest = words.filter((w) => w !== num).join(" ");
    return trails.filter((t) => {
      const sys = systemOf(t).toLowerCase(), label = String(t.label).toLowerCase(), name = t.name.toLowerCase();
      if (num && label !== num) return false;
      if (rest && !(sys.includes(rest) || name.includes(rest))) return false;
      return !!(num || rest);
    });
  };
  const centerOf = (t) => {
    const seg = t.segments.reduce((a, b) => (b.length > a.length ? b : a));
    const [lon, lat] = seg[Math.floor(seg.length / 2)];
    return { lat, lon };
  };
  if (parts.length >= 2) {
    // A junction: the closest pair of points between the two trails, kept if they nearly touch.
    const A = matchOne(parts[0]), B = matchOne(parts[1]);
    const out = [];
    for (const a of A) for (const b of B) {
      if (a === b) continue;
      let best = null;
      for (const sa of a.segments) for (const pa of sa) for (const sb of b.segments) {
        for (let i = 0; i < sb.length; i += 1) {
          const d = distance({ lat: pa[1], lon: pa[0] }, { lat: sb[i][1], lon: sb[i][0] });
          if (!best || d < best.d) best = { d, lat: pa[1], lon: pa[0] };
        }
      }
      if (best && best.d < 60) out.push({ kind: "junction", title: `${a.label} & ${b.label}`, subtitle: systemOf(a), lat: best.lat, lon: best.lon, trails: [a, b] });
    }
    return sortNear(out, near).slice(0, 20);
  }
  return sortNear(matchOne(parts[0] || q).map((t) => ({ kind: "trail", title: t.name, subtitle: systemOf(t), ...centerOf(t), trails: [t] })), near).slice(0, 30);
}

function sortNear(list, near) {
  if (!near) return list;
  return list.sort((a, b) => distance(near, a) - distance(near, b));
}
