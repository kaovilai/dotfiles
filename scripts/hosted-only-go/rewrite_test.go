package main

import (
	"strings"
	"testing"
	"time"
)

func testConfig() *config {
	return &config{
		GLM:            "rits/zai-org/glm-5-3",
		DeepSeek:       "rits/deepseek-ai/DeepSeek-V4.1-Flash-1017",
		Aliases:        map[string]struct{}{"claude-sonnet-5-5": {}},
		VisionFallback: true,
		FallbackOn:     true,
		LimitRewrite:   true,
		SearchNudge:    true,
		MaxModelLen:    1048576,
		OutputReserve:  512,
		MinOutput:      16000,
		BytesPerToken:  3,
		DefaultRetry:   60,
		ClientRetryMax: 60,
		OutageBase:     60,
		OutageMax:      600,
		RequestTimeout: 300 * time.Second,
		QuotaTZ:        time.UTC,
	}
}

func decode(t *testing.T, raw string) map[string]any {
	t.Helper()
	data, err := decodeObject([]byte(raw))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	return data
}

func TestAliasIsServedByGLM(t *testing.T) {
	data := decode(t, `{"model":"claude-sonnet-5-5","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}`)
	if _, err, _ := rewriteRequest(testConfig(), "/v1/messages", data); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := asString(data["model"]); got != "rits/zai-org/glm-5-3" {
		t.Fatalf("model = %q, want GLM", got)
	}
}

func TestThinkingDisabledForMessagesWithoutInput(t *testing.T) {
	data := decode(t, `{"model":"rits/zai-org/glm-5-3","messages":[{"role":"user","content":"hi"}]}`)
	if _, err, _ := rewriteRequest(testConfig(), "/v1/messages", data); err != nil {
		t.Fatal(err)
	}
	thinking := asMap(data["thinking"])
	if asString(thinking["type"]) != "disabled" {
		t.Fatalf("thinking = %#v, want disabled", data["thinking"])
	}

	explicit := decode(t, `{"model":"rits/zai-org/glm-5-3","messages":[{"role":"user","content":"hi"}],"thinking":{"type":"enabled","budget_tokens":2048}}`)
	if _, err, _ := rewriteRequest(testConfig(), "/v1/messages", explicit); err != nil {
		t.Fatal(err)
	}
	if asString(asMap(explicit["thinking"])["type"]) != "enabled" {
		t.Fatalf("explicit thinking was overwritten: %#v", explicit["thinking"])
	}
}

func TestEmptyInstructionDropped(t *testing.T) {
	data := decode(t, `{"model":"rits/zai-org/glm-5-3","input":[
		{"role":"developer","content":[{"type":"input_text","text":"   "}]},
		{"role":"user","content":[{"type":"input_text","text":"hello"}]},
		{"role":"system","content":""}
	],"max_output_tokens":10}`)
	if _, err, _ := rewriteRequest(testConfig(), "/v1/responses", data); err != nil {
		t.Fatal(err)
	}
	input := asList(data["input"])
	if len(input) != 1 {
		t.Fatalf("input length = %d, want 1: %#v", len(input), input)
	}
	if asString(asMap(input[0])["role"]) != "user" {
		t.Fatalf("kept the wrong item: %#v", input[0])
	}
}

func TestToolReferencesStripped(t *testing.T) {
	data := decode(t, `{"model":"rits/zai-org/glm-5-3","messages":[
		{"role":"user","content":[{"type":"tool_reference","tool_name":"x"}]},
		{"role":"assistant","content":[{"type":"text","text":"ok"},{"type":"tool_reference","tool_name":"y"}]}
	],"max_tokens":10}`)
	if _, err, _ := rewriteRequest(testConfig(), "/v1/messages", data); err != nil {
		t.Fatal(err)
	}
	first := asList(asMap(asList(data["messages"])[0])["content"])
	if len(first) != 1 || asString(asMap(first[0])["text"]) != "(tool reference omitted)" {
		t.Fatalf("emptied content = %#v", first)
	}
	second := asList(asMap(asList(data["messages"])[1])["content"])
	if len(second) != 1 || asString(asMap(second[0])["type"]) != "text" {
		t.Fatalf("tool_reference not stripped: %#v", second)
	}
}

func TestGrammarStrippedFromCustomTools(t *testing.T) {
	data := decode(t, `{"model":"rits/zai-org/glm-5-3","messages":[{"role":"user","content":"hi"}],"max_tokens":10,
		"tools":[{"type":"custom","name":"apply_patch","format":{"type":"grammar","grammar":{"syntax":"lark","definition":"start: x"}}}]}`)
	if _, err, _ := rewriteRequest(testConfig(), "/v1/chat/completions", data); err != nil {
		t.Fatal(err)
	}
	tool := asMap(asList(data["tools"])[0])
	if _, still := tool["format"]; still {
		t.Fatalf("grammar format survived: %#v", tool)
	}
}

