package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// ---------------------------------------------------------------- helpers

func respJSON(t *testing.T, s string) map[string]any {
	t.Helper()
	m, err := decodeObject([]byte(s))
	if err != nil {
		t.Fatalf("bad test json %q: %v", s, err)
	}
	return m
}

// respNorm round-trips a value through JSON so numbers compare uniformly.
func respNorm(t *testing.T, v any) any {
	t.Helper()
	var out any
	if err := json.Unmarshal(marshal(v), &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func respWantJSON(t *testing.T, s string) any {
	t.Helper()
	var out any
	if err := json.Unmarshal([]byte(s), &out); err != nil {
		t.Fatalf("bad want json %q: %v", s, err)
	}
	return out
}

func respDo(t *testing.T, reqJSON string) map[string]any {
	t.Helper()
	req := respJSON(t, reqJSON)
	before := string(marshal(req))
	path, out, err := newResponsesTranslator().Request(req)
	if err != nil {
		t.Fatalf("Request: %v", err)
	}
	if path != "/v1/responses" {
		t.Fatalf("path = %q", path)
	}
	if after := string(marshal(req)); after != before {
		t.Fatalf("Request mutated its input:\n before %s\n after  %s", before, after)
	}
	return out
}

type respEv struct {
	name string
	data map[string]any
}

func (e respEv) typ() string { return asString(e.data["type"]) }

func respSSE(pairs ...string) string {
	var sb strings.Builder
	for i := 0; i+1 < len(pairs); i += 2 {
		sb.WriteString("event: " + pairs[i] + "\ndata: " + pairs[i+1] + "\n\n")
	}
	return sb.String()
}

func respRunStream(t *testing.T, sse string) ([]respEv, usageInfo, error) {
	t.Helper()
	var evs []respEv
	u, err := newResponsesTranslator().Stream(strings.NewReader(sse), func(name string, data []byte) error {
		m, derr := decodeObject(data)
		if derr != nil {
			t.Fatalf("emitted invalid json %q: %v", data, derr)
		}
		evs = append(evs, respEv{name, m})
		return nil
	}, "gpt-test")
	return evs, u, err
}

// respCheckInvariants asserts Anthropic stream invariants. complete=false means
// the stream aborted with an error (no message_delta / message_stop expected).
func respCheckInvariants(t *testing.T, evs []respEv, complete bool) {
	t.Helper()
	if len(evs) == 0 {
		t.Fatal("no events")
	}
	if evs[0].typ() != "message_start" {
		t.Fatalf("first event = %s, want message_start", evs[0].typ())
	}
	starts := 0
	next := 0
	open := -1
	for i, e := range evs {
		if e.name != e.typ() {
			t.Errorf("event %d name %q != type %q", i, e.name, e.typ())
		}
		idx, _ := asInt(e.data["index"])
		switch e.typ() {
		case "message_start":
			starts++
		case "content_block_start":
			if open != -1 {
				t.Errorf("event %d: block %d started while %d open", i, idx, open)
			}
			if idx != next {
				t.Errorf("event %d: block index %d, want %d", i, idx, next)
			}
			next++
			open = idx
		case "content_block_delta":
			if open != idx {
				t.Errorf("event %d: delta for index %d, open %d", i, idx, open)
			}
		case "content_block_stop":
			if open != idx {
				t.Errorf("event %d: stop for index %d, open %d", i, idx, open)
			}
			open = -1
		}
	}
	if starts != 1 {
		t.Errorf("message_start count = %d", starts)
	}
	if open != -1 {
		t.Errorf("block %d never stopped", open)
	}
	n := len(evs)
	if complete {
		if n < 3 || evs[n-1].typ() != "message_stop" || evs[n-2].typ() != "message_delta" {
			t.Fatalf("stream must end with message_delta, message_stop; got %v", respTypes(evs))
		}
	} else {
		for _, e := range evs {
			if e.typ() == "message_delta" || e.typ() == "message_stop" {
				t.Errorf("unexpected %s after failure", e.typ())
			}
		}
	}
}

func respTypes(evs []respEv) []string {
	var out []string
	for _, e := range evs {
		out = append(out, e.typ())
	}
	return out
}

func respStopOf(evs []respEv) string {
	for _, e := range evs {
		if e.typ() == "message_delta" {
			return asString(asMap(e.data["delta"])["stop_reason"])
		}
	}
	return ""
}

// respBlocks summarises the content blocks as "text:hello" / "tool:id/name:{json}".
func respBlocks(evs []respEv) []string {
	var out []string
	cur := -1
	for _, e := range evs {
		switch e.typ() {
		case "content_block_start":
			cb := asMap(e.data["content_block"])
			if asString(cb["type"]) == "text" {
				out = append(out, "text:")
			} else {
				out = append(out, "tool:"+asString(cb["id"])+"/"+asString(cb["name"])+":")
			}
			cur = len(out) - 1
		case "content_block_delta":
			d := asMap(e.data["delta"])
			out[cur] += asString(d["text"]) + asString(d["partial_json"])
		}
	}
	return out
}

// ---------------------------------------------------------------- request

func TestResponsesRequestGolden(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "instructions string and plain text",
			in:   `{"model":"gpt-5.1","system":"be brief","max_tokens":64,"temperature":0.2,"top_p":0.9,"top_k":5,"stop_sequences":["x"],"thinking":{"type":"enabled","budget_tokens":100},"metadata":{"user_id":"u"},"messages":[{"role":"user","content":"hi"}]}`,
			want: `{"model":"gpt-5.1","instructions":"be brief","max_output_tokens":64,"temperature":0.2,"top_p":0.9,"store":false,
				"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}]}`,
		},
		{
			name: "system blocks joined, cache_control ignored",
			in:   `{"model":"m","system":[{"type":"text","text":"A","cache_control":{"type":"ephemeral"}},{"type":"text","text":"B"}],"messages":[]}`,
			want: `{"model":"m","instructions":"A\n\nB","store":false,"input":[]}`,
		},
		{
			name: "stream flag",
			in:   `{"model":"m","stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"x"}]}]}`,
			want: `{"model":"m","stream":true,"store":false,"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"x"}]}]}`,
		},
		{
			name: "images base64 and url",
			in: `{"model":"m","messages":[{"role":"user","content":[
				{"type":"text","text":"look"},
				{"type":"image","source":{"type":"base64","media_type":"image/png","data":"QUJD"}},
				{"type":"image","source":{"type":"url","url":"https://x/y.png"}}]}]}`,
			want: `{"model":"m","store":false,"input":[{"type":"message","role":"user","content":[
				{"type":"input_text","text":"look"},
				{"type":"input_image","image_url":"data:image/png;base64,QUJD"},
				{"type":"input_image","image_url":"https://x/y.png"}]}]}`,
		},
		{
			name: "multi-turn tool round trip ordering",
			in: `{"model":"m","messages":[
				{"role":"user","content":"run it"},
				{"role":"assistant","content":[
					{"type":"thinking","thinking":"hmm","signature":"s"},
					{"type":"redacted_thinking","data":"zz"},
					{"type":"text","text":"ok"},
					{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"cmd":"ls"}},
					{"type":"tool_use","id":"toolu_2","name":"Noop","input":{}}]},
				{"role":"user","content":[
					{"type":"text","text":"and then"},
					{"type":"tool_result","tool_use_id":"toolu_1","content":"a\nb"},
					{"type":"tool_result","tool_use_id":"toolu_2","content":[{"type":"text","text":"x"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="}},{"type":"text","text":"y"}],"is_error":true}]}]}`,
			want: `{"model":"m","store":false,"input":[
				{"type":"message","role":"user","content":[{"type":"input_text","text":"run it"}]},
				{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]},
				{"type":"function_call","call_id":"toolu_1","name":"Bash","arguments":"{\"cmd\":\"ls\"}"},
				{"type":"function_call","call_id":"toolu_2","name":"Noop","arguments":"{}"},
				{"type":"function_call_output","call_id":"toolu_1","output":"a\nb"},
				{"type":"function_call_output","call_id":"toolu_2","output":"Error: x\n[image omitted]\ny"},
				{"type":"message","role":"user","content":[{"type":"input_text","text":"and then"}]}]}`,
		},
		{
			name: "assistant tool_use without input and string content",
			in: `{"model":"m","messages":[
				{"role":"assistant","content":"plain"},
				{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"N"}]},
				{"role":"user","content":[{"type":"tool_result","tool_use_id":"t"}]}]}`,
			want: `{"model":"m","store":false,"input":[
				{"type":"message","role":"assistant","content":[{"type":"output_text","text":"plain"}]},
				{"type":"function_call","call_id":"t","name":"N","arguments":"{}"},
				{"type":"function_call_output","call_id":"t","output":""}]}`,
		},
		{
			name: "tools flat shape, server tools dropped, tool_choice auto",
			in: `{"model":"m","messages":[],"tools":[
				{"name":"A","description":"da","input_schema":{"type":"object","properties":{"p":{"type":"string"}}}},
				{"type":"custom","name":"B"},
				{"type":"web_search_20250305","name":"web_search"},
				{"type":"bash_20250124","name":"bash"}],
				"tool_choice":{"type":"auto"}}`,
			want: `{"model":"m","store":false,"input":[],
				"tools":[
					{"type":"function","name":"A","description":"da","parameters":{"type":"object","properties":{"p":{"type":"string"}}},"strict":false},
					{"type":"function","name":"B","parameters":{"type":"object","properties":{}},"strict":false}],
				"tool_choice":"auto"}`,
		},
		{
			name: "tool_choice any with disable_parallel",
			in:   `{"model":"m","messages":[],"tools":[{"name":"A","input_schema":{"type":"object"}}],"tool_choice":{"type":"any","disable_parallel_tool_use":true}}`,
			want: `{"model":"m","store":false,"input":[],"tools":[{"type":"function","name":"A","parameters":{"type":"object"},"strict":false}],"tool_choice":"required","parallel_tool_calls":false}`,
		},
		{
			name: "tool_choice specific tool",
			in:   `{"model":"m","messages":[],"tools":[{"name":"A"}],"tool_choice":{"type":"tool","name":"A"}}`,
			want: `{"model":"m","store":false,"input":[],"tools":[{"type":"function","name":"A","parameters":{"type":"object","properties":{}},"strict":false}],"tool_choice":{"type":"function","name":"A"}}`,
		},
		{
			name: "tool_choice none",
			in:   `{"model":"m","messages":[],"tools":[{"name":"A"}],"tool_choice":{"type":"none"}}`,
			want: `{"model":"m","store":false,"input":[],"tools":[{"type":"function","name":"A","parameters":{"type":"object","properties":{}},"strict":false}],"tool_choice":"none"}`,
		},
		{
			name: "no tools: tool_choice and parallel omitted",
			in:   `{"model":"m","messages":[],"tool_choice":{"type":"any","disable_parallel_tool_use":true}}`,
			want: `{"model":"m","store":false,"input":[]}`,
		},
		{
			name: "only server tools: tool_choice omitted",
			in:   `{"model":"m","messages":[],"tools":[{"type":"web_search_20250305","name":"web_search"}],"tool_choice":{"type":"auto"}}`,
			want: `{"model":"m","store":false,"input":[]}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := respNorm(t, respDo(t, tc.in))
			want := respWantJSON(t, tc.want)
			if !reflect.DeepEqual(got, want) {
				t.Errorf("mismatch\n got  %s\n want %s", marshal(got), marshal(want))
			}
		})
	}
}

// ---------------------------------------------------------------- response

func TestResponsesResponseGolden(t *testing.T) {
	cases := []struct {
		name     string
		upstream string
		want     string
	}{
		{
			name: "text",
			upstream: `{"id":"resp_1","status":"completed","output":[
				{"type":"reasoning","summary":[]},
				{"type":"message","content":[{"type":"output_text","text":"Hel"},{"type":"output_text","text":"lo"}]}],
				"usage":{"input_tokens":10,"output_tokens":3}}`,
			want: `{"id":"msg_resp_1","type":"message","role":"assistant","model":"claude-x","content":[{"type":"text","text":"Hello"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":3,"cache_read_input_tokens":0}}`,
		},
		{
			name: "tool call",
			upstream: `{"id":"resp_2","status":"completed","output":[
				{"type":"message","content":[{"type":"output_text","text":"calling"}]},
				{"type":"function_call","id":"fc_1","call_id":"call_1","name":"Bash","arguments":"{\"cmd\":\"ls\"}"}],
				"usage":{"input_tokens":5,"output_tokens":7}}`,
			want: `{"id":"msg_resp_2","type":"message","role":"assistant","model":"claude-x","content":[{"type":"text","text":"calling"},{"type":"tool_use","id":"call_1","name":"Bash","input":{"cmd":"ls"}}],"stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":5,"output_tokens":7,"cache_read_input_tokens":0}}`,
		},
		{
			name: "tool id falls back to item id",
			upstream: `{"id":"r","status":"completed","output":[
				{"type":"function_call","id":"fc_9","name":"N","arguments":"{}"}]}`,
			want: `{"id":"msg_r","type":"message","role":"assistant","model":"claude-x","content":[{"type":"tool_use","id":"fc_9","name":"N","input":{}}],"stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0}}`,
		},
		{
			name: "invalid args json becomes empty object",
			upstream: `{"id":"r","status":"completed","output":[
				{"type":"function_call","call_id":"c","name":"N","arguments":"{not json"}]}`,
			want: `{"id":"msg_r","type":"message","role":"assistant","model":"claude-x","content":[{"type":"tool_use","id":"c","name":"N","input":{}}],"stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0}}`,
		},
		{
			name: "non-object args become empty object",
			upstream: `{"id":"r","status":"completed","output":[
				{"type":"function_call","call_id":"c","name":"N","arguments":"[1,2]"}]}`,
			want: `{"id":"msg_r","type":"message","role":"assistant","model":"claude-x","content":[{"type":"tool_use","id":"c","name":"N","input":{}}],"stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0}}`,
		},
		{
			name: "incomplete max_output_tokens",
			upstream: `{"id":"r","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[
				{"type":"message","content":[{"type":"output_text","text":"cut"}]}],"usage":{"input_tokens":1,"output_tokens":2}}`,
			want: `{"id":"msg_r","type":"message","role":"assistant","model":"claude-x","content":[{"type":"text","text":"cut"}],"stop_reason":"max_tokens","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":0}}`,
		},
		{
			name: "incomplete other reason is end_turn",
			upstream: `{"id":"r","status":"incomplete","incomplete_details":{"reason":"content_filter"},"output":[
				{"type":"message","content":[{"type":"output_text","text":"x"}]}]}`,
			want: `{"id":"msg_r","type":"message","role":"assistant","model":"claude-x","content":[{"type":"text","text":"x"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0}}`,
		},
		{
			name: "cached usage split",
			upstream: `{"id":"r","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"a"}]}],
				"usage":{"input_tokens":100,"output_tokens":9,"input_tokens_details":{"cached_tokens":80}}}`,
			want: `{"id":"msg_r","type":"message","role":"assistant","model":"claude-x","content":[{"type":"text","text":"a"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":20,"output_tokens":9,"cache_read_input_tokens":80}}`,
		},
		{
			name: "cached exceeding input floors at zero",
			upstream: `{"id":"r","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"a"}]}],
				"usage":{"input_tokens":10,"output_tokens":1,"input_tokens_details":{"cached_tokens":50}}}`,
			want: `{"id":"msg_r","type":"message","role":"assistant","model":"claude-x","content":[{"type":"text","text":"a"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":1,"cache_read_input_tokens":50}}`,
		},
		{
			name:     "no blocks yields one empty text block",
			upstream: `{"id":"r","status":"completed","output":[{"type":"reasoning"}]}`,
			want:     `{"id":"msg_r","type":"message","role":"assistant","model":"claude-x","content":[{"type":"text","text":""}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0}}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out, err := newResponsesTranslator().Response([]byte(tc.upstream), "claude-x")
			if err != nil {
				t.Fatal(err)
			}
			got := respNorm(t, respJSON(t, string(out)))
			want := respWantJSON(t, tc.want)
			if !reflect.DeepEqual(got, want) {
				t.Errorf("mismatch\n got  %s\n want %s", out, marshal(want))
			}
		})
	}
}

func TestResponsesResponseErrors(t *testing.T) {
	tr := newResponsesTranslator()
	for name, body := range map[string]string{
		"not json":   `nope`,
		"failed":     `{"id":"r","status":"failed","error":{"message":"boom"}}`,
		"error only": `{"error":{"message":"bad"}}`,
	} {
		if _, err := tr.Response([]byte(body), "m"); err == nil {
			t.Errorf("%s: want error", name)
		}
	}
}

// ---------------------------------------------------------------- stream

func TestResponsesStream(t *testing.T) {
	created := `{"type":"response.created","response":{"id":"resp_7","status":"in_progress"}}`
	type want struct {
		blocks []string
		stop   string
		in     int
		out    int
		cache  int
		fail   string // non-empty: stream ends with this error substring
	}
	cases := []struct {
		name string
		sse  string
		want want
	}{
		{
			name: "plain text",
			sse: respSSE(
				"response.created", created,
				"response.output_item.added", `{"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_a","role":"assistant","content":[]}}`,
				"response.output_text.delta", `{"type":"response.output_text.delta","item_id":"msg_a","output_index":0,"content_index":0,"delta":"Hel"}`,
				"response.output_text.delta", `{"type":"response.output_text.delta","item_id":"msg_a","output_index":0,"content_index":0,"delta":"lo"}`,
				"response.output_text.done", `{"type":"response.output_text.done","item_id":"msg_a","output_index":0,"text":"Hello"}`,
				"response.output_item.done", `{"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_a","content":[{"type":"output_text","text":"Hello"}]}}`,
				"response.completed", `{"type":"response.completed","response":{"id":"resp_7","status":"completed","usage":{"input_tokens":12,"output_tokens":4}}}`),
			want: want{blocks: []string{"text:Hello"}, stop: "end_turn", in: 12, out: 4},
		},
		{
			name: "text then tool",
			sse: respSSE(
				"response.created", created,
				"response.output_text.delta", `{"type":"response.output_text.delta","item_id":"msg_a","output_index":0,"delta":"run"}`,
				"response.output_item.added", `{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"Bash","arguments":""}}`,
				"response.function_call_arguments.delta", `{"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":1,"delta":"{\"cmd\":"}`,
				"response.function_call_arguments.delta", `{"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":1,"delta":"\"ls\"}"}`,
				"response.function_call_arguments.done", `{"type":"response.function_call_arguments.done","item_id":"fc_1","output_index":1,"arguments":"{\"cmd\":\"ls\"}"}`,
				"response.output_item.done", `{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"Bash","arguments":"{\"cmd\":\"ls\"}"}}`,
				"response.completed", `{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":3,"output_tokens":9}}}`),
			want: want{blocks: []string{"text:run", `tool:call_1/Bash:{"cmd":"ls"}`}, stop: "tool_use", in: 3, out: 9},
		},
		{
			name: "two tools, output_index mismatch with emission index",
			sse: respSSE(
				"response.created", created,
				"response.output_item.added", `{"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1"}}`,
				"response.reasoning_summary_text.delta", `{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","output_index":0,"delta":"thinking"}`,
				"response.output_item.done", `{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1"}}`,
				"response.output_item.added", `{"type":"response.output_item.added","output_index":3,"item":{"type":"function_call","id":"fc_a","call_id":"call_a","name":"A"}}`,
				"response.function_call_arguments.delta", `{"type":"response.function_call_arguments.delta","item_id":"fc_a","output_index":3,"delta":"{\"x\":1}"}`,
				"response.function_call_arguments.done", `{"type":"response.function_call_arguments.done","item_id":"fc_a","output_index":3,"arguments":"{\"x\":1}"}`,
				"response.output_item.added", `{"type":"response.output_item.added","output_index":5,"item":{"type":"function_call","id":"fc_b","call_id":"call_b","name":"B"}}`,
				"response.function_call_arguments.delta", `{"type":"response.function_call_arguments.delta","item_id":"fc_b","output_index":5,"delta":"{}"}`,
				"response.output_item.done", `{"type":"response.output_item.done","output_index":5,"item":{"type":"function_call","id":"fc_b","call_id":"call_b","name":"B","arguments":"{}"}}`,
				"response.completed", `{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":2}}}`),
			want: want{blocks: []string{`tool:call_a/A:{"x":1}`, "tool:call_b/B:{}"}, stop: "tool_use", in: 1, out: 2},
		},
		{
			name: "completed usage with cached tokens",
			sse: respSSE(
				"response.created", created,
				"response.output_text.delta", `{"type":"response.output_text.delta","item_id":"m","output_index":0,"delta":"ok"}`,
				"response.completed", `{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":100,"output_tokens":5,"input_tokens_details":{"cached_tokens":60}}}}`),
			want: want{blocks: []string{"text:ok"}, stop: "end_turn", in: 40, out: 5, cache: 60},
		},
		{
			name: "incomplete max_output_tokens",
			sse: respSSE(
				"response.created", created,
				"response.output_text.delta", `{"type":"response.output_text.delta","item_id":"m","output_index":0,"delta":"partial"}`,
				"response.incomplete", `{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":2,"output_tokens":50}}}`),
			want: want{blocks: []string{"text:partial"}, stop: "max_tokens", in: 2, out: 50},
		},
		{
			name: "failed after partial text",
			sse: respSSE(
				"response.created", created,
				"response.output_text.delta", `{"type":"response.output_text.delta","item_id":"m","output_index":0,"delta":"half"}`,
				"response.failed", `{"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"kaboom"}}}`,
				"response.output_text.delta", `{"type":"response.output_text.delta","item_id":"m","output_index":0,"delta":"ignored"}`),
			want: want{blocks: []string{"text:half"}, fail: "kaboom"},
		},
		{
			name: "error event",
			sse: respSSE(
				"response.created", created,
				"error", `{"type":"error","code":"rate_limit","message":"slow down"}`),
			want: want{fail: "slow down"},
		},
		{
			name: "error event named only, nested error object",
			sse: respSSE(
				"response.created", created,
				"error", `{"error":{"message":"nested"}}`),
			want: want{fail: "nested"},
		},
		{
			name: "EOF without terminal event",
			sse: respSSE(
				"response.created", created,
				"response.output_text.delta", `{"type":"response.output_text.delta","item_id":"m","output_index":0,"delta":"cut off"}`),
			want: want{blocks: []string{"text:cut off"}, stop: "end_turn"},
		},
		{
			name: "EOF without terminal during tool call",
			sse: respSSE(
				"response.created", created,
				"response.output_item.added", `{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc","call_id":"c","name":"T"}}`,
				"response.function_call_arguments.delta", `{"type":"response.function_call_arguments.delta","item_id":"fc","output_index":0,"delta":"{}"}`),
			want: want{blocks: []string{"tool:c/T:{}"}, stop: "tool_use"},
		},
		{
			name: "empty stream",
			sse:  "",
			want: want{stop: "end_turn"},
		},
		{
			name: "missing response.created: message_start emitted lazily first",
			sse: respSSE(
				"response.output_text.delta", `{"type":"response.output_text.delta","item_id":"m","output_index":0,"delta":"late"}`,
				"response.completed", `{"type":"response.completed","response":{"status":"completed"}}`),
			want: want{blocks: []string{"text:late"}, stop: "end_turn"},
		},
		{
			name: "reasoning events ignored",
			sse: respSSE(
				"response.created", created,
				"response.in_progress", `{"type":"response.in_progress","response":{}}`,
				"response.output_item.added", `{"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs"}}`,
				"response.reasoning_summary_part.added", `{"type":"response.reasoning_summary_part.added","item_id":"rs","output_index":0}`,
				"response.reasoning_summary_text.delta", `{"type":"response.reasoning_summary_text.delta","item_id":"rs","delta":"zzz"}`,
				"response.reasoning_text.delta", `{"type":"response.reasoning_text.delta","item_id":"rs","delta":"zzz"}`,
				"response.output_item.done", `{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs"}}`,
				"response.content_part.added", `{"type":"response.content_part.added","item_id":"m","output_index":1}`,
				"response.output_text.delta", `{"type":"response.output_text.delta","item_id":"m","output_index":1,"delta":"answer"}`,
				"response.completed", `{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}`),
			want: want{blocks: []string{"text:answer"}, stop: "end_turn", in: 1, out: 1},
		},
		{
			name: "event name only (no type in data)",
			sse: respSSE(
				"response.created", `{"response":{"id":"resp_n"}}`,
				"response.output_text.delta", `{"item_id":"m","output_index":0,"delta":"named"}`,
				"response.completed", `{"response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}`),
			want: want{blocks: []string{"text:named"}, stop: "end_turn", in: 4, out: 2},
		},
		{
			name: "tool args only in done events (no deltas)",
			sse: respSSE(
				"response.created", created,
				"response.output_item.added", `{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc","call_id":"c1","name":"T"}}`,
				"response.output_item.done", `{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc","call_id":"c1","name":"T","arguments":"{\"k\":2}"}}`,
				"response.completed", `{"type":"response.completed","response":{"status":"completed"}}`),
			want: want{blocks: []string{`tool:c1/T:{"k":2}`}, stop: "tool_use"},
		},
		{
			name: "text only in output_item.done (no deltas)",
			sse: respSSE(
				"response.created", created,
				"response.output_item.done", `{"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"m","content":[{"type":"output_text","text":"whole"}]}}`,
				"response.completed", `{"type":"response.completed","response":{"status":"completed"}}`),
			want: want{blocks: []string{"text:whole"}, stop: "end_turn"},
		},
		{
			name: "tool with no args at all gets {}",
			sse: respSSE(
				"response.created", created,
				"response.output_item.added", `{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc","call_id":"c1","name":"T"}}`,
				"response.output_item.done", `{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc","call_id":"c1","name":"T","arguments":""}}`,
				"response.completed", `{"type":"response.completed","response":{"status":"completed"}}`),
			want: want{blocks: []string{"tool:c1/T:{}"}, stop: "tool_use"},
		},
		{
			name: "text after tool opens a new block",
			sse: respSSE(
				"response.created", created,
				"response.output_item.added", `{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc","call_id":"c","name":"T"}}`,
				"response.function_call_arguments.delta", `{"type":"response.function_call_arguments.delta","item_id":"fc","output_index":0,"delta":"{}"}`,
				"response.output_text.delta", `{"type":"response.output_text.delta","item_id":"m","output_index":1,"delta":"after"}`,
				"response.completed", `{"type":"response.completed","response":{"status":"completed"}}`),
			want: want{blocks: []string{"tool:c/T:{}", "text:after"}, stop: "tool_use"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			evs, usage, err := respRunStream(t, tc.sse)
			if tc.want.fail != "" {
				if err == nil || !strings.Contains(err.Error(), tc.want.fail) {
					t.Fatalf("err = %v, want containing %q", err, tc.want.fail)
				}
				if len(evs) > 0 {
					respCheckInvariants(t, evs, false)
				}
				if got := respBlocks(evs); !reflect.DeepEqual(got, tc.want.blocks) {
					t.Errorf("blocks = %q, want %q", got, tc.want.blocks)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected err %v", err)
			}
			respCheckInvariants(t, evs, true)
			if got := respBlocks(evs); !reflect.DeepEqual(got, tc.want.blocks) {
				t.Errorf("blocks = %q, want %q", got, tc.want.blocks)
			}
			if got := respStopOf(evs); got != tc.want.stop {
				t.Errorf("stop_reason = %q, want %q", got, tc.want.stop)
			}
			if usage.In != tc.want.in || usage.Out != tc.want.out || usage.CacheRead != tc.want.cache {
				t.Errorf("usage = %+v, want in %d out %d cache %d", usage, tc.want.in, tc.want.out, tc.want.cache)
			}
			md := asMap(evs[len(evs)-2].data["usage"])
			if n, _ := asInt(md["output_tokens"]); n != tc.want.out {
				t.Errorf("message_delta output_tokens = %d, want %d", n, tc.want.out)
			}
		})
	}
}

func TestResponsesStreamMessageStartShape(t *testing.T) {
	evs, _, err := respRunStream(t, respSSE(
		"response.created", `{"type":"response.created","response":{"id":"resp_9"}}`,
		"response.completed", `{"type":"response.completed","response":{"status":"completed"}}`))
	if err != nil {
		t.Fatal(err)
	}
	ms := asMap(evs[0].data["message"])
	want := respWantJSON(t, `{"id":"msg_resp_9","type":"message","role":"assistant","model":"gpt-test","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}`)
	if got := respNorm(t, ms); !reflect.DeepEqual(got, want) {
		t.Errorf("message_start.message = %s", marshal(got))
	}
	md := evs[len(evs)-2].data
	if d := asMap(md["delta"]); d["stop_sequence"] != nil {
		t.Errorf("stop_sequence = %v", d["stop_sequence"])
	}
}

func TestResponsesStreamEmitError(t *testing.T) {
	sse := respSSE(
		"response.created", `{"type":"response.created","response":{}}`,
		"response.completed", `{"type":"response.completed","response":{"status":"completed"}}`)
	wantErr := strings.NewReader(sse)
	n := 0
	_, err := newResponsesTranslator().Stream(wantErr, func(string, []byte) error {
		n++
		return errResponsesTestSink
	}, "m")
	if err != errResponsesTestSink || n != 1 {
		t.Errorf("err = %v after %d emits", err, n)
	}
}

var errResponsesTestSink = &respSinkErr{}

type respSinkErr struct{}

func (*respSinkErr) Error() string { return "sink closed" }

// ---------------------------------------------------------------- errors

func TestResponsesError(t *testing.T) {
	long := strings.Repeat("x", 2500)
	cases := []struct {
		name    string
		status  int
		body    string
		wantTyp string
		wantMsg string
	}{
		{"nested error.message", 400, `{"error":{"message":"bad param","type":"invalid_request_error"}}`, "invalid_request_error", "bad param"},
		{"top-level message", 429, `{"message":"slow down"}`, "rate_limit_error", "slow down"},
		{"error as string", 401, `{"error":"nope"}`, "authentication_error", "nope"},
		{"raw text trimmed", 502, "  upstream exploded \n", "api_error", "upstream exploded"},
		{"raw capped at 2000", 500, long, "api_error", long[:2000]},
		{"json without message falls back to raw", 404, `{"detail":"gone"}`, "not_found_error", `{"detail":"gone"}`},
		{"empty body", 529, ``, "overloaded_error", "upstream returned HTTP 529"},
		{"403", 403, `{"error":{"message":"no"}}`, "permission_error", "no"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := newResponsesTranslator().Error(tc.status, []byte(tc.body))
			got := respNorm(t, respJSON(t, string(out)))
			want := respWantJSON(t, string(marshal(map[string]any{
				"type":  "error",
				"error": map[string]any{"type": tc.wantTyp, "message": tc.wantMsg},
			})))
			if !reflect.DeepEqual(got, want) {
				t.Errorf("got %s want %s", out, marshal(want))
			}
		})
	}
}

