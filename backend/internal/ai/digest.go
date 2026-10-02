// Package ai turns the live planet state into narrated briefings and grounded answers.
package ai

import (
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"karman/internal/planet"
)

// Digest is the compact, model-facing summary of the planet right now. Every scene the
// model writes must reference one of these items by ID, which keeps narration grounded.
type Digest struct {
	AsOf       string       `json:"asOf"`
	Quakes     []DigestItem `json:"notableEarthquakes"`
	QuakeStats QuakeStats   `json:"earthquakeStats"`
	Storms     []DigestItem `json:"tropicalAndSevereStorms"`
	Volcanoes  []DigestItem `json:"volcanoes"`
	Fires      FireStats    `json:"wildfires"`
	Ice        []DigestItem `json:"seaAndLakeIce,omitempty"`
	Other      []DigestItem `json:"otherEvents,omitempty"`
	Space      SpaceDigest  `json:"spaceWeather"`
	Launches   []DigestItem `json:"upcomingLaunches"`
	Asteroids  []DigestItem `json:"asteroidCloseApproaches"`
}

type DigestItem struct {
	ID      string  `json:"refId"`
	Kind    string  `json:"kind"`
	Title   string  `json:"title"`
	Lat     float64 `json:"lat"`
	Lon     float64 `json:"lon"`
	When    string  `json:"when"`
	Details string  `json:"details"`
}

type QuakeStats struct {
	Last24hM25Plus int     `json:"last24hMagnitude2_5Plus"`
	Last7dM45Plus  int     `json:"last7dMagnitude4_5Plus"`
	Last7dM6Plus   int     `json:"last7dMagnitude6Plus"`
	StrongestWeek  float64 `json:"strongestThisWeek"`
}

type FireStats struct {
	Active  int          `json:"activeTracked"`
	Notable []DigestItem `json:"notable"`
}

type SpaceDigest struct {
	Kp             float64      `json:"kpNow"`
	KpMax24h       float64      `json:"kpMax24h"`
	KpForecastMax  float64      `json:"kpForecastMax72h"`
	GScale         int          `json:"geomagneticStormLevelG"`
	AuroraNorthMax int          `json:"auroraOvalPeakProbabilityNorth"`
	AuroraSouthMax int          `json:"auroraOvalPeakProbabilitySouth"`
	WindSpeed      float64      `json:"solarWindSpeedKmS"`
	Bz             float64      `json:"imfBzNt"`
	Xray           string       `json:"xrayClassNow"`
	Flares24h      []string     `json:"flaresLast24h"`
	Items          []DigestItem `json:"items"`
}

func ago(now, t time.Time) string {
	d := now.Sub(t)
	switch {
	case d < 0:
		return "in " + dur(-d)
	case d < time.Minute:
		return "just now"
	default:
		return dur(d) + " ago"
	}
}

func dur(d time.Duration) string {
	plural := func(n int, one, many string) string {
		if n == 1 {
			return "1 " + one
		}
		return fmt.Sprintf("%d %s", n, many)
	}
	switch {
	case d < time.Hour:
		return plural(max(1, int(d.Minutes())), "minute", "minutes")
	case d < 48*time.Hour:
		return plural(int(d.Hours()+0.5), "hour", "hours")
	default:
		return plural(int(d.Hours()/24+0.5), "day", "days")
	}
}

