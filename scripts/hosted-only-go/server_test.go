package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// proxyHarness runs the real handler against a stub gateway that answers every
// upstream call with the given status and body, counting calls per model.
type proxyHarness struct {
	app   *app
	mu    sync.Mutex
	calls map[string]int
}

func newProxyHarness(t *testing.T, status int, body string, tweak func(*config)) *proxyHarness {
	t.Helper()
	h := &proxyHarness{calls: map[string]int{}}
	stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reqBody, _ := io.ReadAll(r.Body) // a single Read may return a partial body
		var model string
		if data, err := decodeObject(reqBody); err == nil {
			model = asString(data["model"])
		}
		h.mu.Lock()
		h.calls[model]++
		h.mu.Unlock()
		w.Header().Set("content-type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(stub.Close)
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
