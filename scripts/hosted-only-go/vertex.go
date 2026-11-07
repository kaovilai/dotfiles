package main

// Vertex AI partner-model support for the "vertex" flavor (claude-vertex).
// Claude Code speaks Anthropic Messages and so does Vertex's anthropic-partner
// endpoint, so no dialect translation is needed -- unlike every other flavor
// this one needs only two things the route table cannot express:
//
//   - the model id is part of the upstream path
//     (/v1/projects/P/locations/R/publishers/anthropic/models/<id>:rawPredict,
//     :streamRawPredict when streaming), so the path is built per request in
//     server.go (vertexPath) instead of coming from the deployment dialect;
//   - upstream auth is a Google ADC access token (gcloud auth
//     application-default login), not a static bearer key, so upstream()
//     draws it from the cached refresher here instead of cfg.APIKey.
//
// The route table the launcher generates carries anthropic-dialect entries
// with no api_base; cfg.BaseURL is the deployment root from vertexBaseURL().

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// vertexTokenEndpoint is a var so tests can point it at an httptest server.
var vertexTokenEndpoint = "https://oauth2.googleapis.com/token"

// vertexTokenScope matches what the Vertex SDKs request; LiteLLM's vertex_ai
// route uses the same cloud-platform scope.
const vertexTokenScope = "https://www.googleapis.com/auth/cloud-platform"

// vertexBaseURL builds the deployment root for the route table's empty
// api_base entries. CLOUD_ML_REGION and ANTHROPIC_VERTEX_PROJECT_ID are the
// same vars claude-vertex()/claude-vertex-native-adc() have always required.
func vertexBaseURL() string {
	region := os.Getenv("CLOUD_ML_REGION")
	project := os.Getenv("ANTHROPIC_VERTEX_PROJECT_ID")
	return fmt.Sprintf("https://%s-aiplatform.googleapis.com/v1/projects/%s/locations/%s/publishers/anthropic",
		region, project, region)
}

// vertexPath builds the partner-model endpoint for one request; the model id
// is part of the path, and streaming uses the :streamRawPredict sibling.
// Plain aliases like "claude-sonnet-5" resolve as publisher model ids -- no
// dated-snapshot suffix needed (verified live by the LiteLLM path).
func vertexPath(model string, stream bool) string {
	if stream {
		return "/models/" + model + ":streamRawPredict"
	}
	return "/models/" + model + ":rawPredict"
}

// adcFile is the Application Default Credentials file gcloud writes
// (`gcloud auth application-default login`), honoring the standard override.
func adcFile() string {
	if p := os.Getenv("GOOGLE_APPLICATION_CREDENTIALS"); p != "" {
		return p
	}
	return os.Getenv("HOME") + "/.config/gcloud/application_default_credentials.json"
}

// adcCredentials is the gcloud "authorized_user" ADC shape -- the only type
// supported here. Service-account and external-account files need a different
// flow and are refused with the fix-it hint rather than half-working.
type adcCredentials struct {
	Type         string `json:"type"`
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret"`
	RefreshToken string `json:"refresh_token"`
}

