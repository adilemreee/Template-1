package ai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"strings"
	"sync"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

// Briefing is a short narrated tour of the planet that the app performs on the globe.
type Briefing struct {
	ID          string    `json:"id"`
	Language    string    `json:"language"`
	Title       string    `json:"title"`
	Dek         string    `json:"dek"`
	Scenes      []Scene   `json:"scenes"`
	Signoff     string    `json:"signoff"`
	GeneratedAt time.Time `json:"generatedAt"`
	Source      string    `json:"source"` // "ai" or "template"
}

type Scene struct {
	Focus      string  `json:"focus"`
	RefID      string  `json:"refId"`
	Lat        float64 `json:"lat"`
	Lon        float64 `json:"lon"`
	AltitudeKm float64 `json:"altitudeKm"`
	Headline   string  `json:"headline"`
	Narration  string  `json:"narration"`
}

// SupportedLanguages bounds what the cache can be asked to generate.
var SupportedLanguages = map[string]string{
	"en": "English", "tr": "Turkish", "de": "German", "fr": "French", "es": "Spanish", "it": "Italian",
	"pt": "Portuguese", "nl": "Dutch", "ja": "Japanese", "ko": "Korean", "zh": "Simplified Chinese", "ar": "Arabic", "ru": "Russian",
}

type Store interface {
	GetBriefing(key string) (*Briefing, bool)
	PutBriefing(key string, b *Briefing) error
}

type Service struct {
	log    *slog.Logger
	client *anthropic.Client
	model  string
	store  Store
	snap   func() Digest

	mu       sync.Mutex
	inflight map[string]chan struct{}
	// failedUntil short-circuits generation after a failure so users get the template
	// instantly instead of waiting for the model to time out again.
	failedUntil map[string]time.Time
}

func NewService(log *slog.Logger, apiKey, model string, store Store, digest func() Digest) *Service {
	s := &Service{log: log, model: model, store: store, snap: digest, inflight: map[string]chan struct{}{}, failedUntil: map[string]time.Time{}}
	if apiKey != "" {
		c := anthropic.NewClient(option.WithAPIKey(apiKey), option.WithMaxRetries(2))
		s.client = &c
	}
	return s
}

func (s *Service) Enabled() bool { return s.client != nil }

// requestOptions opts every call into server-side refusal fallbacks.
func requestOptions() []option.RequestOption {
	return []option.RequestOption{
		option.WithHeaderAdd("anthropic-beta", "server-side-fallback-2026-07-01"),
		option.WithJSONSet("fallbacks", "default"),
	}
}

func bucket(t time.Time) string {
	return t.UTC().Truncate(3 * time.Hour).Format("2006010215")
}

// Briefing returns the cached briefing for the current 3-hour window, generating it once.
func (s *Service) Briefing(ctx context.Context, lang string) (*Briefing, error) {
	if _, ok := SupportedLanguages[lang]; !ok {
		lang = "en"
	}
	key := lang + ":" + bucket(time.Now())
	if b, ok := s.store.GetBriefing(key); ok {
		return b, nil
	}

	s.mu.Lock()
	if ch, ok := s.inflight[key]; ok {
		s.mu.Unlock()
		select {
		case <-ch:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		if b, ok := s.store.GetBriefing(key); ok {
			return b, nil
		}
		return Template(s.snap(), lang), nil
	}
	ch := make(chan struct{})
	s.inflight[key] = ch
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.inflight, key)
		s.mu.Unlock()
		close(ch)
	}()

	digest := s.snap()
	var b *Briefing
	s.mu.Lock()
	coolingDown := time.Now().Before(s.failedUntil[key])
	s.mu.Unlock()
	if s.client != nil && !coolingDown {
		gctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 90*time.Second)
		generated, err := s.generate(gctx, digest, lang)
		cancel()
		if err != nil {
			s.log.Warn("briefing generation failed, using template", "lang", lang, "err", err)
			s.mu.Lock()
			s.failedUntil[key] = time.Now().Add(10 * time.Minute)
			s.mu.Unlock()
		} else {
			b = generated
		}
	}
	if b == nil {
		b = Template(digest, lang)
		// Template briefings are cheap; cache briefly so an AI one can replace it soon.
		_ = s.store.PutBriefing(key+":tpl:"+time.Now().UTC().Format("1504"), b)
		return b, nil
	}
	b.ID = key
	_ = s.store.PutBriefing(key, b)
	return b, nil
}

// Prewarm keeps the most common languages ready so users never wait.
func (s *Service) Prewarm(ctx context.Context, langs ...string) {
	if s.client == nil {
		return
	}
	go func() {
		t := time.NewTicker(10 * time.Minute)
		defer t.Stop()
		for {
			for _, l := range langs {
				if _, err := s.Briefing(ctx, l); err != nil {
					s.log.Warn("prewarm", "lang", l, "err", err)
				}
			}
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			}
		}
	}()
}

