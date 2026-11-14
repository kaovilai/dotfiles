package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// The launch that started a proxy records the ids it serves; a later reused-busy
// launch reads that record to name the ids the stale proxy will refuse.

func TestServedModelsRoundTrip(t *testing.T) {
	dir := t.TempDir()
	if readServedModels(dir) != nil {
		t.Fatal("no record yet: want nil, not an empty set")
	}
	writeServedModels(dir, []string{"rits/a", "rits/b"})
	served := readServedModels(dir)
	if len(served) != 2 || !served["rits/a"] || !served["rits/b"] {
		t.Fatalf("round trip lost names: %v", served)
	}
	writeServedModels(dir, nil) // nothing to record: leave the file alone
	if len(readServedModels(dir)) != 2 {
		t.Fatal("an empty list must not clear a record")
	}
}

// The hosted-only flavors (claude/codex) get no generated --config: the only
// routes.json on disk belongs to the RUNNING proxy, so the desired pair has to
// come from this process's knobs. Comparing against that file made the check a
// no-op on exactly the flavors a pair swap affects (2026-11-14 review).
func TestMissingServedModelsUsesEnvForHostedOnly(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOSTED_ONLY_GLM_MODEL", "rits/new-primary")
	t.Setenv("HOSTED_ONLY_DEEPSEEK_MODEL", "rits/new-fallback")
	t.Setenv("HOSTED_ONLY_ALIAS_MODELS", "claude-sonnet-5-5")
	writeServedModels(dir, []string{"rits/old-primary", "rits/old-fallback", "claude-sonnet-5-5"})

	want := []string{"rits/new-primary", "rits/new-fallback"} // the alias is unchanged
	if got := missingServedModels(dir, "claude", "4148", ""); !reflect.DeepEqual(got, want) {
		t.Fatalf("hosted-only must compare against the knobs: got %v want %v", got, want)
	}
	// Once the record matches the knobs, nothing is missing.
	writeServedModels(dir, append(want, "claude-sonnet-5-5"))
	if got := missingServedModels(dir, "claude", "4148", ""); len(got) != 0 {
		t.Fatalf("a proxy serving the current pair reports nothing missing: %v", got)
	}
}

// Route-table flavors are handed their generated config by the launcher; that
// file is the desired pair.
func TestMissingServedModelsReadsTheGivenRouteTable(t *testing.T) {
	dir := t.TempDir()
	config := filepath.Join(t.TempDir(), "routes.json")
	doc := `{"model_list":[
	 {"model_name":"rits/x","litellm_params":{"model":"anthropic/rits/x","api_base":"http://127.0.0.1:1"}},
	 {"model_name":"rits/y","litellm_params":{"model":"anthropic/rits/y","api_base":"http://127.0.0.1:1"}}]}`
	if err := os.WriteFile(config, []byte(doc), 0o600); err != nil {
		t.Fatal(err)
	}
	writeServedModels(dir, []string{"rits/x"})
	if got := missingServedModels(dir, "enmaas", "4146", config); !reflect.DeepEqual(got, []string{"rits/y"}) {
		t.Fatalf("want the route-table id the record lacks, got %v", got)
	}
}

// A launch that starts replacing the proxy, and a stop, both invalidate the
// stamps the old proxy owned: the boot wait can time out and leave a detached
// child that binds later with nobody recording its pair, so a stale record must
// never outlive it (2026-11-14 review).
func TestClearProxyStamps(t *testing.T) {
	dir := t.TempDir()
	writeServedModels(dir, []string{"rits/a"})
	writeFingerprint(dir, "fp", "token")
	clearProxyStamps(dir)
	if readServedModels(dir) != nil {
		t.Fatal("the served-models record must be gone")
	}
	if _, err := os.Stat(filepath.Join(dir, "fingerprint")); !os.IsNotExist(err) {
		t.Fatalf("the fingerprint must be gone: %v", err)
	}
}

// servedModelNames folds the "#openai" sibling onto its bare group and drops the
// wildcard, which serves anything.
func TestServedModelNamesFoldsDialectSiblings(t *testing.T) {
	config := filepath.Join(t.TempDir(), "routes.json")
	doc := `{"model_list":[
	 {"model_name":"rits/x","litellm_params":{"model":"anthropic/rits/x","api_base":"http://127.0.0.1:1"}},
	 {"model_name":"rits/x#openai","litellm_params":{"model":"openai/rits/x","api_base":"http://127.0.0.1:1/v1"}},
	 {"model_name":"*","litellm_params":{"model":"openai/*","api_base":"http://127.0.0.1:1/v1"}}]}`
	if err := os.WriteFile(config, []byte(doc), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := servedModelNames(config, "claude"); !reflect.DeepEqual(got, []string{"rits/x"}) {
		t.Fatalf("want the bare group only, got %v", got)
	}
}
