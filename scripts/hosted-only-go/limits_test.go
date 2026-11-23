package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestParseDuration(t *testing.T) {
	cases := map[string]float64{
		"120":      120,
		"6m0s":     360,
		"1h2m3.5s": 3723.5,
		"250ms":    0.25,
	}
	for raw, want := range cases {
		got, ok := parseDuration(raw)
		if !ok || got != want {
			t.Fatalf("parseDuration(%q) = %v, %v; want %v", raw, got, ok, want)
		}
	}
	if _, ok := parseDuration("soon"); ok {
		t.Fatal("parseDuration accepted junk")
	}
}

func TestAnalyzeLimitRetryAfterHeader(t *testing.T) {
	now := time.Now()
	info := analyzeLimit(testConfig(), 429, map[string]string{"retry-after": "120"}, "rate limited", now)
	if got := info.Reset.Sub(now); got < 119*time.Second || got > 121*time.Second {
		t.Fatalf("reset delta = %v, want ~120s", got)
	}
	if info.Source != "upstream-header:retry-after" {
		t.Fatalf("source = %q", info.Source)
	}
	if info.Monthly {
		t.Fatal("monthly = true, want false")
	}
}

func TestAnalyzeLimitBodyReset(t *testing.T) {
	now := time.Now()
	text := `{"error":{"message":"slow down","reset_after_seconds":90}}`
	info := analyzeLimit(testConfig(), 429, map[string]string{}, text, now)
	if got := info.Reset.Sub(now); got < 89*time.Second || got > 91*time.Second {
		t.Fatalf("reset delta = %v, want ~90s", got)
	}
	if info.Source != "upstream-body:reset_after_seconds" {
		t.Fatalf("source = %q", info.Source)
	}
}

func TestAnalyzeLimitMonthlyEstimate(t *testing.T) {
	now := time.Now()
	info := analyzeLimit(testConfig(), 429, map[string]string{}, "Monthly token budget exhausted.", now)
	if !info.Monthly {
		t.Fatal("monthly = false, want true")
	}
	want := time.Date(now.In(time.UTC).Year(), now.In(time.UTC).Month()+1, 1, 0, 0, 0, 0, time.UTC)
	if !info.Reset.Equal(want) {
		t.Fatalf("reset = %v, want %v", info.Reset, want)
	}
	if info.Source != "estimate:next-month-utc" {
		t.Fatalf("source = %q", info.Source)
	}
}

func TestAnalyzeLimitLongResetIsQuota(t *testing.T) {
	now := time.Now()
	// 3 days out with no quota wording: still a quota, not a rate limit.
	info := analyzeLimit(testConfig(), 429, map[string]string{"retry-after": "259200"}, "rate limited", now)
	if !info.Monthly || info.Kind != "quota" {
		t.Fatalf("kind = %q monthly = %v, want quota", info.Kind, info.Monthly)
	}
}

func TestRenderAnthropicLimit(t *testing.T) {
	now := time.Now()
	cfg := testConfig()
	info := limitInfo{Reset: now.Add(120 * time.Second), Kind: "rate-limit", Source: "upstream-header:retry-after"}
	status, body, headers := renderLimit(cfg, "/v1/messages", cfg.GLM, info, 0, now)
	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", status)
	}
	if headers["retry-after"] != "120" {
		t.Fatalf("retry-after = %q", headers["retry-after"])
	}
	if headers["x-should-retry"] != "false" {
		t.Fatalf("x-should-retry = %q, want false (120 > knob 60)", headers["x-should-retry"])
	}
	text := string(body)
	if !strings.Contains(text, "[rits/zai-org/glm-5-3] [429]:") || !strings.Contains(text, "(reset after 2m)") {
		t.Fatalf("body = %s", text)
	}
	// Type-first key order: json.Marshal sorts map keys alphabetically, which
	// broke every consumer parsing the inner error shape (T3's adapter).
	var decoded map[string]any
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Fatalf("body: %v", err)
	}
	message := asString(asMap(decoded["error"])["message"])
	if !strings.Contains(message, `[429]: {"type":"error","error":{"type":"rate_limit_error","message":`) {
		t.Fatalf("inner error must be type-first, got: %s", message)
	}
}

