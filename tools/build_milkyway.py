#!/usr/bin/env python3
"""
Paints the Milky Way backdrop (Karman/Resources/Textures/milkyway.jpg) procedurally, so it ships
without third-party imagery: star light from a disk and bulge model, dust as optical depth (the
mid-plane lane, the Great Rift, the Coalsack, the Ophiuchus and Taurus dark clouds), the bright
star clouds, emission nebulae, the Magellanic Clouds and Andromeda, all at their real galactic
coordinates.

Layout: equirectangular in galactic coordinates. Columns run from l = +180° at the left edge
through the galactic centre in the middle to l = -180° at the right (longitude increases to the
left, as on the sky); rows run from b = +45° at the top to b = -45° at the bottom. The globe's sky
pass (milkyway_fragment in Globe.metal) turns each view ray into (l, b) and samples it.

Usage: build_milkyway.py [width] [out.jpg]      (default 4096 -> Karman/Resources/Textures/milkyway.jpg)
Needs numpy and Pillow; deterministic, takes a few minutes at 4096.
"""
import os
import sys

import numpy as np
from PIL import Image

f32 = np.float32
W = int(sys.argv[1]) if len(sys.argv) > 1 else 4096
H = W // 4
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), "..", "Karman", "Resources", "Textures", "milkyway.jpg")
BMAX = np.radians(45.0)
DEG = f32(np.pi / 180)


# --- noise (3D value noise sampled on the unit sphere, so there is no seam) -------------------

def fract(x):
    return x - np.floor(x)


def mix(a, b, t):
    return a + (b - a) * t


def saturate(x):
    return np.clip(x, 0.0, 1.0)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def hash31(p):
    p = fract(p * f32(0.1031))
    d = (p * (p[..., ::-1] + f32(31.32))).sum(-1)
    p = p + d[..., None]
    return fract((p[..., 0] + p[..., 1]) * p[..., 2])


def noise3(p):
    i = np.floor(p)
    f = p - i
    u = f * f * (3.0 - 2.0 * f)

    def h(o):
        return hash31(i + np.array(o, dtype=f32))

    x00 = mix(h([0, 0, 0]), h([1, 0, 0]), u[..., 0])
    x10 = mix(h([0, 1, 0]), h([1, 1, 0]), u[..., 0])
    x01 = mix(h([0, 0, 1]), h([1, 0, 1]), u[..., 0])
    x11 = mix(h([0, 1, 1]), h([1, 1, 1]), u[..., 0])
    return mix(mix(x00, x10, u[..., 1]), mix(x01, x11, u[..., 1]), u[..., 2])


def fbm3(p, octaves=5):
    v = np.zeros(p.shape[:-1], dtype=f32)
    a, norm = f32(0.5), 0.0
    for _ in range(octaves):
        v += a * noise3(p)
        norm += a
        p = p * f32(2.02) + np.array([1.7, 9.2, 3.1], dtype=f32)
        a *= f32(0.5)
    return v / f32(norm)


def ridged(p, octaves=5):
    v = np.zeros(p.shape[:-1], dtype=f32)
    a, norm = f32(0.5), 0.0
    for _ in range(octaves):
        n = 1.0 - np.abs(2.0 * noise3(p) - 1.0)
        v += a * n * n
        norm += a
        p = p * f32(2.07) + np.array([3.1, 7.7, 1.3], dtype=f32)
        a *= f32(0.5)
    return v / f32(norm)


# --- sky grid ---------------------------------------------------------------------------------

xs = (np.arange(W, dtype=np.float64) + 0.5) / W
ys = (np.arange(H, dtype=np.float64) + 0.5) / H
L, B = np.meshgrid(np.pi - xs * 2 * np.pi, BMAX - ys * 2 * BMAX)
G = np.stack([np.cos(B) * np.cos(L), np.cos(B) * np.sin(L), np.sin(B)], -1).astype(f32)
l, b = L.astype(f32), B.astype(f32)


def gauss(v, s):
    return np.exp(-(v / s) ** 2)


def wrap(dl):
    return (dl + np.pi) % (2 * np.pi) - np.pi


def blob(lc, bc, rl, rb, angle=0.0):
    """An elliptical glow centred on (l, b) in degrees, radii in degrees, tilted by angle."""
    dl = wrap(l - lc * DEG) * np.cos(b)
    db = b - bc * DEG
    if angle:
        c, s = np.cos(np.radians(angle)), np.sin(np.radians(angle))
        dl, db = c * dl + s * db, -s * dl + c * db
    return np.exp(-(dl / (rl * DEG)) ** 2 - (db / (rb * DEG)) ** 2)


def along_l(lc, width):
    return np.exp(-(wrap(l - lc * DEG) / (width * DEG)) ** 2)


