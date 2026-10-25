"""Downloads named roads around the Hatfield-McCoy trail systems from OpenStreetMap
and writes App/Resources/Roads.json, so the app can find "trail 73 and Bearwallow Rd" offline.

Run by the "Fetch road data" GitHub Action (the phone never needs to do this).
Road data (c) OpenStreetMap contributors, ODbL.
"""
import json
import math
import os
import re
import sys
import time
import urllib.parse
import urllib.request

# Trail extents from App/Maps/TrailSystems.swift, read from the source so they stay in step.
src = open("App/Maps/TrailSystems.swift").read()
boxes = []
for m in re.finditer(r"trailheadLatitude: ([-\d.]+), trailheadLongitude: ([-\d.]+),\s*minLat: ([-\d.]+), maxLat: ([-\d.]+), minLon: ([-\d.]+), maxLon: ([-\d.]+)", src):
    tlat, tlon, s, n, w, e = map(float, m.groups())
    pad = 0.04
    boxes.append((min(s, tlat) - pad, min(w, tlon) - pad, max(n, tlat) + pad, max(e, tlon) + pad))
if not boxes:
    sys.exit("no trail systems found in TrailSystems.swift")

skip = "footway|path|cycleway|steps|pedestrian|bridleway|corridor|construction|proposed|platform|elevator|via_ferrata|bus_stop|raceway"
parts = "".join(f'way["highway"]["highway"!~"^({skip})$"]["name"]({s},{w},{n},{e});'
                f'way["highway"]["highway"!~"^({skip})$"]["ref"]({s},{w},{n},{e});' for s, w, n, e in boxes)
query = f"[out:json][timeout:180];({parts});out tags geom;"

servers = ["https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter",
           "https://maps.mail.ru/osm/tools/overpass/api/interpreter"]
data = None
for attempt in range(6):
    url = servers[attempt % len(servers)]
    try:
        req = urllib.request.Request(url, data=urllib.parse.urlencode({"data": query}).encode(),
                                     headers={"User-Agent": "TrailTracker road fetch (github.com/bowerman2018-collab/junglemachinetrack)"})
        with urllib.request.urlopen(req, timeout=240) as r:
            data = json.load(r)
        break
    except Exception as ex:  # noqa: BLE001
        print(f"{url}: {ex}", file=sys.stderr)
        time.sleep(10 * (attempt + 1))
if data is None:
    sys.exit("could not reach any Overpass server")


def meters(a, b):
    k = math.cos(math.radians(37.7))
    return math.hypot((a[0] - b[0]) * 111320 * k, (a[1] - b[1]) * 111320)


def seg_dist(p, a, b):
    k = math.cos(math.radians(37.7))
    ax, ay, bx, by, px, py = a[0] * k, a[1], b[0] * k, b[1], p[0] * k, p[1]
    dx, dy = bx - ax, by - ay
    t = 0 if dx == dy == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - ax - t * dx, py - ay - t * dy) * 111320


def simplify(pts, tol=6.0):
    if len(pts) < 3:
        return pts
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        i, j = stack.pop()
        best, idx = 0, -1
        for k in range(i + 1, j):
            d = seg_dist(pts[k], pts[i], pts[j])
            if d > best:
                best, idx = d, k
        if best > tol:
            keep[idx] = True
            stack += [(i, idx), (idx, j)]
    return [p for p, k in zip(pts, keep) if k]


roads = []
seen = set()
for el in data.get("elements", []):
    if el.get("type") != "way" or el["id"] in seen or "geometry" not in el:
        continue
    seen.add(el["id"])
    tags = el.get("tags", {})
    name = tags.get("name", "")
    # Some Hatfield-McCoy trails are also in OpenStreetMap as tracks ("BW-#10-EASY", "Rockhouse Trail 45").
    # The official trail map already has those, so leave them out rather than list them twice.
    if "#" in name or re.search(r"\btrail\s*\d", name, re.I) or tags.get("highway") == "track" and not tags.get("ref"):
        continue
    if set(name) <= set("? "):
        tags.pop("name", None)
        if not tags.get("ref"):
            continue
    pts = simplify([(g["lon"], g["lat"]) for g in el["geometry"]])
    if len(pts) < 2:
        continue
    road = {"n": tags.get("name", ""), "k": tags.get("highway", "")}
    if tags.get("ref"):
        road["r"] = tags["ref"]
    alt = [tags[k] for k in ("alt_name", "old_name", "official_name") if tags.get(k)]
    if alt:
        road["a"] = ";".join(alt)
    road["p"] = [round(v, 5) for p in pts for v in p]
    roads.append(road)

roads.sort(key=lambda r: (r["n"], r.get("r", "")))
out = {"source": "(c) OpenStreetMap contributors, ODbL", "fetched": time.strftime("%Y-%m-%d"), "roads": roads}
os.makedirs("App/Resources", exist_ok=True)
with open("App/Resources/Roads.json", "w") as f:
    json.dump(out, f, separators=(",", ":"))
names = {r["n"] or r.get("r") for r in roads}
print(f"{len(roads)} road pieces, {len(names)} distinct names")
