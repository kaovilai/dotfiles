package main

import (
	"crypto/sha1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// These mirror the image-prune and per-image pricing cases in
// tests/hosted-only-proxy.zsh so the Go proxy keeps the same observable
// behavior as hosted_only_hooks.py item 6 and the #600 clamp fix.

func png(seed byte, size int) []byte {
	return append([]byte("\x89PNG"), []byte(strings.Repeat(string([]byte{seed}), size))...)
}

func dataURL(b64 string) string { return "data:image/png;base64," + b64 }

func sha1hex(b []byte) string {
	sum := sha1.Sum(b)
	return hex.EncodeToString(sum[:])
}

type imageFixture struct {
	cfg  *config
	imgs [][]byte
	b64  []string
	dir  string
}

func newImageFixture(t *testing.T) *imageFixture {
	t.Helper()
	dir := t.TempDir()
	cfg := &config{
		ImageBudget:    2500000,
		ImageTokens:    2500,
		ImageCacheDays: 5,
		ImageCacheDir:  filepath.Join(dir, "cache"),
		AttachmentsDir: filepath.Join(dir, "attachments"),
	}
	if err := os.MkdirAll(cfg.AttachmentsDir, 0o700); err != nil {
		t.Fatal(err)
	}
	f := &imageFixture{cfg: cfg, dir: dir}
	for i := 0; i < 4; i++ {
		img := png(byte(i), 4000)
		f.imgs = append(f.imgs, img)
		f.b64 = append(f.b64, base64.StdEncoding.EncodeToString(img))
	}
	// imgs[3] is a pasted T3 attachment: a byte-identical file in the dir.
	if err := os.WriteFile(filepath.Join(cfg.AttachmentsDir, "thread-att.png"), f.imgs[3], 0o600); err != nil {
		t.Fatal(err)
	}
	return f
}

// responsesReq is a Responses-shaped history: three tool-produced images with
// path arguments, then a pasted one in the newest user turn. Built from JSON so
// the tree has the exact types the proxy decodes.
func (f *imageFixture) responsesReq(t *testing.T) map[string]any {
	t.Helper()
	call := func(id, path string) map[string]any {
		args, _ := json.Marshal(map[string]string{"path": path})
		return map[string]any{"type": "function_call", "name": "view_image", "call_id": id, "arguments": string(args)}
	}
	output := func(id string, i int) map[string]any {
		return map[string]any{"type": "function_call_output", "call_id": id,
			"output": []any{map[string]any{"type": "input_image", "image_url": dataURL(f.b64[i])}}}
	}
	return map[string]any{
		"model":        "rits/deepseek-ai/DeepSeek-V4.1-Flash-1017",
		"instructions": "sys",
		"input": []any{
			map[string]any{"role": "user", "content": []any{map[string]any{"type": "input_text", "text": "look"}}},
			call("c1", "/tmp/slides/4.png"), output("c1", 0),
			call("c2", "/tmp/slides/5.png"), output("c2", 1),
			call("c3", "/tmp/slides/6.png"), output("c3", 2),
			map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "input_text", "text": "and this"},
				map[string]any{"type": "input_image", "image_url": dataURL(f.b64[3])},
			}},
		},
		// LiteLLM-style bookkeeping must not count toward the content size.
		"proxy_server_request": map[string]any{"body": strings.Repeat("x", 100000)},
	}
}

func outputBlock(req map[string]any, item int) map[string]any {
	return asMap(asList(asMap(asList(req["input"])[item])["output"])[0])
}

