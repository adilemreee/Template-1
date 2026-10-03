// Package httpapi exposes the planet state, satellites, imagery and AI features over HTTPS.
package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"karman/internal/ai"
	"karman/internal/auth"
	"karman/internal/feeds"
	"karman/internal/store"
)

type Server struct {
	Log        *slog.Logger
	Hub        *feeds.Hub
	AI         *ai.Service
	Auth       *auth.Verifier
	Store      *store.Store
	AskLimit   int
	PushActive bool
	Version    string
	// SupportEmail is shown on /support when set (KARMAN_SUPPORT_EMAIL).
	SupportEmail string
	// SiteDir, when set, serves the static product website at / (KARMAN_SITE_DIR).
	SiteDir string

	limiter     *ipLimiter
	supportOnce sync.Once
	supportPage []byte
}

func (s *Server) Handler() http.Handler {
	s.limiter = newIPLimiter(240, time.Minute)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("GET /privacy", s.privacy)
	mux.HandleFunc("GET /support", s.support)
	mux.HandleFunc("GET /v1/snapshot", s.snapshot)
	mux.HandleFunc("GET /v1/satellites/{group}", s.satellites)
	mux.HandleFunc("GET /v1/imagery", s.imageryIndex)
	mux.HandleFunc("GET /v1/imagery/{day}", s.imagery)
	mux.HandleFunc("GET /v1/briefing", s.briefing)
	mux.HandleFunc("GET /v1/sun/{band}", s.sun)
	mux.HandleFunc("GET /v1/sun/{band}/frames", s.sunFrames)
	mux.HandleFunc("GET /v1/sun/{band}/frames/{id}", s.sunFrame)
	mux.HandleFunc("GET /v1/weather", s.weatherIndex)
	mux.HandleFunc("GET /v1/weather/{id}", s.weatherFrame)
	mux.HandleFunc("GET /v1/quakes/year", s.quakeYear)
	mux.HandleFunc("GET /v1/plates", s.plates)
	mux.HandleFunc("GET /v1/sky/clouds", s.skyClouds)
	mux.HandleFunc("POST /v1/auth/app-transaction", s.authAppTransaction)
	mux.HandleFunc("GET /v1/ask/quota", s.askQuota)
	mux.HandleFunc("POST /v1/ask", s.ask)
	mux.HandleFunc("POST /v1/devices", s.registerDevice)
	mux.HandleFunc("DELETE /v1/devices/{token}", s.deleteDevice)
	if s.SiteDir != "" {
		mux.Handle("GET /", siteHandler(s.SiteDir))
	}
	return s.middleware(mux)
}

func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ip := clientIP(r)
		if !s.limiter.allow(ip) {
			writeError(w, http.StatusTooManyRequests, "slow down")
			return
		}
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Server", "karman")
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(rec, r)
		if r.URL.Path != "/healthz" {
			s.Log.Info("http", "method", r.Method, "path", r.URL.Path, "status", rec.status, "ms", time.Since(start).Milliseconds(), "ip", ip)
		}
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Flush() {
	if f, ok := r.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	// Behind a reverse proxy on the same machine (nginx serving the website), use the address
	// it forwards; the header is never trusted from anyone else.
	if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
		if real := strings.TrimSpace(r.Header.Get("X-Real-IP")); net.ParseIP(real) != nil {
			return real
		}
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			if last := strings.TrimSpace(parts[len(parts)-1]); net.ParseIP(last) != nil {
				return last
			}
		}
	}
	return host
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// serveCached writes a pre-gzipped body, honouring If-None-Match.
func serveCached(w http.ResponseWriter, r *http.Request, gz []byte, plain func() []byte, etag string, maxAge int) {
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", fmt.Sprintf("public, max-age=%d", maxAge))
	w.Header().Set("Vary", "Accept-Encoding")
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if match := r.Header.Get("If-None-Match"); match != "" && match == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("Content-Length", strconv.Itoa(len(gz)))
		_, _ = w.Write(gz)
		return
	}
	_, _ = w.Write(plain())
}

