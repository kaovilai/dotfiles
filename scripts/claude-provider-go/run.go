package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// errCancelled is returned by supervisor.start when a cancellation already
// began: nothing was launched, so nothing needs tearing down.
var errCancelled = errors.New("claude-provider: cancelled before start")

// run prepares the backend through claude-provider-prepare.zsh and then
// supervises the native CLI for this invocation only, mirroring
// claude-provider.py's run() step for step: per-backend lock over the
// preparation only (a long session never blocks the next launch on the same
// backend), prep in its own session with stdout on stderr (so --prepare's
// JSON owns stdout), profile merge, settings file in a private tempdir
// removed on exit, native in its own session, and TERM/INT/HUP tearing down
// the child's whole process group. A cancellation never exits the process
// directly: it records 128+signal and lets the main flow return through its
// defers, so the tempdir holding the transport credentials is always removed.
func run(backend, native string, args []string) int {
	_ = syscall.Umask(0o077)
	preparationOnly := len(args) == 1 && args[0] == "--prepare"
	if preparationOnly {
		args = nil
	}
	root := os.Getenv("CLAUDE_PROVIDER_ROOT")
	if root == "" {
		fmt.Fprintln(os.Stderr, "claude-provider: CLAUDE_PROVIDER_ROOT is not set (claude-provider.zsh sets it).")
		return 1
	}
	temporary, err := os.MkdirTemp("", "claude-provider-")
	if err != nil {
		failGeneric()
		return 1
	}
	defer os.RemoveAll(temporary)

	sup := newSupervisor()
	bridgeSupervisor = sup
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	go func() {
		received, ok := <-signals
		if !ok {
			return
		}
		// Do not interrupt cleanup with a second TERM.
		signal.Ignore(syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
		code := 128
		if s, isSignal := received.(syscall.Signal); isSignal {
			code = 128 + int(s)
		}
		sup.cancel(code)
	}()

	profile, prepStatus := prepareProfile(sup, root, backend, args, temporary, preparationOnly)
	if prepStatus != 0 {
		return prepStatus
	}
	if preparationOnly {
		// Only transport metadata/model names; never credential values. The
		// endpoint is a local proxy URL, but redact any userinfo anyway so a
		// URL that ever embeds credentials cannot reach the caller's logs.
		endpoint, _ := profile.Env["ANTHROPIC_BASE_URL"]
		if parsed, err := url.Parse(endpoint); err == nil && parsed.User != nil {
			parsed.User = nil
			endpoint = parsed.String()
		}
		modelPicker, _ := profile.Settings["modelPicker"].(map[string]any)
		models := []any{}
		if modelPicker != nil {
			if options, ok := modelPicker["options"].([]any); ok {
				models = options
			}
		}
		out, err := json.Marshal(map[string]any{
			"backend":  backend,
			"endpoint": endpoint,
			"tiers":    profile.Tiers,
			"models":   models,
		})
		if err != nil {
			failGeneric()
			return 1
		}
		fmt.Println(string(out))
		return 0
	}

	// Settings "env" is applied by Claude Code itself, but some limits are
	// read before that happens. Export the entries into the child's
	// environment too (existing entries win), so every knob the launcher sets
	// in settings wins regardless of the client's timing.
	if settingsEnv, ok := profile.Settings["env"].(map[string]any); ok {
		for key, value := range settingsEnv {
			if text, isString := value.(string); isString {
				if _, present := profile.Env[key]; !present {
					profile.Env[key] = text
				}
			}
		}
	}
	// T3 has no TUI: blast-radius holds tool.call on a Pane nobody can answer.
	enabledPlugins, _ := profile.Settings["enabledPlugins"].(map[string]any)
	if enabledPlugins == nil {
		enabledPlugins = map[string]any{}
	}
	enabledPlugins["blast-radius@local-mods"] = false
	profile.Settings["enabledPlugins"] = enabledPlugins

	settingsPath := filepath.Join(temporary, "settings.json")
	settingsBody, err := json.Marshal(profile.Settings)
	if err != nil {
		failGeneric()
		return 1
	}
	if err := os.WriteFile(settingsPath, settingsBody, 0o600); err != nil {
		failGeneric()
		return 1
	}
	// The private settings file keeps transport credentials off argv.
	_ = os.Remove(filepath.Join(temporary, "profile.json"))

	child := exec.Command(native, "--settings")
	child.Args = append(child.Args, settingsPath)
	child.Args = append(child.Args, profile.Args...)
	child.Env = environSlice(profile.Env)
	child.Stdin = os.Stdin
	child.Stdout = os.Stdout
	child.Stderr = os.Stderr
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := sup.start(child); err != nil {
		if !errors.Is(err, errCancelled) {
			failGeneric()
		}
		return 1
	}
	childErr := child.Wait()
	sup.clear()
	return exitStatus(childErr, child)
}

// prepareProfile runs the ZSH preparation under the per-backend lock and
// returns the captured profile. The lock covers exactly the Python bridge's
// window — the preparation and the profile read — and is released (via the
// defers below) before the caller starts the native CLI.
func prepareProfile(sup *supervisor, root, backend string, args []string, temporary string, preparationOnly bool) (*profile, int) {
	state := xdgState()
	locks := filepath.Join(state, "claude-provider")
	if err := os.MkdirAll(locks, 0o700); err != nil {
		failGeneric()
		return nil, 1
	}
	// Separate backend locks prevent concurrent config writes/startup through
	// these launchers. Interactive shells retain their existing lifecycle.
	// The wait is cancellation-aware: Python's blocking flock let a signal
	// interrupt the wait, so a TERM while queued behind another session's
	// preparation must return instead of blocking until that session ends.
	lock, err := os.OpenFile(filepath.Join(locks, backend+".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		failGeneric()
		return nil, 1
	}
	defer func() {
		_ = syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
		_ = lock.Close()
	}()
	for {
		err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			failGeneric()
			return nil, 1
		}
		if sup.cancelRequested() {
			// main applies the recorded 128+signal once the cancel path is
			// done; nothing was started, so there is nothing to tear down.
			return nil, 1
		}
		time.Sleep(50 * time.Millisecond)
	}

	profilePath := filepath.Join(temporary, "profile.json")
	self, err := os.Executable()
	if err != nil {
		failGeneric()
		return nil, 1
	}
	environment := environMap()
	environment["CLAUDE_PROVIDER_PROFILE"] = profilePath
	environment["CLAUDE_PROVIDER_PREPARATION_ONLY"] = boolDigit(preparationOnly)
	environment["CLAUDE_PROVIDER_CONFIG_DIR_PRESENT"] = boolDigit(environment["CLAUDE_CONFIG_DIR"] != "")
	environment["CLAUDE_PROVIDER_CONFIG_DIR"] = environment["CLAUDE_CONFIG_DIR"]
	environment["CLAUDE_PROVIDER_CAPTURE_SCRIPT"] = self
	environment["CLAUDE_PROVIDER_ROOT"] = root

	// --prepare may take a cold-start minute; do it before T3's SDK probe.
	prep := exec.Command("/bin/zsh", "-f", "-c",
		`source "$1"; shift; claude-provider-prepare "$@"`,
		"claude-provider", filepath.Join(root, "scripts/claude-provider-prepare.zsh"), root, backend)
	prep.Args = append(prep.Args, args...)
	prep.Env = environSlice(environment)
	prep.Stdin = devNull()
	prep.Stdout = os.Stderr
	prep.Stderr = os.Stderr
	prep.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := sup.start(prep); err != nil {
		if !errors.Is(err, errCancelled) {
			failGeneric()
		}
		return nil, 1
	}
	prepErr := prep.Wait()
	sup.clear()
	if prepErr != nil {
		return nil, exitStatus(prepErr, prep)
	}

	profile, err := readProfile(profilePath)
	if err != nil {
		failGeneric()
		return nil, 1
	}
	return profile, 0
}

// supervisor tracks the live child so a cancellation can tear down its whole
// process group (the children start their own sessions, so the group is the
// pid). A cancellation owns the exit code but never the process exit: the
// main flow returns through its defers (tempdir removed, locks released) and
// main applies the recorded code — a direct os.Exit here would skip those
// defers and leave the credentials-bearing tempdir behind.
type supervisor struct {
	mu         sync.Mutex
	cmd        *exec.Cmd
	cancelling bool
	exitCode   int
	done       chan struct{}
}

func newSupervisor() *supervisor {
	return &supervisor{done: make(chan struct{})}
}

// start launches cmd with the cancel race closed: a cancellation that already
// began refuses to start the process at all, and one that arrives after the
// start still reaches the group via cancel() (the process is visible to it the
// moment it exists, both under mu).
func (s *supervisor) start(cmd *exec.Cmd) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cancelling {
		return errCancelled
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	s.cmd = cmd
	return nil
}

// cancelRequested is a lock-guarded read of the cancellation flag.
func (s *supervisor) cancelRequested() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cancelling
}

