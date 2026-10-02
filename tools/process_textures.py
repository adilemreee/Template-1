#!/usr/bin/env python3
"""
Builds the Earth texture set shipped with Kármán from NASA public-domain sources.

Sources (download into SRC dir first, see tools/README.md):
  day21600.jpg     Blue Marble Next Generation w/ topography & bathymetry, July 2004 (NASA Visible Earth #73751)
  plain5400.jpg    Blue Marble Next Generation, July 2004, flat oceans (NASA Visible Earth #74092) -> water mask
  night13500.jpg   Black Marble 2016, 3 km (NASA Earth Observatory #144898)
  clouds8192.tif   Blue Marble cloud composite (NASA Visible Earth #57747)
  elev21600.png    GEBCO 08 land elevation (NASA Visible Earth #73934)

Usage: process_textures.py <SRC dir> <OUT dir> [<WIDGET OUT dir>]
"""
import sys
import numpy as np
from PIL import Image, ImageFilter

Image.MAX_IMAGE_PIXELS = None
src, out = sys.argv[1], sys.argv[2]
widget_out = sys.argv[3] if len(sys.argv) > 3 else None


def save_jpeg(img, path, q):
    img.save(path, "JPEG", quality=q, optimize=True, progressive=False, subsampling=0)
    print("wrote", path, img.size, img.mode)


# Day ------------------------------------------------------------------------
day = Image.open(f"{src}/day21600.jpg").convert("RGB")
day8 = day.resize((8192, 4096), Image.LANCZOS)
save_jpeg(day8, f"{out}/earth_day.jpg", 88)

# Water mask -------------------------------------------------------------------
plain = np.asarray(Image.open(f"{src}/plain5400.jpg").convert("RGB")).astype(np.int32)
ocean = np.array([2, 5, 20])
dist = np.abs(plain - ocean).sum(axis=2)
mask = (dist < 18).astype(np.uint8) * 255
mask_img = Image.fromarray(mask, "L").resize((4096, 2048), Image.BILINEAR).filter(ImageFilter.GaussianBlur(0.8))
mask_img.save(f"{out}/earth_water.png", optimize=True)
print("wrote water mask", mask_img.size)

# Night lights -------------------------------------------------------------------
night = np.asarray(Image.open(f"{src}/night13500.jpg").convert("RGB").resize((4096, 2048), Image.LANCZOS)).astype(np.float32) / 255.0
r, g, b = night[..., 0], night[..., 1], night[..., 2]
# Background terrain in Black Marble is blue-grey; lights are white/sodium. Penalise blueness to drop the terrain.
base = np.minimum(r, g)
blueness = np.clip(b - base, 0, None)
warm = base - blueness * 1.5
lights = np.clip((warm - 0.06) / 0.70, 0, 1) ** 0.85
lights_img = Image.fromarray((lights * 255).astype(np.uint8), "L")
save_jpeg(lights_img, f"{out}/earth_lights.jpg", 90)

# Clouds -------------------------------------------------------------------------
clouds = Image.open(f"{src}/clouds8192.tif").convert("L").resize((4096, 2048), Image.LANCZOS)
save_jpeg(clouds, f"{out}/earth_clouds.jpg", 88)

# Relief normal map from elevation -----------------------------------------------
elev_img = Image.open(f"{src}/elev21600.png").convert("L").resize((4096, 2048), Image.BOX)
elev = np.asarray(elev_img).astype(np.float32) / 255.0
elev = np.asarray(Image.fromarray((elev * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.6))).astype(np.float32) / 255.0
h, w = elev.shape
# Gradient in texel space; x wraps around the antimeridian.
dx = (np.roll(elev, -1, axis=1) - np.roll(elev, 1, axis=1)) * 0.5
dy = np.zeros_like(elev)
dy[1:-1] = (elev[2:] - elev[:-2]) * 0.5
# Compensate longitudinal texel shrink toward the poles.
lat = (0.5 - (np.arange(h) + 0.5) / h) * np.pi
coslat = np.clip(np.cos(lat), 0.08, 1.0)[:, None]
strength = 26.0
nx = -dx * strength / coslat
ny = dy * strength
nz = np.ones_like(elev)
length = np.sqrt(nx * nx + ny * ny + nz * nz)
nx, ny, nz = nx / length, ny / length, nz / length
normal = np.stack([(nx * 0.5 + 0.5), (ny * 0.5 + 0.5), (nz * 0.5 + 0.5)], axis=2)
normal_img = Image.fromarray((normal * 255).astype(np.uint8), "RGB")
save_jpeg(normal_img, f"{out}/earth_normal.jpg", 90)

# Widget-sized maps -----------------------------------------------------------------
if widget_out:
    save_jpeg(day.resize((1024, 512), Image.LANCZOS), f"{widget_out}/widget_day.jpg", 86)
    save_jpeg(lights_img.resize((1024, 512), Image.LANCZOS), f"{widget_out}/widget_lights.jpg", 88)
