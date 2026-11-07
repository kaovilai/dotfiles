package main

// Web-search shim, part 1+2 request side (docs/notes/web-search-shim.md).
//
// Detection: per-request detection is impossible ("tool offered, no call came
// back" is indistinguishable from the model choosing not to search), so a
// forced-choice canary piggybacks on the first real request that carries a
// hosted web_search tool for a verdict-less model. Verdicts are cached per
// (model, gateway) with a TTL so an upstream vLLM upgrade re-probes.
//
// Shim: when the verdict is *ignored*, the hosted tool is rewritten into a
// plain function tool named web_search exposing only {query}; the proxy
// executes the calls itself against the Parallel Search API (parallel.go) and
// loops upstream (shimloop.go) until the model stops searching, capped at
// max_uses. cfg.isRits stays the fail-closed default: no verdict -> strip.

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// searchVerdict values.
const (
	verdictNative  = "native"  // upstream emits search call items: passthrough
	verdictIgnored = "ignored" // 200 without a call item, or a 400 naming the tool: strip + shim
	verdictUnknown = "unknown" // anything else: fail closed to today's strip + note
)

const shimVerdictTTL = 7 * 24 * time.Hour

// shimPlan is the per-request engagement state once the shim decides to act.
// mode "native" suppresses the strip (passthrough); mode "shim" rewrites the
// hosted tool into a function tool and runs the response-side loop.
type shimPlan struct {
	Mode           string   // "shim" | "native"
	MaxUses        int      // caller's max_uses, capped at 5, default 5
	AllowedDomains []string // caller's allowed_domains, enforced proxy-side
	Forced         bool     // caller forced tool_choice naming web_search
	Dialect        string   // "anthropic" | "responses"
	Model          string   // upstream model id the verdict applies to
}

const shimMaxUsesCap = 5

// hostedSearchTools returns the hosted web-search tool definitions in data.
func hostedSearchTools(data map[string]any) []map[string]any {
	var found []map[string]any
	for _, tool := range asList(data["tools"]) {
		m := asMap(tool)
		if m == nil || !strings.HasPrefix(asString(m["type"]), searchToolPrefix) {
			continue
		}
		found = append(found, m)
	}
	return found
}

// clientOwnsSearchName reports a non-hosted tool already named web_search: the
// shim declines for that request rather than shadowing the client's tool.
func clientOwnsSearchName(data map[string]any) bool {
	for _, tool := range asList(data["tools"]) {
		m := asMap(tool)
		if m == nil || strings.HasPrefix(asString(m["type"]), searchToolPrefix) {
			continue
		}
		name := asString(m["name"])
		if name == "" {
			if fn := asMap(m["function"]); fn != nil {
				name = asString(fn["name"])
			}
		}
		if name == searchToolPrefix {
			return true
		}
	}
	return false
}

// shimRewriteTools rewrites the hosted web-search tools into a single function
// tool named web_search exposing only {query}, reading allowed_domains and
// max_uses off the original definitions (they are caller-set fields, not model
// arguments) and preserving a forced tool_choice that names the tool: the
// rewritten tool keeps the name, so a caller's explicit requirement to search
// survives the rewrite. Returns nil when it must decline.
func shimRewriteTools(path string, data map[string]any) *shimPlan {
	hosted := hostedSearchTools(data)
	if len(hosted) == 0 || clientOwnsSearchName(data) {
		return nil
	}
	plan := &shimPlan{MaxUses: shimMaxUsesCap, Dialect: requestDialect(path)}
	for _, tool := range hosted {
		if n, ok := asInt(tool["max_uses"]); ok && n > 0 && n < plan.MaxUses {
			plan.MaxUses = n
		}
		for _, d := range asList(tool["allowed_domains"]) {
			if s := strings.TrimSpace(asString(d)); s != "" {
				plan.AllowedDomains = append(plan.AllowedDomains, s)
			}
		}
	}
	// Forced choice: {"type":"tool","name":"web_search"} (Messages) or
	// {"type":"function","name":"web_search"} (Responses). Preserved as-is.
	if choice := asMap(data["tool_choice"]); choice != nil {
		named := asString(choice["name"])
		if named == "" {
			named = asString(asMap(choice["function"])["name"])
		}
		plan.Forced = named == searchToolPrefix
	}

	fn := map[string]any{
		"name":        searchToolPrefix,
		"description": "Search the web. Returns titled results with excerpts for the query.",
	}
	schema := map[string]any{
		"type":       "object",
		"properties": map[string]any{"query": map[string]any{"type": "string", "description": "The search query."}},
		"required":   []any{"query"},
	}
	if plan.Dialect == "responses" || plan.Dialect == "openai" {
		fn["type"] = "function"
		fn["parameters"] = schema
	} else {
		fn["input_schema"] = schema
	}
	tools := asList(data["tools"])
	kept := make([]any, 0, len(tools))
	for _, tool := range tools {
		if m := asMap(tool); m != nil && strings.HasPrefix(asString(m["type"]), searchToolPrefix) {
			continue
		}
		kept = append(kept, tool)
	}
	data["tools"] = append(kept, fn)
	return plan
}

