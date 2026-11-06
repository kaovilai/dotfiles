package main

import (
	"errors"
	"strings"
	"testing"
)

func TestSSEEventsParsing(t *testing.T) {
	in := ": keep-alive\n" +
		"event: response.output_text.delta\ndata: {\"a\":1}\n\n" +
		"data: {\"b\":2}\ndata: {\"c\":3}\n\n" + // multi-line data joins with \n
		"data: [DONE]\n\n" +
		"event: tail\ndata: last" // no trailing blank line
	type ev struct{ name, data string }
	var got []ev
	if err := sseEvents(strings.NewReader(in), func(e string, d []byte) error {
		got = append(got, ev{e, string(d)})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	want := []ev{
		{"response.output_text.delta", `{"a":1}`},
		{"", "{\"b\":2}\n{\"c\":3}"},
		{"", "[DONE]"},
		{"tail", "last"},
	}
	if len(got) != len(want) {
		t.Fatalf("got %d events %v, want %d", len(got), got, len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("event %d = %v, want %v", i, got[i], want[i])
		}
	}
}

func TestSSEEventsStopsOnCallbackError(t *testing.T) {
	boom := errors.New("boom")
	calls := 0
	err := sseEvents(strings.NewReader("data: 1\n\ndata: 2\n\n"), func(string, []byte) error {
		calls++
		return boom
	})
	if !errors.Is(err, boom) || calls != 1 {
		t.Fatalf("err=%v calls=%d", err, calls)
	}
}

func TestSSEEventsLongLine(t *testing.T) {
	big := strings.Repeat("x", 3<<20) // a 3 MB tool-call fragment
	n := 0
	if err := sseEvents(strings.NewReader("data: "+big+"\n\n"), func(_ string, d []byte) error {
		n = len(d)
		return nil
	}); err != nil || n != len(big) {
		t.Fatalf("err=%v n=%d", err, n)
	}
}

func TestTranslatableAndErrorType(t *testing.T) {
	if !translatable("/v1/messages", "openai") || !translatable("/v1/messages", "responses") {
		t.Fatal("messages -> chat/responses must be translatable")
	}
	if translatable("/v1/messages", "anthropic") || translatable("/v1/chat/completions", "responses") || translatable("/v1/responses", "openai") {
		t.Fatal("only Messages clients bridge to chat/responses")
	}
	for status, want := range map[int]string{400: "invalid_request_error", 401: "authentication_error", 429: "rate_limit_error", 529: "overloaded_error", 502: "api_error"} {
		if got := anthropicErrorType(status); got != want {
			t.Fatalf("%d -> %s, want %s", status, got, want)
		}
	}
	if newTranslator("openai") == nil || newTranslator("responses") == nil || newTranslator("anthropic") != nil {
		t.Fatal("newTranslator registry")
	}
}
