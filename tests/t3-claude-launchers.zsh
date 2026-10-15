#!/bin/zsh
# Offline tests for link-claude-t3-launchers, verify-claude-t3-launchers, and
# the provider binaryPath check in verify-t3-migration. Uses temp dirs and a
# stub Claude binary; never touches ~/.local/bin or ~/.t3.
emulate -LR zsh
setopt err_exit pipe_fail
local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export T3_CLAUDE_LAUNCHER_DIR="$tmp/bin" T3CODE_HOME="$tmp/t3"
export CLAUDE_PROVIDER_NATIVE_BINARY="$tmp/claude" CLAUDE_PROVIDER_CREDENTIALS_FILE="$tmp/secrets.zsh"
print -r -- $'#!/bin/sh\necho "9.9.9 (Claude Code)"' > "$tmp/claude"
chmod +x "$tmp/claude"
: > "$tmp/secrets.zsh"
source "$repo/zsh/functions/migrate-laptop.zsh"

fail() { print -ru2 -- "FAIL: $*"; exit 1; }
local target="$repo/scripts/claude-provider.zsh" out b l
(( ${#_T3_CLAUDE_BACKENDS} == 6 )) || fail "expected six backends, got $_T3_CLAUDE_BACKENDS"
[[ "$_T3_DOTFILES_ROOT" == "${repo:A}" ]] || fail "dotfiles root resolved to $_T3_DOTFILES_ROOT"

# A fresh directory gets every link, each resolving to this checkout
link-claude-t3-launchers >/dev/null 2>&1 || fail "first link run failed"
for b in $_T3_CLAUDE_BACKENDS; do
    l="$tmp/bin/claude-t3-$b"
    [[ -L "$l" && "${l:A}" == "${target:A}" ]] || fail "claude-t3-$b not linked to $target"
done

# Re-running changes nothing
out=$(link-claude-t3-launchers 2>&1) || fail "second link run failed"
[[ "$out" == *"claude-t3-enmaas already linked"* ]] || fail "second run did not report existing links: $out"

# A stale or dangling symlink is repointed
ln -sfn "$tmp/nowhere" "$tmp/bin/claude-t3-vertex"
link-claude-t3-launchers >/dev/null 2>&1 || fail "repoint run failed"
l="$tmp/bin/claude-t3-vertex"
[[ "${l:A}" == "${target:A}" ]] || fail "stale claude-t3-vertex not repointed"

# A regular file is left untouched and reported as a failure
rm "$tmp/bin/claude-t3-openai"
print -r -- keep > "$tmp/bin/claude-t3-openai"
if link-claude-t3-launchers >/dev/null 2>&1; then fail "regular file at a launcher path did not fail"; fi
[[ ! -L "$tmp/bin/claude-t3-openai" && "$(<"$tmp/bin/claude-t3-openai")" == keep ]] \
    || fail "regular file at claude-t3-openai was modified"
rm "$tmp/bin/claude-t3-openai"
link-claude-t3-launchers >/dev/null 2>&1 || fail "relink after removing the regular file failed"

# Verification runs each launcher's --version through the stub
verify-claude-t3-launchers >/dev/null 2>&1 || fail "verify failed with every launcher linked"
"$tmp/bin/claude-t3-enmaas" --version | grep -q '9.9.9' || fail "launcher did not exec the native binary"

# Codex launchers: same contract, codex-t3-<backend> -> codex-provider.zsh
export CODEX_PROVIDER_NATIVE_BINARY="$tmp/codex"
print -r -- $'#!/bin/sh\necho "codex-cli 9.9.9"' > "$tmp/codex"
chmod +x "$tmp/codex"
(( ${#_T3_CODEX_BACKENDS} == 3 )) || fail "expected three codex backends, got $_T3_CODEX_BACKENDS"
local codex_target="$repo/scripts/codex-provider.zsh"
link-codex-t3-launchers >/dev/null 2>&1 || fail "codex link run failed"
for b in $_T3_CODEX_BACKENDS; do
    l="$tmp/bin/codex-t3-$b"
    [[ -L "$l" && "${l:A}" == "${codex_target:A}" ]] || fail "codex-t3-$b not linked to $codex_target"
    "$l" --version | grep -q 'codex-cli 9.9.9' || fail "codex-t3-$b did not exec the native binary"
done
verify-codex-t3-launchers >/dev/null 2>&1 || fail "codex verify failed with every launcher linked"

chmod -x "$tmp/codex"
if verify-codex-t3-launchers >/dev/null 2>&1; then fail "codex verify passed without a runnable Codex CLI"; fi
chmod +x "$tmp/codex"

chmod -x "$tmp/claude"
if verify-claude-t3-launchers >/dev/null 2>&1; then fail "verify passed without a runnable Claude Code"; fi
chmod +x "$tmp/claude"

rm "$tmp/bin/claude-t3-copilot"
if verify-claude-t3-launchers >/dev/null 2>&1; then fail "verify passed with a missing launcher"; fi
link-claude-t3-launchers >/dev/null 2>&1 || fail "relink failed"

# Absolute binaryPaths in T3 settings must exist; bare names and disabled
# instances are skipped
mkdir -p "$tmp/t3/userdata"
cat > "$tmp/t3/userdata/settings.json" <<EOF
{"providerInstances": {
  "claude_enmaas": {"enabled": true, "config": {"binaryPath": "$tmp/bin/claude-t3-enmaas"}},
  "claude_twin":   {"config": {"binaryPath": "$tmp/bin/claude-t3-enmaas"}},
  "codex":         {"config": {"binaryPath": "codex"}},
  "codex_enmaas":  {"enabled": true, "config": {"binaryPath": "$tmp/bin/codex-t3-enmaas"}},
  "disabled":      {"enabled": false, "config": {"binaryPath": "$tmp/never-installed"}},
  "no_config":     {}
}}
EOF
_t3_check_provider_binaries >/dev/null 2>&1 || fail "provider check failed with every enabled binary present"

cat > "$tmp/t3/userdata/settings.json" <<EOF
{"providerInstances": {
  "claude_old_home": {"config": {"binaryPath": "/Users/someone-else/.local/bin/claude-t3-enmaas"}},
  "codex_old_home":  {"config": {"binaryPath": "/Users/someone-else/.local/bin/codex-t3-enmaas"}},
  "native":          {"config": {"binaryPath": "$tmp/missing-claude"}}
}}
EOF
if out=$(_t3_check_provider_binaries 2>&1); then fail "provider check passed with missing binaries"; fi
[[ "$out" == *"claude-t3-enmaas missing (run link-claude-t3-launchers"* ]] || fail "launcher hint missing: $out"
[[ "$out" == *"codex-t3-enmaas missing (run link-codex-t3-launchers"* ]] || fail "codex launcher hint missing: $out"
[[ "$out" == *"missing-claude missing (install it"* ]] || fail "generic hint missing: $out"
[[ "$out" == *"✗"* ]] || fail "default reporter is not error: $out"

# verify-t3-migration passes "warning": still nonzero, but reported as a warning
if out=$(_t3_check_provider_binaries warning 2>&1); then fail "warning mode returned 0 with missing binaries"; fi
[[ "$out" == *"⚠"* && "$out" != *"✗"* ]] || fail "warning mode did not report as warnings: $out"

rm "$tmp/t3/userdata/settings.json"
_t3_check_provider_binaries >/dev/null 2>&1 || fail "provider check failed without a settings file"

print -r -- "ok t3-claude-launchers"
