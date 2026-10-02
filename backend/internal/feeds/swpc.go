package feeds

import (
	"context"
	"encoding/base64"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strings"
	"time"

	"karman/internal/planet"
)

const swpc = "https://services.swpc.noaa.gov"

func parseSWPCTime(s string) time.Time {
	s = strings.TrimSpace(s)
	for _, layout := range []string{time.RFC3339, "2006-01-02T15:04:05", "2006-01-02 15:04:05.000", "2006-01-02 15:04:05", "2006-01-02T15:04Z"} {
		if t, err := time.Parse(layout, s); err == nil {
			return t.UTC()
		}
	}
	return time.Time{}
}

// ---- Kp index ---------------------------------------------------------------------

func (h *Hub) pollKp(ctx context.Context) error {
	var observed []struct {
		TimeTag string  `json:"time_tag"`
		Kp      float64 `json:"Kp"`
	}
	if err := h.getJSON(ctx, swpc+"/products/noaa-planetary-k-index.json", &observed); err != nil {
		return err
	}
	var forecast []struct {
		TimeTag  string  `json:"time_tag"`
		Kp       float64 `json:"kp"`
		Observed string  `json:"observed"`
	}
	_ = h.getJSON(ctx, swpc+"/products/noaa-planetary-k-index-forecast.json", &forecast)
	var minute []struct {
		TimeTag     string  `json:"time_tag"`
		EstimatedKp float64 `json:"estimated_kp"`
	}
	_ = h.getJSON(ctx, swpc+"/json/planetary_k_index_1m.json", &minute)

	if len(observed) == 0 {
		return errNoData
	}
	history := make([]planet.Sample, 0, len(observed))
	for _, o := range observed {
		if t := parseSWPCTime(o.TimeTag); !t.IsZero() {
			history = append(history, planet.Sample{T: t, V: round(o.Kp, 2)})
		}
	}
	var fc []planet.Sample
	now := time.Now().UTC()
	for _, f := range forecast {
		t := parseSWPCTime(f.TimeTag)
		if t.IsZero() || f.Observed == "observed" || t.Before(now.Add(-3*time.Hour)) {
			continue
		}
		fc = append(fc, planet.Sample{T: t, V: round(f.Kp, 2)})
	}
	last := history[len(history)-1]
	estimated := last.V
	if n := len(minute); n > 0 {
		estimated = round(minute[n-1].EstimatedKp, 2)
	}

	h.mu.Lock()
	h.space.Kp = last.V
	h.space.KpTime = last.T
	h.space.KpEstimated = estimated
	h.space.GScale = gScale(math.Max(last.V, estimated))
	h.space.KpHistory = history
	h.space.KpForecast = fc
	h.mu.Unlock()
	h.touch()
	h.notify(ChangeSpace)
	return nil
}

func gScale(kp float64) int {
	switch {
	case kp >= 9:
		return 5
	case kp >= 8:
		return 4
	case kp >= 7:
		return 3
	case kp >= 6:
		return 2
	case kp >= 5:
		return 1
	}
	return 0
}

// ---- Real-time solar wind ---------------------------------------------------------------

type rtswWind struct {
	TimeTag string   `json:"time_tag"`
	Active  bool     `json:"active"`
	Speed   *float64 `json:"proton_speed"`
	Density *float64 `json:"proton_density"`
}

type rtswMag struct {
	TimeTag string   `json:"time_tag"`
	Active  bool     `json:"active"`
	Bt      *float64 `json:"bt"`
	BzGSM   *float64 `json:"bz_gsm"`
}