# A shared domain warp makes star clouds and dust look turbulent rather than tiled.
warp = np.stack([fbm3(G * f32(3.0) + off, 4) for off in (11.0, 37.0, 71.0)], -1) - 0.5
Gw = G + warp * f32(0.16)

# --- star light ---------------------------------------------------------------------------------

inner = gauss(wrap(l), 55 * DEG)                         # brighter toward the inner Galaxy
scale_h = (2.6 + 3.2 * inner) * DEG                      # apparent thickness of the disk
thin = np.exp(-(b / scale_h) ** 2)
halo = np.exp(-np.abs(b) / (scale_h * 1.7))
disk = 0.80 * thin + 0.20 * halo
along = (0.30 + 0.55 * inner
         + 0.55 * along_l(78, 12) + 0.30 * along_l(60, 10)       # Cygnus star cloud
         + 0.45 * along_l(27, 5)                                 # Scutum star cloud
         + 0.40 * along_l(-30, 9) + 0.42 * along_l(-52, 10)      # Norma, Centaurus
         + 0.45 * along_l(-72, 9) + 0.25 * along_l(-95, 14)      # Carina, Vela
         + 0.10 * along_l(130, 25) - 0.12 * along_l(180, 30))    # Cassiopeia-Perseus; the faint anticentre
along = np.maximum(along, 0.12)

clouds = fbm3(Gw * np.array([5.0, 5.0, 11.0], dtype=f32), 5)            # star-cloud patches
grain = fbm3(Gw * np.array([22.0, 22.0, 40.0], dtype=f32) + 5.0, 4)     # clumps
fine = fbm3(G * np.array([90.0, 90.0, 120.0], dtype=f32) + 17.0, 3)     # the grain of countless stars
patch = 0.30 + 1.6 * smoothstep(0.36, 0.74, clouds)
star_clouds = mix(np.full_like(patch, 0.8), patch, thin) * (0.75 + 0.55 * (grain - 0.5) + 0.6 * (fine - 0.5))

# The bulge: a boxy glow around the centre, brightest on its southern side (Baade's window).
bulge = (np.exp(-(wrap(l) / (10.5 * DEG)) ** 2 - (b / (7.5 * DEG)) ** 2) * 1.25
         + np.exp(-(wrap(l) / (22 * DEG)) ** 2 - (b / (13 * DEG)) ** 2) * 0.35
         + blob(1.5, -4.0, 6, 3.6) * 0.7)
star_cloud_glow = blob(4.0, -2.5, 5.5, 2.8) * 0.9 + blob(-4.0, -1.5, 4.0, 2.3) * 0.5 + blob(27.0, -2.5, 3.5, 2.6) * 0.8
light = (disk * along * star_clouds
         + bulge * (0.85 + 0.35 * grain + 0.35 * (fine - 0.5))
         + star_cloud_glow * (0.6 + 0.8 * clouds) * (0.8 + 0.6 * (fine - 0.5)))

# --- dust (optical depth) -----------------------------------------------------------------------

fil = ridged(Gw * np.array([9.0, 9.0, 22.0], dtype=f32) + 21.0, 5)
lump = fbm3(Gw * np.array([6.0, 6.0, 12.0], dtype=f32) + 63.0, 5)

# The mid-plane lane: wavy and thicker toward the inner Galaxy.
b0 = (0.5 + 1.2 * (lump - 0.5)) * DEG
plane_w = (0.9 + 1.4 * inner) * DEG
tau_plane = (0.6 + 1.6 * inner) * np.exp(-((b - b0) / plane_w) ** 2) * (0.35 + 1.1 * smoothstep(0.35, 0.65, fil))
# The Great Rift splits the band from Cygnus to Sagittarius.
rift_mask = smoothstep(95 * DEG, 70 * DEG, np.abs(wrap(l) - 45 * DEG)) * smoothstep(-20 * DEG, 5 * DEG, wrap(l))
tau_rift = 1.5 * rift_mask * np.exp(-((b - 1.6 * DEG - 1.2 * DEG * (lump - 0.5)) / (2.2 * DEG)) ** 2) * (0.45 + 0.9 * smoothstep(0.3, 0.7, fil))
# Dark clouds off the plane.
clumps = smoothstep(0.50, 0.78, lump) * (0.4 + 0.9 * fil)
tau_off = clumps * (gauss(b, 9 * DEG)
                    + blob(355, 15, 9, 7) * 1.6 + blob(2, 6, 7, 2.5, 25) * 1.6    # Ophiuchus, the Pipe
                    + blob(172, -15, 14, 8) * 1.4 + blob(340, 14, 8, 6) * 0.9       # Taurus, Lupus
                    + blob(300, -16, 6, 4) * 0.8 + blob(160, -18, 7, 4) * 0.6)      # Chamaeleon, Perseus
coalsack = blob(301.0, -1.0, 3.0, 2.4) * 2.0
tau = tau_plane + tau_rift + tau_off * 1.2 + coalsack
light = light * np.exp(-tau)