// BuildDigest condenses a snapshot into what a narrator needs.
func BuildDigest(s planet.Snapshot) Digest {
	now := s.GeneratedAt
	d := Digest{AsOf: now.Format(time.RFC3339)}

	// Earthquakes: the strongest of the week plus anything notable in the last day.
	qs := append([]planet.Quake{}, s.Quakes...)
	for _, q := range qs {
		age := now.Sub(q.Time)
		if age < 24*time.Hour {
			d.QuakeStats.Last24hM25Plus++
		}
		if age < 7*24*time.Hour {
			if q.Mag >= 4.5 {
				d.QuakeStats.Last7dM45Plus++
			}
			if q.Mag >= 6 {
				d.QuakeStats.Last7dM6Plus++
			}
			d.QuakeStats.StrongestWeek = math.Max(d.QuakeStats.StrongestWeek, q.Mag)
		}
	}
	sort.Slice(qs, func(i, j int) bool { return quakeScore(now, qs[i]) > quakeScore(now, qs[j]) })
	for _, q := range qs {
		if len(d.Quakes) >= 6 {
			break
		}
		if q.Mag < 4.5 && now.Sub(q.Time) > 24*time.Hour {
			continue
		}
		details := fmt.Sprintf("magnitude %.1f, depth %.0f km", q.Mag, q.DepthKm)
		if q.Tsunami {
			details += ", tsunami flag set by USGS (informational)"
		}
		if q.Felt > 0 {
			details += fmt.Sprintf(", %d felt reports", q.Felt)
		}
		if q.Alert != "" {
			details += ", PAGER alert " + q.Alert
		}
		d.Quakes = append(d.Quakes, DigestItem{ID: q.ID, Kind: "quake", Title: q.Place, Lat: q.Lat, Lon: q.Lon, When: ago(now, q.Time), Details: details})
	}

	for _, e := range s.Events {
		item := DigestItem{ID: e.ID, Kind: e.Kind, Title: e.Title, Lat: e.Lat, Lon: e.Lon, When: ago(now, e.Time)}
		if e.Value > 0 {
			item.Details = fmt.Sprintf("%.0f %s", e.Value, e.Unit)
		}
		switch e.Kind {
		case "storm":
			if len(e.Track) > 1 {
				first := e.Track[0]
				item.Details = strings.TrimSpace(item.Details + fmt.Sprintf(", tracked since %s", first.Time.Format("Jan 2")))
			}
			if now.Sub(e.Time) < 4*24*time.Hour {
				d.Storms = append(d.Storms, item)
			}
		case "volcano":
			d.Volcanoes = append(d.Volcanoes, item)
		case "wildfire":
			d.Fires.Active++
			if len(d.Fires.Notable) < 4 && now.Sub(e.Time) < 5*24*time.Hour {
				d.Fires.Notable = append(d.Fires.Notable, item)
			}
		case "ice":
			if len(d.Ice) < 2 {
				d.Ice = append(d.Ice, item)
			}
		default:
			if len(d.Other) < 4 {
				d.Other = append(d.Other, item)
			}
		}
	}
	sort.Slice(d.Storms, func(i, j int) bool { return stormStrength(d.Storms[i]) > stormStrength(d.Storms[j]) })
	if len(d.Storms) > 5 {
		d.Storms = d.Storms[:5]
	}

	if sp := s.Space; sp != nil {
		d.Space = SpaceDigest{Kp: sp.Kp, GScale: sp.GScale, WindSpeed: sp.WindSpeed, Bz: sp.Bz, Xray: sp.XrayClass}
		d.Space.Kp = math.Max(sp.Kp, sp.KpEstimated)
		for _, k := range sp.KpHistory {
			if now.Sub(k.T) < 24*time.Hour {
				d.Space.KpMax24h = math.Max(d.Space.KpMax24h, k.V)
			}
		}
		for _, k := range sp.KpForecast {
			d.Space.KpForecastMax = math.Max(d.Space.KpForecastMax, k.V)
		}
		for _, f := range sp.Flares {
			if now.Sub(f.Peak) < 24*time.Hour {
				d.Space.Flares24h = append(d.Space.Flares24h, f.Class+" at "+f.Peak.Format("15:04 UTC"))
			}
		}
		// A synthetic "sun" item lets the narrator point the camera at the subsolar point.
		sunLat, sunLon := SubsolarPoint(now)
		d.Space.Items = append(d.Space.Items, DigestItem{ID: "sun", Kind: "sun", Title: "The Sun / space weather", Lat: sunLat, Lon: sunLon, When: "now",
			Details: fmt.Sprintf("Kp %.1f, solar wind %.0f km/s, X-ray %s", d.Space.Kp, sp.WindSpeed, sp.XrayClass)})
	}
	if a := s.Aurora; a != nil {
		d.Space.AuroraNorthMax, d.Space.AuroraSouthMax = a.MaxNorth, a.MaxSouth
		lon := auroraFocusLongitude(now)
		d.Space.Items = append(d.Space.Items,
			DigestItem{ID: "aurora-north", Kind: "aurora", Title: "Northern auroral oval", Lat: 67, Lon: lon, When: "now", Details: fmt.Sprintf("peak probability %d%%", a.MaxNorth)},
			DigestItem{ID: "aurora-south", Kind: "aurora", Title: "Southern auroral oval", Lat: -67, Lon: lon, When: "now", Details: fmt.Sprintf("peak probability %d%%", a.MaxSouth)},
		)
	}

	for _, l := range s.Launches {
		if len(d.Launches) >= 4 {
			break
		}
		if l.NET.Before(now.Add(-6*time.Hour)) || l.NET.After(now.Add(72*time.Hour)) {
			continue
		}
		details := fmt.Sprintf("%s by %s from %s; status %s", l.Rocket, l.Provider, l.Location, l.Status)
		if l.Orbit != "" {
			details += "; orbit " + l.Orbit
		}
		d.Launches = append(d.Launches, DigestItem{ID: l.ID, Kind: "launch", Title: strings.ReplaceAll(l.Name, " | ", ": "), Lat: l.Lat, Lon: l.Lon, When: ago(now, l.NET), Details: details})
	}

	neos := append([]planet.NEO{}, s.NEOs...)
	sort.Slice(neos, func(i, j int) bool { return neos[i].MissLunar < neos[j].MissLunar })
	for _, n := range neos {
		if len(d.Asteroids) >= 2 {
			break
		}
		d.Asteroids = append(d.Asteroids, DigestItem{ID: "neo-" + n.ID, Kind: "asteroid", Title: n.Name, When: ago(now, n.Approach),
			Details: fmt.Sprintf("misses Earth by %.1f lunar distances (%.0f km), %.0f-%.0f m wide, %.1f km/s", n.MissLunar, n.MissKm, n.DiameterMinM, n.DiameterMaxM, n.VelocityKps)})
	}
	return d
}

