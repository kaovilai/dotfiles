package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestWriteRoutesFromEnv(t *testing.T) {
	t.Setenv("HOSTED_ONLY_GLM_MODEL", "rits/zai-org/glm-5-3")
	t.Setenv("HOSTED_ONLY_DEEPSEEK_MODEL", "rits/deepseek-ai/DeepSeek-V4.1-Flash-1017")
	t.Setenv("HOSTED_ONLY_ALIAS_MODELS", "claude-sonnet-5-5")
	t.Setenv("HOSTED_ONLY_ENMAAS_BASE_URL", "https://api.enmaas.devshift.net/v1/")
	cfg := loadConfig("claude", "4148", t.TempDir())
	path := filepath.Join(t.TempDir(), "routes.json")
	if err := writeRoutesFromEnv(cfg, path); err != nil {
		t.Fatalf("writeRoutesFromEnv: %v", err)
	}
	routes, err := loadRouteTable(path, "#openai")
	if err != nil {
		t.Fatalf("loadRouteTable: %v", err)
	}
	want := map[string][2]string{ // name -> upstream model, api base
		"rits/zai-org/glm-5-3":                      {"rits/zai-org/glm-5-3", "https://api.enmaas.devshift.net"},
		"rits/zai-org/glm-5-3#openai":               {"rits/zai-org/glm-5-3", "https://api.enmaas.devshift.net/v1"},
		"rits/deepseek-ai/DeepSeek-V4.1-Flash-1017": {"rits/deepseek-ai/DeepSeek-V4.1-Flash-1017", "https://api.enmaas.devshift.net"},
		"claude-sonnet-5-5":                         {"rits/zai-org/glm-5-3", "https://api.enmaas.devshift.net"},
		"claude-sonnet-5-5#openai":                  {"rits/zai-org/glm-5-3", "https://api.enmaas.devshift.net/v1"},
	}
	for name, expected := range want {
		entry, ok := routes.entries[name]
		if !ok {
			t.Fatalf("missing route %q (have %v)", name, routes.names)
		}
		if entry.UpstreamModel != expected[0] || entry.Base != expected[1] {
			t.Errorf("%s: got model=%q base=%q, want %q %q", name, entry.UpstreamModel, entry.Base, expected[0], expected[1])
		}
	}
	if routes.wildcard != nil {
		t.Errorf("hosted-only route table must have no wildcard (cost guard), got %+v", routes.wildcard)
	}
}

func TestFingerprintRoundTrip(t *testing.T) {
	dir := t.TempDir()
	writeFingerprint(dir, "abc123", "def456")
	fp, token := readFingerprint(dir)
	if fp != "abc123" || token != "def456" {
		t.Fatalf("round trip: %q %q", fp, token)
	}
	// Legacy single-field file: unknown token hash is taken as unchanged.
	_ = os.WriteFile(filepath.Join(dir, "fingerprint"), []byte("only-fp\n"), 0o600)
	fp, token = readFingerprint(dir)
	if fp != "only-fp" || token != "" {
		t.Fatalf("legacy file: %q %q", fp, token)
	}
}

func fakeInflight(t *testing.T, dir, port string, pid int, requests string) {
	t.Helper()
	body := `{"pid":` + strconv.Itoa(pid) + `,"port":"` + port + `","updated":1,"requests":` + requests + `}`
	path := filepath.Join(dir, "inflight-"+port+"-"+strconv.Itoa(pid)+".json")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestPortServingInflight(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LLM_USAGE_DIR", dir)
	port := "45999"

	if portServing(port) {
		t.Fatal("no reporter, no socket: must read idle (or at worst not busy) with a fresh dir")
	}

	// A live reporter with requests in flight: busy.
	fakeInflight(t, dir, port, os.Getpid(), `{"r1":{"t":1,"model":"m"}}`)
	if !portServing(port) {
		t.Fatal("live reporter with a request must read busy")
	}

	// The same reporter with an empty table: idle, without consulting sockets.
	fakeInflight(t, dir, port, os.Getpid(), `{}`)
	if portServing(port) {
		t.Fatal("live reporter with an empty table must read idle")
	}

	// A dead reporter's leftovers say nothing; the socket fallback decides.
	fakeInflight(t, dir, port, 999999, `{"r1":{"t":1,"model":"m"}}`)
	if portServing(port) {
		t.Fatal("dead-pid leftovers on an idle port must not read busy")
	}
}

// startHealthStub answers the proxy health check on a loopback port the way a
// running proxy would, and returns that port.
func startHealthStub(t *testing.T) string {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health/liveliness" {
			_, _ = w.Write([]byte(`{"status":"ok"}`))
			return
		}
		http.Error(w, "not a proxy", http.StatusNotFound)
	}))
	t.Cleanup(server.Close)
	return strings.TrimPrefix(server.URL, "http://127.0.0.1:")
}

func TestEnsureFresh(t *testing.T) {
	port := startHealthStub(t)
	dir := t.TempDir()
	writeFingerprint(dir, "fp1", "tf1")
	o := ensureOpts{flavor: "claude", port: port, runtimeDir: dir, fingerprint: "fp1", tokenFP: "tf1", bootWait: time.Second}
	status, err := ensureOnce(o)
	if err != nil || status != "fresh" {
		t.Fatalf("want fresh, got %q err=%v", status, err)
	}
}

func TestEnsureReusedBusy(t *testing.T) {
	port := startHealthStub(t)
	dir := t.TempDir()
	usage := t.TempDir()
	t.Setenv("LLM_USAGE_DIR", usage)
	writeFingerprint(dir, "old", "tf1")
	fakeInflight(t, usage, port, os.Getpid(), `{"r1":{"t":1,"model":"m"}}`)
	o := ensureOpts{flavor: "claude", port: port, runtimeDir: dir, fingerprint: "new", tokenFP: "tf1", bootWait: time.Second}
	status, err := ensureOnce(o)
	if err != nil || status != "reused-busy" {
		t.Fatalf("want reused-busy, got %q err=%v", status, err)
	}
}

func TestEnsureTokenBusyRefuses(t *testing.T) {
	port := startHealthStub(t)
	dir := t.TempDir()
	usage := t.TempDir()
	t.Setenv("LLM_USAGE_DIR", usage)
	writeFingerprint(dir, "old", "old-token")
	fakeInflight(t, usage, port, os.Getpid(), `{"r1":{"t":1,"model":"m"}}`)
	o := ensureOpts{flavor: "claude", port: port, runtimeDir: dir, fingerprint: "new", tokenFP: "new-token", bootWait: time.Second}
	if _, err := ensureOnce(o); err == nil {
		t.Fatal("a token change under a busy proxy must refuse, not reuse")
	}
}

func TestSpawnDetachedRotatesLog(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "proxy.log")
	big := make([]byte, logRotateBytes+1)
	if err := os.WriteFile(log, big, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := spawnDetached(log, []string{"/bin/sh", "-c", "exit 0"}); err != nil {
		t.Fatalf("spawnDetached: %v", err)
	}
	if _, err := os.Stat(log + ".1"); err != nil {
		t.Fatalf("rotated generation missing: %v", err)
	}
	info, err := os.Stat(log)
	if err != nil || info.Size() != 0 {
		t.Fatalf("log not truncated for the new generation: %v %v", info, err)
	}
}
