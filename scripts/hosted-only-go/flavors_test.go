package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The mlx flavor's route table: one shared model, localhost chat-dialect
// upstream (mlx_lm.server), master_key as the client token.
const mlxTestConfig = `{
  "model_list": [
    {"model_name": "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
     "litellm_params": {"model": "openai/mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
                        "api_base": "http://127.0.0.1:4143/v1"}}
  ],
  "general_settings": {"master_key": "mlx-proxy-local"}
}`

// The openai flavor's route table: a wildcard plus pinned tiers against
// api.openai.com, exactly the shape the LiteLLM config had.
const openaiTestConfig = `{
  "model_list": [
    {"model_name": "*", "litellm_params": {"model": "openai/*", "api_base": "https://api.openai.com/v1"}},
    {"model_name": "gpt-6", "litellm_params": {"model": "openai/gpt-6", "api_base": "https://api.openai.com/v1"}}
  ],
  "general_settings": {"master_key": "openai-proxy-local"}
}`

// The vertex flavor's route table (what _claude_vertex_proxy_write_routes
// emits): anthropic-dialect entries with no api_base (the deployment root
// comes from vertexBaseURL), a "*" wildcard so any Claude id picked in
// /model routes to Vertex, and the dated haiku alias.
const vertexTestConfig = `{
  "model_list": [
    {"model_name": "*", "litellm_params": {"model": "anthropic/*"}},
    {"model_name": "claude-sonnet-5", "litellm_params": {"model": "anthropic/claude-sonnet-5"}},
    {"model_name": "claude-haiku-4-5-20251001", "litellm_params": {"model": "anthropic/claude-haiku-4-5"}}
  ],
  "general_settings": {"master_key": "vertex-proxy-local"}
}`

func loadTestTable(t *testing.T, raw, flavor string) *routeTable {
	t.Helper()
	path := filepath.Join(t.TempDir(), "routes.json")
	if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	table, err := loadRouteTable(path, dialectSuffixFor(flavor))
	if err != nil {
		t.Fatal(err)
	}
	return table
}

func TestRouteTableFlavors(t *testing.T) {
	for _, flavor := range []string{"enmaas", "mlx", "openai", "vertex"} {
		if !routeTableFlavor(flavor) {
			t.Errorf("routeTableFlavor(%q) = false, want true", flavor)
		}
	}
	for _, flavor := range []string{"claude", "codex", ""} {
		if routeTableFlavor(flavor) {
			t.Errorf("routeTableFlavor(%q) = true, want false", flavor)
		}
	}
}

// The single-dialect route-table flavors have no "#openai" siblings, so their
// dialect suffix must default to "" (the merged hosted-only config's "#openai"
// default would make every chat request look for a nonexistent sibling).
func TestDialectSuffixDefaults(t *testing.T) {
	for _, flavor := range []string{"enmaas", "mlx", "openai", "vertex"} {
		t.Setenv("HOSTED_ONLY_DIALECT_SUFFIX", "")
		if got := dialectSuffixFor(flavor); got != "" {
			t.Errorf("dialectSuffixFor(%q) = %q, want \"\"", flavor, got)
		}
	}
	for _, flavor := range []string{"claude", "codex"} {
		t.Setenv("HOSTED_ONLY_DIALECT_SUFFIX", "")
		if got := dialectSuffixFor(flavor); got != "#openai" {
			t.Errorf("dialectSuffixFor(%q) = %q, want #openai", flavor, got)
		}
	}
}

func TestMlxFlavorRoutes(t *testing.T) {
	table := loadTestTable(t, mlxTestConfig, "mlx")
	const model = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
	if !table.known(model, "/v1/messages") {
		t.Fatal("the one shared model must be served on /v1/messages")
	}
	entry, upstream, path := table.resolve(model, "/v1/messages")
	if entry.Dialect != "openai" || upstream != model {
		t.Fatalf("resolve = %#v upstream=%q", entry, upstream)
	}
	if path != "/v1/chat/completions" {
		t.Fatalf("Messages must bridge to chat, path = %q", path)
	}
	if entry.Base != "http://127.0.0.1:4143/v1" {
		t.Fatalf("base = %q", entry.Base)
	}
	// A Messages client bridged to the chat deployment must be translatable
	// (the chatTranslator this flavor runs on).
	if !translatable("/v1/messages", entry.Dialect) {
		t.Fatal("Messages -> chat must be translatable")
	}
}

func TestOpenaiFlavorRoutes(t *testing.T) {
	table := loadTestTable(t, openaiTestConfig, "openai")
	// Pinned tier entry wins over the wildcard.
	entry, upstream, path := table.resolve("gpt-6", "/v1/messages")
	if entry.Name != "gpt-6" || upstream != "gpt-6" || path != "/v1/chat/completions" {
		t.Fatalf("resolve = %#v %q %q", entry, upstream, path)
	}
	// Any id picked in /model routes through the wildcard.
	entry, upstream, path = table.resolve("gpt-6.5-mini", "/v1/messages")
	if entry.Name != "*" || upstream != "gpt-6.5-mini" || path != "/v1/chat/completions" {
		t.Fatalf("wildcard resolve = %#v %q %q", entry, upstream, path)
	}
	if !table.known("gpt-anything", "/v1/messages") {
		t.Fatal("wildcard must make any id known on /v1/messages")
	}
}

