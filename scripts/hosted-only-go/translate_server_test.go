package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// chatRoutedApp builds the real handler with a Messages client routed to a
// chat-dialect deployment served by stub (the EnMaaS GPT/Gemini case).
func chatRoutedApp(t *testing.T, stub http.HandlerFunc) (*app, *httptest.Server) {
	t.Helper()
	return chatRoutedModelApp(t, "gpt-5-mini", stub)
}

// chatRoutedModelApp is chatRoutedApp for any chat-dialect model id.
func chatRoutedModelApp(t *testing.T, model string, stub http.HandlerFunc) (*app, *httptest.Server) {
	t.Helper()
	gw := httptest.NewServer(stub)
	t.Cleanup(gw.Close)
	t.Setenv("ENMAAS_API_KEY", "test-key")
	t.Setenv("LLM_USAGE_DIR", t.TempDir())
	doc := map[string]any{
		"model_list":       []any{map[string]any{"model_name": model, "litellm_params": map[string]any{"model": "openai/" + model, "api_base": gw.URL + "/v1"}}},
		"general_settings": map[string]any{"master_key": "x"},
	}
	path := filepath.Join(t.TempDir(), "routes.json")
	if err := os.WriteFile(path, marshal(doc), 0o600); err != nil {
		t.Fatal(err)
	}
	routes, err := loadRouteTable(path, "")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOSTED_ONLY_ENMAAS_BASE_URL", gw.URL)
	cfg := loadConfig("enmaas", "0", t.TempDir())
	cfg.Routes = routes
	return newApp(cfg), gw
}

func messagesRequest(a *app, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/v1/messages", strings.NewReader(body))
	req.Header.Set("x-api-key", a.cfg.Token)
	req.Header.Set("content-type", "application/json")
	rec := httptest.NewRecorder()
	a.ServeHTTP(rec, req)
	return rec
}

func TestMessagesClientOnChatDeploymentIsTranslated(t *testing.T) {
	var gotPath, gotAuth string
	var gotBody map[string]any
	a, _ := chatRoutedApp(t, func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotAuth = r.URL.Path, r.Header.Get("Authorization")
		raw, _ := io.ReadAll(r.Body)
		gotBody, _ = decodeObject(raw)
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"id":"chatcmpl-1","model":"gpt-5-mini-2025","choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"hello"}}],"usage":{"prompt_tokens":7,"completion_tokens":2}}`))
	})
	rec := messagesRequest(a, `{"model":"gpt-5-mini","max_tokens":64,"system":"be brief","messages":[{"role":"user","content":"hi"}]}`)
	if rec.Code != 200 {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if gotPath != "/v1/chat/completions" || gotAuth != "Bearer test-key" {
		t.Fatalf("upstream call: path=%q auth=%q (a Messages body must never reach a chat endpoint)", gotPath, gotAuth)
	}
	if _, bad := gotBody["messages"].([]any)[0].(map[string]any)["role"]; !bad || asString(asMap(gotBody["messages"].([]any)[0])["role"]) != "system" {
		t.Fatalf("system prompt must lead the chat messages: %v", gotBody["messages"])
	}
	if _, has := gotBody["max_completion_tokens"]; !has {
		t.Fatalf("gpt-5 takes max_completion_tokens: %v", gotBody)
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("answer is not JSON: %v", err)
	}
	if out["type"] != "message" || out["model"] != "gpt-5-mini" || out["stop_reason"] != "end_turn" {
		t.Fatalf("not a Messages answer (model must echo the requested id): %v", out)
	}
	content := asList(out["content"])
	if len(content) != 1 || asString(asMap(content[0])["text"]) != "hello" {
		t.Fatalf("content: %v", out["content"])
	}
	usage := asMap(out["usage"])
	if n, _ := asInt(usage["input_tokens"]); n != 7 {
		t.Fatalf("usage: %v", usage)
	}
}

func TestMessagesClientChatStreamIsTranslated(t *testing.T) {
	a, _ := chatRoutedApp(t, func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		if obj, _ := decodeObject(raw); !asBool(obj["stream"]) {
			t.Errorf("stream flag must reach the upstream: %v", obj)
		}
		w.Header().Set("content-type", "text/event-stream")
		for _, c := range []string{
			`{"id":"c1","choices":[{"delta":{"role":"assistant","content":"Hel"}}]}`,
			`{"id":"c1","choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}`,
			`{"id":"c1","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2}}`,
			`[DONE]`,
		} {
			_, _ = io.WriteString(w, "data: "+c+"\n\n")
		}
	})
	rec := messagesRequest(a, `{"model":"gpt-5-mini","max_tokens":64,"stream":true,"messages":[{"role":"user","content":"hi"}]}`)
	if rec.Code != 200 || !strings.HasPrefix(rec.Header().Get("Content-Type"), "text/event-stream") {
		t.Fatalf("status %d ct %q", rec.Code, rec.Header().Get("Content-Type"))
	}
	body := rec.Body.String()
	for _, want := range []string{"event: message_start", "event: content_block_start", `"text":"Hel"`, `"text":"lo"`, "event: content_block_stop", "event: message_delta", "event: message_stop"} {
		if !strings.Contains(body, want) {
			t.Fatalf("stream lacks %q:\n%s", want, body)
		}
	}
	if strings.Index(body, "message_start") > strings.Index(body, "message_stop") {
		t.Fatalf("event order:\n%s", body)
	}
}

