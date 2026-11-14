package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The web-search decision is per rits/ id, not per slot: every model the proxy
// serves gets exactly one of the two behaviors — the Parallel-injected function
// tool (shim on, upstream ignores the hosted tool) or the strip + "no web
// search" note (shim off, or no verdict). Muse Spark, the fallback slot since
// the 2026-11-14 pair swap, is a rits/ id like the primary, so it is covered by
// the same path; a Claude id behind the gateway keeps its native search.
func TestSearchHandlingCoversEveryServedModel(t *testing.T) {
	a, cfg := shimApp(t, &stubUpstream{t: t, dialect: "anthropic"}, true)
	cfg.Aliases = map[string]struct{}{
		"claude-sonnet-5-5":    {},
		"rits/zai-org/glm-5-3": {}, // the retired id, served by the primary slot
	}
	// Clone the pair so the test does not depend on the launcher defaults.
	cfg.GLM = "rits/deepseek-ai/DeepSeek-V4.1-Flash-1017"
	cfg.DeepSeek = "rits/meta-models/Muse-Spark-Open-816B-A42B-NVFP4"

	hosted := []string{cfg.GLM, cfg.DeepSeek, "rits/zai-org/glm-5-3", "claude-sonnet-5-5"}

	off := *cfg
	off.SearchShim = false
	for _, model := range hosted {
		t.Run("strip/"+model, func(t *testing.T) {
			data := shimTestData()
			data["model"] = model
			if _, reqErr, _ := rewriteRequest(&off, "/v1/messages", data); reqErr != nil {
				t.Fatalf("refused: %+v", reqErr)
			}
			for _, tool := range asList(data["tools"]) {
				if strings.HasPrefix(asString(asMap(tool)["type"]), searchToolPrefix) {
					t.Fatalf("%s: the hosted tool must be stripped", model)
				}
			}
			if !searchNotePresent(data) {
				t.Fatalf("%s: the no-web-search note must be injected", model)
			}
		})
		t.Run("shim/"+model, func(t *testing.T) {
			served := model
			if _, ok := cfg.Aliases[model]; ok {
				served = cfg.GLM // an alias is served by the primary slot
			}
			seedVerdict(a, served, verdictIgnored)
			data := shimTestData()
			data["model"] = model
			plan := a.engageShim(httptest.NewRequest(http.MethodPost, "/v1/messages", nil), "/v1/messages", data)
			if plan == nil || plan.Mode != "shim" {
				t.Fatalf("%s: the shim must serve every hosted id, got %#v", model, plan)
			}
		})
	}

	// A real Claude model behind the gateway implements (or rejects) search on
	// its own: the workarounds must not touch it.
	t.Run("native claude untouched", func(t *testing.T) {
		data := shimTestData()
		data["model"] = "claude-opus-5-5"
		if _, reqErr, changed := rewriteRequest(&off, "/v1/messages", data); reqErr != nil {
			t.Fatalf("refused: %+v", reqErr)
		} else if changed {
			t.Fatal("a non-rits, non-alias id must be forwarded untouched")
		}
		body := string(marshal(asList(data["tools"])))
		if !strings.Contains(body, "web_search_20250305") || searchNotePresent(data) {
			t.Fatalf("native search tool or note was rewritten: %s", body)
		}
		if plan := a.engageShim(httptest.NewRequest(http.MethodPost, "/v1/messages", nil), "/v1/messages", data); plan != nil {
			t.Fatalf("the shim must not engage for a native-search model: %#v", plan)
		}
	})
}
