#!/usr/bin/env python3
"""
Packs Peter Bird's PB2002 plate-boundary model into the compact JSON the Kármán API serves at
/v1/plates (backend/internal/feeds/plates.json).

Source: Bird, P. (2003), An updated digital model of plate boundaries, G-cubed 4(3), 1027,
via Hugo Ahlenius / Nordpil (https://github.com/fraxen/tectonicplates), Open Data Commons
Attribution License 1.0.

Boundary steps are merged into polylines and grouped by motion:
  divergent  - spreading ridges (OSR) and continental rifts (CRB)
  convergent - subduction zones (SUB) and oceanic/continental collision zones (OCB, CCB)
  transform  - oceanic and continental transform faults (OTF, CTF)
Plate labels sit at the centre of each major plate's outline.

Usage: build_plates.py PB2002_steps.json PB2002_plates.json backend/internal/feeds/plates.json
"""
import json
import math
import sys

KIND = {"OSR": "divergent", "CRB": "divergent", "SUB": "convergent", "OCB": "convergent",
        "CCB": "convergent", "OTF": "transform", "CTF": "transform"}

# Plates big or famous enough to label on a whole-Earth view.
LABELS = {"AF": "African", "AN": "Antarctic", "SO": "Somali", "IN": "Indian", "AU": "Australian",
          "EU": "Eurasian", "NA": "North American", "SA": "South American", "NZ": "Nazca",
          "PA": "Pacific", "AR": "Arabian", "SU": "Sunda", "CA": "Caribbean", "CO": "Cocos",
          "JF": "Juan de Fuca", "PS": "Philippine Sea", "SC": "Scotia", "AT": "Anatolian",
          "OK": "Okhotsk", "AM": "Amur", "YA": "Yangtze"}

steps_path, plates_path, out_path = sys.argv[1:4]
steps = json.load(open(steps_path))["features"]

kinds = {"divergent": [], "convergent": [], "transform": []}
current, current_kind, current_bound = None, None, None
for f in steps:
    p = f["properties"]
    kind = KIND.get(p["STEPCLASS"])
    if kind is None:
        continue
    a = (round(p["STARTLONG"], 2), round(p["STARTLAT"], 2))
    b = (round(p["FINALLONG"], 2), round(p["FINALLAT"], 2))
    joined = (current is not None and kind == current_kind and p["PLATEBOUND"] == current_bound
              and abs(current[-1][0] - a[0]) < 0.011 and abs(current[-1][1] - a[1]) < 0.011)
    if joined:
        current.append(b)
    else:
        current = [a, b]
        current_kind, current_bound = kind, p["PLATEBOUND"]
        kinds[kind].append(current)

def flat(line):
    out = []
    for lon, lat in line:
        out += [lon, lat]
    return out

labels = []
for f in json.load(open(plates_path))["features"]:
    code = f["properties"].get("Code")
    if code not in LABELS or any(l["code"] == code for l in labels):
        continue
    g = f["geometry"]
    rings = [g["coordinates"][0]] if g["type"] == "Polygon" else [poly[0] for poly in g["coordinates"]]
    x = y = z = 0.0
    for ring in rings:
        for lon, lat in ring:
            la, lo = math.radians(lat), math.radians(lon)
            x += math.cos(la) * math.cos(lo)
            y += math.cos(la) * math.sin(lo)
            z += math.sin(la)
    n = math.sqrt(x * x + y * y + z * z) or 1
    labels.append({"code": code, "name": LABELS[code], "lat": round(math.degrees(math.asin(z / n)), 1),
                   "lon": round(math.degrees(math.atan2(y, x)), 1)})
# Hand-placed where the outline's centre falls off the plate or behind a neighbour's label.
for l in labels:
    if l["code"] == "PA":
        l["lat"], l["lon"] = -5.0, -145.0
    if l["code"] == "AN":
        l["lat"], l["lon"] = -78.0, 40.0
    if l["code"] == "EU":
        l["lat"], l["lon"] = 55.0, 60.0
    if l["code"] == "NA":
        l["lat"], l["lon"] = 48.0, -100.0
    if l["code"] == "AF":
        l["lat"], l["lon"] = 5.0, 20.0
    if l["code"] == "SA":
        l["lat"], l["lon"] = -12.0, -55.0

out = {
    "attribution": "Plate boundaries: P. Bird (2003), PB2002, via H. Ahlenius / Nordpil, ODC-By 1.0",
    "kinds": {k: [flat(line) for line in v] for k, v in kinds.items()},
    "plates": sorted(labels, key=lambda l: l["code"]),
}
json.dump(out, open(out_path, "w"), separators=(",", ":"))
print({k: (len(v), sum(len(l) for l in v)) for k, v in kinds.items()}, len(labels), "labels ->", out_path)