func requestDialect(path string) string {
	switch {
	case strings.Contains(path, "/v1/messages"):
		return "anthropic"
	case strings.Contains(path, "/v1/responses"):
		return "responses"
	case strings.Contains(path, "/v1/chat/completions"):
		return "openai"
	}
	return ""
}

// --- verdict cache ------------------------------------------------------------

// verdictStore caches (model, gateway) -> verdict with a TTL, JSON file beside
// the proxy state, so an EnMaaS-side vLLM upgrade re-probes when real support
// ships and the strip auto-retires.
type verdictStore struct {
	path string
	mu   sync.Mutex
	seed map[string]verdictEntry
}

type verdictEntry struct {
	Verdict  string `json:"verdict"`
	ProbeAt  int64  `json:"probe_at"`
	HTTPCode int    `json:"http_code,omitempty"`
}

func newVerdictStore(path string) *verdictStore {
	return &verdictStore{path: path}
}

func (v *verdictStore) key(model, gateway string) string {
	return model + "@" + gateway
}

func (v *verdictStore) load() map[string]verdictEntry {
	if v.seed != nil {
		return v.seed
	}
	out := map[string]verdictEntry{}
	if b, err := os.ReadFile(v.path); err == nil {
		_ = json.Unmarshal(b, &out)
	}
	return out
}

// get returns ("", false) when there is no fresh verdict.
func (v *verdictStore) get(model, gateway string) (string, bool) {
	v.mu.Lock()
	defer v.mu.Unlock()
	e, ok := v.load()[v.key(model, gateway)]
	if !ok || time.Since(time.Unix(e.ProbeAt, 0)) > shimVerdictTTL {
		return "", false
	}
	return e.Verdict, true
}

func (v *verdictStore) put(model, gateway, verdict string, code int) {
	v.mu.Lock()
	defer v.mu.Unlock()
	all := v.load()
	all[v.key(model, gateway)] = verdictEntry{Verdict: verdict, ProbeAt: time.Now().Unix(), HTTPCode: code}
	if v.seed != nil { // test seeding: stay in memory
		v.seed = all
		return
	}
	_ = os.MkdirAll(filepath.Dir(v.path), 0o700)
	_ = os.WriteFile(v.path, marshal(all), 0o600)
}

// --- canary -------------------------------------------------------------------

