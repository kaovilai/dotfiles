// Command hosted-only-proxy is a stdlib-only replacement for the LiteLLM
// proxies behind `claude-hosted-only` and `codex-hosted-only`. It speaks the
// same three upstream dialects, applies the same request and limit rewrites as
// scripts/hosted_only_hooks.py, and writes the same llm-usage JSONL.
//
// It is opt-in: set HOSTED_ONLY_PROXY_IMPL=go. Everything else (knobs, state
// dir, stop/restart commands, fingerprint) behaves like the LiteLLM path.
package main

import (
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

func main() {
	flavor := flag.String("flavor", os.Getenv("HOSTED_ONLY_FLAVOR"), "client flavor: claude, codex or enmaas")
	port := flag.String("port", "", "listen port (default 4147 codex / 4148 claude / 4146 enmaas)")
	runtimeDir := flag.String("runtime-dir", "", "state directory (named in the process command line so the stop helper can find it)")
	configPath := flag.String("config", os.Getenv("HOSTED_ONLY_CONFIG"), "generated LiteLLM config.json (required for enmaas)")
	flag.Parse()

	if *flavor != "claude" && *flavor != "codex" && *flavor != "enmaas" {
		fmt.Fprintln(os.Stderr, "hosted-only-go: --flavor must be claude, codex or enmaas")
		os.Exit(2)
	}
	if *port == "" {
		switch *flavor {
		case "codex":
			*port = "4147"
		case "claude":
			*port = "4148"
		default:
			*port = "4146"
		}
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
	if *flavor == "enmaas" && cfg.Routes == nil {
		fmt.Fprintln(os.Stderr, "hosted-only-go: --config is required for the enmaas flavor")
		os.Exit(1)
	}
	if cfg.APIKey == "" {
		fmt.Fprintln(os.Stderr, "hosted-only-go: ENMAAS_API_KEY is not set")
		os.Exit(1)
	}

	server := &http.Server{
		Addr:              "127.0.0.1:" + cfg.Port,
		Handler:           newApp(cfg),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		signals := make(chan os.Signal, 1)
		signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
		<-signals
		_ = server.Close()
	}()

	log.Printf("hosted-only-go: %s flavor, 127.0.0.1:%s -> %s, upstream retries off, limit rewrite=%t, fallback=%t",
		cfg.Flavor, cfg.Port, cfg.BaseURL, cfg.LimitRewrite, cfg.FallbackOn)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("hosted-only-go: %v", err)
	}
}
