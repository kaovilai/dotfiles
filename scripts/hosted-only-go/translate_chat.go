package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"unicode/utf8"
)

// chatTranslator bridges Messages <-> OpenAI chat completions
// (POST /v1/chat/completions). One instance serves one request.
type chatTranslator struct{}

func newChatTranslator() translator { return &chatTranslator{} }

var errNotImplemented = errors.New("translator not implemented")

// chatStreamDone stops sseEvents once the upstream sent [DONE].
var chatStreamDone = errors.New("chat stream done")

var chatReasoningModel = regexp.MustCompile(`^o[0-9]`)

// chatUsesMaxCompletionTokens reports whether to send "max_completion_tokens"
// instead of "max_tokens". Verified live against the EnMaaS gateway
// (2026-11-07): gpt-6-sol rejects max_tokens ("Use 'max_completion_tokens'
// instead"), while gpt-4o-mini, gemini-3.x and gpt-5.x all accept
// max_completion_tokens, so it is the default. Only self-hosted "rits/"
// (vLLM) ids keep the classic max_tokens. A provider prefix such as "openai/"
// is ignored.
func chatUsesMaxCompletionTokens(model string) bool {
	m := strings.ToLower(model)
	if strings.HasPrefix(m, "rits/") {
		return false
	}
	return true
}

// Gemini 3 (via the OpenAI-compatible endpoint) returns a thought_signature on
// every tool call (extra_content.google.thought_signature) and rejects the next
// turn with 400 "Function call is missing a thought_signature" unless it is
// echoed back. A Messages tool_use block has no place for it, and Claude Code
// echoes only id/name/input, so it rides inside the tool_use id (the same trick
// LiteLLM uses): <call id>__thought__<base64url(signature)>. The request side
// splits it again; both the assistant tool_calls id and the matching tool
// message's tool_call_id carry the ORIGINAL id.
const chatThoughtSep = "__thought__"

// toolImageMarker labels tool_result images re-homed into the following user
// message (chat/Responses tool outputs take strings only), so the upstream
// model cannot read tool output — a screenshot, fetched web content — as
// user-provided intent.
const toolImageMarker = "[tool_result image follows; not user-provided]"

// chatEncodeToolID folds a tool call's thought signature (if any) into its id.
func chatEncodeToolID(id string, tc map[string]any) string {
	sig := asString(asMap(asMap(tc["extra_content"])["google"])["thought_signature"])
	if sig == "" {
		return id
	}
	return id + chatThoughtSep + base64.RawURLEncoding.EncodeToString([]byte(sig))
}

// chatSplitToolID undoes chatEncodeToolID: the original id and the signature
// ("" when the id carries none or it does not decode).
func chatSplitToolID(id string) (string, string) {
	i := strings.Index(id, chatThoughtSep)
	if i < 0 {
		return id, ""
	}
	raw, err := base64.RawURLEncoding.DecodeString(id[i+len(chatThoughtSep):])
	if err != nil {
		return id[:i], ""
	}
	return id[:i], string(raw)
}

// chatTemplateKwargs maps a Messages "thinking" setting onto the vLLM chat
// template switch (chat_template_kwargs.enable_thinking) that reasoning models
// such as DiffusionGemma/Gemma 4 read; nil when the model is not vLLM-hosted or
// the request does not say. Only self-hosted "rits/" ids get it: a hosted
// OpenAI-compatible API may reject an unknown request field, vLLM passes it to
// the template. budget_tokens has no vLLM equivalent and is dropped. These
// models call tools more reliably with thinking on, so a client that asks for
// it gets it.
func chatTemplateKwargs(model string, thinking map[string]any) map[string]any {
	if !strings.HasPrefix(strings.ToLower(model), "rits/") || thinking == nil {
		return nil
	}
	switch asString(thinking["type"]) {
	case "enabled", "adaptive":
		return map[string]any{"enable_thinking": true}
	case "disabled":
		return map[string]any{"enable_thinking": false}
	}
	return nil
}

func chatRandomID() string {
	var b [12]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "000000000000000000000000"
	}
	return hex.EncodeToString(b[:])
}

// ---------------------------------------------------------------- request

