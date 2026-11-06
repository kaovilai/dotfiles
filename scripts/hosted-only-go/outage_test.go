package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestOutageBackoffSemantics(t *testing.T) {
	tr := newOutageTracker("", 60, 600, 5*time.Second)
	now := time.Now()

	if wait := tr.wait("glm", now); wait != 60 {
		t.Fatalf("first failure: want 60, got %d", wait)
	}
	// Same episode (within the coalesce window): parallel requests hitting the
	// same blip must not each double the wait.
	if wait := tr.wait("glm", now.Add(2*time.Second)); wait != 60 {
		t.Fatalf("same episode: want 60, got %d", wait)
	}
	// A later failure in the same streak window doubles.
	if wait := tr.wait("glm", now.Add(30*time.Second)); wait != 120 {
		t.Fatalf("second failure: want 120, got %d", wait)
	}
	if wait := tr.wait("glm", now.Add(60*time.Second)); wait != 240 {
		t.Fatalf("third failure: want 240, got %d", wait)
	}
	// A success clears the streak.
	tr.success("glm")
	if wait := tr.wait("glm", now.Add(90*time.Second)); wait != 60 {
		t.Fatalf("after success: want 60, got %d", wait)
	}
	// A failure more than the streak window after the previous one starts over.
	if wait := tr.wait("deepseek", now); wait != 60 {
		t.Fatalf("other model: want 60, got %d", wait)
	}
	if wait := tr.wait("deepseek", now.Add(16*time.Minute)); wait != 60 {
		t.Fatalf("past the streak window: want 60, got %d", wait)
	}
}

func TestOutageCap(t *testing.T) {
	tr := newOutageTracker("", 60, 600, 0)
	now := time.Now()
	wait := 0
	for i := 0; i < 10; i++ {
		wait = tr.wait("glm", now.Add(time.Duration(i)*time.Minute))
	}
	if wait != 600 {
		t.Fatalf("want the 600s cap, got %d", wait)
	}
}

func TestOutagePersistence(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outage-streak.json")
	now := time.Now()

	first := newOutageTracker(path, 60, 600, 5*time.Second)
	if wait := first.wait("glm", now); wait != 60 {
		t.Fatalf("first: %d", wait)
	}
	if wait := first.wait("glm", now.Add(30*time.Second)); wait != 120 {
		t.Fatalf("second: %d", wait)
	}

	// A restarted proxy continues the streak from the state file.
	restarted := newOutageTracker(path, 60, 600, 5*time.Second)
	if wait := restarted.wait("glm", now.Add(60*time.Second)); wait != 240 {
		t.Fatalf("after restart: want 240 (streak continued), got %d", wait)
	}
	// The file holds the live streak in the python schema.
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var saved map[string][2]float64
	if json.Unmarshal(data, &saved) != nil {
		t.Fatal("state file is not the python {model: [count, last]} shape")
	}
	if saved["glm"][0] != 3 {
		t.Fatalf("saved count: want 3, got %v", saved["glm"])
	}
}

func TestOutageSuccessPersistsTheClear(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outage-streak.json")
	now := time.Now()
	first := newOutageTracker(path, 60, 600, 5*time.Second)
	first.wait("glm", now)
	first.wait("glm", now.Add(30*time.Second))
	first.success("glm")
	// A restart inside the streak window must not resurrect the cleared
	// count: one blip then gives 60 s, not the doubled wait.
	restarted := newOutageTracker(path, 60, 600, 5*time.Second)
	if _, ok := restarted.streaks["glm"]; ok {
		t.Fatal("a cleared streak must not survive a restart")
	}
	if wait := restarted.wait("glm", now.Add(60*time.Second)); wait != 60 {
		t.Fatalf("after a cleared streak: want 60, got %d", wait)
	}
}

func TestOutagePersistencePrunesDeadModels(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outage-streak.json")
	now := time.Now()
	tr := newOutageTracker(path, 60, 600, 5*time.Second)
	tr.wait("live-model", now)
	tr.streaks["dead-model"] = outageStreak{count: 2, last: now.Add(-3 * outageStreakWindow)}
	tr.save(now)

	restarted := newOutageTracker(path, 60, 600, 5*time.Second)
	if _, ok := restarted.streaks["dead-model"]; ok {
		t.Fatal("a model last seen two streak windows ago must not survive the state file")
	}
	if _, ok := restarted.streaks["live-model"]; !ok {
		t.Fatal("the live model must survive the state file")
	}
}
