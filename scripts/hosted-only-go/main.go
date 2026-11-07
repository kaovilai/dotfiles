// Command hosted-only-proxy is a stdlib-only replacement for the LiteLLM
// proxies behind `claude-hosted-only` and `codex-hosted-only`. It speaks the
// same three upstream dialects, applies the same request and limit rewrites as
// scripts/hosted_only_hooks.py, and writes the same llm-usage JSONL.
//
// It is opt-in: set HOSTED_ONLY_PROXY_IMPL=go. Everything else (knobs, state
// dir, stop/restart commands, fingerprint) behaves like the LiteLLM path.
//
// Subcommands (used by the launcher's Go path): `ensure` starts or restarts
// the proxy to a launcher-computed fingerprint, `stop` retires a listener by
// identity, `status` reports health/busy/fingerprint, and `watch` restarts at
// the first idle moment (the Go impl's llm-proxy-watch). With no subcommand
// the binary serves, as before.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// shutdownDrain bounds how long a SIGTERMed proxy keeps serving in-flight
// requests; the swap's retire step waits stopWaitFree (15 s) before KILL.
const shutdownDrain = 10 * time.Second

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "ensure":
			os.Exit(runEnsure(os.Args[2:]))
		case "stop":
			os.Exit(runStop(os.Args[2:]))
		case "status":
			os.Exit(runStatus(os.Args[2:]))
		case "watch":
			os.Exit(runWatch(os.Args[2:]))
		case "serve":
			rest := append([]string{os.Args[0]}, os.Args[2:]...)
			os.Args = rest
		}
	}
	runServe()
}

func runServe() {
	flavor := flag.String("flavor", os.Getenv("HOSTED_ONLY_FLAVOR"), "client flavor: claude, codex or enmaas")
	port := flag.String("port", "", "listen port (default 4147 codex / 4148 claude / 4146 enmaas)")
	runtimeDir := flag.String("runtime-dir", "", "state directory (named in the process command line so the stop helper can find it)")
	configPath := flag.String("config", os.Getenv("HOSTED_ONLY_CONFIG"), "generated LiteLLM config.json (required for enmaas)")
	flag.Parse()

	if !routeTableFlavor(*flavor) && *flavor != "claude" && *flavor != "codex" {
		fmt.Fprintln(os.Stderr, "hosted-only-go: --flavor must be claude, codex, enmaas, mlx, openai or vertex")
		os.Exit(2)
	}
	if *port == "" {
		*port = defaultPort(*flavor)
	}

	cfg := loadConfig(*flavor, *port, *runtimeDir)
	if *configPath != "" {
		routes, err := loadRouteTable(*configPath, dialectSuffixFor(*flavor))
		if err != nil {
			fmt.Fprintf(os.Stderr, "hosted-only-go: %s: %v\n", *configPath, err)
			os.Exit(1)
		}
		cfg.Routes = routes
		// The hosted config's master_key is the literal os.environ/... token
		// reference; only take a real token from the file.
		if routes.token != "" && !strings.HasPrefix(routes.token, "os.environ/") {
			cfg.Token = routes.token
		}
	}
	if routeTableFlavor(*flavor) && cfg.Routes == nil {
		fmt.Fprintf(os.Stderr, "hosted-only-go: --config is required for the %s flavor\n", *flavor)
		os.Exit(1)
	}
	if cfg.APIKey == "" {
		fmt.Fprintln(os.Stderr, "hosted-only-go: HOSTED_ONLY_UPSTREAM_KEY (enmaas: ENMAAS_API_KEY) is not set")
		os.Exit(1)
	}
	if *flavor == "vertex" && (os.Getenv("CLOUD_ML_REGION") == "" || os.Getenv("ANTHROPIC_VERTEX_PROJECT_ID") == "") {
		fmt.Fprintln(os.Stderr, "hosted-only-go: CLOUD_ML_REGION and ANTHROPIC_VERTEX_PROJECT_ID are required for the vertex flavor")
		os.Exit(1)
	}

	startCacheSweeper(cfg)
	server := &http.Server{
		Handler:           newApp(cfg),
		ReadHeaderTimeout: 10 * time.Second,
	}
	listener, err := reusePortListener("127.0.0.1:" + cfg.Port)
	if err != nil {
		log.Fatalf("hosted-only-go: %v", err)
	}

	drained := make(chan struct{})
	go func() {
		signals := make(chan os.Signal, 1)
		signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
		<-signals
		// Stop accepting (the kernel routes new connections to a sibling
		// SO_REUSEPORT listener during a swap) and let in-flight requests and
		// streams finish; anything still open past the budget is cut. Close
		// alone dropped active streams mid-answer.
		ctx, cancel := context.WithTimeout(context.Background(), shutdownDrain)
		defer cancel()
		if server.Shutdown(ctx) != nil {
			_ = server.Close()
		}
		close(drained)
	}()

	log.Printf("hosted-only-go: %s flavor, 127.0.0.1:%s -> %s, upstream retries off, limit rewrite=%t, fallback=%t",
		cfg.Flavor, cfg.Port, cfg.BaseURL, cfg.LimitRewrite, cfg.FallbackOn)
	if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
		log.Fatalf("hosted-only-go: %v", err)
	}
	// Serve returns as soon as Shutdown begins; the process must stay until
	// the in-flight requests have drained (or the budget ran out).
	<-drained
}