func (t *chatTranslator) Request(req map[string]any) (string, map[string]any, error) {
	if req == nil {
		return "", nil, errors.New("nil request")
	}
	out := map[string]any{}
	model := asString(req["model"])
	if model != "" {
		out["model"] = model
	}

	msgs := []any{}
	if sys := chatSystemText(req["system"]); sys != "" {
		msgs = append(msgs, map[string]any{"role": "system", "content": sys})
	}
	for _, m := range asList(req["messages"]) {
		msgs = chatAppendMessage(msgs, asMap(m))
	}
	out["messages"] = msgs

	tools := chatTools(req["tools"])
	if len(tools) > 0 {
		out["tools"] = tools
		tc := asMap(req["tool_choice"])
		switch asString(tc["type"]) {
		case "auto":
			out["tool_choice"] = "auto"
		case "any":
			out["tool_choice"] = "required"
		case "none":
			out["tool_choice"] = "none"
		case "tool":
			if name := asString(tc["name"]); name != "" {
				out["tool_choice"] = map[string]any{
					"type":     "function",
					"function": map[string]any{"name": name},
				}
			}
		}
		if asBool(tc["disable_parallel_tool_use"]) {
			out["parallel_tool_calls"] = false
		}
	}

	if v, ok := req["max_tokens"]; ok && v != nil {
		if chatUsesMaxCompletionTokens(model) {
			out["max_completion_tokens"] = v
		} else {
			out["max_tokens"] = v
		}
	}
	for _, k := range []string{"temperature", "top_p"} {
		if v, ok := req[k]; ok && v != nil {
			out[k] = v
		}
	}
	if stops := asList(req["stop_sequences"]); len(stops) > 0 {
		out["stop"] = stops
	}
	if uid := asString(asMap(req["metadata"])["user_id"]); uid != "" {
		out["user"] = uid
	}
	if kwargs := chatTemplateKwargs(model, asMap(req["thinking"])); kwargs != nil {
		out["chat_template_kwargs"] = kwargs
	}
	if asBool(req["stream"]) {
		out["stream"] = true
		out["stream_options"] = map[string]any{"include_usage": true}
	}
	return "/v1/chat/completions", out, nil
}

// chatSystemText flattens a Messages "system" value (string or text blocks).
func chatSystemText(v any) string {
	switch s := v.(type) {
	case string:
		return s
	case []any:
		var parts []string
		for _, b := range s {
			bm := asMap(b)
			if bm == nil {
				continue
			}
			if tx := asString(bm["text"]); tx != "" && (asString(bm["type"]) == "text" || bm["type"] == nil) {
				parts = append(parts, tx)
			}
		}
		return strings.Join(parts, "\n\n")
	}
	return ""
}

func chatTools(v any) []any {
	var out []any
	for _, e := range asList(v) {
		tm := asMap(e)
		if tm == nil {
			continue
		}
		if ty := asString(tm["type"]); ty != "" && ty != "custom" {
			continue // server tools (web_search_*, ...) have no chat equivalent
		}
		name := asString(tm["name"])
		if name == "" {
			continue
		}
		params := tm["input_schema"]
		if asMap(params) == nil {
			params = map[string]any{"type": "object", "properties": map[string]any{}}
		}
		fn := map[string]any{"name": name, "parameters": params}
		if d := asString(tm["description"]); d != "" {
			fn["description"] = d
		}
		out = append(out, map[string]any{"type": "function", "function": fn})
	}
	return out
}

func chatAppendMessage(msgs []any, m map[string]any) []any {
	if m == nil {
		return msgs
	}
	role := asString(m["role"])
	if role != "user" && role != "assistant" {
		return msgs
	}
	if s, ok := m["content"].(string); ok {
		return append(msgs, map[string]any{"role": role, "content": s})
	}
	blocks := asList(m["content"])
	if role == "assistant" {
		return chatAppendAssistant(msgs, blocks)
	}
	return chatAppendUser(msgs, blocks)
}

