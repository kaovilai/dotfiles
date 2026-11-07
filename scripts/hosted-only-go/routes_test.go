package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const enmaasTestConfig = `{
  "model_list": [
    {"model_name": "*", "litellm_params": {"model": "openai/*", "api_base": "https://gw/v1"}},
    {"model_name": "claude-x", "litellm_params": {"model": "anthropic/claude-x", "api_base": "https://gw"}},
    {"model_name": "rits/zai-org/glm-5-3", "litellm_params": {"model": "anthropic/rits/zai-org/glm-5-3", "api_base": "https://gw"}},
    {"model_name": "gpt-6", "litellm_params": {"model": "openai/responses/gpt-6", "api_base": "https://gw/v1"}},
    {"model_name": "gpt-6#responses", "litellm_params": {"model": "openai/gpt-6", "api_base": "https://gw/v1"}}
  ],
  "general_settings": {"master_key": "sk-test"}
}`

func testRoutes(t *testing.T) *routeTable {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(enmaasTestConfig), 0o600); err != nil {
		t.Fatal(err)
	}
	table, err := loadRouteTable(path, "")
	if err != nil {
		t.Fatal(err)
	}
	return table
}

func TestRouteResponsesSibling(t *testing.T) {
	table := testRoutes(t)
	entry, upstream, path := table.resolve("gpt-6", "/v1/responses")
	if entry.Name != "gpt-6#responses" || upstream != "gpt-6" || path != "/v1/responses" {
		t.Fatalf("resolve = %#v %q %q", entry, upstream, path)
	}
	if entry.Base != "https://gw/v1" {
		t.Fatalf("base = %q", entry.Base)
	}
}

// A Responses-only model's generated config has a bare responses-dialect entry
// plus an openai-dialect "#responses" sibling. The sibling serves /v1/responses
// only: on chat it must not be selected, or the chat request passes the dialect
// check and is forwarded to an upstream that rejects it instead of getting the
// proxy's actionable 400.
func TestResponsesOnlyModelIsRejectedOnChat(t *testing.T) {
	table := testRoutes(t)
	entry, _, _ := table.resolve("gpt-6", "/v1/chat/completions")
	if entry.Name != "gpt-6" || entry.Dialect != "responses" {
		t.Fatalf("chat must resolve the bare responses deployment, got %#v", entry)
	}
	if msg := dialectMismatch("/v1/chat/completions", entry.Dialect, "gpt-6"); msg == "" {
		t.Fatal("chat to a Responses-only model must be rejected with a 400 message")
	}
	// naming the sibling directly must not bypass the restriction
	entry, _, _ = table.resolve("gpt-6#responses", "/v1/chat/completions")
	if msg := dialectMismatch("/v1/chat/completions", entry.Dialect, "gpt-6#responses"); msg == "" {
		t.Fatal("chat to the explicit #responses sibling must be rejected with a 400 message")
	}
	if msg := dialectMismatch("/v1/responses", entry.Dialect, "gpt-6#responses"); msg != "" {
		t.Fatalf("the explicit sibling on /v1/responses must pass: %s", msg)
	}
	entry, _, path := table.resolve("gpt-6", "/v1/responses")
	if entry.Name != "gpt-6#responses" || path != "/v1/responses" {
		t.Fatalf("the Responses endpoint must still use the sibling: %#v %q", entry, path)
	}
	if msg := dialectMismatch("/v1/responses", entry.Dialect, "gpt-6"); msg != "" {
		t.Fatalf("responses to the sibling must pass: %s", msg)
	}
}

func TestRouteAnthropicModel(t *testing.T) {
	table := testRoutes(t)
	entry, upstream, path := table.resolve("claude-x", "/v1/messages")
	if entry.Dialect != "anthropic" || upstream != "claude-x" || path != "/v1/messages" {
		t.Fatalf("resolve = %#v %q %q", entry, upstream, path)
	}
	if entry.Base != "https://gw" {
		t.Fatalf("base = %q (must be the root, not /v1)", entry.Base)
	}
}

func TestRouteWildcardFallback(t *testing.T) {
	table := testRoutes(t)
	entry, upstream, path := table.resolve("something-new", "/v1/chat/completions")
	if entry.Dialect != "openai" || upstream != "something-new" || path != "/v1/chat/completions" {
		t.Fatalf("resolve = %#v %q %q", entry, upstream, path)
	}
	if !table.known("something-new", "/v1/chat/completions") {
		t.Fatal("wildcard route should make any id known")
	}
	if entry, ok := table.entries["gpt-6"]; !ok || entry.Dialect != "responses" {
		t.Fatalf("gpt-6 should be a responses-dialect deployment: %#v", entry)
	}
}

