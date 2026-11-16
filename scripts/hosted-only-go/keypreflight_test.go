package main

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// gatewayAnswering is a fake EnMaaS gateway that answers every request with
// status and hands the test the auth headers the probe sent. The handler runs on
// its own goroutine, so the snapshot travels over a channel (a socket round trip
// is not a happens-before edge the race detector recognises).
func gatewayAnswering(t *testing.T, status int) (*httptest.Server, func() http.Header) {
	t.Helper()
	seen := make(chan http.Header, 8)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case seen <- r.Header.Clone():
		default:
		}
		w.WriteHeader(status)
	}))
	t.Cleanup(server.Close)
	return server, func() http.Header {
		select {
		case h := <-seen:
			return h
		default:
			return nil
		}
	}
}

// A replacement proxy the gateway would answer 401 must be refused before it
// can retire the proxy that is serving (2026-11-16 outage).
func TestCheckUpstreamKeyRejectsOnlyDefiniteAuthFailures(t *testing.T) {
	for _, tc := range []struct {
		status int
		reject bool
	}{
		{http.StatusUnauthorized, true},
		{http.StatusForbidden, false}, // valid key, route not entitled (over the cap) or an ingress/WAF
		{http.StatusFound, false},     // a redirect is not a verdict
		{http.StatusOK, false},
		{http.StatusNotFound, false},            // a gateway without a models route
		{http.StatusTooManyRequests, false},     // quota is not a bad key
		{http.StatusInternalServerError, false}, // an outage must not block a restart
	} {
		server, _ := gatewayAnswering(t, tc.status)
		err := checkUpstreamKey("claude", server.URL, "some-key")
		var keyErr *upstreamKeyError
		if got := errors.As(err, &keyErr); got != tc.reject {
			t.Errorf("status %d: rejected=%v want %v (err=%v)", tc.status, got, tc.reject, err)
		}
		if tc.reject && keyErr.Status != tc.status {
			t.Errorf("status %d: error carries %d", tc.status, keyErr.Status)
		}
	}
}

func TestCheckUpstreamKeyNeverBlocksOnAnUnreachableGatewayOrOtherFlavors(t *testing.T) {
	server, _ := gatewayAnswering(t, http.StatusOK)
	dead := server.URL
	server.Close()
	if err := checkUpstreamKey("claude", dead, "k"); err != nil {
		t.Fatalf("an unreachable gateway must not block a restart: %v", err)
	}
	rejecting, _ := gatewayAnswering(t, http.StatusUnauthorized)
	for _, flavor := range []string{"enmaas", "mlx", "openai", "vertex"} {
		if err := checkUpstreamKey(flavor, rejecting.URL, "k"); err != nil {
			t.Errorf("%s carries its own upstream and key; the EnMaaS probe must not apply: %v", flavor, err)
		}
	}
	if err := checkUpstreamKey("claude", rejecting.URL, ""); err != nil {
		t.Errorf("an empty key is reported by the caller, not probed: %v", err)
	}
}

func TestProbeSendsOneCredentialShapePerRequest(t *testing.T) {
	server, seen := gatewayAnswering(t, http.StatusOK)
	if status := probeUpstreamKey(server.URL, "secret-value"); status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
	got := seen()
	if got.Get("Authorization") != "Bearer secret-value" || got.Get("x-api-key") != "" {
		t.Fatalf("the first probe is the Bearer shape alone: %v", got)
	}
}

// The probe must never follow a redirect: x-api-key would be copied to whatever
// host the 3xx names (the rule _claude_enmaas_discover already states).
func TestProbeNeverFollowsARedirect(t *testing.T) {
	var elsewhereHit atomic.Bool
	elsewhere := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		elsewhereHit.Store(true)
		w.WriteHeader(http.StatusUnauthorized) // a "rejection" nobody asked for
	}))
	t.Cleanup(elsewhere.Close)
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, elsewhere.URL+"/login", http.StatusFound)
	}))
	t.Cleanup(gateway.Close)

	if status := probeUpstreamKey(gateway.URL, "secret-value"); status != http.StatusFound {
		t.Fatalf("the redirect itself is the answer, got %d", status)
	}
	if elsewhereHit.Load() {
		t.Fatal("the key must never be sent to a redirect target")
	}
	if err := checkUpstreamKey("claude", gateway.URL, "secret-value"); err != nil {
		t.Fatalf("a redirect is not a rejection: %v", err)
	}
}

