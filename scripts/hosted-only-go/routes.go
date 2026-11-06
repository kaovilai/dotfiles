package main

import (
	"encoding/json"
	"errors"
	"os"
	"strings"
)

// routeEntry is one LiteLLM model_list row, reduced to what the proxy needs.
// The EnMaaS launcher already generates that config (dialect per id, #responses
// siblings, per-entry api_base), so the Go path reads it instead of inventing a
// second format.
type routeEntry struct {
	Name          string // model_name the client asks for
	UpstreamModel string // id sent upstream (provider prefix and #responses stripped)
	Dialect       string // anthropic | openai | responses
	Base          string // api_base from the config (may end in /v1)
}

type routeTable struct {
	entries  map[string]routeEntry
	wildcard *routeEntry
	token    string
	names    []string
}

type rawConfig struct {
	ModelList []struct {
		ModelName     string         `json:"model_name"`
		LitellmParams map[string]any `json:"litellm_params"`
	} `json:"model_list"`
	GeneralSettings struct {
		MasterKey string `json:"master_key"`
	} `json:"general_settings"`
}

func loadRouteTable(path string) (*routeTable, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var raw rawConfig
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	if len(raw.ModelList) == 0 {
		return nil, errors.New("config has no model_list")
	}
	table := &routeTable{entries: map[string]routeEntry{}}
	for _, row := range raw.ModelList {
		if row.ModelName == "" {
			continue
		}
		entry := routeEntry{
			Name:          row.ModelName,
			UpstreamModel: upstreamModelName(row.LitellmParams),
			Dialect:       dialectOf(row.LitellmParams),
			Base:          strings.TrimRight(asString(row.LitellmParams["api_base"]), "/"),
		}
		if row.ModelName == "*" {
			table.wildcard = &entry
			continue
		}
		table.entries[row.ModelName] = entry
		table.names = append(table.names, row.ModelName)
	}
	table.token = raw.GeneralSettings.MasterKey
	return table, nil
}

// upstreamModelName strips the provider prefix ("anthropic/", "openai/",
// "openai/responses/") from the configured model.
func upstreamModelName(params map[string]any) string {
	model := asString(params["model"])
	switch {
	case strings.HasPrefix(model, "openai/responses/"):
		return strings.TrimPrefix(model, "openai/responses/")
	case strings.HasPrefix(model, "anthropic/"):
		return strings.TrimPrefix(model, "anthropic/")
	case strings.HasPrefix(model, "openai/"):
		return strings.TrimPrefix(model, "openai/")
	}
	return model
}

func dialectOf(params map[string]any) string {
	model := asString(params["model"])
	switch {
	case strings.HasPrefix(model, "anthropic/"):
		return "anthropic"
	case strings.HasPrefix(model, "openai/responses/"):
		return "responses"
	case strings.HasPrefix(model, "openai/"):
		return "openai"
	}
	return "openai"
}

// resolve picks the deployment for a client model id and endpoint. It mirrors
// enmaas_proxy_hooks.route_model: on /v1/responses a model with a "<id>#responses"
// sibling is served by that sibling (the native Responses passthrough), and an
// unknown id falls back to the wildcard chat route.
func (t *routeTable) resolve(model, clientPath string) (routeEntry, string, string) {
	isResponses := strings.Contains(clientPath, "/v1/responses")
	if isResponses {
		if entry, ok := t.entries[model+"#responses"]; ok {
			upstream := entry.UpstreamModel
			if upstream == "*" {
				upstream = model
			}
			return entry, upstream, "/v1/responses"
		}
	}
	entry, ok := t.entries[model]
	if !ok {
		if t.wildcard == nil {
			return routeEntry{Name: model, UpstreamModel: model, Dialect: "openai", Base: ""}, model, defaultUpstreamPath(clientPath, "openai")
		}
		entry = *t.wildcard
		if entry.UpstreamModel == "*" {
			entry.UpstreamModel = model
		}
		return entry, entry.UpstreamModel, defaultUpstreamPath(clientPath, entry.Dialect)
	}
	return entry, entry.UpstreamModel, defaultUpstreamPath(clientPath, entry.Dialect)
}

func defaultUpstreamPath(clientPath, dialect string) string {
	switch dialect {
	case "anthropic":
		return "/v1/messages"
	case "responses":
		return "/v1/responses"
	}
	if strings.Contains(clientPath, "/v1/responses") {
		return "/v1/responses"
	}
	return "/v1/chat/completions"
}

func (t *routeTable) modelNames() []string {
	return t.names
}

// known reports whether this id is served: an exact deployment, a #responses
// sibling on that endpoint, or the wildcard route.
func (t *routeTable) known(model, clientPath string) bool {
	if _, ok := t.entries[model]; ok {
		return true
	}
	if strings.Contains(clientPath, "/v1/responses") {
		if _, ok := t.entries[model+"#responses"]; ok {
			return true
		}
	}
	return t.wildcard != nil
}