func TestMessagesClientChatErrorIsAnthropicShaped(t *testing.T) {
	a, _ := chatRoutedApp(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "application/json")
		w.WriteHeader(400)
		_, _ = w.Write([]byte(`{"error":{"message":"Unsupported value: temperature","type":"invalid_request_error"}}`))
	})
	rec := messagesRequest(a, `{"model":"gpt-5-mini","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`)
	if rec.Code != 400 {
		t.Fatalf("status %d", rec.Code)
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil || out["type"] != "error" {
		t.Fatalf("a Messages client needs the Anthropic error envelope, got %s", rec.Body.String())
	}
	if msg := asString(asMap(out["error"])["message"]); !strings.Contains(msg, "temperature") {
		t.Fatalf("upstream message lost: %s", rec.Body.String())
	}
}

// gpt-6-* refuse function tools on chat completions ("use /v1/responses", live
// 2026-11-07). The proxy retries once through the Responses translator and
// remembers the model, so only the FIRST request pays the failed chat call.
func TestChatDeploymentThatWantsResponsesIsRetriedAndLearned(t *testing.T) {
	var paths []string
	a, _ := chatRoutedApp(t, func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		w.Header().Set("content-type", "application/json")
		if r.URL.Path == "/v1/chat/completions" {
			w.WriteHeader(400)
			_, _ = w.Write([]byte(`{"error":{"message":"Function tools with reasoning_effort are not supported for gpt-5-mini in /v1/chat/completions. To use function tools, use /v1/responses.","type":"invalid_request_error"}}`))
			return
		}
		_, _ = w.Write([]byte(`{"id":"resp_1","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"via responses"}]}],"usage":{"input_tokens":4,"output_tokens":2}}`))
	})
	body := `{"model":"gpt-5-mini","max_tokens":64,"tools":[{"name":"f","description":"d","input_schema":{"type":"object","properties":{}}}],"messages":[{"role":"user","content":"hi"}]}`
	for i := 0; i < 2; i++ {
		rec := messagesRequest(a, body)
		if rec.Code != 200 || !strings.Contains(rec.Body.String(), "via responses") {
			t.Fatalf("request %d: %d %s", i, rec.Code, rec.Body.String())
		}
	}
	want := []string{"/v1/chat/completions", "/v1/responses", "/v1/responses"}
	if strings.Join(paths, ",") != strings.Join(want, ",") {
		t.Fatalf("upstream paths %v, want %v (one failed chat call, then learned)", paths, want)
	}
}

// A failed Responses retry must not poison the model or replace the client's
// answer: the original chat 400 is returned and the next request tries chat again.
func TestResponsesRetryThatFailsIsNotLearned(t *testing.T) {
	var paths []string
	a, _ := chatRoutedApp(t, func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		w.Header().Set("content-type", "application/json")
		w.WriteHeader(map[bool]int{true: 400, false: 404}[r.URL.Path == "/v1/chat/completions"])
		if r.URL.Path == "/v1/chat/completions" {
			_, _ = w.Write([]byte(`{"error":{"message":"use /v1/responses for function tools"}}`))
			return
		}
		_, _ = w.Write([]byte(`{"error":{"message":"no such route"}}`))
	})
	body := `{"model":"gpt-5-mini","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}`
	for i := 0; i < 2; i++ {
		rec := messagesRequest(a, body)
		if rec.Code != 400 || !strings.Contains(rec.Body.String(), "use /v1/responses") {
			t.Fatalf("request %d must surface the ORIGINAL chat 400: %d %s", i, rec.Code, rec.Body.String())
		}
	}
	want := "/v1/chat/completions,/v1/responses,/v1/chat/completions,/v1/responses"
	if strings.Join(paths, ",") != want {
		t.Fatalf("paths %v: the model must not be learned after a failed retry", paths)
	}
}