func TestRenderAnthropicShortWaitStaysRetryable(t *testing.T) {
	now := time.Now()
	cfg := testConfig()
	info := limitInfo{Reset: now.Add(30 * time.Second), Kind: "rate-limit"}
	_, _, headers := renderLimit(cfg, "/v1/messages", cfg.GLM, info, 0, now)
	if _, ok := headers["x-should-retry"]; ok {
		t.Fatalf("x-should-retry = %q, want absent for a 30s wait", headers["x-should-retry"])
	}
}

// The production default knob (21600) matches the client watchdog's 6 h wait
// cap: an outage or rate-limit reset inside it must stay retryable so
// CLAUDE_CODE_RETRY_WATCHDOG sleeps through it.
func TestRenderAnthropicWatchdogWaitStaysRetryable(t *testing.T) {
	now := time.Now()
	cfg := testConfig()
	cfg.ClientRetryMax = 21600
	info := limitInfo{Reset: now.Add(480 * time.Second), Kind: "outage"}
	_, _, headers := renderLimit(cfg, "/v1/messages", cfg.GLM, info, 502, now)
	if _, ok := headers["x-should-retry"]; ok {
		t.Fatalf("x-should-retry = %q, want absent for a watchdog-sized wait", headers["x-should-retry"])
	}
}

// A month-end quota is never worth waiting out: the answer must fail fast so
// T3 snoozes the thread instead of Claude Code sleeping toward the reset.
func TestRenderAnthropicMonthlyQuotaFailsFast(t *testing.T) {
	now := time.Now()
	cfg := testConfig()
	cfg.ClientRetryMax = 21600
	info := limitInfo{Reset: monthEnd(now, time.UTC), QuotaReset: monthEnd(now, time.UTC), Monthly: true, Kind: "quota"}
	status, _, headers := renderLimit(cfg, "/v1/messages", cfg.GLM, info, 0, now)
	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", status)
	}
	if headers["x-should-retry"] != "false" {
		t.Fatalf("x-should-retry = %q, want false for a monthly quota", headers["x-should-retry"])
	}
}

func TestRenderChatQuotaIs402(t *testing.T) {
	now := time.Now()
	cfg := testConfig()
	info := limitInfo{Reset: monthEnd(now, time.UTC), QuotaReset: monthEnd(now, time.UTC), Monthly: true, Kind: "quota"}
	status, body, headers := renderLimit(cfg, "/v1/chat/completions", cfg.GLM, info, 0, now)
	if status != 402 {
		t.Fatalf("status = %d, want 402", status)
	}
	if _, ok := headers["retry-after"]; ok {
		t.Fatal("quota answer must not carry retry-after")
	}
	var decoded map[string]any
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Fatalf("body: %v", err)
	}
	errObj := asMap(decoded["error"])
	if asString(errObj["type"]) != "insufficient_quota" {
		t.Fatalf("type = %q", asString(errObj["type"]))
	}
	if !strings.Contains(asString(errObj["message"]), "Quota resets") {
		t.Fatalf("message = %q", asString(errObj["message"]))
	}
}

func TestRenderResponsesCarriesResetsAt(t *testing.T) {
	now := time.Now()
	cfg := testConfig()
	info := limitInfo{Reset: now.Add(30 * time.Second), Kind: "rate-limit"}
	status, body, headers := renderLimit(cfg, "/v1/responses", cfg.GLM, info, 0, now)
	if status != 429 {
		t.Fatalf("status = %d, want 429", status)
	}
	var decoded map[string]any
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Fatalf("body: %v", err)
	}
	errObj := asMap(decoded["error"])
	if _, ok := asInt(errObj["resets_at"]); !ok {
		t.Fatalf("error.resets_at missing: %s", body)
	}
	if headers["x-codex-primary-used-percent"] != "100" {
		t.Fatalf("codex headers missing: %#v", headers)
	}
	if headers["retry-after"] != "30" {
		t.Fatalf("retry-after = %q", headers["retry-after"])
	}
}

