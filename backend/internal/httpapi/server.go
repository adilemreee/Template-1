// Package httpapi exposes the planet state, satellites, imagery and AI features over HTTPS.
package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
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

	limiter *ipLimiter
}

func (s *Server) Handler() http.Handler {
	s.limiter = newIPLimiter(240, time.Minute)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("GET /v1/snapshot", s.snapshot)
	mux.HandleFunc("GET /v1/satellites/{group}", s.satellites)
	mux.HandleFunc("GET /v1/imagery", s.imageryIndex)
	mux.HandleFunc("GET /v1/imagery/{day}", s.imagery)
	mux.HandleFunc("GET /v1/briefing", s.briefing)
	mux.HandleFunc("GET /v1/sun/{band}", s.sun)
	mux.HandleFunc("POST /v1/auth/app-transaction", s.authAppTransaction)
	mux.HandleFunc("GET /v1/ask/quota", s.askQuota)
	mux.HandleFunc("POST /v1/ask", s.ask)
	mux.HandleFunc("POST /v1/devices", s.registerDevice)
	mux.HandleFunc("DELETE /v1/devices/{token}", s.deleteDevice)
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
		return r.RemoteAddr
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
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "version": s.Version, "ai": s.AI.Enabled(), "push": s.PushActive,
		"quakes": len(snap.Quakes), "events": len(snap.Events), "sources": snap.Sources, "stats": s.Store.Stats(),
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
	err = s.AI.Ask(r.Context(), req, func(text string) error { return emit("delta", map[string]string{"text": text}) })
	if err != nil {
		s.Log.Warn("ask failed", "err", err)
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
