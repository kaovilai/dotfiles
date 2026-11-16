package main

import (
	"errors"
	"fmt"
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

// upstreamKeyError is the gateway answering 401/403 to the key the new proxy
// would carry.
type upstreamKeyError struct{ Status int }

func (e *upstreamKeyError) Error() string {
	return fmt.Sprintf("hosted-only: the upstream gateway rejected the API key (HTTP %d); refresh ENMAAS_API_KEY in the credentials file (default ~/secrets.zsh)", e.Status)
}

// keyProbe is the seam tests replace; it returns the gateway's HTTP status for
// a cheap authenticated read, or 0 when the gateway could not be reached.
var keyProbe = probeUpstreamKey

// probeUpstreamKey asks the gateway to list models with the key in both header
// shapes the proxy uses (x-api-key for Messages, Bearer for Responses/chat). A
// read costs nothing and is allowed over the monthly cap.
func probeUpstreamKey(base, key string) int {
	req, err := http.NewRequest(http.MethodGet, strings.TrimRight(base, "/")+"/v1/models", nil)
	if err != nil {
		return 0
	}
	req.Header.Set("x-api-key", key)
	req.Header.Set("Authorization", "Bearer "+key)
	resp, err := (&http.Client{Timeout: 5 * time.Second}).Do(req)
	if err != nil {
		return 0
	}
	_ = resp.Body.Close()
	return resp.StatusCode
}

// checkUpstreamKey fails only on a DEFINITE rejection (401/403). An outage, a
// slow gateway, DNS trouble or a gateway without a models route must never block
// a restart, so every other answer passes. Route-table flavors carry their own
// upstream and key, which this EnMaaS probe does not describe.
func checkUpstreamKey(flavor, base, key string) error {
	if routeTableFlavor(flavor) || base == "" || key == "" {
		return nil
	}
	if status := keyProbe(base, key); status == http.StatusUnauthorized || status == http.StatusForbidden {
		return &upstreamKeyError{Status: status}
	}
	return nil
}

// keepRunning reports whether a failed replacement should leave the old proxy
// serving instead of falling back to stop-then-start: only an upstream key
// rejection, and only while an old listener is still alive. Stopping a working
// proxy to start one that cannot authenticate is the outage this prevents.
func keepRunning(err error, oldPids []int) bool {
	var keyErr *upstreamKeyError
	return errors.As(err, &keyErr) && anyPidAlive(oldPids)
}