func (s *supervisor) clear() {
	s.mu.Lock()
	s.cmd = nil
	s.mu.Unlock()
}

// cancel tears the child's group down — TERM, then signal-0 polls until the
// group is genuinely empty (the main flow owns the child's Wait, so a second
// Wait cannot observe the reaping), then KILL — and records the exit code.
// The main flow can compute the same 128+signal from the child's exit status
// on its own; main resolves the race by waiting for done and preferring this
// code.
func (s *supervisor) cancel(code int) {
	s.mu.Lock()
	s.cancelling = true
	s.exitCode = code
	cmd := s.cmd
	s.mu.Unlock()
	if cmd != nil && cmd.Process != nil {
		pid := cmd.Process.Pid
		_ = syscall.Kill(-pid, syscall.SIGTERM)
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if err := syscall.Kill(-pid, 0); err != nil {
				break // group gone
			}
			time.Sleep(50 * time.Millisecond)
		}
		_ = syscall.Kill(-pid, syscall.SIGKILL)
	}
	close(s.done)
}

// cancelResult is 0 when no cancellation happened; otherwise it waits for the
// teardown to finish (bounded by its 5 s budget plus margin) and returns the
// recorded code.
func (s *supervisor) cancelResult() int {
	s.mu.Lock()
	cancelling := s.cancelling
	s.mu.Unlock()
	if !cancelling {
		return 0
	}
	select {
	case <-s.done:
	case <-time.After(10 * time.Second):
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.exitCode
}

// exitStatus maps a child result to the Python bridge's convention: a signal
// death becomes 128+signal, anything else keeps the child's code, and a spawn
// failure reports the generic message.
func exitStatus(err error, cmd *exec.Cmd) int {
	if err == nil {
		return cmd.ProcessState.ExitCode()
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		if status, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && status.Signaled() {
			return 128 + int(status.Signal())
		}
		return cmd.ProcessState.ExitCode()
	}
	failGeneric()
	return 1
}

// profile is the capture contract: what claude-provider-prepare.zsh's final
// _claude_invoke captured for this invocation.
type profile struct {
	Args     []string          `json:"args"`
	Settings map[string]any    `json:"settings"`
	Env      map[string]string `json:"env"`
	Tiers    map[string]any    `json:"tiers"`
}

func readProfile(path string) (*profile, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var p profile
	if err := json.Unmarshal(body, &p); err != nil {
		return nil, err
	}
	if p.Settings == nil {
		p.Settings = map[string]any{}
	}
	if p.Env == nil {
		p.Env = map[string]string{}
	}
	return &p, nil
}

func environMap() map[string]string {
	env := map[string]string{}
	for _, entry := range os.Environ() {
		if key, value, found := strings.Cut(entry, "="); found {
			env[key] = value
		}
	}
	return env
}

func environSlice(env map[string]string) []string {
	out := make([]string, 0, len(env))
	for key, value := range env {
		out = append(out, key+"="+value)
	}
	return out
}

func boolDigit(value bool) string {
	if value {
		return "1"
	}
	return "0"
}

func devNull() *os.File {
	file, err := os.OpenFile(os.DevNull, os.O_RDONLY, 0)
	if err != nil {
		failGeneric()
		os.Exit(1)
	}
	return file
}
