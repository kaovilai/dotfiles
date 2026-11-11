package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	longWaitQuotaSeconds = 86400 // an upstream reset this far out is a quota
	upstreamRateLimited  = "upstream rate limited"
	budgetExhaustedText  = "token budget exhausted"
)

var (
	durationRe = regexp.MustCompile(`(\d+(?:\.\d+)?)(ms|h|m|s)`)
	// The gateway answers 503 no_db_connection when its auth DB is down and
	// gateway-wide 503 "metering system unavailable" / "service unavailable"
	// when its metering plane is down (observed 2026-10-22: 90 + 33 unrewritten
	// events), so they become reset-bearing answers T3 resumes from.
	outageGateway = regexp.MustCompile(`(?i)no_db_connection|database is temporarily unreachable|retry shortly|metering system unavailable|service unavailable`)
	// A refused/dropped connect and a DNS failure surface as a 500 with these
	// shapes — the same transient class as "Connection error".
	outageConn = regexp.MustCompile(`(?i)connection error|connection (refused|reset|aborted)|connect timeout` +
		`|cannot connect to host|connect call failed|nodename nor servname` +
		`|name or service not known|temporary failure in name resolution|network is unreachable`)
	// Monthly-budget wording that only appears in the message (bodyKind reads
	// the structured reason/type/code fields), used by the failover-reason
	// classifier so a quota 429 is not filed under plain throttling.
	quotaMessage = regexp.MustCompile(`(?i)token budget exhausted|monthly token budget|monthly_quota`)
)

type limitInfo struct {
	Reset       time.Time
	Monthly     bool
	Kind        string // quota | rate-limit | outage
	Source      string
	Passthrough map[string]string
}

type resetCand struct {
	rank   int
	at     time.Time
	source string
}

// normalizeHeaders lower-cases header names and drops the llm_provider- prefix
// LiteLLM adds to forwarded provider headers.
func normalizeHeaders(h http.Header) map[string]string {
	out := make(map[string]string, len(h))
	for name, values := range h {
		key := strings.ToLower(name)
		key = strings.TrimPrefix(key, "llm_provider-")
		if _, seen := out[key]; !seen && len(values) > 0 {
			out[key] = strings.Join(values, ", ")
		}
	}
	return out
}

func parseDuration(raw string) (float64, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0, false
	}
	if v, err := strconv.ParseFloat(raw, 64); err == nil && !math.IsInf(v, 0) && !math.IsNaN(v) {
		return v, true
	}
	matches := durationRe.FindAllStringSubmatch(raw, -1)
	if len(matches) == 0 {
		return 0, false
	}
	var built strings.Builder
	scale := map[string]float64{"h": 3600, "m": 60, "s": 1, "ms": 0.001}
	total := 0.0
	for _, m := range matches {
		built.WriteString(m[1] + m[2])
		n, _ := strconv.ParseFloat(m[1], 64)
		total += n * scale[m[2]]
	}
	if built.String() != raw {
		return 0, false
	}
	return total, true
}

func parseWhen(raw string, now time.Time) (time.Time, bool) {
	text := strings.TrimSpace(raw)
	if text == "" {
		return time.Time{}, false
	}
	if v, err := strconv.ParseFloat(text, 64); err == nil {
		switch {
		case v > 1e12:
			return time.UnixMilli(int64(v)), true
		case v > 1e9:
			return time.Unix(int64(v), 0), true
		default:
			return now.Add(time.Duration(v * float64(time.Second))), true
		}
	}
	if t, err := time.Parse(time.RFC3339, strings.Replace(text, "Z", "+00:00", 1)); err == nil {
		return t, true
	}
	if t, err := http.ParseTime(text); err == nil {
		return t, true
	}
	return time.Time{}, false
}

func errorBodyObject(text string) map[string]any {
	start := strings.IndexByte(text, '{')
	end := strings.LastIndexByte(text, '}')
	if start < 0 || end <= start {
		return nil
	}
	var data map[string]any
	if err := json.Unmarshal([]byte(text[start:end+1]), &data); err != nil {
		return nil
	}
	return data
}

func errorObject(body map[string]any) map[string]any {
	if body == nil {
		return nil
	}
	if err, ok := body["error"].(map[string]any); ok {
		return err
	}
	return body
}

func isLimitError(status int, headers map[string]string, text string) bool {
	if status == 429 || status == 402 {
		return true
	}
	if status == 503 && strings.Contains(strings.ToLower(text), upstreamRateLimited) {
		return true
	}
	err := errorObject(errorBodyObject(text))
	if err == nil {
		return false
	}
	return strings.EqualFold(asString(err["code"]), "rate_limited")
}

