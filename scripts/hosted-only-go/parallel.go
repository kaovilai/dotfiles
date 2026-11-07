package main

// Web-search shim, part 3: the Parallel Search API client (docs/notes/
// web-search-shim.md).
//
// Auth ladder (preferred order — avoid ever hand-pasting a key):
//  1. PARALLEL_API_KEY env, if the user set one explicitly.
//  2. OAuth-minted key: device-flow OAuth (RFC 8628) against
//     platform.parallel.ai, one browser approval, then a dedicated
//     app-scoped key minted via the Account API (keys:create) and stored in
//     the proxy state dir. Re-minted on a 401.
//  3. Anonymous free tier: no key. Anonymous calls reject ALL overrides
//     (mode pin, advanced_settings), so this tier sends a bare
//     {objective, search_queries} body and takes default-shaped free results.
//     Knobs are omitted wholesale, not partially — one rejected override
//     422s the whole call.
//
// Execution gate (independent of model output — the model requesting a search
// never by itself authorizes one): argument validation before every call, a
// per-turn max_uses cap and a proxy-side daily ceiling keyed to the
// credential, and no new external side effects beyond Parallel Search.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	parallelSearchTimeout = 5 * time.Second
	parallelMaxResults    = 8
	parallelExcerptChars  = 2000
)

type parallelClient struct {
	cfg     *config
	client  *http.Client
	account *http.Client // platform.parallel.ai for OAuth
	logf    func(format string, args ...any)

	mu       sync.Mutex
	budget   map[string]int // UTC day -> executed searches
	mintedIn map[string]bool
}

func newParallelClient(cfg *config, logf func(format string, args ...any)) *parallelClient {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	return &parallelClient{
		cfg:      cfg,
		client:   &http.Client{Timeout: parallelSearchTimeout},
		account:  &http.Client{Timeout: 30 * time.Second},
		logf:     logf,
		budget:   map[string]int{},
		mintedIn: map[string]bool{},
	}
}

// credential is one rung of the auth ladder.
type credential struct {
	Key      string // "" for the anonymous tier
	Authed   bool
	Source   string // "env" | "oauth" | "anonymous"
	Minted   bool   // OAuth-minted: re-mint on 401
	ClientID string
}

func (c *parallelClient) stateFile(name string) string {
	return filepath.Join(c.cfg.shimStateDir(), name)
}

// resolveCredential walks the auth ladder. OAuth minting happens once per
// process; a failed mint degrades to the anonymous tier for this process
// (logged, not fatal).
func (c *parallelClient) resolveCredential(ctx context.Context) credential {
	if c.cfg.ParallelKey != "" {
		return credential{Key: c.cfg.ParallelKey, Authed: true, Source: "env"}
	}
	if key := c.readMintedKey(); key != "" {
		return credential{Key: key, Authed: true, Source: "oauth", Minted: true}
	}
	if c.mintedIn["once"] {
		return credential{Source: "anonymous"}
	}
	c.mintedIn["once"] = true
	key, err := c.mintKey(ctx)
	if err != nil {
		c.logf("search-shim: OAuth key mint failed (%v); using the anonymous free tier", err)
		return credential{Source: "anonymous"}
	}
	return credential{Key: key, Authed: true, Source: "oauth", Minted: true}
}

