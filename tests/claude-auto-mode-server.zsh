#!/usr/bin/env zsh
# Every Claude provider that overrides the endpoint must run with
# CLAUDE_CODE_AUTO_MODE_SERVER=0 (auto-mode review stays client-side; a gateway
# cannot serve the server-side classifier). The guard lives in one place
# (_claude_endpoint_guard in zsh/functions/claude/common.zsh) and runs from
# every final invocation: _claude_invoke, the T3 capture bridge and the
# openshell invoke. This test checks the behavior and that no provider
# launches claude around it.
emulate -L zsh
setopt err_return pipe_fail
root=${0:A:h:h}
fail() { print -u2 -- "FAIL: $*"; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# Stub claude: print the value it was launched with.
mkdir -p $tmp/bin
cat > $tmp/bin/claude <<'EOS'
#!/bin/sh
echo "AUTO_MODE_SERVER=${CLAUDE_CODE_AUTO_MODE_SERVER-<unset>}"
EOS
chmod +x $tmp/bin/claude

run() {  # run <env assignments...> -- : prints what the stubbed claude saw
    env -i HOME="$HOME" PATH="$tmp/bin:/usr/bin:/bin" "$@" zsh -fc "source $root/zsh/functions/claude/common.zsh; _claude_invoke --x"
}

[[ "$(run ANTHROPIC_BASE_URL=http://127.0.0.1:4146)" == "AUTO_MODE_SERVER=0" ]] || fail "base URL set: expected 0"
[[ "$(run ANTHROPIC_BASE_URL=http://127.0.0.1:4146 CLAUDE_CODE_AUTO_MODE_SERVER=1)" == "AUTO_MODE_SERVER=0" ]] || fail "inherited 1 must be overridden to 0"
[[ "$(run ANTHROPIC_VERTEX_BASE_URL=https://vertex.example)" == "AUTO_MODE_SERVER=0" ]] || fail "vertex base URL set: expected 0"
[[ "$(run)" == "AUTO_MODE_SERVER=<unset>" ]] || fail "no endpoint override: must stay untouched"
[[ "$(run CLAUDE_CODE_AUTO_MODE_SERVER=1)" == "AUTO_MODE_SERVER=1" ]] || fail "no endpoint override: caller value must stay"

# Static: the guard is wired into every final-invocation variant.
grep -q '_claude_endpoint_guard' $root/scripts/claude-provider-prepare.zsh || fail "T3 capture bridge does not call the guard"
grep -q '_claude_endpoint_guard' $root/zsh/functions/claude/providers/openshell.zsh || fail "openshell invoke does not call the guard"
grep -q 'CLAUDE_CODE_AUTO_MODE_SERVER' $root/zsh/functions/claude/providers/openshell.zsh || fail "openshell sandbox env does not forward the variable"

# Static: no provider launches claude directly (bypassing _claude_invoke).
bad=$(grep -nE '^\s*command claude\s+("|--bare|-)' $root/zsh/functions/claude/providers/*.zsh | grep -v -- '--version' || true)
[[ -z "$bad" ]] || fail "provider launches claude without _claude_invoke:\n$bad"

print -- "PASS: claude-auto-mode-server"