// ---- handlers ------------------------------------------------------------------------------

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	snap := s.Hub.Current()
	year, _ := s.Hub.YearStats()
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "version": s.Version, "ai": s.AI.Enabled(), "push": s.PushActive,
		"quakes": len(snap.Quakes), "events": len(snap.Events), "sources": snap.Sources, "stats": s.Store.Stats(),
		"weatherFrames": len(s.Hub.WeatherFrames()), "quakesYear": year.M45Plus,
	})
}

func (s *Server) snapshot(w http.ResponseWriter, r *http.Request) {
	plain, gz, etag := s.Hub.Snapshot()
	serveCached(w, r, gz, func() []byte { return plain }, etag, 30)
}

func (s *Server) satellites(w http.ResponseWriter, r *http.Request) {
	group := r.PathValue("group")
	if !feeds.SatelliteGroups[group] {
		writeError(w, http.StatusNotFound, "unknown group")
		return
	}
	gz, etag, ok := s.Hub.Satellites(group)
	if !ok {
		writeError(w, http.StatusServiceUnavailable, "elements not loaded yet")
		return
	}
	serveCached(w, r, gz, func() []byte { return gunzip(gz) }, etag, 3600)
}

func (s *Server) imageryIndex(w http.ResponseWriter, r *http.Request) {
	days := s.Hub.ImageryDays()
	w.Header().Set("Cache-Control", "public, max-age=600")
	writeJSON(w, http.StatusOK, map[string]any{"days": days, "attribution": "NASA GIBS / EOSDIS - VIIRS Corrected Reflectance"})
}

func (s *Server) imagery(w http.ResponseWriter, r *http.Request) {
	day := strings.TrimSuffix(r.PathValue("day"), ".jpg")
	if day == "latest" {
		days := s.Hub.ImageryDays()
		if len(days) == 0 {
			writeError(w, http.StatusNotFound, "no imagery yet")
			return
		}
		day = days[0]
	}
	path, ok := s.Hub.ImageryPath(day)
	if !ok {
		writeError(w, http.StatusNotFound, "no imagery for that day")
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=86400, immutable")
	w.Header().Set("X-Imagery-Day", day)
	http.ServeFile(w, r, path)
}

func (s *Server) sun(w http.ResponseWriter, r *http.Request) {
	band := strings.TrimSuffix(r.PathValue("band"), ".jpg")
	img, taken, err := s.Hub.SunImage(r.Context(), band)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "sun image unavailable")
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "public, max-age=300")
	w.Header().Set("X-Observed", taken.UTC().Format(time.RFC3339))
	w.Header().Set("X-Attribution", "NOAA GOES-19 SUVI")
	_, _ = w.Write(img)
}

