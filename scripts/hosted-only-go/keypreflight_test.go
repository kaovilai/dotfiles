package main

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// gatewayAnswering is a fake EnMaaS gateway that answers every request with
// status and records the auth headers the probe sent.
func gatewayAnswering(t *testing.T, status int) (*httptest.Server, *http.Header) {
	t.Helper()
	var seen http.Header
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r.Header.Clone()
		w.WriteHeader(status)
	}))
	t.Cleanup(server.Close)
	return server, &seen
}

// A replacement proxy the gateway would answer 401 must be refused before it
// can retire the proxy that is serving (2026-11-16 outage).
func TestCheckUpstreamKeyRejectsOnlyDefiniteAuthFailures(t *testing.T) {
	for _, tc := range []struct {
		status int
		reject bool
	}{
		{http.StatusUnauthorized, true},
		{http.StatusForbidden, false},        // valid key, route not entitled (over the cap) or an ingress/WAF
		{http.StatusFound, false},            // a redirect is not a verdict
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

func TestProbeSendsBothAuthShapes(t *testing.T) {
	server, seen := gatewayAnswering(t, http.StatusOK)
	if status := probeUpstreamKey(server.URL, "secret-value"); status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
	if (*seen).Get("x-api-key") != "secret-value" || (*seen).Get("Authorization") != "Bearer secret-value" {
		t.Fatalf("probe must send the key as x-api-key and Bearer: %v", *seen)
	}
	if (*seen).Get("anthropic-version") == "" {
		t.Fatalf("the Messages shape carries anthropic-version: %v", *seen)
	}
}

// The probe must never follow a redirect: x-api-key would be copied to whatever
// host the 3xx names (the rule _claude_enmaas_discover already states).
func TestProbeNeverFollowsARedirect(t *testing.T) {
	var elsewhereHit bool
	elsewhere := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		elsewhereHit = true
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
	if elsewhereHit {
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
