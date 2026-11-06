package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// proxyHarness runs the real handler against a stub gateway that answers every
// upstream call with the given status and body, counting calls per model.
type proxyHarness struct {
	app   *app
	url   string
	mu    sync.Mutex
	calls map[string]int
	paths map[string][]string // upstream API path seen per model
}

func newProxyHarness(t *testing.T, status int, body string, tweak func(*config)) *proxyHarness {
	t.Helper()
	h := &proxyHarness{calls: map[string]int{}, paths: map[string][]string{}}
	stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reqBody, _ := io.ReadAll(r.Body) // a single Read may return a partial body
		var model string
		if data, err := decodeObject(reqBody); err == nil {
			model = asString(data["model"])
		}
		h.mu.Lock()
		h.calls[model]++
		h.paths[model] = append(h.paths[model], r.URL.Path)
		h.mu.Unlock()
		w.Header().Set("content-type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(stub.Close)
	h.url = stub.URL
	t.Setenv("ENMAAS_API_KEY", "test-key")
	t.Setenv("HOSTED_ONLY_ENMAAS_BASE_URL", stub.URL)
	t.Setenv("LLM_USAGE_DIR", t.TempDir())
	cfg := loadConfig("claude", "0", t.TempDir())
	if tweak != nil {
		tweak(cfg)
	}
	h.app = newApp(cfg)
	return h
}

func (h *proxyHarness) messages(model string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/v1/messages",
		strings.NewReader(`{"model":"`+model+`","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`))
	req.Header.Set("x-api-key", h.app.cfg.Token)
	req.Header.Set("content-type", "application/json")
	rec := httptest.NewRecorder()
	h.app.ServeHTTP(rec, req)
	return rec
}

func (h *proxyHarness) count(model string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.calls[model]
}

// LIMIT_REWRITE=0 used to silence the outage rewrite too, leaving 502/504/529
// answers unwritten for T3 (it only resumes a thread from a reset-bearing
// answer). Either knob must be enough on its own.
func TestOutageRewriteSurvivesLimitRewriteOff(t *testing.T) {
	h := newProxyHarness(t, 529, `{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}`, func(c *config) {
		c.LimitRewrite = false
		c.OutageRewrite = true
		c.FallbackOn = false
	})
	rec := h.messages("rits/zai-org/glm-5-3")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("a 529 outage must become a reset-bearing 503, got %d: %s", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("retry-after") == "" {
		t.Fatalf("missing retry-after: %v", rec.Header())
	}
}

func TestBothRewritesOffPassesTheUpstreamAnswerThrough(t *testing.T) {
	h := newProxyHarness(t, 529, `{"type":"error","error":{"type":"overloaded_error"}}`, func(c *config) {
		c.LimitRewrite = false
		c.OutageRewrite = false
		c.FallbackOn = false
	})
	if rec := h.messages("rits/zai-org/glm-5-3"); rec.Code != 529 {
		t.Fatalf("both knobs off must not rewrite: %d", rec.Code)
	}
}

func TestGatewayMeteringOutageIsRewritten(t *testing.T) {
	h := newProxyHarness(t, 503, `{"error":{"message":"metering system unavailable"}}`, func(c *config) { c.FallbackOn = false })
	if rec := h.messages("rits/zai-org/glm-5-3"); rec.Code != http.StatusServiceUnavailable || rec.Header().Get("retry-after") == "" {
		t.Fatalf("503 metering unavailable must carry a reset: %d %v", rec.Code, rec.Header())
	}
}

// A monthly quota is account-wide: falling back to the other model only buys
// the same 429 plus latency, so after one quota answer the fallback is skipped
// until the reset.
func TestQuotaExhaustedModelSkipsTheFallback(t *testing.T) {
	quota := `{"error":{"message":"monthly token budget exhausted","type":"insufficient_quota"}}`
	h := newProxyHarness(t, 429, quota, nil)
	glm, ds := h.app.cfg.GLM, h.app.cfg.DeepSeek

	h.messages(glm)
	if h.count(glm) != 1 || h.count(ds) != 1 {
		t.Fatalf("first request tries GLM then the fallback: glm=%d ds=%d", h.count(glm), h.count(ds))
	}
	h.messages(glm)
	if h.count(glm) != 2 || h.count(ds) != 1 {
		t.Fatalf("with the quota active the second request must not fall back: glm=%d ds=%d", h.count(glm), h.count(ds))
	}
}

func TestRateLimitedModelStillFallsBack(t *testing.T) {
	// A per-minute rate limit is NOT account-wide quota: the other model may answer.
	h := newProxyHarness(t, 429, `{"error":{"message":"slow down"}}`, nil)
	glm, ds := h.app.cfg.GLM, h.app.cfg.DeepSeek
	h.messages(glm)
	h.messages(glm)
	if h.count(ds) != 2 {
		t.Fatalf("a rate limit must keep falling back: ds=%d", h.count(ds))
	}
}

// An explicit dialect override can give the two hosted models different
// dialects. A Messages request that fails over to a chat-dialect fallback must
// NEVER forward a Messages body to a chat endpoint: it is translated (the
// fallback answers on /v1/chat/completions) or, when translation is impossible,
// skipped with the original failure returned. The control run (both Anthropic)
// still falls back on /v1/messages.
func TestFallbackIsTranslatedForItsDialect(t *testing.T) {
	run := func(t *testing.T, fallbackDialect string) *proxyHarness {
		h := newProxyHarness(t, 502, `{"error":{"message":"bad gateway"}}`, nil)
		glm, ds := h.app.cfg.GLM, h.app.cfg.DeepSeek
		route := func(name, dialect, base string) map[string]any {
			return map[string]any{"model_name": name, "litellm_params": map[string]any{"model": dialect + "/" + name, "api_base": base}}
		}
		doc := map[string]any{"model_list": []any{route(glm, "anthropic", h.url), route(ds, fallbackDialect, h.url)},
			"general_settings": map[string]any{"master_key": "x"}}
		path := filepath.Join(t.TempDir(), "routes.json")
		if err := os.WriteFile(path, marshal(doc), 0o600); err != nil {
			t.Fatal(err)
		}
		routes, err := loadRouteTable(path, "")
		if err != nil {
			t.Fatal(err)
		}
		h.app.cfg.Routes = routes
		h.messages(glm)
		return h
	}
	h := run(t, "openai")
	ds := h.app.cfg.DeepSeek
	if h.count(h.app.cfg.GLM) != 1 || h.count(ds) != 1 {
		t.Fatalf("a chat-dialect fallback is translated and tried once: glm=%d ds=%d", h.count(h.app.cfg.GLM), h.count(ds))
	}
	if got := h.paths[ds]; len(got) != 1 || got[0] != "/v1/chat/completions" {
		t.Fatalf("the chat-dialect fallback must be called on /v1/chat/completions, not with a Messages body: %v", got)
	}
	h = run(t, "responses")
	if got := h.paths[h.app.cfg.DeepSeek]; len(got) != 1 || got[0] != "/v1/responses" {
		t.Fatalf("a Responses-dialect fallback must be called on /v1/responses: %v", got)
	}
	h = run(t, "anthropic")
	if got := h.paths[h.app.cfg.DeepSeek]; len(got) != 1 || got[0] != "/v1/messages" {
		t.Fatalf("control: an Anthropic-dialect fallback stays on /v1/messages: %v", got)
	}
}
