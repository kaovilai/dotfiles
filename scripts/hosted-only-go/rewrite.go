package main

import (
	"encoding/json"
	"fmt"
	"math"
	"strings"
)

var imageBlockTypes = map[string]bool{"image": true, "input_image": true, "image_url": true}

type requestError struct {
	Status  int
	Message string
	Code    string
}

// rewriteRequest applies the hosted-only request rewrites in the same order as
// HostedOnlyHooks.async_pre_call_hook. It returns the model to fall back to
// (empty for none), a requestError when the request must be refused, and
// whether the body changed (so an untouched request can be forwarded verbatim).
func rewriteRequest(cfg *config, path string, data map[string]any) (fallback string, reqErr *requestError, changed bool) {
	requested := asString(data["model"])
	model := requested
	// Aliases (claude-sonnet-5-5 on the Claude flavor) are served by GLM: the
	// upstream must receive the real model id.
	if _, ok := cfg.Aliases[model]; ok {
		model = cfg.GLM
		data["model"] = model
		changed = true
	}
	if !cfg.isRits(model) {
		return "", nil, changed
	}

	if cfg.VisionFallback && cfg.isGLM(model) && cfg.DeepSeek != cfg.GLM &&
		(hasImage(data["messages"]) || hasImage(data["input"])) {
		data["model"] = cfg.DeepSeek
		model = cfg.DeepSeek
		changed = true
	}

	if tools, ok := data["tools"].([]any); ok {
		for _, t := range tools {
			tool := asMap(t)
			if tool == nil || asString(tool["type"]) != "custom" {
				continue
			}
			if format := asMap(tool["format"]); format != nil && asString(format["type"]) == "grammar" {
				delete(tool, "format")
				changed = true
			}
		}
	}

	if cfg.SearchNudge && stripWebSearchTools(data) {
		changed = true
		if !searchNotePresent(data) && injectSearchNote(cfg, path, data) {
			changed = true
		}
	}

	if _, hasMessages := data["messages"]; hasMessages && data["input"] == nil && data["thinking"] == nil {
		data["thinking"] = map[string]any{"type": "disabled"}
		changed = true
	}

	if input, ok := data["input"].([]any); ok {
		kept := make([]any, 0, len(input))
		for _, item := range input {
			if !isEmptyInstruction(item) {
				kept = append(kept, item)
			}
		}
		if len(kept) != len(input) {
			data["input"] = kept
			changed = true
		}
	}

	if stripToolReferences(data) > 0 {
		changed = true
	}

	if e, clamped := clampOutput(cfg, data); e != nil {
		return "", e, changed
	} else if clamped {
		changed = true
	}

	if cfg.FallbackOn {
		if _, set := data["fallbacks"]; !set && cfg.GLM != cfg.DeepSeek {
			var other string
			switch {
			case model == cfg.GLM:
				other = cfg.DeepSeek
			case model == cfg.DeepSeek:
				other = cfg.GLM
			}
			if other != "" && !hasImage(data["messages"]) && !hasImage(data["input"]) {
				fallback = other
			}
		}
	}
	return fallback, nil, changed
}

func hasImage(node any) bool {
	switch v := node.(type) {
	case map[string]any:
		if imageBlockTypes[asString(v["type"])] {
			return true
		}
		for _, child := range v {
			if hasImage(child) {
				return true
			}
		}
	case []any:
		for _, child := range v {
			if hasImage(child) {
				return true
			}
		}
	}
	return false
}

func isEmptyInstruction(item any) bool {
	m := asMap(item)
	if m == nil {
		return false
	}
	role := asString(m["role"])
	if role != "developer" && role != "system" {
		return false
	}
	switch content := m["content"].(type) {
	case nil:
		return true
	case string:
		return strings.TrimSpace(content) == ""
	case []any:
		for _, block := range content {
			b := asMap(block)
			if b == nil {
				return false
			}
			kind := asString(b["type"])
			if kind != "input_text" && kind != "text" {
				return false
			}
			if strings.TrimSpace(asString(b["text"])) != "" {
				return false
			}
		}
		return true
	}
	return false
}

func contentSize(data map[string]any) int {
	size := 0
	for _, key := range []string{"messages", "input", "system", "instructions", "tools"} {
		if v, ok := data[key]; ok && v != nil {
			size += jsonLen(v)
		}
	}
	return size
}

