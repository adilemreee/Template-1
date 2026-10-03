// Package feeds polls public Earth and space-weather sources and keeps a normalized,
// in-memory picture of the planet that the HTTP layer serves and the alert engine watches.
package feeds

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"karman/internal/planet"
)

// Change tells listeners which part of the planet state was refreshed.
type Change string

const (
	ChangeQuakes   Change = "quakes"
	ChangeEvents   Change = "events"
	ChangeAurora   Change = "aurora"
	ChangeSpace    Change = "space"
	ChangeLaunches Change = "launches"
	ChangeNEOs     Change = "neos"
	ChangeSats     Change = "satellites"
)

type Hub struct {
	log      *slog.Logger
	client   *http.Client
	cacheDir string
	nasaKey  string

	mu       sync.RWMutex
	quakes   []planet.Quake
	events   []planet.NaturalEvent
	aurora   *planet.Aurora
	space    planet.SpaceWeather
	launches []planet.Launch
	neos     []planet.NEO
	sats     map[string][]planet.Satellite
	satGen   map[string]uint64
	sources  map[string]planet.SourceState

	snapMu   sync.Mutex
	snapGen  uint64
	dataGen  uint64
	snapJSON []byte
	snapGzip []byte
	snapETag string

	satCache map[string]encoded

	listenMu  sync.Mutex
	listeners []func(Change)
}

type encoded struct {
	gen  uint64
	gz   []byte
	etag string
}

func NewHub(log *slog.Logger, cacheDir, nasaKey string) *Hub {
	_ = os.MkdirAll(cacheDir, 0o755)
	h := &Hub{
		log:      log,
		client:   &http.Client{Timeout: 45 * time.Second},
		cacheDir: cacheDir,
		nasaKey:  nasaKey,
		sats:     map[string][]planet.Satellite{},
		satGen:   map[string]uint64{},
		sources:  map[string]planet.SourceState{},
		satCache: map[string]encoded{},
	}
	h.loadCaches()
	return h
}

func (h *Hub) OnChange(fn func(Change)) {
	h.listenMu.Lock()
	h.listeners = append(h.listeners, fn)
	h.listenMu.Unlock()
}

func (h *Hub) notify(c Change) {
	h.listenMu.Lock()
	ls := append([]func(Change){}, h.listeners...)
	h.listenMu.Unlock()
	for _, fn := range ls {
		go fn(c)
	}
}

// Start launches every poller; they run until ctx is cancelled.
func (h *Hub) Start(ctx context.Context) {
	h.every(ctx, "usgs", 90*time.Second, h.pollQuakes)
	h.every(ctx, "swpc-kp", 5*time.Minute, h.pollKp)
	h.every(ctx, "swpc-wind", 2*time.Minute, h.pollWind)
	h.every(ctx, "swpc-xray", 3*time.Minute, h.pollXray)
	h.every(ctx, "swpc-alerts", 10*time.Minute, h.pollSpaceAlerts)
	h.every(ctx, "swpc-ovation", 5*time.Minute, h.pollAurora)
	h.every(ctx, "eonet", 15*time.Minute, h.pollEONET)
	h.every(ctx, "launches", 30*time.Minute, h.pollLaunches)
	h.every(ctx, "neo", 6*time.Hour, h.pollNEO)
	h.every(ctx, "celestrak-stations", 4*time.Hour, func(ctx context.Context) error { return h.pollSatellites(ctx, "stations") })
	h.every(ctx, "celestrak-visual", 8*time.Hour, func(ctx context.Context) error { return h.pollSatellites(ctx, "visual") })
	h.every(ctx, "celestrak-starlink", 12*time.Hour, func(ctx context.Context) error { return h.pollSatellites(ctx, "starlink") })
}

