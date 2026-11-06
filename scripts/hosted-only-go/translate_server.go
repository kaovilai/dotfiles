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
func (a *app) streamTranslated(w http.ResponseWriter, resp *http.Response, tr translator, path string, data map[string]any, requested, served string, started time.Time, usedFallback bool, userAgent string) {
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

	// A failure after the 200 was sent must still reach the client: emit the
	// Anthropic mid-stream error event (the stream then ends without
	// message_stop, per the protocol) instead of a bare EOF.
	if readErr != nil && writeErr == nil {
		_ = emit("error", marshal(map[string]any{
			"type":  "error",
			"error": map[string]any{"type": "api_error", "message": readErr.Error()},
		}))
	}

	ok := readErr == nil && writeErr == nil
	status := http.StatusOK
	errText := ""
	if !ok {
		status = http.StatusBadGateway
		if writeErr != nil {
			status = 499 // client closed the stream; same convention as streamResponse
			errText = "client write failed: " + writeErr.Error()
		} else {
			errText = "upstream stream interrupted: " + readErr.Error()
		}
	}
	if ok {
		a.outages.success(served)
	}
	a.usage.write(a.buildEvent(path, data, requested, served, started, info, ok, status, 0, errText, false, 0, "", false, 0, usedFallback, true, served, firstChunk, userAgent))
}
