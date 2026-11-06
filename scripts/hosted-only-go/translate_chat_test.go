package main

import (
	"encoding/json"
	"errors"
	"io"
	"reflect"
	"strings"
	"testing"
)

// chatNorm round-trips v (or raw JSON bytes/strings) through encoding/json so
// json.Number and float64 compare equal.
func chatNorm(t *testing.T, v any) any {
	t.Helper()
	var raw []byte
	switch x := v.(type) {
	case []byte:
		raw = x
	case string:
		raw = []byte(x)
	default:
		b, err := json.Marshal(v)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		raw = b
	}
	var out any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("bad JSON %q: %v", raw, err)
	}
	return out
}

func chatJSONEq(t *testing.T, got any, want string) {
	t.Helper()
	g, w := chatNorm(t, got), chatNorm(t, want)
	if !reflect.DeepEqual(g, w) {
		gb, _ := json.MarshalIndent(g, "", " ")
		wb, _ := json.MarshalIndent(w, "", " ")
		t.Fatalf("mismatch\n got: %s\nwant: %s", gb, wb)
	}
}

func chatReq(t *testing.T, in string) (string, map[string]any) {
	t.Helper()
	m, err := decodeObject([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	path, out, err := newChatTranslator().Request(m)
	if err != nil {
		t.Fatal(err)
	}
	return path, out
}

func TestChatRequestGolden(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{
			"system string + simple user",
			`{"model":"gpt-4o-mini","max_tokens":100,"system":"be nice","messages":[{"role":"user","content":"hi"}],"top_k":5,"thinking":{"type":"enabled","budget_tokens":1000}}`,
			`{"model":"gpt-4o-mini","max_completion_tokens":100,"messages":[{"role":"system","content":"be nice"},{"role":"user","content":"hi"}]}`,
		},
		{
			"system blocks joined, cache_control ignored",
			`{"model":"m","system":[{"type":"text","text":"a","cache_control":{"type":"ephemeral"}},{"type":"text","text":"b"}],"messages":[]}`,
			`{"model":"m","messages":[{"role":"system","content":"a\n\nb"}]}`,
		},
		{
			"sampling, stop, user",
			`{"model":"m","temperature":0.5,"top_p":0.9,"stop_sequences":["X","Y"],"metadata":{"user_id":"u1"},"messages":[{"role":"user","content":"x"}]}`,
			`{"model":"m","temperature":0.5,"top_p":0.9,"stop":["X","Y"],"user":"u1","messages":[{"role":"user","content":"x"}]}`,
		},
		{
			"stream flags",
			`{"model":"m","stream":true,"messages":[{"role":"user","content":"x"}]}`,
			`{"model":"m","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"x"}]}`,
		},
		{
			"multi-turn tool_use + tool_result ordering",
			`{"model":"m","messages":[
			  {"role":"user","content":"weather?"},
			  {"role":"assistant","content":[
			    {"type":"thinking","thinking":"hmm","signature":"s"},
			    {"type":"redacted_thinking","data":"zz"},
			    {"type":"tool_use","id":"t1","name":"get_weather","input":{"city":"SF"}},
			    {"type":"tool_use","id":"t2","name":"noargs","input":{}}]},
			  {"role":"user","content":[
			    {"type":"text","text":"also"},
			    {"type":"tool_result","tool_use_id":"t1","content":"sunny"},
			    {"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"a"},{"type":"text","text":"b"}],"is_error":true}]},
			  {"role":"assistant","content":[{"type":"text","text":"one"},{"type":"text","text":"two"}]}]}`,
			`{"model":"m","messages":[
			  {"role":"user","content":"weather?"},
			  {"role":"assistant","content":"","tool_calls":[
			    {"id":"t1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"SF\"}"}},
			    {"id":"t2","type":"function","function":{"name":"noargs","arguments":"{}"}}]},
			  {"role":"tool","tool_call_id":"t1","content":"sunny"},
			  {"role":"tool","tool_call_id":"t2","content":"Error: a\nb"},
			  {"role":"user","content":"also"},
			  {"role":"assistant","content":"one\ntwo"}]}`,
		},
		{
			"assistant text + tool_use keeps text",
			`{"model":"m","messages":[{"role":"assistant","content":[{"type":"text","text":"ok"},{"type":"tool_use","id":"t","name":"n","input":{"a":1}}]}]}`,
			`{"model":"m","messages":[{"role":"assistant","content":"ok","tool_calls":[{"id":"t","type":"function","function":{"name":"n","arguments":"{\"a\":1}"}}]}]}`,
		},
		{
			"tool_result with image block",
			`{"model":"m","messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":[{"type":"text","text":"shot"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"QQ=="}}]}]}]}`,
			`{"model":"m","messages":[{"role":"tool","tool_call_id":"t","content":"shot"},{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,QQ=="}}]}]}`,
		},
		{
			"images",
			`{"model":"m","messages":[{"role":"user","content":[
			  {"type":"text","text":"look"},
			  {"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"QUJD"}},
			  {"type":"image","source":{"type":"url","url":"https://x/y.png"}}]}]}`,
			`{"model":"m","messages":[{"role":"user","content":[
			  {"type":"text","text":"look"},
			  {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,QUJD"}},
			  {"type":"image_url","image_url":{"url":"https://x/y.png"}}]}]}`,
		},
		{
			"tools drop server tools, default schema, auto",
			`{"model":"m","tools":[
			  {"name":"a","description":"da","input_schema":{"type":"object","properties":{"x":{"type":"string"}}}},
			  {"type":"web_search_20250305","name":"web_search"},
			  {"type":"custom","name":"b"}],
			  "tool_choice":{"type":"auto"},"messages":[]}`,
			`{"model":"m","tools":[
			  {"type":"function","function":{"name":"a","description":"da","parameters":{"type":"object","properties":{"x":{"type":"string"}}}}},
			  {"type":"function","function":{"name":"b","parameters":{"type":"object","properties":{}}}}],
			  "tool_choice":"auto","messages":[]}`,
		},
		{
			"tool_choice any + disable parallel",
			`{"model":"m","tools":[{"name":"a","input_schema":{"type":"object"}}],"tool_choice":{"type":"any","disable_parallel_tool_use":true},"messages":[]}`,
			`{"model":"m","tools":[{"type":"function","function":{"name":"a","parameters":{"type":"object"}}}],"tool_choice":"required","parallel_tool_calls":false,"messages":[]}`,
		},
		{
			"tool_choice tool",
			`{"model":"m","tools":[{"name":"a","input_schema":{"type":"object"}}],"tool_choice":{"type":"tool","name":"a"},"messages":[]}`,
			`{"model":"m","tools":[{"type":"function","function":{"name":"a","parameters":{"type":"object"}}}],"tool_choice":{"type":"function","function":{"name":"a"}},"messages":[]}`,
		},
		{
			"tool_choice none",
			`{"model":"m","tools":[{"name":"a","input_schema":{"type":"object"}}],"tool_choice":{"type":"none"},"messages":[]}`,
			`{"model":"m","tools":[{"type":"function","function":{"name":"a","parameters":{"type":"object"}}}],"tool_choice":"none","messages":[]}`,
		},
		{
			"no tools omits tool_choice and parallel flag",
			`{"model":"m","tool_choice":{"type":"any","disable_parallel_tool_use":true},"messages":[]}`,
			`{"model":"m","messages":[]}`,
		},
		{
			"only server tools omits tool_choice",
			`{"model":"m","tools":[{"type":"web_search_20250305","name":"web_search"}],"tool_choice":{"type":"auto"},"messages":[]}`,
			`{"model":"m","messages":[]}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path, out := chatReq(t, tc.in)
			if path != "/v1/chat/completions" {
				t.Fatalf("path %q", path)
			}
			chatJSONEq(t, out, tc.want)
		})
	}
}

func TestChatRequestMaxTokensNaming(t *testing.T) {
	cases := map[string]string{
		"gpt-5":                "max_completion_tokens",
		"GPT-5.1-mini":         "max_completion_tokens",
		"o1":                   "max_completion_tokens",
		"o3-mini":              "max_completion_tokens",
		"O4-mini":              "max_completion_tokens",
		"openai/gpt-5-codex":   "max_completion_tokens",
		"gpt-4o-mini":          "max_completion_tokens", // accepted live 2026-11-07
		"gpt-4.1":              "max_completion_tokens",
		"gpt-6-sol":            "max_completion_tokens", // rejects max_tokens live 2026-11-07
		"gemini-3.7-flash":     "max_completion_tokens", // accepted live 2026-11-07
		"omni-model":           "max_completion_tokens",
		"rits/zai-org/glm-5-3": "max_tokens", // self-hosted vLLM keeps the classic name
	}
	for model, key := range cases {
		_, out := chatReq(t, `{"model":"`+model+`","max_tokens":77,"messages":[]}`)
		other := "max_tokens"
		if key == "max_tokens" {
			other = "max_completion_tokens"
		}
		if v, ok := out[key]; !ok || chatNorm(t, v) != float64(77) {
			t.Errorf("%s: want %s=77, got %v", model, key, out)
		}
		if _, ok := out[other]; ok {
			t.Errorf("%s: must not set %s", model, other)
		}
	}
}

func TestChatRequestDoesNotMutateInput(t *testing.T) {
	in := `{"model":"gpt-5","max_tokens":5,"stream":true,"system":[{"type":"text","text":"s"}],
	"tools":[{"name":"a","input_schema":{"type":"object"}},{"type":"web_search_1","name":"w"}],
	"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"x"}]}]}`
	m, _ := decodeObject([]byte(in))
	before := marshal(m)
	if _, _, err := newChatTranslator().Request(m); err != nil {
		t.Fatal(err)
	}
	if string(before) != string(marshal(m)) {
		t.Fatal("Request mutated its input")
	}
}

func TestChatResponseGolden(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{
			"text",
			`{"id":"chatcmpl-abc","choices":[{"message":{"role":"assistant","content":"hello","reasoning_content":"think"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":3}}`,
			`{"id":"msg_abc","type":"message","role":"assistant","model":"claude-x","content":[{"type":"text","text":"hello"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":3,"cache_read_input_tokens":0}}`,
		},
		{
			"tools with text, finish stop forced to tool_use",
			`{"id":"chatcmpl-1","choices":[{"message":{"content":"ok","tool_calls":[
			  {"id":"c1","type":"function","function":{"name":"a","arguments":"{\"x\":1}"}},
			  {"id":"c2","type":"function","function":{"name":"b","arguments":""}}]},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}`,
			`{"id":"msg_1","type":"message","role":"assistant","model":"claude-x","content":[
			  {"type":"text","text":"ok"},
			  {"type":"tool_use","id":"c1","name":"a","input":{"x":1}},
			  {"type":"tool_use","id":"c2","name":"b","input":{}}],"stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":5,"output_tokens":2,"cache_read_input_tokens":0}}`,
		},
		{
			"length",
			`{"id":"chatcmpl-2","choices":[{"message":{"content":"cut"},"finish_reason":"length"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`,
			`{"id":"msg_2","type":"message","role":"assistant","model":"claude-x","content":[{"type":"text","text":"cut"}],"stop_reason":"max_tokens","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0}}`,
		},
		{
			"cached usage",
			`{"id":"chatcmpl-3","choices":[{"message":{"content":"x"},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":60}}}`,
			`{"id":"msg_3","type":"message","role":"assistant","model":"claude-x","content":[{"type":"text","text":"x"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":40,"output_tokens":7,"cache_read_input_tokens":60}}`,
		},
		{
			"cached greater than prompt floors at 0",
			`{"id":"chatcmpl-4","choices":[{"message":{"content":"x"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":1,"prompt_tokens_details":{"cached_tokens":9}}}`,
			`{"id":"msg_4","type":"message","role":"assistant","model":"claude-x","content":[{"type":"text","text":"x"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":1,"cache_read_input_tokens":9}}`,
		},
		{
			"invalid arguments JSON -> {}",
			`{"id":"chatcmpl-5","choices":[{"message":{"content":null,"tool_calls":[{"id":"c","type":"function","function":{"name":"a","arguments":"{\"x\":"}}]},"finish_reason":"tool_calls"}]}`,
			`{"id":"msg_5","type":"message","role":"assistant","model":"claude-x","content":[{"type":"tool_use","id":"c","name":"a","input":{}}],"stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0}}`,
		},
		{
			"empty message -> empty text block, content_filter -> end_turn",
			`{"id":"chatcmpl-6","choices":[{"message":{"content":""},"finish_reason":"content_filter"}]}`,
			`{"id":"msg_6","type":"message","role":"assistant","model":"claude-x","content":[{"type":"text","text":""}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0}}`,
		},
		{
			"unknown finish reason",
			`{"id":"chatcmpl-7","choices":[{"message":{"content":"a"},"finish_reason":"weird"}]}`,
			`{"id":"msg_7","type":"message","role":"assistant","model":"claude-x","content":[{"type":"text","text":"a"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0}}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out, err := newChatTranslator().Response([]byte(tc.in), "claude-x")
			if err != nil {
				t.Fatal(err)
			}
			chatJSONEq(t, out, tc.want)
		})
	}
}

func TestChatResponseGeneratesID(t *testing.T) {
	out, err := newChatTranslator().Response([]byte(`{"choices":[{"message":{"content":"a"}}]}`), "m")
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	_ = json.Unmarshal(out, &m)
	if id, _ := m["id"].(string); !strings.HasPrefix(id, "msg_") || len(id) < 8 {
		t.Fatalf("id %q", id)
	}
}

type chatEv struct {
	name string
	data map[string]any
}

func chatRunStream(t *testing.T, sse string) ([]chatEv, usageInfo) {
	t.Helper()
	var evs []chatEv
	u, err := newChatTranslator().Stream(strings.NewReader(sse), func(ev string, data []byte) error {
		var m map[string]any
		if err := json.Unmarshal(data, &m); err != nil {
			t.Fatalf("event %s bad JSON %q", ev, data)
		}
		if ty, _ := m["type"].(string); ty != ev {
			t.Fatalf("event name %q != data type %q", ev, ty)
		}
		evs = append(evs, chatEv{ev, m})
		return nil
	}, "claude-x")
	if err != nil {
		t.Fatalf("stream error: %v", err)
	}
	chatCheckInvariants(t, evs)
	return evs, u
}

func chatCheckInvariants(t *testing.T, evs []chatEv) {
	t.Helper()
	if len(evs) < 3 {
		t.Fatalf("too few events: %d", len(evs))
	}
	if evs[0].name != "message_start" {
		t.Fatalf("first event %s", evs[0].name)
	}
	if evs[len(evs)-1].name != "message_stop" || evs[len(evs)-2].name != "message_delta" {
		t.Fatalf("must end with message_delta, message_stop; got %s, %s", evs[len(evs)-2].name, evs[len(evs)-1].name)
	}
	next := 0
	open := map[int]bool{}
	for _, e := range evs[1 : len(evs)-2] {
		idx := -1
		if f, ok := e.data["index"].(float64); ok {
			idx = int(f)
		}
		switch e.name {
		case "content_block_start":
			if idx != next {
				t.Fatalf("block index %d, want sequential %d", idx, next)
			}
			next++
			open[idx] = true
		case "content_block_delta":
			if !open[idx] {
				t.Fatalf("delta for non-open block %d", idx)
			}
		case "content_block_stop":
			if !open[idx] {
				t.Fatalf("stop for non-open block %d", idx)
			}
			delete(open, idx)
		default:
			t.Fatalf("unexpected mid-stream event %s", e.name)
		}
	}
	if len(open) != 0 {
		t.Fatalf("unclosed blocks %v", open)
	}
}

// chatSummary renders events compactly for golden comparison.
func chatSummary(evs []chatEv) []string {
	var out []string
	for _, e := range evs {
		switch e.name {
		case "content_block_start":
			cb := asMap(e.data["content_block"])
			s := "start:" + asString(cb["type"])
			if asString(cb["type"]) == "tool_use" {
				s += ":" + asString(cb["id"]) + ":" + asString(cb["name"])
			}
			out = append(out, s)
		case "content_block_delta":
			d := asMap(e.data["delta"])
			if asString(d["type"]) == "text_delta" {
				out = append(out, "text:"+asString(d["text"]))
			} else {
				out = append(out, "json:"+asString(d["partial_json"]))
			}
		case "content_block_stop":
			out = append(out, "stop")
		case "message_delta":
			out = append(out, "delta:"+asString(asMap(e.data["delta"])["stop_reason"]))
		default:
			out = append(out, e.name)
		}
	}
	return out
}

func chatSSE(chunks ...string) string {
	var sb strings.Builder
	for _, c := range chunks {
		sb.WriteString("data: " + c + "\n\n")
	}
	return sb.String()
}

func TestChatStreamGolden(t *testing.T) {
	cases := []struct {
		name string
		sse  string
		want []string
		use  usageInfo
		out  int // expected message_delta output_tokens
	}{
		{
			name: "plain text with usage after finish",
			sse: chatSSE(
				`{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}`,
				`{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"Hel"}}]}`,
				`{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"reasoning_content":"hmm"}}]}`,
				`{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"lo"}}]}`,
				`{"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`,
				`{"id":"chatcmpl-1","choices":[],"usage":{"prompt_tokens":20,"completion_tokens":4,"prompt_tokens_details":{"cached_tokens":5}}}`,
				`[DONE]`),
			want: []string{"message_start", "start:text", "text:Hel", "text:lo", "stop", "delta:end_turn", "message_stop"},
			use:  usageInfo{In: 15, Out: 4, CacheRead: 5},
			out:  4,
		},
		{
			name: "text then tool",
			sse: chatSSE(
				`{"id":"c","choices":[{"delta":{"content":"let me"}}]}`,
				`{"id":"c","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get","arguments":""}}]}}]}`,
				`{"id":"c","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"a\":"}}]}}]}`,
				`{"id":"c","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]}}]}`,
				`{"id":"c","choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
				`{"id":"c","choices":[],"usage":{"prompt_tokens":3,"completion_tokens":9}}`,
				`[DONE]`),
			want: []string{"message_start", "start:text", "text:let me", "stop", "start:tool_use:call_1:get", `json:{"a":`, "json:1}", "stop", "delta:tool_use", "message_stop"},
			use:  usageInfo{In: 3, Out: 9},
			out:  9,
		},
		{
			name: "two parallel tools by index",
			sse: chatSSE(
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"f","arguments":"{"}}]}}]}`,
				`{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"g","arguments":"{"}}]}}]}`,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]}}]}`,
				`{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
				`[DONE]`),
			want: []string{"message_start", "start:tool_use:a:f", "json:{", "start:tool_use:b:g", "json:{", "json:}", "json:}", "stop", "stop", "delta:tool_use", "message_stop"},
		},
		{
			name: "gemini same index distinct ids",
			sse: chatSSE(
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"g1","function":{"name":"f","arguments":"{\"a\":1}"}}]}}]}`,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"g2","function":{"name":"g","arguments":"{\"b\":2}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"stop"}]}`,
				`[DONE]`),
			want: []string{"message_start", "start:tool_use:g1:f", `json:{"a":1}`, "start:tool_use:g2:g", `json:{"b":2}`, "stop", "stop", "delta:tool_use", "message_stop"},
		},
		{
			name: "whole args in one chunk, id repeated on continuation",
			sse: chatSSE(
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"w","type":"function","function":{"name":"f","arguments":"{\"k\":\"v\"}"}}]},"finish_reason":"tool_calls"}]}`,
				`{"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}`,
				`[DONE]`),
			want: []string{"message_start", "start:tool_use:w:f", `json:{"k":"v"}`, "stop", "delta:tool_use", "message_stop"},
			use:  usageInfo{In: 1, Out: 1},
			out:  1,
		},
		{
			name: "tool without arguments gets {}",
			sse: chatSSE(
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"n","function":{"name":"f"}}]},"finish_reason":"tool_calls"}]}`,
				`[DONE]`),
			want: []string{"message_start", "start:tool_use:n:f", "json:{}", "stop", "delta:tool_use", "message_stop"},
		},
		{
			name: "length finish",
			sse: chatSSE(
				`{"choices":[{"delta":{"content":"x"},"finish_reason":"length"}]}`,
				`[DONE]`),
			want: []string{"message_start", "start:text", "text:x", "stop", "delta:max_tokens", "message_stop"},
		},
		{
			name: "EOF without DONE or finish_reason",
			sse: chatSSE(
				`{"choices":[{"delta":{"content":"partial"}}]}`),
			want: []string{"message_start", "start:text", "text:partial", "stop", "delta:end_turn", "message_stop"},
		},
		{
			name: "empty upstream still well formed",
			sse:  "",
			want: []string{"message_start", "delta:end_turn", "message_stop"},
		},
		{
			name: "role-only and empty chunks, keepalive comments",
			sse: ": ping\n\n" + chatSSE(
				`{"choices":[{"delta":{"role":"assistant"}}]}`,
				`{"choices":[{"delta":{}}]}`,
				`{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}`,
				`[DONE]`),
			want: []string{"message_start", "start:text", "text:ok", "stop", "delta:end_turn", "message_stop"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			evs, u := chatRunStream(t, tc.sse)
			if got := chatSummary(evs); !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("events\n got: %q\nwant: %q", got, tc.want)
			}
			if u != tc.use {
				t.Fatalf("usage %+v, want %+v", u, tc.use)
			}
			md := asMap(evs[len(evs)-2].data["usage"])
			if f, _ := md["output_tokens"].(float64); int(f) != tc.out {
				t.Fatalf("message_delta output_tokens %v, want %d", md["output_tokens"], tc.out)
			}
		})
	}
}

func TestChatStreamMessageStartShape(t *testing.T) {
	evs, _ := chatRunStream(t, chatSSE(`{"id":"chatcmpl-zz","choices":[{"delta":{"content":"a"}}]}`, `[DONE]`))
	chatJSONEq(t, evs[0].data, `{"type":"message_start","message":{"id":"msg_zz","type":"message","role":"assistant","model":"claude-x","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}}`)
	last := evs[len(evs)-2].data
	chatJSONEq(t, last["delta"], `{"stop_reason":"end_turn","stop_sequence":null}`)
}

type chatErrReader struct {
	data string
	done bool
}

func (r *chatErrReader) Read(p []byte) (int, error) {
	if r.done {
		return 0, errors.New("conn reset")
	}
	r.done = true
	return copy(p, r.data), nil
}

func TestChatStreamReadErrorClosesBlocks(t *testing.T) {
	var evs []string
	_, err := newChatTranslator().Stream(&chatErrReader{data: "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"}, func(ev string, _ []byte) error {
		evs = append(evs, ev)
		return nil
	}, "m")
	if err == nil || err.Error() != "conn reset" {
		t.Fatalf("err = %v", err)
	}
	want := []string{"message_start", "content_block_start", "content_block_delta", "content_block_stop"}
	if !reflect.DeepEqual(evs, want) {
		t.Fatalf("events %v, want %v", evs, want)
	}
}

func TestChatStreamEmitErrorPropagates(t *testing.T) {
	boom := errors.New("client gone")
	_, err := newChatTranslator().Stream(strings.NewReader(chatSSE(`{"choices":[{"delta":{"content":"a"}}]}`, `[DONE]`)), func(string, []byte) error {
		return boom
	}, "m")
	if !errors.Is(err, boom) {
		t.Fatalf("err = %v", err)
	}
}

func TestChatStreamStopsReadingAtDone(t *testing.T) {
	// A reader that would block forever after [DONE] must not be read further.
	pr, pw := io.Pipe()
	go func() {
		_, _ = pw.Write([]byte(chatSSE(`{"choices":[{"delta":{"content":"a"},"finish_reason":"stop"}]}`, `[DONE]`)))
		// leave the pipe open
	}()
	defer pw.Close()
	var last string
	if _, err := newChatTranslator().Stream(pr, func(ev string, _ []byte) error { last = ev; return nil }, "m"); err != nil {
		t.Fatal(err)
	}
	if last != "message_stop" {
		t.Fatalf("last event %s", last)
	}
}

func TestChatError(t *testing.T) {
	long := strings.Repeat("é", 3000)
	cases := []struct {
		name   string
		status int
		body   string
		typ    string
		msg    string
	}{
		{"openai error object", 400, `{"error":{"message":"bad param","type":"invalid_request_error"}}`, "invalid_request_error", "bad param"},
		{"top-level message", 429, `{"message":"slow down"}`, "rate_limit_error", "slow down"},
		{"error string", 401, `{"error":"no key"}`, "authentication_error", "no key"},
		{"raw body trimmed", 502, "  upstream exploded \n", "api_error", "upstream exploded"},
		{"529", 529, `{}`, "overloaded_error", "{}"},
		{"404", 404, `{"error":{"message":"no such model"}}`, "not_found_error", "no such model"},
		{"empty body", 500, ``, "api_error", "upstream returned status 500 (Internal Server Error)"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := newChatTranslator().Error(tc.status, []byte(tc.body))
			chatJSONEq(t, out, `{"type":"error","error":{"type":"`+tc.typ+`","message":`+string(marshal(tc.msg))+`}}`)
		})
	}
	out := newChatTranslator().Error(500, []byte(long))
	var m struct {
		Error struct{ Message string }
	}
	if err := json.Unmarshal(out, &m); err != nil {
		t.Fatal(err)
	}
	if len(m.Error.Message) > 2000 || !strings.HasPrefix(m.Error.Message, "é") || strings.ContainsRune(m.Error.Message, '�') {
		t.Fatalf("bad truncation len=%d", len(m.Error.Message))
	}
}