func TestPruneImagesOldestFirstWithSources(t *testing.T) {
	f := newImageFixture(t)
	full := contentSize(f.responsesReq(t))
	if full <= 4*len(f.b64[0]) {
		t.Fatalf("fixture too small: %d", full)
	}
	if n := pruneImages(f.cfg, f.responsesReq(t)); n != 0 {
		// default budget is 2.5 MB: this small fixture fits untouched
		t.Fatalf("fits the default budget: pruned %d", n)
	}
	f.cfg.ImageBudget = full
	if n := pruneImages(f.cfg, f.responsesReq(t)); n != 0 {
		t.Fatalf("at the budget exactly: pruned %d", n)
	}
	f.cfg.ImageBudget = 0
	if n := pruneImages(f.cfg, f.responsesReq(t)); n != 0 {
		t.Fatalf("budget 0 is off: pruned %d", n)
	}

	// room for exactly two images: the two oldest go, the two newest stay
	budget := full - 2*len(f.b64[0]) + 1000
	f.cfg.ImageBudget = budget
	req := f.responsesReq(t)
	if n := pruneImages(f.cfg, req); n != 2 {
		t.Fatalf("want 2 pruned, got %d", n)
	}
	if size := contentSize(req); size > budget {
		t.Fatalf("still over budget: %d > %d", size, budget)
	}
	out1, out2, out3 := outputBlock(req, 2), outputBlock(req, 4), outputBlock(req, 6)
	user := asMap(asList(asMap(asList(req["input"])[7])["content"])[1])
	text1 := asString(out1["text"])
	if asString(out1["type"]) != "input_text" || !strings.Contains(text1, pruneMarker) || !strings.Contains(text1, "source file /tmp/slides/4.png") {
		t.Fatalf("first image note: %v", out1)
	}
	if asString(out2["type"]) != "input_text" || !strings.Contains(asString(out2["text"]), "source file /tmp/slides/5.png") {
		t.Fatalf("second image note: %v", out2)
	}
	if asString(out3["type"]) != "input_image" || asString(user["type"]) != "input_image" {
		t.Fatal("the two newest images must survive")
	}
	sha0 := sha1hex(f.imgs[0])
	want := "proxy copy " + f.cfg.ImageCacheDir + "/" + sha0 + ".png (kept 5 days)"
	if !strings.Contains(text1, want) {
		t.Fatalf("missing %q in %q", want, text1)
	}
	if body, err := os.ReadFile(filepath.Join(f.cfg.ImageCacheDir, sha0+".png")); err != nil || string(body) != string(f.imgs[0]) {
		t.Fatalf("cached copy missing or wrong: %v", err)
	}

	// The note states the days in effect (singular for 1).
	one := f.responsesReq(t)
	oneCfg := *f.cfg
	oneCfg.ImageBudget = 1000
	oneCfg.ImageCacheDays = 1
	oneCfg.ImageCacheDir = filepath.Join(f.dir, "cache1")
	pruneImages(&oneCfg, one)
	if !strings.Contains(asString(outputBlock(one, 2)["text"]), "(kept 1 day)") {
		t.Fatalf("singular day: %v", outputBlock(one, 2))
	}

	// Replaying the same history next turn gives the same text, no new cache
	// files: the replaced prefix stays stable for prompt caching.
	again := f.responsesReq(t)
	pruneImages(f.cfg, again)
	if asString(outputBlock(again, 2)["text"]) != text1 {
		t.Fatal("replacement text is not stable across turns")
	}
	entries, _ := os.ReadDir(f.cfg.ImageCacheDir)
	if len(entries) != 2 {
		t.Fatalf("want 2 cached copies, got %d", len(entries))
	}
}

func TestPruneImagesAttachmentCacheOffAndGenericNotes(t *testing.T) {
	f := newImageFixture(t)
	f.cfg.ImageBudget = 1000
	req := f.responsesReq(t)
	if n := pruneImages(f.cfg, req); n != 4 {
		t.Fatalf("prune everything: %d", n)
	}
	note := asMap(asList(asMap(asList(req["input"])[7])["content"])[1])
	text := asString(note["text"])
	if asString(note["type"]) != "input_text" || !strings.Contains(text, "T3 attachment "+f.cfg.AttachmentsDir+"/thread-att.png") ||
		strings.Contains(text, "source file") || !strings.Contains(text, "View that path again") {
		t.Fatalf("pasted image note: %v", note)
	}

	// cache off: no copy is made, the note still names the source file
	off := *f.cfg
	off.ImageCacheDays = 0
	off.ImageCacheDir = filepath.Join(f.dir, "nocache")
	req = f.responsesReq(t)
	pruneImages(&off, req)
	if strings.Contains(asString(outputBlock(req, 2)["text"]), "proxy copy") {
		t.Fatal("cache off must not mention a proxy copy")
	}
	if _, err := os.Stat(off.ImageCacheDir); err == nil {
		t.Fatal("cache off must not create the cache dir")
	}

	// no path known at all: generic note
	bare := map[string]any{"model": "m", "input": []any{map[string]any{"role": "user",
		"content": []any{map[string]any{"type": "input_image", "image_url": dataURL(f.b64[0])}}}}}
	tiny := off
	tiny.ImageBudget = 10
	pruneImages(&tiny, bare)
	got := asString(asMap(asList(asMap(asList(bare["input"])[0])["content"])[0])["text"])
	if !strings.Contains(got, "Re-create and view it again") {
		t.Fatalf("generic note: %q", got)
	}
}

