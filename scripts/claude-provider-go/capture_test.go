package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var captureBin string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "claude-provider-test-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer os.RemoveAll(dir)
	out, err := exec.Command("go", "build", "-o", dir+"/claude-provider", ".").CombinedOutput()
	if err != nil {
		fmt.Fprintf(os.Stderr, "go build: %v: %s\n", err, out)
		os.Exit(1)
	}
	captureBin = dir + "/claude-provider"
	os.Exit(m.Run())
}

func captureBinary(t *testing.T) string {
	t.Helper()
	if captureBin == "" {
		t.Fatal("test binary was not built")
	}
	return captureBin
}

func runCaptureBinary(t *testing.T, binary, stdin string) (int, *profile, []byte) {
	t.Helper()
	destination := filepath.Join(t.TempDir(), "profile.json")
	cmd := exec.Command(binary, "--capture", destination)
	cmd.Stdin = strings.NewReader(stdin)
	errText := &strings.Builder{}
	cmd.Stderr = errText
	err := cmd.Run()
	code := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			code = exitErr.ExitCode()
		} else {
			t.Fatalf("run: %v", err)
		}
	}
	if code != 0 {
		return code, nil, []byte(errText.String())
	}
	body, err := os.ReadFile(destination)
	if err != nil {
		t.Fatalf("profile missing: %v", err)
	}
	var p profile
	if err := json.Unmarshal(body, &p); err != nil {
		t.Fatalf("profile json: %v", err)
	}
	return 0, &p, body
}

func nulArgs(args ...string) string {
	return strings.Join(args, "\x00") + "\x00"
}

func TestCaptureMergesSettingsAndPinsTransport(t *testing.T) {
	t.Setenv("ANTHROPIC_BASE_URL", "http://127.0.0.1:4411/copilot")
	t.Setenv("ANTHROPIC_AUTH_TOKEN", "fixture-local-token")
	t.Setenv("ANTHROPIC_DEFAULT_SONNET_MODEL", "copilot-sonnet")
	t.Setenv("CLAUDE_CODE_USE_VERTEX", "1")
	t.Setenv("ENMAAS_API_KEY", "fixture-upstream-key")
	t.Setenv("OPENAI_API_KEY", "fixture-upstream-key")
	t.Setenv("CLAUDE_PROVIDER_ROOT", "/leak/attempt")

	code, p, _ := runCaptureBinary(t, captureBinary(t), nulArgs(
		"--model", "t3-sonnet", "--resume", "session with spaces", "--", "literal $argument"))
	if code != 0 {
		t.Fatalf("capture failed: %s", p)
	}
	// Tier resolved, everything else forwarded verbatim including "--".
	want := []string{"--model", "copilot-sonnet", "--resume", "session with spaces", "--", "literal $argument"}
	if strings.Join(p.Args, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("args: %v", p.Args)
	}
	// The wrapper transport wins over USE_* envs.
	if p.Env["ANTHROPIC_BASE_URL"] != "http://127.0.0.1:4411/copilot" {
		t.Fatalf("transport base url: %q", p.Env["ANTHROPIC_BASE_URL"])
	}
	if p.Env["CLAUDE_CODE_USE_VERTEX"] != "0" || p.Env["CLAUDE_CODE_USE_BEDROCK"] != "0" || p.Env["CLAUDE_CODE_USE_FOUNDRY"] != "0" {
		t.Fatalf("use-* pins: %v", p.Env)
	}
	if p.Env["ANTHROPIC_API_KEY"] != "" {
		t.Fatalf("api key must be empty: %q", p.Env["ANTHROPIC_API_KEY"])
	}
	// Upstream keys and bridge bookkeeping stay out of the Claude child.
	if _, leaked := p.Env["ENMAAS_API_KEY"]; leaked {
		t.Fatal("ENMAAS_API_KEY leaked into the profile env")
	}
	if _, leaked := p.Env["OPENAI_API_KEY"]; leaked {
		t.Fatal("OPENAI_API_KEY leaked into the profile env")
	}
	if _, leaked := p.Env["CLAUDE_PROVIDER_ROOT"]; leaked {
		t.Fatal("CLAUDE_PROVIDER_* leaked into the profile env")
	}
	if p.Tiers["t3-sonnet"] != "copilot-sonnet" {
		t.Fatalf("tiers: %v", p.Tiers)
	}
}