# --- colour -------------------------------------------------------------------------------------

warm = saturate(bulge * 1.1 + 0.35 * inner)
col = mix(np.array([0.72, 0.80, 1.0], dtype=f32), np.array([1.0, 0.80, 0.56], dtype=f32), warm[..., None])
img = col * light[..., None]
img = img * np.exp(-tau[..., None] * np.array([0.0, 0.18, 0.42], dtype=f32))   # dust reddens what it lets through

hii = np.array([1.0, 0.25, 0.38], dtype=f32)
for lc, bc, r, a in [(6.0, -1.2, 0.7, 1.2),       # Lagoon
                     (15.1, -0.7, 0.5, 0.8),      # Omega
                     (17.0, 0.8, 0.5, 0.7),       # Eagle
                     (287.6, -0.6, 1.3, 1.6),     # Carina
                     (85.5, -1.0, 1.6, 0.8),      # North America
                     (206.3, -2.1, 0.9, 0.6),     # Rosette
                     (134.7, 0.9, 1.4, 0.5),      # Heart and Soul
                     (209.0, -19.4, 0.8, 0.9),    # Orion
                     (160.4, -12.4, 1.5, 0.18),   # California
                     (351.0, 0.6, 1.0, 0.5),      # Cat's Paw
                     (333.0, -0.5, 0.8, 0.5)]:    # RCW 106
    shape = blob(lc, bc, r * 1.6, r * 1.3, 30) ** 0.8
    wisps = smoothstep(0.35, 0.8, fbm3(G * f32(60.0) + lc, 4))
    img += hii * (shape * a * 0.30 * (0.15 + 1.2 * wisps) * np.exp(-tau * 0.5))[..., None]
# Barnard's Loop around Orion, faint and broken.
dl = wrap(l - 207.5 * DEG) * np.cos(b)
db = b + 17.5 * DEG
ring = np.exp(-((np.sqrt(dl ** 2 + db ** 2) - 7.0 * DEG) / (0.9 * DEG)) ** 2) * smoothstep(-0.2, 0.6, -dl / (7 * DEG) + 0.2)
img += hii * (ring * 0.045 * smoothstep(0.4, 0.8, grain))[..., None]
# Rho Ophiuchi's golds and blues just above Antares.
img += np.array([1.0, 0.70, 0.35], dtype=f32) * (blob(351.9, 15.1, 1.8, 1.4) * 0.16 * (0.4 + grain))[..., None]
img += np.array([0.45, 0.6, 1.0], dtype=f32) * (blob(353.7, 17.7, 1.5, 1.1) * 0.13 * (0.4 + grain))[..., None]

# The Magellanic Clouds (the LMC with its bar and the Tarantula) and Andromeda.
knots = (0.45 + 0.9 * smoothstep(0.35, 0.72, grain)) * (0.8 + 0.6 * (fine - 0.5))
lmc = blob(280.47, -32.89, 4.2, 3.2, 20) * knots + blob(280.0, -33.0, 2.6, 0.9, -25) * 0.9 * (0.8 + 0.5 * (fine - 0.5))
smc = blob(302.81, -44.33, 2.2, 1.4, -30) * knots
img += np.array([0.84, 0.86, 1.0], dtype=f32) * (lmc * 0.55 + smc * 0.42)[..., None]
img += hii * (blob(279.47, -31.67, 0.5, 0.4) * 0.35 * (0.5 + grain))[..., None]
m31 = blob(121.17, -21.57, 1.5, 0.42, -35) * 0.55 + blob(121.17, -21.57, 0.35, 0.18, -35) * 0.8
img += np.array([1.0, 0.88, 0.72], dtype=f32) * m31[..., None]

# Unresolved stars: a fine speckle that thickens toward the plane (the app draws the named stars itself).
rng = np.random.default_rng(7)
density = saturate(disk * along * star_clouds * np.exp(-tau * 0.8) * 0.9 + bulge * 0.5 + 0.03)
specks = (rng.random((H, W)).astype(f32) < density * 0.02) * (0.2 + 0.8 * rng.random((H, W)).astype(f32) ** 4)
img += specks[..., None] * np.array([0.9, 0.93, 1.0], dtype=f32) * 0.6

# Fade toward the cropped edges, then scale so the brightest star clouds just reach white.
img *= smoothstep(45 * DEG, 37 * DEG, np.abs(b))[..., None]
img = np.clip(img / np.percentile(img.max(-1), 99.95), 0, 1)
srgb = np.where(img <= 0.0031308, img * 12.92, 1.055 * np.power(img, 1 / 2.4) - 0.055)
Image.fromarray((np.clip(srgb, 0, 1) * 255 + 0.5).astype(np.uint8)).save(OUT, "JPEG", quality=92, optimize=True, subsampling=0)
print("wrote", OUT, (W, H))
