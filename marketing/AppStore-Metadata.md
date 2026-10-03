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

**Promotional text (155/170):**
Live winds sweep the globe, seismic waves race from every quake and the Sky Lens names any star you point at. The whole planet, live, narrated by AI daily.

**Keywords (93/100):**
`earthquake,hurricane,wind,weather,iss,satellite,space weather,stars,planets,aurora,nasa,globe`

**Description (3113/4000):**

See the whole planet, live — the way astronauts do.

Kármán renders a cinematic, real-time Earth: city lights on the night side, a glowing atmosphere, real relief, 3D clouds that blush pink at sunset, the Moon at its true place and phase, and the Milky Way behind it all. On top of it, everything happening right now: earthquakes pulsing as they strike, hurricanes with their tracks, wildfires, volcanoes, the aurora from NOAA's live model, launches, and 11,000 satellites on their real orbits.

LIVE WEATHER, ALIVE
Thousands of glowing particles ride the real winds of NOAA's global forecast model. Paint the planet with temperature or rain, then press play to watch the next 24 hours unfold, daylight and all. Tap anywhere on Earth for its weather, local time and a one-day outlook.

WATCH THE WAVES
Pick any earthquake and watch its P, S and surface waves race across the planet. See when each reaches you, feel them arrive as haptics, and get the shaking you'd feel where you are.

A YEAR IN A MINUTE
Thousands of strong earthquakes from the past year flare up day by day until they draw the edges of the tectonic plates: the Ring of Fire, the Himalaya, the mid-ocean ridges.

SKY LENS
Point your iPhone at the sky to name every bright star, planet, constellation and the space stations. A finder arrow guides you to Jupiter, the ISS or a meteor shower's radiant. Red night-vision mode included.

TONIGHT'S SKY
An hour-by-hour stargazing score from cloud cover, darkness and moonlight; which planets are up and when; upcoming meteor showers with real rates for your location; space station passes on a sky dome; moonrise and twilight.

INSIDE THE EARTH
Slice the planet open like an orange: crust, a slowly churning mantle, the liquid outer core and a core as hot as the Sun's surface, each named with its depth and temperature.

THE SOLAR SYSTEM
All eight planets on their real orbits right now, with a time machine ten years either way. Tap one to see how far away it is, how long its light takes to reach you, and whether you can see it tonight.

RIDE WITH THE ISS
Fly with the International Space Station 400 km up as city lights, aurora and airglow slide by. Or pull back past the Moon's orbit.

PLANET BRIEFING
Press play and an AI narrator flies you around the globe through today's biggest stories.

ASK THE PLANET
"Why was there an earthquake near Japan?" The answer streams in while the globe flies there. Ask about any quake, storm or place straight from its card.

THE SUN, ALIVE
A six-hour time-lapse of the Sun, solar wind, flares, Kp and your aurora odds.

PEOPLE YOU CARE ABOUT
Watch up to five places, like family or a second home, for nearby earthquakes.

NIGHTSTAND GLOBE
A dimmed, slowly touring planet behind a big clock while your iPhone charges.

Plus widgets, Lock Screen launch countdowns, Siri shortcuts, a 24-hour replay, 500 m close-ups and shareable postcards.

ONE PURCHASE. EVERYTHING, FOREVER.
No subscriptions. No ads. No accounts. No tracking. Your precise location never leaves your iPhone.

Data: USGS, NOAA, NASA, MET Norway, CelesTrak, The Space Devs, PB2002 plate model.

**What's New (1.1, 927/4000):**
The biggest update yet.

• Live weather: wind particles, temperature and rain maps, and a 24-hour forecast player
• Tap anywhere on Earth for its weather, local time and outlook
• Watch seismic waves cross the planet from any earthquake, with arrival times and shaking where you are
• A year of earthquakes in under a minute, tracing the tectonic plates (new plate boundaries layer)
• Sky Lens: point your iPhone at the sky to name stars, planets, constellations and the ISS
• Tonight's Sky: stargazing score with cloud forecast, planets, meteor showers
• Ask Kármán flies the globe to its answers; ask about anything from its card
• Watched places for family and second homes
• Ambient nightstand globe
• Inside the Earth: slice the planet open to its core
• The Solar System: every planet on its real orbit, with a time machine
• The Milky Way, 3D clouds lit by the sunset, and the Moon in its true phase
• New Siri shortcuts

---

## Turkish listing

Removed: the app ships in English only. App Store Connect will show the English listing in every storefront, including Turkey.

---

## App Privacy ("nutrition label")

- **Tracking:** No.
- **Data Not Linked to You:**
  - Location → *Coarse Location* — App Functionality (alerts and watched places, only if the user enables them; the stargazing cloud forecast; all rounded to ~50 km).
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
> • Sky Lens (Tonight's Sky → Sky Lens) uses the motion sensors to label the sky. The camera is optional (camera button in the Sky Lens) and only shows the live view on screen; nothing is recorded or uploaded.
> • Weather layers (Layers → Live Weather) and the year of earthquakes (home carousel) load public NOAA/USGS data from our server.
