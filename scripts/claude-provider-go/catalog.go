package main

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"time"
)

const catalogTTL = 6 * time.Hour

// catalogMode caches credential-free model catalogs briefly so the EnMaaS
// inventories do not consume every SDK initialization probe's deadline.
// rc 3 is a miss (stale or absent), the caller falls back to discovery.
func catalogMode(mode, identity string) int {
	if !validIdentity(identity) {
		failGeneric()
		return 1
	}
	directory := filepath.Join(cacheHome(), "claude-provider")
	path := filepath.Join(directory, identity+".json")
	if mode == "--catalog-read" {
		info, err := os.Stat(path)
		if err != nil || time.Since(info.ModTime()) > catalogTTL {
			return 3
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return 3
		}
		// A malformed cache entry is a miss (rc 3), never passed through.
		var catalog map[string]any
		if json.Unmarshal(body, &catalog) != nil {
			return 3
		}
		if _, ok := catalog["data"].([]any); !ok {
			return 3
		}
		_, _ = os.Stdout.Write(body)
		return 0
	}
	body, err := io.ReadAll(os.Stdin)
	if err != nil {
		failGeneric()
		return 1
	}
	var catalog map[string]any
	if err := json.Unmarshal(body, &catalog); err != nil {
		failGeneric()
		return 1
	}
	if _, ok := catalog["data"].([]any); !ok {
		failGeneric()
		return 1
	}
	if err := os.MkdirAll(directory, 0o700); err != nil {
		failGeneric()
		return 1
	}
	// Write to a sibling temp file and rename into place, so a reader never
	// sees a truncated catalog (the same contract as the outage state file).
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, body, 0o600); err != nil {
		failGeneric()
		return 1
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		failGeneric()
		return 1
	}
	return 0
}

func validIdentity(identity string) bool {
	if len(identity) != 64 {
		return false
	}
	for _, c := range identity {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func cacheHome() string {
	if dir := os.Getenv("XDG_CACHE_HOME"); dir != "" {
		return dir
	}
	return os.Getenv("HOME") + "/.cache"
}

func xdgState() string {
	if dir := os.Getenv("XDG_STATE_HOME"); dir != "" {
		return dir
	}
	return os.Getenv("HOME") + "/.local/state"
}
