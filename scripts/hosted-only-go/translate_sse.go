package main

import (
	"bufio"
	"bytes"
	"io"
	"strings"
)

// sseEvents reads an upstream Server-Sent Events stream and calls fn once per
// event with the event name (empty when the stream has no "event:" lines, as
// OpenAI chat streams do) and the joined data payload. A "[DONE]" data line is
// delivered as data "[DONE]" so the caller can finish. Comment lines (":" prefix)
// and unknown fields are ignored. Lines may be very long (a tool-call chunk with
// a big argument fragment), so the scanner buffer is large. fn returning an error
// stops the read and is returned.
func sseEvents(r io.Reader, fn func(event string, data []byte) error) error {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 16<<20)
	var event string
	var data bytes.Buffer
	haveData := false
	flush := func() error {
		defer func() { event = ""; data.Reset(); haveData = false }()
		if !haveData {
			return nil
		}
		return fn(event, data.Bytes())
	}
	for sc.Scan() {
		line := sc.Text()
		switch {
		case line == "":
			if err := flush(); err != nil {
				return err
			}
		case strings.HasPrefix(line, ":"):
			// comment / keep-alive
		case strings.HasPrefix(line, "event:"):
			event = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
		case strings.HasPrefix(line, "data:"):
			payload := strings.TrimPrefix(line, "data:")
			payload = strings.TrimPrefix(payload, " ")
			if haveData {
				data.WriteByte('\n')
			}
			data.WriteString(payload)
			haveData = true
		}
	}
	if err := sc.Err(); err != nil {
		return err
	}
	return flush() // a final event without the blank line
}