func chatAppendUser(msgs []any, blocks []any) []any {
	var tools []any
	var parts []any
	var texts []string
	hasImage := false
	for _, b := range blocks {
		bm := asMap(b)
		switch asString(bm["type"]) {
		case "tool_result":
			tools = append(tools, map[string]any{
				"role":         "tool",
				"tool_call_id": chatOrigToolID(asString(bm["tool_use_id"])),
				"content":      chatToolResultText(bm),
			})
			// A tool message takes string content only, so images ride the
			// user message that follows (vision models keep seeing them),
			// labeled so their provenance stays distinguishable.
			if imgs := chatToolResultImages(bm); len(imgs) > 0 {
				hasImage = true
				parts = append(parts, map[string]any{"type": "text", "text": toolImageMarker})
				parts = append(parts, imgs...)
			}
		case "text":
			tx := asString(bm["text"])
			texts = append(texts, tx)
			parts = append(parts, map[string]any{"type": "text", "text": tx})
		case "image":
			if url := chatImageURL(asMap(bm["source"])); url != "" {
				hasImage = true
				parts = append(parts, map[string]any{"type": "image_url", "image_url": map[string]any{"url": url}})
			}
		}
	}
	// tool messages must directly follow the assistant tool_calls message
	msgs = append(msgs, tools...)
	switch {
	case len(parts) == 0:
	case hasImage:
		msgs = append(msgs, map[string]any{"role": "user", "content": parts})
	default:
		msgs = append(msgs, map[string]any{"role": "user", "content": strings.Join(texts, "\n")})
	}
	return msgs
}

func chatImageURL(src map[string]any) string {
	switch asString(src["type"]) {
	case "base64":
		data := asString(src["data"])
		if data == "" {
			return ""
		}
		mt := asString(src["media_type"])
		if mt == "" {
			mt = "image/png"
		}
		return "data:" + mt + ";base64," + data
	case "url":
		return asString(src["url"])
	}
	return ""
}

func chatToolResultText(b map[string]any) string {
	var s string
	switch c := b["content"].(type) {
	case string:
		s = c
	case []any:
		parts := make([]string, 0, len(c))
		for _, e := range c {
			if em := asMap(e); em != nil && asString(em["type"]) == "text" {
				parts = append(parts, asString(em["text"]))
			}
		}
		s = strings.Join(parts, "\n")
	}
	if asBool(b["is_error"]) {
		s = "Error: " + s
	}
	return s
}

// chatToolResultImages extracts a tool_result's image blocks as chat
// image_url parts; they cannot stay in the tool message (string content
// only) and are appended to the turn's user message instead.
func chatToolResultImages(b map[string]any) []any {
	var out []any
	for _, e := range asList(b["content"]) {
		em := asMap(e)
		if em == nil || asString(em["type"]) != "image" {
			continue
		}
		if url := chatImageURL(asMap(em["source"])); url != "" {
			out = append(out, map[string]any{"type": "image_url", "image_url": map[string]any{"url": url}})
		}
	}
	return out
}

func chatAppendAssistant(msgs []any, blocks []any) []any {
	var texts []string
	var calls []any
	for _, b := range blocks {
		bm := asMap(b)
		switch asString(bm["type"]) {
		case "text":
			texts = append(texts, asString(bm["text"]))
		case "tool_use":
			args := "{}"
			if in := asMap(bm["input"]); in != nil {
				args = string(marshal(in))
			}
			origID, sig := chatSplitToolID(asString(bm["id"]))
			call := map[string]any{
				"id":   origID,
				"type": "function",
				"function": map[string]any{
					"name":      asString(bm["name"]),
					"arguments": args,
				},
			}
			if sig != "" {
				call["extra_content"] = map[string]any{"google": map[string]any{"thought_signature": sig}}
			}
			calls = append(calls, call)
		}
		// thinking / redacted_thinking and unknown blocks are dropped
	}
	if len(texts) == 0 && len(calls) == 0 {
		return msgs
	}
	msg := map[string]any{"role": "assistant", "content": strings.Join(texts, "\n")}
	if len(calls) > 0 {
		msg["tool_calls"] = calls
	}
	return append(msgs, msg)
}

// --------------------------------------------------------------- response

func chatStopReason(finish string) string {
	switch finish {
	case "length":
		return "max_tokens"
	case "tool_calls", "function_call":
		return "tool_use"
	}
	return "end_turn"
}