func TestRouteToken(t *testing.T) {
	table := testRoutes(t)
	if table.token != "sk-test" {
		t.Fatalf("token = %q", table.token)
	}
	if len(table.modelNames()) != 4 {
		t.Fatalf("model names = %v", table.modelNames())
	}
}

func TestMergeDialectSuffix(t *testing.T) {
	cfg := `{"model_list":[
	 {"model_name":"rits/zai-org/glm-5-3","litellm_params":{"model":"anthropic/rits/zai-org/glm-5-3","api_base":"https://gw"}},
	 {"model_name":"rits/zai-org/glm-5-3#openai","litellm_params":{"model":"openai/rits/zai-org/glm-5-3","api_base":"https://gw/v1"}},
	 {"model_name":"claude-sonnet-5-5","litellm_params":{"model":"anthropic/rits/zai-org/glm-5-3","api_base":"https://gw"}}
	],"general_settings":{"master_key":"os.environ/HOSTED_ONLY_PROXY_TOKEN"}}`
	path := filepath.Join(t.TempDir(), "merged.json")
	if err := os.WriteFile(path, []byte(cfg), 0o600); err != nil {
		t.Fatal(err)
	}
	table, err := loadRouteTable(path, "#openai")
	if err != nil {
		t.Fatal(err)
	}
	// /v1/messages: the bare anthropic group.
	entry, upstream, up := table.resolve("rits/zai-org/glm-5-3", "/v1/messages")
	if entry.Dialect != "anthropic" || upstream != "rits/zai-org/glm-5-3" || up != "/v1/messages" {
		t.Fatalf("messages route = %#v %q %q", entry, upstream, up)
	}
	// OpenAI-wire: the #openai sibling, on the deployment's own path.
	entry, _, up = table.resolve("rits/zai-org/glm-5-3", "/v1/chat/completions")
	if entry.Dialect != "openai" || entry.Base != "https://gw/v1" || up != "/v1/chat/completions" {
		t.Fatalf("chat route = %#v %q", entry, up)
	}
	entry, _, up = table.resolve("rits/zai-org/glm-5-3", "/v1/responses")
	if entry.Dialect != "openai" || up != "/v1/responses" {
		t.Fatalf("responses route = %#v %q", entry, up)
	}
	// The alias is served by GLM on the Messages dialect.
	entry, upstream, _ = table.resolve("claude-sonnet-5-5", "/v1/messages")
	if entry.Dialect != "anthropic" || upstream != "rits/zai-org/glm-5-3" {
		t.Fatalf("alias route = %#v %q", entry, upstream)
	}
	// The cost guard: an unserved id is unknown on both endpoints, and the
	// literal os.environ/ token is visible to the caller (main.go ignores it).
	if table.known("gpt-6-luna", "/v1/messages") || table.known("gpt-6-luna", "/v1/chat/completions") {
		t.Fatal("an unregistered model must not be known")
	}
	if table.token != "os.environ/HOSTED_ONLY_PROXY_TOKEN" {
		t.Fatalf("token parsed unexpectedly: %q", table.token)
	}
}

func TestJoinURL(t *testing.T) {
	cases := []struct{ base, path, want string }{
		{"https://gw", "/v1/messages", "https://gw/v1/messages"},
		{"https://gw/v1", "/v1/chat/completions", "https://gw/v1/chat/completions"},
		{"https://gw/v1/", "/v1/responses", "https://gw/v1/responses"},
		{"https://gw", "/v1/chat/completions", "https://gw/v1/chat/completions"},
	}
	for _, tc := range cases {
		if got := joinURL(tc.base, tc.path); got != tc.want {
			t.Fatalf("joinURL(%q, %q) = %q, want %q", tc.base, tc.path, got, tc.want)
		}
	}
}

