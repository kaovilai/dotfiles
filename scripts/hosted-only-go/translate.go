package main

import (
	"io"
	"strings"
)

// translator bridges a /v1/messages (Anthropic) client to a deployment that
// speaks OpenAI chat completions or the Responses API. Claude Code always sends
// Messages, but the EnMaaS gateway serves GPT/Gemini models over the other two
// dialects, and LiteLLM used to convert between them (tools and streaming
// included). The Go proxy forwards bodies; this is the conversion layer that
// lets it default for the EnMaaS flavor too (kaovilai/dotfiles issue 602).
//
// One translator instance serves ONE request: it may keep per-request state
// (tool-call index maps, block counters, accumulated usage) between Request
// and Response/Stream/Error. Implementations live in translate_chat.go and
// translate_responses.go; both must be pure stdlib, concurrency-free per
// instance, and never panic on malformed upstream input (return an error).
type translator interface {
	// Request converts the client's Messages request object into the upstream
	// request object and returns the API path to POST ("/v1/chat/completions" or
	// "/v1/responses"). It must not mutate req. stream follows req["stream"].
	Request(req map[string]any) (path string, out map[string]any, err error)

	// Response converts a COMPLETE upstream JSON answer (non-stream) into the
	// Messages answer body. model is the model id the client asked for; use it
	// as the answer's "model" so the client sees the id it requested.
	Response(upstream []byte, model string) ([]byte, error)

	// Stream converts the upstream SSE stream r into Anthropic SSE events, one
	// emit call per event (event name + JSON data; the caller frames and
	// flushes). It must emit message_start first, close every content block it
	// opened, and finish with message_delta (stop_reason + usage) then
	// message_stop, even if the upstream ends without a terminal marker. It
	// returns the usage it observed. An upstream read error is returned after
	// the already-translated events were emitted.
	Stream(r io.Reader, emit func(event string, data []byte) error, model string) (usageInfo, error)

	// Error converts an upstream error body (status >= 400) into an Anthropic
	// error body {"type":"error","error":{"type":...,"message":...}}. The type is
	// derived from status (400 invalid_request_error, 401 authentication_error,
	// 403 permission_error, 404 not_found_error, 413 request_too_large,
	// 429 rate_limit_error, 5xx api_error, 529 overloaded_error).
	Error(status int, body []byte) []byte
}

// translatable reports whether a client on clientPath can be bridged to a
// deployment of the given dialect ("openai" = chat completions, "responses").
// Only Messages clients are bridged; the reverse directions stay rejected.
func translatable(clientPath, deployment string) bool {
	if !strings.Contains(clientPath, "/v1/messages") {
		return false
	}
	return deployment == "openai" || deployment == "responses"
}

// newTranslator returns a fresh per-request translator, or nil when the
// dialect has none.
func newTranslator(dialect string) translator {
	switch dialect {
	case "openai":
		return newChatTranslator()
	case "responses":
		return newResponsesTranslator()
	}
	return nil
}

// anthropicErrorType maps an HTTP status to the Anthropic error type string.
func anthropicErrorType(status int) string {
	switch {
	case status == 400:
		return "invalid_request_error"
	case status == 401:
		return "authentication_error"
	case status == 403:
		return "permission_error"
	case status == 404:
		return "not_found_error"
	case status == 413:
		return "request_too_large"
	case status == 429:
		return "rate_limit_error"
	case status == 529:
		return "overloaded_error"
	case status >= 500:
		return "api_error"
	}
	return "invalid_request_error"
}