func TestLimitAndOutageClassification(t *testing.T) {
	if !isLimitError(429, nil, "") || !isLimitError(402, nil, "") {
		t.Fatal("429/402 must be limits")
	}
	if !isLimitError(503, nil, "Upstream rate limited") {
		t.Fatal("503 upstream rate limited must be a limit")
	}
	if isLimitError(500, nil, "boom") {
		t.Fatal("500 must not be a limit")
	}
	if !isOutageError(502, "") || !isOutageError(504, "") {
		t.Fatal("502/504 must be outages")
	}
	if !isOutageError(503, "no_db_connection: the authentication database is temporarily unreachable") {
		t.Fatal("503 no_db_connection must be an outage")
	}
	if isOutageError(429, "") {
		t.Fatal("429 must not be an outage")
	}
	if isOutageError(503, "upstream rate limited") {
		t.Fatal("503 rate limit must not be an outage")
	}
}

func TestPassthroughHeaders(t *testing.T) {
	now := time.Now()
	headers := map[string]string{
		"retry-after-ms":           "2000",
		"x-ratelimit-limit-tokens": "1000",
	}
	info := analyzeLimit(testConfig(), 429, headers, "rate limited", now)
	if info.Passthrough["x-ratelimit-limit-tokens"] != "1000" {
		t.Fatalf("passthrough = %#v", info.Passthrough)
	}
	if info.Passthrough["retry-after-ms"] != "2000" {
		t.Fatalf("retry-after-ms = %q", info.Passthrough["retry-after-ms"])
	}
}

// The observed EnMaaS monthly-quota event (2026-11-20, ryzen-wsl + spectrex360):
// 429 with type rate_limit_error AND code token_budget_exhausted, plus a
// retry-after header of 875,852 s (~243 h to the UTC month boundary). The
// quota code must win the classification and the announced reset must be
// capped.
func TestAnalyzeLimitEnMaasMonthlyQuotaCapped(t *testing.T) {
	now := time.Now()
	cfg := testConfig()
	cfg.LimitResetMax = 3600
	text := `{"error":{"message":"token budget exhausted","type":"rate_limit_error","code":"token_budget_exhausted"}}`
	info := analyzeLimit(cfg, 429, map[string]string{"retry-after": "875852"}, text, now)
	if !info.Monthly || info.Kind != "quota" {
		t.Fatalf("kind = %q monthly = %v, want quota/monthly", info.Kind, info.Monthly)
	}
	if got := info.Reset.Sub(now); got < 3599*time.Second || got > 3601*time.Second {
		t.Fatalf("reset delta = %v, want ~3600s (capped)", got)
	}
	if info.Source != "upstream-header:retry-after+capped" {
		t.Fatalf("source = %q", info.Source)
	}
	// The true window end survives for internal state and wording.
	if got := info.QuotaReset.Sub(now); got < 875850*time.Second {
		t.Fatalf("quota reset delta = %v, want the uncapped header value", got)
	}
	// A capped answer must not leak the uncapped reset via forwarded headers.
	if _, ok := info.Passthrough["x-ratelimit-reset-tokens"]; ok {
		t.Fatal("capped answer forwarded x-ratelimit-reset-tokens")
	}
}

func TestAnalyzeLimitPassthroughKeptWhenUncapped(t *testing.T) {
	now := time.Now()
	cfg := testConfig()
	cfg.LimitResetMax = 3600
	info := analyzeLimit(cfg, 429, map[string]string{
		"retry-after": "60", "x-ratelimit-reset-tokens": "60",
	}, "rate limited", now)
	if info.Monthly {
		t.Fatal("monthly = true, want false")
	}
	if info.Passthrough["x-ratelimit-reset-tokens"] != "60" {
		t.Fatalf("passthrough = %v, want the short reset forwarded", info.Passthrough)
	}
}

// Field identity is positional: a type/code value that textually equals the
// reason string must still match the exact rate map (CodeRabbit + GLM review
// on #664: {"reason":"tokens","type":"tokens"} and
// {"reason":"too_many_requests","type":"too_many_requests"}).
func TestBodyKindPositionalFieldSemantics(t *testing.T) {
	for _, body := range []map[string]any{
		{"reason": "tokens", "type": "tokens"},
		{"reason": "too_many_requests", "type": "too_many_requests"},
	} {
		if got := bodyKind(body); got != "rate-limit" {
			t.Fatalf("bodyKind(%v) = %q, want rate-limit", body, got)
		}
	}
}

