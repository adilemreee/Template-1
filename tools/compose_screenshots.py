#!/usr/bin/env python3
"""
Composes App Store marketing screenshots (1320x2868, 6.9" iPhone) from raw simulator captures.
Usage: compose_screenshots.py <captures dir with en/> <output dir>
Renders HTML with headless Chrome so typography uses the system SF Pro faces.
"""
import base64
import html
import os
import subprocess
import sys
import tempfile

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
src, out = sys.argv[1], sys.argv[2]

SHOTS = [
    # (capture file, accent, headline, subline) — English only; the app ships in English.
    ("hero", "#7fd4ff",
     "The whole planet.<br>Live.", "Earthquakes, storms, wildfires, aurora and satellites — in real time on a cinematic 3D Earth."),
    ("ride", "#7fd4ff",
     "Ride with<br>the ISS.", "Fly 400 km up at 28,000 km/h, and watch the Sun rise every 92 minutes."),
    ("closeup", "#ffcf7a",
     "Dive into<br>any city.", "NASA imagery streams in at 500 m as you zoom — down to the street grids of light at night."),
    ("briefing_46", "#c9a8ff",
     "Your planet,<br>narrated.", "An AI-written documentary of what's happening right now — flown in 3D, with word-synced captions."),
    ("storm", "#c9a8ff",
     "Watch storms<br>breathe.", "Hurricanes and typhoons as living cloud spirals, with their tracks, wind speed and category."),
    ("space", "#ffb04a",
     "The Sun,<br>alive.", "Six hours of GOES-19 imagery as a time-lapse — plus solar wind, flares and your aurora odds."),
    ("replay", "#3dffa0",
     "Rewind<br>the planet.", "Replay the last 24 hours: daylight sweeps round the globe as every earthquake ripples in."),
    ("quake", "#ff5c33",
     "Feel every<br>earthquake.", "Depth, energy and aftershocks — plus a haptic seismogram you can feel in your hand."),
    ("sky", "#3dffa0",
     "Know when<br>to look up.", "Space station passes, moonrise and golden hour — computed for exactly where you are."),
    ("ask", "#3dffa0",
     "Ask the planet<br>anything.", "A planetary scientist that answers with live data from USGS, NOAA and NASA."),
]

TEMPLATE = """<!doctype html><html><head><meta charset="utf-8"><style>
html,body{{margin:0;padding:0;width:1320px;height:2868px;overflow:hidden;background:#02040a}}
body{{font-family:-apple-system,"SF Pro Display","Helvetica Neue",sans-serif;color:#fff;position:relative}}
.bg{{position:absolute;inset:0;background:
  radial-gradient(1200px 900px at 50% 108%, {accent}33, transparent 70%),
  radial-gradient(900px 700px at 85% 8%, {accent}22, transparent 70%),
  linear-gradient(180deg,#060a16 0%,#02040a 55%,#02030a 100%)}}
.stars{{position:absolute;inset:0;background-image:{stars};opacity:.7}}
.text{{position:absolute;top:150px;left:110px;right:110px}}
.eyebrow{{font-size:34px;letter-spacing:9px;font-weight:700;color:{accent};margin-bottom:26px;font-stretch:expanded}}
h1{{font-size:112px;line-height:1.02;margin:0;font-weight:800;letter-spacing:-2px}}
p{{font-size:44px;line-height:1.32;color:rgba(255,255,255,.66);margin:34px 0 0;font-weight:500;max-width:1080px}}
.device{{position:absolute;left:50%;transform:translateX(-50%);top:{device_top}px;width:1000px;height:2173px;border-radius:128px;
  background:#0b0d12;padding:22px;box-sizing:border-box;
  box-shadow:0 0 0 3px #2a2e38,0 0 0 9px #0a0b0f,0 60px 160px rgba(0,0,0,.7),0 0 220px {accent}2a}}
.screen{{width:100%;height:100%;border-radius:108px;overflow:hidden;background:#000}}
.screen img{{width:100%;height:100%;object-fit:cover;display:block}}
</style></head><body>
<div class="bg"></div><div class="stars"></div>
<div class="text"><div class="eyebrow">KÁRMÁN</div><h1>{headline}</h1><p>{sub}</p></div>
<div class="device"><div class="screen"><img src="data:image/png;base64,{img}"></div></div>
</body></html>"""


def star_layer():
    import random
    random.seed(11)
    dots = []
    for _ in range(90):
        x, y = random.randint(0, 1320), random.randint(0, 900)
        a = random.uniform(0.15, 0.7)
        s = random.choice([1, 1, 2])
        dots.append(f"radial-gradient({s}px {s}px at {x}px {y}px, rgba(255,255,255,{a:.2f}), transparent)")
    return ",".join(dots)


STARS = star_layer()


def render(lang, idx, shot):
    name, accent, headline, sub = shot
    path = os.path.join(src, lang, name + ".png")
    if not os.path.exists(path):
        print("missing", path)
        return
    img = base64.b64encode(open(path, "rb").read()).decode()
    two_lines = "<br>" in headline
    page = TEMPLATE.format(accent=accent, stars=STARS, headline=headline, sub=html.escape(sub),
                           img=img, device_top=650 if two_lines else 560)
    os.makedirs(os.path.join(out, lang), exist_ok=True)
    target = os.path.join(out, lang, f"{idx:02d}_{name.split('_')[0]}.png")
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
        f.write(page)
        html_path = f.name
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                    f"--screenshot={target}", "--window-size=1320,2868", f"file://{html_path}"],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.unlink(html_path)
    print("wrote", target)


for i, shot in enumerate(SHOTS, start=1):
    render("en", i, shot)
