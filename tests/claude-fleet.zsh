#!/bin/zsh
# Offline tests for zsh/functions/claude/fleet.zsh: a throwaway
# LLM_USAGE_CONFIG_DIR with a stub fleet.json, a stub ssh that emulates the
# remote login shell RE-PARSING the joined command line (plain "$*" loses
# quoting — that bug shipped once), and a stub remote claude. Stubs locate
# their own dir via $0 so no path interpolation is needed; ZDOTDIR keeps the
# user's ~/.zshenv (and its PATH tweaks) out of every spawned zsh. Never
# touches the real fleet.json or the network.
emulate -LR zsh
setopt err_exit pipe_fail
local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { print -ru2 -- "FAIL: $*"; exit 1; }

mkdir -p "$tmp/bin" "$tmp/cfg"
export LLM_USAGE_CONFIG_DIR="$tmp/cfg"
export PATH="$tmp/bin:$PATH"
export ZDOTDIR="$tmp"

# Stub remote claude: prints its args, one per line.
cat > "$tmp/bin/claude" <<'STUB'
#!/bin/sh
echo claude-stub
for a in "$@"; do echo "  arg: $a"; done
STUB

# Stub ssh: skip flags, record the host, then EMULATE the remote login shell
# re-parsing the command line: join the remaining args with spaces and run
# them in a fresh zsh (which re-parses quoting exactly like the real thing).
cat > "$tmp/bin/ssh" <<'STUB'
#!/bin/zsh
stubdir=${0:A:h}
export ZDOTDIR=$stubdir:h PATH=$stubdir:$PATH
local -a remote_args
remote_args=("$@")
local first=${remote_args[1]}
while [[ $first == -* ]]; do
  remote_args=("${remote_args[@]:1}")
  first=${remote_args[1]}
done
print -r -- "ssh-host: ${remote_args[1]}"
local joined="${(j: :)remote_args[@]:1}"
zsh -dfc "PS1=; $joined" 2>&1
STUB
chmod +x "$tmp/bin/claude" "$tmp/bin/ssh"
# zsh hashes commands at startup (ssh -> /usr/bin/ssh from the user's
# .zshenv PATH); a PATH prepend does not invalidate the entry, and rehash
# before the stub exists would just re-hash the real one — so rehash HERE.
rehash

print -r -- '{"hosts":[{"name":"ryzen-wsl","ssh":"user@ryzen.example"},{"name":"spectre","ssh":"spec"}]}' \
    > "$tmp/cfg/fleet.json"

source "$repo/zsh/functions/claude/fleet.zsh"

# Function generation: full names + short alias for dashed names.
(( $+functions[claude-fleet] )) || fail "claude-fleet not defined"
(( $+functions[claude-ryzen-wsl] )) || fail "claude-ryzen-wsl not generated"
(( $+functions[claude-ryzen] )) || fail "short alias claude-ryzen not generated"
(( $+functions[claude-spectre] )) || fail "claude-spectre not generated"

# Short alias resolves the FULL fleet name (the wrapper hardcodes it).
out=$(claude-ryzen)
[[ $out == *"ssh-host: user@ryzen.example"* ]] || fail "claude-ryzen wrong target: $out"
[[ $out == *"claude-stub"* ]] || fail "remote claude did not run: $out"

# Undashed host: single function, correct target.
out=$(claude-spectre)
[[ $out == *"ssh-host: spec"* ]] || fail "claude-spectre wrong target: $out"
[[ $out == *"claude-stub"* ]] || fail "remote claude did not run: $out"

# Args pass through the remote re-parse intact — quoting survives ssh.
out=$(claude-spectre -c 'print hi there')
[[ $out == *"arg: -c"* && $out == *"arg: print hi there"* ]] || fail "args mangled by remote re-parse: $out"

# Unknown host: friendly error, nonzero exit.
if claude-fleet nosuchhost >/dev/null 2>&1; then
    fail "unknown host accepted"
fi

