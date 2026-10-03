package feeds

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"time"

	"karman/internal/planet"
)

// A year of the planet's earthquakes (M4.5+, USGS FDSN event service), refreshed twice a day,
// for the app's "replay the year": in under a minute the plate boundaries draw themselves.

const (
	historyMinMag = 4.5
	historyDays   = 365
)

// fdsnBase is the USGS event service (a variable so tests can point elsewhere).
var fdsnBase = "https://earthquake.usgs.gov/fdsnws/event/1/query"

type quakeHistory struct {
	From   time.Time      `json:"from"`
	To     time.Time      `json:"to"`
	MinMag float64        `json:"minMag"`
	Quakes []planet.Quake `json:"quakes"`

	gz   []byte
	etag string
}

// YearStats summarises the last year for the narrator and the assistant.
type YearStats struct {
	From      time.Time    `json:"from"`
	M45Plus   int          `json:"magnitude4_5Plus"`
	M6Plus    int          `json:"magnitude6Plus"`
	M7Plus    int          `json:"magnitude7Plus"`
	Strongest planet.Quake `json:"strongest"`
}

// StartHistory restores the cached year and keeps it current.
func (h *Hub) StartHistory(ctx context.Context) {
	h.loadHistory()
	h.mu.Lock()
	if len(h.history.Quakes) == 0 {
		delete(h.sources, "usgs-year")
	}
	h.mu.Unlock()
	h.every(ctx, "usgs-year", 12*time.Hour, h.pollHistory)
}

func (h *Hub) historyPath() string { return filepath.Join(h.cacheDir, "quakes-year.json") }

func (h *Hub) pollHistory(ctx context.Context) error {
	to := time.Now().UTC().Truncate(time.Hour)
	from := to.Add(-historyDays * 24 * time.Hour)
	url := fmt.Sprintf("%s?format=geojson&eventtype=earthquake&orderby=time-asc&minmagnitude=%.1f&starttime=%s&endtime=%s",
		fdsnBase, historyMinMag, from.Format("2006-01-02T15:04:05"), to.Format("2006-01-02T15:04:05"))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "KarmanEarth/1.1 (backend for the Karman iOS app)")
	resp, err := h.slowClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
		if resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusTooManyRequests {
			return fmt.Errorf("USGS FDSN: HTTP %d: %w", resp.StatusCode, errRateLimited)
		}
		return fmt.Errorf("USGS FDSN: HTTP %d", resp.StatusCode)
	}
	var col usgsCollection
	if err := json.NewDecoder(io.LimitReader(resp.Body, 128<<20)).Decode(&col); err != nil {
		return fmt.Errorf("decode FDSN: %w", err)
	}
	quakes := make([]planet.Quake, 0, len(col.Features))
	for _, f := range col.Features {
		p := f.Properties
		if p.Mag == nil || len(f.Geometry.Coordinates) < 2 || (p.Type != "" && p.Type != "earthquake") {
			continue
		}
		q := planet.Quake{
			ID: f.ID, Mag: round(*p.Mag, 1), Place: p.Place, Time: time.UnixMilli(p.Time).UTC(),
			Lon: round(f.Geometry.Coordinates[0], 2), Lat: round(f.Geometry.Coordinates[1], 2), Sig: p.Sig,
			Tsunami: p.Tsunami == 1,
		}
		if q.Place == "" {
			q.Place = p.Title
		}
		if len(f.Geometry.Coordinates) > 2 {
			q.DepthKm = round(f.Geometry.Coordinates[2], 0)
		}
		if p.Alert != nil {
			q.Alert = *p.Alert
		}
		quakes = append(quakes, q)
	}
	if len(quakes) < 100 {
		return errNoData // a year always has thousands; anything less is a broken response
	}
	sort.Slice(quakes, func(i, j int) bool { return quakes[i].Time.Before(quakes[j].Time) })
	hist := quakeHistory{From: from, To: to, MinMag: historyMinMag, Quakes: quakes}
	if err := hist.encode(); err != nil {
		return err
	}
	if b, err := json.Marshal(hist); err == nil {
		tmp := h.historyPath() + ".tmp"
		if os.WriteFile(tmp, b, 0o644) == nil {
			_ = os.Rename(tmp, h.historyPath())
		}
	}
	h.mu.Lock()
	h.history = hist
	h.mu.Unlock()
	h.notify(ChangeHistory)
	h.log.Info("quake history updated", "quakes", len(quakes))
	return nil
}

func (q *quakeHistory) encode() error {
	plain, err := json.Marshal(q)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(plain)
	q.gz = gzipBytes(plain)
	q.etag = `"` + hex.EncodeToString(sum[:10]) + `"`
	return nil
}

func (h *Hub) loadHistory() {
	b, err := os.ReadFile(h.historyPath())
	if err != nil {
		return
	}
	var hist quakeHistory
	if json.Unmarshal(b, &hist) != nil || len(hist.Quakes) == 0 || hist.encode() != nil {
		return
	}
	h.mu.Lock()
	h.history = hist
	h.mu.Unlock()
}

// QuakeHistory returns the gzipped year of earthquakes and its ETag.
func (h *Hub) QuakeHistory() (gz []byte, etag string, ok bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	if len(h.history.Quakes) == 0 {
		return nil, "", false
	}
	return h.history.gz, h.history.etag, true
}

// YearStats counts the last year's significant earthquakes.
func (h *Hub) YearStats() (YearStats, bool) {
	h.mu.RLock()
	hist := h.history
	h.mu.RUnlock()
	if len(hist.Quakes) == 0 {
		return YearStats{}, false
	}
	s := YearStats{From: hist.From}
	for _, q := range hist.Quakes {
		s.M45Plus++
		if q.Mag >= 6 {
			s.M6Plus++
		}
		if q.Mag >= 7 {
			s.M7Plus++
		}
		if q.Mag > s.Strongest.Mag {
			s.Strongest = q
		}
	}
	return s, true
}