func TestPruneImagesAnthropicChatAndSkips(t *testing.T) {
	f := newImageFixture(t)
	msgs := map[string]any{"model": "rits/zai-org/glm-5-3", "system": "s", "messages": []any{
		map[string]any{"role": "assistant", "content": []any{map[string]any{"type": "tool_use", "id": "t1", "name": "Read",
			"input": map[string]any{"file_path": "/Users/x/shot.png"}}}},
		map[string]any{"role": "user", "content": []any{map[string]any{"type": "tool_result", "tool_use_id": "t1", "content": []any{
			map[string]any{"type": "image", "source": map[string]any{"type": "base64", "media_type": "image/png", "data": f.b64[0]}}}}}},
		map[string]any{"role": "user", "content": []any{
			map[string]any{"type": "text", "text": "hi"},
			map[string]any{"type": "image", "source": map[string]any{"type": "base64", "media_type": "image/jpeg", "data": f.b64[1]}}}},
	}}
	f.cfg.ImageBudget = len(f.b64[1]) + 1500
	if n := pruneImages(f.cfg, msgs); n != 1 {
		t.Fatalf("anthropic shape: pruned %d", n)
	}
	result := asMap(asList(asMap(asList(msgs["messages"])[1])["content"])[0])
	blk := asMap(asList(result["content"])[0])
	if asString(blk["type"]) != "text" || !strings.Contains(asString(blk["text"]), "source file /Users/x/shot.png") {
		t.Fatalf("anthropic image note: %v", blk)
	}
	newest := asMap(asList(asMap(asList(msgs["messages"])[2])["content"])[1])
	if asString(newest["type"]) != "image" {
		t.Fatal("the newest image survives")
	}

	chat := map[string]any{"model": "m", "messages": []any{
		map[string]any{"role": "assistant", "tool_calls": []any{map[string]any{"id": "k1", "type": "function",
			"function": map[string]any{"name": "shot", "arguments": `{"path": "/tmp/a.png"}`}}}},
		map[string]any{"role": "tool", "tool_call_id": "k1", "content": []any{
			map[string]any{"type": "image_url", "image_url": map[string]any{"url": dataURL(f.b64[0])}}}},
	}}
	f.cfg.ImageBudget = 10
	if n := pruneImages(f.cfg, chat); n != 1 {
		t.Fatalf("chat shape: pruned %d", n)
	}
	chatBlock := asMap(asList(asMap(asList(chat["messages"])[1])["content"])[0])
	// Python's anchor reads call_id / tool_use_id only, so a chat tool_call_id
	// does not resolve to the call's path; parity keeps it that way.
	if asString(chatBlock["type"]) != "text" || !strings.Contains(asString(chatBlock["text"]), pruneMarker) {
		t.Fatalf("chat image note: %v", chatBlock)
	}

	// URL and file-id images carry no bytes: never counted, never replaced
	ref := map[string]any{"model": "m", "input": []any{map[string]any{"role": "user", "content": []any{
		map[string]any{"type": "input_image", "file_id": "f1"},
		map[string]any{"type": "input_image", "image_url": "https://x/y.png"}}}}}
	f.cfg.ImageBudget = 1
	if n := pruneImages(f.cfg, ref); n != 0 {
		t.Fatalf("URL images pruned: %d", n)
	}
}

