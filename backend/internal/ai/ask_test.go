package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

func TestAskStreamsTextDeltas(t *testing.T) {
	var req map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &req)
		w.Header().Set("Content-Type", "text/event-stream")
		events := []string{
			`event: message_start` + "\n" + `data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":10,"output_tokens":0}}}`,
			`event: content_block_start` + "\n" + `data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`,
			`event: content_block_delta` + "\n" + `data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Aurora is "}}`,
			`event: content_block_delta` + "\n" + `data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"likely tonight."}}`,
			`event: content_block_stop` + "\n" + `data: {"type":"content_block_stop","index":0}`,
			`event: message_delta` + "\n" + `data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":6}}`,
			`event: message_stop` + "\n" + `data: {"type":"message_stop"}`,
		}
		for _, e := range events {
			fmt.Fprintf(w, "%s\n\n", e)
		}
	}))
	defer srv.Close()

	client := anthropic.NewClient(option.WithAPIKey("test"), option.WithBaseURL(srv.URL), option.WithMaxRetries(0))
	s := &Service{log: slog.New(slog.NewTextHandler(io.Discard, nil)), client: &client, model: "claude-opus-5-5",
		store: &memStore{m: map[string]*Briefing{}}, snap: sampleDigest, inflight: map[string]chan struct{}{}}

	var out strings.Builder
	lat, lon := 41.0, 29.0
	err := s.Ask(context.Background(), AskRequest{Question: "Will I see the aurora?", Language: "en", Lat: &lat, Lon: &lon,
		History: []Turn{{Role: "assistant", Text: "hi"}, {Role: "user", Text: "earlier q"}, {Role: "assistant", Text: "earlier a"}}},
		func(s string) error { out.WriteString(s); return nil })
	if err != nil {
		t.Fatalf("ask: %v", err)
	}
	if out.String() != "Aurora is likely tonight." {
		t.Errorf("streamed %q", out.String())
	}
	msgs, _ := req["messages"].([]any)
	if len(msgs) != 3 {
		t.Fatalf("messages = %d, want 3 (leading assistant dropped)", len(msgs))
	}
	if first, _ := msgs[0].(map[string]any); first["role"] != "user" {
		t.Errorf("first message role = %v", first["role"])
	}
	if oc, _ := req["output_config"].(map[string]any); oc["effort"] != "low" {
		t.Errorf("effort = %v", req["output_config"])
	}
	if req["stream"] != true {
		t.Errorf("stream flag missing")
	}
	sys, _ := req["system"].([]any)
	if len(sys) != 2 {
		t.Fatalf("system blocks = %d", len(sys))
	}
	if cc, _ := sys[1].(map[string]any)["cache_control"].(map[string]any); cc["type"] != "ephemeral" {
		t.Errorf("digest block not cached: %v", sys[1])
	}
}