const briefingSystem = `You are the narrator of Kármán, a premium iOS app that renders the living planet in real time on a cinematic 3D globe.

Write a "Planet Briefing": a 60-90 second narrated tour built only from the live data digest the user provides. The app flies its camera to each scene's coordinates while a text-to-speech voice reads the narration and the headline appears on screen.

Structure:
- 5 to 7 scenes. Open with the single most consequential or striking item; close with something that leaves a sense of wonder (aurora, a launch, the Sun, an asteroid passing harmlessly).
- Every scene must reference exactly one digest item through its refId and reuse that item's lat/lon. Use focus "overview" with refId "" only for an optional opening wide shot, at most once.
- altitudeKm frames the shot: 2500-5000 for a single quake, fire or volcano; 5000-9000 for storms and launch sites; 12000-20000 for aurora ovals, the Sun and asteroids.

Narration is spoken aloud:
- 25-45 words per scene, short sentences, written for the ear. Say "magnitude 6.2", never "M6.2". Spell out units on first use. No markdown, emojis, URLs, parentheses or lists.
- Be strictly accurate: state only what the digest contains. Never invent casualties, damage, evacuations or forecasts. Note that USGS tsunami flags are informational and not warnings.
- Calm, intelligent, quietly awe-struck - a planetary scientist on a late-night documentary, not a news anchor. Give one sentence of context that helps a curious person understand why something happens, where it fits.
- Headlines: at most 48 characters, no trailing period.
- If the day is quiet, say so honestly and find the beauty in it.`

var briefingSchema = map[string]any{
	"type": "object",
	"properties": map[string]any{
		"title":   map[string]any{"type": "string"},
		"dek":     map[string]any{"type": "string"},
		"signoff": map[string]any{"type": "string"},
		"scenes": map[string]any{
			"type": "array",
			"items": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"focus":      map[string]any{"type": "string", "enum": []string{"overview", "quake", "storm", "wildfire", "volcano", "ice", "aurora", "sun", "launch", "asteroid", "other"}},
					"refId":      map[string]any{"type": "string"},
					"lat":        map[string]any{"type": "number"},
					"lon":        map[string]any{"type": "number"},
					"altitudeKm": map[string]any{"type": "number"},
					"headline":   map[string]any{"type": "string"},
					"narration":  map[string]any{"type": "string"},
				},
				"required":             []string{"focus", "refId", "lat", "lon", "altitudeKm", "headline", "narration"},
				"additionalProperties": false,
			},
		},
	},
	"required":             []string{"title", "dek", "scenes", "signoff"},
	"additionalProperties": false,
}

func (s *Service) generate(ctx context.Context, d Digest, lang string) (*Briefing, error) {
	digestJSON, _ := json.MarshalIndent(d, "", " ")
	user := fmt.Sprintf("Language: write title, dek, headlines, narration and signoff in %s.\nThe title should evoke the moment (time of day in UTC is in asOf).\n\nLive data digest:\n%s", SupportedLanguages[lang], digestJSON)

	msg, err := s.client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:     anthropic.Model(s.model),
		MaxTokens: 16000,
		System:    []anthropic.TextBlockParam{{Text: briefingSystem}},
		Messages:  []anthropic.MessageParam{anthropic.NewUserMessage(anthropic.NewTextBlock(user))},
		OutputConfig: anthropic.OutputConfigParam{
			Effort: anthropic.OutputConfigEffortMedium,
			Format: anthropic.JSONOutputFormatParam{Schema: briefingSchema},
		},
	}, requestOptions()...)
	if err != nil {
		return nil, err
	}
	if msg.StopReason == anthropic.StopReasonRefusal {
		return nil, errors.New("model declined the briefing request")
	}
	if msg.StopReason == anthropic.StopReasonMaxTokens {
		return nil, errors.New("briefing truncated")
	}
	var text strings.Builder
	for _, block := range msg.Content {
		if t, ok := block.AsAny().(anthropic.TextBlock); ok {
			text.WriteString(t.Text)
		}
	}
	var b Briefing
	if err := json.Unmarshal([]byte(text.String()), &b); err != nil {
		return nil, fmt.Errorf("parse briefing: %w", err)
	}
	if err := validateBriefing(&b, d); err != nil {
		return nil, err
	}
	b.Language = lang
	b.GeneratedAt = time.Now().UTC()
	b.Source = "ai"
	s.log.Info("briefing generated", "lang", lang, "scenes", len(b.Scenes), "in", msg.Usage.InputTokens, "out", msg.Usage.OutputTokens)
	return &b, nil
}

// validateBriefing drops scenes that point at unknown items and clamps camera framing.
func validateBriefing(b *Briefing, d Digest) error {
	known := map[string][2]float64{}
	add := func(items []DigestItem) {
		for _, i := range items {
			known[i.ID] = [2]float64{i.Lat, i.Lon}
		}
	}
	add(d.Quakes)
	add(d.Storms)
	add(d.Volcanoes)
	add(d.Fires.Notable)
	add(d.Ice)
	add(d.Other)
	add(d.Space.Items)
	add(d.Launches)
	add(d.Asteroids)

	var scenes []Scene
	for _, sc := range b.Scenes {
		if sc.Focus != "overview" {
			pos, ok := known[sc.RefID]
			if !ok {
				continue
			}
			if sc.Focus != "asteroid" {
				sc.Lat, sc.Lon = pos[0], pos[1]
			}
		}
		sc.AltitudeKm = math.Max(1800, math.Min(sc.AltitudeKm, 22000))
		sc.Headline = strings.TrimSuffix(strings.TrimSpace(sc.Headline), ".")
		sc.Narration = strings.TrimSpace(sc.Narration)
		if sc.Narration == "" {
			continue
		}
		scenes = append(scenes, sc)
	}
	if len(scenes) < 3 {
		return fmt.Errorf("briefing has only %d usable scenes", len(scenes))
	}
	if len(scenes) > 8 {
		scenes = scenes[:8]
	}
	b.Scenes = scenes
	return nil
}
