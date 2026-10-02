package feeds

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"time"

	"karman/internal/planet"
)

// ---- CelesTrak general perturbations (OMM) ---------------------------------------------

type omm struct {
	Name        string  `json:"OBJECT_NAME"`
	NoradID     int     `json:"NORAD_CAT_ID"`
	Epoch       string  `json:"EPOCH"`
	MeanMotion  float64 `json:"MEAN_MOTION"`
	Ecc         float64 `json:"ECCENTRICITY"`
	Inc         float64 `json:"INCLINATION"`
	RAAN        float64 `json:"RA_OF_ASC_NODE"`
	ArgP        float64 `json:"ARG_OF_PERICENTER"`
	MeanAnomaly float64 `json:"MEAN_ANOMALY"`
	BStar       float64 `json:"BSTAR"`
	NDot        float64 `json:"MEAN_MOTION_DOT"`
	NDDot       float64 `json:"MEAN_MOTION_DDOT"`
}

// SatelliteGroups lists the CelesTrak groups the API exposes.
var SatelliteGroups = map[string]bool{"stations": true, "visual": true, "starlink": true}

func (h *Hub) pollSatellites(ctx context.Context, group string) error {
	var raw []omm
	url := fmt.Sprintf("https://celestrak.org/NORAD/elements/gp.php?GROUP=%s&FORMAT=json", group)
	if err := h.getJSON(ctx, url, &raw); err != nil {
		return err
	}
	out := make([]planet.Satellite, 0, len(raw))
	for _, o := range raw {
		// The app propagates with near-Earth SGP4 only; skip deep-space orbits (period > 225 min).
		if o.MeanMotion < 6.4 {
			continue
		}
		out = append(out, planet.Satellite{
			Name: o.Name, NoradID: o.NoradID, Epoch: o.Epoch, MeanMotion: o.MeanMotion, Ecc: o.Ecc,
			Inc: o.Inc, RAAN: o.RAAN, ArgP: o.ArgP, MeanAnomaly: o.MeanAnomaly, BStar: o.BStar, NDot: o.NDot, NDDot: o.NDDot,
		})
	}
	if len(out) == 0 {
		return errNoData
	}
	h.mu.Lock()
	h.sats[group] = out
	h.satGen[group]++
	h.mu.Unlock()
	h.notify(ChangeSats)
	return nil
}

// ---- Launch Library 2 (The Space Devs) ------------------------------------------------------

type ll2Launch struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	NET    string `json:"net"`
	Status struct {
		Name   string `json:"name"`
		Abbrev string `json:"abbrev"`
	} `json:"status"`
	LSP struct {
		Name string `json:"name"`
	} `json:"launch_service_provider"`
	Rocket struct {
		Configuration struct {
			Name     string `json:"name"`
			FullName string `json:"full_name"`
		} `json:"configuration"`
	} `json:"rocket"`
	Mission *struct {
		Name        string `json:"name"`
		Description string `json:"description"`
		Orbit       *struct {
			Name   string `json:"name"`
			Abbrev string `json:"abbrev"`
		} `json:"orbit"`
	} `json:"mission"`
	Pad struct {
		Name      string `json:"name"`
		Latitude  any    `json:"latitude"`
		Longitude any    `json:"longitude"`
		Location  struct {
			Name string `json:"name"`
		} `json:"location"`
	} `json:"pad"`
	Image *struct {
		ImageURL     string `json:"image_url"`
		ThumbnailURL string `json:"thumbnail_url"`
	} `json:"image"`
	VidURLs []struct {
		URL string `json:"url"`
	} `json:"vid_urls"`
}

func anyFloat(v any) float64 {
	switch t := v.(type) {
	case float64:
		return t
	case string:
		f, _ := strconv.ParseFloat(t, 64)
		return f
	}
	return 0
}