func (c *parallelClient) readMintedKey() string {
	b, err := os.ReadFile(c.stateFile("parallel-key"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// mintKey runs the device-flow OAuth and mints an app-scoped key:
// register client -> device code -> (user approves in browser) -> poll token
// -> create app + key -> store. The verification URL is logged for the user;
// this is the one interactive step, once ever.
func (c *parallelClient) mintKey(ctx context.Context) (string, error) {
	platform := c.cfg.ParallelPlatform
	clientID := ""
	if b, err := os.ReadFile(c.stateFile("parallel-client-id")); err == nil {
		clientID = strings.TrimSpace(string(b))
	}
	if clientID == "" {
		body := map[string]any{
			"client_name": "hosted-only-proxy",
			"platform":    map[string]any{"os_name": "posix", "system": "linux"},
		}
		var out struct {
			ClientID string `json:"client_id"`
		}
		if err := c.postForm(ctx, c.account, platform+"/getServiceKeys/register", "json", marshal(body), &out, nil); err != nil {
			return "", fmt.Errorf("register: %w", err)
		}
		if out.ClientID == "" {
			return "", fmt.Errorf("register: no client_id")
		}
		clientID = out.ClientID
		_ = os.MkdirAll(c.cfg.shimStateDir(), 0o700)
		_ = os.WriteFile(c.stateFile("parallel-client-id"), []byte(clientID), 0o600)
	}

	form := url.Values{"client_id": {clientID}, "scope": {"keys:create apps:create"}}
	var code struct {
		DeviceCode string `json:"device_code"`
		UserCode   string `json:"user_code"`
		VerifyURL  string `json:"verification_uri_complete"`
		Interval   int    `json:"interval"`
		ExpiresIn  int    `json:"expires_in"`
	}
	if err := c.postForm(ctx, c.account, platform+"/getServiceKeys/device/code", "form", []byte(form.Encode()), &code, nil); err != nil {
		return "", fmt.Errorf("device code: %w", err)
	}
	if code.VerifyURL == "" {
		code.VerifyURL = "https://platform.parallel.ai/getServiceKeys/device"
	}
	c.logf("search-shim: approve once at %s (code %s) to mint a Parallel search key", code.VerifyURL, code.UserCode)

	interval := time.Duration(max(code.Interval, 5)) * time.Second
	deadline := time.Now().Add(time.Duration(min(code.ExpiresIn, 900)) * time.Second)
	var token struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return "", fmt.Errorf("token poll: %w", ctx.Err())
		case <-time.After(interval):
		}
		err := c.postForm(ctx, c.account, platform+"/getServiceKeys/token", "form", []byte(url.Values{
			"grant_type":  {"urn:ietf:params:oauth:grant-type:device_code"},
			"client_id":   {clientID},
			"device_code": {code.DeviceCode},
		}.Encode()), &token, nil)
		if err == nil && token.AccessToken != "" {
			break
		}
		if strings.Contains(err.Error(), "authorization_pending") || strings.Contains(err.Error(), "slow_down") {
			continue
		}
		return "", fmt.Errorf("token poll: %w", err)
	}
	if token.AccessToken == "" {
		return "", fmt.Errorf("token poll: device code expired without approval")
	}
	_ = os.WriteFile(c.stateFile("parallel-refresh"), []byte(token.RefreshToken), 0o600)

	// Mint a dedicated app-scoped key rather than holding the account token.
	account := "https://api.parallel.ai/account"
	var app struct {
		AppID string `json:"app_id"`
	}
	bearer := map[string]string{"Authorization": "Bearer " + token.AccessToken}
	if err := c.postForm(ctx, c.account, account+"/service/v1/apps", "json", marshal(map[string]any{"app_name": "hosted-only-proxy"}), &app, bearer); err != nil {
		return "", fmt.Errorf("create app: %w", err)
	}
	if app.AppID == "" {
		return "", fmt.Errorf("create app: no app_id")
	}
	var key struct {
		RawAPIKey string `json:"raw_api_key"`
	}
	if err := c.postForm(ctx, c.account, account+"/service/v1/apps/"+app.AppID+"/keys", "json", marshal(map[string]any{"api_key_name": "hosted-only-proxy-shim"}), &key, bearer); err != nil {
		return "", fmt.Errorf("create key: %w", err)
	}
	if key.RawAPIKey == "" {
		return "", fmt.Errorf("create key: no raw_api_key")
	}
	_ = os.MkdirAll(c.cfg.shimStateDir(), 0o700)
	_ = os.WriteFile(c.stateFile("parallel-key"), []byte(key.RawAPIKey), 0o600)
	return key.RawAPIKey, nil
}

func (c *parallelClient) postForm(ctx context.Context, client *http.Client, u string, encoding string, body []byte, out any, headers map[string]string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	if encoding == "form" {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	} else {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: %d %s", u, resp.StatusCode, truncate(string(b), 200))
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(b, out); err != nil {
		return fmt.Errorf("%s: %w", u, err)
	}
	return nil
}

// searchResult is one Parallel result: untrusted web content, reinjected only
// through the injection-hardening path in shimloop.go.
type searchResult struct {
	URL      string
	Title    string
	Excerpts []string
}

// searchError is a gate or transport failure: the loop turns it into an
// is_error tool result so the turn stays well-formed; never a 500.
type searchError struct{ Message string }

func (e *searchError) Error() string { return e.Message }

// validateSearchQuery is the argument gate: non-empty, bounded, no site:
// operators (domains are enforced via source_policy only).
func validateSearchQuery(query string) error {
	q := strings.TrimSpace(query)
	if q == "" {
		return &searchError{"web search query is empty"}
	}
	if len(q) > 2000 {
		return &searchError{"web search query is too long"}
	}
	if strings.Contains(strings.ToLower(q), "site:") {
		return &searchError{"site: operators are not supported; use allowed_domains on the tool"}
	}
	return nil
}

func (c *parallelClient) budgetDay(now time.Time) string {
	return now.UTC().Format("2006-01-02")
}

func (c *parallelClient) budgetLeft(now time.Time) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return max(c.cfg.SearchDailyCap-c.budget[c.budgetDay(now)], 0)
}

func (c *parallelClient) countSearch(now time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	day := c.budgetDay(now)
	c.budget[day]++
	if len(c.budget) > 8 { // keep a week plus slack of days
		for d := range c.budget {
			if d < day {
				delete(c.budget, d)
			}
		}
	}
}

// budgetDayCount reports today's executed-search count (tests and logging).
func (c *parallelClient) budgetDayCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.budget[c.budgetDay(time.Now())]
}

