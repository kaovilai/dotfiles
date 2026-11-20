package main

import (
	"context"
	"errors"
	"fmt"
	"io"
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

const (
	keyProbeDialBudget  = 15 * time.Second
	keyProbeTotalBudget = 20 * time.Second
)

// keyProbe is the seam tests replace; it returns the gateway's HTTP status for
// a cheap authenticated read, or 0 when the gateway could not be reached.
var keyProbe = probeUpstreamKey

// keyProbeClient dials the way the serving proxy does: through the DoH-capable
// dialer, so a network where the system resolver fails for the gateway (the
// reason ENMAAS_DNS_FALLBACK_HOSTS exists) gets the same verdict the proxy
// will, instead of a silent "unreachable" that lets the swap through. It never
// follows a redirect: x-api-key would travel to whatever host a 3xx names (the
// gateway-key rule in _claude_enmaas_discover), and a 3xx is not a verdict.
//
// The budget must outlast the system resolver: dohDialContext only falls back to
// DoH after the base dial returns a DNS error, which on a stale or unresponsive
// DNS server arrives at the resolver's own timeout. A shorter client deadline
// would cancel the context before DoH ran and fail open on exactly the network
// the dialer exists for. The dial gets 15s (the proxy allows 30s) and the whole
// request 20s, still bounding a launch on a dead network.
func keyProbeClient() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.DialContext = dohDialContext(&net.Dialer{Timeout: keyProbeDialBudget}, sharedDoHResolver())
	return &http.Client{
		Timeout:   keyProbeTotalBudget,
		Transport: transport,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

// probeUpstreamKey asks the gateway to list models, one credential shape per
// request — the shapes the serving proxy itself sends (Bearer for Responses/chat,
// x-api-key + anthropic-version for Messages) — never both on one request: a
// gateway that 401s conflicting credentials would otherwise block a VALID key
// from every swap and cold start, an outage that looks exactly like a bad key.
// The key counts as rejected only when EVERY shape is answered 401; the first
// answer that is not a 401 (200, 403, 404, 3xx, 5xx, unreachable) is returned.
// A read costs nothing and is allowed over the monthly cap.
//
// Verified against the live gateway 2026-11-16: with a valid key /v1/models is 200 for
// Bearer alone, for x-api-key + anthropic-version alone and for both together; with
// no credential it is 401. Re-check that if the gateway's auth layer changes.
func probeUpstreamKey(base, key string) int {
	endpoint := strings.TrimRight(base, "/") + "/v1/models"
	shapes := []func(*http.Request){
		func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+key) },
		func(r *http.Request) {
			r.Header.Set("x-api-key", key)
			r.Header.Set("anthropic-version", "2023-06-01")
		},
	}
	status := 0
	// One client for both shapes: they hit the same endpoint, so the second
	// rides the first's connection instead of paying its own TCP+TLS
	// handshake — the probe runs on every launch and every watcher restart.
	// One shared deadline spans both requests AND their body drains (the
	// per-Do Client.Timeout restarts per call, so a stalled 401 body could
	// otherwise add a second full timeout before the rejection is reported).
	client := keyProbeClient()
	defer client.CloseIdleConnections()
	ctx, cancel := context.WithTimeout(context.Background(), keyProbeTotalBudget)
	defer cancel()
	for i, shape := range shapes {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
		if err != nil {
			return 0
		}
		shape(req)
		resp, err := client.Do(req)
		if err != nil {
			return 0
		}
		if status = resp.StatusCode; status != http.StatusUnauthorized {
			// Terminal: no later probe request can reuse the connection, so
			// skip the drain and let Close drop it.
			_ = resp.Body.Close()
			return status
		}
		if i < len(shapes)-1 {
			// 401 and another shape follows: drain (bounded) before Close so
			// the pooled connection is reused instead of being discarded. The
			// FINAL 401 needs no drain either — the rejection is already
			// known, and a stalled body would only delay reporting it.
			_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
		}
		_ = resp.Body.Close()
	}
	return status
}

// checkUpstreamKey fails only on a DEFINITE rejection (401). An outage, a slow
// gateway, DNS trouble, a 403 (entitlement/WAF), a redirect or a gateway without
// a models route must never block a restart, so every other answer passes.
//
// Scope: the hosted-only flavors (claude, codex). The route-table flavors mlx,
// openai and vertex carry their own upstream and key, which this EnMaaS probe
// does not describe. The enmaas flavor shares the gateway and key too, but its
// swap lives in the Python controller (zsh/functions/claude/providers/
// enmaas-proxy.zsh), which spawns `serve` itself and never reaches startProxy:
// :4146 is guarded there instead, by the controller's gateway_rejects_key
// (same both-shapes, 401-only contract) running before any side effect.
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