func (h *Hub) pollWind(ctx context.Context) error {
	var wind []rtswWind
	if err := h.getJSON(ctx, swpc+"/json/rtsw/rtsw_wind_1m.json", &wind); err != nil {
		return err
	}
	var mag []rtswMag
	_ = h.getJSON(ctx, swpc+"/json/rtsw/rtsw_mag_1m.json", &mag)

	// Newest first in the feed; keep the active spacecraft only and bucket to 10 minutes.
	speedBuckets := map[int64][]float64{}
	var latestSpeed, latestDensity float64
	var latestT time.Time
	for _, w := range wind {
		if !w.Active || w.Speed == nil {
			continue
		}
		t := parseSWPCTime(w.TimeTag)
		if t.IsZero() {
			continue
		}
		if t.After(latestT) {
			latestT, latestSpeed = t, *w.Speed
			if w.Density != nil {
				latestDensity = *w.Density
			}
		}
		k := t.Truncate(10 * time.Minute).Unix()
		speedBuckets[k] = append(speedBuckets[k], *w.Speed)
	}
	if latestT.IsZero() {
		return errNoData
	}
	bzBuckets := map[int64][]float64{}
	var latestBz, latestBt float64
	var latestMagT time.Time
	for _, m := range mag {
		if !m.Active || m.BzGSM == nil {
			continue
		}
		t := parseSWPCTime(m.TimeTag)
		if t.IsZero() {
			continue
		}
		if t.After(latestMagT) {
			latestMagT, latestBz = t, *m.BzGSM
			if m.Bt != nil {
				latestBt = *m.Bt
			}
		}
		k := t.Truncate(10 * time.Minute).Unix()
		bzBuckets[k] = append(bzBuckets[k], *m.BzGSM)
	}

	h.mu.Lock()
	h.space.WindSpeed = round(latestSpeed, 0)
	h.space.WindDensity = round(latestDensity, 2)
	h.space.Bz = round(latestBz, 2)
	h.space.Bt = round(latestBt, 2)
	h.space.WindTime = latestT
	h.space.WindHistory = bucketsToSamples(speedBuckets, 0)
	h.space.BzHistory = bucketsToSamples(bzBuckets, 2)
	h.mu.Unlock()
	h.touch()
	h.notify(ChangeSpace)
	return nil
}

func bucketsToSamples(b map[int64][]float64, places int) []planet.Sample {
	out := make([]planet.Sample, 0, len(b))
	for k, vs := range b {
		sum := 0.0
		for _, v := range vs {
			sum += v
		}
		out = append(out, planet.Sample{T: time.Unix(k, 0).UTC(), V: round(sum/float64(len(vs)), places)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].T.Before(out[j].T) })
	return out
}

// ---- GOES X-ray flux & flares -------------------------------------------------------------

func (h *Hub) pollXray(ctx context.Context) error {
	var xr []struct {
		TimeTag string  `json:"time_tag"`
		Flux    float64 `json:"flux"`
		Energy  string  `json:"energy"`
	}
	if err := h.getJSON(ctx, swpc+"/json/goes/primary/xrays-1-day.json", &xr); err != nil {
		return err
	}
	buckets := map[int64][]float64{}
	var latest float64
	var latestT time.Time
	for _, x := range xr {
		if x.Energy != "0.1-0.8nm" || x.Flux <= 0 {
			continue
		}
		t := parseSWPCTime(x.TimeTag)
		if t.IsZero() {
			continue
		}
		if t.After(latestT) {
			latestT, latest = t, x.Flux
		}
		k := t.Truncate(10 * time.Minute).Unix()
		buckets[k] = append(buckets[k], x.Flux)
	}
	if latestT.IsZero() {
		return errNoData
	}
	// Flares: keep the log-scale max per bucket so short spikes survive downsampling.
	history := make([]planet.Sample, 0, len(buckets))
	for k, vs := range buckets {
		m := 0.0
		for _, v := range vs {
			m = math.Max(m, v)
		}
		history = append(history, planet.Sample{T: time.Unix(k, 0).UTC(), V: m})
	}
	sort.Slice(history, func(i, j int) bool { return history[i].T.Before(history[j].T) })

	var flares []struct {
		BeginTime string `json:"begin_time"`
		MaxTime   string `json:"max_time"`
		EndTime   string `json:"end_time"`
		MaxClass  string `json:"max_class"`
	}
	_ = h.getJSON(ctx, swpc+"/json/goes/primary/xray-flares-7-day.json", &flares)
	var fl []planet.Flare
	for _, f := range flares {
		if f.MaxClass == "" {
			continue
		}
		c := f.MaxClass[0]
		if c != 'C' && c != 'M' && c != 'X' {
			continue
		}
		fl = append(fl, planet.Flare{Begin: parseSWPCTime(f.BeginTime), Peak: parseSWPCTime(f.MaxTime), End: parseSWPCTime(f.EndTime), Class: f.MaxClass})
	}
	sort.Slice(fl, func(i, j int) bool { return fl[i].Peak.After(fl[j].Peak) })
	if len(fl) > 40 {
		fl = fl[:40]
	}

	h.mu.Lock()
	h.space.XrayFlux = latest
	h.space.XrayClass = xrayClass(latest)
	h.space.XrayTime = latestT
	h.space.XrayHistory = history
	h.space.Flares = fl
	h.mu.Unlock()
	h.touch()
	h.notify(ChangeSpace)
	return nil
}

