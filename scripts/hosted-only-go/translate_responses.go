package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"strconv"
	"strings"
	"unicode/utf8"
)

// responsesTranslator bridges Messages <-> the OpenAI Responses API
// (POST /v1/responses). One instance serves one request.
type responsesTranslator struct{}

func newResponsesTranslator() translator { return &responsesTranslator{} }

const (
	responsesPath         = "/v1/responses"
	responsesImageOmitted = "[image omitted]"
	responsesErrMaxBytes  = 2000
)

// ---------------------------------------------------------------- request

func (t *responsesTranslator) Request(req map[string]any) (string, map[string]any, error) {
	if req == nil {
		return "", nil, fmt.Errorf("responses: nil request")
	}
	out := map[string]any{"store": false}
	if m := asString(req["model"]); m != "" {
		out["model"] = m
	}
	if instr := respSystemText(req["system"]); instr != "" {
		out["instructions"] = instr
	}
	out["input"] = respInputItems(asList(req["messages"]))

	tools := respTools(asList(req["tools"]))
	if len(tools) > 0 {
		out["tools"] = tools
		if choice, parallelOff := respToolChoice(req["tool_choice"]); choice != nil {
			out["tool_choice"] = choice
			if parallelOff {
				out["parallel_tool_calls"] = false
			}
		}
	}
	if v, ok := req["max_tokens"]; ok && v != nil {
		// The Responses API rejects max_output_tokens below 16 (Claude Code sends
		// max_tokens:1 for its quota and title probes); LiteLLM's bridge raised it
		// the same way.
		if n, isInt := asInt(v); isInt && n < 16 {
			v = 16
		}
		out["max_output_tokens"] = v
	}
	for _, k := range []string{"temperature", "top_p"} {
		if v, ok := req[k]; ok && v != nil {
			out[k] = v
		}
	}
	if asBool(req["stream"]) {
		out["stream"] = true
	}
	return responsesPath, out, nil
}

// respSystemText flattens a Messages "system" (string or text blocks).
func respSystemText(v any) string {
	switch s := v.(type) {
	case string:
		return s
	case []any:
		var parts []string
		for _, b := range s {
			if bm := asMap(b); bm != nil && asString(bm["type"]) == "text" {
				if txt := asString(bm["text"]); txt != "" {
					parts = append(parts, txt)
				}
			}
		}
		return strings.Join(parts, "\n\n")
	}
	return ""
}

func respMessageItem(role string, parts []any) map[string]any {
	return map[string]any{"type": "message", "role": role, "content": parts}
}

func respInputItems(messages []any) []any {
	items := []any{}
	for _, raw := range messages {
		m := asMap(raw)
		if m == nil {
			continue
		}
		switch asString(m["role"]) {
		case "user":
			items = respAppendUser(items, m["content"])
		case "assistant":
			items = respAppendAssistant(items, m["content"])
		}
	}
	return items
}

func respAppendUser(items []any, content any) []any {
	if s, ok := content.(string); ok {
		if s == "" {
			return items
		}
		return append(items, respMessageItem("user", []any{
			map[string]any{"type": "input_text", "text": s}}))
	}
	var parts []any
	for _, raw := range asList(content) {
		b := asMap(raw)
		if b == nil {
			continue
		}
		switch asString(b["type"]) {
		case "text":
			if txt := asString(b["text"]); txt != "" {
				parts = append(parts, map[string]any{"type": "input_text", "text": txt})
			}
		case "image":
			if url := respImageURL(asMap(b["source"])); url != "" {
				parts = append(parts, map[string]any{"type": "input_image", "image_url": url})
			}
		case "tool_result":
			// function_call_output items precede the turn's remaining message.
			items = append(items, map[string]any{
				"type":    "function_call_output",
				"call_id": asString(b["tool_use_id"]),
				"output":  respToolResultOutput(b),
			})
		}
	}
	if len(parts) > 0 {
		items = append(items, respMessageItem("user", parts))
	}
	return items
}

func respImageURL(src map[string]any) string {
	if src == nil {
		return ""
	}
	switch asString(src["type"]) {
	case "base64":
		data := asString(src["data"])
		if data == "" {
			return ""
		}
		mt := asString(src["media_type"])
		if mt == "" {
			mt = "application/octet-stream"
		}
		return "data:" + mt + ";base64," + data
	case "url":
		return asString(src["url"])
	}
	return ""
}