func TestCacheSweepExpiresStaleCopies(t *testing.T) {
	f := newImageFixture(t)
	if err := os.MkdirAll(f.cfg.ImageCacheDir, 0o700); err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(f.cfg.ImageCacheDir, "deadbeef.png")
	if err := os.WriteFile(stale, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Unix(1, 0)
	_ = os.Chtimes(stale, old, old)
	cacheSweep.mu.Lock()
	cacheSweep.at = time.Time{}
	cacheSweep.mu.Unlock()
	path := cacheImage(f.cfg, f.imgs[2], sha1hex(f.imgs[2]), "image/png", time.Now())
	if path == "" {
		t.Fatal("cache write failed")
	}
	if _, err := os.Stat(stale); err == nil {
		t.Fatal("the stale copy must be swept")
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal("the fresh copy must stay")
	}
}

// Images are priced per image, not as base64 text (2026-11-06 audit: 20 x
// 120 KiB images tripped the compaction hint on a small real load).
func TestClampPricesImagesPerImage(t *testing.T) {
	cfg := &config{GLM: "g", DeepSeek: "d", Aliases: map[string]struct{}{}, MaxModelLen: 1048576,
		OutputReserve: 512, MinOutput: 16000, BytesPerToken: 3, ImageTokens: 2500}
	content := make([]any, 20)
	for i := range content {
		content[i] = map[string]any{"type": "image_url", "image_url": map[string]any{"url": "data:image/png;base64," + strings.Repeat("A", 122880)}}
	}
	imgs := map[string]any{"model": "d", "messages": []any{map[string]any{"role": "user", "content": content}}, "max_tokens": json.Number("128000")}
	if e, _ := clampOutput(cfg, imgs); e != nil {
		t.Fatalf("base64 bytes must not count as text tokens: %v", e.Message)
	}

	many := make([]any, 500)
	for i := range many {
		many[i] = map[string]any{"type": "image", "source": map[string]any{"type": "base64", "data": strings.Repeat("A", 100)}}
	}
	flood := map[string]any{"model": "g", "messages": []any{map[string]any{"role": "user", "content": many}}, "max_tokens": json.Number("8192")}
	cfg.MaxModelLen = 1048576
	// 500 images x 2500 tokens = 1.25M tokens: over the window, must refuse
	if e, _ := clampOutput(cfg, flood); e == nil || e.Status != 400 {
		t.Fatal("500 images must refuse")
	}
}

// tool_reference nested in tool_result.content is stripped too, and a forced
// tool_choice naming a removed web_search tool is freed (strict upstreams 400
// on a choice that references an undeclared tool).
func TestNestedToolReferenceAndToolChoice(t *testing.T) {
	nested := map[string]any{"model": "g", "messages": []any{map[string]any{"role": "user", "content": []any{
		map[string]any{"type": "tool_result", "tool_use_id": "t1", "content": []any{
			map[string]any{"type": "tool_reference", "tool_name": "t"}, map[string]any{"type": "text", "text": "ok"}}}}}}}
	if n := stripToolReferences(nested); n != 1 {
		t.Fatalf("nested tool_reference: stripped %d", n)
	}
	inner := asMap(asList(asMap(asList(asMap(asList(nested["messages"])[0])["content"])[0])["content"])[0])
	if asString(inner["type"]) != "text" {
		t.Fatalf("nested content: %v", inner)
	}

	ws := map[string]any{"tools": []any{map[string]any{"type": "web_search_20250305"}, map[string]any{"type": "custom", "name": "c"}},
		"tool_choice": map[string]any{"type": "tool", "name": "web_search"}}
	if !stripWebSearchTools(ws) || len(asList(ws["tools"])) != 1 {
		t.Fatalf("web_search not stripped: %v", ws)
	}
	if _, still := ws["tool_choice"]; still {
		t.Fatalf("a forced tool_choice naming the removed tool must be freed: %v", ws)
	}
}
