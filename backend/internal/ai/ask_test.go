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
		func(s string) error { out.WriteString(s); return nil }, nil)
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
	tools, _ := req["tools"].([]any)
	if len(tools) != 1 {
		t.Fatalf("tools = %v", req["tools"])
	}
	if tool, _ := tools[0].(map[string]any); tool["name"] != "show_on_globe" || tool["eager_input_streaming"] != true {
		t.Errorf("tool = %v", tool)
	}
	if _, forced := req["tool_choice"]; forced {
		t.Errorf("first round must leave tool_choice on auto: %v", req["tool_choice"])
	}
}

// sse writes a scripted Messages API stream.
func sse(w http.ResponseWriter, events ...string) {
	w.Header().Set("Content-Type", "text/event-stream")
	for _, e := range events {
		var probe struct {
			Type string `json:"type"`
		}
		_ = json.Unmarshal([]byte(e), &probe)
		fmt.Fprintf(w, "event: %s\ndata: %s\n\n", probe.Type, e)
	}
}

func TestAskShowsItemsOnTheGlobeThenAnswers(t *testing.T) {
	var bodies []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var body map[string]any
		_ = json.Unmarshal(raw, &body)
		bodies = append(bodies, body)
		start := `{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":10,"output_tokens":0}}}`
		if len(bodies) == 1 {
			sse(w, start,
				`{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}`,
				`{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-abc"}}`,
				`{"type":"content_block_stop","index":0}`,
				`{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"show_on_globe","input":{}}}`,
				`{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"refIds\": [\"us1\", "}}`,
				`{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"nope\"]}"}}`,
				`{"type":"content_block_stop","index":1}`,
				`{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}`,
				`{"type":"message_stop"}`)
			return
		}
		sse(w, start,
			`{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`,
			`{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"That quake was a megathrust event."}}`,
			`{"type":"content_block_stop","index":0}`,
			`{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":8}}`,
			`{"type":"message_stop"}`)
	}))
	defer srv.Close()

	client := anthropic.NewClient(option.WithAPIKey("test"), option.WithBaseURL(srv.URL), option.WithMaxRetries(0))
	s := &Service{log: slog.New(slog.NewTextHandler(io.Discard, nil)), client: &client, model: "claude-opus-5-5",
		store: &memStore{m: map[string]*Briefing{}}, snap: sampleDigest, inflight: map[string]chan struct{}{}}
	s.SetLocal(func(lat, lon float64) string { return "Local weather: 19 °C, light wind." })

	var out strings.Builder
	var shown []GlobeFocus
	lat, lon := 41.0, 29.0
	err := s.Ask(context.Background(), AskRequest{Question: "Why did Kamchatka shake?", Language: "en", Lat: &lat, Lon: &lon,
		About: &AskAbout{RefID: "us1", Kind: "earthquake", Title: "Kamchatka", Details: "M6.1"}},
		func(s string) error { out.WriteString(s); return nil },
		func(items []GlobeFocus) error { shown = items; return nil })
	if err != nil {
		t.Fatal(err)
	}
	if len(bodies) != 2 {
		t.Fatalf("requests = %d, want 2", len(bodies))
	}
	if len(shown) != 1 || shown[0].RefID != "us1" || shown[0].Lat != 51.7 {
		t.Fatalf("focus = %+v", shown)
	}
	if out.String() != "That quake was a megathrust event." {
		t.Fatalf("streamed %q", out.String())
	}
	first, _ := bodies[0]["messages"].([]any)
	question := fmt.Sprint(first[len(first)-1])
	for _, want := range []string{"Local weather: 19 °C", "Kamchatka - M6.1 [refId us1]"} {
		if !strings.Contains(question, want) {
			t.Errorf("question lacks %q: %s", want, question)
		}
	}
	msgs, _ := bodies[1]["messages"].([]any)
	if len(msgs) != 3 {
		t.Fatalf("second request has %d messages", len(msgs))
	}
	assistant, _ := msgs[1].(map[string]any)
	blocks, _ := assistant["content"].([]any)
	if len(blocks) != 2 {
		t.Fatalf("assistant turn = %v", assistant)
	}
	if b, _ := blocks[0].(map[string]any); b["type"] != "thinking" || b["signature"] != "sig-abc" {
		t.Errorf("thinking block not echoed unchanged: %v", b)
	}
	if b, _ := blocks[1].(map[string]any); b["type"] != "tool_use" || b["id"] != "toolu_1" {
		t.Errorf("tool_use block = %v", b)
	}
	user, _ := msgs[2].(map[string]any)
	results, _ := user["content"].([]any)
	result, _ := results[0].(map[string]any)
	if result["type"] != "tool_result" || result["tool_use_id"] != "toolu_1" || result["is_error"] == true {
		t.Fatalf("tool result = %v", result)
	}
	if !strings.Contains(fmt.Sprint(result["content"]), "has not seen any text") {
		t.Errorf("tool result content = %v", result["content"])
	}
}

func TestShowOnGlobeRejectsUnknownItems(t *testing.T) {
	call := anthropic.ToolUseBlock{ID: "toolu_9", Name: "show_on_globe", Input: json.RawMessage(`{"refIds":["ghost"]}`)}
	text, isErr := runShowOnGlobe(call, sampleDigest(), false, nil)
	if !isErr || !strings.Contains(text, "ghost") {
		t.Fatalf("got %q, error %v", text, isErr)
	}
	call.Input = json.RawMessage(`{}`)
	if text, isErr := runShowOnGlobe(call, sampleDigest(), false, nil); !isErr || !strings.Contains(text, "INVALID_JSON") {
		t.Fatalf("empty input: %q, %v", text, isErr)
	}
}