// clampOutput keeps input + max_tokens inside the served window. A request with
// no room left for a useful answer is refused with a 400 worded like the
// provider's context-overflow error, so the client compacts and retries.
func clampOutput(cfg *config, data map[string]any) (*requestError, bool) {
	model := asString(data["model"])
	if model != cfg.GLM && model != cfg.DeepSeek {
		if _, alias := cfg.Aliases[model]; !alias {
			return nil, false
		}
	}
	key := "max_tokens"
	if _, ok := data["max_output_tokens"]; ok {
		key = "max_output_tokens"
	}
	requested, ok := asInt(data[key])
	if !ok {
		return nil, false
	}
	estimate := int(math.Ceil(float64(contentSize(data)) / cfg.BytesPerToken))
	room := cfg.MaxModelLen - estimate - cfg.OutputReserve
	minOut := cfg.MinOutput
	if requested < minOut {
		minOut = requested
	}
	if room < minOut {
		limit := cfg.MaxModelLen - minOut
		return &requestError{
			Status: 400,
			Code:   "context_length_exceeded",
			Message: fmt.Sprintf(
				"prompt is too long: %d tokens > %d maximum. Input length (~%d) exceeds the model's maximum context length (%d) once %d output tokens are reserved; compact the conversation and retry (context_length_exceeded).",
				estimate, limit, estimate, cfg.MaxModelLen, minOut),
		}, false
	}
	if room < requested {
		data[key] = room
		return nil, true
	}
	return nil, false
}

func stripToolReferences(data map[string]any) int {
	total := 0
	for _, key := range []string{"messages", "input"} {
		items, ok := data[key].([]any)
		if !ok {
			continue
		}
		for _, item := range items {
			m := asMap(item)
			if m == nil {
				continue
			}
			blocks, ok := m["content"].([]any)
			if !ok {
				continue
			}
			kept := make([]any, 0, len(blocks))
			dropped := 0
			for _, block := range blocks {
				if b := asMap(block); b != nil && asString(b["type"]) == "tool_reference" {
					dropped++
					continue
				}
				kept = append(kept, block)
			}
			if dropped == 0 {
				continue
			}
			if len(kept) == 0 {
				kept = []any{map[string]any{"type": "text", "text": "(tool reference omitted)"}}
			}
			m["content"] = kept
			total += dropped
		}
	}
	return total
}

// flattenAdditionalTools ports unwrap_tools_middleware.py: Codex can send tools
// as an {"type":"additional_tools"} input item, which vLLM-served rits/ models
// reject. Function tools (including namespaced ones) move into data["tools"];
// the item is dropped. Only rits/ models are touched.
func flattenAdditionalTools(data map[string]any) bool {
	items, ok := data["input"].([]any)
	if !ok {
		return false
	}
	var extracted []any
	kept := make([]any, 0, len(items))
	found := false
	for _, item := range items {
		m := asMap(item)
		if m == nil || asString(m["type"]) != "additional_tools" {
			kept = append(kept, item)
			continue
		}
		found = true
		for _, tool := range asList(m["tools"]) {
			tm := asMap(tool)
			if tm == nil {
				continue
			}
			switch asString(tm["type"]) {
			case "namespace":
				for _, nested := range asList(tm["tools"]) {
					if nm := asMap(nested); nm != nil && asString(nm["type"]) == "function" {
						extracted = append(extracted, nested)
					}
				}
			case "function":
				extracted = append(extracted, tool)
			}
		}
	}
	if !found {
		return false
	}
	if len(extracted) > 0 {
		data["tools"] = append(asList(data["tools"]), extracted...)
	}
	data["input"] = kept
	return true
}

const searchToolPrefix = "web_search"

func stripWebSearchTools(data map[string]any) bool {
	tools, ok := data["tools"].([]any)
	if !ok {
		return false
	}
	kept := make([]any, 0, len(tools))
	for _, tool := range tools {
		m := asMap(tool)
		if m != nil && strings.HasPrefix(asString(m["type"]), searchToolPrefix) {
			continue
		}
		kept = append(kept, tool)
	}
	if len(kept) == len(tools) {
		return false
	}
	if len(kept) > 0 {
		data["tools"] = kept
	} else {
		delete(data, "tools")
		delete(data, "tool_choice")
	}
	return true
}