func TestVertexFlavorRoutes(t *testing.T) {
	table := loadTestTable(t, vertexTestConfig, "vertex")
	// Pinned entry wins over the wildcard.
	entry, upstream, path := table.resolve("claude-sonnet-5", "/v1/messages")
	if entry.Name != "claude-sonnet-5" || entry.Dialect != "anthropic" || upstream != "claude-sonnet-5" {
		t.Fatalf("resolve = %#v %q", entry, upstream)
	}
	// Anthropic dialect keeps the Messages path; the vertex flavor replaces
	// it per request (vertexPath) since the model id is part of the URL.
	if path != "/v1/messages" {
		t.Fatalf("static path = %q, want /v1/messages (overridden per request)", path)
	}
	// The dated haiku alias maps to the bare backend id.
	_, upstream, _ = table.resolve("claude-haiku-4-5-20251001", "/v1/messages")
	if upstream != "claude-haiku-4-5" {
		t.Fatalf("dated alias upstream = %q", upstream)
	}
	// Any other Claude id picked in /model routes through the wildcard.
	entry, upstream, _ = table.resolve("claude-opus-9", "/v1/messages")
	if entry.Name != "*" || upstream != "claude-opus-9" {
		t.Fatalf("wildcard resolve = %#v %q", entry, upstream)
	}
	// No api_base on vertex rows: the deployment root comes from
	// vertexBaseURL, not the route table.
	if entry.Base != "" {
		t.Fatalf("vertex wildcard base = %q, want empty", entry.Base)
	}
}

func TestVertexPath(t *testing.T) {
	if got := vertexPath("claude-sonnet-5", false); got != "/models/claude-sonnet-5:rawPredict" {
		t.Fatalf("vertexPath non-stream = %q", got)
	}
	if got := vertexPath("claude-sonnet-5", true); got != "/models/claude-sonnet-5:streamRawPredict" {
		t.Fatalf("vertexPath stream = %q", got)
	}
}

func TestVertexBaseURL(t *testing.T) {
	t.Setenv("CLOUD_ML_REGION", "us-east5")
	t.Setenv("ANTHROPIC_VERTEX_PROJECT_ID", "proj-1")
	want := "https://us-east5-aiplatform.googleapis.com/v1/projects/proj-1/locations/us-east5/publishers/anthropic"
	if got := vertexBaseURL(); got != want {
		t.Fatalf("vertexBaseURL = %q", got)
	}
	// The vertex flavor overrides the EnMaaS gateway root.
	cfg := loadConfig("vertex", "4142", "")
	if !cfg.Vertex || cfg.BaseURL != want {
		t.Fatalf("cfg.Vertex=%t BaseURL=%q", cfg.Vertex, cfg.BaseURL)
	}
}

func TestUpstreamKeyKnob(t *testing.T) {
	t.Setenv("ENMAAS_API_KEY", "")
	t.Setenv("HOSTED_ONLY_UPSTREAM_KEY", "sk-openai")
	cfg := loadConfig("openai", "4145", "")
	if cfg.APIKey != "sk-openai" {
		t.Fatalf("APIKey = %q, want the HOSTED_ONLY_UPSTREAM_KEY value", cfg.APIKey)
	}
	// EnMaaS keeps reading ENMAAS_API_KEY when the generic knob is unset.
	t.Setenv("HOSTED_ONLY_UPSTREAM_KEY", "")
	t.Setenv("ENMAAS_API_KEY", "sk-enmaas")
	cfg = loadConfig("enmaas", "4146", "")
	if cfg.APIKey != "sk-enmaas" {
		t.Fatalf("APIKey = %q, want the ENMAAS_API_KEY value", cfg.APIKey)
	}
}

// vertexToken refreshes from the ADC file via the token endpoint, caches the
// answer and reuses it until near expiry.
func TestVertexTokenRefreshAndCache(t *testing.T) {
	refreshes := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		refreshes++
		if err := r.ParseForm(); err != nil {
			t.Errorf("parse form: %v", err)
		}
		if got := r.PostForm.Get("grant_type"); got != "refresh_token" {
			t.Errorf("grant_type = %q", got)
		}
		if got := r.PostForm.Get("refresh_token"); got != "rt-1" {
			t.Errorf("refresh_token = %q", got)
		}
		if got := r.PostForm.Get("scope"); got != vertexTokenScope {
			t.Errorf("scope = %q", got)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"access_token": "at-1", "expires_in": 3600})
	}))
	defer srv.Close()
	old := vertexTokenEndpoint
	vertexTokenEndpoint = srv.URL
	defer func() { vertexTokenEndpoint = old }()

	dir := t.TempDir()
	adc := filepath.Join(dir, "adc.json")
	cred, _ := json.Marshal(adcCredentials{Type: "authorized_user", ClientID: "ci", ClientSecret: "cs", RefreshToken: "rt-1"})
	if err := os.WriteFile(adc, cred, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", adc)

	a := newApp(loadConfig("vertex", "4142", ""))
	tok, err := a.vertexToken(context.Background())
	if err != nil {
		t.Fatalf("vertexToken: %v", err)
	}
	if tok != "at-1" {
		t.Fatalf("token = %q", tok)
	}
	tok, err = a.vertexToken(context.Background())
	if err != nil || tok != "at-1" {
		t.Fatalf("cached token = %q err=%v", tok, err)
	}
	if refreshes != 1 {
		t.Fatalf("refreshes = %d, want 1 (cache must serve the second call)", refreshes)
	}
	// Invalidation forces a fresh draw.
	a.vertexInvalidate()
	if tok, err = a.vertexToken(context.Background()); err != nil || tok != "at-1" {
		t.Fatalf("post-invalidate token = %q err=%v", tok, err)
	}
	if refreshes != 2 {
		t.Fatalf("refreshes = %d, want 2 after invalidation", refreshes)
	}
}

