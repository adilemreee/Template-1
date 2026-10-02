package ai

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

// Template builds a deterministic briefing from the digest. It is used when no AI key is
// configured or the model is unavailable, so the experience never breaks.
func Template(d Digest, lang string) *Briefing {
	t := texts["en"]
	if tt, ok := texts[lang]; ok {
		t = tt
	} else {
		lang = "en"
	}
	b := &Briefing{Language: lang, Title: t.title, Signoff: t.signoff, GeneratedAt: time.Now().UTC(), Source: "template"}
	b.Dek = fmt.Sprintf(t.dek, d.QuakeStats.Last24hM25Plus, len(d.Storms), d.Fires.Active, d.Space.Kp)

	if len(d.Quakes) > 0 {
		q := d.Quakes[0]
		var mag, depth float64
		fmt.Sscanf(q.Details, "magnitude %f, depth %f km", &mag, &depth)
		ctx := t.quakeShallow
		switch {
		case depth >= 300:
			ctx = t.quakeDeep
		case depth >= 70:
			ctx = t.quakeMid
		}
		b.Scenes = append(b.Scenes, Scene{Focus: "quake", RefID: q.ID, Lat: q.Lat, Lon: q.Lon, AltitudeKm: 3800,
			Headline:  clip(fmt.Sprintf(t.quakeHeadline, mag, shortPlace(q.Title)), 48),
			Narration: fmt.Sprintf(t.quakeNarration, mag, nearPlace(q.Title, lang), t.when(q.When), depth) + " " + ctx})
	}
	if len(d.Storms) > 0 {
		s := d.Storms[0]
		var kts float64
		fmt.Sscanf(s.Details, "%f", &kts)
		n := fmt.Sprintf(t.stormNarration, s.Title)
		if kts > 0 {
			n = fmt.Sprintf(t.stormNarrationWind, s.Title, kts, kts*1.852)
		}
		b.Scenes = append(b.Scenes, Scene{Focus: "storm", RefID: s.ID, Lat: s.Lat, Lon: s.Lon, AltitudeKm: 6500,
			Headline: clip(s.Title, 48), Narration: n + " " + t.stormContext})
	}
	if len(d.Volcanoes) > 0 {
		v := d.Volcanoes[0]
		b.Scenes = append(b.Scenes, Scene{Focus: "volcano", RefID: v.ID, Lat: v.Lat, Lon: v.Lon, AltitudeKm: 3200,
			Headline: clip(v.Title, 48), Narration: fmt.Sprintf(t.volcanoNarration, v.Title)})
	}
	if d.Fires.Active > 0 && len(d.Fires.Notable) > 0 {
		f := d.Fires.Notable[0]
		b.Scenes = append(b.Scenes, Scene{Focus: "wildfire", RefID: f.ID, Lat: f.Lat, Lon: f.Lon, AltitudeKm: 4200,
			Headline: clip(fmt.Sprintf(t.fireHeadline, d.Fires.Active), 48), Narration: fmt.Sprintf(t.fireNarration, d.Fires.Active, f.Title)})
	}
	for _, item := range d.Space.Items {
		if item.ID != "aurora-north" {
			continue
		}
		var n, h string
		switch {
		case d.Space.GScale >= 1:
			h, n = fmt.Sprintf(t.auroraStormHeadline, d.Space.GScale), fmt.Sprintf(t.auroraStorm, d.Space.GScale, d.Space.Kp)
		case d.Space.Kp >= 4:
			h, n = t.auroraActiveHeadline, fmt.Sprintf(t.auroraActive, d.Space.Kp, d.Space.AuroraNorthMax)
		default:
			h, n = t.auroraQuietHeadline, fmt.Sprintf(t.auroraQuiet, d.Space.Kp, d.Space.WindSpeed)
		}
		b.Scenes = append(b.Scenes, Scene{Focus: "aurora", RefID: item.ID, Lat: item.Lat, Lon: item.Lon, AltitudeKm: 14000, Headline: clip(h, 48), Narration: n})
	}
	if len(d.Launches) > 0 {
		l := d.Launches[0]
		rocket := strings.SplitN(l.Details, " by ", 2)[0]
		b.Scenes = append(b.Scenes, Scene{Focus: "launch", RefID: l.ID, Lat: l.Lat, Lon: l.Lon, AltitudeKm: 6000,
			Headline: clip(fmt.Sprintf(t.launchHeadline, rocket), 48), Narration: fmt.Sprintf(t.launchNarration, l.Title, t.when(l.When))})
	}
	if len(d.Asteroids) > 0 {
		a := d.Asteroids[0]
		var ld float64
		fmt.Sscanf(a.Details, "misses Earth by %f", &ld)
		b.Scenes = append(b.Scenes, Scene{Focus: "asteroid", RefID: a.ID, Lat: 20, Lon: 0, AltitudeKm: 20000,
			Headline: clip(fmt.Sprintf(t.asteroidHeadline, a.Title), 48), Narration: fmt.Sprintf(t.asteroidNarration, a.Title, ld)})
	}
	if len(b.Scenes) < 3 {
		sunLat, sunLon := 0.0, 0.0
		for _, item := range d.Space.Items {
			if item.ID == "sun" {
				sunLat, sunLon = item.Lat, item.Lon
			}
		}
		b.Scenes = append(b.Scenes, Scene{Focus: "sun", RefID: "sun", Lat: sunLat, Lon: sunLon, AltitudeKm: 16000, Headline: t.quietHeadline, Narration: t.quietNarration})
	}
	b.ID = "tpl-" + lang + "-" + bucket(time.Now())
	if lang == "tr" {
		b.Dek = decimalComma(b.Dek)
		for i := range b.Scenes {
			b.Scenes[i].Narration = decimalComma(b.Scenes[i].Narration)
			b.Scenes[i].Headline = decimalComma(b.Scenes[i].Headline)
		}
	}
	return b
}

