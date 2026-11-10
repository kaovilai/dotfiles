package main

// mlx warm gate (CLAUDE_MLX_* knobs, only the mlx flavor).
//
// mlx_lm.server loads its weights at STARTUP (observed 2026-11-10: ~6.7 GB
// seconds after spawn, before any completion) and answers /health while it
// loads. Everything that spawns the provider wrapper -- T3's periodic
// capability probe above all -- must therefore not start it, and a real
// request that arrives cold must not block inside the load either.
//
// So the launcher starts only the proxy, and this gate owns the server:
//   - listener absent  -> spawn CLAUDE_MLX_SERVER_CMD (detached, logged),
//     answer 429 + retry-after so the client retries instead of timing out;
//   - listener present, RSS below CLAUDE_MLX_LOADED_RSS_KB -> still warming,
//     same 429;
//   - RSS at/above the threshold -> forward.
// Provider capability probes never send an API request (their prompt
// generator never yields), so they can never spawn the server here.

import (
	"bytes"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type warmGate struct {
	mu        sync.Mutex
	checkedAt time.Time
	resident  bool
	kickedAt  time.Time
	warmStart time.Time
}

// Overridable in tests.
var (
	// mlxListenerRSS returns the mlx_lm.server listener's RSS in KB and
	// whether a listener was found at all. measurable=false (no lsof/ps) makes
	// the gate fail open instead of holding every request.
	mlxListenerRSS = func(base string) (rssKB int, found bool, measurable bool) {
		port := portOf(base)
		if port == "" {
			return 0, false, false
		}
		out, err := exec.Command("lsof", "-ti", "tcp:"+port, "-sTCP:LISTEN").Output()
		if err != nil {
			// A clean "no matches" exit is indistinguishable from a broken
			// lsof here; treat a missing ps/lsof as unmeasurable (fail open)
			// and an empty answer as no listener.
			if len(bytes.TrimSpace(out)) == 0 {
				return 0, false, true
			}
			return 0, false, false
		}
		pid := strings.TrimSpace(strings.SplitN(strings.TrimSpace(string(out)), "\n", 2)[0])
		if pid == "" {
			return 0, false, true
		}
		out, err = exec.Command("ps", "-o", "rss=", "-p", pid).Output()
		if err != nil {
			return 0, true, false
		}
		kb, err := strconv.Atoi(strings.TrimSpace(string(out)))
		if err != nil {
			return 0, true, false
		}
		return kb, true, true
	}
	// mlxSpawnServer starts mlx_lm.server detached; its own startup is the
	// load. Only ever called from a real API request path.
	mlxSpawnServer = func(command, log string) {
		cmd := exec.Command("sh", "-c", command)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		if log != "" {
			if f, err := os.OpenFile(log, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600); err == nil {
				cmd.Stdout, cmd.Stderr = f, f
				defer f.Close()
			}
		}
		_ = cmd.Start()
	}
)

// warmReady reports whether the request may be forwarded. When it returns
// false the gate has already answered 429.
func (a *app) warmReady(w http.ResponseWriter, r *http.Request, data map[string]any, base, served, requested string, started time.Time) bool {
	if a.cfg.Flavor != "mlx" || a.cfg.WarmRSSKB <= 0 {
		return true
	}
	now := time.Now()
	a.warmGateState.mu.Lock()
	if now.Sub(a.warmGateState.checkedAt) < time.Second {
		resident := a.warmGateState.resident
		a.warmGateState.mu.Unlock()
		if resident {
			return true
		}
		// Cached verdict: no spawn decision here (the 1 s window is shorter
		// than any spawn guard anyway); the uncached path below spawns.
		a.writeWarm(w, r, data, served, requested, started)
		return false
	}
	a.warmGateState.mu.Unlock()

	rss, found, measurable := mlxListenerRSS(base)
	if !measurable {
		return true // cannot measure: never wedge the proxy on a guess
	}
	resident := found && rss >= a.cfg.WarmRSSKB

	a.warmGateState.mu.Lock()
	a.warmGateState.checkedAt, a.warmGateState.resident = now, resident
	if resident {
		a.warmGateState.warmStart = time.Time{}
	} else if a.warmGateState.warmStart.IsZero() {
		a.warmGateState.warmStart = now
	}
	// A load that outlasts the budget is not "warming" any more (dead server,
	// missing model): stop holding the client; the request waits upstream.
	giveUp := !resident && a.cfg.WarmMax > 0 && now.Sub(a.warmGateState.warmStart) > time.Duration(a.cfg.WarmMax)*time.Second
	a.warmGateState.mu.Unlock()
	if giveUp || resident {
		return true
	}
	a.warmKick(base, found, now)
	a.writeWarm(w, r, data, served, requested, started)
	return false
}

// warmKick starts the server (listener absent) or lets a loading startup
// finish, at most once per 120 s: a duplicate spawn would load a second copy
// of the weights, and a burst of parallel requests must not queue one each.
func (a *app) warmKick(base string, found bool, now time.Time) {
	// A present listener is already loading; spawning another would load a
	// second copy of the weights.
	if found || a.cfg.WarmServerCmd == "" {
		return
	}
	a.warmGateState.mu.Lock()
	if now.Sub(a.warmGateState.kickedAt) < 120*time.Second {
		a.warmGateState.mu.Unlock()
		return
	}
	a.warmGateState.kickedAt = now
	a.warmGateState.mu.Unlock()
	go mlxSpawnServer(a.cfg.WarmServerCmd, a.cfg.WarmServerLog)
}

// writeWarm answers a request that arrived while the model was not resident:
// 429 + retry-after, in the client's dialect, so the client retries and
// prolongs its wait instead of failing the turn on its own timeout.
func (a *app) writeWarm(w http.ResponseWriter, r *http.Request, data map[string]any, served, requested string, started time.Time) {
	seconds := a.cfg.WarmRetryAfter
	if seconds <= 0 {
		seconds = 30
	}
	w.Header().Set("retry-after", strconv.Itoa(seconds))
	w.Header().Set("x-should-retry", "true")
	var body []byte
	if strings.Contains(r.URL.Path, "/v1/messages") {
		inner := marshal(map[string]any{
			"type":  "error",
			"error": map[string]any{"type": "rate_limit_error", "message": "MLX model is loading; retry shortly."},
		})
		body = marshal(map[string]any{
			"type": "error",
			"error": map[string]any{
				"type":    "rate_limit_error",
				"message": "[" + served + "] [429]: " + string(inner) + " (model loading, retry in " + strconv.Itoa(seconds) + "s)",
			},
		})
	} else {
		body = marshal(map[string]any{"error": map[string]any{
			"message": "MLX model is loading; retry shortly. Try again in " + strconv.Itoa(seconds) + "s.",
			"type":    "rate_limit_exceeded",
			"code":    "429",
		}})
	}
	a.writeJSON(w, http.StatusTooManyRequests, nil, body)
	now := time.Now()
	a.usage.write(a.event(r, data, requested, served, started, usageInfo{}, false, http.StatusTooManyRequests, 0,
		"mlx warm: model not resident", true, now.Unix()+int64(seconds), "estimate:warm", false, seconds, false, "", false, "", 0))
}

// portOf extracts the :port of a base URL ("http://127.0.0.1:4143/v1").
func portOf(base string) string {
	u, err := url.Parse(base)
	if err != nil || u.Port() == "" {
		return ""
	}
	return u.Port()
}