// chatUsage extracts Anthropic-semantics usage from a chat usage object.
func chatUsage(u map[string]any) usageInfo {
	if u == nil {
		return usageInfo{}
	}
	prompt, _ := asInt(u["prompt_tokens"])
	out, _ := asInt(u["completion_tokens"])
	cached, _ := asInt(asMap(u["prompt_tokens_details"])["cached_tokens"])
	reasoning, _ := asInt(asMap(u["completion_tokens_details"])["reasoning_tokens"])
	if cached < 0 {
		cached = 0
	}
	in := prompt - cached
	if in < 0 {
		in = 0
	}
	return usageInfo{In: in, Out: out, CacheRead: cached, Reasoning: reasoning}
}

func chatMessageID(upstream string) string {
	id := strings.TrimPrefix(upstream, "chatcmpl-")
	id = strings.TrimPrefix(id, "msg_")
	if id == "" {
		id = chatRandomID()
	}
	return "msg_" + id
}

// chatContentText returns message.content as text (string or text parts).
func chatContentText(v any) string {
	switch c := v.(type) {
	case string:
		return c
	case []any:
		var sb strings.Builder
		for _, p := range c {
			pm := asMap(p)
			if ty := asString(pm["type"]); ty == "text" || ty == "output_text" || ty == "" {
				sb.WriteString(asString(pm["text"]))
			}
		}
		return sb.String()
	}
	return ""
}

func (t *chatTranslator) Response(upstream []byte, model string) ([]byte, error) {
	root, err := decodeObject(upstream)
	if err != nil {
		return nil, fmt.Errorf("decode chat completion: %w", err)
	}
	choices := asList(root["choices"])
	if len(choices) == 0 {
		if e := asMap(root["error"]); e != nil {
			return nil, fmt.Errorf("upstream error: %s", asString(e["message"]))
		}
		return nil, errors.New("chat completion has no choices")
	}
	choice := asMap(choices[0])
	msg := asMap(choice["message"])

	content := []any{}
	if text := chatContentText(msg["content"]); text != "" {
		content = append(content, map[string]any{"type": "text", "text": text})
	}
	if ref := asString(msg["refusal"]); ref != "" {
		content = append(content, map[string]any{"type": "text", "text": ref})
	}
	hasTool := false
	for _, c := range asList(msg["tool_calls"]) {
		cm := asMap(c)
		if cm == nil {
			continue
		}
		fn := asMap(cm["function"])
		id := asString(cm["id"])
		if id == "" {
			id = "call_" + chatRandomID()
		}
		input := map[string]any{}
		if args := strings.TrimSpace(asString(fn["arguments"])); args != "" {
			if parsed, err := decodeObject([]byte(args)); err == nil && parsed != nil {
				input = parsed
			}
		}
		content = append(content, map[string]any{
			"type": "tool_use", "id": chatEncodeToolID(id, cm), "name": asString(fn["name"]), "input": input,
		})
		hasTool = true
	}
	if len(content) == 0 {
		content = append(content, map[string]any{"type": "text", "text": ""})
	}
	stop := chatStopReason(asString(choice["finish_reason"]))
	// A token-budget cutoff must win over tool_use: the call is truncated and
	// not executable, and the client retries only on max_tokens.
	if hasTool && stop != "max_tokens" {
		stop = "tool_use"
	}
	u := chatUsage(asMap(root["usage"]))
	return marshal(map[string]any{
		"id":            chatMessageID(asString(root["id"])),
		"type":          "message",
		"role":          "assistant",
		"model":         model,
		"content":       content,
		"stop_reason":   stop,
		"stop_sequence": nil,
		"usage": map[string]any{
			"input_tokens":            u.In,
			"output_tokens":           u.Out,
			"cache_read_input_tokens": u.CacheRead,
		},
	}), nil
}

// ----------------------------------------------------------------- stream

type chatBlock struct {
	index    int
	tool     bool
	id       string
	closed   bool
	hadDelta bool
}

type chatStream struct {
	emit    func(string, []byte) error
	model   string
	id      string
	started bool
	next    int
	text    *chatBlock
	blocks  []*chatBlock
	byIndex map[int]*chatBlock
	last    int
	finish  string
	usage   usageInfo
}

