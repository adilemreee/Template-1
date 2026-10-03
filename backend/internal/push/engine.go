package push

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"sync"
	"time"

	"karman/internal/ai"
	"karman/internal/feeds"
	"karman/internal/planet"
	"karman/internal/store"
)

// Engine watches the hub and sends at most one push per device per event.
type Engine struct {
	log   *slog.Logger
	hub   *feeds.Hub
	store *store.Store
	apns  *Client

	mu         sync.Mutex
	seenQuakes map[string]bool
	seeded     bool
}

func NewEngine(log *slog.Logger, hub *feeds.Hub, st *store.Store, apns *Client) *Engine {
	return &Engine{log: log, hub: hub, store: st, apns: apns, seenQuakes: map[string]bool{}}
}

func (e *Engine) Start(ctx context.Context) {
	if e.apns == nil {
		e.log.Info("push disabled: APNs key not configured")
		return
	}
	e.hub.OnChange(func(c feeds.Change) {
		switch c {
		case feeds.ChangeQuakes:
			e.checkQuakes(ctx)
		case feeds.ChangeAurora, feeds.ChangeSpace:
			e.checkAurora(ctx)
		}
	})
	go func() {
		t := time.NewTicker(time.Minute)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				e.checkLaunches(ctx)
			}
		}
	}()
	go func() {
		t := time.NewTicker(6 * time.Hour)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				e.store.PruneSent(14 * 24 * time.Hour)
			}
		}
	}()
}

func (e *Engine) send(ctx context.Context, d store.Device, key string, n Notification) {
	ok, err := e.store.MarkSent(d.Token, key)
	if err != nil || !ok {
		return
	}
	n.DeviceToken = d.Token
	n.Sandbox = d.Env == "sandbox"
	if err := e.apns.Send(ctx, n); err != nil {
		if errors.Is(err, ErrUnregistered) {
			_ = e.store.DeleteDevice(d.Token)
			return
		}
		e.log.Warn("push failed", "key", key, "err", err)
	}
}

// ---- earthquakes ------------------------------------------------------------------------

func (e *Engine) checkQuakes(ctx context.Context) {
	snap := e.hub.Current()
	e.mu.Lock()
	var fresh []planet.Quake
	for _, q := range snap.Quakes {
		if e.seenQuakes[q.ID] {
			continue
		}
		e.seenQuakes[q.ID] = true
		if e.seeded && time.Since(q.Time) < 90*time.Minute {
			fresh = append(fresh, q)
		}
	}
	e.seeded = true
	e.mu.Unlock()
	if len(fresh) == 0 {
		return
	}
	devices, err := e.store.Devices()
	if err != nil {
		return
	}
	for _, q := range fresh {
		for _, d := range devices {
			t := strings(d.Language)
			if d.Prefs.GlobalMajor && q.Mag >= 7.0 {
				e.send(ctx, d, "q:"+q.ID, Notification{
					Title: fmt.Sprintf(t.majorTitle, q.Mag), Body: q.Place, ThreadID: "quakes", Critical: true, CollapseID: q.ID,
					Data: map[string]any{"kind": "quake", "id": q.ID, "lat": q.Lat, "lon": q.Lon},
				})
				continue
			}
			if d.Prefs.QuakeMinMag <= 0 || q.Mag < d.Prefs.QuakeMinMag {
				continue
			}
			if d.Lat != nil && d.Lon != nil {
				if dist := haversineKm(*d.Lat, *d.Lon, q.Lat, q.Lon); dist <= d.Prefs.QuakeRadiusKm {
					e.send(ctx, d, "q:"+q.ID, Notification{
						Title: fmt.Sprintf(t.nearTitle, q.Mag), Subtitle: fmt.Sprintf(t.nearSubtitle, dist), Body: q.Place,
						ThreadID: "quakes", Critical: q.Mag >= 5.5, CollapseID: q.ID,
						Data: map[string]any{"kind": "quake", "id": q.ID, "lat": q.Lat, "lon": q.Lon},
					})
					continue
				}
			}
			// The places the user watches: the closest one inside the alert radius speaks.
			if p, dist, ok := nearestPlace(d.Places, q.Lat, q.Lon, d.Prefs.QuakeRadiusKm); ok {
				e.send(ctx, d, "q:"+q.ID, Notification{
					Title: fmt.Sprintf(t.placeTitle, p.Name, q.Mag), Subtitle: fmt.Sprintf(t.placeSubtitle, dist, p.Name), Body: q.Place,
					ThreadID: "quakes", Critical: q.Mag >= 6, CollapseID: q.ID,
					Data: map[string]any{"kind": "quake", "id": q.ID, "lat": q.Lat, "lon": q.Lon},
				})
			}
		}
	}
}

