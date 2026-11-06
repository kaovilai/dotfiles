package main

// Inline image budget prune, ported from hosted_only_hooks.py item 6.
//
// The gateway caps each request body (10 MiB; 413 beyond) and Claude Code and
// Codex resend the whole history every turn with every viewed image inline as
// base64, so an image-heavy review loop crosses the cap after ~50 images. When
// the content fields serialize past ImageBudget, inline image blocks are
// replaced oldest-first with a text block until the body fits. The text names
// where the image still lives (the tool call's path argument, a matching T3
// attachment, a content-addressed copy this proxy keeps for a day) so the
// model can re-view it on demand. The same bytes always give the same text, so
// the replaced prefix stays stable for prompt caching across turns.

import (
	"crypto/sha1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const pruneMarker = "[image-pruned]"

var imageContentKeys = []string{"messages", "input", "system", "instructions", "tools"}

// imagePayload is the (base64 text, mime) of an inline image block; ok is
// false for URLs and file ids.
func imagePayload(block map[string]any) (data, mime string, ok bool) {
	var url any
	switch asString(block["type"]) {
	case "input_image":
		url = block["image_url"]
	case "image_url":
		url = block["image_url"]
		if m := asMap(url); m != nil {
			url = m["url"]
		}
	case "image":
		source := asMap(block["source"])
		if source == nil || asString(source["type"]) != "base64" {
			return "", "", false
		}
		data = asString(source["data"])
		if data == "" {
			return "", "", false
		}
		mime = asString(source["media_type"])
		if mime == "" {
			mime = "image/png"
		}
		return data, mime, true
	default:
		return "", "", false
	}
	text, isString := url.(string)
	if !isString || !strings.HasPrefix(text, "data:") {
		return "", "", false
	}
	header, data, found := strings.Cut(text, ",")
	if !found || !strings.Contains(header, ";base64") || data == "" {
		return "", "", false
	}
	mime = strings.SplitN(strings.TrimPrefix(header, "data:"), ";", 2)[0]
	if mime == "" {
		mime = "image/png"
	}
	return data, mime, true
}

type imageRef struct {
	parent []any
	index  int
	block  map[string]any
	anchor string // id of the enclosing tool call / result
}

// collectImages gathers inline image blocks in document order (oldest first),
// each with the list that holds it so it can be replaced in place. Dict keys
// are walked sorted: Go maps have no order and the replaced set must be
// deterministic for prompt caching.
func collectImages(node any, parent []any, index int, anchor string, out *[]imageRef) {
	switch v := node.(type) {
	case map[string]any:
		if imageBlockTypes[asString(v["type"])] {
			if _, _, ok := imagePayload(v); ok {
				if parent != nil {
					*out = append(*out, imageRef{parent: parent, index: index, block: v, anchor: anchor})
				}
				return
			}
		}
		if own := asString(v["call_id"]); own != "" {
			anchor = own
		} else if own := asString(v["tool_use_id"]); own != "" {
			anchor = own
		}
		keys := make([]string, 0, len(v))
		for key := range v {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			switch child := v[key].(type) {
			case map[string]any, []any:
				collectImages(child, nil, 0, anchor, out)
			}
		}
	case []any:
		for i, child := range v {
			collectImages(child, v, i, anchor, out)
		}
	}
}

func pathFromArgs(args any) string {
	if text, ok := args.(string); ok {
		var parsed any
		if json.Unmarshal([]byte(text), &parsed) != nil {
			return ""
		}
		args = parsed
	}
	m := asMap(args)
	if m == nil {
		return ""
	}
	for _, name := range []string{"path", "file_path", "image_path", "image"} {
		if value, ok := m[name].(string); ok && strings.TrimSpace(value) != "" && strings.Contains(value, "/") {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

// toolPathIndex maps a tool call id to its file path argument, for Responses
// function_call items, Anthropic tool_use blocks and chat tool_calls.
func toolPathIndex(data map[string]any) map[string]string {
	index := map[string]string{}
	for _, item := range asList(data["input"]) {
		m := asMap(item)
		if m == nil || asString(m["type"]) != "function_call" {
			continue
		}
		if path := pathFromArgs(m["arguments"]); path != "" && asString(m["call_id"]) != "" {
			index[asString(m["call_id"])] = path
		}
	}
	for _, message := range asList(data["messages"]) {
		m := asMap(message)
		if m == nil {
			continue
		}
		for _, block := range asList(m["content"]) {
			b := asMap(block)
			if b == nil || asString(b["type"]) != "tool_use" {
				continue
			}
			if path := pathFromArgs(b["input"]); path != "" && asString(b["id"]) != "" {
				index[asString(b["id"])] = path
			}
		}
		for _, call := range asList(m["tool_calls"]) {
			c := asMap(call)
			if c == nil {
				continue
			}
			if path := pathFromArgs(asMap(c["function"])["arguments"]); path != "" && asString(c["id"]) != "" {
				index[asString(c["id"])] = path
			}
		}
	}
	return index
}

// --- T3 attachment match -----------------------------------------------------

type hashKey struct {
	path  string
	size  int64
	mtime int64
}

var attachmentIndex struct {
	mu     sync.Mutex
	dir    string
	mtime  int64
	bySHA  map[string]string
	hashed map[hashKey]string
}

// attachmentMatch is the path of a T3 attachment whose bytes hash to sha. Files
// are hashed once per (size, mtime); the index is rebuilt when the directory
// changes.
func attachmentMatch(dir, sha string) string {
	info, err := os.Stat(dir)
	if err != nil {
		return ""
	}
	state := &attachmentIndex
	state.mu.Lock()
	defer state.mu.Unlock()
	stamp := info.ModTime().UnixNano()
	if state.bySHA == nil || state.dir != dir || state.mtime != stamp {
		bySHA := map[string]string{}
		hashed := state.hashed
		if hashed == nil {
			hashed = map[hashKey]string{}
		}
		entries, _ := os.ReadDir(dir)
		for _, entry := range entries {
			name := strings.ToLower(entry.Name())
			if !entry.Type().IsRegular() || !(strings.HasSuffix(name, ".png") || strings.HasSuffix(name, ".jpg") ||
				strings.HasSuffix(name, ".jpeg") || strings.HasSuffix(name, ".gif") || strings.HasSuffix(name, ".webp")) {
				continue
			}
			path := filepath.Join(dir, entry.Name())
			fi, err := entry.Info()
			if err != nil {
				continue
			}
			key := hashKey{path, fi.Size(), fi.ModTime().UnixNano()}
			digest, ok := hashed[key]
			if !ok {
				body, err := os.ReadFile(path)
				if err != nil {
					continue
				}
				sum := sha1.Sum(body)
				digest = hex.EncodeToString(sum[:])
				hashed[key] = digest
			}
			bySHA[digest] = path
		}
		live := map[string]bool{}
		for _, path := range bySHA {
			live[path] = true
		}
		for key := range hashed {
			if !live[key.path] {
				delete(hashed, key)
			}
		}
		state.bySHA, state.hashed, state.dir, state.mtime = bySHA, hashed, dir, stamp
	}
	return state.bySHA[sha]
}

// --- proxy-side copy ----------------------------------------------------------

var cacheSweep struct {
	mu sync.Mutex
	at time.Time
}

var mimeExt = map[string]string{"image/jpeg": "jpg", "image/jpg": "jpg", "image/gif": "gif", "image/webp": "webp"}

// cacheImage keeps a copy of pruned image bytes at <dir>/<sha>.<ext> and
// returns the path, or "" when caching is off or failed. Expired copies are
// swept hourly.
func cacheImage(cfg *config, raw []byte, sha, mime string, now time.Time) string {
	if cfg.ImageCacheDays <= 0 {
		return ""
	}
	dir := cfg.ImageCacheDir
	if err := os.MkdirAll(dir, 0o700); err != nil {
		log.Printf("hosted-only-go: image cache unavailable: %v", err)
		return ""
	}
	ext := mimeExt[mime]
	if ext == "" {
		ext = "png"
	}
	path := filepath.Join(dir, sha+"."+ext)
	if _, err := os.Stat(path); err == nil {
		_ = os.Chtimes(path, now, now)
	} else {
		tmp, err := os.CreateTemp(dir, sha+".*.tmp")
		if err != nil {
			log.Printf("hosted-only-go: image cache unavailable: %v", err)
			return ""
		}
		_, werr := tmp.Write(raw)
		cerr := tmp.Close()
		if werr != nil || cerr != nil || os.Rename(tmp.Name(), path) != nil {
			_ = os.Remove(tmp.Name())
			return ""
		}
	}
	cacheSweep.mu.Lock()
	sweep := now.Sub(cacheSweep.at) > time.Hour
	if sweep {
		cacheSweep.at = now
	}
	cacheSweep.mu.Unlock()
	if sweep {
		cutoff := now.Add(-time.Duration(cfg.ImageCacheDays) * 24 * time.Hour)
		entries, _ := os.ReadDir(dir)
		for _, entry := range entries {
			if !entry.Type().IsRegular() {
				continue
			}
			if fi, err := entry.Info(); err == nil && fi.ModTime().Before(cutoff) {
				_ = os.Remove(filepath.Join(dir, entry.Name()))
			}
		}
	}
	return path
}

func prunePlaceholder(source, attachment, cached string, days int) string {
	var where []string
	if source != "" {
		where = append(where, "source file "+source)
	}
	if attachment != "" {
		where = append(where, "T3 attachment "+attachment)
	}
	if cached != "" {
		plural := "s"
		if days == 1 {
			plural = ""
		}
		where = append(where, fmt.Sprintf("proxy copy %s (kept %d day%s)", cached, days, plural))
	}
	tail := ". Re-create and view it again if you need it."
	if len(where) > 0 {
		tail = "; it is still at " + strings.Join(where, ", ") + ". View that path again if you need the image."
	}
	return pruneMarker + " Image removed by the local proxy to keep this request under the gateway's body limit" + tail
}

func pruneReplacement(block map[string]any, text string) map[string]any {
	if asString(block["type"]) == "input_image" {
		return map[string]any{"type": "input_text", "text": text}
	}
	return map[string]any{"type": "text", "text": text}
}

// imageLoad is (bytes of inline image payloads, number of image blocks) in a
// content tree. The clamp uses it so base64 is not priced as text: the JSON
// bytes of an image are ~1000x its token cost, which made image-heavy turns
// look over-limit long before they were.
func imageLoad(value any) (size, count int) {
	switch v := value.(type) {
	case map[string]any:
		if imageBlockTypes[asString(v["type"])] {
			src := v["image_url"]
			if src == nil {
				src = v["source"]
			}
			if src == nil {
				src = v["data"]
			}
			if m := asMap(src); m != nil {
				if u := asString(m["url"]); u != "" {
					src = u
				} else {
					src = asString(m["data"])
				}
			}
			if text, ok := src.(string); ok && text != "" {
				return len(text), 1
			}
		}
		for _, child := range v {
			b, c := imageLoad(child)
			size += b
			count += c
		}
	case []any:
		for _, child := range v {
			b, c := imageLoad(child)
			size += b
			count += c
		}
	}
	return size, count
}

// pruneImages replaces inline images, oldest first, until the content fits the
// budget, and returns how many it replaced.
func pruneImages(cfg *config, data map[string]any) int {
	if cfg.ImageBudget <= 0 {
		return 0
	}
	history := asList(data["messages"])
	if len(history) == 0 {
		history = asList(data["input"])
	}
	if !hasImage(history) {
		return 0
	}
	size := contentSize(data)
	before := size
	if size <= cfg.ImageBudget {
		return 0
	}
	var blocks []imageRef
	collectImages(data["messages"], nil, 0, "", &blocks)
	collectImages(data["input"], nil, 0, "", &blocks)
	if len(blocks) == 0 {
		return 0
	}
	index := toolPathIndex(data)
	now := time.Now()
	pruned := 0
	for _, ref := range blocks {
		if size <= cfg.ImageBudget {
			break
		}
		encoded, mime, ok := imagePayload(ref.block)
		if !ok {
			continue
		}
		var sha, cached, attachment string
		if raw, err := base64.StdEncoding.DecodeString(encoded); err == nil && len(raw) > 0 {
			sum := sha1.Sum(raw)
			sha = hex.EncodeToString(sum[:])
			cached = cacheImage(cfg, raw, sha, mime, now)
		} else if raw, err := base64.RawStdEncoding.DecodeString(encoded); err == nil && len(raw) > 0 {
			sum := sha1.Sum(raw)
			sha = hex.EncodeToString(sum[:])
			cached = cacheImage(cfg, raw, sha, mime, now)
		}
		if sha != "" {
			attachment = attachmentMatch(cfg.AttachmentsDir, sha)
		}
		text := prunePlaceholder(index[ref.anchor], attachment, cached, cfg.ImageCacheDays)
		ref.parent[ref.index] = pruneReplacement(ref.block, text)
		size -= len(encoded) - len(text)
		pruned++
	}
	if pruned > 0 {
		log.Printf("hosted-only-go: pruned %d of %d inline images for %s (content %d -> ~%d bytes, budget %d)",
			pruned, len(blocks), asString(data["model"]), before, size, cfg.ImageBudget)
	}
	return pruned
}