func TestKeyErrorNamesBothKeySources(t *testing.T) {
	msg := (&upstreamKeyError{Status: 401}).Error()
	for _, want := range []string{"ENMAAS_API_KEY", "HOSTED_ONLY_UPSTREAM_KEY"} {
		if !strings.Contains(msg, want) {
			t.Errorf("the message must name %s as a place to fix the key: %q", want, msg)
		}
	}
}

// A kept proxy must still accept the client about to start: a proxy-token change
// in the same launch would hand it a token the old proxy rejects.
func TestTokenCompatible(t *testing.T) {
	if !tokenCompatible("", "new") {
		t.Error("an old record without a token is unknown and taken as unchanged")
	}
	if !tokenCompatible("same", "same") {
		t.Error("matching tokens are compatible")
	}
	if tokenCompatible("old", "new") {
		t.Error("a changed proxy token must not take the keep-running path")
	}
}

// The refusal happens before ANY side effect: the serving proxy's stamps stay,
// no route table is written and nothing is spawned.
func TestStartProxyRefusesARejectedKeyBeforeTouchingAnything(t *testing.T) {
	server, _ := gatewayAnswering(t, http.StatusUnauthorized)
	t.Setenv("ENMAAS_API_KEY", "dead-key")
	t.Setenv("HOSTED_ONLY_ENMAAS_BASE_URL", server.URL)
	dir := t.TempDir()
	writeFingerprint(dir, "old-fp", "old-token")
	writeServedModels(dir, []string{"rits/a"})

	_, err := startProxy(ensureOpts{flavor: "claude", port: "1", runtimeDir: dir, fingerprint: "new", tokenFP: "t"}, []int{os.Getpid()})
	var keyErr *upstreamKeyError
	if !errors.As(err, &keyErr) || keyErr.Status != http.StatusUnauthorized {
		t.Fatalf("want a 401 key error, got %v", err)
	}
	if fp, _ := readFingerprint(dir); fp != "old-fp" {
		t.Fatalf("the serving proxy's fingerprint stamp must survive a refused swap, got %q", fp)
	}
	if len(readServedModels(dir)) != 1 {
		t.Fatal("the serving proxy's served-models stamp must survive a refused swap")
	}
	if _, statErr := os.Stat(filepath.Join(dir, "routes.json")); !os.IsNotExist(statErr) {
		t.Fatalf("no route table may be written for a refused swap: %v", statErr)
	}
}

func TestKeepRunningOnlyForARejectedKeyWithALiveOldListener(t *testing.T) {
	keyErr := &upstreamKeyError{Status: 401}
	alive := []int{os.Getpid()}
	if !keepRunning(keyErr, alive) {
		t.Error("a rejected key with a live old proxy must leave it serving")
	}
	if keepRunning(keyErr, nil) {
		t.Error("with no old proxy there is nothing to keep: the cold start must fail loudly")
	}
	if keepRunning(errors.New("bind failed"), alive) {
		t.Error("any other failure keeps the stop-then-start fallback")
	}
	if keepRunning(nil, alive) {
		t.Error("success is not a reason to keep anything")
	}
}

// captureStderr runs fn and returns what it wrote to os.Stderr.
func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stderr = w
	fn()
	_ = w.Close()
	os.Stderr = old
	buf, _ := io.ReadAll(r)
	return string(buf)
}

// A kept proxy (busy, or key-rejected) is the OLD code: when the same launch
// also changed the pair, a request naming a new id gets the cost guard's 400, so
// the launcher names the ids up front instead of leaving the caller to decode it.
func TestReportPairGapNamesWhatAKeptProxyCannotServe(t *testing.T) {
	t.Setenv("HOSTED_ONLY_GLM_MODEL", "rits/new-primary")
	t.Setenv("HOSTED_ONLY_DEEPSEEK_MODEL", "rits/new-fallback")
	t.Setenv("HOSTED_ONLY_ALIAS_MODELS", "claude-sonnet-5-5") // independent of the default alias list
	dir := t.TempDir()
	o := ensureOpts{flavor: "claude", port: "4148", runtimeDir: dir}

	if out := captureStderr(t, func() { reportPairGap(o) }); !strings.Contains(out, "predates the pair record") {
		t.Fatalf("a proxy with no pair record cannot be compared, and must say so: %q", out)
	}

	writeServedModels(dir, []string{"rits/old-primary", "rits/old-fallback"})
	out := captureStderr(t, func() { reportPairGap(o) })
	if !strings.Contains(out, "does not serve") || !strings.Contains(out, "rits/new-primary") || !strings.Contains(out, "rits/new-fallback") {
		t.Fatalf("the kept proxy's missing ids must be named: %q", out)
	}

	writeServedModels(dir, []string{"rits/new-primary", "rits/new-fallback", "claude-sonnet-5-5"})
	if out := captureStderr(t, func() { reportPairGap(o) }); out != "" {
		t.Fatalf("a kept proxy serving the current pair reports nothing: %q", out)
	}
}

