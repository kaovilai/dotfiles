package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func readInflight(t *testing.T, path string) map[string]any {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(body, &doc); err != nil {
		t.Fatal(err)
	}
	return doc
}

// A live proxy is a live reporter: the empty in-flight table is written at
// startup, so idle detection (portServing, the EnMaaS controller's busy) reads
// the table instead of falling back to socket counting, where pooled client
// keep-alives would read busy forever.
func TestUsageLogWritesEmptyInflightAtStartup(t *testing.T) {
	dir := t.TempDir()
	u := newUsageLog(dir, "45998")
	path := filepath.Join(dir, "inflight-45998-"+strconv.Itoa(os.Getpid())+".json")
	doc := readInflight(t, path)
	if requests, ok := doc["requests"].(map[string]any); !ok || len(requests) != 0 {
		t.Fatalf("startup table must exist and be empty, got %v", doc["requests"])
	}
	_ = u
}

// Only empty<->non-empty transitions (and the periodic debounce) rewrite the
// whole in-flight map: steady concurrency must not pay a file rewrite per
// request, while the transitions portServing keys on stay timely.
func TestUsageLogInflightFlushesOnTransitionsOnly(t *testing.T) {
	dir := t.TempDir()
	u := newUsageLog(dir, "45997")
	path := filepath.Join(dir, "inflight-45997-"+strconv.Itoa(os.Getpid())+".json")

	u.start("a", "m", "m")
	if doc := readInflight(t, path); len(doc["requests"].(map[string]any)) != 1 {
		t.Fatalf("the 0->1 transition must flush, got %v", doc["requests"])
	}
	u.start("b", "m", "m") // still non-empty: no rewrite inside the debounce window
	if doc := readInflight(t, path); len(doc["requests"].(map[string]any)) != 1 {
		t.Fatalf("a second start within the debounce window must not rewrite, got %v", doc["requests"])
	}
	u.end("a") // still non-empty (b): no rewrite
	if doc := readInflight(t, path); len(doc["requests"].(map[string]any)) != 1 {
		t.Fatalf("an end that stays non-empty must not rewrite, got %v", doc["requests"])
	}
	u.end("b") // -> empty: flush
	if doc := readInflight(t, path); len(doc["requests"].(map[string]any)) != 0 {
		t.Fatalf("the ->0 transition must flush, got %v", doc["requests"])
	}
}

// The month's events file stays open across writes: one open per month, not
// one per request, and a month rollover opens the new file.
func TestUsageLogKeepsEventsFileOpenAcrossMonths(t *testing.T) {
	dir := t.TempDir()
	u := newUsageLog(dir, "45996")
	event := func(id, ts string) map[string]any {
		return map[string]any{"ts": ts, "ok": true, "id": id}
	}
	u.write(event("e1", "2026-11-20T10:00:00.000Z"))
	u.write(event("e2", "2026-11-21T10:00:00.000Z"))
	u.write(event("e3", "2026-12-01T10:00:00.000Z"))
	for name, want := range map[string]int{"events-2026-11.jsonl": 2, "events-2026-12.jsonl": 1} {
		body, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if got := len(splitLines(body)); got != want {
			t.Fatalf("%s: %d events, want %d", name, got, want)
		}
	}
}

// A deleted/recreated usage dir must not keep feeding the unlinked inode: the
// open handle is re-stat'ed per write and reopened when the path no longer
// resolves to it, so events keep landing in the live file.
func TestUsageLogReopensWhenEventsFileIsReplaced(t *testing.T) {
	dir := t.TempDir()
	u := newUsageLog(dir, "45995")
	event := func(id, ts string) map[string]any {
		return map[string]any{"ts": ts, "ok": true, "id": id}
	}
	u.write(event("e1", "2026-11-20T10:00:00.000Z"))
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	u.write(event("e2", "2026-11-20T11:00:00.000Z"))
	body, err := os.ReadFile(filepath.Join(dir, "events-2026-11.jsonl"))
	if err != nil || !strings.Contains(string(body), `"e2"`) {
		t.Fatalf("the write after the dir was wiped must land in the new file: %v %q", err, body)
	}
	if err := os.Remove(filepath.Join(dir, "events-2026-11.jsonl")); err != nil {
		t.Fatal(err)
	}
	u.write(event("e3", "2026-11-20T12:00:00.000Z"))
	body, err = os.ReadFile(filepath.Join(dir, "events-2026-11.jsonl"))
	if err != nil || !strings.Contains(string(body), `"e3"`) {
		t.Fatalf("the write after the file was replaced must land in the new file: %v %q", err, body)
	}
}

func splitLines(body []byte) []string {
	var lines []string
	start := 0
	for i, b := range body {
		if b == '\n' {
			lines = append(lines, string(body[start:i]))
			start = i + 1
		}
	}
	if start < len(body) {
		lines = append(lines, string(body[start:]))
	}
	return lines
}