// ---------------------------------------------------------------- robustness

func TestResponsesNoPanic(t *testing.T) {
	tr := func() translator { return newResponsesTranslator() }

	reqs := []map[string]any{
		nil,
		{},
		{"messages": "nope", "tools": 5, "system": 7},
		{"messages": []any{nil, 1, "x", []any{}, map[string]any{"role": 3}}},
		{"messages": []any{map[string]any{"role": "user", "content": []any{nil, 1, map[string]any{"type": "tool_result"}, map[string]any{"type": "image"}, map[string]any{"type": "image", "source": 3}}}}},
		{"messages": []any{map[string]any{"role": "assistant", "content": []any{map[string]any{"type": "tool_use", "input": make(chan int)}}}}},
		{"tools": []any{nil, 3, map[string]any{}, map[string]any{"name": 4}, map[string]any{"name": "a", "input_schema": "str"}}, "tool_choice": "auto"},
		{"tools": []any{map[string]any{"name": "a"}}, "tool_choice": map[string]any{"type": "tool"}},
		{"tools": []any{map[string]any{"name": "a"}}, "tool_choice": 5, "max_tokens": nil, "stream": "yes"},
	}
	for i, r := range reqs {
		func() {
			defer func() {
				if p := recover(); p != nil {
					t.Errorf("Request case %d panicked: %v", i, p)
				}
			}()
			_, _, _ = tr().Request(r)
		}()
	}

	bodies := []string{
		``, `null`, `[]`, `"str"`, `{`, `{"output":"x"}`, `{"output":[null,1,"a",{}]}`,
		`{"output":[{"type":"message","content":"x"}]}`,
		`{"output":[{"type":"message","content":[null,{"type":"output_text","text":5}]}]}`,
		`{"output":[{"type":"function_call","arguments":{"a":1}}]}`,
		`{"output":[{"type":"function_call","arguments":5}],"usage":"u"}`,
		`{"usage":{"input_tokens":"x","input_tokens_details":3}}`,
		`{"status":"incomplete","incomplete_details":"str"}`,
	}
	for _, b := range bodies {
		func() {
			defer func() {
				if p := recover(); p != nil {
					t.Errorf("Response(%q) panicked: %v", b, p)
				}
			}()
			_, _ = tr().Response([]byte(b), "m")
		}()
		func() {
			defer func() {
				if p := recover(); p != nil {
					t.Errorf("Error(%q) panicked: %v", b, p)
				}
			}()
			out := tr().Error(500, []byte(b))
			if _, err := decodeObject(out); err != nil {
				t.Errorf("Error(%q) produced invalid json: %v", b, err)
			}
		}()
	}

	streams := []string{
		"data: not json\n\n",
		"data: null\n\n",
		"data: [DONE]\n\n",
		"event: response.output_text.delta\ndata: {}\n\n",
		"event: response.function_call_arguments.delta\ndata: {\"delta\":5}\n\n",
		"event: response.output_item.added\ndata: {\"item\":null}\n\n",
		"event: response.output_item.done\ndata: {\"item\":\"x\",\"output_index\":\"y\"}\n\n",
		"event: response.completed\ndata: {\"response\":\"x\"}\n\n",
		"event: response.completed\ndata: {\"response\":{\"usage\":{\"input_tokens\":null}}}\n\n",
		"event: response.failed\ndata: {}\n\n",
		"event: error\ndata: {\"error\":5}\n\n",
		": keep-alive\n\nevent: response.created\ndata: {\"response\":null}\n\n",
		"data: {\"type\":\"response.output_text.delta\",\"delta\":\"x\"}",
	}
	for _, s := range streams {
		func() {
			defer func() {
				if p := recover(); p != nil {
					t.Errorf("Stream(%q) panicked: %v", s, p)
				}
			}()
			var evs []respEv
			_, err := tr().Stream(strings.NewReader(s), func(name string, data []byte) error {
				m, derr := decodeObject(data)
				if derr != nil {
					t.Errorf("Stream(%q) emitted invalid json %q", s, data)
				}
				evs = append(evs, respEv{name, m})
				return nil
			}, "m")
			if len(evs) > 0 {
				respCheckInvariants(t, evs, err == nil)
			}
		}()
	}
}

// Request output must survive JSON encoding (what the proxy does next).
func TestResponsesRequestEncodes(t *testing.T) {
	out := respDo(t, `{"model":"m","max_tokens":10,"temperature":1,"messages":[{"role":"user","content":"hi"}]}`)
	if b, err := json.Marshal(out); err != nil || !strings.Contains(string(b), `"max_output_tokens":10`) {
		t.Errorf("encode: %s %v", b, err)
	}
}
