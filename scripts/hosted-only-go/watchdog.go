package main

// Timeout model (2026-11-11).
//
// The proxy used http.Client.Timeout = REQUEST_TIMEOUT, a TOTAL deadline that
// includes the streamed body. A GLM answer that streamed actively for longer
// than 180 s was therefore cut mid-answer ("upstream stream interrupted:
// context deadline exceeded"), with no fallback possible (bytes had already
// reached the client), and Claude Code surfaced the abort as "Claude API
// unknown".
//
// Now: the response-header (first-byte) budget is REQUEST_TIMEOUT via
// Transport.ResponseHeaderTimeout, and the body is watched by an idle timer
// (STREAM_IDLE_TIMEOUT): a stream that keeps producing bytes lives as long as
// it needs; only a stall with no bytes for that long is cut. A header timeout
// happens before anything reached the client, so the normal failover path can
// still try the sibling; a stalled stream that already wrote bytes is ended
// with a retryable rate-limit error event carrying the outage backoff wait.

import (
	"context"
	"fmt"
	"io"
	"sync"
	"time"
)

// idleBody cuts a response body that produces no bytes for `idle` by
// cancelling the request context (which unblocks an in-flight Read).
type idleBody struct {
	r    io.ReadCloser
	idle time.Duration
	stop context.CancelFunc

	mu      sync.Mutex
	timer   *time.Timer
	stalled bool
	closed  bool
}

func newIdleBody(r io.ReadCloser, idle time.Duration, stop context.CancelFunc) io.ReadCloser {
	if idle <= 0 {
		return r
	}
	b := &idleBody{r: r, idle: idle, stop: stop}
	b.timer = time.AfterFunc(idle, b.fire)
	return b
}

func (b *idleBody) fire() {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return
	}
	b.stalled = true
	b.mu.Unlock()
	b.stop() // cancels the request; the blocked Read returns an error
}

func (b *idleBody) Read(p []byte) (int, error) {
	n, err := b.r.Read(p)
	b.mu.Lock()
	stalled := b.stalled
	if n > 0 && !b.closed && b.timer != nil {
		b.timer.Reset(b.idle)
	}
	b.mu.Unlock()
	if stalled {
		if err == nil {
			err = context.Canceled
		}
		return n, fmt.Errorf("upstream stream idle for %s (no bytes): %w", b.idle, err)
	}
	return n, err
}

func (b *idleBody) Close() error {
	b.mu.Lock()
	b.closed = true
	if b.timer != nil {
		b.timer.Stop()
	}
	b.mu.Unlock()
	b.stop() // release the per-request context once the body is done
	return b.r.Close()
}