var decimalPoint = regexp.MustCompile(`(\d)\.(\d)`)

func decimalComma(s string) string { return decimalPoint.ReplaceAllString(s, "$1,$2") }

// nearPlace turns USGS "165 km SSE of Vilyuchinsk, Russia" into "Vilyuchinsk, Russia" for
// languages where the English distance phrase would read badly.
func nearPlace(p, lang string) string {
	if lang == "en" {
		return p
	}
	if i := strings.Index(p, " of "); i >= 0 {
		return p[i+4:]
	}
	return p
}

func clip(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return strings.TrimSpace(string(r[:n-1])) + "…"
}

func shortPlace(p string) string {
	if i := strings.LastIndex(p, ", "); i >= 0 {
		return p[i+2:]
	}
	if i := strings.Index(p, " of "); i >= 0 {
		return p[i+4:]
	}
	return p
}

type templateTexts struct {
	title, dek, signoff                              string
	quakeHeadline, quakeNarration                    string
	quakeShallow, quakeMid, quakeDeep                string
	stormNarration, stormNarrationWind, stormContext string
	volcanoNarration                                 string
	fireHeadline, fireNarration                      string
	auroraStormHeadline, auroraStorm                 string
	auroraActiveHeadline, auroraActive               string
	auroraQuietHeadline, auroraQuiet                 string
	launchHeadline, launchNarration                  string
	asteroidHeadline, asteroidNarration              string
	quietHeadline, quietNarration                    string
	when                                             func(string) string
}

