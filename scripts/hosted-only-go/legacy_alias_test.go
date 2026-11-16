package main

import (
	"net/http"
	"os"
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

// An id that is an active SLOT is served as itself. rewriteRequestMode expands
// aliases to the primary before it looks at the slots, so a slot pinned to an id
// that is still in the default alias list (Muse as the fallback while it is the
// retired-alias default) would silently answer from GLM (2026-11-16 review).
func TestSlotIdsNeverAlsoBecomeAliases(t *testing.T) {
	const muse = "rits/meta-models/Muse-Spark-Open-816B-A42B-NVFP4"
	t.Setenv("HOSTED_ONLY_DEEPSEEK_MODEL", muse)
	cfg := loadConfig("claude", "4148", t.TempDir())
	if _, ok := cfg.Aliases[muse]; ok {
		t.Fatalf("a slot id must not also be an alias: %v", cfg.Aliases)
	}
	if _, ok := cfg.Aliases["claude-sonnet-5-5"]; !ok {
		t.Fatalf("the other default aliases stay: %v", cfg.Aliases)
	}

	h := newProxyHarness(t, 200, `{"id":"m","type":"message","role":"assistant","model":"x","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}`, func(c *config) {
		c.GLM, c.DeepSeek, c.Aliases = cfg.GLM, cfg.DeepSeek, cfg.Aliases
	})
	if rec := h.messages(muse); rec.Code != http.StatusOK {
		t.Fatalf("the fallback slot must be served: %d %s", rec.Code, rec.Body.String())
	}
	if h.count(muse) != 1 || h.count(cfg.GLM) != 0 {
		t.Fatalf("a text request for the Muse slot must reach Muse, not collapse onto the primary: muse=%d primary=%d",
			h.count(muse), h.count(cfg.GLM))
	}
}

// With no slot using it, the retired Muse id stays an alias of the primary.
func TestRetiredMuseStaysAnAliasWhenNoSlotUsesIt(t *testing.T) {
	const muse = "rits/meta-models/Muse-Spark-Open-816B-A42B-NVFP4"
	cfg := loadConfig("claude", "4148", t.TempDir())
	if _, ok := cfg.Aliases[muse]; !ok {
		t.Fatalf("the retired Muse id must stay an alias by default: %v", cfg.Aliases)
	}
}

// An alias list the launcher filtered down to nothing is forwarded as an EMPTY
// HOSTED_ONLY_ALIAS_MODELS. That means "no aliases", not "unset": otherwise the
// child serves the defaults while the generated config and fingerprint list none
// (2026-11-16 review).
func TestEmptyAliasKnobMeansNoAliasesNotTheDefault(t *testing.T) {
	t.Setenv("HOSTED_ONLY_ALIAS_MODELS", "")
	if cfg := loadConfig("claude", "4148", t.TempDir()); len(cfg.Aliases) != 0 {
		t.Fatalf("a set-but-empty alias knob must serve no aliases: %v", cfg.Aliases)
	}
	os.Unsetenv("HOSTED_ONLY_ALIAS_MODELS")
	if cfg := loadConfig("claude", "4148", t.TempDir()); len(cfg.Aliases) == 0 {
		t.Fatal("an unset alias knob keeps the per-flavor default")
	}
	t.Setenv("GLM_HYBRID_ALIAS_MODELS", "")
	if cfg := loadConfig("claude", "4148", t.TempDir()); len(cfg.Aliases) != 0 {
		t.Fatalf("the retired name behaves the same: %v", cfg.Aliases)
	}
}
