package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type app struct {
	cfg     *config
	client  *http.Client
	usage   *usageLog
	outages *outageTracker
	seq     atomic.Uint64

	// quotaUntil is the reset of the last monthly-quota answer per model id.
	// Quota is account-wide (token quota AND USD budget gate the same EnMaaS
	// account), so a fallback to the other model would only buy the same 429
	// plus latency until the reset.
	quotaMu    sync.Mutex
	quotaUntil map[string]time.Time
}

func (a *app) noteQuota(model string, reset time.Time) {
	a.quotaMu.Lock()
	defer a.quotaMu.Unlock()
	if a.quotaUntil == nil {
		a.quotaUntil = map[string]time.Time{}
	}
	a.quotaUntil[model] = reset
}

func (a *app) quotaActive(model string) bool {
	a.quotaMu.Lock()
	defer a.quotaMu.Unlock()
	until, ok := a.quotaUntil[model]
	return ok && until.After(time.Now())
}

type outageStreak struct {
	count int
	last  time.Time
}

func newApp(cfg *config) *app {
	// One transport for the process: keep-alive (and HTTP/2 where the gateway
	// offers it) is shared across requests instead of re-dialing per call.
	// DNS failures for the allow-listed gateway name fall back to DoH
	// (doh.go), mirroring dns_fallback.py on the LiteLLM path.
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.ForceAttemptHTTP2 = true
	transport.DialContext = dohDialContext(&net.Dialer{Timeout: 30 * time.Second}, newDoHResolver())
	return &app{
		cfg:     cfg,
		client:  &http.Client{Timeout: cfg.RequestTimeout, Transport: transport},
		usage:   newUsageLog(cfg.UsageDir, cfg.Port),
		outages: newOutageTracker(cfg.OutageState, cfg.OutageBase, cfg.OutageMax, time.Duration(cfg.OutageCoalesce*float64(time.Second))),
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

	fallback, reqErr, changed := rewriteRequest(a.cfg, r.URL.Path, data)
	if reqErr != nil {
		a.writeRequestError(w, r.URL.Path, reqErr)
		a.usage.write(a.event(r, data, requested, served, started, usageInfo{}, false, reqErr.Status, 0, reqErr.Message, false, 0, "", false, 0, false, true, "", 0))
		return
	}
	model := asString(data["model"])
	if fallback != "" && a.quotaActive(model) {
		fallback = ""
	}

	// EnMaaS flavor: the launcher's generated config.json decides the
	// deployment (dialect, api_base, #responses siblings). The hosted-only
	// flavors have no route table and are restricted to the two hosted models,
	// which is the cost guard.
	upstreamBase := a.cfg.BaseURL
	upstreamPath := r.URL.Path
	upstreamModel := model
	if a.cfg.Routes != nil {
		if strings.HasPrefix(model, "rits/") && flattenAdditionalTools(data) {
			changed = true
		}
		if !a.cfg.Routes.known(model, r.URL.Path) {
			a.rejectModel(w, r, data, requested, started, model)
			return
		}
		entry, upstream, path := a.cfg.Routes.resolve(model, r.URL.Path)
		if msg := dialectMismatch(r.URL.Path, entry.Dialect, model); msg != "" {
			a.rejectDialect(w, r, data, requested, started, model, msg)
			return
		}
		if upstream != model {
			data["model"] = upstream
			changed = true
		}
		if entry.Base != "" {
			upstreamBase = entry.Base
		}
		upstreamPath = path
		upstreamModel = upstream
	} else if !a.cfg.allowedModel(model) {
		a.rejectModel(w, r, data, requested, started, model)
		return
	}
	served = upstreamModel

	// Forward the original bytes when nothing changed: the enmaas path is
	// mostly pass-through, and re-marshaling a 1M-token prompt is pure CPU.
	outBody := body
	if changed {
		outBody = marshal(data)
	}

	stream := asBool(data["stream"]) || strings.Contains(r.Header.Get("Accept"), "text/event-stream")
	resp, transportErr := a.upstream(r, outBody, upstreamBase, upstreamPath, stream)
	usedFallback := false
	if fallback != "" && a.shouldFailover(resp, transportErr) && a.fallbackServable(fallback, r.URL.Path) {
		if resp != nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
		clone := cloneObject(data)
		clone["model"] = fallback
		fbBase, fbPath, fbModel := upstreamBase, upstreamPath, fallback
		if a.cfg.Routes != nil {
			entry, upstream, path := a.cfg.Routes.resolve(fallback, r.URL.Path)
			if upstream != fallback {
				clone["model"] = upstream
			}
			fbModel = upstream
			if entry.Base != "" {
				fbBase = entry.Base
			}
			fbPath = path
		}
		resp, transportErr = a.upstream(r, marshal(clone), fbBase, fbPath, stream)
		usedFallback = true
		served = fbModel
	}
	if transportErr != nil {
		if errors.Is(transportErr, context.Canceled) {
			return // the client went away; nothing to answer
		}
		if a.cfg.OutageRewrite {
			now := time.Now()
			info := limitInfo{
				Reset:  now.Add(time.Duration(a.outageWait(served, now)) * time.Second),
				Kind:   "outage",
				Source: "estimate:outage",
			}
			status, out, extra := renderLimit(a.cfg, r.URL.Path, served, info, http.StatusBadGateway, now)
			for k, v := range extra {
				w.Header().Set(k, v)
			}
			a.writeJSON(w, status, nil, out)
			retryAfter := maxInt(1, int(math.Ceil(info.Reset.Sub(now).Seconds())))
			a.usage.write(a.event(r, data, requested, served, started, usageInfo{}, false, status, http.StatusBadGateway, transportErr.Error(), true, info.Reset.Unix(), info.Source, false, retryAfter, usedFallback, stream, "", 0))
			return
		}
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
		// Either knob is enough: LIMIT_REWRITE=0 must not silence the outage
		// rewrite (502/504/connect failures would reach the client unwritten).
		if (a.cfg.LimitRewrite && limit) || outage {
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
				if info.Monthly {
					a.noteQuota(model, info.Reset)
				}
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
		a.streamResponse(w, resp, r.URL.Path, data, requested, served, started, usedFallback, r.Header.Get("User-Agent"))
		return
	}

	respBody, readErr := io.ReadAll(resp.Body)
	info := usageFromJSON(respBody)
	responseModel := ""
	if obj, err := decodeObject(respBody); err == nil {
		responseModel = asString(obj["model"])
	}
	if resp.StatusCode < 400 && readErr == nil {
		a.outages.success(served)
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
	var ids []string
	if a.cfg.Routes != nil {
		ids = append(ids, a.cfg.Routes.modelNames()...)
	} else {
		ids = append(ids, a.cfg.GLM, a.cfg.DeepSeek)
		for alias := range a.cfg.Aliases {
			ids = append(ids, alias)
		}
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

// upstream sends the (already rewritten) body to the deployment the route table
// chose, using the dialect that deployment speaks.
func (a *app) upstream(r *http.Request, body []byte, base, path string, stream bool) (*http.Response, error) {
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, joinURL(base, path), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if accept := r.Header.Get("Accept"); accept != "" {
		req.Header.Set("Accept", accept)
	} else if stream {
		req.Header.Set("Accept", "text/event-stream")
	}
	if isAnthropicPath(path) {
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

// joinURL appends an API path to a deployment base. EnMaaS openai deployments
// carry "/v1" in api_base while the path starts with "/v1/", so that prefix is
// dropped rather than doubled.
func joinURL(base, path string) string {
	base = strings.TrimRight(base, "/")
	if strings.HasSuffix(base, "/v1") && strings.HasPrefix(path, "/v1/") {
		path = strings.TrimPrefix(path, "/v1")
	}
	return base + path
}

func (a *app) shouldFailover(resp *http.Response, err error) bool {
	if err != nil {
		return true
	}
	switch resp.StatusCode {
	case 408, 429, 500, 502, 503, 504, 524, 529:
		return true
	}
	return false
}

func (a *app) outageWait(model string, now time.Time) int {
	return a.outages.wait(model, now)
}

// fallbackServable reports whether the fallback model can answer THIS client
// on THIS endpoint: it must be a known route and speak a dialect the proxy can
// forward without translating. The generated hosted-only routes always do (both
// models are Anthropic-dialect natively), but an explicit dialect override
// (CLAUDE_ENMAAS_MODEL_DIALECTS) can give the two models different dialects;
// forwarding then would send a Messages body to a chat endpoint on a failure
// path. Not servable means no fallback: the original failure is returned.
func (a *app) fallbackServable(fallback, path string) bool {
	if a.cfg.Routes == nil {
		return true
	}
	if !a.cfg.Routes.known(fallback, path) {
		return false
	}
	entry, _, _ := a.cfg.Routes.resolve(fallback, path)
	return dialectMismatch(path, entry.Dialect, fallback) == ""
}

// dialectMismatch is non-empty when the client speaks a different protocol
// family than the deployment, which this proxy cannot bridge: it forwards
// bodies, it does not translate them. LiteLLM converts Messages <-> Chat <->
// Responses (tools and streaming included); forwarding a Messages body to a
// chat endpoint, or handing a chat answer back to a Messages client, produces
// an answer the client cannot parse. Fail with an actionable 400 instead.
func dialectMismatch(clientPath, deployment, model string) string {
	messages := strings.Contains(clientPath, "/v1/messages")
	chat := strings.Contains(clientPath, "/v1/chat/completions")
	switch {
	case chat && deployment == "responses":
		return fmt.Sprintf("model %s is served over the Responses dialect and this proxy does not translate chat requests to it; "+
			"set CLAUDE_ENMAAS_PROXY_IMPL=litellm (or LLM_PROXY_IMPL=litellm) to use the LiteLLM proxy, which does", model)
	case messages && deployment != "anthropic":
		return fmt.Sprintf("model %s is served over the %s dialect and this proxy does not translate Messages requests to it; "+
			"set CLAUDE_ENMAAS_PROXY_IMPL=litellm (or LLM_PROXY_IMPL=litellm) to use the LiteLLM proxy, which does", model, deployment)
	case !messages && deployment == "anthropic":
		return fmt.Sprintf("model %s is served over the Anthropic dialect and this proxy does not translate chat/Responses requests to it; "+
			"set CLAUDE_ENMAAS_PROXY_IMPL=litellm (or LLM_PROXY_IMPL=litellm) to use the LiteLLM proxy, which does", model)
	}
	return ""
}

func (a *app) rejectDialect(w http.ResponseWriter, r *http.Request, data map[string]any, requested string, started time.Time, model, message string) {
	e := &requestError{Status: http.StatusBadRequest, Code: "invalid_request_error", Message: message}
	a.writeRequestError(w, r.URL.Path, e)
	a.usage.write(a.event(r, data, requested, model, started, usageInfo{}, false, e.Status, 0, e.Message, false, 0, "", false, 0, false, true, "", 0))
}

func (a *app) rejectModel(w http.ResponseWriter, r *http.Request, data map[string]any, requested string, started time.Time, model string) {
	e := &requestError{
		Status:  http.StatusBadRequest,
		Code:    "invalid_request_error",
		Message: "Invalid model name passed in model=" + model,
	}
	a.writeRequestError(w, r.URL.Path, e)
	a.usage.write(a.event(r, data, requested, model, started, usageInfo{}, false, e.Status, 0, e.Message, false, 0, "", false, 0, false, true, "", 0))
}

func (a *app) streamResponse(w http.ResponseWriter, resp *http.Response, path string, data map[string]any, requested, served string, started time.Time, usedFallback bool, userAgent string) {
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
	var readErr, writeErr error
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if firstChunk == 0 {
				firstChunk = int(time.Since(started).Milliseconds())
			}
			parser.feed(buf[:n])
			if _, werr := w.Write(buf[:n]); werr != nil {
				writeErr = werr
				break
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err != nil {
			if err != io.EOF {
				readErr = err
			}
			break
		}
	}
	ok := readErr == nil && writeErr == nil
	status := http.StatusOK
	errText := ""
	if !ok {
		status = http.StatusBadGateway
		if writeErr != nil {
			status = 499 // client closed the stream; same convention as nginx
			errText = "client write failed: " + writeErr.Error()
		} else {
			errText = "upstream stream interrupted: " + readErr.Error()
		}
	}
	if ok {
		a.outages.success(served)
	}
	a.usage.write(a.buildEvent(path, data, requested, served, started, parser.info, ok, status, 0, errText, false, 0, "", false, 0, usedFallback, true, parser.model, firstChunk, userAgent))
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