// vertexToken returns a cached ADC access token, refreshing it when it is
// within a minute of expiry. The cache lives for the process; ADC refresh
// tokens stay valid until revoked, so this is the same lifetime LiteLLM's
// google-auth path gave the old proxy.
func (a *app) vertexToken(ctx context.Context) (string, error) {
	a.vxMu.Lock()
	defer a.vxMu.Unlock()
	if a.vxToken != "" && time.Now().Before(a.vxExpiry) {
		return a.vxToken, nil
	}
	data, err := os.ReadFile(adcFile())
	if err != nil {
		return "", fmt.Errorf("vertex: reading ADC (%s): %w -- run gcloud auth application-default login", adcFile(), err)
	}
	var cred adcCredentials
	if err := json.Unmarshal(data, &cred); err != nil {
		return "", fmt.Errorf("vertex: parsing ADC: %w", err)
	}
	if cred.Type != "authorized_user" || cred.RefreshToken == "" {
		return "", fmt.Errorf("vertex: ADC type %q is not supported (need the gcloud authorized_user file; run gcloud auth application-default login)", cred.Type)
	}
	form := url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {cred.RefreshToken},
		"client_id":     {cred.ClientID},
		"client_secret": {cred.ClientSecret},
		"scope":         {vertexTokenScope},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, vertexTokenEndpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := a.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("vertex: refreshing ADC token: %w", err)
	}
	defer resp.Body.Close()
	var tok struct {
		AccessToken      string `json:"access_token"`
		ExpiresIn        int    `json:"expires_in"`
		Error            string `json:"error"`
		ErrorDescription string `json:"error_description"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tok); err != nil {
		return "", fmt.Errorf("vertex: decoding token answer: %w", err)
	}
	if resp.StatusCode != http.StatusOK || tok.AccessToken == "" {
		if tok.Error != "" {
			return "", fmt.Errorf("vertex: token refresh failed: %s: %s", tok.Error, tok.ErrorDescription)
		}
		return "", fmt.Errorf("vertex: token refresh failed with status %d", resp.StatusCode)
	}
	// Refresh a minute early so a request starting on a nearly-live token
	// does not carry an expired one to the gateway.
	a.vxToken = tok.AccessToken
	a.vxExpiry = time.Now().Add(time.Duration(tok.ExpiresIn-60) * time.Second)
	return a.vxToken, nil
}

// vertexInvalidate drops the cached access token so the next request draws a
// fresh one. Called on an upstream 401 (the cached token died mid-flight).
func (a *app) vertexInvalidate() {
	a.vxMu.Lock()
	a.vxToken = ""
	a.vxExpiry = time.Time{}
	a.vxMu.Unlock()
}

// hasToolSearchTool reports whether the request's tools contain a tool-search
// tool -- the same tool types LiteLLM's is_tool_search_used matched
// (llms/anthropic/common_utils.py).
func hasToolSearchTool(data map[string]any) bool {
	tools, ok := data["tools"].([]any)
	if !ok {
		return false
	}
	for _, t := range tools {
		tool := asMap(t)
		if tool == nil {
			continue
		}
		switch asString(tool["type"]) {
		case "tool_search_tool_regex_20251119", "tool_search_tool_bm25_20251119":
			return true
		}
	}
	return false
}

// addBetaHeader merges one token into the request's comma-separated
// anthropic-beta header, deduplicated.
func addBetaHeader(r *http.Request, beta string) {
	cur := r.Header.Get("anthropic-beta")
	for _, b := range strings.Split(cur, ",") {
		if strings.TrimSpace(b) == beta {
			return
		}
	}
	if cur == "" {
		r.Header.Set("anthropic-beta", beta)
	} else {
		r.Header.Set("anthropic-beta", cur+","+beta)
	}
}

// sanitizeVertexBody applies the partner endpoint's body constraints -- the
// same ones LiteLLM's vertex_ai partner transformation applied
// (vertex_ai_partner_models/anthropic/transformation.py +
// output_params_utils.py):
//   - the body must not carry "model" (the id lives in the URL; the endpoint
//     rejects the field);
//   - output_config.effort 400s on models that do not accept it (Claude Code
//     injects output_config into every Messages payload; Haiku advertises no
//     effort support), so it is dropped there;
//   - a non-dict or emptied output_config is removed entirely.
//
// Returns whether the body changed (the caller re-marshals then).
func sanitizeVertexBody(data map[string]any, model string) bool {
	changed := false
	if _, ok := data["model"]; ok {
		delete(data, "model")
		changed = true
	}
	if oc, ok := data["output_config"]; ok {
		cfg, isMap := oc.(map[string]any)
		if !isMap {
			delete(data, "output_config")
			return true
		}
		if _, has := cfg["effort"]; has && strings.Contains(model, "haiku") {
			delete(cfg, "effort")
			changed = true
		}
		if len(cfg) == 0 {
			delete(data, "output_config")
			changed = true
		}
	}
	return changed
}