func respToolResultOutput(b map[string]any) string {
	var out string
	switch c := b["content"].(type) {
	case string:
		out = c
	case []any:
		var parts []string
		for _, raw := range c {
			cm := asMap(raw)
			if cm != nil && asString(cm["type"]) == "text" {
				parts = append(parts, asString(cm["text"]))
			} else {
				parts = append(parts, responsesImageOmitted)
			}
		}
		out = strings.Join(parts, "\n")
	}
	if asBool(b["is_error"]) {
		out = "Error: " + out
	}
	return out
}

func respAppendAssistant(items []any, content any) []any {
	if s, ok := content.(string); ok {
		if s == "" {
			return items
		}
		return append(items, respMessageItem("assistant", []any{
			map[string]any{"type": "output_text", "text": s}}))
	}
	var parts []any
	flush := func() {
		if len(parts) > 0 {
			items = append(items, respMessageItem("assistant", parts))
			parts = nil
		}
	}
	for _, raw := range asList(content) {
		b := asMap(raw)
		if b == nil {
			continue
		}
		switch asString(b["type"]) {
		case "text":
			if txt := asString(b["text"]); txt != "" {
				parts = append(parts, map[string]any{"type": "output_text", "text": txt})
			}
		case "tool_use":
			flush()
			args := "{}"
			if in := b["input"]; in != nil {
				if enc := string(marshal(in)); enc != "null" {
					args = enc
				}
			}
			items = append(items, map[string]any{
				"type":      "function_call",
				"call_id":   asString(b["id"]),
				"name":      asString(b["name"]),
				"arguments": args,
			})
		}
		// thinking / redacted_thinking and anything else: dropped.
	}
	flush()
	return items
}

func respTools(raw []any) []any {
	var tools []any
	for _, r := range raw {
		t := asMap(r)
		if t == nil {
			continue
		}
		if typ := asString(t["type"]); typ != "" && typ != "custom" {
			continue // server tools have no Responses equivalent
		}
		name := asString(t["name"])
		if name == "" {
			continue
		}
		schema := asMap(t["input_schema"])
		if schema == nil {
			schema = map[string]any{"type": "object", "properties": map[string]any{}}
		}
		fn := map[string]any{
			"type":       "function",
			"name":       name,
			"parameters": schema,
			"strict":     false,
		}
		if d := asString(t["description"]); d != "" {
			fn["description"] = d
		}
		tools = append(tools, fn)
	}
	return tools
}

// respToolChoice maps Messages tool_choice; the bool is disable_parallel_tool_use.
func respToolChoice(v any) (any, bool) {
	tc := asMap(v)
	if tc == nil {
		return nil, false
	}
	parallelOff := asBool(tc["disable_parallel_tool_use"])
	switch asString(tc["type"]) {
	case "auto":
		return "auto", parallelOff
	case "any":
		return "required", parallelOff
	case "none":
		return "none", false
	case "tool":
		if name := asString(tc["name"]); name != "" {
			return map[string]any{"type": "function", "name": name}, parallelOff
		}
		return "required", parallelOff
	}
	return nil, parallelOff
}

// -------------------------------------------------------------- response

