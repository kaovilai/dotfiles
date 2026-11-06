package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"sync"
	"time"
)

// outageTracker ports hosted_only_hooks.py's outage backoff exactly:
//
//   - HOSTED_ONLY_OUTAGE_RETRY_SECONDS (base) doubling per consecutive failure
//     of the same model, capped at _MAX_SECONDS.
//   - A failure more than 15 min (outageStreakWindow) after the previous one
//     starts the streak over.
//   - Failures less than OUTAGE_COALESCE_SECONDS apart (default 5) are one
//     episode — parallel requests hitting the same blip must not each double
//     the wait.
//   - Any later success clears the streak.
//   - The streak survives a restart when HOSTED_ONLY_OUTAGE_STATE points at a
//     writable file (the launcher passes the runtime dir), persisted only when
//     the episode count moves, written atomically (the restart machinery kills
//     this process; a truncate-then-write caught mid-flight silently dropped
//     the whole backoff history).
type outageTracker struct {
	mu       sync.Mutex
	streaks  map[string]outageStreak
	file     string
	base     int
	max      int
	coalesce time.Duration
}

const outageStreakWindow = 15 * time.Minute

func newOutageTracker(file string, base, max int, coalesce time.Duration) *outageTracker {
	t := &outageTracker{
		streaks:  map[string]outageStreak{},
		file:     file,
		base:     base,
		max:      max,
		coalesce: coalesce,
	}
	t.load()
	return t
}

// load reads {"model": [count, last-epoch]} written by an earlier process.
func (t *outageTracker) load() {
	if t.file == "" {
		return
	}
	data, err := os.ReadFile(t.file)
	if err != nil {
		return
	}
	var saved map[string][2]float64
	if json.Unmarshal(data, &saved) != nil {
		return
	}
	for model, row := range saved {
		count := int(row[0])
		if count < 1 {
			count = 1
		}
		seconds, fraction := math.Modf(row[1])
		t.streaks[model] = outageStreak{count: count, last: time.Unix(int64(seconds), int64(fraction*1e9)).UTC()}
	}
}

// save keeps only live entries (last seen within two streak windows) so the
// file does not grow with long-dead models.
func (t *outageTracker) save(now time.Time) {
	if t.file == "" {
		return
	}
	live := map[string][2]float64{}
	for model, streak := range t.streaks {
		if streak.last.After(now.Add(-2 * outageStreakWindow)) {
			live[model] = [2]float64{float64(streak.count), float64(streak.last.UnixMilli()) / 1e3}
		}
	}
	body, err := json.Marshal(live)
	if err != nil {
		return
	}
	tmp := fmt.Sprintf("%s.%d.tmp", t.file, os.Getpid())
	if os.WriteFile(tmp, body, 0o600) == nil {
		_ = os.Rename(tmp, t.file)
	}
}

// wait is outage_wait: seconds a client should wait after this failure.
func (t *outageTracker) wait(model string, now time.Time) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	prev := t.streaks[model]
	count := prev.count
	elapsed := now.Sub(prev.last)
	if elapsed > outageStreakWindow {
		count = 1
	} else if elapsed > t.coalesce {
		count++
	} // else: same episode (simultaneous failures), count unchanged
	grew := count != prev.count
	t.streaks[model] = outageStreak{count: count, last: now}
	// Persist only when the episode count moved: `last` alone is not worth a
	// truncate+write on the hot path for every failing request.
	if grew {
		t.save(now)
	}
	wait := t.base
	for i := 1; i < count && wait < t.max; i++ {
		wait *= 2
	}
	if wait > t.max {
		wait = t.max
	}
	return wait
}

// success clears the streak: async_post_call_success_hook's behavior, which
// also persists the clear — otherwise a restart inside the streak window
// would resurrect the old count and one blip would jump straight to the
// doubled wait.
func (t *outageTracker) success(model string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if _, ok := t.streaks[model]; ok {
		delete(t.streaks, model)
		if t.file != "" {
			t.save(time.Now())
		}
	}
}