// canaryBody builds the forced-choice probe: the hosted tool present, a forced
// choice, and a minimal prompt. It is sent through the proxy's own upstream
// path (bypassing strip/rewrite, since it is built fresh) so it observes the
// gateway + vLLM behavior, not our rewrite.
func canaryBody(path string, data map[string]any) map[string]any {
	probe := map[string]any{
		"model":      asString(data["model"]),
		"max_tokens": 512,
	}
	hosted := hostedSearchTools(data)
	if len(hosted) == 0 {
		hosted = []map[string]any{{"type": "web_search"}}
	}
	tools := make([]any, 0, len(hosted))
	for _, h := range hosted {
		tools = append(tools, map[string]any{"type": asString(h["type"])})
	}
	probe["tools"] = tools
	if requestDialect(path) == "anthropic" {
		probe["tool_choice"] = map[string]any{"type": "tool", "name": searchToolPrefix}
		probe["messages"] = []any{map[string]any{"role": "user", "content": "current weather in Reykjavik"}}
	} else {
		probe["tool_choice"] = map[string]any{"type": searchToolPrefix}
		probe["input"] = "current weather in Reykjavik"
	}
	return probe
}

// classifyCanary maps the probe answer to a verdict: a search call item means
// native; a 200 without one, or a 400 naming the tool, means ignored (the
// silent-ignore this whole shim exists for); anything else is unknown and
// fails closed to today's strip.
func classifyCanary(status int, body []byte) string {
	if status == http.StatusBadRequest && strings.Contains(strings.ToLower(string(body)), searchToolPrefix) {
		return verdictIgnored
	}
	if status != http.StatusOK {
		return verdictUnknown
	}
	obj, err := decodeObject(body)
	if err != nil {
		return verdictUnknown
	}
	return hasNativeSearchCall(obj)
}

// hasNativeSearchCall reports a hosted search call item in a completed answer:
// server_tool_use/web_search_call in Messages content, web_search_call in
// Responses output.
func hasNativeSearchCall(obj map[string]any) string {
	for _, block := range asList(obj["content"]) {
		if b := asMap(block); b != nil {
			switch asString(b["type"]) {
			case "server_tool_use", "web_search_call":
				if strings.HasPrefix(asString(b["name"]), searchToolPrefix) || asString(b["type"]) == "web_search_call" {
					return verdictNative
				}
			}
		}
	}
	for _, item := range asList(obj["output"]) {
		if m := asMap(item); m != nil && asString(m["type"]) == "web_search_call" {
			return verdictNative
		}
	}
	return verdictIgnored
}

// --- server wiring -------------------------------------------------------------

// engageShim decides per request whether the web-search shim acts. nil means
// today's behavior (strip + note when SearchNudge). A *native* verdict
// suppresses the strip (passthrough); an *ignored* verdict rewrites the hosted
// tool and runs the response-side loop. cfg.isRits stays the fail-closed
// default: unknown verdicts and every decline path fall back to the strip.
func (a *app) engageShim(r *http.Request, path string, data map[string]any) *shimPlan {
	if !a.cfg.SearchShim {
		return nil
	}
	requested := asString(data["model"])
	model := requested
	if _, ok := a.cfg.Aliases[model]; ok {
		model = a.cfg.GLM
	}
	if !a.cfg.isRits(model) {
		return nil
	}
	if len(hostedSearchTools(data)) == 0 || clientOwnsSearchName(data) {
		return nil
	}
	dialect := requestDialect(path)
	if dialect != "anthropic" && dialect != "responses" {
		return nil // chat dialect: no native search block shapes to map
	}
	verdict, fresh := a.verdicts.get(model, a.cfg.BaseURL)
	if !fresh {
		verdict = a.probeVerdict(r, path, data, model)
		a.verdicts.put(model, a.cfg.BaseURL, verdict, 0)
	}
	switch verdict {
	case verdictNative:
		return &shimPlan{Mode: "native", Dialect: dialect, Model: model}
	case verdictIgnored:
		plan := shimRewriteTools(path, data)
		if plan == nil {
			return nil
		}
		plan.Mode = "shim"
		plan.Model = model
		return plan
	}
	return nil // unknown: fail closed to strip + note
}

