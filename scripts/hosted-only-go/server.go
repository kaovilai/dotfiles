package main

import (
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type app struct {
	cfg    *config
	client *http.Client
	usage  *usageLog
	seq    atomic.Uint64

	streakMu sync.Mutex
	streaks  map[string]outageStreak
}

type outageStreak struct {
	count int
	last  time.Time
}

func newApp(cfg *config) *app {
	return &app{
		cfg:     cfg,
		client:  &http.Client{Timeout: cfg.RequestTimeout},
		usage:   newUsageLog(cfg.UsageDir, cfg.Port),
		streaks: map[string]outageStreak{},
	}
}

func (a *app) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/health/liveliness" || r.URL.Path == "/health" {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
		return
	}
	if r.URL.Path == "/v1/models" && r.Method == http.MethodGet {
		if !a.authorized(r) {
			a.writeAuthError(w, r.URL.Path)
			return
		}
		a.writeModels(w)
		return
	}
	if !a.authorized(r) {
		a.writeAuthError(w, r.URL.Path)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if strings.HasSuffix(r.URL.Path, "/count_tokens") {
		a.handleCountTokens(w, r)
		return
	}

	started := time.Now()
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 256<<20))
	if err != nil {
		http.Error(w, "request body too large", http.StatusRequestEntityTooLarge)
		return
	}
	data, err := decodeObject(body)
	if err != nil {
		a.writeJSON(w, http.StatusBadRequest, map[string]any{
			"error": map[string]any{"message": "invalid JSON body", "type": "invalid_request_error"},
		}, nil)
		return
	}

	requested := asString(data["model"])
	requestID := fmt.Sprintf("%d-%d", started.UnixNano(), a.seq.Add(1))
	served := requested
	a.usage.start(requestID, served, requested)
	defer a.usage.end(requestID)

	fallback, reqErr := rewriteRequest(a.cfg, r.URL.Path, data)
	if reqErr != nil {
		a.writeRequestError(w, r.URL.Path, reqErr)
		a.usage.write(a.event(r, data, requested, served, started, usageInfo{}, false, reqErr.Status, 0, reqErr.Message, false, 0, "", false, 0, false, true, "", 0))
		return
	}
	served = asString(data["model"])

	stream := asBool(data["stream"]) || strings.Contains(r.Header.Get("Accept"), "text/event-stream")
	resp, transportErr := a.upstream(r, data, stream)
	usedFallback := false
	if fallback != "" && a.shouldFailover(resp, transportErr) {
		if resp != nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
		clone := cloneObject(data)
		clone["model"] = fallback
		resp, transportErr = a.upstream(r, clone, stream)
		usedFallback = true
		served = fallback
	}
	if transportErr != nil {
		status := http.StatusBadGateway
		msg := fmt.Sprintf("upstream request failed: %v", transportErr)
		a.writeDialectError(w, r.URL.Path, status, msg, "")
		a.usage.write(a.event(r, data, requested, served, started, usageInfo{}, false, status, 0, msg, false, 0, "", false, 0, usedFallback, stream, "", 0))
		return
	}
	defer resp.Body.Close()

	headers := normalizeHeaders(resp.Header)
	if resp.StatusCode >= 400 {
		errBody, _ := io.ReadAll(resp.Body)
		text := string(errBody)
		limit := isLimitError(resp.StatusCode, headers, text)
		outage := a.cfg.OutageRewrite && isOutageError(resp.StatusCode, text)
		if a.cfg.LimitRewrite && (limit || outage) {
			now := time.Now()
			var info limitInfo
			var outageStatus int
			if outage {
				outageStatus = resp.StatusCode
				info = limitInfo{
					Reset:   now.Add(time.Duration(a.outageWait(served, now)) * time.Second),
					Kind:    "outage",
					Source:  "estimate:outage",
					Monthly: false,
				}
			} else {
				info = analyzeLimit(a.cfg, resp.StatusCode, headers, text, now)
			}
			status, out, extra := renderLimit(a.cfg, r.URL.Path, served, info, outageStatus, now)
			for k, v := range extra {
				w.Header().Set(k, v)
			}
			a.writeJSON(w, status, nil, out)
			retryAfter := int(math.Ceil(info.Reset.Sub(now).Seconds()))
			if retryAfter < 1 {
				retryAfter = 1
			}
			a.usage.write(a.event(r, data, requested, served, started, usageInfo{}, false, status, resp.StatusCode, text, true, info.Reset.Unix(), info.Source, info.Monthly, retryAfter, usedFallback, stream, "", 0))
			return
		}
		a.writeRaw(w, resp.StatusCode, headers, errBody)
		a.usage.write(a.event(r, data, requested, served, started, usageInfo{}, false, resp.StatusCode, resp.StatusCode, text, false, 0, "", false, 0, usedFallback, stream, "", 0))
		return
	}

	if stream {
		a.streamResponse(w, resp, r.URL.Path, data, requested, served, started, usedFallback)
		return
	}

	respBody, _ := io.ReadAll(resp.Body)
	info := usageFromJSON(respBody)
	responseModel := ""
	if obj, err := decodeObject(respBody); err == nil {
		responseModel = asString(obj["model"])
	}
	a.writeRaw(w, resp.StatusCode, headers, respBody)
	a.usage.write(a.event(r, data, requested, served, started, info, true, http.StatusOK, 0, "", false, 0, "", false, 0, usedFallback, false, responseModel, 0))
}

