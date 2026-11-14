package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Claude Code's tool search on a vLLM-served upstream: the search tool is an
// Anthropic server tool, the deferred definitions travel in tools[] with
// defer_loading, and the results come back as tool_reference blocks the chat
// template rejects. Stripping the references alone left a search result the
// model could not act on ("(tool reference omitted)"), so ToolSearch never
// worked on the hosted-only / enmaas route. The shim opens the deferred tools
// inline instead.

func toolSearchConfig(t *testing.T) *config {
	t.Helper()
	cfg := loadConfig("claude", "0", t.TempDir())
	cfg.GLM = "rits/meta-models/Muse-Spark-Open-816B-A42B-NVFP4"
	cfg.DeepSeek = "rits/deepseek-ai/DeepSeek-V4.1-Flash-1017"
	cfg.Aliases = nil
	cfg.FallbackOn = false
	cfg.SearchNudge = false // the web-search note is a different shim
	return cfg
}

func toolSearchRequest(model string) map[string]any {
	return map[string]any{
		"model":      model,
		"max_tokens": 16,
		"system":     "you are a test",
		"messages": []any{map[string]any{"role": "user", "content": []any{
			map[string]any{"type": "tool_result", "tool_use_id": "t1", "content": []any{
				map[string]any{"type": "tool_reference", "tool_name": "mcp__x__y"}}},
		}}},
		"tools": []any{
			map[string]any{"type": "tool_search_tool_regex_20251119", "name": "tool_search_tool_regex"},
			map[string]any{"name": "Bash", "description": "run", "input_schema": map[string]any{"type": "object"}},
			map[string]any{"name": "mcp__x__y", "description": "deferred", "defer_loading": true,
				"input_schema": map[string]any{"type": "object"}},
		},
	}
}

func toolNames(t *testing.T, data map[string]any) []string {
	t.Helper()
	var names []string
	for _, raw := range asList(data["tools"]) {
		tool := asMap(raw)
		if tool == nil {
			continue
		}
		if name := asString(tool["name"]); name != "" {
			names = append(names, name)
		}
		if ty := asString(tool["type"]); ty != "" {
			names = append(names, ty)
		}
	}
	return names
}

// The deferred tool must reach the upstream WITH its definition, and the
// server tool the upstream cannot run must be gone.
func TestDeferredToolsAreOpenedInline(t *testing.T) {
	cfg := toolSearchConfig(t)
	data := toolSearchRequest(cfg.GLM)
	_, reqErr, changed := rewriteRequest(cfg, "/v1/messages", data)
	if reqErr != nil {
		t.Fatalf("a tool-search request must not be refused: %+v", reqErr)
	}
	if !changed {
		t.Fatal("a tool-search request must be rewritten")
	}
	names := toolNames(t, data)
	for _, n := range names {
		if strings.HasPrefix(n, "tool_search_tool_") {
			t.Fatalf("the upstream cannot run the search tool: %v", names)
		}
	}
	if len(names) != 2 {
		t.Fatalf("both client tools must survive, search tool dropped: %v", names)
	}
	for _, raw := range asList(data["tools"]) {
		if tool := asMap(raw); tool != nil {
			if _, ok := tool["defer_loading"]; ok {
				t.Fatalf("every tool must be loaded inline: %v", tool)
			}
		}
	}
	// The pointer blocks stay stripped (vLLM rejects them)...
	msgs := string(marshal(asList(data["messages"])))
	if strings.Contains(msgs, "tool_reference") {
		t.Fatalf("tool_reference blocks must still be stripped: %s", msgs)
	}
	// ...and the model is told not to look for a search step.
	if !toolSearchNotePresent(data) {
		t.Fatal("the opened tool list needs the note, or the model keeps searching")
	}
}

// The note is what stops a model from spending turns on ToolSearch; it must
// not be repeated on later requests of the same conversation.
func TestToolSearchNoteIsNotDuplicated(t *testing.T) {
	cfg := toolSearchConfig(t)
	data := toolSearchRequest(cfg.GLM)
	_, _, _ = rewriteRequest(cfg, "/v1/messages", data)
	note := toolSearchNoteText()
	if n := strings.Count(string(marshal(data["system"])), note); n != 1 {
		t.Fatalf("note injected %d times, want 1", n)
	}
	// The conversation keeps the note, and the client keeps sending the search
	// tool + defer_loading: the rewrite must not stack a second copy.
	next := toolSearchRequest(cfg.GLM)
	next["system"] = data["system"]
	_, reqErr, changed := rewriteRequest(cfg, "/v1/messages", next)
	if reqErr != nil || !changed {
		t.Fatalf("a later request still drops the search tool (changed=%v err=%+v)", changed, reqErr)
	}
	if n := strings.Count(string(marshal(next["system"])), note); n != 1 {
		t.Fatalf("second request duplicated the note: %d", n)
	}
}

// A model the workaround does not cover keeps the native request untouched:
// Claude models behind the gateway do implement tool search.
func TestToolSearchPassesThroughForNonRitsModels(t *testing.T) {
	cfg := toolSearchConfig(t)
	data := toolSearchRequest("claude-opus-5-5")
	_, reqErr, changed := rewriteRequest(cfg, "/v1/messages", data)
	if reqErr != nil {
		t.Fatalf("unexpected refusal: %+v", reqErr)
	}
	if changed {
		t.Fatal("a non-rits model must keep its native tool search")
	}
	if !strings.Contains(string(marshal(data["tools"])), "tool_search_tool_regex_20251119") {
		t.Fatal("search tool was dropped for a model that supports it")
	}
}

