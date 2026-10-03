package ai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/anthropics/anthropic-sdk-go"
)

type Turn struct {
	Role string `json:"role"` // "user" or "assistant"
	Text string `json:"text"`
}

type AskRequest struct {
	Question string   `json:"question"`
	Language string   `json:"language"`
	Lat      *float64 `json:"lat,omitempty"`
	Lon      *float64 `json:"lon,omitempty"`
	History  []Turn   `json:"history,omitempty"`
}

var ErrDisabled = errors.New("AI is not configured on this server")

const askSystem = `You are Kármán, the planetary-science companion inside a premium iOS app that shows the living Earth in real time: earthquakes, storms, wildfires, volcanoes, aurora and space weather, satellites, rocket launches and passing asteroids.

Answer the user's question using the live data digest below as your source of truth for anything happening now; use your general scientific knowledge to explain how and why. If the digest does not cover something current, say so plainly rather than guessing - never invent events, casualties, damage or forecasts.

Style: warm, precise and concise - usually 2-4 short paragraphs, under 160 words, plain text without markdown headings, tables or bullet symbols. Use metric units and include imperial in parentheses only when it helps. Reply in the language the user writes in (or the requested language). For safety questions (earthquake, tsunami, storm), be calm and point people to their local authorities.`

// Ask streams an answer; onDelta receives text fragments as they arrive.
func (s *Service) Ask(ctx context.Context, req AskRequest, onDelta func(string) error) error {
	if s.client == nil {
		return ErrDisabled
	}
	digest := s.snap()
	digestJSON, _ := json.Marshal(digest)

	lang := SupportedLanguages[req.Language]
	if lang == "" {
		lang = "the user's language"
	}
	where := "unknown"
	if req.Lat != nil && req.Lon != nil {
		where = fmt.Sprintf("approximately %.0f°, %.0f° (lat, lon)", *req.Lat, *req.Lon)
	}

	// Normalise history: strictly alternating turns that start with the user and end with
	// the assistant, so the new question becomes the final user turn.
	var turns []Turn
	for _, t := range trimHistory(req.History, 6) {
		text := strings.TrimSpace(t.Text)
		role := "user"
		if t.Role == "assistant" {
			role = "assistant"
		}
		if text == "" {
			continue
		}
		if n := len(turns); n > 0 && turns[n-1].Role == role {
			turns[n-1].Text += "\n\n" + text
			continue
		}
		turns = append(turns, Turn{Role: role, Text: text})
	}
	for len(turns) > 0 && turns[0].Role == "assistant" {
		turns = turns[1:]
	}
	if n := len(turns); n > 0 && turns[n-1].Role == "user" {
		turns = turns[:n-1]
	}
	var msgs []anthropic.MessageParam
	for _, t := range turns {
		if t.Role == "assistant" {
			msgs = append(msgs, anthropic.NewAssistantMessage(anthropic.NewTextBlock(t.Text)))
		} else {
			msgs = append(msgs, anthropic.NewUserMessage(anthropic.NewTextBlock(t.Text)))
		}
	}
	question := fmt.Sprintf("(Preferred language: %s. My location: %s.)\n\n%s", lang, where, strings.TrimSpace(req.Question))
	msgs = append(msgs, anthropic.NewUserMessage(anthropic.NewTextBlock(question)))

	stream := s.client.Messages.NewStreaming(ctx, anthropic.MessageNewParams{
		Model:     anthropic.Model(s.model),
		MaxTokens: 4000,
		System: []anthropic.TextBlockParam{
			{Text: askSystem},
			{Text: "Live data digest (UTC):\n" + string(digestJSON), CacheControl: anthropic.NewCacheControlEphemeralParam()},
		},
		Messages:     msgs,
		OutputConfig: anthropic.OutputConfigParam{Effort: anthropic.OutputConfigEffortLow},
	}, requestOptions()...)
	defer stream.Close()

	refused := false
	for stream.Next() {
		event := stream.Current()
		switch ev := event.AsAny().(type) {
		case anthropic.ContentBlockDeltaEvent:
			if d, ok := ev.Delta.AsAny().(anthropic.TextDelta); ok && d.Text != "" {
				if err := onDelta(d.Text); err != nil {
					return err
				}
			}
		case anthropic.MessageDeltaEvent:
			if ev.Delta.StopReason == anthropic.StopReasonRefusal {
				refused = true
			}
		}
	}
	if err := stream.Err(); err != nil {
		return err
	}
	if refused {
		return onDelta("\n\nI can't help with that one, but I'm happy to talk about anything happening on the planet.")
	}
	return nil
}

func trimHistory(h []Turn, n int) []Turn {
	if len(h) <= n {
		return h
	}
	return h[len(h)-n:]
}
