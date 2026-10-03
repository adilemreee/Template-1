# Kármán — App Store metadata

All fields are within App Store Connect limits (checked). Screenshots: `marketing/appstore/en/` (10 images, 1320×2868, 6.9" iPhone). App Preview: `marketing/app-preview/karman-preview-en-886x1920.mp4` (29.3 s, 886×1920, H.264 + AAC stereo, generative soundtrack): intro → riding with the ISS through an orbital sunrise → diving into New York at night → the 24-hour replay → a typhoon spiral.

## Business setup

| Field | Value |
|---|---|
| Price | **Paid up front — USD 9.99** (Apple generates local prices, ~₺ 449 in Turkey). No subscription, no IAP. |
| Primary category | Weather |
| Secondary category | Education |
| Age rating | 4+ |
| Bundle ID | `com.adilemre.karman` (widgets: `com.adilemre.karman.widgets`) |
| SKU | `karman-ios-1` |
| Copyright | © 2026 Adil Emre |
| Privacy Policy URL | `https://<your-domain>/karman/privacy` (see README → nginx snippet) |
| Support URL | `https://<your-domain>/karman/support` |
| Marketing URL (optional) | `https://<your-domain>/karman/` — the landing site in `marketing/site/` |

Why paid up front: the Top Paid chart only ranks paid downloads, and "one purchase, no subscription" is itself a selling point in 2026. AI cost is bounded: briefings are generated once per language per 3 hours and shared by everyone; Ask Kármán has a daily per-buyer quota (default 25, `KARMAN_ASK_DAILY_LIMIT`).

---

## English (primary)

**Name (18/30):** Kármán: Live Earth

**Subtitle (28/30):** Quakes, storms, aurora & ISS

**Promotional text (151/170):**
Ride with the ISS, rewind the last 24 hours and dive into any city at 500 m. The whole planet, live on a cinematic 3D Earth — narrated by AI every day.

**Keywords (93/100):**
`earthquake,hurricane,iss,satellite,space weather,typhoon,starlink,nasa,kp index,globe,volcano`

**Description:**

See the whole planet, live — the way astronauts do.

Kármán renders a cinematic, real-time Earth: city lights on the night side, a glowing atmosphere, real relief and clouds, the Sun rising over the limb. On top of it, everything that is happening right now: earthquakes pulsing as they strike, hurricanes and typhoons with their full tracks, wildfires, volcanoes, the aurora driven by NOAA's live model, rocket launches, and more than 11,000 satellites on their real orbits.

RIDE WITH THE ISS
Fly along with the International Space Station, 400 km up at 28,000 km/h. The camera chases the station over the curve of the Earth as city lights, aurora and the thin green airglow slide by — with a countdown to the next orbital sunrise.

REWIND THE PLANET
Replay the last 24 hours in half a minute: daylight sweeps round the globe, the stars wheel overhead and every earthquake ripples in where and when it happened.

DIVE INTO ANY CITY
Zoom in and NASA imagery streams in at 500 m: mountain ranges in shaded relief by day, and at night the street grids of light of New York, Istanbul or Tokyo.

PLANET BRIEFING — YOUR DAILY DOCUMENTARY
Press play and Kármán flies you around the globe. An AI narrator writes a short documentary from the latest data — the strongest earthquake, the storm to watch, tonight's aurora, the next launch — and reads it to you while the camera swoops in. Captions light up word by word over a generative ambient score.

FEEL EVERY EARTHQUAKE
Tap a quake to see its depth in a living cross-section of the crust, the energy it released, nearby aftershocks — and press "Feel it" to hold a haptic seismogram in your hand. Hurricanes and typhoons turn as living cloud spirals with their full tracks.

THE SUN, ALIVE
The last six hours of the Sun from the GOES-19 satellite as a time-lapse, solar wind speed and magnetic field, X-ray flares, the Kp index and a 3-day forecast. A polar map of the auroral oval shows where the northern and southern lights are glowing right now — and your own odds of seeing them.

TONIGHT'S SKY
Space station passes for exactly where you are, drawn on a sky dome, plus moonrise, the Moon's phase, golden hour and blue hour. Get a reminder before the station flies over.

YESTERDAY'S EARTH FROM ORBIT
Switch on NASA's daily satellite mosaic and wrap the globe in yesterday's real clouds, typhoons and smoke.

ASK THE PLANET
Ask anything — "Why was there an earthquake near Japan?", "Could I see the aurora tonight?" — and get a clear answer grounded in live data from USGS, NOAA and NASA.

ON YOUR HOME SCREEN
Earth Now, Aurora & Kp and Space Station widgets, including Lock Screen widgets. Rocket launch countdowns live on your Lock Screen and in the Dynamic Island. Optional alerts for nearby earthquakes, aurora, geomagnetic storms and launches. Add a Planet Briefing control to Control Center or the Action button, or ask Siri to "Ride with the ISS".

SHARE THE MOMENT
Turn the planet right now into a beautiful postcard — the live globe, the date and the day's numbers — and share it anywhere.

ONE PURCHASE. EVERYTHING, FOREVER.
No subscriptions. No ads. No accounts. No tracking. Your precise location never leaves your iPhone.

Data: USGS, NOAA Space Weather Prediction Center, NASA (EONET, GIBS, Visible Earth, NeoWs), CelesTrak, The Space Devs.

**What's New (1.0):**
The living planet, live. Welcome to Kármán.

---

## Turkish listing

Removed: the app ships in English only. App Store Connect will show the English listing in every storefront, including Turkey.

---

## App Privacy ("nutrition label")

- **Tracking:** No.
- **Data Not Linked to You:**
  - Location → *Coarse Location* — App Functionality (alerts, only if the user enables them; rounded to ~50 km).
  - User Content → *Other User Content* — App Functionality (questions sent to Ask Kármán).
- Everything else: not collected. Push tokens are used only to deliver chosen alerts.

Privacy policy (`/privacy`) and Support (`/support`, FAQ + optional contact address from `KARMAN_SUPPORT_EMAIL`) pages are served by the backend in EN + TR. App Store Connect needs public HTTPS URLs with a trusted certificate for both the **Privacy Policy URL** and the **Support URL** — host the same pages on your own domain (e.g. `https://adilemree.xyz/karman/privacy` and `/karman/support`) or GitHub Pages.

AI data sharing (Guideline 5.1.2(i)): before the first question, Ask Kármán shows a one-time consent screen naming Anthropic and exactly what is shared (the question and a location rounded to ~50 km). Nothing is sent until the user taps "Agree and continue"; Settings → Ask Kármán → "Share questions with Claude" withdraws consent. Planet Briefings send no personal data.

## App Review notes

> Kármán is a paid app with no account or login. All features work immediately.
> • The globe, Pulse, Space Weather and Tonight's Sky use public scientific data (USGS, NOAA, NASA, CelesTrak, The Space Devs) via our server.
> • Planet Briefing and Ask Kármán use Anthropic's Claude on our server. Access is authorised with StoreKit's signed AppTransaction (sandbox purchases are accepted), so they work in TestFlight and review builds.
> • Ask Kármán asks for explicit permission before the first question is shared with Anthropic (one-time screen; can be withdrawn in Settings → Ask Kármán). Briefings contain no personal data.
> • App Transport Security: a single exception (NSExceptionAllowsInsecureHTTPLoads) is scoped to our own API domain, karman.adilemree.xyz. The API uses a self-signed certificate that the app verifies by public-key pinning in code, which is stricter than CA validation. All other connections use default ATS.
> • Location is optional (Settings → Location → Choose a place). It is only used for "near you" features and alerts.
> • "Feel it" on an earthquake plays a haptic pattern; it requires a device with haptics.
