package main

import (
	"errors"
	"io"
)

// chatTranslator bridges Messages <-> OpenAI chat completions. STUB: the real
// implementation replaces this file.
type chatTranslator struct{}

func newChatTranslator() translator { return &chatTranslator{} }

var errNotImplemented = errors.New("translator not implemented")

func (t *chatTranslator) Request(req map[string]any) (string, map[string]any, error) {
	return "", nil, errNotImplemented
}
func (t *chatTranslator) Response(upstream []byte, model string) ([]byte, error) {
	return nil, errNotImplemented
}
func (t *chatTranslator) Stream(r io.Reader, emit func(string, []byte) error, model string) (usageInfo, error) {
	return usageInfo{}, errNotImplemented
}
func (t *chatTranslator) Error(status int, body []byte) []byte { return nil }