func (a *app) authorized(r *http.Request) bool {
	token := a.cfg.Token
	check := func(got string) bool {
		return subtle.ConstantTimeCompare([]byte(got), []byte(token)) == 1
	}
	if auth := r.Header.Get("Authorization"); strings.HasPrefix(auth, "Bearer ") {
		if check(strings.TrimPrefix(auth, "Bearer ")) {
			return true
		}
	}
	return check(r.Header.Get("x-api-key"))
}

func (a *app) writeAuthError(w http.ResponseWriter, path string) {
	if strings.Contains(path, "/v1/messages") {
		a.writeJSON(w, http.StatusUnauthorized, map[string]any{
			"type":  "error",
			"error": map[string]any{"type": "authentication_error", "message": "invalid x-api-key"},
		}, nil)
		return
	}
	a.writeJSON(w, http.StatusUnauthorized, map[string]any{
		"error": map[string]any{"message": "invalid proxy token", "type": "authentication_error"},
	}, nil)
}

func (a *app) writeModels(w http.ResponseWriter) {
	ids := []string{a.cfg.GLM, a.cfg.DeepSeek}
	for alias := range a.cfg.Aliases {
		ids = append(ids, alias)
	}
	data := make([]any, 0, len(ids))
	for _, id := range ids {
		data = append(data, map[string]any{"id": id, "object": "model", "owned_by": "enmaas"})
	}
	a.writeJSON(w, http.StatusOK, map[string]any{"object": "list", "data": data}, nil)
}

func (a *app) handleCountTokens(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(http.MaxBytesReader(w, r.Body, 256<<20))
	data, err := decodeObject(body)
	if err != nil {
		a.writeJSON(w, http.StatusBadRequest, map[string]any{
			"type":  "error",
			"error": map[string]any{"type": "invalid_request_error", "message": "invalid JSON body"},
		}, nil)
		return
	}
	estimate := int(math.Ceil(float64(contentSize(data)) / a.cfg.BytesPerToken))
	a.writeJSON(w, http.StatusOK, map[string]any{"input_tokens": estimate}, nil)
}

// upstream sends the (already rewritten) body to EnMaaS using the dialect the
// path speaks.
func (a *app) upstream(r *http.Request, data map[string]any, stream bool) (*http.Response, error) {
	body := marshal(data)
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, a.cfg.BaseURL+r.URL.Path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if accept := r.Header.Get("Accept"); accept != "" {
		req.Header.Set("Accept", accept)
	} else if stream {
		req.Header.Set("Accept", "text/event-stream")
	}
	if isAnthropicPath(r.URL.Path) {
		req.Header.Set("x-api-key", a.cfg.APIKey)
		version := r.Header.Get("anthropic-version")
		if version == "" {
			version = "2023-06-01"
		}
		req.Header.Set("anthropic-version", version)
	} else {
		req.Header.Set("Authorization", "Bearer "+a.cfg.APIKey)
	}
	if beta := r.Header.Get("anthropic-beta"); beta != "" {
		req.Header.Set("anthropic-beta", beta)
	}
	return a.client.Do(req)
}

func isAnthropicPath(path string) bool {
	return strings.Contains(path, "/v1/messages")
}

func (a *app) shouldFailover(resp *http.Response, err error) bool {
	if err != nil {
		return true
	}
	switch resp.StatusCode {
	case 408, 429, 500, 502, 503, 504, 524:
		return true
	}
	return false
}