var outageStatuses = map[int]bool{408: true, 502: true, 504: true, 524: true, 529: true}

func isOutageError(status int, text string) bool {
	if isLimitError(status, nil, text) {
		return false
	}
	if outageStatuses[status] {
		return true
	}
	if status == 503 {
		return outageGateway.MatchString(text)
	}
	return status == 500 && outageConn.MatchString(text)
}

func bodyKind(err map[string]any) string {
	if err == nil {
		return ""
	}
	quota := map[string]bool{
		"insufficient_quota": true, "quota_exceeded": true, "quota_exhausted": true,
		"budget_exceeded": true, "billing_hard_limit_reached": true, "usage_limit_reached": true,
	}
	rate := map[string]bool{
		"rate_limit_exceeded": true, "rate_limit_error": true, "rate_limited": true,
		"too_many_requests": true, "requests": true, "tokens": true,
	}
	reason := strings.ToLower(asString(err["reason"]))
	if strings.HasPrefix(reason, "monthly_") || quota[reason] {
		return "quota"
	}
	if reason != "" && (strings.Contains(reason, "rate_limit") ||
		strings.HasPrefix(reason, "per_second") || strings.HasPrefix(reason, "per_minute") ||
		strings.HasPrefix(reason, "per_hour") || reason == "rpm" || reason == "tpm") {
		return "rate-limit"
	}
	for _, field := range []string{"type", "code"} {
		value := strings.ToLower(asString(err[field]))
		if quota[value] {
			return "quota"
		}
		if rate[value] {
			return "rate-limit"
		}
	}
	return ""
}

func pickReset(pairs []resetCand, remaining map[string]float64) (resetCand, bool) {
	if len(pairs) == 0 {
		return resetCand{}, false
	}
	exhausted := make([]resetCand, 0, len(pairs))
	for _, p := range pairs {
		if r, ok := remaining[p.source]; ok && r <= 0 {
			exhausted = append(exhausted, p)
		}
	}
	if len(exhausted) > 0 {
		sort.Slice(exhausted, func(i, j int) bool { return exhausted[i].at.After(exhausted[j].at) })
		return exhausted[0], true
	}
	sort.Slice(pairs, func(i, j int) bool { return pairs[i].at.Before(pairs[j].at) })
	return pairs[0], true
}

