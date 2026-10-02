#!/usr/bin/env python3
"""
Renders the Kármán app icon: sunrise over Earth's limb seen from orbit — the edge of space.
Usage: render_icon.py <repo root> [size]
Outputs AppIcon.png (light), AppIcon-Dark.png, AppIcon-Tinted.png and marketing/icon-1024.png.
"""
import sys
import numpy as np
from PIL import Image, ImageFilter

Image.MAX_IMAGE_PIXELS = None
root = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
SS = 2  # supersampling
W = N * SS

lights = np.asarray(Image.open(f"{root}/Karman/Resources/Textures/earth_lights.jpg").convert("L"), dtype=np.float32) / 255.0
day = np.asarray(Image.open(f"{root}/Karman/Resources/Textures/earth_day.jpg").convert("RGB").resize((4096, 2048)), dtype=np.float32) / 255.0
clouds = np.asarray(Image.open(f"{root}/Karman/Resources/Textures/earth_clouds.jpg").convert("L"), dtype=np.float32) / 255.0

ys, xs = np.mgrid[0:W, 0:W].astype(np.float32)
u = (xs + 0.5) / W * 2 - 1          # -1..1 left->right
v = 1 - (ys + 0.5) / W * 2          # -1..1 bottom->top

# Planet: a large disc whose limb arcs across the lower part of the icon.
R = 1.55
cx, cy = 0.0, -1.62
dx, dy = (u - cx) / R, (v - cy) / R
r2 = dx * dx + dy * dy
inside = r2 <= 1.0
r = np.sqrt(r2)

img = np.zeros((W, W, 3), dtype=np.float32)

# Space background: deep navy to black with a faint glow near the horizon.
space_top = np.array([0.0015, 0.002, 0.006])
space_bot = np.array([0.006, 0.012, 0.034])
t = np.clip((v + 1) / 2, 0, 1)[..., None]
img[:] = space_bot * (1 - t) + space_top * t

# Stars
rng = np.random.default_rng(7)
for _ in range(70):
    sx, sy = rng.uniform(-1, 1), rng.uniform(-0.25, 1)
    b = rng.uniform(0.1, 0.8) ** 3
    d2 = (u - sx) ** 2 + (v - sy) ** 2
    img += (np.exp(-d2 / (2 * (0.0035) ** 2)) * b)[..., None] * np.array([0.85, 0.9, 1.0])

# Surface: orthographic sphere seen from the night side, centred over the Mediterranean.
z = np.sqrt(np.clip(1 - r2, 0, 1))
nx, ny, nz = dx, dy, z
lat0, lon0 = np.radians(18.0), np.radians(30.0)
# rotate view-space normal into world (Y up, Z toward lat0/lon0)
cy0, sy0 = np.cos(lat0), np.sin(lat0)
wy = ny * cy0 + nz * sy0
wz = -ny * sy0 + nz * cy0
wx = nx
cl, sl = np.cos(lon0), np.sin(lon0)
fx = wx * cl + wz * sl
fz = -wx * sl + wz * cl
lat = np.degrees(np.arcsin(np.clip(wy, -1, 1)))
lon = np.degrees(np.arctan2(fx, fz))
tu = ((lon + 180) / 360 * lights.shape[1]).astype(np.int32) % lights.shape[1]
tv = np.clip(((90 - lat) / 180 * lights.shape[0]).astype(np.int32), 0, lights.shape[0] - 1)
lt = lights[tv, tu]
du = ((lon + 180) / 360 * day.shape[1]).astype(np.int32) % day.shape[1]
dv = np.clip(((90 - lat) / 180 * day.shape[0]).astype(np.int32), 0, day.shape[0] - 1)
albedo = day[dv, du] ** 2.2
cl_ = clouds[np.clip(((90 - lat) / 180 * clouds.shape[0]).astype(np.int32), 0, clouds.shape[0] - 1),
             ((lon + 180) / 360 * clouds.shape[1]).astype(np.int32) % clouds.shape[1]]