// An upstream SSE error line must reach the Messages client as an Anthropic
// error event, not as a 200 with a silent EOF.
func TestChatStreamUpstreamErrorReachesClient(t *testing.T) {
	a, _ := chatRoutedApp(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "text/event-stream")
		_, _ = io.WriteString(w, "data: {\"error\":{\"message\":\"backend failed\"}}\n\n")
		_, _ = io.WriteString(w, "data: [DONE]\n\n")
	})
	rec := messagesRequest(a, `{"model":"gpt-5-mini","max_tokens":64,"stream":true,"messages":[{"role":"user","content":"hi"}]}`)
	body := rec.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, "backend failed") {
		t.Fatalf("the client must see the upstream failure:\n%s", body)
	}
	if strings.Contains(body, "message_stop") {
		t.Fatalf("a failed stream must not end as a normal completion:\n%s", body)
	}
}

// Same for a Responses stream that fails mid-flight.
func TestResponsesStreamFailureReachesClient(t *testing.T) {
	a, _ := chatRoutedApp(t, func(w http.ResponseWriter, r *http.Request) {
		paths := r.URL.Path
		w.Header().Set("content-type", "text/event-stream")
		if strings.Contains(paths, "/v1/responses") {
			_, _ = io.WriteString(w, "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"r\",\"status\":\"in_progress\"}}\n\n")
			_, _ = io.WriteString(w, "event: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"message\":\"kaboom\"}}}\n\n")
			return
		}
		w.Header().Set("content-type", "application/json")
		w.WriteHeader(400)
		_, _ = w.Write([]byte(`{"error":{"message":"Function tools ... use /v1/responses."}}`))
	})
	rec := messagesRequest(a, `{"model":"gpt-5-mini","max_tokens":64,"stream":true,"messages":[{"role":"user","content":"hi"}]}`)
	body := rec.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, "kaboom") {
		t.Fatalf("the client must see the upstream failure:\n%s", body)
	}
	if strings.Contains(body, "message_stop") {
		t.Fatalf("a failed stream must not end as a normal completion:\n%s", body)
	}
}

// The usage log's ts reaches a filename; anything that is not YYYY-MM must
// be rejected, not joined into the path.
func TestUsageWriteRejectsNonDateTimestamp(t *testing.T) {
	dir := t.TempDir()
	u := &usageLog{dir: dir, port: "0"}
	for _, bad := range []string{"../../etc", "2026-1x-07T00:00:00.000Z", "2026_11-07T00:00:00.000Z"} {
		u.write(map[string]any{"ts": bad, "ok": true})
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("a non-ISO ts must not create a file: %v", entries)
	}
	u.write(map[string]any{"ts": "2026-11-07T00:00:00.000Z", "ok": true})
	entries, err = os.ReadDir(dir)
	if err != nil || len(entries) != 1 || entries[0].Name() != "events-2026-11.jsonl" {
		t.Fatalf("a valid ts must land in events-2026-11.jsonl: %v %v", entries, err)
	}
}

// DiffusionGemma-style end to end: a Messages client with thinking on talks to a
// vLLM-hosted (rits/) chat deployment that answers in whole blocks. The upstream
// must get the vLLM thinking switch and the classic max_tokens; the client must
// see a keepalive ping during the reasoning-only block, the answer as text, and
// none of the reasoning.
func TestMessagesClientBlockDiffusionStream(t *testing.T) {
	const model = "rits/google/diffusiongemma-26B-A4B-it"
	var got map[string]any
	a, _ := chatRoutedModelApp(t, model, func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		got, _ = decodeObject(raw)
		w.Header().Set("content-type", "text/event-stream")
		for _, c := range []string{
			`{"id":"c1","choices":[{"delta":{"role":"assistant","reasoning_content":"a whole canvas of private thinking"}}]}`,
			`{"id":"c1","choices":[{"delta":{"content":"The answer is 42."},"finish_reason":"stop"}]}`,
			`{"id":"c1","choices":[],"usage":{"prompt_tokens":9,"completion_tokens":280}}`,
			`[DONE]`,
		} {
			_, _ = io.WriteString(w, "data: "+c+"\n\n")
		}
	})
	rec := messagesRequest(a, `{"model":"`+model+`","max_tokens":64,"stream":true,"thinking":{"type":"enabled","budget_tokens":2000},"messages":[{"role":"user","content":"hi"}]}`)
	if rec.Code != 200 {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if kw := asMap(got["chat_template_kwargs"]); kw == nil || !asBool(kw["enable_thinking"]) {
		t.Fatalf("the vLLM thinking switch did not reach the upstream: %v", got)
	}
	if _, ok := got["max_tokens"]; !ok {
		t.Fatalf("a rits/ chat model keeps classic max_tokens: %v", got)
	}
	body := rec.Body.String()
	if ping, text := strings.Index(body, "event: ping"), strings.Index(body, `"text":"The answer is 42."`); ping < 0 || text < 0 || ping > text {
		t.Fatalf("want a keepalive ping before the answer text:\n%s", body)
	}
	if strings.Contains(body, "private thinking") {
		t.Fatalf("reasoning leaked to the client:\n%s", body)
	}
}
