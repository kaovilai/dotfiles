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
(( ${#_T3_CLAUDE_BACKENDS} == 4 )) || fail "expected four backends, got $_T3_CLAUDE_BACKENDS"
[[ "$_T3_DOTFILES_ROOT" == "${repo:A}" ]] || fail "dotfiles root resolved to $_T3_DOTFILES_ROOT"

# A fresh directory gets every link, each resolving to this checkout
link-claude-t3-launchers >/dev/null 2>&1 || fail "first link run failed"
for b in $_T3_CLAUDE_BACKENDS; do
    l="$tmp/bin/claude-t3-$b"
    [[ -L "$l" && "${l:A}" == "${target:A}" ]] || fail "claude-t3-$b not linked to $target"
done

# Re-running changes nothing
out=$(link-claude-t3-launchers 2>&1) || fail "second link run failed"
[[ "$out" == *"claude-t3-enmass already linked"* ]] || fail "second run did not report existing links: $out"

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
"$tmp/bin/claude-t3-enmass" --version | grep -q '9.9.9' || fail "launcher did not exec the native binary"

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
  "claude_enmass": {"enabled": true, "config": {"binaryPath": "$tmp/bin/claude-t3-enmass"}},
  "claude_twin":   {"config": {"binaryPath": "$tmp/bin/claude-t3-enmass"}},
  "codex":         {"config": {"binaryPath": "codex"}},
  "disabled":      {"enabled": false, "config": {"binaryPath": "$tmp/never-installed"}},
  "no_config":     {}
}}
EOF
_t3_check_provider_binaries >/dev/null 2>&1 || fail "provider check failed with every enabled binary present"

cat > "$tmp/t3/userdata/settings.json" <<EOF
{"providerInstances": {
  "claude_old_home": {"config": {"binaryPath": "/Users/someone-else/.local/bin/claude-t3-enmass"}},
  "native":          {"config": {"binaryPath": "$tmp/missing-claude"}}
}}
EOF
if out=$(_t3_check_provider_binaries 2>&1); then fail "provider check passed with missing binaries"; fi
[[ "$out" == *"claude-t3-enmass missing (run link-claude-t3-launchers"* ]] || fail "launcher hint missing: $out"
[[ "$out" == *"missing-claude missing (install it"* ]] || fail "generic hint missing: $out"
[[ "$out" == *"✗"* ]] || fail "default reporter is not error: $out"

# verify-t3-migration passes "warning": still nonzero, but reported as a warning
if out=$(_t3_check_provider_binaries warning 2>&1); then fail "warning mode returned 0 with missing binaries"; fi
[[ "$out" == *"⚠"* && "$out" != *"✗"* ]] || fail "warning mode did not report as warnings: $out"

rm "$tmp/t3/userdata/settings.json"
_t3_check_provider_binaries >/dev/null 2>&1 || fail "provider check failed without a settings file"

print -r -- "ok t3-claude-launchers"