func respRandomID() string {
	var b [12]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func respMessageID(upstreamID string) string {
	if upstreamID == "" {
		return "msg_" + respRandomID()
	}
	return "msg_" + upstreamID
}

// respStopReason maps Responses termination info to a Messages stop_reason.
func respStopReason(hadTool bool, status, reason string) string {
	if hadTool {
		return "tool_use"
	}
	if status == "incomplete" && reason == "max_output_tokens" {
		return "max_tokens"
	}
	return "end_turn"
}

func respParseArgs(v any) any {
	switch a := v.(type) {
	case map[string]any:
		return a
	case string:
		if m, err := decodeObject([]byte(a)); err == nil && m != nil {
			return m
		}
	}
	return map[string]any{}
}

func respUsageMap(u usageInfo) map[string]any {
	return map[string]any{
		"input_tokens":            u.In,
		"output_tokens":           u.Out,
		"cache_read_input_tokens": u.CacheRead,
	}
}

func respErrorMessage(m map[string]any) string {
	if m == nil {
		return ""
	}
	if e := asMap(m["error"]); e != nil {
		if s := asString(e["message"]); s != "" {
			return s
		}
	}
	if s := asString(m["error"]); s != "" {
		return s
	}
	return asString(m["message"])
}

func (t *responsesTranslator) Response(upstream []byte, model string) ([]byte, error) {
	resp, err := decodeObject(upstream)
	if err != nil {
		return nil, fmt.Errorf("responses: decode upstream: %w", err)
	}
	if resp == nil {
		return nil, fmt.Errorf("responses: empty upstream body")
	}
	if asString(resp["status"]) == "failed" || (resp["error"] != nil && resp["output"] == nil) {
		msg := respErrorMessage(resp)
		if msg == "" {
			msg = respErrorMessage(map[string]any{"error": resp["error"]})
		}
		if msg == "" {
			msg = "upstream response failed"
		}
		return nil, fmt.Errorf("responses: %s", msg)
	}

	content := []any{}
	hadTool := false
	for _, raw := range asList(resp["output"]) {
		item := asMap(raw)
		if item == nil {
			continue
		}
		switch asString(item["type"]) {
		case "message":
			var sb strings.Builder
			for _, p := range asList(item["content"]) {
				if pm := asMap(p); pm != nil && asString(pm["type"]) == "output_text" {
					sb.WriteString(asString(pm["text"]))
				}
			}
			if sb.Len() > 0 {
				content = append(content, map[string]any{"type": "text", "text": sb.String()})
			}
		case "function_call":
			id := asString(item["call_id"])
			if id == "" {
				id = asString(item["id"])
			}
			hadTool = true
			content = append(content, map[string]any{
				"type":  "tool_use",
				"id":    id,
				"name":  asString(item["name"]),
				"input": respParseArgs(item["arguments"]),
			})
		}
	}
	if len(content) == 0 {
		content = append(content, map[string]any{"type": "text", "text": ""})
	}
	reason := ""
	if d := asMap(resp["incomplete_details"]); d != nil {
		reason = asString(d["reason"])
	}
	usage := usageFromObject(map[string]any{"usage": resp["usage"]})
	return marshal(map[string]any{
		"id":            respMessageID(asString(resp["id"])),
		"type":          "message",
		"role":          "assistant",
		"model":         model,
		"content":       content,
		"stop_reason":   respStopReason(hadTool, asString(resp["status"]), reason),
		"stop_sequence": nil,
		"usage":         respUsageMap(usage),
	}), nil
}

// ---------------------------------------------------------------- stream

type respBlock struct {
	idx     int
	started bool
	open    bool
}

type respCall struct {
	itemID, callID, name string
	blk                  *respBlock
	sawDelta             bool
	done                 bool
}

type respStream struct {
	emit     func(string, []byte) error
	model    string
	id       string
	started  bool
	finished bool
	next     int
	cur      *respBlock
	texts    map[string]*respBlock
	calls    map[string]*respCall
	hadTool  bool
	usage    usageInfo
}

func (s *respStream) send(typ string, payload map[string]any) error {
	payload["type"] = typ
	return s.emit(typ, marshal(payload))
}

func (s *respStream) start() error {
	if s.started {
		return nil
	}
	s.started = true
	return s.send("message_start", map[string]any{"message": map[string]any{
		"id":            respMessageID(s.id),
		"type":          "message",
		"role":          "assistant",
		"model":         s.model,
		"content":       []any{},
		"stop_reason":   nil,
		"stop_sequence": nil,
		"usage":         map[string]any{"input_tokens": 0, "output_tokens": 0},
	}})
}

func (s *respStream) closeCur() error {
	b := s.cur
	if b == nil {
		return nil
	}
	s.cur = nil
	if !b.open {
		return nil
	}
	b.open = false
	return s.send("content_block_stop", map[string]any{"index": b.idx})
}

func (s *respStream) begin(b *respBlock, block map[string]any) error {
	if err := s.start(); err != nil {
		return err
	}
	if err := s.closeCur(); err != nil {
		return err
	}
	b.idx = s.next
	s.next++
	b.started, b.open = true, true
	s.cur = b
	return s.send("content_block_start", map[string]any{"index": b.idx, "content_block": block})
}

func (s *respStream) delta(b *respBlock, delta map[string]any) error {
	return s.send("content_block_delta", map[string]any{"index": b.idx, "delta": delta})
}

// respEventKeys returns the item-id key and output-index key of an event.
func respEventKeys(itemID any, outIdx any) (string, string) {
	k1, k2 := "", ""
	if id := asString(itemID); id != "" {
		k1 = "i:" + id
	}
	if idx, ok := asInt(outIdx); ok {
		k2 = "o:" + strconv.Itoa(idx)
	}
	return k1, k2
}

func (s *respStream) textBlock(itemID, outIdx any) *respBlock {
	k1, k2 := respEventKeys(itemID, outIdx)
	key := k1
	if key == "" {
		key = k2
	}
	if key == "" {
		key = "o:?"
	}
	b := s.texts[key]
	if b == nil {
		b = &respBlock{}
		s.texts[key] = b
	}
	return b
}

func (s *respStream) emitText(b *respBlock, text string) error {
	if text == "" || (b.started && !b.open) {
		return nil
	}
	if !b.started {
		if err := s.begin(b, map[string]any{"type": "text", "text": ""}); err != nil {
			return err
		}
	}
	return s.delta(b, map[string]any{"type": "text_delta", "text": text})
}

func (s *respStream) registerCall(item map[string]any, outIdx any) *respCall {
	c := &respCall{
		itemID: asString(item["id"]),
		callID: asString(item["call_id"]),
		name:   asString(item["name"]),
	}
	if c.callID == "" {
		c.callID = c.itemID
	}
	k1, k2 := respEventKeys(item["id"], outIdx)
	if k1 != "" {
		s.calls[k1] = c
	}
	if k2 != "" {
		s.calls[k2] = c
	}
	return c
}

// lookupCall finds the call an event refers to, synthesizing one when the
// upstream never announced it with output_item.added.
func (s *respStream) lookupCall(itemID, outIdx any, name string) *respCall {
	k1, k2 := respEventKeys(itemID, outIdx)
	for _, k := range []string{k1, k2} {
		if k != "" {
			if c := s.calls[k]; c != nil {
				return c
			}
		}
	}
	c := &respCall{itemID: asString(itemID), name: name}
	c.callID = c.itemID
	if k1 != "" {
		s.calls[k1] = c
	}
	if k2 != "" {
		s.calls[k2] = c
	}
	return c
}

func (s *respStream) startCall(c *respCall) error {
	if c.blk == nil {
		c.blk = &respBlock{}
	}
	if c.blk.started {
		return nil
	}
	s.hadTool = true
	return s.begin(c.blk, map[string]any{
		"type": "tool_use", "id": c.callID, "name": c.name, "input": map[string]any{},
	})
}

func (s *respStream) callDelta(c *respCall, frag string) error {
	if c.done {
		return nil
	}
	if err := s.startCall(c); err != nil {
		return err
	}
	if !c.blk.open || frag == "" {
		return nil
	}
	c.sawDelta = true
	return s.delta(c.blk, map[string]any{"type": "input_json_delta", "partial_json": frag})
}

func (s *respStream) callDone(c *respCall, args string) error {
	if c.done {
		return nil
	}
	if err := s.startCall(c); err != nil {
		return err
	}
	if c.blk.open && !c.sawDelta {
		if args == "" {
			args = "{}"
		}
		c.sawDelta = true
		if err := s.delta(c.blk, map[string]any{"type": "input_json_delta", "partial_json": args}); err != nil {
			return err
		}
	}
	c.done = true
	if s.cur == c.blk {
		return s.closeCur()
	}
	return nil
}

func (s *respStream) finish(stop string) error {
	if s.finished {
		return nil
	}
	s.finished = true
	if err := s.start(); err != nil {
		return err
	}
	if err := s.closeCur(); err != nil {
		return err
	}
	u := map[string]any{"output_tokens": s.usage.Out}
	if s.usage.In > 0 {
		u["input_tokens"] = s.usage.In
	}
	if s.usage.CacheRead > 0 {
		u["cache_read_input_tokens"] = s.usage.CacheRead
	}
	if err := s.send("message_delta", map[string]any{
		"delta": map[string]any{"stop_reason": stop, "stop_sequence": nil},
		"usage": u,
	}); err != nil {
		return err
	}
	return s.send("message_stop", map[string]any{})
}

func (s *respStream) takeUsage(resp map[string]any) {
	if resp == nil {
		return
	}
	if u := usageFromObject(map[string]any{"usage": resp["usage"]}); !u.empty() {
		s.usage = u
	}
}

// abort closes the open block and ends the stream with an error (no
// message_delta / message_stop follow, per the contract).
func (s *respStream) abort(msg, fallback string) error {
	if err := s.closeCur(); err != nil {
		return err
	}
	s.finished = true
	if msg == "" {
		msg = fallback
	}
	return fmt.Errorf("responses: %s", msg)
}

// handle processes one upstream event. A non-nil error aborts the stream.
func (s *respStream) handle(event string, data []byte) error {
	if s.finished {
		return nil
	}
	ev, err := decodeObject(data)
	if err != nil || ev == nil {
		return nil // "[DONE]", garbage, keep-alives
	}
	typ := asString(ev["type"])
	if typ == "" {
		typ = event
	}
	switch typ {
	case "response.created":
		if resp := asMap(ev["response"]); resp != nil && s.id == "" {
			s.id = asString(resp["id"])
		}
		return s.start()

	case "response.output_item.added":
		if item := asMap(ev["item"]); asString(item["type"]) == "function_call" {
			s.registerCall(item, ev["output_index"])
		}

	case "response.output_text.delta":
		return s.emitText(s.textBlock(ev["item_id"], ev["output_index"]), asString(ev["delta"]))

	case "response.output_text.done":
		if b := s.textBlock(ev["item_id"], ev["output_index"]); !b.started {
			return s.emitText(b, asString(ev["text"]))
		}

	case "response.function_call_arguments.delta":
		c := s.lookupCall(ev["item_id"], ev["output_index"], asString(ev["name"]))
		return s.callDelta(c, asString(ev["delta"]))

	case "response.function_call_arguments.done":
		c := s.lookupCall(ev["item_id"], ev["output_index"], asString(ev["name"]))
		return s.callDone(c, asString(ev["arguments"]))

	case "response.output_item.done":
		item := asMap(ev["item"])
		switch asString(item["type"]) {
		case "function_call":
			c := s.lookupCall(item["id"], ev["output_index"], asString(item["name"]))
			if c.blk == nil || !c.blk.started {
				if cid := asString(item["call_id"]); cid != "" {
					c.callID = cid
				}
				if c.name == "" {
					c.name = asString(item["name"])
				}
			}
			return s.callDone(c, asString(item["arguments"]))
		case "message":
			b := s.textBlock(item["id"], ev["output_index"])
			if !b.started {
				var sb strings.Builder
				for _, p := range asList(item["content"]) {
					if pm := asMap(p); pm != nil && asString(pm["type"]) == "output_text" {
						sb.WriteString(asString(pm["text"]))
					}
				}
				if err := s.emitText(b, sb.String()); err != nil {
					return err
				}
			}
			if s.cur == b {
				return s.closeCur()
			}
		}

	case "response.completed", "response.incomplete":
		resp := asMap(ev["response"])
		s.takeUsage(resp)
		status := asString(resp["status"])
		if typ == "response.incomplete" {
			status = "incomplete"
		}
		reason := ""
		if d := asMap(resp["incomplete_details"]); d != nil {
			reason = asString(d["reason"])
		}
		return s.finish(respStopReason(s.hadTool, status, reason))

	case "response.failed":
		resp := asMap(ev["response"])
		msg := respErrorMessage(resp)
		return s.abort(msg, "upstream response failed")

	case "error":
		return s.abort(respErrorMessage(ev), "upstream stream error")
	}
	return nil // reasoning.*, in_progress, content_part.*, unknown
}

func (t *responsesTranslator) Stream(r io.Reader, emit func(string, []byte) error, model string) (usageInfo, error) {
	s := &respStream{
		emit:  emit,
		model: model,
		texts: map[string]*respBlock{},
		calls: map[string]*respCall{},
	}
	if err := sseEvents(r, s.handle); err != nil {
		if !s.finished {
			// Flush what was translated; surface the failure to the caller.
			if cerr := s.closeCur(); cerr != nil {
				return s.usage, cerr
			}
		}
		return s.usage, err
	}
	if !s.finished {
		if err := s.finish(respStopReason(s.hadTool, "", "")); err != nil {
			return s.usage, err
		}
	}
	return s.usage, nil
}

// ----------------------------------------------------------------- error

func (t *responsesTranslator) Error(status int, body []byte) []byte {
	msg := ""
	if m, err := decodeObject(body); err == nil {
		msg = respErrorMessage(m)
	}
	if msg == "" {
		msg = respTrimBody(body)
	}
	if msg == "" {
		msg = "upstream returned HTTP " + strconv.Itoa(status)
	}
	return marshal(map[string]any{
		"type": "error",
		"error": map[string]any{
			"type":    anthropicErrorType(status),
			"message": msg,
		},
	})
}

func respTrimBody(body []byte) string {
	s := strings.TrimSpace(string(body))
	if len(s) > responsesErrMaxBytes {
		s = s[:responsesErrMaxBytes]
		for len(s) > 0 && !utf8.ValidString(s) {
			s = s[:len(s)-1]
		}
	}
	return s
}
