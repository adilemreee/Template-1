package ai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

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
	// About is the item the user opened Ask from ("Ask about this"), if any.
	About *AskAbout `json:"about,omitempty"`
}

// AskAbout describes the event on screen when the user asked.
type AskAbout struct {
	RefID   string `json:"refId"`
	Kind    string `json:"kind"`
	Title   string `json:"title"`
	Details string `json:"details,omitempty"`
}

// GlobeFocus is an item the assistant asked the app to show on the globe.
type GlobeFocus struct {
	RefID string  `json:"refId"`
	Kind  string  `json:"kind"`
	Title string  `json:"title"`
	Lat   float64 `json:"lat"`
	Lon   float64 `json:"lon"`
}

var ErrDisabled = errors.New("AI is not configured on this server")

const askSystem = `You are Kármán, the planetary-science companion inside a premium iOS app that shows the living Earth in real time on a 3D globe: earthquakes, storms, wildfires, volcanoes, aurora and space weather, live wind, temperature and rain, satellites, rocket launches and passing asteroids.

Answer the user's question using the live data digest below as your source of truth for anything happening now; use your general scientific knowledge to explain how and why. If the digest does not cover something current, say so plainly rather than guessing - never invent events, casualties, damage or forecasts.

The globe: when the question is about specific events or places in the digest, call show_on_globe first, before you write anything, with their refId values (most relevant first). The app flies the user's globe there while you answer. Skip the tool for general questions, and never call it more than once.

Style: warm, precise and concise - usually 2-4 short paragraphs, under 160 words, plain text without markdown headings, tables or bullet symbols. Use metric units and include imperial in parentheses only when it helps. Reply in the language the user writes in (or the requested language). For safety questions (earthquake, tsunami, storm), be calm and point people to their local authorities.`

const showOnGlobeName = "show_on_globe"

// showOnGlobeTool lets the model point the user's globe at digest items. The input is tiny,
// but the request is streamed, so the tool streams its input eagerly and the server validates
// it before acting.
var showOnGlobeTool = anthropic.ToolParam{
	Name: showOnGlobeName,
	Description: anthropic.String("Flies the user's 3D globe to items from the live data digest and highlights them, so the user sees what you are talking about. " +
		"Use it for questions about specific earthquakes, storms, fires, volcanoes, launch sites or the aurora. Pass refId values exactly as they appear in the digest."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"refIds": map[string]any{
				"type":        "array",
				"description": "Digest refId values to show, most relevant first (1 to 4).",
				"items":       map[string]any{"type": "string"},
				"minItems":    1,
				"maxItems":    4,
			},
		},
		Required:    []string{"refIds"},
		ExtraFields: map[string]any{"additionalProperties": false},
	},
	EagerInputStreaming: anthropic.Bool(true),
}

const askMaxRounds = 3

// Ask streams an answer: onDelta receives text fragments as they arrive and onFocus the
// digest items the model chose to show on the globe.
func (s *Service) Ask(ctx context.Context, req AskRequest, onDelta func(string) error, onFocus func([]GlobeFocus) error) error {
	if s.client == nil {
		return ErrDisabled
	}
	digest, digestJSON := s.askDigest()

	lang := SupportedLanguages[req.Language]
	if lang == "" {
		lang = "the user's language"
	}
	where := "unknown"
	if req.Lat != nil && req.Lon != nil {
		where = fmt.Sprintf("approximately %.0f°, %.0f° (lat, lon)", *req.Lat, *req.Lon)
		if s.local != nil {
			if local := s.local(*req.Lat, *req.Lon); local != "" {
				where += ". " + local
			}
		}
	}

	msgs := historyMessages(req.History)
	var preface strings.Builder
	fmt.Fprintf(&preface, "(Preferred language: %s. My location: %s.)", lang, where)
	if a := req.About; a != nil && strings.TrimSpace(a.Title) != "" {
		fmt.Fprintf(&preface, "\n(I am looking at this %s on the globe: %s", clipText(a.Kind, 40), clipText(a.Title, 160))
		if a.Details != "" {
			fmt.Fprintf(&preface, " - %s", clipText(a.Details, 240))
		}
		if a.RefID != "" {
			fmt.Fprintf(&preface, " [refId %s]", clipText(a.RefID, 80))
		}
		preface.WriteString(".)")
	}
	question := preface.String() + "\n\n" + strings.TrimSpace(req.Question)
	msgs = append(msgs, anthropic.NewUserMessage(anthropic.NewTextBlock(question)))

	system := []anthropic.TextBlockParam{
		{Text: askSystem},
		{Text: "Live data digest (UTC):\n" + string(digestJSON), CacheControl: anthropic.NewCacheControlEphemeralParam()},
	}
	tools := []anthropic.ToolUnionParam{{OfTool: &showOnGlobeTool}}

	wrote := false
	for round := 0; round < askMaxRounds; round++ {
		params := anthropic.MessageNewParams{
			Model:        anthropic.Model(s.model),
			MaxTokens:    4000,
			System:       system,
			Messages:     msgs,
			Tools:        tools,
			OutputConfig: anthropic.OutputConfigParam{Effort: anthropic.OutputConfigEffortLow},
		}
		if round == askMaxRounds-1 {
			// Last round: the answer has to be text now.
			params.ToolChoice = anthropic.ToolChoiceUnionParam{OfNone: &anthropic.ToolChoiceNoneParam{}}
		}
		msg, refused, err := s.streamRound(ctx, params, func(text string) error {
			wrote = true
			return onDelta(text)
		})
		if err != nil {
			return err
		}
		if refused {
			return onDelta("\n\nI can't help with that one, but I'm happy to talk about anything happening on the planet.")
		}
		// Only a clean tool_use stop runs tools: max_tokens or a refusal can cut an input short.
		if msg.StopReason != anthropic.StopReasonToolUse {
			return nil
		}
		var results []anthropic.ContentBlockParamUnion
		for _, block := range msg.Content {
			call, ok := block.AsAny().(anthropic.ToolUseBlock)
			if !ok {
				continue
			}
			content, isError := runShowOnGlobe(call, digest, wrote, onFocus)
			results = append(results, anthropic.NewToolResultBlock(call.ID, content, isError))
		}
		if len(results) == 0 {
			return nil
		}
		msgs = append(msgs, msg.ToParam(), anthropic.NewUserMessage(results...))
	}
	return nil
}