// A forced restart exists to apply new code: keeping the old proxy is a failure
// of THAT request, while a plain launch must still start against the proxy that
// is serving.
func TestEnsureExitCodeForcedRestartThatKeptTheOldProxyFails(t *testing.T) {
	for _, tc := range []struct {
		status string
		forced bool
		want   int
	}{
		{"kept-key-rejected", true, exitKeyRejected},
		{"kept-key-rejected", false, 0},
		{"restarted", true, 0},
		{"fresh", true, 0},
		{"reused-busy", false, 0},
	} {
		if got := ensureExitCode(tc.status, tc.forced); got != tc.want {
			t.Errorf("status %q forced=%v: exit %d want %d", tc.status, tc.forced, got, tc.want)
		}
	}
}

// The probe budget has to outlast the system resolver's timeout, or the DoH
// fallback the dialer exists for never gets to run.
func TestKeyProbeBudgetOutlastsTheResolver(t *testing.T) {
	if keyProbeDialBudget < 10*time.Second || keyProbeTotalBudget <= keyProbeDialBudget {
		t.Fatalf("dial %v total %v: DoH needs time after a slow DNS failure", keyProbeDialBudget, keyProbeTotalBudget)
	}
	if got := keyProbeClient().Timeout; got != keyProbeTotalBudget {
		t.Fatalf("client timeout %v, want %v", got, keyProbeTotalBudget)
	}
}

// The probe never sends both credential shapes on one request, and refuses only
// when EVERY shape is answered 401. A gateway that 401s conflicting credentials
// must not block a valid key; a dead key is 401 on each shape.
func TestProbeRefusesOnlyWhenEveryShapeIs401(t *testing.T) {
	var mu sync.Mutex
	var sawBoth bool
	gateway := func(valid func(h http.Header) bool) *httptest.Server {
		s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			mu.Lock()
			if r.Header.Get("Authorization") != "" && r.Header.Get("x-api-key") != "" {
				sawBoth = true
			}
			mu.Unlock()
			if valid(r.Header) {
				w.WriteHeader(http.StatusOK)
				return
			}
			w.WriteHeader(http.StatusUnauthorized)
		}))
		t.Cleanup(s.Close)
		return s
	}

	// valid key, but this gateway only accepts the Messages shape
	xOnly := gateway(func(h http.Header) bool { return h.Get("x-api-key") == "good" && h.Get("Authorization") == "" })
	if status := probeUpstreamKey(xOnly.URL, "good"); status != http.StatusOK {
		t.Fatalf("a valid key accepted on the second shape must pass, got %d", status)
	}
	if err := checkUpstreamKey("claude", xOnly.URL, "good"); err != nil {
		t.Fatalf("a valid key must not be refused: %v", err)
	}
	// valid key, Bearer only
	bearerOnly := gateway(func(h http.Header) bool { return h.Get("Authorization") == "Bearer good" && h.Get("x-api-key") == "" })
	if err := checkUpstreamKey("claude", bearerOnly.URL, "good"); err != nil {
		t.Fatalf("a valid key accepted on the first shape must not be refused: %v", err)
	}
	// dead key: 401 on every shape
	dead := gateway(func(http.Header) bool { return false })
	var keyErr *upstreamKeyError
	if err := checkUpstreamKey("claude", dead.URL, "bad"); !errors.As(err, &keyErr) {
		t.Fatalf("a key rejected on every shape must be refused: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if sawBoth {
		t.Fatal("no single request may carry both credential shapes")
	}
}

// A key the gateway rejected is a PERMANENT refusal: its own exit code, so a caller
// that retries failed restarts can stop instead of backing off forever, and the
// compound token-change error keeps it (wrapped with %w).
func TestEnsureErrExitCodeSeparatesPermanentKeyRefusals(t *testing.T) {
	if got := ensureErrExitCode(&upstreamKeyError{Status: 401}); got != exitKeyRejected {
		t.Errorf("a key refusal exits %d, want %d", got, exitKeyRejected)
	}
	wrapped := fmt.Errorf("%w; the running proxy also uses a different proxy token", &upstreamKeyError{Status: 401})
	if got := ensureErrExitCode(wrapped); got != exitKeyRejected {
		t.Errorf("the token-change compound error must stay a key refusal: %d", got)
	}
	if got := ensureErrExitCode(errors.New("port 4148 is held")); got != 1 {
		t.Errorf("any other failure stays the generic code 1, got %d", got)
	}
}
