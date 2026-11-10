package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// warmApp builds the real handler with the mlx flavor and a stub upstream.
func warmApp(t *testing.T, stub http.HandlerFunc, rssKB int, retryAfter, max int) (*app, *httptest.Server, *int32) {
	t.Helper()
	gw := httptest.NewServer(stub)
	t.Cleanup(gw.Close)
	t.Setenv("LLM_USAGE_DIR", t.TempDir())
	doc := map[string]any{
		"model_list":       []any{map[string]any{"model_name": "local-model", "litellm_params": map[string]any{"model": "openai/local-model", "api_base": gw.URL + "/v1"}}},
		"general_settings": map[string]any{"master_key": "x"},
	}
	path := writeRoutes(t, doc)
	routes, err := loadRouteTable(path, "")
	if err != nil {
		t.Fatal(err)
	}
	cfg := loadConfig("mlx", "0", t.TempDir())
	cfg.Routes = routes
	cfg.Token = "tok"
	cfg.WarmRSSKB = rssKB
	cfg.WarmRetryAfter = retryAfter
	cfg.WarmMax = max
	a := newApp(cfg)
	cfg.WarmServerCmd = "true"
	var kicks int32
	oldRSS, oldSpawn := mlxListenerRSS, mlxSpawnServer
	t.Cleanup(func() { mlxListenerRSS, mlxSpawnServer = oldRSS, oldSpawn })
	mlxListenerRSS = func(string) (int, bool, bool) { return 0, false, true } // per-test override below
	mlxSpawnServer = func(string, string) { atomic.AddInt32(&kicks, 1) }
	return a, gw, &kicks
}

func writeRoutes(t *testing.T, doc map[string]any) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "routes.json")
	if err := os.WriteFile(path, marshal(doc), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// A cold model answers 429 + retry-after and kicks the load once; a resident
// model forwards normally; probes (no API request) never reach this.
func TestMlxWarmGateAnswersRetryableWhileCold(t *testing.T) {
	var upstreamCalls int32
	a, _, kicks := warmApp(t, func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&upstreamCalls, 1)
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"id":"c","choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"hi"}}]}`))
	}, 10*1024*1024, 30, 900)
	// cold: listener RSS below the threshold
	mlxListenerRSS = func(string) (int, bool, bool) { return 1024, true, true }

	body := `{"model":"local-model","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`
	rec := messagesRequest(a, body)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("cold request must be a retryable 429, got %d %s", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("retry-after"); got != "30" {
		t.Fatalf("retry-after %q", got)
	}
	if !strings.Contains(rec.Body.String(), "model loading") && !strings.Contains(rec.Body.String(), "model is loading") {
		t.Fatalf("body must say the model is loading: %s", rec.Body.String())
	}
	if atomic.LoadInt32(kicks) != 0 {
		t.Fatalf("a present-but-loading listener must not be spawned again, got %d spawns", atomic.LoadInt32(kicks))
	}
	if atomic.LoadInt32(&upstreamCalls) != 0 {
		t.Fatal("no upstream call while cold")
	}

	// resident: forwards
	mlxListenerRSS = func(string) (int, bool, bool) { return 11 * 1024 * 1024, true, true }
	a.warmGateState.checkedAt = time.Time{} // bypass the 1s cache
	rec = messagesRequest(a, body)
	if rec.Code != 200 || atomic.LoadInt32(&upstreamCalls) != 1 {
		t.Fatalf("resident request must forward: %d %s", rec.Code, rec.Body.String())
	}
}

// An unmeasurable listener (no lsof/ps) fails open: never wedge the proxy.
func TestMlxWarmGateFailsOpenWhenUnmeasurable(t *testing.T) {
	var upstreamCalls int32
	a, _, kicks := warmApp(t, func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&upstreamCalls, 1)
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"id":"c","choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"hi"}}]}`))
	}, 10*1024*1024, 30, 900)
	mlxListenerRSS = func(string) (int, bool, bool) { return 0, false, false }
	rec := messagesRequest(a, `{"model":"local-model","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`)
	if rec.Code != 200 || atomic.LoadInt32(&upstreamCalls) != 1 || atomic.LoadInt32(kicks) != 0 {
		t.Fatalf("unmeasurable must forward without kicking: %d kicks=%d upstream=%d", rec.Code, atomic.LoadInt32(kicks), atomic.LoadInt32(&upstreamCalls))
	}
}

// A load longer than the budget stops holding the client (request blocks
// upstream instead of 429ing forever).
func TestMlxWarmGateGivesUpAfterBudget(t *testing.T) {
	var upstreamCalls int32
	a, _, _ := warmApp(t, func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&upstreamCalls, 1)
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"id":"c","choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"hi"}}]}`))
	}, 10*1024*1024, 30, 1)
	mlxListenerRSS = func(string) (int, bool, bool) { return 1024, true, true }
	a.warmGateState.warmStart = time.Now().Add(-5 * time.Second)
	rec := messagesRequest(a, `{"model":"local-model","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`)
	if rec.Code != 200 || atomic.LoadInt32(&upstreamCalls) != 1 {
		t.Fatalf("past the budget the request must pass through: %d", rec.Code)
	}
}

// The gate is mlx-only: other flavors never consult it.
func TestWarmGateOffForOtherFlavors(t *testing.T) {
	var upstreamCalls int32
	a, _, kicks := warmApp(t, func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&upstreamCalls, 1)
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"id":"c","choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"hi"}}]}`))
	}, 10*1024*1024, 30, 900)
	a.cfg.Flavor = "claude"
	mlxListenerRSS = func(string) (int, bool, bool) { return 1024, true, true }
	rec := messagesRequest(a, `{"model":"local-model","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`)
	if rec.Code != 200 || atomic.LoadInt32(kicks) != 0 {
		t.Fatalf("non-mlx flavors must not gate: %d kicks=%d", rec.Code, atomic.LoadInt32(kicks))
	}
}

// No listener at all: spawn mlx_lm.server once (the load happens in the
// server's own startup) and answer the retryable 429.
func TestMlxWarmGateSpawnsServerWhenAbsent(t *testing.T) {
	var upstreamCalls int32
	a, _, kicks := warmApp(t, func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&upstreamCalls, 1)
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"id":"c","choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"hi"}}]}`))
	}, 10*1024*1024, 30, 900)
	mlxListenerRSS = func(string) (int, bool, bool) { return 0, false, true }
	rec := messagesRequest(a, `{"model":"local-model","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("absent server must be a retryable 429, got %d", rec.Code)
	}
	if got := atomic.LoadInt32(kicks); got != 1 {
		t.Fatalf("the gate must spawn the server once, got %d", got)
	}
	if atomic.LoadInt32(&upstreamCalls) != 0 {
		t.Fatal("no upstream call without a server")
	}
}
