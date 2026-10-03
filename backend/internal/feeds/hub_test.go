package feeds

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"karman/internal/planet"
)

func quietHub(t *testing.T) *Hub {
	return NewHub(slog.New(slog.NewTextHandler(io.Discard, nil)), t.TempDir(), "DEMO_KEY")
}

func TestUpstreamRefusalIsRateLimited(t *testing.T) {
	for code, want := range map[int]bool{http.StatusForbidden: true, http.StatusTooManyRequests: true, http.StatusInternalServerError: false} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(code) }))
		_, err := quietHub(t).get(context.Background(), srv.URL)
		srv.Close()
		if err == nil || errors.Is(err, errRateLimited) != want {
			t.Errorf("HTTP %d: err=%v, rate limited=%v, want %v", code, err, errors.Is(err, errRateLimited), want)
		}
	}
}

func TestRestartKeepsFeedFreshness(t *testing.T) {
	dir := t.TempDir()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := NewHub(log, dir, "DEMO_KEY")
	fetched := time.Now().UTC().Add(-30 * time.Minute)
	h.sats["stations"] = []planet.Satellite{{Name: "ISS (ZARYA)", NoradID: 25544}}
	h.sources["celestrak-stations"] = planet.SourceState{Name: "celestrak-stations", UpdatedAt: fetched, OK: true}
	h.sources["celestrak-starlink"] = planet.SourceState{Name: "celestrak-starlink", UpdatedAt: fetched, OK: true} // no data cached
	h.persist()

	warm := NewHub(log, dir, "DEMO_KEY")
	if got := warm.sources["celestrak-stations"].UpdatedAt; !got.Equal(fetched) {
		t.Fatalf("stations freshness not restored: %v", got)
	}
	if _, ok := warm.sources["celestrak-starlink"]; ok {
		t.Fatal("a feed without cached data must not be treated as fresh")
	}
}
