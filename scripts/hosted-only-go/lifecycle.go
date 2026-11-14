package main

// Lifecycle subcommands — ensure, stop, status, watch — move the launcher's
// process management for the Go impl out of scripts/hosted-only-proxy.zsh and
// scripts/llm-proxy-watch.zsh: fingerprint comparison against the running
// proxy, idle detection, detached spawn with log rotation, stop-by-identity,
// and the restart-at-first-idle watcher.
//
// The fingerprint VALUES still come from the launcher (same protocol and same
// inputs as the LiteLLM path), so both impls restart on the same config
// changes; only the mechanics live here. Port probes mirror
// zsh/functions/claude/common.zsh (_claude_listen_pids, _claude_port_serving)
// and the stop matching mirrors _hosted_only_proxy_stop, so a Go `stop` can
// retire a stale LiteLLM listener after an impl switch and vice versa.

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	ensureLockTimeout = 120 * time.Second
	stopWaitFree      = 15 * time.Second
	defaultBootWait   = 15 * time.Second
	watchPoll         = 2 * time.Second
	watchIdlePolls    = 2
	logRotateBytes    = 8 << 20
)

// --- port probes -------------------------------------------------------------

// parsePIDs reads one pid per line.
func parsePIDs(out []byte) []int {
	var pids []int
	for _, line := range strings.Fields(string(out)) {
		if pid, err := strconv.Atoi(line); err == nil && pid > 0 {
			pids = append(pids, pid)
		}
	}
	return pids
}

// listenPIDs mirrors _claude_listen_pids: lsof where installed, else ss.
func listenPIDs(port string) []int {
	if path, err := exec.LookPath("lsof"); err == nil {
		out, _ := exec.Command(path, "-ti", "tcp:"+port, "-sTCP:LISTEN").Output()
		pids := parsePIDs(out)
		sort.Ints(pids)
		return dedupeInts(pids)
	}
	if path, err := exec.LookPath("ss"); err == nil {
		out, _ := exec.Command(path, "-Hltnp", "sport = :"+port).Output()
		var pids []int
		text := string(out)
		for {
			idx := strings.Index(text, "pid=")
			if idx < 0 {
				break
			}
			text = text[idx+4:]
			num := text
			if cut := strings.IndexFunc(num, func(r rune) bool { return r < '0' || r > '9' }); cut >= 0 {
				num = num[:cut]
			}
			if pid, err := strconv.Atoi(num); err == nil && pid > 0 {
				pids = append(pids, pid)
			}
		}
		sort.Ints(pids)
		return dedupeInts(pids)
	}
	return nil
}

func dedupeInts(values []int) []int {
	out := values[:0]
	for i, v := range values {
		if i == 0 || v != values[i-1] {
			out = append(out, v)
		}
	}
	return out
}

// inflightHasRequests reports whether an inflight-<port>-<pid>.json has at
// least one request in flight.
func inflightHasRequests(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var doc struct {
		Requests map[string]json.RawMessage `json:"requests"`
	}
	if json.Unmarshal(data, &doc) != nil {
		return false
	}
	return len(doc.Requests) > 0
}

// usageInflightDir mirrors the zsh LLM_USAGE_DIR resolution.
func usageInflightDir() string {
	if dir := os.Getenv("LLM_USAGE_DIR"); dir != "" {
		return dir
	}
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		state = os.Getenv("HOME") + "/.local/state"
	}
	return state + "/llm-usage"
}

// portServing mirrors _claude_port_serving: the port's inflight files are the
// preferred source (a keep-alive pool holds ESTABLISHED sockets between
// requests, so sockets alone would read busy forever); a live reporter with an
// empty table says idle, and only dead-pid leftovers fall back to the socket
// test.
func portServing(port string) bool {
	matches, _ := filepath.Glob(filepath.Join(usageInflightDir(), "inflight-"+port+"-*.json"))
	reporter := false
	for _, path := range matches {
		base := strings.TrimSuffix(filepath.Base(path), ".json")
		pid, err := strconv.Atoi(base[strings.LastIndexByte(base, '-')+1:])
		if err != nil || !pidAlive(pid) {
			continue
		}
		reporter = true
		if inflightHasRequests(path) {
			return true
		}
	}
	if reporter {
		return false
	}
	if path, err := exec.LookPath("lsof"); err == nil {
		out, _ := exec.Command(path, "-nP", "-iTCP:"+port, "-sTCP:ESTABLISHED", "-Fn").Output()
		for _, line := range strings.Split(string(out), "\n") {
			if strings.HasPrefix(line, "n") && strings.Contains(line, ":"+port+"->") {
				return true
			}
		}
		return false
	}
	if path, err := exec.LookPath("ss"); err == nil {
		out, _ := exec.Command(path, "-Htn", "state", "established", "sport = :"+port).Output()
		return len(strings.TrimSpace(string(out))) > 0
	}
	return false
}

