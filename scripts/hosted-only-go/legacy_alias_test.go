package main

import (
	"net/http"
	"testing"
)

// A model id the fleet used to serve (GLM 5.3, which left the hosted-only pair
// on 2026-11-14) must keep working for sessions that stored it: the cost guard
// answers 400 "Invalid model name" for any id outside the pair, so the launcher
// registers it as a legacy alias that the primary slot serves. The usage log
// keeps requested vs served visible.
func TestLegacyModelAliasIsServedByThePrimarySlot(t *testing.T) {
	const legacy = "rits/zai-org/glm-5-3"
	h := newProxyHarness(t, 200, `{"id":"m","type":"message","role":"assistant","model":"x","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}`, func(c *config) {
		// the fleet's pair since the swap (the launcher always passes these)
		c.GLM, c.DeepSeek = "rits/deepseek-ai/DeepSeek-V4.1-Flash-1017", "rits/meta-models/Muse-Spark-Open-816B-A42B-NVFP4"
		c.Aliases = map[string]struct{}{legacy: {}}
	})
	rec := h.messages(legacy)
	if rec.Code != http.StatusOK {
		t.Fatalf("a legacy alias must be served, not refused by the cost guard: %d %s", rec.Code, rec.Body.String())
	}
	if h.count(legacy) != 0 || h.count(h.app.cfg.GLM) != 1 {
		t.Fatalf("the upstream must receive the PRIMARY slot's id, not the legacy one: legacy=%d primary=%d",
			h.count(legacy), h.count(h.app.cfg.GLM))
	}
}

// Without the alias the same id is refused: pins down why the launcher default
// must carry it (and that an unrelated model id still hits the cost guard).
func TestUnregisteredModelStillHitsTheCostGuard(t *testing.T) {
	h := newProxyHarness(t, 200, `{}`, func(c *config) {
		c.GLM, c.DeepSeek = "rits/deepseek-ai/DeepSeek-V4.1-Flash-1017", "rits/meta-models/Muse-Spark-Open-816B-A42B-NVFP4"
		c.Aliases = nil // the claude default carries the retired id; drop it here
	})
	rec := h.messages("rits/zai-org/glm-5-3")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("an id outside the pair and aliases must be refused: %d %s", rec.Code, rec.Body.String())
	}
}