# Collision guard: a peer named like a real function never overwrites it.
claude-copilot() { echo REAL; }
print -r -- '{"hosts":[{"name":"copilot","ssh":"x@y"}]}' > "$tmp/cfg/fleet.json"
unset -f claude-ryzen claude-ryzen-wsl claude-spectre
source "$repo/zsh/functions/claude/fleet.zsh"
[[ $(claude-copilot) == REAL ]] || fail "collision guard overwrote claude-copilot"

# Short alias cannot shadow a later full peer name (two-pass generation):
# ryzen-wsl listed before ryzen must leave claude-ryzen pointing at the REAL
# ryzen peer.
print -r -- '{"hosts":[{"name":"ryzen-wsl","ssh":"w@dashed"},{"name":"ryzen","ssh":"r@full"}]}' \
    > "$tmp/cfg/fleet.json"
unset -f claude-ryzen claude-ryzen-wsl 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
out=$(claude-ryzen)
[[ $out == *"ssh-host: r@full"* ]] || fail "short alias shadowed the real peer: $out"
out=$(claude-ryzen-wsl)
[[ $out == *"ssh-host: w@dashed"* ]] || fail "full dashed name broken: $out"

# Peers without an ssh target (local-state entries) get no launcher.
print -r -- '{"hosts":[{"name":"localish","dir":"/tmp"},{"name":"remoteish","ssh":"r@x"}]}' \
    > "$tmp/cfg/fleet.json"
unset -f claude-localish claude-remoteish 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-localish] )) && fail "launcher generated for ssh-less peer"
(( $+functions[claude-remoteish] )) || fail "ssh-backed peer skipped"

# Hostile fleet.json names never become code: anything outside
# [A-Za-z0-9_-] is skipped, not eval'd/defined (GHAS prompt-injection fix).
print -r -- '{"hosts":[{"name":"x; touch $tmp/PWNED; #","ssh":"x@y"},{"name":"ok-host","ssh":"z@z"},{"name":"bad name","ssh":"z@z"},{"name":"$(echo pwn)","ssh":"z@z"}]}' \
    > "$tmp/cfg/fleet.json"
unset -f claude-ok-host 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
[[ -e $tmp/PWNED ]] && fail "hostile name executed code"
(( $+functions[claude-ok-host] )) || fail "valid peer skipped by hostile-name validation"
for bad in 'claude-x;' 'claude-bad' 'claude-$'; do
    (( $+functions[$bad] )) && fail "function generated from hostile name: $bad"
done

# Missing fleet.json: no functions generated, no errors at load.
export LLM_USAGE_CONFIG_DIR="$tmp/nope"
unset -f claude-fleet claude-copilot
source "$repo/zsh/functions/claude/fleet.zsh" 2>/dev/null
(( $+functions[claude-fleet] )) || fail "claude-fleet should stay defined on missing cfg"

# Completion: _claude-fleet defined, registers via compdef when compinit ran
# (bare shells without compdef must still source cleanly — covered above).
export LLM_USAGE_CONFIG_DIR="$tmp/cfg"
print -r -- '{"hosts":[{"name":"ryzen-wsl","ssh":"user@ryzen.example"},{"name":"spectre","ssh":"spec"}]}' \
    > "$tmp/cfg/fleet.json"
autoload -Uz compinit && compinit -u -d "$tmp/zcompdump" >/dev/null 2>&1
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[_claude-fleet] )) || fail "_claude-fleet completion not defined"
[[ ${_comps[claude-fleet]:-} == _claude-fleet ]] || fail "claude-fleet not registered with compdef"
# The describe source reads fleet.json live: descriptions carry ssh targets.
out=$(_claunch=1; zsh -c "
source '$repo/zsh/functions/claude/fleet.zsh'
print -rl -- \$(jq -r '.hosts[].name' '$tmp/cfg/fleet.json')
" 2>/dev/null)
[[ $out == *ryzen-wsl* && $out == *spectre* ]] || fail "host list for completion wrong: $out"

print -- "ok claude-fleet"
