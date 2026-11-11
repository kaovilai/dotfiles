package main

import (
	"fmt"
	"net/http"
	"time"
)

// streamTranslated relays an upstream chat/Responses SSE stream to a Messages
// client as Anthropic SSE (the translator does the conversion; this frames and
// flushes each event and records the same usage/latency event streamResponse
// does). Status 200 was already decided by the caller (errors are answered
// before streaming starts).
func (a *app) streamTranslated(w http.ResponseWriter, resp *http.Response, tr translator, path string, data map[string]any, requested, served string, started time.Time, usedFallback bool, fallbackReason string, userAgent string) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)

	var firstChunk int
	var writeErr error
	emit := func(event string, payload []byte) error {
		if firstChunk == 0 {
			firstChunk = int(time.Since(started).Milliseconds())
		}
		if _, err := fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, payload); err != nil {
			writeErr = err
			return err
		}
		if flusher != nil {
			flusher.Flush()
		}
		return nil
	}
	info, readErr := tr.Stream(resp.Body, emit, requested)

	ok := readErr == nil && writeErr == nil
	status := http.StatusOK
	errText := ""
	resetAt, resetSource, retryAfter := int64(0), "", 0
	if !ok {
		status = http.StatusBadGateway
		if writeErr != nil {
			status = 499 // client closed the stream; same convention as streamResponse
			errText = "client write failed: " + writeErr.Error()
		} else {
			// Headers are already out: the SSE error event is the retry channel.
			// rate_limit_error + the outage wait makes Claude Code retry the
			// turn instead of classifying a mid-stream cut as an unknown API
			// error (2026-11-11, GLM "Claude API unknown").
			now := time.Now()
			retryAfter = a.outages.wait(served, now)
			resetAt, resetSource = now.Add(time.Duration(retryAfter)*time.Second).Unix(), "estimate:stall"
			errText = fmt.Sprintf("upstream stream interrupted (retry after %ds): %v", retryAfter, readErr)
			message := readErr.Error()
			if retryAfter > 0 {
				message = fmt.Sprintf("%s (retry after %ds)", message, retryAfter)
			}
			_ = emit("error", marshal(map[string]any{
				"type":  "error",
				"error": map[string]any{"type": "rate_limit_error", "message": message},
			}))
		}
	}
	if ok {
		a.outages.success(served)
	}
	a.usage.write(a.buildEvent(path, data, requested, served, started, info, ok, status, 0, errText, !ok && readErr != nil, resetAt, resetSource, false, retryAfter, usedFallback, fallbackReason, true, served, firstChunk, userAgent))
}
