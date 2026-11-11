package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// routedApp builds the real handler for one deployment dialect served by stub.
// dialect "anthropic" exercises the native streamResponse path; "openai" the
// translated one. RequestTimeout is the header (first-byte) budget and
// StreamIdleTimeout the no-bytes watchdog.
func routedApp(t *testing.T, dialect string, headerTimeout, idle time.Duration, stub http.HandlerFunc) *app {
	t.Helper()
	gw := httptest.NewServer(stub)
	t.Cleanup(gw.Close)
	t.Setenv("LLM_USAGE_DIR", t.TempDir())
	model := "gpt-5-mini"
	if dialect == "anthropic" {
		model = "claude-test"
	}
	doc := map[string]any{
		"model_list": []any{map[string]any{"model_name": model, "litellm_params": map[string]any{
			"model": dialect + "/" + model, "api_base": gw.URL + "/v1"}}},
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
	cfg.RequestTimeout = headerTimeout
	cfg.StreamIdleTimeout = idle
	return newApp(cfg)
}

func sseStream(w http.ResponseWriter, chunks []string, gap time.Duration) {
	w.Header().Set("content-type", "text/event-stream")
	w.WriteHeader(http.StatusOK)
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
	for _, c := range chunks {
		_, _ = io.WriteString(w, c)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		time.Sleep(gap)
	}
}

// An actively streaming answer must outlive the header timeout: the old
// http.Client.Timeout cut it mid-answer at exactly that number (2026-11-11
// GLM "Claude API unknown").
func TestActiveStreamOutlivesRequestTimeout(t *testing.T) {
	chunks := []string{
		"event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n",
		"event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
	}
	words := []string{"Hel", "lo", " wor", "ld", " and", " more", " text", " here"}
	for _, wd := range words {
		chunks = append(chunks, "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\""+wd+"\"}}\n\n")
	}
	chunks = append(chunks,
		"event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
		"event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":8}}\n\n",
		"event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
	)
	a := routedApp(t, "anthropic", 200*time.Millisecond, 5*time.Second, func(w http.ResponseWriter, r *http.Request) {
		sseStream(w, chunks, 60*time.Millisecond) // ~700ms total, > header budget
	})
	rec := messagesRequest(a, `{"model":"claude-test","max_tokens":64,"stream":true,"messages":[{"role":"user","content":"hi"}]}`)
	body := rec.Body.String()
	if !strings.Contains(body, "message_stop") || !strings.Contains(body, " wor") {
		t.Fatalf("an active stream must not be cut by the header timeout:\n%s", body)
	}
	events := a.usageEvents(t)
	if len(events) != 1 || events[0]["ok"] != true {
		t.Fatalf("the surviving stream must be one success event: %v", events)
	}
}

// usageEvents reads the JSONL this app wrote (the test's temp LLM_USAGE_DIR).
func (a *app) usageEvents(t *testing.T) []map[string]any {
	t.Helper()
	files, err := os.ReadDir(a.cfg.UsageDir)
	if err != nil {
		return nil
	}
	var out []map[string]any
	for _, f := range files {
		if !strings.HasPrefix(f.Name(), "events-") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(a.cfg.UsageDir, f.Name()))
		if err != nil {
			continue
		}
		for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
			if line == "" {
				continue
			}
			if obj, err := decodeObject([]byte(line)); err == nil && obj != nil {
				out = append(out, obj)
			}
		}
	}
	return out
}

// A stream that produces no bytes for STREAM_IDLE_TIMEOUT is cut and ends with
// a retryable rate_limit_error event (Claude Code retries it) plus the outage
// wait in the usage event.
func TestStalledStreamIsCutAndAnsweredRetryable(t *testing.T) {
	a := routedApp(t, "anthropic", 2*time.Second, 250*time.Millisecond, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n")
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		time.Sleep(3 * time.Second) // stall past the idle budget
	})
	start := time.Now()
	rec := messagesRequest(a, `{"model":"claude-test","max_tokens":64,"stream":true,"messages":[{"role":"user","content":"hi"}]}`)
	if took := time.Since(start); took > 2*time.Second {
		t.Fatalf("the idle watchdog must cut the stall quickly, took %s", took)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, "rate_limit_error") || !strings.Contains(body, "retry after") {
		t.Fatalf("a stalled stream must end with a retryable error event:\n%s", body)
	}
	events := a.usageEvents(t)
	if len(events) == 0 {
		t.Fatal("no usage event")
	}
	last := events[len(events)-1]
	if last["ok"] == true || last["retry_after"] == nil {
		t.Fatalf("the stall must be recorded with its retry wait: %v", last)
	}
}

// A non-streaming answer whose body stalls can still be answered retryably:
// the buffered path renders the 429 shape before anything reaches the client.
func TestStalledBodyNonStreamAnswers429(t *testing.T) {
	a := routedApp(t, "openai", 2*time.Second, 250*time.Millisecond, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"id":"c","choices":[`)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		time.Sleep(3 * time.Second)
	})
	rec := messagesRequest(a, `{"model":"gpt-5-mini","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}`)
	// Messages clients get the 503+retry-after shape (renderLimit), chat/Responses 429.
	if rec.Code != http.StatusTooManyRequests && rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("a stalled buffered body must answer retryably, got %d %s", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("retry-after") == "" {
		t.Fatal("429 must carry retry-after")
	}
}

// A first-byte timeout happens before anything reaches the client; with the
// outage rewrite it answers retryably instead of a bare 502.
func TestFirstByteTimeoutAnswersRetryable(t *testing.T) {
	a := routedApp(t, "anthropic", 200*time.Millisecond, 0, func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(2 * time.Second) // never sends headers in budget
		w.WriteHeader(http.StatusOK)
	})
	rec := messagesRequest(a, `{"model":"claude-test","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}`)
	if rec.Code != http.StatusServiceUnavailable && rec.Code != http.StatusTooManyRequests {
		t.Fatalf("a first-byte timeout must be retryable, got %d %s", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("retry-after") == "" {
		t.Fatal("retryable answer must carry retry-after")
	}
}