func TestFlattenAdditionalTools(t *testing.T) {
	data := decode(t, `{"model":"rits/zai-org/glm-5-3","input":[
		{"type":"additional_tools","tools":[
			{"type":"function","name":"a"},
			{"type":"namespace","tools":[{"type":"function","name":"b"},{"type":"local_shell"}]},
			{"type":"local_shell"}]},
		{"role":"user","content":[{"type":"input_text","text":"hi"}]}
	]}`)
	if !flattenAdditionalTools(data) {
		t.Fatal("expected a change")
	}
	tools := asList(data["tools"])
	if len(tools) != 2 {
		t.Fatalf("tools = %#v, want the two function tools", tools)
	}
	input := asList(data["input"])
	if len(input) != 1 || asString(asMap(input[0])["role"]) != "user" {
		t.Fatalf("input = %#v", input)
	}
}

func TestUsageOpenAICacheNotDoubleCounted(t *testing.T) {
	chat := usageFromObject(decode(t, `{"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":80}}}`))
	if chat.In != 20 || chat.CacheRead != 80 || chat.Out != 5 {
		t.Fatalf("chat usage = %#v", chat)
	}
	responses := usageFromObject(decode(t, `{"usage":{"input_tokens":100,"output_tokens":5,"input_tokens_details":{"cached_tokens":80}}}`))
	if responses.In != 20 || responses.CacheRead != 80 {
		t.Fatalf("responses usage = %#v", responses)
	}
	anthropic := usageFromObject(decode(t, `{"usage":{"input_tokens":7,"output_tokens":3,"cache_read_input_tokens":2}}`))
	if anthropic.In != 7 || anthropic.CacheRead != 2 {
		t.Fatalf("anthropic usage = %#v", anthropic)
	}
}

func TestAnthropicExhaustedDimensionWins(t *testing.T) {
	now := time.Now()
	headers := map[string]string{
		"anthropic-ratelimit-requests-reset":     now.Add(5 * time.Second).Format(time.RFC3339),
		"anthropic-ratelimit-requests-remaining": "9",
		"anthropic-ratelimit-tokens-reset":       now.Add(30 * time.Second).Format(time.RFC3339),
		"anthropic-ratelimit-tokens-remaining":   "0",
	}
	info := analyzeLimit(testConfig(), 429, headers, "rate limited", now)
	if got := info.Reset.Sub(now); got < 29*time.Second || got > 31*time.Second {
		t.Fatalf("reset delta = %v, want ~30s (the exhausted tokens dimension)", got)
	}
}

func TestIETFExhaustedPolicyWins(t *testing.T) {
	now := time.Now()
	headers := map[string]string{"ratelimit": `"requests";r=9;t=5, "tokens";r=0;t=120`}
	info := analyzeLimit(testConfig(), 429, headers, "rate limited", now)
	if got := info.Reset.Sub(now); got < 119*time.Second || got > 121*time.Second {
		t.Fatalf("reset delta = %v, want ~120s (the exhausted policy)", got)
	}
}

func TestOutageBackoffUsesKnobs(t *testing.T) {
	cfg := testConfig()
	cfg.OutageBase = 7
	cfg.OutageMax = 30
	a := newApp(cfg)
	now := time.Now()
	if got := a.outageWait("m", now); got != 7 {
		t.Fatalf("first wait = %d, want 7", got)
	}
	if got := a.outageWait("m", now.Add(time.Second)); got != 14 {
		t.Fatalf("second wait = %d, want 14", got)
	}
	if got := a.outageWait("m", now.Add(2*time.Second)); got != 28 {
		t.Fatalf("third wait = %d, want 28", got)
	}
	if got := a.outageWait("m", now.Add(3*time.Second)); got != 30 {
		t.Fatalf("capped wait = %d, want 30", got)
	}
}

func TestDialectMismatchIsRefusedNotForwarded(t *testing.T) {
	cases := []struct {
		path, deployment string
		refused          bool
	}{
		{"/v1/messages", "anthropic", false},
		{"/v1/messages", "openai", true},
		{"/v1/messages", "responses", true},
		{"/v1/chat/completions", "openai", false},
		{"/v1/responses", "responses", false},
		{"/v1/responses", "openai", false},
		{"/v1/chat/completions", "responses", true},
		{"/v1/chat/completions", "anthropic", true},
		{"/v1/responses", "anthropic", true},
	}
	for _, c := range cases {
		msg := dialectMismatch(c.path, c.deployment, "m")
		if (msg != "") != c.refused {
			t.Errorf("%s -> %s: refused=%v, message %q", c.path, c.deployment, c.refused, msg)
		}
		if c.refused && !strings.Contains(msg, "litellm") {
			t.Errorf("the refusal must name the escape hatch: %q", msg)
		}
	}
}