func TestAnalyzeLimitResetCapZeroUncapped(t *testing.T) {
	now := time.Now()
	cfg := testConfig()
	cfg.LimitResetMax = 0
	text := `{"error":{"message":"token budget exhausted","type":"rate_limit_error","code":"token_budget_exhausted"}}`
	info := analyzeLimit(cfg, 429, map[string]string{"retry-after": "875852"}, text, now)
	if !info.Monthly {
		t.Fatal("monthly = false, want true")
	}
	if got := info.Reset.Sub(now); got < 875850*time.Second {
		t.Fatalf("reset delta = %v, want the uncapped header value", got)
	}
}

func TestBodyKindQuotaCodeBeatsRateType(t *testing.T) {
	err := map[string]any{"type": "rate_limit_error", "code": "token_budget_exhausted"}
	if got := bodyKind(err); got != "quota" {
		t.Fatalf("bodyKind = %q, want quota", got)
	}
}

// The fail-fast must key on the UNCAPPED reset: a 7-day rate-limit reset
// capped to 1 h would otherwise stay retryable and a watchdog client would
// re-probe in-process for the whole window instead of handing off to T3.
func TestRenderCappedLongWaitStillFailsFast(t *testing.T) {
	now := time.Now()
	cfg := testConfig()
	cfg.LimitResetMax = 3600
	cfg.ClientRetryMax = 21600
	info := limitInfo{
		Reset:      now.Add(3600 * time.Second),   // capped announcement
		QuotaReset: now.Add(604800 * time.Second), // true 7-day wait
		Kind:       "rate-limit",
	}
	_, _, headers := renderLimit(cfg, "/v1/messages", cfg.GLM, info, 0, now)
	if headers["x-should-retry"] != "false" {
		t.Fatalf("x-should-retry = %q, want false (uncapped 7d > knob 6h)", headers["x-should-retry"])
	}
	if headers["retry-after"] != "3600" {
		t.Fatalf("retry-after = %q, want the capped 3600", headers["retry-after"])
	}
}

// Rank-first candidate selection can pair a short chosen reset with a
// month-sized forwarded header (retry-after: 30 alongside
// x-ratelimit-reset-tokens: 875852): the per-header magnitude check must
// drop the long one even though the chosen reset was never capped.
func TestAnalyzeLimitPassthroughDropsMonthSizedHeaderDespiteShortChosen(t *testing.T) {
	now := time.Now()
	cfg := testConfig()
	cfg.LimitResetMax = 3600
	info := analyzeLimit(cfg, 429, map[string]string{
		"retry-after": "30", "x-ratelimit-reset-tokens": "875852",
		"x-ratelimit-remaining-tokens": "0",
	}, "rate limited", now)
	if _, ok := info.Passthrough["x-ratelimit-reset-tokens"]; ok {
		t.Fatal("month-sized x-ratelimit-reset-tokens was forwarded")
	}
	if info.Passthrough["x-ratelimit-remaining-tokens"] != "0" {
		t.Fatalf("remaining dimension dropped: %v", info.Passthrough)
	}
	if _, ok := info.Passthrough["retry-after"]; ok {
		t.Fatal("plain retry-after must not be forwarded (renderLimit sets its own)")
	}
	// IETF ratelimit policy with a month-sized reset field is dropped too.
	info = analyzeLimit(cfg, 429, map[string]string{
		"retry-after": "30",
		"ratelimit":   "limit=100, r=0; t=875852",
	}, "rate limited", now)
	if _, ok := info.Passthrough["ratelimit"]; ok {
		t.Fatal("month-sized IETF ratelimit policy was forwarded")
	}
	// A short policy stays.
	info = analyzeLimit(cfg, 429, map[string]string{
		"retry-after": "30",
		"ratelimit":   "limit=100, r=0; t=45",
	}, "rate limited", now)
	if info.Passthrough["ratelimit"] != "limit=100, r=0; t=45" {
		t.Fatalf("short IETF policy dropped: %v", info.Passthrough)
	}
}