func xrayClass(flux float64) string {
	if flux <= 0 {
		return "A0.0"
	}
	classes := []struct {
		letter string
		base   float64
	}{{"X", 1e-4}, {"M", 1e-5}, {"C", 1e-6}, {"B", 1e-7}, {"A", 1e-8}}
	for _, c := range classes {
		if flux >= c.base {
			return fmt.Sprintf("%s%.1f", c.letter, flux/c.base)
		}
	}
	return fmt.Sprintf("A%.1f", flux/1e-8)
}

// ---- Space weather alerts ---------------------------------------------------------------------

var alertTitle = regexp.MustCompile(`(?m)^(WARNING|ALERT|WATCH|SUMMARY|CONTINUED ALERT|EXTENDED WARNING|CANCEL WATCH|CANCEL WARNING):\s*(.+)$`)

func (h *Hub) pollSpaceAlerts(ctx context.Context) error {
	var alerts []struct {
		ProductID string `json:"product_id"`
		Issue     string `json:"issue_datetime"`
		Message   string `json:"message"`
	}
	if err := h.getJSON(ctx, swpc+"/products/alerts.json", &alerts); err != nil {
		return err
	}
	cutoff := time.Now().Add(-72 * time.Hour)
	var out []planet.SpaceAlert
	for _, a := range alerts {
		t := parseSWPCTime(a.Issue)
		if t.Before(cutoff) {
			continue
		}
		msg := strings.ReplaceAll(a.Message, "\r\n", "\n")
		title := a.ProductID
		if m := alertTitle.FindStringSubmatch(msg); m != nil {
			title = strings.TrimSpace(m[1] + ": " + m[2])
		}
		out = append(out, planet.SpaceAlert{Time: t, Code: a.ProductID, Title: title, Message: strings.TrimSpace(msg)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Time.After(out[j].Time) })
	if len(out) > 25 {
		out = out[:25]
	}
	h.mu.Lock()
	h.space.Alerts = out
	h.mu.Unlock()
	h.touch()
	return nil
}

// ---- OVATION aurora probability grid ---------------------------------------------------------

func (h *Hub) pollAurora(ctx context.Context) error {
	var ov struct {
		Observation string       `json:"Observation Time"`
		Forecast    string       `json:"Forecast Time"`
		Coordinates [][3]float64 `json:"coordinates"`
	}
	if err := h.getJSON(ctx, swpc+"/json/ovation_aurora_latest.json", &ov); err != nil {
		return err
	}
	if len(ov.Coordinates) < 1000 {
		return errNoData
	}
	const w, hgt = 360, 181
	grid := make([]byte, w*hgt)
	maxN, maxS := 0, 0
	for _, c := range ov.Coordinates {
		lon, lat, v := int(c[0]), int(c[1]), int(c[2])
		if lon < 0 || lon >= w || lat < -90 || lat > 90 {
			continue
		}
		v = max(0, min(100, v))
		grid[(lat+90)*w+lon] = byte(v)
		if lat > 0 && v > maxN {
			maxN = v
		}
		if lat < 0 && v > maxS {
			maxS = v
		}
	}
	a := &planet.Aurora{
		Observed:   parseSWPCTime(ov.Observation),
		Forecast:   parseSWPCTime(ov.Forecast),
		MaxNorth:   maxN,
		MaxSouth:   maxS,
		Grid:       base64.StdEncoding.EncodeToString(grid),
		GridWidth:  w,
		GridHeight: hgt,
	}
	h.mu.Lock()
	h.aurora = a
	h.mu.Unlock()
	h.touch()
	h.notify(ChangeAurora)
	return nil
}

// AuroraAt returns the OVATION probability (0-100) nearest to the given coordinate.
func (h *Hub) AuroraAt(lat, lon float64) int {
	h.mu.RLock()
	a := h.aurora
	h.mu.RUnlock()
	if a == nil {
		return 0
	}
	grid, err := base64.StdEncoding.DecodeString(a.Grid)
	if err != nil || len(grid) != a.GridWidth*a.GridHeight {
		return 0
	}
	lo := int(math.Round(math.Mod(lon+360, 360))) % 360
	la := int(math.Round(lat)) + 90
	la = max(0, min(180, la))
	return int(grid[la*a.GridWidth+lo])
}

func round(v float64, places int) float64 {
	p := math.Pow(10, float64(places))
	return math.Round(v*p) / p
}