// A non-authorized_user ADC file (service account) is refused with the fix-it
// hint instead of a confusing upstream auth failure.
func TestVertexTokenRejectsUnsupportedADC(t *testing.T) {
	dir := t.TempDir()
	adc := filepath.Join(dir, "adc.json")
	if err := os.WriteFile(adc, []byte(`{"type":"service_account"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", adc)
	a := newApp(loadConfig("vertex", "4142", ""))
	_, err := a.vertexToken(context.Background())
	if err == nil || !strings.Contains(err.Error(), "authorized_user") {
		t.Fatalf("err = %v, want the authorized_user hint", err)
	}
}

// The partner endpoint's body constraints, as LiteLLM's partner route
// applied them: no "model" field, effort dropped for Haiku (Claude Code
// injects output_config everywhere), emptied output_config removed.
func TestSanitizeVertexBody(t *testing.T) {
	data := map[string]any{
		"model":         "claude-sonnet-5",
		"output_config": map[string]any{"effort": "high"},
		"messages":      []any{},
	}
	if !sanitizeVertexBody(data, "claude-sonnet-5") {
		t.Fatal("sonnet with model field must change")
	}
	if _, ok := data["model"]; ok {
		t.Fatal("model must be popped from the body")
	}
	// Sonnet keeps its effort.
	oc := data["output_config"].(map[string]any)
	if oc["effort"] != "high" {
		t.Fatalf("sonnet effort dropped: %#v", oc)
	}

	data = map[string]any{
		"model":         "claude-haiku-4-5",
		"output_config": map[string]any{"effort": "high"},
	}
	if !sanitizeVertexBody(data, "claude-haiku-4-5") {
		t.Fatal("haiku with model field must change")
	}
	if _, ok := data["output_config"]; ok {
		t.Fatal("haiku's emptied output_config must be removed (effort dropped)")
	}

	// A non-dict output_config is dropped, not forwarded malformed.
	data = map[string]any{"output_config": "oops"}
	if !sanitizeVertexBody(data, "claude-sonnet-5") {
		t.Fatal("non-dict output_config must change")
	}
	if _, ok := data["output_config"]; ok {
		t.Fatal("non-dict output_config must be removed")
	}

	// A clean body stays untouched (the verbatim-forward path).
	data = map[string]any{"messages": []any{}, "max_tokens": float64(64)}
	if sanitizeVertexBody(data, "claude-sonnet-5") {
		t.Fatal("clean body must not change")
	}
}

func TestHasToolSearchTool(t *testing.T) {
	if hasToolSearchTool(map[string]any{}) {
		t.Fatal("no tools must be false")
	}
	data := map[string]any{"tools": []any{
		map[string]any{"type": "custom", "name": "bash"},
		map[string]any{"name": "notamap"},
	}}
	if hasToolSearchTool(data) {
		t.Fatal("plain tools must be false")
	}
	data["tools"] = append(data["tools"].([]any), map[string]any{"type": "tool_search_tool_regex_20251119"})
	if !hasToolSearchTool(data) {
		t.Fatal("a tool_search tool must be detected")
	}
}

func TestAddBetaHeader(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "/v1/messages", nil)
	addBetaHeader(r, "tool-search-tool-2025-10-19")
	if got := r.Header.Get("anthropic-beta"); got != "tool-search-tool-2025-10-19" {
		t.Fatalf("beta = %q", got)
	}
	r.Header.Set("anthropic-beta", "prompt-caching-2024-07-31")
	addBetaHeader(r, "tool-search-tool-2025-10-19")
	if got := r.Header.Get("anthropic-beta"); got != "prompt-caching-2024-07-31,tool-search-tool-2025-10-19" {
		t.Fatalf("merged beta = %q", got)
	}
	// Deduplicated.
	addBetaHeader(r, "tool-search-tool-2025-10-19")
	if got := r.Header.Get("anthropic-beta"); got != "prompt-caching-2024-07-31,tool-search-tool-2025-10-19" {
		t.Fatalf("beta after re-add = %q", got)
	}
}
