package feeds

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"time"

	"karman/internal/planet"
)

type eonetResponse struct {
	Events []struct {
		ID         string `json:"id"`
		Title      string `json:"title"`
		Link       string `json:"link"`
		Categories []struct {
			ID string `json:"id"`
		} `json:"categories"`
		Sources []struct {
			ID  string `json:"id"`
			URL string `json:"url"`
		} `json:"sources"`
		Geometry []struct {
			MagnitudeValue *float64        `json:"magnitudeValue"`
			MagnitudeUnit  *string         `json:"magnitudeUnit"`
			Date           string          `json:"date"`
			Type           string          `json:"type"`
			Coordinates    json.RawMessage `json:"coordinates"`
		} `json:"geometry"`
	} `json:"events"`
}

var eonetKinds = map[string]string{
	"wildfires":    "wildfire",
	"severeStorms": "storm",
	"volcanoes":    "volcano",
	"seaLakeIce":   "ice",
	"floods":       "flood",
	"dustHaze":     "dust",
	"drought":      "drought",
	"landslides":   "landslide",
	"snow":         "snow",
	"tempExtremes": "heat",
	"earthquakes":  "", // USGS is authoritative for quakes
	"manmade":      "other",
	"waterColor":   "other",
}

func (h *Hub) pollEONET(ctx context.Context) error {
	var r eonetResponse
	if err := h.getJSON(ctx, "https://eonet.gsfc.nasa.gov/api/v3/events?status=open&days=45", &r); err != nil {
		return err
	}
	var out []planet.NaturalEvent
	for _, e := range r.Events {
		if len(e.Categories) == 0 || len(e.Geometry) == 0 {
			continue
		}
		kind, ok := eonetKinds[e.Categories[0].ID]
		if !ok {
			kind = "other"
		}
		if kind == "" {
			continue
		}
		ev := planet.NaturalEvent{ID: e.ID, Kind: kind, Title: cleanTitle(e.Title), SourceURL: e.Link}
		if len(e.Sources) > 0 {
			ev.Source = e.Sources[0].ID
			if e.Sources[0].URL != "" {
				ev.SourceURL = e.Sources[0].URL
			}
		}
		for _, g := range e.Geometry {
			lat, lon, ok := centroid(g.Type, g.Coordinates)
			if !ok {
				continue
			}
			tp := planet.TrackPoint{Lat: round(lat, 3), Lon: round(lon, 3), Time: parseSWPCTime(g.Date)}
			if g.MagnitudeValue != nil {
				tp.Value = *g.MagnitudeValue
			}
			ev.Track = append(ev.Track, tp)
		}
		if len(ev.Track) == 0 {
			continue
		}
		sort.Slice(ev.Track, func(i, j int) bool { return ev.Track[i].Time.Before(ev.Track[j].Time) })
		last := ev.Track[len(ev.Track)-1]
		ev.Lat, ev.Lon, ev.Time, ev.Value = last.Lat, last.Lon, last.Time, last.Value
		if g := e.Geometry[len(e.Geometry)-1]; g.MagnitudeUnit != nil {
			ev.Unit = *g.MagnitudeUnit
		}
		age := time.Since(ev.Time)
		if age > 30*24*time.Hour || (kind == "storm" && age > 6*24*time.Hour) {
			continue // EONET sometimes leaves finished events open
		}
		if kind != "storm" || len(ev.Track) < 2 {
			ev.Track = nil // only storms have meaningful tracks
		}
		out = append(out, ev)
	}
	if len(out) == 0 && len(r.Events) > 0 {
		return errNoData
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Time.After(out[j].Time) })
	h.mu.Lock()
	h.events = out
	h.mu.Unlock()
	h.touch()
	h.notify(ChangeEvents)
	return nil
}

func centroid(kind string, raw json.RawMessage) (lat, lon float64, ok bool) {
	switch kind {
	case "Point":
		var c []float64
		if json.Unmarshal(raw, &c) != nil || len(c) < 2 {
			return 0, 0, false
		}
		return c[1], c[0], true
	case "Polygon":
		var rings [][][]float64
		if json.Unmarshal(raw, &rings) != nil || len(rings) == 0 || len(rings[0]) == 0 {
			return 0, 0, false
		}
		var sx, sy float64
		for _, p := range rings[0] {
			sx += p[0]
			sy += p[1]
		}
		n := float64(len(rings[0]))
		return sy / n, sx / n, true
	}
	return 0, 0, false
}

func cleanTitle(t string) string {
	return strings.Join(strings.Fields(t), " ")
}