func (h *Hub) pollLaunches(ctx context.Context) error {
	var r struct {
		Results []ll2Launch `json:"results"`
	}
	if err := h.getJSON(ctx, "https://ll.thespacedevs.com/2.3.0/launches/upcoming/?limit=20&mode=detailed", &r); err != nil {
		return err
	}
	var out []planet.Launch
	for _, l := range r.Results {
		net, err := time.Parse(time.RFC3339, l.NET)
		if err != nil {
			continue
		}
		rocket := l.Rocket.Configuration.FullName
		if rocket == "" {
			rocket = l.Rocket.Configuration.Name
		}
		launch := planet.Launch{
			ID: l.ID, Name: l.Name, Provider: l.LSP.Name, Rocket: rocket,
			Pad: l.Pad.Name, Location: l.Pad.Location.Name,
			Lat: anyFloat(l.Pad.Latitude), Lon: anyFloat(l.Pad.Longitude),
			NET: net.UTC(), Status: l.Status.Name, StatusAbbrev: l.Status.Abbrev,
		}
		if l.Mission != nil {
			launch.Mission = truncate(l.Mission.Description, 420)
			if l.Mission.Orbit != nil {
				launch.Orbit = l.Mission.Orbit.Abbrev
			}
		}
		if l.Image != nil {
			launch.Image = l.Image.ThumbnailURL
			if launch.Image == "" {
				launch.Image = l.Image.ImageURL
			}
		}
		if len(l.VidURLs) > 0 {
			launch.Webcast = l.VidURLs[0].URL
		}
		out = append(out, launch)
	}
	if len(out) == 0 {
		return errNoData
	}
	sort.Slice(out, func(i, j int) bool { return out[i].NET.Before(out[j].NET) })
	h.mu.Lock()
	h.launches = out
	h.mu.Unlock()
	h.touch()
	h.notify(ChangeLaunches)
	return nil
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

// ---- NASA NeoWs close approaches -------------------------------------------------------------

func (h *Hub) pollNEO(ctx context.Context) error {
	var r struct {
		NEOs map[string][]struct {
			ID        string `json:"id"`
			Name      string `json:"name"`
			URL       string `json:"nasa_jpl_url"`
			Hazardous bool   `json:"is_potentially_hazardous_asteroid"`
			Diameter  struct {
				Meters struct {
					Min float64 `json:"estimated_diameter_min"`
					Max float64 `json:"estimated_diameter_max"`
				} `json:"meters"`
			} `json:"estimated_diameter"`
			Approaches []struct {
				Epoch int64 `json:"epoch_date_close_approach"`
				Miss  struct {
					Km    string `json:"kilometers"`
					Lunar string `json:"lunar"`
				} `json:"miss_distance"`
				Velocity struct {
					Kps string `json:"kilometers_per_second"`
				} `json:"relative_velocity"`
				Body string `json:"orbiting_body"`
			} `json:"close_approach_data"`
		} `json:"near_earth_objects"`
	}
	start := time.Now().UTC().Format("2006-01-02")
	url := fmt.Sprintf("https://api.nasa.gov/neo/rest/v1/feed?start_date=%s&api_key=%s", start, h.nasaKey)
	if err := h.getJSON(ctx, url, &r); err != nil {
		return err
	}
	var out []planet.NEO
	for _, day := range r.NEOs {
		for _, n := range day {
			for _, a := range n.Approaches {
				if a.Body != "Earth" {
					continue
				}
				km, _ := strconv.ParseFloat(a.Miss.Km, 64)
				ld, _ := strconv.ParseFloat(a.Miss.Lunar, 64)
				v, _ := strconv.ParseFloat(a.Velocity.Kps, 64)
				out = append(out, planet.NEO{
					ID: n.ID, Name: n.Name, URL: n.URL, Hazardous: n.Hazardous,
					Approach: time.UnixMilli(a.Epoch).UTC(), MissKm: round(km, 0), MissLunar: round(ld, 2),
					DiameterMinM: round(n.Diameter.Meters.Min, 0), DiameterMaxM: round(n.Diameter.Meters.Max, 0), VelocityKps: round(v, 2),
				})
			}
		}
	}
	if len(out) == 0 {
		return errNoData
	}
	sort.Slice(out, func(i, j int) bool { return out[i].MissKm < out[j].MissKm })
	if len(out) > 30 {
		out = out[:30]
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Approach.Before(out[j].Approach) })
	h.mu.Lock()
	h.neos = out
	h.mu.Unlock()
	h.touch()
	h.notify(ChangeNEOs)
	return nil
}
