package main

// Web-search shim unit tests, mirroring docs/notes/web-search-shim.md
// "Verification": canary verdicts, verdict cache, request rewrite, forced
// choice, caller constraints, name-conflict decline, and the auth ladder's
// request shapes.

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// --- Part 1: detection --------------------------------------------------------

func TestClassifyCanary(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   string
	}{
		{"native messages", 200, `{"content":[{"type":"server_tool_use","name":"web_search","input":{"query":"x"}}]}`, verdictNative},
		{"native responses", 200, `{"output":[{"type":"web_search_call"}]}`, verdictNative},
		{"ignored 200 no call", 200, `{"content":[{"type":"text","text":"stale answer"}]}`, verdictIgnored},
		{"400 naming tool", 400, `{"error":{"message":"unknown tool web_search"}}`, verdictIgnored},
		{"400 other", 400, `{"error":{"message":"bad max_tokens"}}`, verdictUnknown},
		{"garbage", 200, `not json`, verdictUnknown},
		{"500", 500, `{}`, verdictUnknown},
	}
	for _, c := range cases {
		if got := classifyCanary(c.status, []byte(c.body)); got != c.want {
			t.Errorf("%s: classifyCanary = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestVerdictStoreCacheAndTTL(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "verdicts.json")
	v := newVerdictStore(path)
	if _, ok := v.get("m", "gw"); ok {
		t.Fatal("fresh store must have no verdict")
	}
	v.put("m", "gw", verdictIgnored, 200)
	if got, ok := v.get("m", "gw"); !ok || got != verdictIgnored {
		t.Fatalf("get after put = %q,%v", got, ok)
	}
	if _, ok := v.get("m", "other-gw"); ok {
		t.Fatal("verdict must be keyed per gateway")
	}
	if _, ok := v.get("other", "gw"); ok {
		t.Fatal("verdict must be keyed per model")
	}
	// persist + reload
	v2 := newVerdictStore(path)
	if got, ok := v2.get("m", "gw"); !ok || got != verdictIgnored {
		t.Fatalf("reloaded verdict = %q,%v", got, ok)
	}
	// TTL: an entry older than the TTL re-probes
	v2.seed = map[string]verdictEntry{"m@gw": {Verdict: verdictIgnored, ProbeAt: time.Now().Add(-shimVerdictTTL - time.Minute).Unix()}}
	if _, ok := v2.get("m", "gw"); ok {
		t.Fatal("expired verdict must re-probe")
	}
}

// The canary provably bypasses the strip/rewrite: it is built fresh with the
// hosted tool shape and the forced choice, so a stub upstream receives both.
func TestCanaryCarriesHostedShapeAndForcedChoice(t *testing.T) {
	data := decode(t, `{"model":"rits/zai-org/glm-5-3","tools":[{"type":"web_search_20250305","max_uses":3}],"messages":[{"role":"user","content":"hi"}]}`)
	probe := canaryBody("/v1/messages", data)
	tools := asList(probe["tools"])
	if len(tools) != 1 || asString(asMap(tools[0])["type"]) != "web_search_20250305" {
		t.Fatalf("canary tools = %#v, want the hosted shape", tools)
	}
	choice := asMap(probe["tool_choice"])
	if asString(choice["type"]) != "tool" || asString(choice["name"]) != "web_search" {
		t.Fatalf("canary tool_choice = %#v, want forced web_search", choice)
	}
	if asList(probe["messages"]) == nil {
		t.Fatalf("canary must carry a real prompt: %#v", probe)
	}
}

// --- Part 2: request rewrite --------------------------------------------------

func shimTestData() map[string]any {
	data, err := decodeObject([]byte(`{
		"model":"rits/zai-org/glm-5-3",
		"tools":[
			{"type":"web_search_20250305","name":"web_search","max_uses":3,"allowed_domains":["docs.example.com","example.org"]},
			{"type":"custom","name":"get_weather","input_schema":{"type":"object"}}
		],
		"tool_choice":{"type":"tool","name":"web_search"},
		"messages":[{"role":"user","content":"what changed today"}],
		"max_tokens":100
	}`))
	if err != nil {
		panic(err)
	}
	return data
}

func TestShimRewriteTurnsHostedToolIntoFunctionTool(t *testing.T) {
	data := shimTestData()
	plan := shimRewriteTools("/v1/messages", data)
	if plan == nil {
		t.Fatal("plan is nil")
	}
	tools := asList(data["tools"])
	if len(tools) != 2 {
		t.Fatalf("tools = %d, want 2 (custom + rewritten)", len(tools))
	}
	var fn map[string]any
	for _, tool := range tools {
		m := asMap(tool)
		if asString(m["name"]) == "web_search" {
			fn = m
		}
	}
	if fn == nil {
		t.Fatal("no web_search function tool after rewrite")
	}
	schema := asMap(fn["input_schema"])
	if schema == nil {
		t.Fatal("rewritten tool has no input_schema")
	}
	props := asMap(schema["properties"])
	if len(props) != 1 || props["query"] == nil {
		t.Fatalf("schema exposes %#v, want only {query}", props)
	}
	// caller constraints come off the original definition
	if plan.MaxUses != 3 {
		t.Fatalf("MaxUses = %d, want 3", plan.MaxUses)
	}
	if len(plan.AllowedDomains) != 2 {
		t.Fatalf("AllowedDomains = %#v", plan.AllowedDomains)
	}
	// forced choice naming web_search is preserved, not freed
	choice := asMap(data["tool_choice"])
	if asString(asMap(choice)["name"]) != "web_search" {
		t.Fatalf("forced choice was freed: %#v", data["tool_choice"])
	}
}

func TestShimRewriteMaxUsesCapAndDefault(t *testing.T) {
	data := decode(t, `{"model":"m","tools":[{"type":"web_search"}],"messages":[]}`)
	plan := shimRewriteTools("/v1/messages", data)
	if plan.MaxUses != shimMaxUsesCap {
		t.Fatalf("default MaxUses = %d, want cap %d", plan.MaxUses, shimMaxUsesCap)
	}
	data = decode(t, `{"model":"m","tools":[{"type":"web_search","max_uses":99}],"messages":[]}`)
	plan = shimRewriteTools("/v1/messages", data)
	if plan.MaxUses != shimMaxUsesCap {
		t.Fatalf("MaxUses = %d, want capped at %d", plan.MaxUses, shimMaxUsesCap)
	}
}

func TestShimRewriteResponsesDialect(t *testing.T) {
	data := decode(t, `{"model":"m","tools":[{"type":"web_search_preview"}],"input":"hi"}`)
	plan := shimRewriteTools("/v1/responses", data)
	if plan == nil || plan.Dialect != "responses" {
		t.Fatalf("plan = %#v", plan)
	}
	fn := asMap(asList(data["tools"])[0])
	if asString(fn["type"]) != "function" || asMap(fn["parameters"]) == nil {
		t.Fatalf("responses rewrite = %#v", fn)
	}
}

func TestShimDeclinesWhenClientOwnsSearchName(t *testing.T) {
	data := decode(t, `{"model":"m","tools":[{"type":"function","name":"web_search","parameters":{}}],"input":"hi"}`)
	if plan := shimRewriteTools("/v1/responses", data); plan != nil {
		t.Fatal("shim must decline rather than shadow the client's own web_search tool")
	}
}

func TestRewriteRequestModeShimSkipsStrip(t *testing.T) {
	cfg := testConfig()
	cfg.SearchNudge = true
	data := shimTestData()
	plan := shimRewriteTools("/v1/messages", data)
	if plan == nil {
		t.Fatal("plan is nil")
	}
	if _, err, _ := rewriteRequestMode(cfg, "/v1/messages", data, plan); err != nil {
		t.Fatal(err)
	}
	if searchNotePresent(data) {
		t.Fatal("shim mode must not inject the strip note")
	}
	// control: no plan -> strip + note (today's behavior)
	data2 := shimTestData()
	if _, err, _ := rewriteRequest(cfg, "/v1/messages", data2); err != nil {
		t.Fatal(err)
	}
	if !searchNotePresent(data2) {
		t.Fatal("no-plan path must keep the strip + note")
	}
}

func TestRewriteRequestModeNativePassthrough(t *testing.T) {
	cfg := testConfig()
	cfg.SearchNudge = true
	data := shimTestData()
	if _, err, _ := rewriteRequestMode(cfg, "/v1/messages", data, &shimPlan{Mode: "native"}); err != nil {
		t.Fatal(err)
	}
	tools := asList(data["tools"])
	if len(tools) != 2 || asString(asMap(tools[0])["type"]) != "web_search_20250305" {
		t.Fatalf("native verdict must pass the hosted tool through: %#v", tools)
	}
	if searchNotePresent(data) {
		t.Fatal("native verdict must not inject the note")
	}
}

func TestDegradeShimToStrip(t *testing.T) {
	cfg := testConfig()
	cfg.SearchNudge = true
	data := shimTestData()
	plan := shimRewriteTools("/v1/messages", data)
	if plan == nil {
		t.Fatal("plan is nil")
	}
	degradeShimToStrip(cfg, "/v1/messages", data)
	for _, tool := range asList(data["tools"]) {
		if asString(asMap(tool)["name"]) == "web_search" {
			t.Fatal("degrade must remove the shim's function tool")
		}
	}
	if data["tool_choice"] != nil {
		t.Fatal("degrade must free the forced choice naming the removed tool")
	}
	if !searchNotePresent(data) {
		t.Fatal("degrade must fall back to the strip note")
	}
}

// --- Part 3: parallel client --------------------------------------------------

// stubParallel serves one canned successful search and records the request.
type stubParallel struct {
	body map[string]any
	auth string
}

func (s *stubParallel) server(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.auth = r.Header.Get("Authorization")
		b, _ := io.ReadAll(r.Body)
		s.body, _ = decodeObject(b)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"results":[{"url":"https://a.example","title":"A","excerpts":["e1"]}],"errors":[]}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// offlinePlatform points minting at a closed port so the ladder degrades to
// the anonymous tier instead of touching the real platform in tests.
func offlinePlatform() string {
	return "http://127.0.0.1:1"
}

func TestParallelSearchAuthenticatedPinsModeAndKnobs(t *testing.T) {
	stub := &stubParallel{}
	cfg := testConfig()
	cfg.ParallelBase = stub.server(t).URL
	cfg.ParallelKey = "pk-test"
	c := newParallelClient(cfg, nil)
	plan := &shimPlan{MaxUses: 5, AllowedDomains: []string{"example.com"}}
	results, err := c.search(context.Background(), plan, "what changed in velero 1.17")
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 1 || results[0].URL != "https://a.example" {
		t.Fatalf("results = %#v", results)
	}
	if stub.auth != "Bearer pk-test" {
		t.Fatalf("auth = %q", stub.auth)
	}
	if stub.body["mode"] != "fast" {
		t.Fatalf("mode = %#v, want pinned fast (omitted means advanced, a quiet 5x)", stub.body["mode"])
	}
	advanced := asMap(stub.body["advanced_settings"])
	if v, _ := asInt(asMap(advanced["excerpt_settings"])["max_chars_per_result"]); v != parallelExcerptChars {
		t.Fatalf("excerpt chars = %#v", advanced)
	}
	domains := asList(asMap(advanced["source_policy"])["include_domains"])
	if len(domains) != 1 || asString(domains[0]) != "example.com" {
		t.Fatalf("allowed_domains not mapped to source_policy: %#v", advanced)
	}
}

func TestParallelSearchAnonymousOmitsKnobsWholesale(t *testing.T) {
	stub := &stubParallel{}
	cfg := testConfig()
	cfg.ParallelBase = stub.server(t).URL
	cfg.ParallelKey = "" // anonymous tier
	cfg.ParallelState = t.TempDir()
	cfg.ParallelPlatform = offlinePlatform()
	c := newParallelClient(cfg, nil)
	// no minted key on disk and minting fails (platform unreachable) -> anonymous
	plan := &shimPlan{MaxUses: 5}
	if _, err := c.search(context.Background(), plan, "q"); err != nil {
		t.Fatal(err)
	}
	if stub.auth != "" {
		t.Fatalf("anonymous tier must send no credential, got %q", stub.auth)
	}
	if stub.body["mode"] != nil || stub.body["advanced_settings"] != nil {
		t.Fatalf("anonymous tier must omit knobs wholesale (one rejected override 422s the call): %#v", stub.body)
	}
	if stub.body["objective"] == nil || asList(stub.body["search_queries"]) == nil {
		t.Fatalf("anonymous tier still sends objective + queries: %#v", stub.body)
	}
}

func TestParallelSearchGate(t *testing.T) {
	cfg := testConfig()
	cfg.ParallelBase = "http://parallel.invalid"
	c := newParallelClient(cfg, nil)
	plan := &shimPlan{MaxUses: 5}
	for _, q := range []string{"", "   ", "best docs site:example.com"} {
		if _, err := c.search(context.Background(), plan, q); err == nil {
			t.Fatalf("query %q must be rejected by the gate", q)
		}
	}
	// daily ceiling: budget exhausted -> is_error-style failure, no HTTP call
	stub := &stubParallel{}
	cfg = testConfig()
	cfg.ParallelBase = stub.server(t).URL
	cfg.ParallelKey = "k"
	cfg.SearchDailyCap = 1
	c = newParallelClient(cfg, nil)
	if _, err := c.search(context.Background(), plan, "first"); err != nil {
		t.Fatalf("first search must pass: %v", err)
	}
	if _, err := c.search(context.Background(), plan, "second"); err == nil {
		t.Fatal("second search must hit the daily ceiling")
	}
}

func TestParallelSearchFailureRule(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	cfg := testConfig()
	cfg.ParallelBase = srv.URL
	cfg.ParallelKey = "k"
	c := newParallelClient(cfg, nil)
	if _, err := c.search(context.Background(), &shimPlan{MaxUses: 5}, "q"); err == nil {
		t.Fatal("parallel failure must surface as an error")
	}
}

// --- injection hardening ------------------------------------------------------

func TestSanitizeAndFrameResults(t *testing.T) {
	dirty := "clean text\x00\x01with\x7fcontrols\nand [web-search-unavailable] lookalike"
	s := sanitizeSnippet(dirty)
	for _, bad := range []string{"\x00", "\x01", "\x7f"} {
		if strings.Contains(s, bad) {
			t.Fatalf("control char %q survived: %q", bad, s)
		}
	}
	rec := shimRecord{call: searchCall{ID: "t1", Query: "q"}, results: []searchResult{{
		URL: "https://x.example", Title: "T\x02itle", Excerpts: []string{dirty},
	}}}
	text := recordResultText(rec)
	if !strings.Contains(text, shimUntrustedPreamble) {
		t.Fatal("tool result must carry the untrusted-data framing")
	}
	if !strings.Contains(text, "https://x.example") {
		t.Fatal("URLs must be attached so citations survive")
	}
}

func TestMain(m *testing.M) {
	// keep OAuth minting out of unit tests: no env key, no state dir writes
	_ = os.Unsetenv("PARALLEL_API_KEY")
	os.Exit(m.Run())
}