func TestChatNoPanicOnOddInputs(t *testing.T) {
	tr := func() translator { return newChatTranslator() }
	reqs := []map[string]any{
		nil,
		{},
		{"model": 5, "messages": "x", "system": 7, "tools": "x", "tool_choice": 3, "stop_sequences": "a", "metadata": []any{}},
		{"messages": []any{nil, 1, "s", map[string]any{"role": "user", "content": []any{nil, 2, map[string]any{"type": "tool_result", "content": []any{nil, 3}}, map[string]any{"type": "image", "source": "x"}}}}},
		{"messages": []any{map[string]any{"role": "assistant", "content": []any{map[string]any{"type": "tool_use", "input": "str"}, map[string]any{"type": "tool_use"}}}}},
		{"tools": []any{nil, map[string]any{}, map[string]any{"name": 1}}, "tool_choice": map[string]any{"type": "tool"}},
		{"max_tokens": "x", "stream": "yes"},
	}
	for i, r := range reqs {
		func() {
			defer func() {
				if p := recover(); p != nil {
					t.Fatalf("Request case %d panicked: %v", i, p)
				}
			}()
			_, _, _ = tr().Request(r)
		}()
	}
	bodies := []string{
		``, `null`, `[]`, `{`, `{}`, `{"choices":null}`, `{"choices":[]}`, `{"choices":[null]}`,
		`{"choices":[{"message":null}]}`, `{"choices":[{"message":{"content":5,"tool_calls":"x"}}]}`,
		`{"choices":[{"message":{"tool_calls":[null,1,{"function":5},{"function":{"arguments":5}}]}}],"usage":"x"}`,
		`{"choices":[{"message":{"content":[null,{"type":"text","text":1}]}}],"usage":{"prompt_tokens":"a"}}`,
	}
	for _, b := range bodies {
		func() {
			defer func() {
				if p := recover(); p != nil {
					t.Fatalf("Response %q panicked: %v", b, p)
				}
			}()
			_, _ = tr().Response([]byte(b), "m")
			_ = tr().Error(500, []byte(b))
		}()
	}
	streams := []string{
		"", "data:", "data: {", "data: null\n\n", "data: []\n\n", "data: [DONE]", "event: x\n\n", "data: {\"choices\":[null]}\n\n",
		"data: {\"choices\":[{\"delta\":null}]}\n\n",
		"data: {\"choices\":[{\"delta\":{\"content\":5,\"tool_calls\":[null,1,{\"index\":\"x\"},{\"function\":null}]}}],\"usage\":5}\n\n",
		"data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":-3,\"id\":5,\"function\":{\"arguments\":9}}]}}]}\n\n",
		"data: {\"choices\":[{\"delta\":{\"content\":\"trunc",
		"data: {\"choices\":[{\"finish_reason\":5}]}\n\n",
	}
	for _, s := range streams {
		func() {
			defer func() {
				if p := recover(); p != nil {
					t.Fatalf("Stream %q panicked: %v", s, p)
				}
			}()
			var evs []chatEv
			_, err := tr().Stream(strings.NewReader(s), func(ev string, d []byte) error {
				var m map[string]any
				_ = json.Unmarshal(d, &m)
				evs = append(evs, chatEv{ev, m})
				return nil
			}, "m")
			if err != nil {
				t.Fatalf("Stream %q: %v", s, err)
			}
			chatCheckInvariants(t, evs)
		}()
	}
}