// streamRound runs one streamed request, forwarding text as it arrives, and returns the
// accumulated message (thinking blocks and signatures included, for the next round).
func (s *Service) streamRound(ctx context.Context, params anthropic.MessageNewParams, onDelta func(string) error) (anthropic.Message, bool, error) {
	stream := s.client.Messages.NewStreaming(ctx, params, requestOptions()...)
	defer stream.Close()
	var msg anthropic.Message
	refused := false
	for stream.Next() {
		event := stream.Current()
		if err := msg.Accumulate(event); err != nil {
			return msg, false, err
		}
		switch ev := event.AsAny().(type) {
		case anthropic.ContentBlockDeltaEvent:
			if d, ok := ev.Delta.AsAny().(anthropic.TextDelta); ok && d.Text != "" {
				if err := onDelta(d.Text); err != nil {
					return msg, false, err
				}
			}
		case anthropic.MessageDeltaEvent:
			if ev.Delta.StopReason == anthropic.StopReasonRefusal {
				refused = true
			}
		}
	}
	return msg, refused, stream.Err()
}

// runShowOnGlobe validates the tool input against the digest, tells the app what to show and
// returns the tool_result text for the model.
func runShowOnGlobe(call anthropic.ToolUseBlock, d Digest, wrote bool, onFocus func([]GlobeFocus) error) (string, bool) {
	if call.Name != showOnGlobeName {
		return fmt.Sprintf("Unknown tool %q.", call.Name), true
	}
	var in struct {
		RefIDs []string `json:"refIds"`
	}
	if err := json.Unmarshal(call.Input, &in); err != nil || len(in.RefIDs) == 0 {
		b, _ := json.Marshal(map[string]string{"INVALID_JSON": string(call.Input)})
		return string(b), true
	}
	known := map[string]DigestItem{}
	for _, list := range [][]DigestItem{d.Quakes, d.Storms, d.Volcanoes, d.Fires.Notable, d.Ice, d.Other, d.Space.Items, d.Launches, d.Weather} {
		for _, item := range list {
			known[item.ID] = item
		}
	}
	var items []GlobeFocus
	var unknown []string
	for _, id := range in.RefIDs {
		item, ok := known[id]
		if !ok {
			unknown = append(unknown, id)
			continue
		}
		if len(items) < 4 {
			items = append(items, GlobeFocus{RefID: item.ID, Kind: item.Kind, Title: item.Title, Lat: item.Lat, Lon: item.Lon})
		}
	}
	if len(items) == 0 {
		return fmt.Sprintf("None of %s are digest items with a place on the globe; use refId values from the digest, or answer without the globe.", strings.Join(unknown, ", ")), true
	}
	if onFocus != nil {
		if err := onFocus(items); err != nil {
			return "The globe could not be updated; answer without it.", true
		}
	}
	titles := make([]string, len(items))
	for i, it := range items {
		titles[i] = it.Title
	}
	next := "The user has not seen any text from you yet: write your full answer now."
	if wrote {
		next = "Now finish your answer."
	}
	return fmt.Sprintf("The user's globe now shows %s. %s", strings.Join(titles, "; "), next), false
}

// historyMessages normalises the app's history: strictly alternating turns that start with the
// user and end with the assistant, so the new question becomes the final user turn.
func historyMessages(history []Turn) []anthropic.MessageParam {
	var turns []Turn
	for _, t := range trimHistory(history, 6) {
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
	return msgs
}

// askDigest returns the digest for the current minute. Every question asked within the same
// minute shares the same bytes, so the cached system prompt is reused across users.
func (s *Service) askDigest() (Digest, []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.askDigestJSON != nil && time.Since(s.askDigestAt) < time.Minute {
		return s.askDigestValue, s.askDigestJSON
	}
	d := s.snap()
	b, _ := json.Marshal(d)
	s.askDigestValue, s.askDigestJSON, s.askDigestAt = d, b, time.Now()
	return d, b
}

// SetLocal installs a describer of local conditions (weather, aurora odds) at a coarse
// location; its sentence is added to the question, after the cached prefix.
func (s *Service) SetLocal(fn func(lat, lon float64) string) { s.local = fn }

func clipText(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

func trimHistory(h []Turn, n int) []Turn {
	if len(h) <= n {
		return h
	}
	return h[len(h)-n:]
}
