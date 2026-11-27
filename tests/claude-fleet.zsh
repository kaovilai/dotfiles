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

# Dash-prefixed ssh targets are refused (ssh option injection) and the
# ssh call carries -- before the target.
print -r -- '{"hosts":[{"name":"evil","ssh":"-oProxyCommand=touch $tmp/PWNED2"}]}' \
    > "$tmp/cfg/fleet.json"
if claude-fleet evil >/dev/null 2>&1; then
    fail "dash-prefixed ssh target accepted"
fi

# Degenerate .ssh values (empty string, non-string) get no launcher and no
# completion pair — the generated set matches what resolution accepts.
print -r -- '{"hosts":[{"name":"emptyish","ssh":""},{"name":"numish","ssh":42},{"name":"goodish","ssh":"g@x"}]}' \
    > "$tmp/cfg/fleet.json"
unset -f claude-emptyish claude-numish claude-goodish 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-emptyish] )) && fail "launcher for empty .ssh"
(( $+functions[claude-numish] )) && fail "launcher for non-string .ssh"
(( $+functions[claude-goodish] )) || fail "valid peer skipped by strict filter"
pairs=$(_claude_fleet_host_pairs)
[[ $pairs == *"goodish:g@x"* ]] || fail "good peer missing from pairs: $pairs"
[[ $pairs != *emptyish* && $pairs != *numish* ]] || fail "degenerate peer offered by completion"

# Direct resolution rejects degenerate targets the same way (claude-fleet
# numish must fail BEFORE ssh sees "42" as a destination).
print -r -- '{"hosts":[{"name":"numish","ssh":42},{"name":"goodish","ssh":"g@x"}]}' \
    > "$tmp/cfg/fleet.json"
out=$(claude-fleet numish 2>&1) && fail "numeric .ssh accepted by resolution"
[[ $out == *"no fleet host named 'numish'"* ]] || fail "numeric .ssh wrong diagnosis: $out"
out=$(claude-fleet goodish 2>&1)
[[ $out == *"ssh-host: g@x"* ]] || fail "valid peer stopped resolving: $out"

# Malformed fleet.json surfaces the parse error, not a missing-host message.
print -r -- '{not json' > "$tmp/cfg/fleet.json"
out=$(claude-fleet goodish 2>&1) || true
[[ $out == *"cannot parse"* ]] || fail "malformed json misdiagnosed: $out"

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
# The completion's host pairs read fleet.json live, ssh-backed peers only.
pairs=$(_claude_fleet_host_pairs)
[[ $pairs == *"ryzen-wsl:user@ryzen.example"* ]] || fail "host pairs wrong: $pairs"
[[ $pairs == *"spectre:spec"* ]] || fail "host pairs missing spectre: $pairs"

# Alias collision: the repo ships claude-<x> aliases (misc.zsh) that
# parse-expand before any function can run; a peer with that name must not
# get a silently dead launcher.
print -r -- '{"hosts":[{"name":"sonnet","ssh":"s@x"},{"name":"free-peer","ssh":"f@x"}]}' \
    > "$tmp/cfg/fleet.json"
alias claude-sonnet='claude --model sonnet'
unset -f claude-sonnet claude-free-peer 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-sonnet] )) && fail "launcher generated over an alias"
(( $+functions[claude-free-peer] )) || fail "peer skipped because of unrelated alias"
unalias claude-sonnet

# Completion pairs exclude ssh-less peers (consistent with generation).
print -r -- '{"hosts":[{"name":"localish","dir":"/tmp"},{"name":"remoteish","ssh":"r@x"}]}' \
    > "$tmp/cfg/fleet.json"
pairs=$(_claude_fleet_host_pairs)
[[ $pairs == *"remoteish:r@x"* ]] || fail "ssh-backed peer missing from completion pairs: $pairs"
[[ $pairs == *localish* ]] && fail "ssh-less peer offered by completion"

# Args with embedded newlines survive the remote re-parse intact
# (${(qq)} quoting, not ${(q)} whose escaped LF becomes a continuation).
print -r -- '{"hosts":[{"name":"spectre","ssh":"spec"}]}' > "$tmp/cfg/fleet.json"
out=$(claude-spectre -p $'line1\nline2')
print -r -- "$out" | grep -q "arg: line1" || fail "newline arg lost entirely"
print -rl -- "$out" | grep -qx "line2" || fail "second line of newline arg lost"
# The re-parse must NOT have fused the lines into one continuation-free arg.
[[ $out == *"line1line2"* ]] && fail "newline eaten by remote re-parse (line continuation)"

# Generation predicate mirrors resolution: numeric names and names with a
# trailing newline (which jq -r would split into phantom peers) generate
# nothing, while the zsh-side regex stays as defense in depth.
print -r -- '{"hosts":[{"name":42,"ssh":"n@x"},{"name":"trailn\n","ssh":"t@x"},{"name":"solidname","ssh":"s@x"}]}' \
    > "$tmp/cfg/fleet.json"