func (s *chatStream) send(event string, v map[string]any) error {
	return s.emit(event, marshal(v))
}

func (s *chatStream) start() error {
	if s.started {
		return nil
	}
	s.started = true
	return s.send("message_start", map[string]any{
		"type": "message_start",
		"message": map[string]any{
			"id": s.id, "type": "message", "role": "assistant", "model": s.model,
			"content": []any{}, "stop_reason": nil, "stop_sequence": nil,
			"usage": map[string]any{"input_tokens": 0, "output_tokens": 0},
		},
	})
}

func (s *chatStream) stop(b *chatBlock) error {
	if b.closed {
		return nil
	}
	b.closed = true
	if b.tool && !b.hadDelta {
		// a tool call with no argument fragments still needs valid JSON input
		b.hadDelta = true
		if err := s.send("content_block_delta", map[string]any{
			"type": "content_block_delta", "index": b.index,
			"delta": map[string]any{"type": "input_json_delta", "partial_json": "{}"},
		}); err != nil {
			return err
		}
	}
	return s.send("content_block_stop", map[string]any{"type": "content_block_stop", "index": b.index})
}

func (s *chatStream) newBlock(tool bool, cb map[string]any) (*chatBlock, error) {
	b := &chatBlock{index: s.next, tool: tool}
	s.next++
	s.blocks = append(s.blocks, b)
	return b, s.send("content_block_start", map[string]any{
		"type": "content_block_start", "index": b.index, "content_block": cb,
	})
}

func (s *chatStream) onText(text string) error {
	if text == "" {
		return nil
	}
	if s.text == nil || s.text.closed {
		b, err := s.newBlock(false, map[string]any{"type": "text", "text": ""})
		if err != nil {
			return err
		}
		s.text = b
	}
	return s.send("content_block_delta", map[string]any{
		"type": "content_block_delta", "index": s.text.index,
		"delta": map[string]any{"type": "text_delta", "text": text},
	})
}

func (s *chatStream) onToolCall(tc map[string]any) error {
	idx, ok := asInt(tc["index"])
	if !ok {
		idx = s.last
	}
	s.last = idx
	id := asString(tc["id"])
	fn := asMap(tc["function"])
	cur := s.byIndex[idx]
	// A new block starts for an unseen index, or when a different id shows up
	// at a known index (Gemini reports every parallel call at index 0).
	if cur == nil || (id != "" && cur.id != "" && id != cur.id) {
		if s.text != nil && !s.text.closed {
			if err := s.stop(s.text); err != nil {
				return err
			}
		}
		if id == "" {
			id = "call_" + chatRandomID()
		}
		b, err := s.newBlock(true, map[string]any{
			"type": "tool_use", "id": chatEncodeToolID(id, tc), "name": asString(fn["name"]), "input": map[string]any{},
		})
		if err != nil {
			return err
		}
		b.id = id
		s.byIndex[idx] = b
		cur = b
	} else if cur.id == "" && id != "" {
		cur.id = id
	}
	if frag := asString(fn["arguments"]); frag != "" {
		cur.hadDelta = true
		return s.send("content_block_delta", map[string]any{
			"type": "content_block_delta", "index": cur.index,
			"delta": map[string]any{"type": "input_json_delta", "partial_json": frag},
		})
	}
	return nil
}

