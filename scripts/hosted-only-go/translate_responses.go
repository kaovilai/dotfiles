package main

import "io"

// responsesTranslator bridges Messages <-> the OpenAI Responses API. STUB: the
// real implementation replaces this file.
type responsesTranslator struct{}

func newResponsesTranslator() translator { return &responsesTranslator{} }

func (t *responsesTranslator) Request(req map[string]any) (string, map[string]any, error) {
	return "", nil, errNotImplemented
}
func (t *responsesTranslator) Response(upstream []byte, model string) ([]byte, error) {
	return nil, errNotImplemented
}
func (t *responsesTranslator) Stream(r io.Reader, emit func(string, []byte) error, model string) (usageInfo, error) {
	return usageInfo{}, errNotImplemented
}
func (t *responsesTranslator) Error(status int, body []byte) []byte { return nil }