func TestVisionReroute(t *testing.T) {
	data := decode(t, `{"model":"rits/zai-org/glm-5-3","max_tokens":10,"messages":[{"role":"user","content":[
		{"type":"text","text":"what is this"},
		{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}
	]}]}`)
	if _, err, _ := rewriteRequest(testConfig(), "/v1/messages", data); err != nil {
		t.Fatal(err)
	}
	if got := asString(data["model"]); got != "rits/deepseek-ai/DeepSeek-V4.1-Flash-1017" {
		t.Fatalf("model = %q, want DeepSeek", got)
	}
}

func TestClampTrimsAndRefuses(t *testing.T) {
	cfg := testConfig()
	cfg.MaxModelLen = 100000
	cfg.OutputReserve = 0
	cfg.MinOutput = 16000
	// ~30000 tokens of padding (90000 bytes) + 128000 requested > window.
	data := decode(t, `{"model":"rits/zai-org/glm-5-3","max_tokens":128000,"messages":[{"role":"user","content":"`+strings.Repeat("a", 90000)+`"}]}`)
	if _, err, _ := rewriteRequest(cfg, "/v1/messages", data); err != nil {
		t.Fatalf("expected a trim, got error: %v", err)
	}
	got, _ := asInt(data["max_tokens"])
	if got > 70000 || got < 69000 {
		t.Fatalf("max_tokens = %d, want ~70000", got)
	}

	cfg.MaxModelLen = 40000
	tooBig := decode(t, `{"model":"rits/zai-org/glm-5-3","max_tokens":128000,"messages":[{"role":"user","content":"`+strings.Repeat("b", 90000)+`"}]}`)
	if _, err, _ := rewriteRequest(cfg, "/v1/messages", tooBig); err == nil {
		t.Fatal("expected a context-overflow refusal")
	} else if err.Status != 400 || !strings.Contains(err.Message, "context_length_exceeded") {
		t.Fatalf("unexpected error: %#v", err)
	}
}

func TestSearchNudgePerDialect(t *testing.T) {
	cases := []struct{ path, body, marker string }{
		{"/v1/messages", `{"model":"rits/zai-org/glm-5-3","max_tokens":10,"messages":[{"role":"user","content":"hi"}],"tools":[{"type":"web_search_20250305","name":"web_search"}]}`, "system"},
		{"/v1/chat/completions", `{"model":"rits/zai-org/glm-5-3","max_tokens":10,"messages":[{"role":"user","content":"hi"}],"tools":[{"type":"web_search","function":{"name":"search"}}]}`, "messages"},
		{"/v1/responses", `{"model":"rits/zai-org/glm-5-3","max_output_tokens":10,"input":[{"role":"user","content":[{"type":"input_text","text":"hi"}]}],"tools":[{"type":"web_search"}]}`, "input"},
	}
	for _, tc := range cases {
		data := decode(t, tc.body)
		if _, err, _ := rewriteRequest(testConfig(), tc.path, data); err != nil {
			t.Fatalf("%s: %v", tc.path, err)
		}
		if _, ok := data["tools"]; ok {
			t.Fatalf("%s: web_search tool survived", tc.path)
		}
		encoded := string(marshal(data))
		if !strings.Contains(encoded, searchNoteMarker) {
			t.Fatalf("%s: note missing from %s", tc.path, encoded)
		}
	}
}

func TestFallbackSkipsImages(t *testing.T) {
	cfg := testConfig()
	text := decode(t, `{"model":"rits/zai-org/glm-5-3","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}`)
	fallback, err, _ := rewriteRequest(cfg, "/v1/messages", text)
	if err != nil || fallback != cfg.DeepSeek {
		t.Fatalf("fallback = %q err = %v, want DeepSeek", fallback, err)
	}

	image := decode(t, `{"model":"rits/zai-org/glm-5-3","max_tokens":10,"messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","data":"AA"}}]}]}`)
	// The image request is rerouted to DeepSeek, and an image request never
	// gets a model fallback.
	fallback, err, _ = rewriteRequest(cfg, "/v1/messages", image)
	if err != nil || fallback != "" {
		t.Fatalf("image fallback = %q err = %v, want none", fallback, err)
	}
}

func TestUnsupportedModelIsUntouched(t *testing.T) {
	data := decode(t, `{"model":"gpt-6-luna","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}`)
	before := string(marshal(data))
	if _, err, _ := rewriteRequest(testConfig(), "/v1/chat/completions", data); err != nil {
		t.Fatal(err)
	}
	if after := string(marshal(data)); after != before {
		t.Fatalf("request changed:\nbefore %s\nafter  %s", before, after)
	}
}

func TestSearchNoteNotDuplicated(t *testing.T) {
	data := decode(t, `{"model":"rits/zai-org/glm-5-3","max_tokens":10,"messages":[{"role":"user","content":"hi"}],"system":[{"type":"text","text":"`+searchNoteMarker+` already here"}],"tools":[{"type":"web_search"}]}`)
	if _, err, _ := rewriteRequest(testConfig(), "/v1/messages", data); err != nil {
		t.Fatal(err)
	}
	count := strings.Count(string(marshal(data)), searchNoteMarker)
	if count != 1 {
		t.Fatalf("marker appears %d times, want 1", count)
	}
}
