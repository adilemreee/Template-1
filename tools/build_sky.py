#!/usr/bin/env python3
"""
Packs constellation stick figures, label points and the brightest named stars into
Karman/Resources/Data/sky.json for Tonight's Sky and the Sky Lens.

Source: d3-celestial by Olaf Frohn (https://github.com/ofrohn/d3-celestial, BSD-3-Clause):
data/constellations.lines.json, data/constellations.json, data/stars.6.json, data/starnames.json.
Coordinates are J2000 right ascension and declination in degrees (RA 0–360).

Usage: build_sky.py <d3-celestial data dir> Karman/Resources/Data/sky.json
"""
import json
import os
import sys

src, out = sys.argv[1], sys.argv[2]


def ra360(lon):
    return round(lon % 360.0, 3)


lines = json.load(open(os.path.join(src, "constellations.lines.json")))["features"]
info = {f["id"]: f for f in json.load(open(os.path.join(src, "constellations.json")))["features"]}

constellations = []
serpens = 0
for f in lines:
    cid = f["id"]
    if cid == "Ser":
        # Serpens comes in two parts on either side of Ophiuchus.
        serpens += 1
        cid = "Ser1" if serpens == 1 else "Ser2"
    meta = info.get(f["id"], {})
    props = meta.get("properties", {})
    label = meta.get("geometry", {}).get("coordinates", [0, 0])
    polylines = []
    for line in f["geometry"]["coordinates"]:
        flat = []
        for lon, lat in line:
            flat += [ra360(lon), round(lat, 3)]
        polylines.append(flat)
    name = props.get("name") or cid          # IAU (Latin) name, e.g. Cygnus
    meaning = props.get("en") or ""          # English meaning, e.g. Swan
    name = {"Ser1": "Serpens Caput", "Ser2": "Serpens Cauda"}.get(cid, name)
    name, meaning = (" ".join(x.split()) for x in (name, meaning))  # thin spaces -> plain
    if cid in ("Ser1", "Ser2"):
        pts = [(fl[i], fl[i + 1]) for fl in polylines for i in range(0, len(fl), 2)]
        label = [sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts)]
    entry = {"id": cid, "name": name, "rank": int(props.get("rank", f["properties"].get("rank", 3))),
             "label": [ra360(label[0]), round(label[1], 3)], "lines": polylines}
    if meaning and meaning != name:
        entry["meaning"] = meaning
    constellations.append(entry)

names = json.load(open(os.path.join(src, "starnames.json")))
stars = []
for f in json.load(open(os.path.join(src, "stars.6.json")))["features"]:
    hip = str(f["id"])
    mag = f["properties"]["mag"]
    meta = names.get(hip, {})
    name = meta.get("name", "")
    if not name or mag > 2.6:
        continue
    lon, lat = f["geometry"]["coordinates"]
    stars.append({"name": name, "ra": ra360(lon), "dec": round(lat, 3), "mag": mag, "con": meta.get("c", "")})
stars.sort(key=lambda s: s["mag"])

json.dump({"attribution": "Constellation figures and star names: d3-celestial, (c) 2015 Olaf Frohn, BSD-3-Clause",
           "constellations": constellations, "stars": stars}, open(out, "w"), separators=(",", ":"), ensure_ascii=False)
print(len(constellations), "constellations,", len(stars), "named stars ->", out, os.path.getsize(out), "bytes")