// probeVerdict runs the forced-choice canary through the proxy's own upstream
// path. Built fresh from the request, it bypasses the strip/rewrite (which is
// exactly why it cannot ride along on the real request: the ordinary path
// frees the forced choice) and measures gateway + vLLM behavior.
func (a *app) probeVerdict(r *http.Request, path string, data map[string]any, model string) string {
	probe := canaryBody(path, data)
	probe["model"] = model
	resp, err := a.upstreamRequest(r.Context(), marshal(probe), a.cfg.BaseURL, path, false)
	if err != nil {
		return verdictUnknown
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	return classifyCanary(resp.StatusCode, b)
}

// degradeShimToStrip undoes the shim rewrite (remove the function tool the
// shim added, free a forced choice naming it) and falls back to today's strip
// + note, e.g. when the deployment turns out to need a translator.
func degradeShimToStrip(cfg *config, path string, data map[string]any) {
	tools := asList(data["tools"])
	kept := make([]any, 0, len(tools))
	for _, tool := range tools {
		if m := asMap(tool); m != nil && asString(m["name"]) == searchToolPrefix &&
			(asString(m["type"]) == "function" || m["type"] == nil) {
			continue
		}
		kept = append(kept, tool)
	}
	if len(kept) != len(tools) {
		if len(kept) == 0 {
			delete(data, "tools")
			delete(data, "tool_choice")
		} else {
			data["tools"] = kept
			if choice := asMap(data["tool_choice"]); choice != nil {
				named := asString(choice["name"])
				if named == "" {
					named = asString(asMap(choice["function"])["name"])
				}
				if named == searchToolPrefix {
					delete(data, "tool_choice")
				}
			}
		}
	}
	removeShimNote(data)
	if cfg.SearchNudge && !searchNotePresent(data) {
		injectSearchNote(cfg, path, data)
	}
}

// serveShim runs the buffered loop and writes the terminal round to the
// client: records prepended, SSE-synthesized for streaming clients.
func (a *app) serveShim(w http.ResponseWriter, r *http.Request, plan *shimPlan, data map[string]any, outBody []byte, base, path string, stream bool, requested, served string, started time.Time) {
	res := a.runShimLoop(r.Context(), plan, data, outBody, base, path)
	info := usageInfo{}
	responseModel := ""
	if obj, err := decodeObject(res.terminal); err == nil {
		info = usageFromJSON(res.terminal)
		responseModel = asString(obj["model"])
	}
	if res.upstreamE != nil {
		msg := "upstream request failed: " + res.upstreamE.Error()
		a.writeDialectError(w, path, http.StatusBadGateway, msg, "")
		a.usage.write(a.event(r, data, requested, served, started, info, false, http.StatusBadGateway, 0, msg, false, 0, "", false, 0, false, "", stream, responseModel, 0))
		return
	}
	if res.status >= 400 {
		a.writeRaw(w, res.status, res.headers, res.terminal)
		a.usage.write(a.event(r, data, requested, served, started, info, false, res.status, res.status, truncate(string(res.terminal), 300), false, 0, "", false, 0, false, "", stream, responseModel, 0))
		return
	}
	if res.status < 400 {
		a.outages.success(served)
	}
	if stream {
		body := synthesizeSSE(plan.Dialect, res.terminal, res.records)
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(body)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		a.usage.write(a.event(r, data, requested, served, started, info, true, http.StatusOK, 0, "", false, 0, "", false, 0, false, "", true, responseModel, 0))
		return
	}
	body := terminalWithRecords(plan.Dialect, res.terminal, res.records)
	a.writeRaw(w, res.status, res.headers, body)
	a.usage.write(a.event(r, data, requested, served, started, info, true, http.StatusOK, 0, "", false, 0, "", false, 0, false, "", false, responseModel, 0))
}

// terminalWithRecords prepends the accumulated native search records to the
// terminal round so clients inspecting search activity see the full trail.
func terminalWithRecords(dialect string, terminal []byte, records []any) []byte {
	if len(records) == 0 {
		return terminal
	}
	obj, err := decodeObject(terminal)
	if err != nil {
		return terminal
	}
	switch dialect {
	case "anthropic":
		obj["content"] = append(append([]any{}, records...), asList(obj["content"])...)
	case "responses":
		obj["output"] = append(append([]any{}, records...), asList(obj["output"])...)
	}
	return marshal(obj)
}