// search executes one model-requested web_search call through the gate and
// the Parallel Search API. Authenticated tiers pin mode fast (omitted mode on
// REST means advanced — a quiet 5x) and set the evidence knobs; the anonymous
// tier sends a bare body because overrides are rejected unauthenticated.
func (c *parallelClient) search(ctx context.Context, plan *shimPlan, query string) ([]searchResult, error) {
	if err := validateSearchQuery(query); err != nil {
		return nil, err
	}
	if c.budgetLeft(time.Now()) <= 0 {
		return nil, &searchError{fmt.Sprintf("web search daily budget of %d exhausted", c.cfg.SearchDailyCap)}
	}
	cred := c.resolveCredential(ctx)
	results, status, err := c.searchOnce(ctx, cred, plan, query)
	if status == http.StatusUnauthorized && cred.Minted {
		// stale minted key: drop it, re-mint once, retry once
		_ = os.Remove(c.stateFile("parallel-key"))
		c.mintedIn["once"] = false
		delete(c.mintedIn, "once")
		cred = c.resolveCredential(ctx)
		if cred.Authed {
			results, status, err = c.searchOnce(ctx, cred, plan, query)
		}
	}
	if err != nil {
		return nil, &searchError{"web search unavailable this turn: " + err.Error()}
	}
	c.countSearch(time.Now())
	return results, nil
}

func (c *parallelClient) searchOnce(ctx context.Context, cred credential, plan *shimPlan, query string) ([]searchResult, int, error) {
	body := map[string]any{
		"objective":      query,
		"search_queries": []string{keywordQuery(query)},
	}
	if cred.Authed {
		// mode fast pinned explicitly; knobs that decide how much evidence the
		// model actually sees.
		body["mode"] = "fast"
		advanced := map[string]any{
			"max_results": parallelMaxResults,
			"excerpt_settings": map[string]any{
				"max_chars_per_result": parallelExcerptChars,
			},
		}
		if len(plan.AllowedDomains) > 0 {
			advanced["source_policy"] = map[string]any{"include_domains": plan.AllowedDomains}
		}
		body["advanced_settings"] = advanced
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.cfg.ParallelBase+"/v1/search", bytes.NewReader(marshal(body)))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	if cred.Authed {
		req.Header.Set("Authorization", "Bearer "+cred.Key)
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode != http.StatusOK {
		return nil, resp.StatusCode, fmt.Errorf("parallel: %d %s", resp.StatusCode, truncate(string(b), 200))
	}
	var out struct {
		Results []struct {
			URL      string   `json:"url"`
			Title    string   `json:"title"`
			Excerpts []string `json:"excerpts"`
		} `json:"results"`
		Errors []struct {
			URL       string `json:"url"`
			ErrorType string `json:"error_type"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, resp.StatusCode, err
	}
	// Read errors as well as results: a URL that failed appears only in
	// errors; silently dropping it overstates the evidence set.
	var results []searchResult
	for _, r := range out.Results {
		if r.URL == "" {
			continue
		}
		results = append(results, searchResult{URL: r.URL, Title: r.Title, Excerpts: r.Excerpts})
	}
	for _, e := range out.Errors {
		c.logf("search-shim: parallel result error %s: %s", e.URL, e.ErrorType)
	}
	return results, resp.StatusCode, nil
}

// keywordQuery reduces a natural-language query to a short keyword query
// (3-6 words): drop question words, keep content terms.
func keywordQuery(query string) string {
	stop := map[string]bool{"what": true, "whats": true, "when": true, "where": true, "which": true, "who": true, "whom": true, "why": true, "how": true, "is": true, "are": true, "was": true, "were": true, "the": true, "a": true, "an": true, "of": true, "in": true, "on": true, "for": true, "to": true, "and": true, "or": true, "does": true, "do": true, "did": true, "current": true, "latest": true, "me": true, "my": true, "find": true, "show": true, "tell": true, "about": true}
	words := strings.FieldsFunc(strings.ToLower(query), func(r rune) bool {
		return r == ' ' || r == ',' || r == '.' || r == '?' || r == '!' || r == ';' || r == ':' || r == '"' || r == '\''
	})
	var kept []string
	for _, w := range words {
		if !stop[w] {
			kept = append(kept, w)
		}
	}
	if len(kept) == 0 {
		kept = words
	}
	if len(kept) > 8 {
		kept = kept[:8]
	}
	q := strings.Join(kept, " ")
	if len(q) > 200 {
		q = q[:200]
	}
	return q
}