func (s *chatStream) onChunk(data []byte) error {
	root, err := decodeObject(data)
	if err != nil || root == nil {
		return nil // tolerate junk lines
	}
	if id := asString(root["id"]); id != "" && !s.started {
		s.id = chatMessageID(id)
	}
	if s.model == "" {
		s.model = asString(root["model"])
	}
	if err := s.start(); err != nil {
		return err
	}
	if u := asMap(root["usage"]); u != nil {
		s.usage = chatUsage(u)
	}
	choices := asList(root["choices"])
	if len(choices) == 0 {
		// usage-only chunks are normal; an error object is not (upstreams send
		// {"error":{...}} as an SSE line instead of an HTTP status).
		if e := asMap(root["error"]); e != nil && e["message"] != nil {
			return fmt.Errorf("upstream stream error: %s", asString(e["message"]))
		}
		return nil
	}
	choice := asMap(choices[0])
	if fr := asString(choice["finish_reason"]); fr != "" {
		s.finish = fr
	}
	delta := asMap(choice["delta"])
	if delta == nil {
		return nil
	}
	// Reasoning is not forwarded (Messages thinking blocks need a signature the
	// upstream cannot supply), but a reasoning-only stretch must not look like a
	// stalled stream: a block-diffusion model denoises a whole 256-token canvas per
	// chunk and a long thinking phase is many such chunks with no visible output.
	// A Messages "ping" is the protocol's keepalive. "reasoning_content" is the
	// classic vLLM field, "reasoning" the newer one.
	if asString(delta["reasoning_content"]) != "" || asString(delta["reasoning"]) != "" {
		if err := s.send("ping", map[string]any{"type": "ping"}); err != nil {
			return err
		}
	}
	if err := s.onText(chatContentText(delta["content"])); err != nil {
		return err
	}
	if err := s.onText(asString(delta["refusal"])); err != nil {
		return err
	}
	for _, tc := range asList(delta["tool_calls"]) {
		if tm := asMap(tc); tm != nil {
			if err := s.onToolCall(tm); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *chatStream) closeAll() error {
	for _, b := range s.blocks {
		if err := s.stop(b); err != nil {
			return err
		}
	}
	return nil
}

func (s *chatStream) finishUp() error {
	if err := s.start(); err != nil {
		return err
	}
	hasTool := false
	for _, b := range s.blocks {
		if b.tool {
			hasTool = true
		}
	}
	if err := s.closeAll(); err != nil {
		return err
	}
	stop := chatStopReason(s.finish)
	if hasTool && stop != "max_tokens" {
		stop = "tool_use"
	}
	if err := s.send("message_delta", map[string]any{
		"type":  "message_delta",
		"delta": map[string]any{"stop_reason": stop, "stop_sequence": nil},
		"usage": map[string]any{
			"input_tokens":            s.usage.In,
			"output_tokens":           s.usage.Out,
			"cache_read_input_tokens": s.usage.CacheRead,
		},
	}); err != nil {
		return err
	}
	return s.send("message_stop", map[string]any{"type": "message_stop"})
}

func (t *chatTranslator) Stream(r io.Reader, emit func(string, []byte) error, model string) (usageInfo, error) {
	s := &chatStream{
		emit: emit, model: model, id: "msg_" + chatRandomID(),
		byIndex: map[int]*chatBlock{},
	}
	var emitErr error
	err := sseEvents(r, func(_ string, data []byte) error {
		d := strings.TrimSpace(string(data))
		if d == "[DONE]" {
			return chatStreamDone
		}
		if e := s.onChunk([]byte(d)); e != nil {
			emitErr = e
			return e
		}
		return nil
	})
	if emitErr != nil {
		return s.usage, emitErr
	}
	if err != nil && !errors.Is(err, chatStreamDone) {
		// read error: close what is open so the client sees well-formed
		// blocks, then surface the error to the caller.
		if s.started {
			_ = s.closeAll()
		}
		return s.usage, err
	}
	if e := s.finishUp(); e != nil {
		return s.usage, e
	}
	return s.usage, nil
}

// ------------------------------------------------------------------ error

func (t *chatTranslator) Error(status int, body []byte) []byte {
	msg := ""
	if root, err := decodeObject(body); err == nil && root != nil {
		switch e := root["error"].(type) {
		case map[string]any:
			msg = asString(e["message"])
		case string:
			msg = e
		}
		if msg == "" {
			msg = asString(root["message"])
		}
	}
	if msg == "" {
		msg = strings.TrimSpace(string(body))
	}
	if len(msg) > 2000 {
		cut := 2000
		for cut > 0 && !utf8.RuneStart(msg[cut]) {
			cut--
		}
		msg = msg[:cut]
	}
	if msg == "" {
		msg = fmt.Sprintf("upstream returned status %d (%s)", status, http.StatusText(status))
	}
	return marshal(map[string]any{
		"type":  "error",
		"error": map[string]any{"type": anthropicErrorType(status), "message": msg},
	})
}

// chatOrigToolID is chatSplitToolID without the signature.
func chatOrigToolID(id string) string {
	orig, _ := chatSplitToolID(id)
	return orig
}