// ---- aurora & geomagnetic storms ---------------------------------------------------------

func (e *Engine) checkAurora(ctx context.Context) {
	snap := e.hub.Current()
	if snap.Aurora == nil {
		return
	}
	grid, err := base64.StdEncoding.DecodeString(snap.Aurora.Grid)
	if err != nil || len(grid) != snap.Aurora.GridWidth*snap.Aurora.GridHeight {
		return
	}
	devices, err := e.store.Devices()
	if err != nil {
		return
	}
	now := time.Now().UTC()
	sunLat, sunLon := ai.SubsolarPoint(now)
	g := 0
	if snap.Space != nil {
		g = snap.Space.GScale
	}
	for _, d := range devices {
		t := strings(d.Language)
		localDay := now.Add(time.Duration(d.TZOffset) * time.Minute).Add(-12 * time.Hour).Format("2006-01-02") // one "night" key
		if d.Prefs.SpaceStorms && g >= 3 {
			e.send(ctx, d, fmt.Sprintf("g:%s:%d", localDay, g), Notification{
				Title: fmt.Sprintf(t.stormTitle, g), Body: t.stormBody, ThreadID: "space", CollapseID: "gstorm",
				Data: map[string]any{"kind": "space"},
			})
		}
		if !d.Prefs.Aurora || d.Lat == nil || d.Lon == nil {
			continue
		}
		if sunAltitude(*d.Lat, *d.Lon, sunLat, sunLon) > -8 {
			continue // aurora is only worth a ping in the dark
		}
		chance := VisibleAuroraChance(grid, snap.Aurora.GridWidth, *d.Lat, *d.Lon)
		if chance < max(5, d.Prefs.AuroraMinChance) {
			continue
		}
		e.send(ctx, d, "a:"+localDay, Notification{
			Title: t.auroraTitle, Body: fmt.Sprintf(t.auroraBody, chance), ThreadID: "aurora", Critical: true, CollapseID: "aurora",
			Data: map[string]any{"kind": "aurora", "lat": *d.Lat, "lon": *d.Lon},
		})
	}
}

// VisibleAuroraChance estimates the chance of seeing aurora from a location: the oval can be
// seen low on the poleward horizon from up to ~1000 km away.
func VisibleAuroraChance(grid []byte, width int, lat, lon float64) int {
	best := 0.0
	for dLat := -10; dLat <= 10; dLat++ {
		la := int(math.Round(lat)) + dLat
		if la < -90 || la > 90 {
			continue
		}
		for dLon := -20; dLon <= 20; dLon++ {
			lo := ((int(math.Round(lon))+dLon)%360 + 360) % 360
			p := float64(grid[(la+90)*width+lo])
			if p == 0 {
				continue
			}
			dist := haversineKm(lat, lon, float64(la), float64(lo))
			if dist > 1000 {
				continue
			}
			best = math.Max(best, p*(1-dist/1150))
		}
	}
	return int(math.Round(best))
}

// ---- launches ------------------------------------------------------------------------------