func quakeScore(now time.Time, q planet.Quake) float64 {
	hours := now.Sub(q.Time).Hours()
	recency := math.Exp(-hours / 72)
	return math.Pow(10, q.Mag/2) * (0.35 + recency) * (1 + float64(q.Felt)/2000)
}

func stormStrength(i DigestItem) float64 {
	var v float64
	fmt.Sscanf(i.Details, "%f", &v)
	return v
}

// auroraFocusLongitude picks a longitude on the night side so the oval is visible.
func auroraFocusLongitude(t time.Time) float64 {
	_, sunLon := SubsolarPoint(t)
	lon := sunLon + 180
	for lon > 180 {
		lon -= 360
	}
	return math.Round(lon)
}

// SubsolarPoint returns the latitude/longitude where the Sun is overhead (NOAA algorithm, ~0.1°).
func SubsolarPoint(t time.Time) (lat, lon float64) {
	jd := float64(t.UnixMilli())/86400000.0 + 2440587.5
	n := jd - 2451545.0
	L := math.Mod(280.460+0.9856474*n, 360)
	g := math.Mod(357.528+0.9856003*n, 360) * math.Pi / 180
	lambda := (L + 1.915*math.Sin(g) + 0.020*math.Sin(2*g)) * math.Pi / 180
	eps := (23.439 - 0.0000004*n) * math.Pi / 180
	dec := math.Asin(math.Sin(eps) * math.Sin(lambda))
	ra := math.Atan2(math.Cos(eps)*math.Sin(lambda), math.Cos(lambda))
	gmst := math.Mod(280.46061837+360.98564736629*n, 360) * math.Pi / 180
	lon = (ra - gmst) * 180 / math.Pi
	for lon > 180 {
		lon -= 360
	}
	for lon < -180 {
		lon += 360
	}
	return dec * 180 / math.Pi, lon
}
