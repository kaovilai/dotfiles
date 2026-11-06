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
	"syscall"
	"time"
)

func main() {
	flavor := flag.String("flavor", os.Getenv("HOSTED_ONLY_FLAVOR"), "client flavor: claude or codex")
	port := flag.String("port", "", "listen port (default 4147 codex / 4148 claude)")
	runtimeDir := flag.String("runtime-dir", "", "state directory (named in the process command line so the stop helper can find it)")
	flag.Parse()

	if *flavor != "claude" && *flavor != "codex" {
		fmt.Fprintln(os.Stderr, "hosted-only-go: --flavor must be claude or codex")
		os.Exit(2)
	}
	if *port == "" {
		if *flavor == "codex" {
			*port = "4147"
		} else {
			*port = "4148"
		}
	}

	cfg := loadConfig(*flavor, *port, *runtimeDir)
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