// analyzeLimit mirrors hosted_only_hooks.analyze_limit: reset from headers
// (ranked), then body, else an estimate.
func analyzeLimit(cfg *config, status int, headers map[string]string, text string, now time.Time) limitInfo {
	var cands []resetCand
	handled := map[string]bool{}

	add := func(rank int, at time.Time, source string) {
		cands = append(cands, resetCand{rank: rank, at: at, source: "upstream-header:" + source})
	}

	if raw, ok := headers["retry-after-ms"]; ok {
		handled["retry-after-ms"] = true
		if ms, ok := parseDuration(raw); ok && ms > 0 {
			add(0, now.Add(time.Duration(ms*float64(time.Millisecond))), "retry-after-ms")
		}
	}
	if raw, ok := headers["retry-after"]; ok {
		handled["retry-after"] = true
		if seconds, ok := parseDuration(raw); ok {
			if seconds > 0 {
				add(1, now.Add(time.Duration(seconds*float64(time.Second))), "retry-after")
			}
		} else if at, ok := parseWhen(raw, now); ok {
			add(1, at, "retry-after")
		}
	}

	// OpenAI x-ratelimit-reset-<dim>, gated by the matching remaining header.
	var openai []resetCand
	remaining := map[string]float64{}
	for name, value := range headers {
		dim, ok := strings.CutPrefix(name, "x-ratelimit-reset-")
		if !ok {
			continue
		}
		handled[name] = true
		seconds, ok := parseDuration(value)
		if !ok {
			continue
		}
		if raw, ok := headers["x-ratelimit-remaining-"+dim]; ok {
			handled["x-ratelimit-remaining-"+dim] = true
			if r, ok := parseDuration(raw); ok {
				remaining[name] = r
			}
		}
		openai = append(openai, resetCand{rank: 3, at: now.Add(time.Duration(seconds * float64(time.Second))), source: name})
	}
	if chosen, ok := pickReset(openai, remainingBySource(openai, remaining)); ok {
		add(chosen.rank, chosen.at, chosen.source)
	}

	// Anthropic dimensions: the exhausted dimension (remaining 0) decides.
	var anthropic []resetCand
	anthropicRemaining := map[string]float64{}
	for _, dim := range []string{"requests", "tokens", "input-tokens", "output-tokens"} {
		name := "anthropic-ratelimit-" + dim + "-reset"
		raw, ok := headers[name]
		if !ok {
			continue
		}
		handled[name] = true
		at, ok := parseWhen(raw, now)
		if !ok {
			continue
		}
		if remRaw, ok := headers["anthropic-ratelimit-"+dim+"-remaining"]; ok {
			handled["anthropic-ratelimit-"+dim+"-remaining"] = true
			if rem, ok := parseDuration(remRaw); ok {
				anthropicRemaining[name] = rem
			}
		}
		anthropic = append(anthropic, resetCand{rank: 5, at: at, source: name})
	}
	if chosen, ok := pickReset(anthropic, anthropicRemaining); ok {
		add(chosen.rank, chosen.at, chosen.source)
	}
	if raw, ok := headers["anthropic-ratelimit-unified-reset"]; ok {
		handled["anthropic-ratelimit-unified-reset"] = true
		if at, ok := parseWhen(raw, now); ok {
			add(4, at, "anthropic-ratelimit-unified-reset")
		}
	}
	for _, name := range []string{"anthropic-ratelimit-unified-5h-reset", "anthropic-ratelimit-unified-7d-reset"} {
		if raw, ok := headers[name]; ok {
			handled[name] = true
			if at, ok := parseWhen(raw, now); ok {
				add(6, at, name)
			}
		}
	}

	// GitHub Copilot `x-usage-ratelimit-<scope>: rem=<pct>&rst=<ISO>`.
	var usage []resetCand
	for _, scope := range []string{"session", "weekly"} {
		name := "x-usage-ratelimit-" + scope
		raw, ok := headers[name]
		if !ok {
			continue
		}
		handled[name] = true
		fields := parseQuery(raw)
		at, okAt := parseWhen(fields["rst"], now)
		if okAt {
			if rem, ok := parseDuration(fields["rem"]); ok {
				remaining[name] = rem
			}
			usage = append(usage, resetCand{rank: 6, at: at, source: name})
		}
	}
	if chosen, ok := pickReset(usage, remaining); ok {
		add(chosen.rank, chosen.at, chosen.source)
	}

	// IETF RateLimit headers: each policy carries its own reset (t=/reset=) and
	// remaining (r=/remaining=), so an exhausted policy decides, like the other
	// dimensions.
	if raw, ok := headers["ratelimit"]; ok {
		handled["ratelimit"] = true
		var found []resetCand
		policyRemaining := map[string]float64{}
		for index, item := range splitRateLimit(raw) {
			seconds, remaining, ok := rateLimitPolicy(item)
			if !ok {
				continue
			}
			source := fmt.Sprintf("ratelimit#%d", index)
			if remaining != nil {
				policyRemaining[source] = *remaining
			}
			found = append(found, resetCand{rank: 7, at: now.Add(time.Duration(seconds * float64(time.Second))), source: source})
		}
		if chosen, ok := pickReset(found, policyRemaining); ok {
			add(7, chosen.at, "ratelimit")
		}
	}
	if raw, ok := headers["ratelimit-reset"]; ok {
		handled["ratelimit-reset"] = true
		if seconds, ok := parseDuration(raw); ok {
			add(7, now.Add(time.Duration(seconds*float64(time.Second))), "ratelimit-reset")
		}
	}
	for _, name := range []string{"reset_at", "x-ratelimit-reset"} {
		if raw, ok := headers[name]; ok {
			handled[name] = true
			if at, ok := parseWhen(raw, now); ok {
				add(8, at, name)
			}
		}
	}

	// JSON error body.
	body := errorBodyObject(text)
	err := errorObject(body)
	upstreamKind := bodyKind(err)
	bodyHandled := map[string]bool{"rate_limit_type": true}
	if err != nil {
		epochKeys := []string{"reset_at", "resets_at", "resetAt", "resetsAt"}
		msKeys := []string{"retry_after_ms", "retryAfterMs", "reset_after_ms", "resetAfterMs"}
		secKeys := []string{"reset_after_seconds", "retry_after", "retry_after_seconds",
			"resetAfterSeconds", "retryAfter", "retryAfterSeconds"}
		lookup := func(key string) (any, bool) {
			if v, ok := err[key]; ok {
				return v, true
			}
			if body != nil {
				if v, ok := body[key]; ok {
					return v, true
				}
			}
			return nil, false
		}
		for _, key := range epochKeys {
			if raw, ok := lookup(key); ok {
				bodyHandled[key] = true
				if at, ok := parseWhen(fmt.Sprint(raw), now); ok {
					add(2, at, key)
					cands[len(cands)-1].source = "upstream-body:" + key
				}
			}
		}
		for _, key := range msKeys {
			if raw, ok := lookup(key); ok {
				bodyHandled[key] = true
				if ms, ok := parseDuration(fmt.Sprint(raw)); ok && ms > 0 {
					cands = append(cands, resetCand{rank: 2, at: now.Add(time.Duration(ms * float64(time.Millisecond))), source: "upstream-body:" + key})
				}
			}
		}
		for _, key := range secKeys {
			if raw, ok := lookup(key); ok {
				bodyHandled[key] = true
				if seconds, ok := parseDuration(fmt.Sprint(raw)); ok && seconds > 0 {
					cands = append(cands, resetCand{rank: 2, at: now.Add(time.Duration(seconds * float64(time.Second))), source: "upstream-body:" + key})
				}
			}
		}
	}

	quotaText := strings.Contains(strings.ToLower(text), budgetExhaustedText) || status == 402
	oursKind := "rate-limit"
	if quotaText {
		oursKind = "quota"
	}
	kind := upstreamKind
	if kind == "" {
		kind = oursKind
	}

	sort.SliceStable(cands, func(i, j int) bool {
		if cands[i].rank != cands[j].rank {
			return cands[i].rank < cands[j].rank
		}
		return cands[i].at.Before(cands[j].at)
	})

	var (
		reset  time.Time
		source string
	)
	if len(cands) > 0 {
		reset, source = cands[0].at, cands[0].source
		if upstreamKind == "" && kind != "quota" && reset.Sub(now) > longWaitQuotaSeconds*time.Second {
			kind = "quota"
		}
	} else if kind == "quota" {
		reset, source = monthEnd(now, cfg.QuotaTZ), "estimate:next-month-utc"
	} else {
		reset, source = now.Add(time.Duration(cfg.DefaultRetry)*time.Second), "estimate:default"
	}

	passthrough := map[string]string{}
	if strings.HasPrefix(source, "upstream-") {
		for name, value := range headers {
			if name == "retry-after-ms" {
				passthrough[name] = strconv.Itoa(maxInt(1, int(math.Ceil(reset.Sub(now).Seconds()*1000))))
			} else if strings.HasPrefix(name, "x-ratelimit-") || strings.HasPrefix(name, "ratelimit") {
				passthrough[name] = value
			}
		}
	}

	return limitInfo{
		Reset:       reset,
		Monthly:     kind == "quota",
		Kind:        kind,
		Source:      source,
		Passthrough: passthrough,
	}
}