const searchNoteMarker = "[web-search-unavailable]"

func searchNoteText(cfg *config) string {
	where := "a search-capable model or provider (for example T3 delegate_task)"
	if cfg.SearchDelegate != "" {
		provider, model := cfg.SearchDelegate, ""
		if i := strings.IndexByte(cfg.SearchDelegate, ':'); i >= 0 {
			provider, model = cfg.SearchDelegate[:i], cfg.SearchDelegate[i+1:]
		}
		if provider != "" && model != "" {
			where = fmt.Sprintf("T3 delegate_task with providerInstanceId=%s model=%s", provider, model)
		} else if provider != "" {
			where = fmt.Sprintf("T3 delegate_task with providerInstanceId=%s", provider)
		}
	}
	return fmt.Sprintf("%s This model has no web search: the hosted upstream ignores the web_search tool, so it was removed for this request. Never claim to have searched, and never guess or invent a URL. When the task needs current information (news, releases, versions, prices, events) or the user asks you to look something up, route the lookup to %s: ask it to search, open every URL it returns, report findings with their URLs, drop dead/403/404 links, one URL per story. If no search-capable provider is available, say web search is unavailable instead of answering from memory. For a known URL, fetch it directly.",
		searchNoteMarker, where)
}

func searchNotePresent(data map[string]any) bool {
	probe := map[string]any{}
	for _, key := range []string{"system", "instructions", "messages", "input"} {
		if v, ok := data[key]; ok {
			probe[key] = v
		}
	}
	b, err := json.Marshal(probe)
	return err == nil && strings.Contains(string(b), searchNoteMarker)
}

func injectSearchNote(cfg *config, path string, data map[string]any) bool {
	if _, ok := data["system"]; ok || strings.Contains(path, "messages") {
		return addToSystem(data, searchNoteText(cfg))
	}
	if _, ok := data["input"]; ok {
		if addToResponsesInput(data, searchNoteText(cfg)) {
			return true
		}
	}
	if _, ok := data["instructions"]; ok {
		if addToInstructions(data, searchNoteText(cfg)) {
			return true
		}
	}
	if _, ok := data["messages"]; ok {
		return addToChatMessages(data, searchNoteText(cfg))
	}
	return false
}

func addToSystem(data map[string]any, text string) bool {
	switch system := data["system"].(type) {
	case string:
		data["system"] = []any{
			map[string]any{"type": "text", "text": system},
			map[string]any{"type": "text", "text": text},
		}
		return true
	case []any:
		data["system"] = append(system, map[string]any{"type": "text", "text": text})
		return true
	case nil:
		if _, present := data["system"]; present {
			data["system"] = text
			return true
		}
		data["system"] = text
		return true
	}
	return false
}

func addToInstructions(data map[string]any, text string) bool {
	switch instructions := data["instructions"].(type) {
	case string:
		if strings.TrimSpace(instructions) != "" {
			data["instructions"] = instructions + "\n\n" + text
		} else {
			data["instructions"] = text
		}
		return true
	case nil:
		data["instructions"] = text
		return true
	}
	return false
}

func addToChatMessages(data map[string]any, text string) bool {
	messages, ok := data["messages"].([]any)
	if !ok {
		return false
	}
	for _, message := range messages {
		m := asMap(message)
		if m == nil || asString(m["role"]) != "system" {
			continue
		}
		switch content := m["content"].(type) {
		case string:
			m["content"] = content + "\n\n" + text
		case []any:
			m["content"] = append(content, map[string]any{"type": "text", "text": text})
		default:
			m["content"] = text
		}
		return true
	}
	data["messages"] = append([]any{map[string]any{"role": "system", "content": text}}, messages...)
	return true
}

func addToResponsesInput(data map[string]any, text string) bool {
	item := map[string]any{
		"role":    "developer",
		"content": []any{map[string]any{"type": "input_text", "text": text}},
	}
	switch input := data["input"].(type) {
	case []any:
		data["input"] = append([]any{item}, input...)
		return true
	case string:
		data["input"] = []any{
			item,
			map[string]any{"role": "user", "content": []any{map[string]any{"type": "input_text", "text": input}}},
		}
		return true
	}
	return false
}
