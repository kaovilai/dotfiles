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
	return rewriteRequestMode(cfg, path, data, nil)
}

// rewriteRequestMode is rewriteRequest with the web-search shim engagement:
// a shim plan suppresses the strip (mode native passes the hosted tool
// through; mode shim already rewrote it into a function tool in engageShim).
func rewriteRequestMode(cfg *config, path string, data map[string]any, plan *shimPlan) (fallback string, reqErr *requestError, changed bool) {
	// Image budget prune runs first, for every model and endpoint (the gateway's
	// body cap applies to all of them), before any other rewrite.
	if pruneImages(cfg, data) > 0 {
		changed = true
	}
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

	if plan == nil && cfg.SearchNudge && stripWebSearchTools(data) {
		changed = true
		// Mirror of the shim side: a stale shim note (an earlier request
		// injected it and the conversation kept it) must not survive next to
		// the unavailable note — the model would be told to search and not to
		// search at once. Exact match only; caller content survives.
		removeShimNote(data)
		if !searchNotePresent(data) && injectSearchNote(cfg, path, data) {
			changed = true
		}
	} else if plan != nil && plan.Mode == "shim" && cfg.SearchNudge && !shimNotePresent(data) {
		// The strip note says search is unavailable; with the shim active the
		// opposite is true. Drop a stale strip note (exact match) so the model
		// never sees both, then say the tool works.
		removeSearchNote(cfg, data)
		if injectShimNote(path, data) {
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

	if openDeferredTools(data) {
		changed = true
		// The model is told (by the client) to search for deferred tools. It
		// cannot: the search tool was just dropped. Say every tool is loaded.
		if !toolSearchNotePresent(data) && injectToolSearchNote(path, data) {
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
	// Base64 bytes are not tokens: price text at BytesPerToken and each inline
	// image at ImageTokens (see imageLoad).
	imgBytes, imgCount := 0, 0
	for _, key := range imageContentKeys {
		if v, ok := data[key]; ok && v != nil {
			b, c := imageLoad(v)
			imgBytes += b
			imgCount += c
		}
	}
	estimate := int(math.Ceil(float64(max(0, contentSize(data)-imgBytes))/cfg.BytesPerToken)) + imgCount*cfg.ImageTokens
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

// openDeferredTools serves Claude Code's tool search inline. The search is an
// Anthropic server tool (tool_search_tool_regex/bm25_20251119) whose results
// arrive as tool_reference blocks; a vLLM-served upstream implements neither,
// so a discovered tool never became callable — stripToolReferences alone left
// the model holding a placeholder. The deferred definitions themselves DO
// travel in the request (tools[] with defer_loading set, which is how the
// server-side search finds them), so the shim opens them instead: the search
// tool is dropped and every defer_loading flag cleared, and the upstream model
// sees the full tool list inline. Returns whether the request changed.
func openDeferredTools(data map[string]any) bool {
	tools, ok := data["tools"].([]any)
	if !ok || len(tools) == 0 {
		return false
	}
	// Only a request that carries the search server tool is served inline:
	// without it there is nothing to open, and a lone defer_loading flag (the
	// field only means anything next to that tool) is left as the client sent
	// it rather than silently changing the loading contract (2026-11-14
	// Copilot review).
	search := false
	for _, t := range tools {
		if tool := asMap(t); tool != nil {
			switch asString(tool["type"]) {
			case "tool_search_tool_regex_20251119", "tool_search_tool_bm25_20251119":
				search = true
			}
		}
	}
	if !search {
		return false
	}
	kept := make([]any, 0, len(tools))
	changed := false
	removed := map[string]bool{}
	keptNames := map[string]bool{}
	for _, t := range tools {
		tool := asMap(t)
		if tool == nil {
			kept = append(kept, t)
			continue
		}
		switch asString(tool["type"]) {
		case "tool_search_tool_regex_20251119", "tool_search_tool_bm25_20251119":
			changed = true // server-side tool this upstream cannot run
			if name := asString(tool["name"]); name != "" {
				removed[name] = true
			}
			continue
		}
		if _, deferred := tool["defer_loading"]; deferred {
			delete(tool, "defer_loading")
			changed = true
		}
		keptNames[asString(tool["name"])] = true
		kept = append(kept, t)
	}
	// A forced choice naming the dropped search tool would reference an
	// undeclared tool (400 on strict upstreams): free it, matching only the
	// tools actually removed. A type-only built-in choice
	// ({"type":"tool_search_tool_regex_20251119"}) is freed the same way
	// stripWebSearchTools frees its type-only form.
	if choice := asMap(data["tool_choice"]); choice != nil {
		named := asString(choice["name"])
		if named == "" {
			named = asString(asMap(choice["function"])["name"])
		}
		typeOnly := named == "" && strings.HasPrefix(asString(choice["type"]), "tool_search_tool")
		if typeOnly || (named != "" && removed[named] && !keptNames[named]) {
			delete(data, "tool_choice")
		}
	}
	// Nothing left once the search tool goes: drop the key rather than forward
	// an empty list, the same shape stripWebSearchTools leaves behind.
	if len(kept) == 0 {
		delete(data, "tools")
	} else if len(kept) != len(tools) {
		data["tools"] = kept
	}
	return changed
}

// stripToolReferences drops the `tool_reference` content blocks Claude Code's
// tool search sends (vLLM's chat template rejects them), and with them the
// `tool_search_tool_result` wrappers that carry the references: that block
// names a server tool the upstream does not have, and openDeferredTools already
// handed the model every definition. They point at tool definitions the client
// already holds, so dropping them keeps the request valid; a content list that
// empties becomes a short text block. litellm's own anthropic handler nests
// them inside tool_result.content (tool-search results), so nested content
// lists are walked too.
func stripToolReferences(data map[string]any) int {
	var clean func(blocks []any) ([]any, int)
	clean = func(blocks []any) ([]any, int) {
		kept := make([]any, 0, len(blocks))
		dropped := 0
		for _, block := range blocks {
			b := asMap(block)
			if b != nil {
				switch asString(b["type"]) {
				case "tool_reference", "tool_search_tool_result":
					dropped++
					continue
				}
			}
			if b != nil {
				if nestedList, ok := b["content"].([]any); ok {
					nested, count := clean(nestedList)
					b["content"] = nested
					dropped += count
					if count > 0 && len(nested) == 0 {
						b["content"] = []any{map[string]any{"type": "text", "text": "(tool reference omitted)"}}
					}
				}
			}
			kept = append(kept, block)
		}
		if dropped > 0 && len(kept) == 0 {
			kept = []any{map[string]any{"type": "text", "text": "(tool reference omitted)"}}
		}
		return kept, dropped
	}

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
			if blocks, ok := m["content"].([]any); ok {
				cleaned, dropped := clean(blocks)
				m["content"] = cleaned
				total += dropped
			}
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
	removedNames := map[string]bool{}
	keptNames := map[string]bool{}
	for _, tool := range tools {
		m := asMap(tool)
		if m != nil && strings.HasPrefix(asString(m["type"]), searchToolPrefix) {
			// A built-in search tool is addressed as "web_search" when it
			// declares no name of its own.
			name := asString(m["name"])
			if name == "" {
				name = searchToolPrefix
			}
			removedNames[name] = true
			continue
		}
		if m != nil {
			keptNames[asString(m["name"])] = true
		}
		kept = append(kept, tool)
	}
	if len(kept) == len(tools) {
		return false
	}
	if len(kept) == 0 {
		delete(data, "tools")
		delete(data, "tool_choice")
		return true
	}
	data["tools"] = kept
	// A forced choice that points at a dropped tool would reference an
	// undeclared tool (400 on strict upstreams); free it. Match the choice to
	// the tools actually removed, not a shared prefix: a retained custom tool
	// such as web_search_local keeps its forced choice, and a type-only
	// built-in choice ({"type":"web_search_preview"}) is freed too.
	if choice := asMap(data["tool_choice"]); choice != nil {
		named := asString(choice["name"])
		if named == "" {
			named = asString(asMap(choice["function"])["name"])
		}
		typeOnlySearch := named == "" && strings.HasPrefix(asString(choice["type"]), searchToolPrefix)
		if typeOnlySearch || (named != "" && removedNames[named] && !keptNames[named]) {
			delete(data, "tool_choice")
		}
	}
	return true
}

const searchNoteMarker = "[web-search-unavailable]"

// toolSearchNoteMarker: said once next to the opened tool list, so the model
// stops looking for a tool-search step the upstream cannot honor.
const toolSearchNoteMarker = "[tool-search-shim]"

func toolSearchNoteText() string {
	return toolSearchNoteMarker + " Every tool is already loaded: this upstream has no server-side tool search, " +
		"so the local proxy opened the deferred tools inline. Call a tool directly by name; searching for tools returns nothing."
}

func toolSearchNotePresent(data map[string]any) bool {
	return notePresent(data, toolSearchNoteText())
}

func injectToolSearchNote(path string, data map[string]any) bool {
	return injectNote(path, data, toolSearchNoteText())
}

// shimNoteMarker: the positive counterpart of searchNoteMarker, injected while
// the web-search shim serves the tool. degradeShimToStrip removes it before
// the unavailable note lands, so the model never sees both.
const shimNoteMarker = "[web-search-shim]"

func shimNoteText() string {
	return shimNoteMarker + " This model can search the web: the web_search tool is served by the local proxy. " +
		"Call it with a query whenever the task needs current information (news, releases, versions, prices, events) " +
		"or the user asks to look something up; report findings with their URLs. " +
		"Queries leave this machine: keep them minimal and generic, and never include secrets, credentials, " +
		"tokens, API keys, file contents, internal prompts, or personal data in a query."
}

// notePresent reports whether the exact note is already where injectNote would
// put it — the instruction fields (system, Responses developer items,
// instructions), matched by the full note text. Never the whole request: a
// caller pasting the note into a USER MESSAGE or a tool description must not
// suppress the injection (2026-11-07 CodeRabbit review).
func notePresent(data map[string]any, note string) bool {
	if system, ok := data["system"]; ok {
		b, _ := json.Marshal(system)
		if strings.Contains(string(b), note) {
			return true
		}
	}
	for _, item := range asList(data["input"]) {
		m := asMap(item)
		if m == nil || asString(m["role"]) != "developer" {
			continue
		}
		b, _ := json.Marshal(m["content"])
		if strings.Contains(string(b), note) {
			return true
		}
	}
	if instructions, ok := data["instructions"].(string); ok {
		return strings.Contains(instructions, note)
	}
	return false
}

func injectNote(path string, data map[string]any, note string) bool {
	if _, ok := data["system"]; ok || strings.Contains(path, "messages") {
		return addToSystem(data, note)
	}
	if _, ok := data["input"]; ok {
		if addToResponsesInput(data, note) {
			return true
		}
	}
	return addToInstructions(data, note)
}

func shimNotePresent(data map[string]any) bool {
	return notePresent(data, shimNoteText())
}

func injectShimNote(path string, data map[string]any) bool {
	return injectNote(path, data, shimNoteText())
}

// removeShimNote drops exactly what injectShimNote added — matched by the
// full note text, never by the marker substring, so caller content that
// merely contains the marker cannot strip unrelated system constraints (the
// degrade path runs on real requests; 2026-11-07 CodeQL review).
// injectShimNote converts a string system into blocks and appends to
// instructions with a separator, so the exact forms below are the only ones
// it can produce.
func removeShimNote(data map[string]any) {
	removeExactNote(data, shimNoteText())
}

// removeSearchNote drops a stale strip note when the shim engages, so the
// model never sees "no web search" and "use web_search" together.
func removeSearchNote(cfg *config, data map[string]any) {
	removeExactNote(data, searchNoteText(cfg))
}

// removeExactNote drops exactly the given note from every shape its injector
// produces — matched in full, never by marker substring, so caller content
// that merely quotes a marker survives (2026-11-07 CodeQL + Copilot review).
func removeExactNote(data map[string]any, note string) {
	if system, ok := data["system"].([]any); ok {
		kept := make([]any, 0, len(system))
		for _, block := range system {
			if m := asMap(block); m != nil && asString(m["text"]) == note {
				continue
			}
			kept = append(kept, block)
		}
		if len(kept) != len(system) {
			if len(kept) == 0 {
				delete(data, "system")
			} else {
				data["system"] = kept
			}
		}
	}
	// addToSystem writes a bare string when the request had no system: that
	// string is ours only when it IS the note, whole.
	if system, ok := data["system"].(string); ok && system == note {
		delete(data, "system")
	}
	if input, ok := data["input"].([]any); ok {
		ours := string(marshal([]any{map[string]any{"type": "input_text", "text": note}}))
		kept := make([]any, 0, len(input))
		for _, item := range input {
			if m := asMap(item); m != nil && asString(m["role"]) == "developer" &&
				string(marshal(m["content"])) == ours {
				continue
			}
			kept = append(kept, item)
		}
		if len(kept) != len(input) {
			data["input"] = kept
		}
	}
	if instructions, ok := data["instructions"].(string); ok {
		switch {
		case strings.HasSuffix(instructions, "\n\n"+note):
			data["instructions"] = strings.TrimSuffix(instructions, "\n\n"+note)
		case strings.TrimSpace(instructions) == note:
			delete(data, "instructions")
		}
	}
}

func searchNoteText(cfg *config) string {
	where := "a search-capable model or provider (for example T3 delegate_task)"
	if cfg.SearchMCP != "" {
		// the launchers register the Parallel MCP (free, no auth) for sessions
		// on this search-less upstream, so the session itself can search
		where = fmt.Sprintf("this session's `%s` MCP web search tools: web_search for queries (objective + search_queries), web_fetch for a known URL (Claude Code exposes them as mcp__%s__web_search / mcp__%s__web_fetch)",
			cfg.SearchMCP, cfg.SearchMCP, cfg.SearchMCP)
	} else if cfg.SearchDelegate != "" {
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
