#!/usr/bin/env python3
"""Builds BundledMaps/maps.sqlite: USGS topo and satellite tiles (public domain) for every
Hatfield-McCoy trail system, so the maps ship inside the app.

Areas come from App/Maps/TrailSystems.swift so the app and the bundle always agree.
Run from the repo root: python3 scripts/build_map_bundle.py [max_zoom]
"""
import concurrent.futures as cf
import math
import os
import re
import sqlite3
import sys
import time
import urllib.request

MIN_ZOOM, MAX_ZOOM = 10, int(sys.argv[1]) if len(sys.argv) > 1 else 15
SOURCES = {
    "usgs-topo": "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}",
    "usgs-imagery": "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryTopo/MapServer/tile/{z}/{y}/{x}",
}
OUT = "BundledMaps/maps.sqlite"


def regions():
    src = open("App/Maps/TrailSystems.swift").read()
    margin = float(re.search(r"static let margin = ([\d.]+)", src).group(1))
    pattern = (r"trailheadLatitude: ([-\d.]+), trailheadLongitude: ([-\d.]+),\s*"
               r"minLat: ([-\d.]+), maxLat: ([-\d.]+), minLon: ([-\d.]+), maxLon: ([-\d.]+)")
    for tla, tlo, mnla, mxla, mnlo, mxlo in re.findall(pattern, src):
        tla, tlo, mnla, mxla, mnlo, mxlo = map(float, (tla, tlo, mnla, mxla, mnlo, mxlo))
        yield (min(mnla, tla) - margin, max(mxla, tla) + margin, min(mnlo, tlo) - margin, max(mxlo, tlo) + margin)


def tile_x(lon, z):
    return min(max(int((lon + 180) / 360 * 2 ** z), 0), 2 ** z - 1)


def tile_y(lat, z):
    r = math.radians(lat)
    return min(max(int((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * 2 ** z), 0), 2 ** z - 1)


def keys():
    seen = set()
    for south, north, west, east in regions():
        for z in range(MIN_ZOOM, MAX_ZOOM + 1):
            for x in range(tile_x(west, z), tile_x(east, z) + 1):
                for y in range(tile_y(north, z), tile_y(south, z) + 1):
                    seen.add((z, x, y))
    return sorted(seen)


def fetch(source, key):
    z, x, y = key
    url = SOURCES[source].format(z=z, x=x, y=y)
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "TrailTracker map bundle builder"})
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
                if r.status == 200 and data:
                    return source, key, data
        except Exception:
            time.sleep(2 * (attempt + 1))
    return source, key, None


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    db = sqlite3.connect(OUT)
    db.execute("CREATE TABLE IF NOT EXISTS tiles (source TEXT, z INTEGER, x INTEGER, y INTEGER, data BLOB, "
               "PRIMARY KEY (source, z, x, y)) WITHOUT ROWID")
    have = set(db.execute("SELECT source, z, x, y FROM tiles"))
    todo = [(s, k) for s in SOURCES for k in keys() if (s, *k) not in have]
    print(f"{len(have)} tiles already in bundle, {len(todo)} to fetch (zoom {MIN_ZOOM}-{MAX_ZOOM})", flush=True)
    failed = 0
    with cf.ThreadPoolExecutor(max_workers=8) as pool:
        for i, (source, key, data) in enumerate(pool.map(lambda t: fetch(*t), todo), 1):
            if data is None:
                failed += 1
            else:
                db.execute("INSERT OR REPLACE INTO tiles VALUES (?, ?, ?, ?, ?)", (source, *key, data))
            if i % 1000 == 0:
                db.commit()
                print(f"  {i}/{len(todo)}", flush=True)
    db.commit()
    db.execute("VACUUM")
    db.close()
    print(f"done: {os.path.getsize(OUT) / 1e6:.0f} MB, {failed} failed", flush=True)
    if failed > len(todo) * 0.02:
        sys.exit(f"too many failed tiles ({failed})")


if __name__ == "__main__":
    main()