func (h *Hub) every(ctx context.Context, name string, interval time.Duration, fn func(context.Context) error) {
	go func() {
		// Stagger start-up so we do not hit every upstream in the same second.
		delay := time.Duration(rand.Int64N(int64(4 * time.Second)))
		// Slow feeds whose cached copy is still fresh are not downloaded again on restart:
		// CelesTrak in particular answers 403 to repeat downloads within its update cycle.
		if interval >= time.Hour {
			h.mu.RLock()
			last := h.sources[name].UpdatedAt
			h.mu.RUnlock()
			if wait := time.Until(last.Add(interval)); wait > delay {
				delay = wait
			}
		}
		failures := 0
		for {
			select {
			case <-ctx.Done():
				return
			case <-time.After(delay):
			}
			cctx, cancel := context.WithTimeout(ctx, 60*time.Second)
			err := fn(cctx)
			cancel()
			if err != nil {
				failures++
				h.markSource(name, false)
				backoff := min(interval, time.Duration(failures)*30*time.Second)
				if errors.Is(err, errRateLimited) {
					// Hammering a source that refused us risks a longer block; wait it out.
					backoff = max(backoff, min(interval, 2*time.Hour))
				}
				h.log.Warn("feed failed", "feed", name, "err", err, "retry_in", backoff)
				delay = backoff
				continue
			}
			failures = 0
			h.markSource(name, true)
			jitter := time.Duration(rand.Int64N(int64(interval / 10)))
			delay = interval + jitter
		}
	}()
}

func (h *Hub) markSource(name string, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	s := h.sources[name]
	s.Name = name
	s.OK = ok
	if ok {
		s.UpdatedAt = time.Now().UTC()
	}
	h.sources[name] = s
}

func (h *Hub) touch() {
	h.snapMu.Lock()
	h.dataGen++
	h.snapMu.Unlock()
}

// ---- HTTP helpers ---------------------------------------------------------------

func (h *Hub) getJSON(ctx context.Context, url string, v any) error {
	body, err := h.get(ctx, url)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(body, v); err != nil {
		return fmt.Errorf("decode %s: %w", url, err)
	}
	return nil
}

func (h *Hub) get(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "KarmanEarth/1.0 (backend for the Karman iOS app)")
	req.Header.Set("Accept", "application/json, */*")
	resp, err := h.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
		if resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusTooManyRequests {
			return nil, fmt.Errorf("GET %s: HTTP %d: %w", url, resp.StatusCode, errRateLimited)
		}
		return nil, fmt.Errorf("GET %s: HTTP %d", url, resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 64<<20))
}

// ---- Snapshot -------------------------------------------------------------------

// Snapshot returns the current state as JSON (plain and gzipped) with a strong ETag.
func (h *Hub) Snapshot() (plain, gz []byte, etag string) {
	h.snapMu.Lock()
	defer h.snapMu.Unlock()
	if h.snapJSON != nil && h.snapGen == h.dataGen {
		return h.snapJSON, h.snapGzip, h.snapETag
	}
	snap := h.Current()
	plain, _ = json.Marshal(snap)
	gz = gzipBytes(plain)
	sum := sha256.Sum256(plain)
	h.snapJSON, h.snapGzip, h.snapETag = plain, gz, `"`+hex.EncodeToString(sum[:10])+`"`
	h.snapGen = h.dataGen
	return h.snapJSON, h.snapGzip, h.snapETag
}

// Current returns a deep-enough copy of the planet state for read-only use.
func (h *Hub) Current() planet.Snapshot {
	h.mu.RLock()
	defer h.mu.RUnlock()
	space := h.space
	snap := planet.Snapshot{
		GeneratedAt: time.Now().UTC(),
		Quakes:      append([]planet.Quake{}, h.quakes...),
		Events:      append([]planet.NaturalEvent{}, h.events...),
		Aurora:      h.aurora,
		Space:       &space,
		Launches:    append([]planet.Launch{}, h.launches...),
		NEOs:        append([]planet.NEO{}, h.neos...),
	}
	for _, s := range h.sources {
		snap.Sources = append(snap.Sources, s)
	}
	sort.Slice(snap.Sources, func(i, j int) bool { return snap.Sources[i].Name < snap.Sources[j].Name })
	return snap
}