func healthOK(port string, timeout time.Duration) bool {
	// DisableKeepAlives: this process's own pooled health connection would
	// otherwise show up as ESTABLISHED on the port and make an idle proxy read
	// busy in the socket fallback (the zsh path used curl, a process that
	// exits).
	client := &http.Client{
		Timeout:   timeout,
		Transport: &http.Transport{DisableKeepAlives: true},
	}
	resp, err := client.Get("http://127.0.0.1:" + port + "/health/liveliness")
	if err != nil {
		return false
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

func waitHealthy(port string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for {
		if healthOK(port, time.Second) {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func waitPortFree(port string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for {
		if len(listenPIDs(port)) == 0 {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// --- identity ----------------------------------------------------------------

// procCmdline mirrors the zsh `ps -o command= -p <pid>`.
func procCmdline(pid int) string {
	out, err := exec.Command("ps", "-o", "command=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// ownsPortListener reports whether the pid's command line names this proxy's
// config under the current or a legacy runtime dir (same match set as
// _hosted_only_proxy_stop, so Go and LiteLLM listeners are interchangeable).
func ownsPortListener(cmd, runtimeDir string, legacyDirs []string, port string) bool {
	for _, dir := range append([]string{runtimeDir}, legacyDirs...) {
		if dir == "" {
			continue
		}
		if strings.Contains(cmd, dir+"/config.yaml") || strings.Contains(cmd, dir+"/routes.json") {
			return true
		}
	}
	return false
}

func readFingerprint(runtimeDir string) (fp, tokenFP string) {
	data, err := os.ReadFile(filepath.Join(runtimeDir, "fingerprint"))
	if err != nil {
		return "", ""
	}
	fields := strings.Fields(string(data))
	if len(fields) > 0 {
		fp = fields[0]
	}
	if len(fields) > 1 {
		tokenFP = fields[1]
	}
	return fp, tokenFP
}

func writeFingerprint(runtimeDir, fp, tokenFP string) {
	_ = os.WriteFile(filepath.Join(runtimeDir, "fingerprint"), []byte(fp+" "+tokenFP+"\n"), 0o600)
}

// servedModelNames lists the model ids a route table serves, deduplicated on
// the bare group (the "#openai" sibling is the same model on another wire) and
// without the wildcard, which serves anything.
func servedModelNames(configPath, flavor string) []string {
	if configPath == "" {
		return nil
	}
	table, err := loadRouteTable(configPath, dialectSuffixFor(flavor))
	if err != nil {
		return nil
	}
	seen := map[string]bool{}
	var names []string
	for _, name := range table.modelNames() {
		base := name
		if i := strings.IndexByte(base, '#'); i >= 0 {
			base = base[:i]
		}
		if base == "" || base == "*" || seen[base] {
			continue
		}
		seen[base] = true
		names = append(names, base)
	}
	return names
}

func writeServedModels(runtimeDir string, names []string) {
	if len(names) == 0 {
		return
	}
	_ = os.WriteFile(filepath.Join(runtimeDir, "models"), []byte(strings.Join(names, "\n")+"\n"), 0o600)
}

// readServedModels returns the pair the RECORDED proxy serves (written by the
// launch that started it), so a reused-busy launch can say which ids the stale
// proxy will refuse.
func readServedModels(runtimeDir string) map[string]bool {
	data, err := os.ReadFile(filepath.Join(runtimeDir, "models"))
	if err != nil {
		return nil
	}
	served := map[string]bool{}
	for _, line := range strings.Split(string(data), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			served[line] = true
		}
	}
	return served
}

// desiredServedModels is the pair THIS launch would serve. The launcher passes
// its generated config for the route-table flavors; the env-routed ones
// (claude/codex, the hosted-only ports) have only the RUNNING proxy's
// routes.json on disk, so the table is regenerated from this process's knobs —
// the same ones writeRoutesFromEnv reads at spawn time.
func desiredServedModels(flavor, port, runtimeDir, configPath string) []string {
	if configPath != "" {
		return servedModelNames(configPath, flavor)
	}
	if routeTableFlavor(flavor) {
		return nil
	}
	file, err := os.CreateTemp("", "hosted-only-desired-*.json")
	if err != nil {
		return nil
	}
	path := file.Name()
	_ = file.Close()
	defer os.Remove(path)
	if err := writeRoutesFromEnv(loadConfig(flavor, port, runtimeDir), path); err != nil {
		return nil
	}
	return servedModelNames(path, flavor)
}

// missingServedModels is the rollout gap the fingerprint cannot express: a
// proxy left running under live sessions keeps serving the model pair it was
// started with, so requests naming a NEW pair member are refused by the cost
// guard until the restart the reuse path asks for.
func missingServedModels(runtimeDir, flavor, port, configPath string) []string {
	served := readServedModels(runtimeDir)
	if len(served) == 0 {
		return nil
	}
	var missing []string
	for _, name := range desiredServedModels(flavor, port, runtimeDir, configPath) {
		if !served[name] {
			missing = append(missing, name)
		}
	}
	return missing
}

// --- detached spawn ----------------------------------------------------------

// spawnDetached starts argv in its own session with output appended to logPath,
// rotating the log past 8 MB (one generation kept) — the same contract as
// claude-provider.py --background.
func spawnDetached(logPath string, argv []string) (*exec.Cmd, error) {
	if st, err := os.Stat(logPath); err == nil && st.Size() > logRotateBytes {
		_ = os.Rename(logPath, logPath+".1")
	}
	log, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	defer log.Close()
	devnull, err := os.OpenFile(os.DevNull, os.O_RDONLY, 0)
	if err != nil {
		return nil, err
	}
	defer devnull.Close()
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdin = devnull
	cmd.Stdout = log
	cmd.Stderr = log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return cmd, nil
}

// reusePortListener binds with SO_REUSEPORT so a zero-refuse restart can
// start the replacement alongside the old listener and retire the old pids
// only once the new one answers — the same property the LiteLLM path gets
// from the runtime sitecustomize (#612).
func reusePortListener(addr string) (net.Listener, error) {
	listenConfig := net.ListenConfig{Control: func(network, address string, raw syscall.RawConn) error {
		var sockErr error
		if err := raw.Control(func(fd uintptr) {
			sockErr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, soReusePort, 1)
		}); err != nil {
			return err
		}
		return sockErr
	}}
	return listenConfig.Listen(context.Background(), "tcp", addr)
}

// lockRuntime takes the runtime dir's startup.lock with an fcntl record
// lock, which is what zsh's zsystem flock uses here — flock(2) and fcntl
// locks never exclude each other on Linux, so a Go ensure and the LiteLLM
// launcher would race if this used Flock.
func lockRuntime(dir string) (func(), error) {
	f, err := os.OpenFile(filepath.Join(dir, "startup.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(ensureLockTimeout)
	for {
		lock := syscall.Flock_t{Type: syscall.F_WRLCK, Whence: 0, Start: 0, Len: 0}
		err = syscall.FcntlFlock(uintptr(f.Fd()), syscall.F_SETLK, &lock)
		if err == nil {
			return func() {
				unlock := syscall.Flock_t{Type: syscall.F_UNLCK, Whence: 0, Start: 0, Len: 0}
				_ = syscall.FcntlFlock(uintptr(f.Fd()), syscall.F_SETLK, &unlock)
				_ = f.Close()
			}, nil
		}
		if !errors.Is(err, syscall.EAGAIN) && !errors.Is(err, syscall.EACCES) {
			_ = f.Close()
			return nil, err
		}
		if time.Now().After(deadline) {
			_ = f.Close()
			return nil, errors.New("timed out waiting for another proxy start")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// --- routes from env ---------------------------------------------------------

// writeRoutesFromEnv regenerates the hosted-only route table from the same
// knobs the launcher folds into the fingerprint (single source: the binary),
// so a watcher-driven restart never serves a routes.json older than the
// fingerprint it records.
func writeRoutesFromEnv(cfg *config, path string) error {
	type params struct {
		Model   string `json:"model"`
		APIBase string `json:"api_base"`
	}
	type row struct {
		ModelName     string `json:"model_name"`
		LitellmParams params `json:"litellm_params"`
	}
	var rows []row
	add := func(name, model, base string) {
		rows = append(rows, row{ModelName: name, LitellmParams: params{Model: model, APIBase: base}})
	}
	suffix := dialectSuffixFor(cfg.Flavor)
	for _, m := range []string{cfg.GLM, cfg.DeepSeek} {
		add(m, "anthropic/"+m, cfg.BaseURL)
		if suffix != "" {
			add(m+suffix, "openai/"+m, cfg.BaseURL+"/v1")
		}
	}
	for alias := range cfg.Aliases {
		add(alias, "anthropic/"+cfg.GLM, cfg.BaseURL)
		if suffix != "" {
			add(alias+suffix, "openai/"+cfg.GLM, cfg.BaseURL+"/v1")
		}
	}
	doc := struct {
		ModelList       []row `json:"model_list"`
		GeneralSettings struct {
			MasterKey string `json:"master_key"`
		} `json:"general_settings"`
	}{ModelList: rows}
	doc.GeneralSettings.MasterKey = "os.environ/HOSTED_ONLY_PROXY_TOKEN"
	body := marshal(doc)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, body, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// --- ensure ------------------------------------------------------------------

type ensureOpts struct {
	flavor      string
	port        string
	runtimeDir  string
	configPath  string // enmaas: the launcher's generated config.json
	fingerprint string
	tokenFP     string
	bootWait    time.Duration
	legacyDirs  []string
}

// ensureOnce is the locked heart of the launcher's start path for the Go impl.
// Status is one of fresh, restarted, reused-busy; the error message is already
// on stderr for the launch path.
func ensureOnce(o ensureOpts) (string, error) {
	unlock, err := lockRuntime(o.runtimeDir)
	if err != nil {
		return "", fmt.Errorf("hosted-only: %v", err)
	}
	defer unlock()

	forced := os.Getenv("HOSTED_ONLY_FORCE_RESTART") != ""
	if healthOK(o.port, 2*time.Second) {
		recFP, recToken := readFingerprint(o.runtimeDir)
		if recFP == o.fingerprint && (recToken == "" || recToken == o.tokenFP) && !forced {
			return "fresh", nil
		}
		if portServing(o.port) && !forced {
			if recToken != "" && recToken != o.tokenFP {
				fmt.Fprintf(os.Stderr, "hosted-only: the running %s proxy on :%s uses a different proxy token and is serving requests; run %s-hosted-only-restart once they finish.\n",
					o.flavor, o.port, o.flavor)
				return "", errors.New("proxy token changed under a busy proxy")
			}
			fmt.Fprintf(os.Stderr, "hosted-only: %s proxy config, hooks or key changed, but it is serving requests; reusing it (%s-hosted-only-restart applies the change now).\n",
				o.flavor, o.flavor)
			// A pair swap is the sharp edge of that reuse: the running proxy
			// still refuses the new ids, so name them instead of leaving the
			// caller to decode a 400 from the cost guard. A proxy started
			// before the pair was recorded cannot be compared — say so, since
			// that IS the rollout case this exists for.
			if len(readServedModels(o.runtimeDir)) == 0 {
				fmt.Fprintf(os.Stderr, "hosted-only: the running %s proxy predates the pair record, so the ids it serves cannot be checked; %s-hosted-only-restart applies the current pair once it is idle.\n",
					o.flavor, o.flavor)
			} else if missing := missingServedModels(o.runtimeDir, o.flavor, o.port, o.configPath); len(missing) > 0 {
				fmt.Fprintf(os.Stderr, "hosted-only: the running proxy does not serve %s; a request naming one of those ids is refused (400) until the restart above runs.\n",
					strings.Join(missing, ", "))
			}
			return "reused-busy", nil
		}
		// Zero-refuse restart (#612): start the new proxy ALONGSIDE the old
		// one — both listeners bind SO_REUSEPORT — and retire the old pids
		// only once the new listener answers, so a request arriving
		// mid-restart is never refused. An old listener that cannot share
		// the port (it predates SO_REUSEPORT) makes the new process exit at
		// bind; that falls back to stop-then-start once, below.
		oldPids := listenPIDs(o.port)
		// Identity first: the old pids get retired by pid (never via the
		// identity-checked stop, which would match the new process too), so a
		// listener that is not this proxy's must be refused here — a foreign
		// process answering the health path is never terminated.
		live := oldPids[:0]
		for _, pid := range oldPids {
			if pidAlive(pid) { // a listener that exited since the scan is not a foreign process
				live = append(live, pid)
			}
		}
		oldPids = live
		for _, pid := range oldPids {
			if !ownsPortListener(procCmdline(pid), o.runtimeDir, o.legacyDirs, o.port) {
				fmt.Fprintf(os.Stderr, "hosted-only: port %s is held by another process (pid %d); leaving it alone.\n", o.port, pid)
				return "", errors.New("port held by a listener that is not this proxy")
			}
		}
		swapNote := ""
		if len(oldPids) > 0 {
			swapNote = " (zero-gap swap)"
		}
		fmt.Fprintf(os.Stderr, "hosted-only: %s proxy config, hooks or key changed; restarting the proxy on :%s%s.\n",
			o.flavor, o.port, swapNote)
		status, err := startProxy(o, oldPids)
		if err == nil {
			if len(oldPids) > 0 {
				retirePids(oldPids)
			}
			return status, nil
		}
		if len(oldPids) > 0 && anyPidAlive(oldPids) {
			fmt.Fprintf(os.Stderr, "hosted-only: overlap start did not take (old listener cannot share the port); stopping it first.\n")
			if code := stopOnce(o.flavor, o.port, o.runtimeDir, o.legacyDirs); code != 0 {
				return "", errors.New("stop of the stale proxy failed")
			}
			if !waitPortFree(o.port, stopWaitFree) {
				return "", fmt.Errorf("port %s is still held after 15s", o.port)
			}
			return startProxy(o, nil)
		}
		return "", err
	}
	// A listener that no longer answers its health check (hung, wedged) would
	// make the replacement's bind fail. Confirm with a few probes and retire
	// it only when it is OURS (identity-checked) and IDLE: a listener that is
	// merely slow on one probe while serving a long stream must not be cut,
	// and the zsh path never terminated a health-fail either. Foreign or busy
	// listeners are left alone and the bind fails loudly.
	if pids := listenPIDs(o.port); len(pids) > 0 {
		healthy := healthOK(o.port, 2*time.Second)
		for probe := 0; !healthy && probe < 2; probe++ {
			time.Sleep(500 * time.Millisecond)
			healthy = healthOK(o.port, 2*time.Second)
		}
		if !healthy && !portServing(o.port) {
			owned := true
			for _, pid := range pids {
				if !ownsPortListener(procCmdline(pid), o.runtimeDir, o.legacyDirs, o.port) {
					owned = false
					break
				}
			}
			if owned {
				fmt.Fprintf(os.Stderr, "hosted-only: %s proxy on :%s is not answering its health check and is idle; retiring the owned listener.\n",
					o.flavor, o.port)
				if code := stopOnce(o.flavor, o.port, o.runtimeDir, o.legacyDirs); code != 0 {
					return "", errors.New("stop of the unhealthy proxy failed")
				}
				if !waitPortFree(o.port, stopWaitFree) {
					return "", fmt.Errorf("port %s is still held after 15s", o.port)
				}
			}
		}
	}
	return startProxy(o, nil)
}

// startProxy spawns the serve mode detached, waits for it to answer and
// records the fingerprint. During a zero-refuse swap the OLD proxy also
// answers health, so a listener pid outside oldPids is the readiness signal;
// with no old pids any listener counts. The child exiting early (its bind
// refused by an old listener that cannot share the port) fails the wait
// immediately so the caller can fall back. Routes come from the knobs for the
// hosted-only flavors (written here, so a watcher restart never pairs a new
// fingerprint with an old table) and from --config for the route-table
// flavors (enmaas, mlx, openai, vertex).
func startProxy(o ensureOpts, oldPids []int) (string, error) {
	cfg := loadConfig(o.flavor, o.port, o.runtimeDir)
	if cfg.APIKey == "" {
		return "", errors.New("hosted-only-go: HOSTED_ONLY_UPSTREAM_KEY (enmaas: ENMAAS_API_KEY) is not set")
	}
	if o.flavor == "vertex" && (os.Getenv("CLOUD_ML_REGION") == "" || os.Getenv("ANTHROPIC_VERTEX_PROJECT_ID") == "") {
		return "", errors.New("hosted-only-go: CLOUD_ML_REGION and ANTHROPIC_VERTEX_PROJECT_ID are required for the vertex flavor")
	}
	routesPath := o.configPath
	if !routeTableFlavor(o.flavor) {
		routesPath = filepath.Join(o.runtimeDir, "routes.json")
		if err := writeRoutesFromEnv(cfg, routesPath); err != nil {
			return "", err
		}
	}
	if routeTableFlavor(o.flavor) && routesPath == "" {
		return "", fmt.Errorf("hosted-only-go: --config is required for the %s flavor", o.flavor)
	}
	_ = os.Remove(filepath.Join(o.runtimeDir, "fingerprint"))

	self, err := os.Executable()
	if err != nil {
		return "", err
	}
	argv := []string{self, "--flavor", o.flavor, "--config", routesPath, "--port", o.port, "--runtime-dir", o.runtimeDir}
	child, err := spawnDetached(filepath.Join(o.runtimeDir, "proxy.log"), argv)
	if err != nil {
		return "", err
	}
	deadline := time.Now().Add(o.bootWait)
	for {
		if hasListenerOutside(o.port, oldPids) && healthOK(o.port, time.Second) {
			writeFingerprint(o.runtimeDir, o.fingerprint, o.tokenFP)
			// Remember the pair this launch serves: a later reused-busy
			// launch cannot read it off a live proxy (the cost guard answers
			// 400, which looks like a client error), so it is recorded here.
			writeServedModels(o.runtimeDir, servedModelNames(routesPath, o.flavor))
			return "restarted", nil
		}
		if !pidAlive(child.Process.Pid) {
			fmt.Fprintf(os.Stderr, "hosted-only: %s proxy exited before answering on port %s; see %s\n",
				o.flavor, o.port, filepath.Join(o.runtimeDir, "proxy.log"))
			return "", fmt.Errorf("new proxy exited before listening")
		}
		if time.Now().After(deadline) {
			fmt.Fprintf(os.Stderr, "hosted-only: %s proxy not ready on port %s; see %s\n",
				o.flavor, o.port, filepath.Join(o.runtimeDir, "proxy.log"))
			return "", fmt.Errorf("proxy did not become healthy")
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// hasListenerOutside reports whether the port has a listener pid that is not
// one of oldPids (any listener when oldPids is empty).
func hasListenerOutside(port string, oldPids []int) bool {
	old := map[int]bool{}
	for _, pid := range oldPids {
		old[pid] = true
	}
	for _, pid := range listenPIDs(port) {
		if !old[pid] {
			return true
		}
	}
	return false
}

// retirePids TERMs the old swap listeners by pid and waits for them to go
// away (KILL past the budget). Never via stopOnce during a swap: both
// processes run the same config path, so the identity check would match the
// new one too.
func retirePids(pids []int) bool {
	for _, pid := range pids {
		_ = syscall.Kill(pid, syscall.SIGTERM)
	}
	deadline := time.Now().Add(stopWaitFree)
	for time.Now().Before(deadline) {
		alive := false
		for _, pid := range pids {
			if pidAlive(pid) {
				alive = true
				break
			}
		}
		if !alive {
			return true
		}
		time.Sleep(100 * time.Millisecond)
	}
	for _, pid := range pids {
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}
	return false
}

func anyPidAlive(pids []int) bool {
	for _, pid := range pids {
		if pidAlive(pid) {
			return true
		}
	}
	return false
}

func runEnsure(args []string) int {
	fs := flag.NewFlagSet("ensure", flag.ExitOnError)
	flavor := fs.String("flavor", os.Getenv("HOSTED_ONLY_FLAVOR"), "client flavor: claude, codex or enmaas")
	port := fs.String("port", "", "listen port")
	runtimeDir := fs.String("runtime-dir", "", "state directory")
	configPath := fs.String("config", "", "generated route table (required for enmaas)")
	fingerprint := fs.String("fingerprint", "", "desired config fingerprint (launcher-computed)")
	tokenFP := fs.String("token-fp", "", "desired proxy-token fingerprint")
	bootWait := fs.Duration("boot-wait", defaultBootWait, "how long to wait for the proxy to answer its health check")
	var legacyDirs []string
	fs.Func("legacy-runtime", "legacy state directory (repeatable)", func(v string) error {
		legacyDirs = append(legacyDirs, v)
		return nil
	})
	_ = fs.Parse(args)
	if *fingerprint == "" || *runtimeDir == "" {
		fmt.Fprintln(os.Stderr, "hosted-only-go ensure: --fingerprint and --runtime-dir are required")
		return 2
	}
	o := ensureOpts{flavor: *flavor, port: *port, runtimeDir: *runtimeDir, configPath: *configPath,
		fingerprint: *fingerprint, tokenFP: *tokenFP, bootWait: *bootWait, legacyDirs: legacyDirs}
	if o.port == "" {
		o.port = defaultPort(o.flavor)
	}
	if _, err := ensureOnce(o); err != nil {
		fmt.Fprintf(os.Stderr, "hosted-only-go ensure: %v\n", err)
		return 1
	}
	return 0
}

func defaultPort(flavor string) string {
	switch flavor {
	case "codex":
		return "4147"
	case "enmaas":
		return "4146"
	case "mlx":
		return "4144"
	case "openai":
		return "4145"
	case "vertex":
		return "4142"
	default:
		return "4148"
	}
}

// --- stop --------------------------------------------------------------------

// stopOnce mirrors _hosted_only_proxy_stop: stop only listeners whose command
// line names this proxy's config under the current or a legacy runtime dir.
func stopOnce(flavor, port, runtimeDir string, legacyDirs []string) int {
	fingerprints := []string{filepath.Join(runtimeDir, "fingerprint")}
	for _, dir := range legacyDirs {
		fingerprints = append(fingerprints, filepath.Join(dir, "fingerprint"))
	}
	stopped := false
	for _, pid := range listenPIDs(port) {
		cmd := procCmdline(pid)
		if !ownsPortListener(cmd, runtimeDir, legacyDirs, port) {
			fmt.Fprintf(os.Stderr, "hosted-only: port %s is held by another process (pid %d); leaving it alone.\n", port, pid)
			return 1
		}
		if syscall.Kill(pid, syscall.SIGTERM) == nil {
			stopped = true
		}
	}
	for _, f := range fingerprints {
		_ = os.Remove(f)
	}
	if stopped {
		fmt.Fprintf(os.Stderr, "hosted-only: stopped %s proxy on port %s.\n", flavor, port)
	}
	return 0
}

func runStop(args []string) int {
	fs := flag.NewFlagSet("stop", flag.ExitOnError)
	flavor := fs.String("flavor", "claude", "client flavor (labeling only)")
	port := fs.String("port", "", "listen port")
	runtimeDir := fs.String("runtime-dir", "", "state directory")
	var legacyDirs []string
	fs.Func("legacy-runtime", "legacy state directory (repeatable)", func(v string) error {
		legacyDirs = append(legacyDirs, v)
		return nil
	})
	_ = fs.Parse(args)
	if *runtimeDir == "" || *port == "" {
		fmt.Fprintln(os.Stderr, "hosted-only-go stop: --runtime-dir and --port are required")
		return 2
	}
	return stopOnce(*flavor, *port, *runtimeDir, legacyDirs)
}

// --- status ------------------------------------------------------------------

func runStatus(args []string) int {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	flavor := fs.String("flavor", "claude", "client flavor")
	port := fs.String("port", "", "listen port")
	runtimeDir := fs.String("runtime-dir", "", "state directory")
	_ = fs.Parse(args)
	if *port == "" {
		*port = defaultPort(*flavor)
	}
	recFP, recToken := "", ""
	if *runtimeDir != "" {
		recFP, recToken = readFingerprint(*runtimeDir)
	}
	pids := listenPIDs(*port)
	out := map[string]any{
		"flavor":               *flavor,
		"port":                 *port,
		"runtime_dir":          *runtimeDir,
		"running":              len(pids) > 0,
		"pids":                 pids,
		"healthy":              healthOK(*port, 2*time.Second),
		"busy":                 portServing(*port),
		"recorded_fingerprint": recFP,
		"recorded_token":       recToken,
	}
	fmt.Println(string(marshal(out)))
	return 0
}

// --- watch -------------------------------------------------------------------

// runWatch is the Go impl's llm-proxy-watch: poll the port's inflight state,
// and at the first idle moment (two consecutive idle polls) bring the proxy to
// the fingerprint this watcher was started with. Someone restarting the proxy
// meanwhile shows up as "fresh" and ends the watch without another restart.
// Log lines and the pid file keep the llm-proxy-sync state contract, so
// _llm_proxy_watch_alive and the fleet-sync logs see the same thing.
func runWatch(args []string) int {
	fs := flag.NewFlagSet("watch", flag.ExitOnError)
	flavor := fs.String("flavor", "claude", "client flavor: claude, codex or enmaas")
	port := fs.String("port", "", "listen port")
	runtimeDir := fs.String("runtime-dir", "", "state directory")
	configPath := fs.String("config", "", "generated route table (enmaas)")
	fingerprint := fs.String("fingerprint", "", "desired config fingerprint")
	tokenFP := fs.String("token-fp", "", "desired proxy-token fingerprint")
	name := fs.String("name", "", "proxy name for the watch state files (e.g. glm-claude)")
	stateDir := fs.String("state-dir", "", "llm-proxy-sync state directory")
	timeout := fs.Duration("timeout", 0, "how long to wait for an idle moment (default LLM_PROXY_WATCH_TIMEOUT or 12h)")
	var legacyDirs []string
	fs.Func("legacy-runtime", "legacy state directory (repeatable)", func(v string) error {
		legacyDirs = append(legacyDirs, v)
		return nil
	})
	_ = fs.Parse(args)
	if *fingerprint == "" || *runtimeDir == "" || *name == "" || *stateDir == "" {
		fmt.Fprintln(os.Stderr, "hosted-only-go watch: --fingerprint, --runtime-dir, --name and --state-dir are required")
		return 2
	}
	if *timeout == 0 {
		*timeout = 12 * time.Hour
		if v := os.Getenv("LLM_PROXY_WATCH_TIMEOUT"); v != "" {
			if seconds, err := strconv.Atoi(v); err == nil && seconds > 0 {
				*timeout = time.Duration(seconds) * time.Second
			}
		}
	}
	if *port == "" {
		*port = defaultPort(*flavor)
	}
	logf := func(format string, args ...any) {
		line := time.Now().Format("2006-01-02T15:04:05-0700") + " " + *name + ": " + fmt.Sprintf(format, args...)
		fmt.Fprintln(os.Stderr, line)
		_ = os.MkdirAll(*stateDir, 0o700)
		if f, err := os.OpenFile(filepath.Join(*stateDir, "watch-"+*name+".log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
			_, _ = f.WriteString(line + "\n")
			_ = f.Close()
		}
	}

	if err := os.MkdirAll(*stateDir, 0o700); err != nil {
		fmt.Fprintf(os.Stderr, "hosted-only-go watch: state dir %s: %v\n", *stateDir, err)
		return 1
	}
	pidfile := filepath.Join(*stateDir, "watch-"+*name+".pid")
	if pid, err := strconv.Atoi(strings.TrimSpace(readFileOr(pidfile, ""))); err == nil && pid != os.Getpid() && pidAlive(pid) {
		if cmd := procCmdline(pid); strings.Contains(cmd, "llm-proxy-watch") || strings.Contains(cmd, "hosted-only-proxy watch") {
			logf("another watcher is already waiting; this one exits")
			return 0
		}
	}
	if err := os.WriteFile(pidfile, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "hosted-only-go watch: pid file %s: %v\n", pidfile, err)
		return 1
	}
	defer func() {
		if pid, err := strconv.Atoi(strings.TrimSpace(readFileOr(pidfile, ""))); err == nil && pid == os.Getpid() {
			_ = os.Remove(pidfile)
		}
	}()

	o := ensureOpts{flavor: *flavor, port: *port, runtimeDir: *runtimeDir, configPath: *configPath,
		fingerprint: *fingerprint, tokenFP: *tokenFP, bootWait: defaultBootWait, legacyDirs: legacyDirs}
	logf("serving a request; waiting for an idle moment (gives up after %s)", *timeout)
	deadline := time.Now().Add(*timeout)
	rc := 0
	idle := 0
	for iter := 0; ; iter++ {
		// The listener check costs a process spawn like the serving check, so
		// it runs every 10th poll only (the serving check below reports a busy
		// proxy the rest of the time), mirroring the zsh watcher.
		if iter%10 == 0 && len(listenPIDs(*port)) == 0 {
			logf("proxy is not running any more; nothing to do")
			break
		}
		if !time.Now().Before(deadline) {
			logf("still busy at the deadline; giving up (the next fleet-sync starts a new watcher)")
			notifyUser("Proxy update deferred",
				fmt.Sprintf("%s (:%s) stayed busy for the whole watch window; the next fleet-sync retries", *name, *port))
			rc = 1
			break
		}
		if portServing(*port) {
			idle = 0
		} else {
			idle++
		}
		if idle >= watchIdlePolls {
			status, err := ensureOnce(o)
			switch {
			case err != nil:
				logf("restart did not bring it back; run: %s-hosted-only-restart", *flavor)
				notifyUser("Proxy restart FAILED",
					fmt.Sprintf("%s (:%s) — run %s-hosted-only-restart", *name, *port, *flavor))
				rc = 1
			case status == "fresh":
				logf("already restarted with the current code; nothing to do")
			case status == "reused-busy":
				// A request arrived between the idle polls; keep waiting.
				idle = 0
				time.Sleep(watchPoll)
				continue
			default:
				logf("restarted with the current code")
				notifyUser("Proxy updated",
					fmt.Sprintf("%s (:%s) restarted at the first idle moment with the pulled code", *name, *port))
			}
			break
		}
		time.Sleep(watchPoll)
	}
	return rc
}

// notifyUser tells the human the deferred restart finally happened (or did
// not), without the terminal: a desktop notification, best effort.
// LLM_PROXY_NOTIFY_LOG=<file> appends instead of notifying (tests, headless).
func notifyUser(title, message string) {
	if log := strings.TrimSpace(os.Getenv("LLM_PROXY_NOTIFY_LOG")); log != "" {
		if f, err := os.OpenFile(log, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
			_, _ = f.WriteString(title + ": " + message + "\n")
			_ = f.Close()
		}
		return
	}
	clean := func(s string) string {
		return strings.NewReplacer("\"", "'", "\n", " ").Replace(s)
	}
	if runtime.GOOS == "darwin" {
		script := fmt.Sprintf("display notification %q with title %q", clean(message), clean(title))
		_ = exec.Command("osascript", "-e", script).Run()
		return
	}
	_ = exec.Command("notify-send", "--app-name=llm-proxy-sync", title, message).Run()
}

func readFileOr(path, fallback string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return fallback
	}
	return string(data)
}
