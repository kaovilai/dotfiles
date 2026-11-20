package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	classifierMarker = "security monitor for autonomous AI coding agents"
)

// usageLog writes the same events-YYYY-MM.jsonl lines litellm_usage_log.py
// writes, so `llm-usage` and the menubar keep working on the Go path.
type usageLog struct {
	dir      string
	port     string
	mu       sync.Mutex
	inflight map[string]inflightEntry

	// lastFlush bounds how often the (whole-map) inflight rewrite runs: only
	// empty<->non-empty transitions must be timely — portServing and the
	// EnMaaS controller's busy() key on non-emptiness — while steady
	// concurrency would otherwise rewrite the file twice per request.
	// flushTimer is the trailing flush: a suppressed update (still busy, no
	// transition) schedules one write after the debounce so the table does
	// not hold a stale entry set for the rest of a long request — and a
	// FAILED write (flushDirty) is retried through it, so a stale table
	// never outlives the request state it describes.
	lastFlush  time.Time
	flushTimer *time.Timer
	flushDirty bool

	// The events file stays open across writes: one open+append+close per
	// request was three syscalls and a path lookup on the hot path. eventsStat
	// is the FileInfo it was opened with: a deleted/recreated usage dir would
	// otherwise keep feeding an unlinked inode (events silently lost), so each
	// write re-stats the path and reopens when the file is gone or replaced.
	eventsPath string
	eventsFile *os.File
	eventsStat os.FileInfo
}

type inflightEntry struct {
	T         float64 `json:"t"`
	Model     string  `json:"model"`
	Requested string  `json:"requested"`
}

func newUsageLog(dir, port string) *usageLog {
	u := &usageLog{dir: dir, port: port, inflight: map[string]inflightEntry{}}
	u.cleanupInflight()
	// Write the (empty) inflight table immediately: a live proxy is then
	// always a live reporter, so idle detection (portServing, the EnMaaS
	// controller's busy) reads the table instead of falling back to socket
	// counting — where a client's pooled keep-alive connections would read
	// busy forever and defer every restart. An empty dir means usage logging
	// is not configured (handmade test configs): write nothing.
	if dir != "" {
		u.flush()
	}
	return u
}

func (u *usageLog) inflightPath() string {
	return filepath.Join(u.dir, fmt.Sprintf("inflight-%s-%d.json", u.port, os.Getpid()))
}

func (u *usageLog) cleanupInflight() {
	matches, err := filepath.Glob(filepath.Join(u.dir, "inflight-"+u.port+"-*.json"))
	if err != nil {
		return
	}
	for _, path := range matches {
		base := filepath.Base(path)
		base = strings.TrimSuffix(base, ".json")
		idx := strings.LastIndexByte(base, '-')
		if idx < 0 {
			continue
		}
		pid, err := strconv.Atoi(base[idx+1:])
		if err != nil {
			continue
		}
		if pid == os.Getpid() || !pidAlive(pid) {
			_ = os.Remove(path)
		}
	}
}

func pidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	if err == nil {
		return true
	}
	return err == syscall.EPERM
}

// flush must be called with u.mu held. It never prunes: an entry leaves the
// table only when its request ends (idle detection keys on non-emptiness, so
// dropping a still-streaming request would mark a busy proxy idle and make
// it restart-eligible mid-request). A crashed proxy's leftovers are handled
// by pid liveness at the readers and cleanupInflight at the next start —
// not by age. A failed write keeps the previous table published, so it
// stays dirty and the trailing timer retries: a stale table must not
// outlive the request state it describes.
func (u *usageLog) flush() {
	u.lastFlush = time.Now()
	if u.flushTimer != nil {
		u.flushTimer.Stop()
		u.flushTimer = nil
	}
	now := float64(u.lastFlush.UnixNano()) / 1e9
	payload := map[string]any{
		"pid":      os.Getpid(),
		"port":     u.port,
		"updated":  now,
		"requests": u.inflight,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		u.flushFailed()
		return
	}
	if err := os.MkdirAll(u.dir, 0o700); err != nil {
		u.flushFailed()
		return
	}
	tmp := u.inflightPath() + ".tmp"
	if err := os.WriteFile(tmp, body, 0o600); err != nil {
		u.flushFailed()
		return
	}
	if err := os.Rename(tmp, u.inflightPath()); err != nil {
		u.flushFailed()
		return
	}
	u.flushDirty = false
}

