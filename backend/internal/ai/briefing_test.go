package ai

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

type memStore struct {
	mu sync.Mutex
	m  map[string]*Briefing
}

func (s *memStore) GetBriefing(k string) (*Briefing, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, ok := s.m[k]
	return b, ok
}

func (s *memStore) PutBriefing(k string, b *Briefing) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.m[k] = b
	return nil
}

func sampleDigest() Digest {
	return Digest{
		AsOf:   time.Now().UTC().Format(time.RFC3339),
		Quakes: []DigestItem{{ID: "us1", Kind: "quake", Title: "Kamchatka", Lat: 51.7, Lon: 159.9, When: "3 hours ago", Details: "magnitude 6.1, depth 30 km"}},
		Storms: []DigestItem{{ID: "EONET_1", Kind: "storm", Title: "Hurricane Rachel", Lat: 19.3, Lon: -110.6, When: "2 hours ago", Details: "95 kts"}},
		Space:  SpaceDigest{Kp: 2, Items: []DigestItem{{ID: "aurora-north", Kind: "aurora", Lat: 67, Lon: 30}}},
	}
}

// TestGenerateBriefingRequestShape checks what we send to the Messages API and that the
// structured response is parsed, validated and re-anchored to digest coordinates.
func TestGenerateBriefingRequestShape(t *testing.T) {
	var got map[string]any
	var beta string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &got)
		beta = r.Header.Get("anthropic-beta")
		briefing := `{"title":"Tonight on Earth","dek":"A restless Pacific","signoff":"Good night.","scenes":[` +
			`{"focus":"quake","refId":"us1","lat":0,"lon":0,"altitudeKm":3000,"headline":"Kamchatka shakes.","narration":"A magnitude 6.1 earthquake struck off Kamchatka."},` +
			`{"focus":"storm","refId":"EONET_1","lat":19,"lon":-110,"altitudeKm":6000,"headline":"Rachel","narration":"Hurricane Rachel churns off Mexico."},` +
			`{"focus":"quake","refId":"does-not-exist","lat":1,"lon":1,"altitudeKm":3000,"headline":"Ghost","narration":"Invented."},` +
			`{"focus":"aurora","refId":"aurora-north","lat":67,"lon":30,"altitudeKm":90000,"headline":"Aurora","narration":"A faint oval crowns the north."}]}`
		resp := map[string]any{
			"id": "msg_test", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
			"content":     []any{map[string]any{"type": "text", "text": briefing}},
			"stop_reason": "end_turn",
			"usage":       map[string]any{"input_tokens": 100, "output_tokens": 200},
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	client := anthropic.NewClient(option.WithAPIKey("test"), option.WithBaseURL(srv.URL), option.WithMaxRetries(0))
	s := &Service{log: slog.New(slog.NewTextHandler(io.Discard, nil)), client: &client, model: "claude-opus-5-5",
		store: &memStore{m: map[string]*Briefing{}}, snap: sampleDigest, inflight: map[string]chan struct{}{}}

	b, err := s.generate(context.Background(), sampleDigest(), "tr")
	if err != nil {
		t.Fatalf("generate: %v", err)
	}

	if got["model"] != "claude-opus-5-5" {
		t.Errorf("model = %v", got["model"])
	}
	if got["fallbacks"] != "default" {
		t.Errorf("fallbacks = %v, want \"default\"", got["fallbacks"])
	}
	if !strings.Contains(beta, "server-side-fallback-2026-07-01") {
		t.Errorf("beta header = %q", beta)
	}
	oc, _ := got["output_config"].(map[string]any)
	if oc["effort"] != "medium" {
		t.Errorf("effort = %v", oc["effort"])
	}
	if f, _ := oc["format"].(map[string]any); f["type"] != "json_schema" {
		t.Errorf("format = %v", oc["format"])
	}
	if _, ok := got["thinking"]; ok {
		t.Errorf("thinking must be omitted on Opus 5.5")
	}

	if len(b.Scenes) != 3 {
		t.Fatalf("scenes = %d, want 3 (unknown refId dropped)", len(b.Scenes))
	}
	if b.Scenes[0].Lat != 51.7 || b.Scenes[0].Lon != 159.9 {
		t.Errorf("scene not re-anchored to digest coordinates: %+v", b.Scenes[0])
	}
	if b.Scenes[0].Headline != "Kamchatka shakes" {
		t.Errorf("headline trailing period not trimmed: %q", b.Scenes[0].Headline)
	}
	if b.Scenes[2].AltitudeKm != 22000 {
		t.Errorf("altitude not clamped: %v", b.Scenes[2].AltitudeKm)
	}
	if b.Source != "ai" || b.Language != "tr" {
		t.Errorf("source/lang = %s/%s", b.Source, b.Language)
	}
}

func TestTemplateBriefingHasScenes(t *testing.T) {
	for _, lang := range []string{"en", "tr", "de"} {
		b := Template(sampleDigest(), lang)
		if len(b.Scenes) < 3 {
			t.Errorf("%s: only %d scenes", lang, len(b.Scenes))
		}
		for _, sc := range b.Scenes {
			if strings.TrimSpace(sc.Narration) == "" || strings.Contains(sc.Narration, "%!") {
				t.Errorf("%s: bad narration %q", lang, sc.Narration)
			}
		}
	}
}

func TestSubsolarPointEquinox(t *testing.T) {
	ts := time.Date(2024, 3, 20, 3, 6, 0, 0, time.UTC)
	lat, _ := SubsolarPoint(ts)
	if lat > 0.2 || lat < -0.2 {
		t.Errorf("subsolar latitude at equinox = %.3f", lat)
	}
}