// No tool-search constructs: nothing to open, no note. (Other rits rewrites,
// e.g. the thinking default, may still fire — only the tool list is asserted.)
func TestPlainRequestKeepsItsTools(t *testing.T) {
	cfg := toolSearchConfig(t)
	tools := []any{map[string]any{"name": "Bash", "input_schema": map[string]any{"type": "object"}}}
	data := map[string]any{
		"model":      cfg.GLM,
		"max_tokens": 16,
		"messages":   []any{map[string]any{"role": "user", "content": "hi"}},
		"tools":      tools,
	}
	_, reqErr, _ := rewriteRequest(cfg, "/v1/messages", data)
	if reqErr != nil {
		t.Fatalf("unexpected refusal: %+v", reqErr)
	}
	if !strings.EqualFold(string(marshal(data["tools"])), string(marshal(tools))) {
		t.Fatalf("a plain tool list must be untouched: %s", marshal(data["tools"]))
	}
	if toolSearchNotePresent(data) {
		t.Fatal("no tool search in the request, the note must not appear")
	}
}

// End to end through the handler: the body the gateway receives carries every
// tool inline and no defer_loading, so the model can call what the client
// deferred.
func TestToolSearchShimReachesTheUpstream(t *testing.T) {
	var got map[string]any
	gw := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &got)
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"id":"m","type":"message","role":"assistant","model":"x","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}`))
	}))
	t.Cleanup(gw.Close)
	t.Setenv("ENMAAS_API_KEY", "test-key")
	t.Setenv("HOSTED_ONLY_ENMAAS_BASE_URL", gw.URL)
	t.Setenv("LLM_USAGE_DIR", t.TempDir())
	cfg := loadConfig("claude", "0", t.TempDir())
	cfg.GLM = "rits/meta-models/Muse-Spark-Open-816B-A42B-NVFP4"
	cfg.DeepSeek = cfg.GLM
	cfg.Aliases = nil
	cfg.FallbackOn = false
	cfg.SearchNudge = false
	app := newApp(cfg)

	payload, _ := json.Marshal(toolSearchRequest(cfg.GLM))
	req := httptest.NewRequest(http.MethodPost, "/v1/messages", strings.NewReader(string(payload)))
	req.Header.Set("x-api-key", cfg.Token)
	req.Header.Set("content-type", "application/json")
	rec := httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("proxy refused the request: %d %s", rec.Code, rec.Body.String())
	}
	if got == nil {
		t.Fatal("the upstream saw no body")
	}
	body := string(marshal(got))
	for _, banned := range []string{"tool_search_tool_", "defer_loading", "tool_reference"} {
		if strings.Contains(body, banned) {
			t.Fatalf("%q reached the upstream: %s", banned, body)
		}
	}
	if !strings.Contains(body, "mcp__x__y") {
		t.Fatalf("the deferred tool definition must reach the upstream inline: %s", body)
	}
	if !strings.Contains(body, toolSearchNoteMarker) {
		t.Fatalf("the note must reach the upstream: %s", body)
	}
}

// A forced tool_choice naming the removed search tool would point at a tool the
// upstream no longer declares; free it, but leave a choice on a kept tool.
func TestForcedToolChoiceOnSearchToolIsFreed(t *testing.T) {
	cfg := toolSearchConfig(t)
	data := toolSearchRequest(cfg.GLM)
	data["tool_choice"] = map[string]any{"type": "tool", "name": "tool_search_tool_regex"}
	if _, reqErr, _ := rewriteRequest(cfg, "/v1/messages", data); reqErr != nil {
		t.Fatalf("unexpected refusal: %+v", reqErr)
	}
	if _, ok := data["tool_choice"]; ok {
		t.Fatal("a forced choice on the dropped search tool must be freed")
	}

	kept := toolSearchRequest(cfg.GLM)
	kept["tool_choice"] = map[string]any{"type": "tool", "name": "Bash"}
	if _, reqErr, _ := rewriteRequest(cfg, "/v1/messages", kept); reqErr != nil {
		t.Fatalf("unexpected refusal: %+v", reqErr)
	}
	if _, ok := kept["tool_choice"]; !ok {
		t.Fatal("a forced choice on a kept tool must survive")
	}
}

// The history block that wraps a search result names a server tool the
// upstream does not have; with the tools opened inline it is dead weight.
func TestSearchResultWrapperIsDropped(t *testing.T) {
	cfg := toolSearchConfig(t)
	data := map[string]any{
		"model":      cfg.GLM,
		"max_tokens": 16,
		"messages": []any{
			map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "tool_search_tool_result", "tool_use_id": "s1", "content": []any{
					map[string]any{"type": "tool_reference", "tool_name": "mcp__x__y"}}},
				map[string]any{"type": "text", "text": "carry on"},
			}},
		},
	}
	if _, reqErr, _ := rewriteRequest(cfg, "/v1/messages", data); reqErr != nil {
		t.Fatalf("unexpected refusal: %+v", reqErr)
	}
	body := string(marshal(asList(data["messages"])))
	if strings.Contains(body, "tool_search_tool_result") {
		t.Fatalf("the wrapper must not reach the upstream: %s", body)
	}
	if !strings.Contains(body, "carry on") {
		t.Fatalf("the rest of the turn must survive: %s", body)
	}
}