func (e *Engine) checkLaunches(ctx context.Context) {
	snap := e.hub.Current()
	now := time.Now().UTC()
	var soon []planet.Launch
	for _, l := range snap.Launches {
		until := l.NET.Sub(now)
		if until > 25*time.Minute && until <= 35*time.Minute && l.StatusAbbrev == "Go" {
			soon = append(soon, l)
		}
	}
	if len(soon) == 0 {
		return
	}
	devices, err := e.store.Devices()
	if err != nil {
		return
	}
	for _, l := range soon {
		for _, d := range devices {
			if !d.Prefs.Launches {
				continue
			}
			t := strings(d.Language)
			e.send(ctx, d, "l:"+l.ID, Notification{
				Title: fmt.Sprintf(t.launchTitle, l.Rocket), Body: fmt.Sprintf(t.launchBody, l.Name, l.Location), ThreadID: "launches", CollapseID: l.ID,
				Data: map[string]any{"kind": "launch", "id": l.ID, "lat": l.Lat, "lon": l.Lon},
			})
		}
	}
}

// ---- geometry & copy ---------------------------------------------------------------------------

func haversineKm(lat1, lon1, lat2, lon2 float64) float64 {
	const r = 6371.0
	p1, p2 := lat1*math.Pi/180, lat2*math.Pi/180
	dp, dl := (lat2-lat1)*math.Pi/180, (lon2-lon1)*math.Pi/180
	a := math.Sin(dp/2)*math.Sin(dp/2) + math.Cos(p1)*math.Cos(p2)*math.Sin(dl/2)*math.Sin(dl/2)
	return 2 * r * math.Asin(math.Min(1, math.Sqrt(a)))
}

// nearestPlace finds the closest watched place within radiusKm of a point.
func nearestPlace(places []store.Place, lat, lon, radiusKm float64) (store.Place, float64, bool) {
	var best store.Place
	bestDist := math.Inf(1)
	for _, p := range places {
		if d := haversineKm(p.Lat, p.Lon, lat, lon); d <= radiusKm && d < bestDist {
			best, bestDist = p, d
		}
	}
	return best, bestDist, !math.IsInf(bestDist, 1)
}

func sunAltitude(lat, lon, sunLat, sunLon float64) float64 {
	ang := haversineKm(lat, lon, sunLat, sunLon) / 6371.0 * 180 / math.Pi
	return 90 - ang
}

type copyText struct {
	majorTitle, nearTitle, nearSubtitle string
	placeTitle, placeSubtitle           string
	stormTitle, stormBody               string
	auroraTitle, auroraBody             string
	launchTitle, launchBody             string
}

func strings(lang string) copyText {
	if lang == "tr" {
		return copyText{
			majorTitle: "Büyük deprem · %.1f", nearTitle: "Yakınında deprem · %.1f", nearSubtitle: "Sana yaklaşık %.0f km uzaklıkta",
			placeTitle: "%s yakınında deprem · %.1f", placeSubtitle: "Yaklaşık %.0f km uzakta: %s",
			stormTitle: "G%d jeomanyetik fırtına", stormBody: "Güçlü bir uzay havası olayı sürüyor. Kutup ışıkları alışılmadık enlemlerde görülebilir.",
			auroraTitle: "Bu gece kutup ışıkları olabilir", auroraBody: "Konumundan görülme ihtimali yaklaşık %%%d. Karanlık bir yere geç ve kuzeye bak.",
			launchTitle: "%s 30 dakika içinde fırlatılıyor", launchBody: "%s · %s",
		}
	}
	return copyText{
		majorTitle: "Major earthquake · M%.1f", nearTitle: "Earthquake near you · M%.1f", nearSubtitle: "About %.0f km from you",
		placeTitle: "Earthquake near %s · M%.1f", placeSubtitle: "About %.0f km from %s",
		stormTitle: "G%d geomagnetic storm", stormBody: "A strong space-weather event is underway. Aurora may reach unusual latitudes.",
		auroraTitle: "Aurora possible tonight", auroraBody: "About %d%% chance from your location. Find a dark spot and look toward the pole.",
		launchTitle: "%s lifts off in 30 minutes", launchBody: "%s · %s",
	}
}
