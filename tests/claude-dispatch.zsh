#!/bin/zsh
# Offline tests for scripts/claude-dispatch.zsh: a throwaway HOME with a stub
# native claude and stub claude-t3-<backend> launchers. Never touches
# ~/.local/bin or the real mode file.
emulate -LR zsh
setopt err_exit pipe_fail
local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { print -ru2 -- "FAIL: $*"; exit 1; }

# Stub native claude: prints its name plus args so tests can see who ran.
print -r -- $'#!/bin/sh\necho "native $@"' > "$tmp/claude"
chmod +x "$tmp/claude"
mkdir -p "$tmp/bin" "$tmp/home/.config"
for b in copilot vertex openai enmaas hosted-only mlx vertex-native-adc ollama; do
    print -r -- "#!/bin/sh
echo \"launcher-$b \$*\"" > "$tmp/bin/claude-t3-$b"
    chmod +x "$tmp/bin/claude-t3-$b"
done
export CLAUDE_PROVIDER_NATIVE_BINARY="$tmp/claude"
export T3_CLAUDE_LAUNCHER_DIR="$tmp/bin"
export HOME="$tmp/home"
# Pin the mode file location: an inherited XDG_CONFIG_HOME would point the
# shim at the real ~/.config/claude-mode.
export XDG_CONFIG_HOME="$HOME/.config"
shim="$repo/scripts/claude-dispatch.zsh"

# Marker set: wrapper-prepared invocation runs native, never a launcher.
[[ "$(CLAUDE_PROVIDER_DISPATCHED=1 "$shim" -p hi)" == "native -p hi" ]] \
    || fail "marker did not pass through to native"

# Version probes run native (fast path).
[[ "$("$shim" --version)" == "native --version" ]] || fail "--version not passed to native"
[[ "$("$shim" -v)" == "native -v" ]] || fail "-v not passed to native"

# Admin subcommands run native without a provider.
[[ "$("$shim" mcp list)" == "native mcp list" ]] || fail "mcp not passed to native"
[[ "$("$shim" plugin install x)" == "native plugin install x" ]] || fail "plugin not passed to native"

# Each dispatchable mode execs its launcher with args intact.
for m in copilot enmaas hosted-only vertex vertex-native-adc ollama; do
    print -r -- "$m" > "$HOME/.config/claude-mode"
    [[ "$("$shim" -p hi --model m)" == "launcher-$m -p hi --model m" ]] \
        || fail "mode $m did not dispatch to its launcher"
done

# Pre-rename persisted value still resolves.
print -r -- enmass > "$HOME/.config/claude-mode"
[[ "$("$shim" x)" == "launcher-enmaas x" ]] || fail "enmass mode not normalized to enmaas"

# Missing/unknown mode fails safe to vertex, like the claude function default.
print -r -- bogus > "$HOME/.config/claude-mode"
[[ "$("$shim" x)" == "launcher-vertex x" ]] || fail "unknown mode not defaulted to vertex"
rm "$HOME/.config/claude-mode"
[[ "$("$shim" x)" == "launcher-vertex x" ]] || fail "missing mode file not defaulted to vertex"

# openshell modes cannot run headless: warn on stderr, run native.
print -r -- openshell-copilot > "$HOME/.config/claude-mode"
out=$("$shim" -p hi 2>/dev/null)
[[ "$out" == "native -p hi" ]] || fail "openshell mode did not fall back to native"
"$shim" -p hi 2>&1 >/dev/null | grep -q "interactive OpenShell" || fail "openshell fallback has no warning"

# A missing native binary is an error, not a silent launcher dispatch.
rm "$tmp/claude"
if "$shim" --version >/dev/null 2>&1; then fail "missing native did not fail"; fi

print -r -- "ok claude-dispatch"