func (a *app) outageWait(model string, now time.Time) int {
	a.streakMu.Lock()
	defer a.streakMu.Unlock()
	streak := a.streaks[model]
	if now.Sub(streak.last) <= 15*time.Minute {
		streak.count++
	} else {
		streak.count = 1
	}
	streak.last = now
	a.streaks[model] = streak
	wait := 60 << (streak.count - 1)
	if wait > 600 {
		wait = 600
	}
	return wait
}

func (a *app) streamResponse(w http.ResponseWriter, resp *http.Response, path string, data map[string]any, requested, served string, started time.Time, usedFallback bool) {
	contentType := resp.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "text/event-stream"
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(resp.StatusCode)
	flusher, _ := w.(http.Flusher)

	parser := &sseUsage{}
	buf := make([]byte, 32*1024)
	var firstChunk int
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if firstChunk == 0 {
				firstChunk = int(time.Since(started).Milliseconds())
			}
			parser.feed(buf[:n])
			if _, werr := w.Write(buf[:n]); werr != nil {
				break
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err != nil {
			break
		}
	}
	a.usage.write(a.buildEvent(path, data, requested, served, started, parser.info, true, http.StatusOK, 0, "", false, 0, "", false, 0, usedFallback, true, parser.model, firstChunk, ""))
}

// eventHTTP exists because the stream callback no longer holds *http.Request.
func (a *app) eventHTTP(data map[string]any, requested, served string, started time.Time, info usageInfo, ok bool, status, upstreamStatus int, errText string, rewritten bool, resetAt int64, resetSource string, quota bool, retryAfter int, fallback, stream bool, responseModel string, ttft int) map[string]any {
	return a.buildEvent("", data, requested, served, started, info, ok, status, upstreamStatus, errText, rewritten, resetAt, resetSource, quota, retryAfter, fallback, stream, responseModel, ttft, "")
}

func (a *app) event(r *http.Request, data map[string]any, requested, served string, started time.Time, info usageInfo, ok bool, status, upstreamStatus int, errText string, rewritten bool, resetAt int64, resetSource string, quota bool, retryAfter int, fallback, stream bool, responseModel string, ttft int) map[string]any {
	return a.buildEvent(r.URL.Path, data, requested, served, started, info, ok, status, upstreamStatus, errText, rewritten, resetAt, resetSource, quota, retryAfter, fallback, stream, responseModel, ttft, r.Header.Get("User-Agent"))
}

