package main

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"
)

// A replacement proxy that cannot authenticate upstream is worse than no
// replacement: the swap retires the proxy that WAS serving, every request then
// answers 401, and the client reports a generic "could not authenticate"
// (2026-11-16: an edit-triggered restart picked up an EnMaaS key the gateway
// rejected). The zero-refuse swap only waits for the health path, so the key is
// checked before anything is started or any stamp is cleared.

// upstreamKeyError is the gateway answering 401 to the key the new proxy would
// carry. Only 401: this gateway answers 403 for a key that is valid but not
// entitled to a route (over the monthly cap, a model it may not use), and an
// ingress/WAF can 403 too — none of which a restart can fix or should wait on.
type upstreamKeyError struct{ Status int }

func (e *upstreamKeyError) Error() string {
	return fmt.Sprintf("hosted-only: the upstream gateway rejected the API key (HTTP %d); refresh ENMAAS_API_KEY (or HOSTED_ONLY_UPSTREAM_KEY, which overrides it when set) in the credentials file (default ~/secrets.zsh)", e.Status)
}

// keyProbe is the seam tests replace; it returns the gateway's HTTP status for
// a cheap authenticated read, or 0 when the gateway could not be reached.
var keyProbe = probeUpstreamKey

// keyProbeClient dials the way the serving proxy does: through the DoH-capable
// dialer, so a network where the system resolver fails for the gateway (the
// reason ENMAAS_DNS_FALLBACK_HOSTS exists) gets the same verdict the proxy
// will, instead of a silent "unreachable" that lets the swap through. It never
// follows a redirect: x-api-key would travel to whatever host a 3xx names (the
// gateway-key rule in _claude_enmaas_discover), and a 3xx is not a verdict.
func keyProbeClient() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.DialContext = dohDialContext(&net.Dialer{Timeout: 5 * time.Second}, newDoHResolver())
	return &http.Client{
		Timeout:   5 * time.Second,
		Transport: transport,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

// probeUpstreamKey asks the gateway to list models with the key in both header
// shapes the proxy uses (x-api-key + anthropic-version for Messages, Bearer for
// Responses/chat). A read costs nothing and is allowed over the monthly cap.
func probeUpstreamKey(base, key string) int {
	req, err := http.NewRequest(http.MethodGet, strings.TrimRight(base, "/")+"/v1/models", nil)
	if err != nil {
		return 0
	}
	req.Header.Set("x-api-key", key)
	req.Header.Set("anthropic-version", "2023-06-01")
	req.Header.Set("Authorization", "Bearer "+key)
	client := keyProbeClient()
	defer client.CloseIdleConnections()
	resp, err := client.Do(req)
	if err != nil {
		return 0
	}
	_ = resp.Body.Close()
	return resp.StatusCode
}

// checkUpstreamKey fails only on a DEFINITE rejection (401). An outage, a slow
// gateway, DNS trouble, a 403 (entitlement/WAF), a redirect or a gateway without
// a models route must never block a restart, so every other answer passes.
// Route-table flavors carry their own upstream and key, which this EnMaaS probe
// does not describe.
func checkUpstreamKey(flavor, base, key string) error {
	if routeTableFlavor(flavor) || base == "" || key == "" {
		return nil
	}
	if status := keyProbe(base, key); status == http.StatusUnauthorized {
		return &upstreamKeyError{Status: status}
	}
	return nil
}

// tokenCompatible reports whether a kept proxy still accepts the client this
// launch is about to start: an old record without a token is unknown (taken as
// unchanged, as the busy path does), otherwise the proxy-token fingerprints must
// match, or the client would be launched with a token the kept proxy rejects.
func tokenCompatible(recToken, wantToken string) bool {
	return recToken == "" || recToken == wantToken
}

// keepRunning reports whether a failed replacement should leave the old proxy
// serving instead of falling back to stop-then-start: only an upstream key
// rejection, and only while an old listener is still alive. Stopping a working
// proxy to start one that cannot authenticate is the outage this prevents.
func keepRunning(err error, oldPids []int) bool {
	var keyErr *upstreamKeyError
	return errors.As(err, &keyErr) && anyPidAlive(oldPids)
}