// Gemini 3 thought signatures survive the Messages round trip inside the
// tool_use id (live 2026-11-07: a follow-up turn without them is a 400).
func TestChatThoughtSignatureRoundTrip(t *testing.T) {
	tr := newChatTranslator()
	upstream := []byte(`{"id":"c1","choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","tool_calls":[` +
		`{"id":"call_abc","type":"function","extra_content":{"google":{"thought_signature":"c2ln+/=="}},"function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]}}],"usage":{"prompt_tokens":3,"completion_tokens":1}}`)
	out, err := tr.Response(upstream, "gemini-3.7-flash")
	if err != nil {
		t.Fatal(err)
	}
	obj, _ := decodeObject(out)
	block := asMap(asList(obj["content"])[0])
	id := asString(block["id"])
	if !strings.HasPrefix(id, "call_abc__thought__") || strings.ContainsAny(id, "+/=") {
		t.Fatalf("tool_use id must carry the signature in an id-safe form: %q", id)
	}
	// the client echoes the block back: assistant tool_use + user tool_result
	req := map[string]any{"model": "gemini-3.7-flash", "max_tokens": 10, "messages": []any{
		map[string]any{"role": "user", "content": "w?"},
		map[string]any{"role": "assistant", "content": []any{map[string]any{"type": "tool_use", "id": id, "name": "get_weather", "input": map[string]any{"city": "Paris"}}}},
		map[string]any{"role": "user", "content": []any{map[string]any{"type": "tool_result", "tool_use_id": id, "content": "sunny"}}},
	}}
	_, body, err := newChatTranslator().Request(req)
	if err != nil {
		t.Fatal(err)
	}
	msgs := asList(body["messages"])
	call := asMap(asList(asMap(msgs[1])["tool_calls"])[0])
	if asString(call["id"]) != "call_abc" {
		t.Fatalf("upstream tool call id must be the original: %v", call["id"])
	}
	if sig := asString(asMap(asMap(call["extra_content"])["google"])["thought_signature"]); sig != "c2ln+/==" {
		t.Fatalf("signature not echoed back: %q", sig)
	}
	if asString(asMap(msgs[2])["tool_call_id"]) != "call_abc" {
		t.Fatalf("tool message must reference the original id: %v", asMap(msgs[2])["tool_call_id"])
	}
	// an id without a signature is untouched, a mangled one degrades to the plain id
	if o, s := chatSplitToolID("call_x"); o != "call_x" || s != "" {
		t.Fatal("plain id changed")
	}
	if o, s := chatSplitToolID("call_x__thought__!!bad!!"); o != "call_x" || s != "" {
		t.Fatalf("undecodable signature must degrade, got %q %q", o, s)
	}
}