var texts = map[string]templateTexts{
	"en": {
		title:                "The Planet, Right Now",
		dek:                  "%d earthquakes in the last day · %d active storms · %d wildfires tracked · Kp %.1f",
		signoff:              "That is the planet, right now. Kármán keeps watching.",
		quakeHeadline:        "Magnitude %.1f · %s",
		quakeNarration:       "A magnitude %.1f earthquake struck %s, %s, at a depth of %.0f kilometres.",
		quakeShallow:         "Shallow earthquakes like this one release their energy close to the surface, so they are felt most strongly.",
		quakeMid:             "At this intermediate depth, the shaking spreads out before it reaches the surface.",
		quakeDeep:            "This one came from deep inside a sinking tectonic plate, where shaking at the surface is usually gentle.",
		stormNarration:       "%s is being tracked over open water.",
		stormNarrationWind:   "%s is churning with sustained winds near %.0f knots, about %.0f kilometres per hour.",
		stormContext:         "Tropical cyclones draw their power from warm ocean water, releasing heat as towering thunderstorms around the eye.",
		volcanoNarration:     "%s is showing signs of activity. Volcanoes like this one are windows into the molten rock beneath the crust.",
		fireHeadline:         "%d wildfires tracked",
		fireNarration:        "Satellites are tracking %d active wildfires. One of the most recent is %s. From orbit, their smoke plumes can stretch for hundreds of kilometres.",
		auroraStormHeadline:  "G%d geomagnetic storm",
		auroraStorm:          "A G%d geomagnetic storm is underway, with the Kp index at %.1f. Charged particles from the Sun are lighting up the upper atmosphere, and the aurora may reach unusually low latitudes tonight.",
		auroraActiveHeadline: "Aurora is active",
		auroraActive:         "The magnetic field is unsettled, with Kp at %.1f. The northern oval peaks near %d percent, so skies under it may be glowing green right now.",
		auroraQuietHeadline:  "A calm magnetosphere",
		auroraQuiet:          "Space weather is calm. The Kp index sits at %.1f and the solar wind flows past Earth at about %.0f kilometres per second. Even so, faint aurora circles both poles.",
		launchHeadline:       "Next launch · %s",
		launchNarration:      "Next on the launch schedule: %s, %s.",
		asteroidHeadline:     "Asteroid %s",
		asteroidNarration:    "Asteroid %s is passing by at %.1f times the distance to the Moon. Close in cosmic terms, but entirely safe.",
		quietHeadline:        "A quiet planet",
		quietNarration:       "It is a quiet moment on Earth. The terminator line sweeps across the globe as it always does, carrying sunrise to one half of the world and night to the other.",
		when:                 func(s string) string { return s },
	},
	"tr": {
		title:                "Gezegen, Şu An",
		dek:                  "Son 24 saatte %d deprem · %d aktif fırtına · %d orman yangını · Kp %.1f",
		signoff:              "Gezegen şu an böyle. Kármán izlemeye devam ediyor.",
		quakeHeadline:        "%.1f büyüklüğünde · %s",
		quakeNarration:       "%.1f büyüklüğünde bir deprem %s yakınlarını sarstı. Deprem %s, %.0f kilometre derinlikte meydana geldi.",
		quakeShallow:         "Bu kadar sığ depremler enerjilerini yüzeye yakın açığa çıkarır, bu yüzden en güçlü şekilde hissedilirler.",
		quakeMid:             "Bu orta derinlikte sarsıntı, yüzeye ulaşana kadar geniş bir alana yayılır.",
		quakeDeep:            "Bu deprem, batmakta olan bir levhanın derinliklerinden geldi; böyle depremlerde yüzeydeki sarsıntı genellikle hafiftir.",
		stormNarration:       "%s açık denizde izleniyor.",
		stormNarrationWind:   "%s, saatte yaklaşık %.0f deniz mili, yani %.0f kilometre hızındaki rüzgârlarla dönüyor.",
		stormContext:         "Tropikal siklonlar güçlerini sıcak okyanus suyundan alır ve bu ısıyı gözün etrafındaki dev fırtına bulutlarıyla açığa çıkarır.",
		volcanoNarration:     "%s hareketlilik gösteriyor. Bu tür volkanlar, yer kabuğunun altındaki erimiş kayaya açılan pencerelerdir.",
		fireHeadline:         "%d orman yangını izleniyor",
		fireNarration:        "Uydular şu anda %d aktif orman yangınını izliyor. En yenilerinden biri: %s. Yörüngeden bakıldığında duman bulutları yüzlerce kilometre uzanabiliyor.",
		auroraStormHeadline:  "G%d jeomanyetik fırtına",
		auroraStorm:          "G%d seviyesinde bir jeomanyetik fırtına sürüyor, Kp indeksi %.1f. Güneş'ten gelen yüklü parçacıklar üst atmosferi aydınlatıyor; kutup ışıkları bu gece alışılmadık derecede güneyden görülebilir.",
		auroraActiveHeadline: "Kutup ışıkları aktif",
		auroraActive:         "Manyetik alan hareketli, Kp %.1f. Kuzey ovalinde olasılık yüzde %d'ye ulaşıyor; altındaki gökyüzü şu anda yeşil parlıyor olabilir.",
		auroraQuietHeadline:  "Sakin bir manyetosfer",
		auroraQuiet:          "Uzay havası sakin. Kp indeksi %.1f ve güneş rüzgârı Dünya'nın yanından saniyede yaklaşık %.0f kilometre hızla akıyor. Yine de iki kutbun çevresinde soluk bir aurora halkası var.",
		launchHeadline:       "Sıradaki fırlatma · %s",
		launchNarration:      "Fırlatma takviminde sırada: %s, %s.",
		asteroidHeadline:     "Asteroit %s",
		asteroidNarration:    "%s adlı asteroit, Ay'a olan uzaklığın %.1f katı mesafeden geçiyor. Kozmik ölçekte yakın, ama tamamen güvenli.",
		quietHeadline:        "Sakin bir gezegen",
		quietNarration:       "Dünya'da sakin bir an. Gece ile gündüzü ayıran çizgi her zamanki gibi gezegeni dolaşıyor; dünyanın bir yarısına gün doğumunu, diğerine geceyi taşıyor.",
		when:                 trWhen,
	},
}

// trWhen converts "5 h ago" / "in 3 h" style strings from the digest into Turkish.
func trWhen(s string) string {
	r := strings.NewReplacer(" ago", " önce", "just now", "az önce", " minutes", " dakika", " minute", " dakika", " hours", " saat", " hour", " saat", " days", " gün", " day", " gün")
	out := r.Replace(s)
	if strings.HasPrefix(out, "in ") {
		out = strings.TrimPrefix(out, "in ") + " sonra"
	}
	return out
}
