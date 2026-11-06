package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// transportKeys are pinned for every launch: the wrapper-selected transport
// wins over a saved/caller transport, preserving unrelated SDK settings.
var transportKeys = []string{
	"ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
	"ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
	"ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
	"ANTHROPIC_DEFAULT_FABLE_MODEL", "CLAUDE_CODE_USE_VERTEX",
	"CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_FOUNDRY",
	"ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_API_KEY_HELPER",
}

// captureMode reads NUL-separated args from stdin (the final invocation the
// ZSH wrapper made), merges --settings, pins the transport, resolves t3-*
// tier names and writes the profile the run flow supervises. Mirrors
// claude-provider.py's capture().
func captureMode(destination string) int {
	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		failGeneric()
		return 1
	}
	parts := bytes.Split(raw, []byte{0})
	if len(parts) > 0 {
		parts = parts[:len(parts)-1] // the zsh writer always appends one NUL
	}
	args := make([]string, len(parts))
	for i, part := range parts {
		args[i] = string(part)
	}

	settings := map[string]any{}
	forwarded := []string{}
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--":
			forwarded = append(forwarded, args[i:]...)
			i = len(args)
		case args[i] == "--settings":
			i++
			if i >= len(args) {
				failGeneric()
				return 1
			}
			merged, err := readSettings(args[i])
			if err != nil {
				failGeneric()
				return 1
			}
			settings = mergeSettings(settings, merged)
		case strings.HasPrefix(args[i], "--settings="):
			merged, err := readSettings(strings.TrimPrefix(args[i], "--settings="))
			if err != nil {
				failGeneric()
				return 1
			}
			settings = mergeSettings(settings, merged)
		default:
			forwarded = append(forwarded, args[i])
		}
	}

	transport := map[string]string{}
	for _, key := range transportKeys {
		transport[key] = os.Getenv(key)
	}
	transport["CLAUDE_CODE_USE_VERTEX"] = "0"
	transport["CLAUDE_CODE_USE_BEDROCK"] = "0"
	transport["CLAUDE_CODE_USE_FOUNDRY"] = "0"
	transport["ANTHROPIC_API_KEY"] = ""
	settings = mergeSettings(settings, map[string]any{"env": stringMapToAny(transport)})

	// t3-<tier> model names resolve to the backend's ANTHROPIC_DEFAULT_*
	// models; an unavailable tier is an error, not a silent pass-through.
	tiers := map[string]any{}
	for _, tier := range []string{"sonnet", "opus", "haiku", "fable"} {
		value := os.Getenv("ANTHROPIC_DEFAULT_" + strings.ToUpper(tier) + "_MODEL")
		if value == "" {
			tiers["t3-"+tier] = nil
		} else {
			tiers["t3-"+tier] = value
		}
	}
	for i := 0; i < len(forwarded); i++ {
		if forwarded[i] == "--" {
			break
		}
		if forwarded[i] == "--model" && i+1 < len(forwarded) {
			value, known := tiers[forwarded[i+1]]
			if known {
				if value == nil || value == "" {
					fmt.Fprintln(os.Stderr, "claude-provider: requested tier is unavailable")
					return 1
				}
				forwarded[i+1] = value.(string)
			}
			i++
			continue
		}
		if value, found := strings.CutPrefix(forwarded[i], "--model="); found {
			if resolved, known := tiers[value]; known {
				if resolved == nil || resolved == "" {
					fmt.Fprintln(os.Stderr, "claude-provider: requested tier is unavailable")
					return 1
				}
				forwarded[i] = "--model=" + resolved.(string)
			}
		}
	}

	// Upstream gateway keys stay with the proxies, not the Claude child.
	environment := map[string]string{}
	for _, entry := range os.Environ() {
		key, value, found := strings.Cut(entry, "=")
		if !found {
			continue
		}
		if key == "ENMAAS_API_KEY" || key == "OPENAI_API_KEY" || strings.HasPrefix(key, "CLAUDE_PROVIDER_") {
			continue
		}
		environment[key] = value
	}
	for key, value := range transport {
		environment[key] = value
	}

	body, err := json.Marshal(map[string]any{
		"args":     forwarded,
		"settings": settings,
		"env":      environment,
		"tiers":    tiers,
	})
	if err != nil {
		failGeneric()
		return 1
	}
	if err := os.WriteFile(destination, body, 0o600); err != nil {
		failGeneric()
		return 1
	}
	return 0
}

// readSettings takes one --settings value: inline JSON or a file path.
func readSettings(value string) (map[string]any, error) {
	text := value
	if !strings.HasPrefix(strings.TrimSpace(value), "{") {
		body, err := os.ReadFile(value)
		if err != nil {
			return nil, err
		}
		text = string(body)
	}
	var settings map[string]any
	if err := json.Unmarshal([]byte(text), &settings); err != nil {
		return nil, err
	}
	if settings == nil {
		// json "null" unmarshals into a nil map without an error; the Python
		// bridge rejects it ("settings must be an object").
		return nil, errors.New("settings must be an object")
	}
	return settings, nil
}

// mergeSettings is the Python bridge's deep merge: nested objects merge, the
// right side wins everywhere else.
func mergeSettings(left, right map[string]any) map[string]any {
	out := make(map[string]any, len(left)+len(right))
	for key, value := range left {
		out[key] = value
	}
	for key, value := range right {
		if nested, rightIsMap := value.(map[string]any); rightIsMap {
			if existing, leftIsMap := out[key].(map[string]any); leftIsMap {
				out[key] = mergeSettings(existing, nested)
				continue
			}
		}
		out[key] = value
	}
	return out
}

func stringMapToAny(input map[string]string) map[string]any {
	out := make(map[string]any, len(input))
	for key, value := range input {
		out[key] = value
	}
	return out
}