func TestChatStreamThoughtSignature(t *testing.T) {
	sse := "data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_z\",\"extra_content\":{\"google\":{\"thought_signature\":\"S1\"}},\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n"
	var ids []string
	_, err := newChatTranslator().Stream(strings.NewReader(sse), func(ev string, d []byte) error {
		if ev == "content_block_start" {
			o, _ := decodeObject(d)
			ids = append(ids, asString(asMap(o["content_block"])["id"]))
		}
		return nil
	}, "gemini-3.7-flash")
	if err != nil || len(ids) != 1 || !strings.HasPrefix(ids[0], "call_z__thought__") {
		t.Fatalf("stream tool_use id must carry the signature: err=%v ids=%v", err, ids)
	}
}

// A refusal-only answer must not become a successful empty message.
func TestChatRefusalPreservedAsText(t *testing.T) {
	out, err := newChatTranslator().Response([]byte(
		`{"id":"chatcmpl-1","choices":[{"message":{"role":"assistant","content":null,"refusal":"cannot help with that"},"finish_reason":"stop"}]}`), "m")
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(out, &m); err != nil {
		t.Fatal(err)
	}
	content := asList(m["content"])
	if len(content) != 1 || asString(asMap(content[0])["text"]) != "cannot help with that" {
		t.Fatalf("refusal must survive as text: %s", out)
	}
}