unset -f claude-42 claude-trailn claude-solidname 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-42] )) && fail "numeric name generated a launcher"
(( $+functions[claude-trailn] )) && fail "trailing-newline name generated a launcher"
(( $+functions[claude-solidname] )) || fail "valid name skipped by generation predicate"

# Newline-in-.ssh entries generate no launcher either (resolution and
# completion already refuse them).
print -r -- '{"hosts":[{"name":"nlgen","ssh":"a@x\nb@y"},{"name":"okgen","ssh":"o@x"}]}' \
    > "$tmp/cfg/fleet.json"
unset -f claude-nlgen claude-okgen 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-nlgen] )) && fail "newline-in-ssh peer got a launcher"
(( $+functions[claude-okgen] )) || fail "valid peer skipped by newline exclusion"

# Dash-prefixed targets and duplicate names are refused by resolution, so
# they get neither launchers nor completion pairs (resolvable == offered).
print -r -- '{"hosts":[{"name":"dashtarget","ssh":"-oProxyCommand=x"},{"name":"dupgen","ssh":"a@x"},{"name":"dupgen","ssh":"b@x"},{"name":"solo","ssh":"s@x"}]}' \
    > "$tmp/cfg/fleet.json"
unset -f claude-dashtarget claude-dupgen claude-solo 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-dashtarget] )) && fail "dash-target peer got a launcher"
(( $+functions[claude-dupgen] )) && fail "ambiguous peer got a launcher"
(( $+functions[claude-solo] )) || fail "valid peer skipped by dedup"
pairs=$(_claude_fleet_host_pairs)
[[ $pairs == *"solo:s@x"* ]] || fail "valid pair missing: $pairs"
[[ $pairs != *dashtarget* && $pairs != *dupgen* ]] || fail "refused peer offered by completion"

# A SINGLE entry with an embedded newline in .ssh is diagnosed as the
# newline defect, not as duplicate entries (count is entries, not lines).
print -r -- '{"hosts":[{"name":"nlnl","ssh":"a@x\nb@y"}]}' \
    > "$tmp/cfg/fleet.json"
out=$(claude-fleet nlnl 2>&1) && fail "newline-in-ssh target accepted"
[[ $out == *"invalid ssh target containing a newline"* ]] || fail "newline-in-ssh misdiagnosed: $out"

# Duplicate host names are diagnosed, not passed to ssh as a multi-line
# destination.
print -r -- '{"hosts":[{"name":"dup","ssh":"a@x"},{"name":"dup","ssh":"b@x"},{"name":"uniq","ssh":"u@x"}]}' \
    > "$tmp/cfg/fleet.json"
out=$(claude-fleet dup 2>&1) && fail "duplicate name accepted"
[[ $out == *"ambiguous"* ]] || fail "duplicate name misdiagnosed: $out"
out=$(claude-fleet uniq 2>&1)
[[ $out == *"ssh-host: u@x"* ]] || fail "unique peer stopped resolving: $out"

# A peer whose launcher would shadow a PATH command (claude-dispatch shim,
# claude-t3-* launchers) generates nothing: functions run before PATH.
print -r -- '#!/bin/sh
echo REAL-LAUNCHER' > "$tmp/bin/claude-pathish"
chmod +x "$tmp/bin/claude-pathish"
rehash  # commands assoc is a PATH snapshot; the stub postdates shell start
print -r -- '{"hosts":[{"name":"pathish","ssh":"p@x"},{"name":"freepath","ssh":"f@x"}]}' \
    > "$tmp/cfg/fleet.json"
unset -f claude-pathish claude-freepath 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-pathish] )) && fail "launcher generated over a PATH command"
(( $+functions[claude-freepath] )) || fail "peer skipped because of unrelated PATH command"

# Completion pairs exclude newline-in-.ssh entries (resolution refuses
# them; jq -r would otherwise split the pair mid-entry).
print -r -- '{"hosts":[{"name":"nlpair","ssh":"a@x\nb@y"},{"name":"cleanpair","ssh":"c@x"}]}' \
    > "$tmp/cfg/fleet.json"
pairs=$(_claude_fleet_host_pairs)
[[ $pairs == *"cleanpair:c@x"* ]] || fail "clean pair missing: $pairs"
[[ $pairs != *nlpair* ]] || fail "newline-in-ssh pair offered by completion"

# Completion pairs only offer label-valid names (numeric/corrupt names
# resolution could never match).
print -r -- '{"hosts":[{"name":42,"ssh":"n@x"},{"name":"col:on","ssh":"c@x"},{"name":"validone","ssh":"v@x"}]}' \
    > "$tmp/cfg/fleet.json"
pairs=$(_claude_fleet_host_pairs)
[[ $pairs == *"validone:v@x"* ]] || fail "valid name missing from pairs: $pairs"
[[ $pairs != *"42:"* && $pairs != *"col:on"* ]] || fail "invalid name offered by completion"

print -- "ok claude-fleet"