func TestCaptureSettingsMergeAndEnvOverride(t *testing.T) {
	settingsFile := filepath.Join(t.TempDir(), "caller.json")
	if err := os.WriteFile(settingsFile, []byte(`{"sdk":"file","env":{"KEEP":"yes","ANTHROPIC_AUTH_TOKEN":"wrong"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ANTHROPIC_AUTH_TOKEN", "fixture-local-token")
	t.Setenv("ANTHROPIC_DEFAULT_OPUS_MODEL", "openai-opus")

	code, p, _ := runCaptureBinary(t, captureBinary(t), nulArgs(
		"--settings", `{"sdk":true,"env":{"KEEP":"yes","ANTHROPIC_AUTH_TOKEN":"wrong"}}`,
		"--settings="+settingsFile, "--model=t3-opus"))
	if code != 0 {
		t.Fatalf("capture failed")
	}
	if p.Args[0] != "--model=openai-opus" {
		t.Fatalf("args: %v", p.Args)
	}
	env := p.Settings["env"].(map[string]any)
	if env["KEEP"] != "yes" || env["ANTHROPIC_AUTH_TOKEN"] != "fixture-local-token" {
		t.Fatalf("settings env merge: %v", env)
	}
	if p.Settings["sdk"] != "file" { // later --settings wins
		t.Fatalf("settings precedence: %v", p.Settings)
	}
}

func TestCaptureUnavailableTierFails(t *testing.T) {
	t.Setenv("ANTHROPIC_DEFAULT_HAIKU_MODEL", "") // unset-equivalent
	code, _, stderr := runCaptureBinary(t, captureBinary(t), nulArgs("--model", "t3-haiku"))
	if code == 0 {
		t.Fatal("an unavailable tier must fail the launch")
	}
	if !strings.Contains(string(stderr), "requested tier is unavailable") {
		t.Fatalf("stderr: %s", stderr)
	}
}

func TestCaptureMissingSettingsValueFails(t *testing.T) {
	code, _, stderr := runCaptureBinary(t, captureBinary(t), nulArgs("--settings"))
	if code == 0 {
		t.Fatal("a dangling --settings must fail")
	}
	// The value never appears in the error output.
	if strings.Contains(string(stderr), "sensitive") {
		t.Fatalf("stderr leaked: %s", stderr)
	}
}

func TestCatalogCache(t *testing.T) {
	bin := captureBinary(t)
	dir := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", dir)
	identity := strings.Repeat("a", 64)

	write := exec.Command(bin, "--catalog-write", identity)
	write.Stdin = strings.NewReader(`{"data":[{"id":"fixture-model"}]}`)
	if err := write.Run(); err != nil {
		t.Fatalf("catalog write: %v", err)
	}
	info, err := os.Stat(filepath.Join(dir, "claude-provider", identity+".json"))
	if err != nil {
		t.Fatalf("cache file: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("cache mode: %v", info.Mode())
	}
	read := exec.Command(bin, "--catalog-read", identity)
	out, err := read.Output()
	if err != nil {
		t.Fatalf("catalog read: %v", err)
	}
	if !strings.Contains(string(out), "fixture-model") {
		t.Fatalf("catalog content: %s", out)
	}
	// Unknown identity: miss (rc 3).
	if err := exec.Command(bin, "--catalog-read", strings.Repeat("b", 64)).Run(); err == nil {
		t.Fatal("unknown identity must be a miss")
	} else if exitErr, ok := err.(*exec.ExitError); !ok || exitErr.ExitCode() != 3 {
		t.Fatalf("unknown identity rc: %v", err)
	}
	// Stale cache: miss (rc 3).
	stale := time.Now().Add(-7 * time.Hour)
	_ = os.Chtimes(filepath.Join(dir, "claude-provider", identity+".json"), stale, stale)
	if err := exec.Command(bin, "--catalog-read", identity).Run(); err == nil {
		t.Fatal("stale cache must be a miss")
	} else if exitErr, ok := err.(*exec.ExitError); !ok || exitErr.ExitCode() != 3 {
		t.Fatalf("stale rc: %v", err)
	}
	// A bad identity is refused outright.
	if err := exec.Command(bin, "--catalog-read", "nothex").Run(); err == nil {
		t.Fatal("invalid identity accepted")
	}
}