// sunFrames lists the band's time-lapse (oldest first); frame images are immutable.
func (s *Server) sunFrames(w http.ResponseWriter, r *http.Request) {
	band := r.PathValue("band")
	if !feeds.SunBands[band] {
		writeError(w, http.StatusNotFound, "unknown band")
		return
	}
	frames := s.Hub.SunFrames(band)
	if len(frames) == 0 {
		writeError(w, http.StatusServiceUnavailable, "time-lapse not ready")
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=300")
	writeJSON(w, http.StatusOK, map[string]any{"band": band, "frames": frames, "attribution": "NOAA GOES-19 SUVI"})
}

func (s *Server) sunFrame(w http.ResponseWriter, r *http.Request) {
	jpg, ok := s.Hub.SunFrameJPEG(r.PathValue("band"), strings.TrimSuffix(r.PathValue("id"), ".jpg"))
	if !ok {
		writeError(w, http.StatusNotFound, "frame not found")
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	_, _ = w.Write(jpg)
}

// weatherIndex lists the GFS frames (oldest first); each frame's bytes never change.
func (s *Server) weatherIndex(w http.ResponseWriter, r *http.Request) {
	frames := s.Hub.WeatherFrames()
	if len(frames) == 0 {
		writeError(w, http.StatusServiceUnavailable, "weather not ready")
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=600")
	writeJSON(w, http.StatusOK, map[string]any{
		"frames": frames, "width": feeds.WeatherWidth, "height": feeds.WeatherHeight, "encoding": "rgba8-uvtp",
		"attribution": "NOAA GFS via PacIOOS ERDDAP",
	})
}

func (s *Server) weatherFrame(w http.ResponseWriter, r *http.Request) {
	raw, gz, ok := s.Hub.WeatherFrameData(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "frame not found")
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	w.Header().Set("Vary", "Accept-Encoding")
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("Content-Length", strconv.Itoa(len(gz)))
		_, _ = w.Write(gz)
		return
	}
	w.Header().Set("Content-Length", strconv.Itoa(len(raw)))
	_, _ = w.Write(raw)
}

// quakeYear serves the last year of M4.5+ earthquakes for the year replay.
func (s *Server) quakeYear(w http.ResponseWriter, r *http.Request) {
	gz, etag, ok := s.Hub.QuakeHistory()
	if !ok {
		writeError(w, http.StatusServiceUnavailable, "history not ready")
		return
	}
	serveCached(w, r, gz, func() []byte { return gunzip(gz) }, etag, 3600)
}

func (s *Server) plates(w http.ResponseWriter, r *http.Request) {
	plain, gz, etag := feeds.Plates()
	serveCached(w, r, gz, func() []byte { return plain }, etag, 86400)
}

// skyClouds is the stargazing cloud forecast near a location already rounded by the app.
func (s *Server) skyClouds(w http.ResponseWriter, r *http.Request) {
	lat, err1 := strconv.ParseFloat(r.URL.Query().Get("lat"), 64)
	lon, err2 := strconv.ParseFloat(r.URL.Query().Get("lon"), 64)
	if err1 != nil || err2 != nil || math.IsNaN(lat) || math.IsNaN(lon) || lat < -90 || lat > 90 || lon < -180 || lon > 180 {
		writeError(w, http.StatusBadRequest, "lat and lon required")
		return
	}
	fc, err := s.Hub.Clouds(r.Context(), lat, lon)
	if err != nil {
		s.Log.Warn("clouds", "err", err)
		writeError(w, http.StatusServiceUnavailable, "cloud forecast unavailable")
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=900")
	writeJSON(w, http.StatusOK, fc)
}

func (s *Server) briefing(w http.ResponseWriter, r *http.Request) {
	lang := strings.ToLower(r.URL.Query().Get("lang"))
	if i := strings.IndexAny(lang, "-_"); i > 0 {
		lang = lang[:i]
	}
	b, err := s.AI.Briefing(r.Context(), lang)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "briefing unavailable")
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=300")
	writeJSON(w, http.StatusOK, b)
}

func (s *Server) authAppTransaction(w http.ResponseWriter, r *http.Request) {
	var body struct {
		JWS string `json:"jws"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&body); err != nil || body.JWS == "" {
		writeError(w, http.StatusBadRequest, "missing jws")
		return
	}
	tx, err := s.Auth.VerifyAppTransaction(body.JWS)
	if err != nil {
		s.Log.Warn("app transaction rejected", "err", err)
		writeError(w, http.StatusUnauthorized, "purchase could not be verified")
		return
	}
	subject := auth.SubjectFor(tx)
	s.Store.RecordPurchaser(subject, tx.Environment)
	token, exp := s.Auth.Issue(subject, tx.Environment, 30*24*time.Hour)
	writeJSON(w, http.StatusOK, map[string]any{"token": token, "expiresAt": exp.UTC()})
}

func (s *Server) claims(w http.ResponseWriter, r *http.Request) (*auth.Claims, bool) {
	c, err := s.Auth.Check(r.Header.Get("Authorization"))
	if err != nil {
		status := http.StatusUnauthorized
		writeError(w, status, err.Error())
		return nil, false
	}
	return c, true
}

func (s *Server) askQuota(w http.ResponseWriter, r *http.Request) {
	c, ok := s.claims(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"remaining": s.Store.Remaining(c.Subject, s.AskLimit), "limit": s.AskLimit, "enabled": s.AI.Enabled()})
}

func (s *Server) ask(w http.ResponseWriter, r *http.Request) {
	c, ok := s.claims(w, r)
	if !ok {
		return
	}
	var req ai.AskRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32<<10)).Decode(&req); err != nil || strings.TrimSpace(req.Question) == "" {
		writeError(w, http.StatusBadRequest, "missing question")
		return
	}
	if len([]rune(req.Question)) > 600 {
		writeError(w, http.StatusBadRequest, "question too long")
		return
	}
	if !s.AI.Enabled() {
		writeError(w, http.StatusServiceUnavailable, "ai disabled")
		return
	}
	remaining, err := s.Store.Consume(c.Subject, s.AskLimit)
	if errors.Is(err, store.ErrQuota) {
		writeError(w, http.StatusTooManyRequests, "daily limit reached")
		return
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "quota error")
		return
	}

	flusher, _ := w.(http.Flusher)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.Header().Set("X-Quota-Remaining", strconv.Itoa(remaining))
	w.WriteHeader(http.StatusOK)
	var mu sync.Mutex
	emit := func(event string, v any) error {
		mu.Lock()
		defer mu.Unlock()
		b, _ := json.Marshal(v)
		if _, err := fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, b); err != nil {
			return err
		}
		if flusher != nil {
			flusher.Flush()
		}
		return nil
	}
	err = s.AI.Ask(r.Context(), req,
		func(text string) error { return emit("delta", map[string]string{"text": text}) },
		func(items []ai.GlobeFocus) error { return emit("focus", map[string]any{"items": items}) })
	if err != nil {
		s.Log.Warn("ask failed", "err", err)
		s.Store.Refund(c.Subject)
		_ = emit("error", map[string]string{"message": "The planet is a little busy - please try again in a moment."})
		return
	}
	_ = emit("done", map[string]int{"remaining": remaining})
}

func (s *Server) registerDevice(w http.ResponseWriter, r *http.Request) {
	var d store.Device
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&d); err != nil || len(d.Token) < 32 || len(d.Token) > 200 {
		writeError(w, http.StatusBadRequest, "invalid device")
		return
	}
	if d.Env != "sandbox" {
		d.Env = "production"
	}
	// Coarsen location to ~50 km; we never need more for alerts.
	if d.Lat != nil && d.Lon != nil {
		lat, lon := roundTo(*d.Lat, 0.5), roundTo(*d.Lon, 0.5)
		d.Lat, d.Lon = &lat, &lon
	}
	d.Prefs.QuakeRadiusKm = clamp(d.Prefs.QuakeRadiusKm, 50, 2000)
	if len(d.Places) > maxPlaces {
		d.Places = d.Places[:maxPlaces]
	}
	places := d.Places[:0]
	for _, p := range d.Places {
		name := strings.Join(strings.Fields(p.Name), " ")
		if r := []rune(name); len(r) > 40 {
			name = string(r[:40])
		}
		if name == "" || math.IsNaN(p.Lat) || math.IsNaN(p.Lon) || p.Lat < -90 || p.Lat > 90 || p.Lon < -180 || p.Lon > 180 {
			continue
		}
		places = append(places, store.Place{Name: name, Lat: roundTo(p.Lat, 0.5), Lon: roundTo(p.Lon, 0.5)})
	}
	d.Places = places
	if err := s.Store.UpsertDevice(d); err != nil {
		writeError(w, http.StatusInternalServerError, "could not save")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "push": s.PushActive})
}

func (s *Server) deleteDevice(w http.ResponseWriter, r *http.Request) {
	_ = s.Store.DeleteDevice(r.PathValue("token"))
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// maxPlaces bounds how many watched places a device can register.
const maxPlaces = 5

func roundTo(v, step float64) float64 {
	return float64(int(v/step+0.5*sign(v))) * step
}

func sign(v float64) float64 {
	if v < 0 {
		return -1
	}
	return 1
}

func clamp(v, lo, hi float64) float64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