// Satellites returns the gzipped element sets for a CelesTrak group.
func (h *Hub) Satellites(group string) (gz []byte, etag string, ok bool) {
	h.mu.RLock()
	sats, found := h.sats[group]
	gen := h.satGen[group]
	h.mu.RUnlock()
	if !found || len(sats) == 0 {
		return nil, "", false
	}
	h.snapMu.Lock()
	defer h.snapMu.Unlock()
	if c, ok := h.satCache[group]; ok && c.gen == gen {
		return c.gz, c.etag, true
	}
	plain, _ := json.Marshal(sats)
	sum := sha256.Sum256(plain)
	c := encoded{gen: gen, gz: gzipBytes(plain), etag: `"` + hex.EncodeToString(sum[:10]) + `"`}
	h.satCache[group] = c
	return c.gz, c.etag, true
}

func gzipBytes(b []byte) []byte {
	var buf bytes.Buffer
	zw, _ := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	zw.Write(b)
	zw.Close()
	return buf.Bytes()
}

// ---- Disk cache so a restart serves data immediately ------------------------------

type diskCache struct {
	Quakes   []planet.Quake                `json:"quakes"`
	Events   []planet.NaturalEvent         `json:"events"`
	Aurora   *planet.Aurora                `json:"aurora"`
	Space    planet.SpaceWeather           `json:"space"`
	Launches []planet.Launch               `json:"launches"`
	NEOs     []planet.NEO                  `json:"neos"`
	Sats     map[string][]planet.Satellite `json:"sats"`
	// Sources remembers when each feed last succeeded, so restarts do not refetch fresh data.
	Sources map[string]planet.SourceState `json:"sources,omitempty"`
}

func (h *Hub) cachePath() string { return filepath.Join(h.cacheDir, "planet-cache.json") }

func (h *Hub) loadCaches() {
	b, err := os.ReadFile(h.cachePath())
	if err != nil {
		return
	}
	var c diskCache
	if err := json.Unmarshal(b, &c); err != nil {
		h.log.Warn("ignoring corrupt cache", "err", err)
		return
	}
	h.quakes, h.events, h.aurora, h.space, h.launches, h.neos = c.Quakes, c.Events, c.Aurora, c.Space, c.Launches, c.NEOs
	if c.Sats != nil {
		h.sats = c.Sats
	}
	for name, st := range c.Sources {
		// Only feeds whose data actually came back from the cache count as fresh.
		if strings.HasPrefix(name, "celestrak-") && len(h.sats[strings.TrimPrefix(name, "celestrak-")]) == 0 {
			continue
		}
		st.OK = true
		h.sources[name] = st
	}
	h.log.Info("warm start from cache", "quakes", len(h.quakes), "events", len(h.events))
}

// PersistLoop writes the in-memory state to disk periodically.
func (h *Hub) PersistLoop(ctx context.Context) {
	t := time.NewTicker(2 * time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			h.persist()
			return
		case <-t.C:
			h.persist()
		}
	}
}

func (h *Hub) persist() {
	h.mu.RLock()
	c := diskCache{Quakes: h.quakes, Events: h.events, Aurora: h.aurora, Space: h.space, Launches: h.launches, NEOs: h.neos, Sats: h.sats,
		Sources: map[string]planet.SourceState{}}
	for name, st := range h.sources {
		if !st.UpdatedAt.IsZero() {
			c.Sources[name] = st
		}
	}
	b, err := json.Marshal(c)
	h.mu.RUnlock()
	if err != nil {
		return
	}
	tmp := h.cachePath() + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err == nil {
		_ = os.Rename(tmp, h.cachePath())
	}
}

var errNoData = errors.New("feed returned no usable data")

// errRateLimited marks upstream refusals (403/429) that call for a long back-off.
var errRateLimited = errors.New("rate limited by upstream")
