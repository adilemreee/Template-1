package feeds

import (
	"context"
	"sort"
	"time"

	"karman/internal/planet"
)

type usgsCollection struct {
	Features []struct {
		ID         string `json:"id"`
		Properties struct {
			Mag     *float64 `json:"mag"`
			Place   string   `json:"place"`
			Time    int64    `json:"time"`
			URL     string   `json:"url"`
			Felt    *int     `json:"felt"`
			Alert   *string  `json:"alert"`
			Tsunami int      `json:"tsunami"`
			Sig     int      `json:"sig"`
			Type    string   `json:"type"`
			Title   string   `json:"title"`
		} `json:"properties"`
		Geometry struct {
			Coordinates []float64 `json:"coordinates"`
		} `json:"geometry"`
	} `json:"features"`
}

// pollQuakes merges the M2.5+ weekly feed with the significant-month feed so that the
// app always sees the big ones even when they are older than a week.
func (h *Hub) pollQuakes(ctx context.Context) error {
	var week, significant usgsCollection
	if err := h.getJSON(ctx, "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_week.geojson", &week); err != nil {
		return err
	}
	_ = h.getJSON(ctx, "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/significant_month.geojson", &significant)

	byID := map[string]planet.Quake{}
	for _, col := range []usgsCollection{week, significant} {
		for _, f := range col.Features {
			p := f.Properties
			if p.Mag == nil || len(f.Geometry.Coordinates) < 2 || p.Type != "earthquake" {
				continue
			}
			q := planet.Quake{
				ID:    f.ID,
				Mag:   round(*p.Mag, 1),
				Place: p.Place,
				Time:  time.UnixMilli(p.Time).UTC(),
				Lon:   round(f.Geometry.Coordinates[0], 3),
				Lat:   round(f.Geometry.Coordinates[1], 3),
				Sig:   p.Sig,
				URL:   p.URL,
			}
			if q.Place == "" {
				q.Place = p.Title
			}
			if len(f.Geometry.Coordinates) > 2 {
				q.DepthKm = round(f.Geometry.Coordinates[2], 1)
			}
			if p.Felt != nil {
				q.Felt = *p.Felt
			}
			if p.Alert != nil {
				q.Alert = *p.Alert
			}
			q.Tsunami = p.Tsunami == 1
			byID[q.ID] = q
		}
	}
	if len(byID) == 0 {
		return errNoData
	}
	quakes := make([]planet.Quake, 0, len(byID))
	for _, q := range byID {
		quakes = append(quakes, q)
	}
	sort.Slice(quakes, func(i, j int) bool { return quakes[i].Time.After(quakes[j].Time) })
	if len(quakes) > 2500 {
		quakes = quakes[:2500]
	}
	h.mu.Lock()
	h.quakes = quakes
	h.mu.Unlock()
	h.touch()
	h.notify(ChangeQuakes)
	return nil
}