// finish_reason length wins over tool_use: the truncated call is not
// executable and the client retries only on max_tokens.
func TestChatTruncatedToolCallKeepsMaxTokens(t *testing.T) {
	out, err := newChatTranslator().Response([]byte(
		`{"id":"chatcmpl-1","choices":[{"message":{"content":null,"tool_calls":[{"id":"c","type":"function","function":{"name":"a","arguments":"{\"x\":"}}]},"finish_reason":"length"}]}`), "m")
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(out, &m); err != nil {
		t.Fatal(err)
	}
	if m["stop_reason"] != "max_tokens" {
		t.Fatalf("a token-budget cutoff must keep max_tokens even with a (truncated) tool call: %s", out)
	}
}

func TestChatStreamRefusalDelta(t *testing.T) {
	sse := "data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"refusal\":\"no can do\"}}]}\n\ndata: [DONE]\n\n"
	evs, _ := chatRunStream(t, sse)
	var text string
	for _, ev := range evs {
		if ev.name == "content_block_delta" {
			text += asString(asMap(ev.data["delta"])["text"])
		}
	}
	if text != "no can do" {
		t.Fatalf("refusal delta lost: %q", text)
	}
}

// An upstream SSE error line ({"error":{...}} with no choices) must fail the
// stream instead of finishing as a normal completion.
func TestChatStreamUpstreamErrorObjectFails(t *testing.T) {
	sse := "data: {\"error\":{\"message\":\"backend failed\"}}\n\ndata: [DONE]\n\n"
	var sawStop bool
	_, err := newChatTranslator().Stream(strings.NewReader(sse), func(ev string, _ []byte) error {
		if ev == "message_stop" {
			sawStop = true
		}
		return nil
	}, "m")
	if err == nil || !strings.Contains(err.Error(), "backend failed") {
		t.Fatalf("the error line must fail the stream: %v", err)
	}
	if sawStop {
		t.Fatal("a failed stream must not emit message_stop")
	}
}