// flushFailed must be called with u.mu held: the previously published table
// no longer describes this map, so drop it — readers then fall back to
// socket counting instead of trusting a stale table — and retry through the
// trailing timer for as long as the failure lasts.
func (u *usageLog) flushFailed() {
	u.flushDirty = true
	_ = os.Remove(u.inflightPath())
	u.scheduleTrailingFlush()
}

// inflightFlushAfter is the steady-state debounce: transitions flush at once,
// anything else at most this often. 5s keeps the table current enough for the
// llm-usage in-flight views while capping the whole-map rewrite under
// sustained concurrency (the old cost was a rewrite per request start AND
// end).
const inflightFlushAfter = 5 * time.Second

// scheduleTrailingFlush must be called with u.mu held: a suppressed update
// still owes the file one write after the debounce window, or a long request
// keeps a stale entry set (an ended request listed, a running one missing)
// until its own end flushes. It also carries the retry of a failed write.
func (u *usageLog) scheduleTrailingFlush() {
	if u.flushTimer != nil {
		return
	}
	u.flushTimer = time.AfterFunc(inflightFlushAfter, func() {
		u.mu.Lock()
		defer u.mu.Unlock()
		u.flushTimer = nil
		if len(u.inflight) > 0 || u.flushDirty {
			u.flush()
		}
	})
}