func remainingBySource(cands []resetCand, remaining map[string]float64) map[string]float64 {
	out := map[string]float64{}
	for _, c := range cands {
		if r, ok := remaining[c.source]; ok {
			out[c.source] = r
		}
	}
	return out
}

func parseQuery(raw string) map[string]string {
	out := map[string]string{}
	for _, part := range strings.Split(raw, "&") {
		k, v, ok := strings.Cut(part, "=")
		if ok {
			out[k] = v
		}
	}
	return out
}

func splitRateLimit(raw string) []string {
	return strings.Split(raw, ",")
}

func rateLimitPolicy(item string) (float64, *float64, bool) {
	var seconds float64
	var remaining *float64
	found := false
	for _, field := range strings.FieldsFunc(item, func(r rune) bool { return r == ';' || r == ',' || r == ' ' }) {
		key, value, ok := strings.Cut(field, "=")
		if !ok {
			continue
		}
		switch key {
		case "reset", "t":
			if v, err := strconv.ParseFloat(value, 64); err == nil {
				seconds, found = v, true
			}
		case "remaining", "r":
			if v, err := strconv.ParseFloat(value, 64); err == nil {
				remaining = &v
			}
		}
	}
	return seconds, remaining, found
}

func monthEnd(now time.Time, tz *time.Location) time.Time {
	local := now.In(tz)
	return time.Date(local.Year(), local.Month()+1, 1, 0, 0, 0, 0, tz)
}

func monthStart(now time.Time, tz *time.Location) time.Time {
	local := now.In(tz)
	return time.Date(local.Year(), local.Month(), 1, 0, 0, 0, 0, tz)
}

func formatWait(seconds int) string {
	hours := seconds / 3600
	rest := seconds % 3600
	minutes := rest / 60
	secs := rest % 60
	parts := make([]string, 0, 3)
	if hours > 0 {
		parts = append(parts, fmt.Sprintf("%dh", hours))
	}
	if minutes > 0 {
		parts = append(parts, fmt.Sprintf("%dm", minutes))
	}
	if secs > 0 {
		parts = append(parts, fmt.Sprintf("%ds", secs))
	}
	if len(parts) == 0 {
		return "0s"
	}
	return strings.Join(parts, " ")
}

