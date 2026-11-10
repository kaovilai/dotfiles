#!/bin/zsh -f
# Symlink as `claude` inside a directory that PATH resolves BEFORE the Claude
# Code installer's ~/.local/bin/claude symlink (link-claude-dispatch links it
# into ~/.local/bin/claude-dispatch/ and zsh/paths.zsh prepends that dir).
#
# Makes PATH-spawned `claude` invocations — `npx t3 triage` (TRIAGE_AGENTS
# looks up "claude" on PATH, not T3 provider instances), editors, scripts —
# follow `claude-mode` (persisted in ${XDG_CONFIG_HOME:-~/.config}/claude-mode)
# instead of inheriting whatever transport vars the parent shell happens to
# export (~/secrets.zsh exports the Vertex ones, which is how triage used to
# come up as vertex-native-adc while claude-mode said hosted-only).
#
# Resolution order:
#   1. CLAUDE_PROVIDER_DISPATCHED set  — a claude-<backend> wrapper already
#      prepared this invocation (interactive `claude` function chain); run the
#      native binary with the wrapper's env, no re-dispatch. The marker is set
#      by _claude_invoke in zsh/functions/claude/common.zsh.
#   2. --version/-v/--help/-h (single arg) and admin subcommands (mcp, plugin,
#      config, doctor, update, install, migrate-installer) — local-only, no
#      provider needed; exec the native binary directly so fleet-sync and
#      daemon-sync machinery never depends on credentials or proxies.
#   3. Otherwise read the mode file and exec the matching claude-t3-<backend>
#      launcher, which runs the full bridge (credential bootstrap + wrapper +
#      env scrub). Unknown/missing mode fails safe to vertex, same as the
#      `claude` shell function's default case. openshell-* modes wrap an
#      interactive OpenShell session and cannot run headless: warn and run the
#      native binary without one.
#
# The native binary is CLAUDE_PROVIDER_NATIVE_BINARY (default
# ~/.local/bin/claude, the installer-managed symlink this shim shadows in PATH
# but never replaces on disk, so Claude Code self-updates keep working).
emulate -L zsh
unsetopt xtrace verbose
typeset self="${0:A}" native="${CLAUDE_PROVIDER_NATIVE_BINARY:-$HOME/.local/bin/claude}"
[[ -x "$native" && "${native:A}" != "$self" ]] || {
    print -ru2 -- "claude-dispatch: native Claude executable missing or misresolved: $native"
    exit 1
}
# 1) Wrapper-prepared invocation: run native with the wrapper's env.
[[ -n "${CLAUDE_PROVIDER_DISPATCHED:-}" ]] && exec "$native" "$@"
# 2) Version probes and admin subcommands never need a provider.
if (( $# == 1 )) && [[ "$1" == --version || "$1" == -v || "$1" == --help || "$1" == -h ]]; then
    exec "$native" "$@"
fi
case "${1-}" in
    (mcp|plugin|plugins|config|doctor|update|install|migrate-installer) exec "$native" "$@" ;;
esac
# 3) Follow claude-mode.
typeset mode=""
typeset mode_file="${XDG_CONFIG_HOME:-$HOME/.config}/claude-mode"
[[ -r "$mode_file" ]] && IFS= read -r mode < "$mode_file"
case "$mode" in
    (copilot|enmaas|enmass|hosted-only|vertex|vertex-native-adc|ollama)
        [[ "$mode" == enmass ]] && mode=enmaas   # pre-rename persisted value
        exec "${T3_CLAUDE_LAUNCHER_DIR:-$HOME/.local/bin}/claude-t3-$mode" "$@" ;;
    (openshell-*)
        print -ru2 -- "claude-dispatch: mode '$mode' wraps an interactive OpenShell session; running claude without one."
        exec "$native" "$@" ;;
    # Missing/unknown (incl. pre-rename "vertex-proxy") fails safe to vertex,
    # matching _claude_mode_get and the `claude` function's default case.
    (*) exec "${T3_CLAUDE_LAUNCHER_DIR:-$HOME/.local/bin}/claude-t3-vertex" "$@" ;;
esac
