package feeds

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"sync"
	"time"
)

// Cloud cover for the stargazing forecast, from MET Norway's Locationforecast 2.0 (CC BY 4.0).
// Places are rounded to 0.5° (about 50 km) before they leave the server and answers are cached
// until MET Norway says they expire, as its terms of service ask.

// metBase is the Locationforecast endpoint (a variable so tests can point elsewhere).
var metBase = "https://api.met.no/weatherapi/locationforecast/2.0/compact"

// CloudPoint is one hour of the forecast at a place.
type CloudPoint struct {
	T        time.Time `json:"t"`
	Cloud    float64   `json:"cloud"`    // total cloud cover, %
	Humidity float64   `json:"humidity"` // relative humidity, %
	TempC    float64   `json:"tempC"`
}

// CloudForecast is the next few days of sky cover for a rounded location.
type CloudForecast struct {
	Lat         float64      `json:"lat"`
	Lon         float64      `json:"lon"`
	Points      []CloudPoint `json:"points"`
	Attribution string       `json:"attribution"`

	expires time.Time
}

type cloudCache struct {
	mu      sync.Mutex
	entries map[string]CloudForecast
}

var clouds = &cloudCache{entries: map[string]CloudForecast{}}

// SetContact sets how upstream services that ask for it (MET Norway) can reach the operator.
func (h *Hub) SetContact(contact string) { h.contact = contact }

// Clouds returns the hourly cloud forecast near a location (rounded to 0.5°).
func (h *Hub) Clouds(ctx context.Context, lat, lon float64) (CloudForecast, error) {
	lat = math.Round(math.Max(-89.5, math.Min(89.5, lat))*2) / 2
	lon = math.Round(math.Mod(math.Mod(lon+180, 360)+360, 360)*2)/2 - 180
	if lon < -180 {
		lon += 360
	}
	key := fmt.Sprintf("%.1f,%.1f", lat, lon)
	clouds.mu.Lock()
	cached, ok := clouds.entries[key]
	clouds.mu.Unlock()
	if ok && time.Now().Before(cached.expires) {
		return cached, nil
	}
	fresh, err := h.fetchClouds(ctx, lat, lon)
	if err != nil {
		if ok {
			return cached, nil // a slightly stale sky beats no sky
		}
		return CloudForecast{}, err
	}
	clouds.mu.Lock()
	if len(clouds.entries) > 4000 {
		now := time.Now()
		for k, v := range clouds.entries {
			if now.After(v.expires) {
				delete(clouds.entries, k)
			}
		}
		if len(clouds.entries) > 4000 {
			clear(clouds.entries)
		}
	}
	clouds.entries[key] = fresh
	clouds.mu.Unlock()
	return fresh, nil
}

func (h *Hub) fetchClouds(ctx context.Context, lat, lon float64) (CloudForecast, error) {
	url := fmt.Sprintf("%s?lat=%.1f&lon=%.1f", metBase, lat, lon)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return CloudForecast{}, err
	}
	contact := h.contact
	if contact == "" {
		contact = "karman.adilemree.xyz"
	}
	req.Header.Set("User-Agent", "KarmanEarth/1.1 "+contact)
	resp, err := h.client.Do(req)
	if err != nil {
		return CloudForecast{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
		return CloudForecast{}, fmt.Errorf("MET Norway: HTTP %d", resp.StatusCode)
	}
	var doc struct {
		Properties struct {
			Timeseries []struct {
				Time string `json:"time"`
				Data struct {
					Instant struct {
						Details struct {
							Cloud    *float64 `json:"cloud_area_fraction"`
							Humidity *float64 `json:"relative_humidity"`
							Temp     *float64 `json:"air_temperature"`
						} `json:"details"`
					} `json:"instant"`
				} `json:"data"`
			} `json:"timeseries"`
		} `json:"properties"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&doc); err != nil {
		return CloudForecast{}, fmt.Errorf("decode MET Norway: %w", err)
	}
	out := CloudForecast{Lat: lat, Lon: lon, Attribution: "Cloud forecast: MET Norway (CC BY 4.0)"}
	horizon := time.Now().Add(72 * time.Hour)
	for _, ts := range doc.Properties.Timeseries {
		t := parseSWPCTime(ts.Time)
		d := ts.Data.Instant.Details
		if t.IsZero() || t.After(horizon) || d.Cloud == nil {
			continue
		}
		p := CloudPoint{T: t, Cloud: round(*d.Cloud, 0)}
		if d.Humidity != nil {
			p.Humidity = round(*d.Humidity, 0)
		}
		if d.Temp != nil {
			p.TempC = round(*d.Temp, 1)
		}
		out.Points = append(out.Points, p)
	}
	if len(out.Points) == 0 {
		return CloudForecast{}, errNoData
	}
	out.expires = time.Now().Add(time.Hour)
	if exp, err := http.ParseTime(resp.Header.Get("Expires")); err == nil {
		out.expires = time.Now().Add(max(15*time.Minute, min(3*time.Hour, time.Until(exp))))
	}
	return out, nil
}