func (u *usageLog) start(id, model, requested string) {
	if id == "" {
		return
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	empty := len(u.inflight) == 0
	u.inflight[id] = inflightEntry{
		T:         float64(time.Now().UnixNano()) / 1e9,
		Model:     model,
		Requested: requested,
	}
	if empty || time.Since(u.lastFlush) > inflightFlushAfter {
		u.flush()
	} else {
		u.scheduleTrailingFlush()
	}
}

func (u *usageLog) end(id string) {
	if id == "" {
		return
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	if _, ok := u.inflight[id]; ok {
		delete(u.inflight, id)
		if len(u.inflight) == 0 || time.Since(u.lastFlush) > inflightFlushAfter {
			u.flush()
		} else {
			u.scheduleTrailingFlush()
		}
	}
}

// write appends one event line; nil values are dropped like the Python logger.
func (u *usageLog) write(event map[string]any) {
	event["port"] = u.port
	for k, v := range event {
		if v == nil {
			delete(event, k)
		}
	}
	ts, _ := event["ts"].(string)
	if len(ts) < 7 {
		return
	}
	// ts reaches a filename (events-YYYY-MM.jsonl): map data is not trusted
	// in a path expression, so require exactly the ISO date shape.
	if !isoMonthPrefix(ts) {
		return
	}
	body, err := json.Marshal(event)
	if err != nil {
		return
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	// Rebuild the month from the parsed numbers after the shape check: the
	// filename never carries a string taken from the event map, so the
	// analyzer sees ints, not tainted text (the map holds request-derived
	// values under other keys and CodeQL cannot tell the keys apart).
	year, _ := strconv.Atoi(ts[:4])
	month, _ := strconv.Atoi(ts[5:7])
	path := filepath.Join(u.dir, fmt.Sprintf("events-%04d-%02d.jsonl", year, month))
	// The month file stays open across writes (one open per process per
	// month, not one per request); a failed open is retried on the next
	// event by remembering only the path that is actually open, and a path
	// that no longer resolves to the opened inode (deleted/recreated usage
	// dir) reopens instead of appending into a lost file.
	reopen := u.eventsFile == nil || u.eventsPath != path
	if !reopen {
		if st, err := os.Stat(path); err != nil || u.eventsStat == nil || !os.SameFile(st, u.eventsStat) {
			reopen = true
		}
	}
	if reopen {
		if u.eventsFile != nil {
			_ = u.eventsFile.Close()
			u.eventsFile, u.eventsStat = nil, nil
		}
		_ = os.MkdirAll(u.dir, 0o700)
		file, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
		if err != nil {
			return
		}
		u.eventsFile, u.eventsPath = file, path
		if st, err := file.Stat(); err == nil {
			u.eventsStat = st
		}
	}
	if _, err := u.eventsFile.Write(append(body, '\n')); err != nil {
		// A failed write (ENOSPC/EIO) leaves the handle suspect: drop it so
		// the next event re-opens instead of appending into a dead fd.
		_ = u.eventsFile.Close()
		u.eventsFile, u.eventsStat = nil, nil
	}
}

// isoMonthPrefix reports whether s starts with YYYY-MM (digits and the one
// dash at index 4).
func isoMonthPrefix(s string) bool {
	for i := 0; i < 7; i++ {
		if i == 4 {
			if s[i] != '-' {
				return false
			}
			continue
		}
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func isoNow(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000Z")
}

func clientFromUA(ua string) string {
	lower := strings.ToLower(ua)
	switch {
	case strings.Contains(lower, "claude-cli"), strings.Contains(lower, "claude-code"), strings.Contains(lower, "anthropic"):
		return "claude-code"
	case strings.Contains(lower, "codex"):
		return "codex"
	case strings.Contains(lower, "t3"):
		return "t3"
	case strings.Contains(lower, "curl"):
		return "curl"
	}
	base := strings.SplitN(lower, "/", 2)[0]
	if base == "" {
		return "unknown"
	}
	if len(base) > 24 {
		base = base[:24]
	}
	return base
}

// headText mirrors litellm_usage_log._head_text, used only for role detection.
func headText(data map[string]any) string {
	var parts []string
	if system, ok := data["system"]; ok {
		switch s := system.(type) {
		case string:
			parts = append(parts, truncate(s, 2000))
		default:
			parts = append(parts, truncate(string(marshal(s)), 2000))
		}
	}
	if messages, ok := data["messages"].([]any); ok {
		for i, message := range messages {
			if i >= 2 {
				break
			}
			m := asMap(message)
			if m == nil {
				continue
			}
			if content, ok := m["content"].(string); ok {
				parts = append(parts, truncate(content, 2000))
			} else if m["content"] != nil {
				parts = append(parts, truncate(string(marshal(m["content"])), 2000))
			}
		}
	}
	return truncate(strings.Join(parts, " "), 4000)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// usageInfo is the token view of a response, in Anthropic semantics.
type usageInfo struct {
	In         int
	Out        int
	CacheRead  int
	CacheWrite int
	Reasoning  int
}

func (u usageInfo) empty() bool {
	return u.In == 0 && u.Out == 0 && u.CacheRead == 0 && u.CacheWrite == 0
}

// usageFromJSON reads usage from a response body: Anthropic Messages, OpenAI
// chat completions, or the Responses API.
func usageFromJSON(body []byte) usageInfo {
	var data map[string]any
	if err := json.Unmarshal(body, &data); err != nil {
		return usageInfo{}
	}
	return usageFromObject(data)
}

func usageFromObject(data map[string]any) usageInfo {
	usage := asMap(data["usage"])
	if usage == nil {
		if resp := asMap(data["response"]); resp != nil {
			usage = asMap(resp["usage"])
		}
	}
	if usage == nil {
		return usageInfo{}
	}
	info := usageInfo{}
	if v, ok := asInt(usage["input_tokens"]); ok {
		info.In = v
	}
	if v, ok := asInt(usage["output_tokens"]); ok {
		info.Out = v
	}
	if v, ok := asInt(usage["cache_read_input_tokens"]); ok {
		info.CacheRead = v
	}
	if v, ok := asInt(usage["cache_creation_input_tokens"]); ok {
		info.CacheWrite = v
	}
	// Cache details are read before normalizing input: OpenAI's prompt_tokens /
	// input_tokens include cached tokens, so subtracting them afterwards would
	// double count (in: 100, cache_read: 80 must become in: 20).
	if details := asMap(usage["prompt_tokens_details"]); details != nil {
		if v, ok := asInt(details["cached_tokens"]); ok {
			info.CacheRead = v
		}
	}
	if details := asMap(usage["input_tokens_details"]); details != nil {
		if v, ok := asInt(details["cached_tokens"]); ok {
			info.CacheRead = v
		}
	}
	if details := asMap(usage["completion_tokens_details"]); details != nil {
		if v, ok := asInt(details["reasoning_tokens"]); ok {
			info.Reasoning = v
		}
	}

	openai := false
	if prompt, ok := asInt(usage["prompt_tokens"]); ok {
		info.In = prompt
		openai = true
	}
	if completion, ok := asInt(usage["completion_tokens"]); ok {
		info.Out = completion
		openai = true
	}
	if details := asMap(usage["input_tokens_details"]); details != nil {
		openai = true
	}
	if openai {
		info.In -= info.CacheRead + info.CacheWrite
		if info.In < 0 {
			info.In = 0
		}
	}
	if v, ok := asInt(usage["reasoning_tokens"]); ok && info.Reasoning == 0 {
		info.Reasoning = v
	}
	return info
}
