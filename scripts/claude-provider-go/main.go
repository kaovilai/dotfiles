// Command claude-provider is the Go port of scripts/claude-provider.py's
// launch path: prepare the existing ZSH providers, then supervise only the
// invocation's Claude. The Python file stays as the transient --background
// spawner for the LiteLLM proxy path and as a manual fallback; this binary is
// what every T3 thread runs resident — a few MB instead of a Python
// interpreter (12–14 MB observed) per live thread.
//
// Mode dispatch matches the Python bridge exactly:
//
//	claude-provider --catalog-read <identity>     cached model catalog (rc 3 = miss)
//	claude-provider --catalog-write <identity>    cache stdin JSON
//	claude-provider --capture <profile.json>      NUL-separated args on stdin
//	claude-provider --background <log> <cmd...>   detached spawn with rotation
//	claude-provider <backend> <native> <args...>  prepare + supervise
//
// The repo root comes from CLAUDE_PROVIDER_ROOT (claude-provider.zsh sets it);
// the settings env is exported into the child so knobs read at claude startup
// always win, same contract as the Python bridge.
package main

import (
	"fmt"
	"os"
)

// bridgeSupervisor is the run flow's child tracker; main consults it before
// exiting so a cancellation in flight (which owns the exit code) is never
// cut short by the main flow's own return.
var bridgeSupervisor = &supervisor{}

func main() {
	code := runMain(os.Args[1:])
	if cancel := bridgeSupervisor.cancelResult(); cancel != 0 {
		code = cancel
	}
	os.Exit(code)
}

func runMain(args []string) int {
	if len(args) == 2 && (args[0] == "--catalog-read" || args[0] == "--catalog-write") {
		return catalogMode(args[0], args[1])
	}
	if len(args) == 2 && args[0] == "--capture" {
		return captureMode(args[1])
	}
	if len(args) >= 3 && args[0] == "--background" {
		return backgroundMode(args[1], args[2:])
	}
	if len(args) >= 2 {
		backend := args[0]
		switch backend {
		case "glm-hybrid", "glm-only", "hybrid": // retired names of hosted-only
			backend = "hosted-only"
		}
		switch backend {
		case "copilot", "vertex", "openai", "enmaas", "hosted-only", "mlx", "vertex-native-adc", "ollama":
			return run(backend, args[1], args[2:])
		}
	}
	fmt.Fprintln(os.Stderr, "Usage: claude-provider <copilot|vertex|openai|enmaas|hosted-only|mlx|vertex-native-adc|ollama> <native> [Claude arguments]")
	return 2
}

// failGeneric mirrors the Python bridge: parsing exceptions can contain
// credentials, so every failure reports the same message with no raw values.
func failGeneric() {
	fmt.Fprintln(os.Stderr, "claude-provider: preparation/settings failed; check the credential source and settings format.")
}