func (a *app) buildEvent(path string, data map[string]any, requested, served string, started time.Time, info usageInfo, ok bool, status, upstreamStatus int, errText string, rewritten bool, resetAt int64, resetSource string, quota bool, retryAfter int, fallback, stream bool, responseModel string, ttft int, userAgent string) map[string]any {
	if path == "" {
		path = "/v1/chat/completions"
	}
	callType := "acompletion"
	provider := "openai"
	if isAnthropicPath(path) {
		callType = "anthropic_messages"
		provider = "anthropic"
	} else if strings.Contains(path, "/v1/responses") {
		callType = "aresponses"
	}
	host := ""
	if parsed, err := url.Parse(a.cfg.BaseURL); err == nil {
		host = parsed.Host
	}
	head := headText(data)
	thinking := ""
	if t := asMap(data["thinking"]); t != nil {
		thinking = asString(t["type"])
	}
	tools := 0
	if list, ok := data["tools"].([]any); ok {
		tools = len(list)
	}
	maxTokens := 0
	for _, key := range []string{"max_tokens", "max_output_tokens"} {
		if v, ok := asInt(data[key]); ok {
			maxTokens = v
			break
		}
	}
	var role any
	if strings.Contains(head, classifierMarker) {
		role = "classifier"
	}
	ev := map[string]any{
		"ts":             isoNow(time.Now()),
		"start":          isoNow(started),
		"call_type":      callType,
		"client":         clientFromUA(userAgent),
		"ua":             truncate(userAgent, 80),
		"requested":      requested,
		"served":         served,
		"response_model": nullIfEmpty(responseModel),
		"provider":       provider,
		"upstream":       host,
		"ok":             ok,
		"ms":             int(time.Since(started).Milliseconds()),
		"ttft_ms":        nullIfZero(ttft),
		"in":             info.In,
		"out":            info.Out,
		"cache_read":     info.CacheRead,
		"cache_write":    info.CacheWrite,
		"reasoning":      info.Reasoning,
		"stream":         stream,
		"tools":          tools,
		"max_tokens":     nullIfZero(maxTokens),
		"thinking":       nullIfEmpty(thinking),
		"role":           role,
		"fallback":       fallback,
		"status":         status,
	}
	if !ok {
		ev["error"] = truncate(errText, 300)
		ev["upstream_status"] = nullIfZero(upstreamStatus)
		ev["rewritten"] = rewritten
		ev["retry_after"] = nullIfZero(retryAfter)
		ev["reset_at"] = nullIfZero64(resetAt)
		ev["reset_source"] = nullIfEmpty(resetSource)
		if quota {
			ev["quota"] = true
		}
	}
	return ev
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func nullIfZero(v int) any {
	if v == 0 {
		return nil
	}
	return v
}

func nullIfZero64(v int64) any {
	if v == 0 {
		return nil
	}
	return v
}

func (a *app) writeRequestError(w http.ResponseWriter, path string, e *requestError) {
	msg := e.Message
	if isAnthropicPath(path) {
		a.writeJSON(w, e.Status, map[string]any{
			"type":  "error",
			"error": map[string]any{"type": "invalid_request_error", "message": msg},
		}, nil)
		return
	}
	a.writeJSON(w, e.Status, map[string]any{
		"error": map[string]any{"message": msg, "type": "invalid_request_error", "code": e.Code},
	}, nil)
}

func (a *app) writeDialectError(w http.ResponseWriter, path string, status int, message, code string) {
	if isAnthropicPath(path) {
		a.writeJSON(w, status, map[string]any{
			"type":  "error",
			"error": map[string]any{"type": "api_error", "message": message},
		}, nil)
		return
	}
	errObj := map[string]any{"message": message, "type": "api_error"}
	if code != "" {
		errObj["code"] = code
	}
	a.writeJSON(w, status, map[string]any{"error": errObj}, nil)
}

// writeJSON writes a JSON body, using raw when it is already encoded.
func (a *app) writeJSON(w http.ResponseWriter, status int, value any, raw []byte) {
	body := raw
	if body == nil {
		body = marshal(value)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func (a *app) writeRaw(w http.ResponseWriter, status int, headers map[string]string, body []byte) {
	for _, name := range []string{"content-type", "anthropic-version", "request-id", "x-request-id"} {
		if v, ok := headers[name]; ok {
			w.Header().Set(name, v)
		}
	}
	if w.Header().Get("Content-Type") == "" {
		w.Header().Set("Content-Type", "application/json")
	}
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

// sseUsage extracts token counts from a streaming response without buffering
// or altering it.
type sseUsage struct {
	buf   []byte
	info  usageInfo
	model string
}

func (p *sseUsage) feed(chunk []byte) {
	p.buf = append(p.buf, chunk...)
	for {
		idx := bytes.IndexByte(p.buf, '\n')
		if idx < 0 {
			break
		}
		line := strings.TrimSpace(string(p.buf[:idx]))
		p.buf = p.buf[idx+1:]
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		payload := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if payload == "" || payload == "[DONE]" {
			continue
		}
		var obj map[string]any
		if json.Unmarshal([]byte(payload), &obj) != nil {
			continue
		}
		p.consume(obj)
	}
	if len(p.buf) > 1<<20 {
		p.buf = p.buf[len(p.buf)-4096:]
	}
}

func (p *sseUsage) consume(obj map[string]any) {
	switch asString(obj["type"]) {
	case "message_start":
		if message := asMap(obj["message"]); message != nil {
			if model := asString(message["model"]); model != "" {
				p.model = model
			}
			p.merge(usageFromObject(message))
		}
	case "message_delta":
		if usage := asMap(obj["usage"]); usage != nil {
			if v, ok := asInt(usage["output_tokens"]); ok {
				p.info.Out = v
			}
		}
	case "response.completed":
		if response := asMap(obj["response"]); response != nil {
			if model := asString(response["model"]); model != "" {
				p.model = model
			}
			p.merge(usageFromObject(response))
		}
	default:
		if usage := asMap(obj["usage"]); usage != nil {
			if model := asString(obj["model"]); model != "" {
				p.model = model
			}
			p.merge(usageFromObject(obj))
		}
	}
}

func (p *sseUsage) merge(info usageInfo) {
	if info.In != 0 {
		p.info.In = info.In
	}
	if info.Out != 0 {
		p.info.Out = info.Out
	}
	if info.CacheRead != 0 {
		p.info.CacheRead = info.CacheRead
	}
	if info.CacheWrite != 0 {
		p.info.CacheWrite = info.CacheWrite
	}
	if info.Reasoning != 0 {
		p.info.Reasoning = info.Reasoning
	}
}