// anthropicErrorBody is Anthropic's error envelope with type-first field
// order. The rewritten /v1/messages text is parsed by consumers (T3's
// ClaudeAdapterV2), and json.Marshal sorts map keys alphabetically, which
// silently broke that order — a map-built inner emitted
// {"error":{...},"type":"error"} where the reader expects
// {"type":"error","error":{...}}.
type anthropicErrorBody struct {
	Type  string               `json:"type"`
	Error anthropicErrorDetail `json:"error"`
}

type anthropicErrorDetail struct {
	Type    string `json:"type"`
	Message string `json:"message"`
}

// renderLimit builds the client-facing answer for a limit or outage, matching
// the shapes hosted_only_hooks.rewrite_limit writes per dialect.
func renderLimit(cfg *config, path, model string, info limitInfo, outageStatus int, now time.Time) (int, []byte, map[string]string) {
	seconds := maxInt(1, int(math.Ceil(info.Reset.Sub(now).Seconds())))
	headers := map[string]string{}
	reason := "Rate limit reached."
	switch {
	case info.Kind == "outage":
		reason = fmt.Sprintf("Upstream unavailable (%d); retrying later.", outageStatus)
	case info.Monthly:
		reason = "Monthly token budget exhausted."
	}

	if strings.Contains(path, "/v1/messages") {
		// Egress is a real 429, not the historical 503: Claude Code's main
		// loop honors retry-after on any retryable status and fails fast past
		// 60 s unless CLAUDE_CODE_RETRY_WATCHDOG is on (the launchers set it:
		// the client then waits out the reset in-process, up to 6 h), and its
		// SDK side-query retries rewrite a long-wait 429 themselves. T3's
		// adapter classifies api_error_status===429 as usage_limit and reads
		// the reset from the "(reset after ...)" suffix, status-based and
		// key-order-agnostic — unlike the old 503-text regex, which the
		// map-marshalled key order never matched. The "[429]" marker and the
		// reset suffix stay: llm-usage and T3's loose reset regex parse them.
		inner, _ := json.Marshal(anthropicErrorBody{"error", anthropicErrorDetail{"rate_limit_error", reason}})
		message := fmt.Sprintf("[%s] [429]: %s (reset after %s)", model, inner, formatWait(seconds))
		body, _ := json.Marshal(anthropicErrorBody{"error", anthropicErrorDetail{"api_error", message}})
		headers["retry-after"] = strconv.Itoa(seconds)
		// A month-end reset must not be waited out (the watchdog would stall
		// 6 h of it) and a wait past the knob is not worth a client retry;
		// x-should-retry:false stops both retry layers so the error reaches
		// T3 at once. Short rate-limit/outage waits stay retryable.
		if info.Monthly || seconds > cfg.ClientRetryMax {
			headers["x-should-retry"] = "false"
		}
		return http.StatusTooManyRequests, body, headers
	}

	if info.Monthly && strings.Contains(path, "/v1/chat/completions") {
		stamp := info.Reset.UTC().Format("2006-01-02T15:04:05Z")
		body, _ := json.Marshal(map[string]any{
			"error": map[string]any{
				"message": fmt.Sprintf("Monthly token budget exhausted. Quota resets %s.", stamp),
				"type":    "insufficient_quota",
				"code":    "402",
			},
		})
		return http.StatusPaymentRequired, body, headers
	}

	window := int(math.Ceil(float64(seconds) / 60))
	if info.Monthly {
		window = int(math.Round(monthEnd(now, cfg.QuotaTZ).Sub(monthStart(now, cfg.QuotaTZ)).Minutes()))
	}
	errObj := map[string]any{
		"message": fmt.Sprintf("%s Try again in %s.", reason, formatWait(seconds)),
		"type":    "usage_limit_reached",
		"code":    "429",
	}
	if strings.Contains(path, "/v1/responses") {
		errObj["resets_at"] = info.Reset.Unix()
	}
	body, _ := json.Marshal(map[string]any{"error": errObj})
	for k, v := range info.Passthrough {
		headers[k] = v
	}
	headers["retry-after"] = strconv.Itoa(seconds)
	headers["x-codex-primary-used-percent"] = "100"
	headers["x-codex-primary-window-minutes"] = strconv.Itoa(window)
	headers["x-codex-primary-reset-at"] = strconv.FormatInt(info.Reset.Unix(), 10)
	return http.StatusTooManyRequests, body, headers
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
