#!/usr/bin/env python3
"""
Packs the Yale Bright Star Catalogue (5th ed., public domain, via NASA ADC) into stars.bin.

Record layout (little endian, 20 bytes): float32 x, y, z (J2000 equatorial unit vector),
float32 visual magnitude, uint8 r, g, b, a (approximate blackbody colour).
Usage: build_stars.py bsc5-short.json out/stars.bin
"""
import json
import math
import struct
import sys


def parse_ra(s):
    h, m, sec = s.replace("h", "").replace("m", "").replace("s", "").split()
    return (float(h) + float(m) / 60 + float(sec) / 3600) * 15.0


def parse_dec(s):
    sign = -1.0 if s.strip().startswith("-") else 1.0
    parts = s.replace("+", "").replace("-", "").replace("°", " ").replace("′", " ").replace("″", " ").split()
    d, m, sec = (float(p) for p in (parts + ["0", "0"])[:3])
    return sign * (d + m / 60 + sec / 3600)


def kelvin_to_rgb(k):
    # Tanner Helland's fit, softened toward white so stars do not look cartoonish.
    t = k / 100.0
    if t <= 66:
        r = 255
        g = 99.4708025861 * math.log(t) - 161.1195681661
        b = 0 if t <= 19 else 138.5177312231 * math.log(t - 10) - 305.0447927307
    else:
        r = 329.698727446 * (t - 60) ** -0.1332047592
        g = 288.1221695283 * (t - 60) ** -0.0755148492
        b = 255
    rgb = [max(0, min(255, c)) for c in (r, g, b)]
    return [int(c * 0.65 + 255 * 0.35) for c in rgb]


stars = json.load(open(sys.argv[1]))
out = bytearray()
count = 0
for s in stars:
    try:
        ra = math.radians(parse_ra(s["RA"]))
        dec = math.radians(parse_dec(s["Dec"]))
        mag = float(s["V"])
        k = float(s.get("K") or 6500)
    except (KeyError, ValueError):
        continue
    x = math.cos(dec) * math.cos(ra)
    y = math.cos(dec) * math.sin(ra)
    z = math.sin(dec)
    r, g, b = kelvin_to_rgb(max(2000.0, min(k, 30000.0)))
    out += struct.pack("<ffff4B", x, y, z, mag, r, g, b, 255)
    count += 1

open(sys.argv[2], "wb").write(out)
print("packed", count, "stars ->", sys.argv[2], len(out), "bytes")