# Sun sits just above the limb at the top centre, behind the planet.
L = np.array([0.0, 0.16, -1.0])
L = L / np.linalg.norm(L)
ndl = nx * L[0] + ny * L[1] + nz * L[2]
daylit = np.clip((ndl + 0.10) / 0.25, 0, 1)
surface = albedo * (daylit * np.clip(ndl, 0, 1) * 2.0)[..., None]
surface += (np.clip(cl_ - 0.2, 0, 1) * daylit * 0.6)[..., None]
nightw = (1 - np.clip((ndl + 0.2) / 0.25, 0, 1))
surface += (lt ** 1.6 * 2.6 * nightw)[..., None] * np.array([1.0, 0.62, 0.28])
surface += albedo * 0.008  # moonlit
# rim haze on the surface near the limb
rim = (1 - z) ** 6
dist_sun = np.abs(u - 0.0)
warm = np.exp(-dist_sun / 0.35)
haze_col = np.stack([0.20 + 0.9 * warm, 0.45 + 0.35 * warm, 1.0 - 0.6 * warm], axis=-1)
surface = surface * (1 - rim[..., None] * 0.6) + haze_col * (rim * 0.75)[..., None]
img = np.where(inside[..., None], surface, img)

# Atmosphere outside the limb: thin bright band plus a soft halo.
d = (r - 1.0) * R  # distance from limb in image units
out = ~inside
band = np.exp(-np.clip(d, 0, None) / 0.007) * 2.6 + np.exp(-np.clip(d, 0, None) / 0.03) * 0.7 + np.exp(-np.clip(d, 0, None) / 0.13) * 0.16
ang = np.arctan2(dy, dx)  # angle around the planet centre
along = np.abs(ang - np.pi / 2)  # 0 at the top of the arc (under the sun)
warmth = np.exp(-along / 0.16)
blue = np.stack([0.22, 0.55, 1.0])
atm_col = blue * (1 - warmth[..., None]) + np.array([1.0, 0.62, 0.28]) * warmth[..., None]
lit = np.exp(-along / 0.9)
img += np.where(out[..., None], atm_col * (band * (0.35 + 0.65 * lit))[..., None], 0)

# The Sun: core, glow and rays at the limb.
sx, sy = 0.0, cy + R + 0.018
du_, dv_ = u - sx, v - sy
rr = np.sqrt(du_ ** 2 + dv_ ** 2)
theta = np.arctan2(dv_, du_)
core = np.exp(-(rr / 0.022) ** 2) * 9.0
glow = np.exp(-rr / 0.05) * 2.0 + np.exp(-rr / 0.2) * 0.42
rays = (np.abs(np.cos(theta * 4.0)) ** 160) * np.exp(-rr / 0.16) * 0.55 + (np.abs(np.cos(theta * 4.0 + np.pi / 8)) ** 220) * np.exp(-rr / 0.09) * 0.3
streak = np.exp(-(dv_ / 0.005) ** 2) * np.exp(-np.abs(du_) / 0.45) * 0.9
sun = (core + glow + rays + streak)[..., None] * np.array([1.0, 0.92, 0.80])
# The planet hides the lower half of the glow.
occl = np.where(inside, np.clip(1 - (1 - r) * 60, 0, 1), 1.0)
img += sun * occl[..., None]

# Tone map (ACES approx) and grade.
def aces(x):
    a, b, c, d_, e = 2.51, 0.03, 2.43, 0.59, 0.14
    return np.clip((x * (a * x + b)) / (x * (c * x + d_) + e), 0, 1)

img = aces(img * 1.05)
img = img ** (1 / 2.2)
# subtle vignette
vig = 1 - 0.25 * np.clip(np.sqrt(u ** 2 + v ** 2) - 0.6, 0, 1)
img *= vig[..., None]

out_img = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8), "RGB").resize((N, N), Image.LANCZOS)
icons = f"{root}/Karman/Resources/Assets.xcassets/AppIcon.appiconset"
out_img.save(f"{icons}/AppIcon.png")
out_img.save(f"{icons}/AppIcon-Dark.png")
gray = out_img.convert("L")
Image.merge("RGB", (gray, gray, gray)).save(f"{icons}/AppIcon-Tinted.png")
out_img.save(f"{root}/marketing/icon-1024.png")
print("icon written", N)
