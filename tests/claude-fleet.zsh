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
# Deterministic umask: the cache write's umask save/restore round-trips
# zero-padded octal, and the invoking shell's umask must not matter.
umask 002
# Isolate the launcher cache: the generator writes XDG_CACHE_HOME, and the
# suite's throwaway configs must not clobber the real one.
export XDG_CACHE_HOME="$tmp/cache"
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

# Whitespace in .ssh (newline or tab) is refused at resolution and
# excluded from generation/completion — a tab target would otherwise fail
# only at ssh, invisible to diagnose.
print -r -- '{"hosts":[{"name":"nlnl","ssh":"a@x\nb@y"},{"name":"tabby","ssh":"a@x\tb"}]}' \
    > "$tmp/cfg/fleet.json"
out=$(claude-fleet nlnl 2>&1) && fail "newline-in-ssh target accepted"
[[ $out == *"invalid ssh target containing whitespace"* ]] || fail "newline-in-ssh misdiagnosed: $out"
out=$(claude-fleet tabby 2>&1) && fail "tab-in-ssh target accepted"
[[ $out == *"invalid ssh target containing whitespace"* ]] || fail "tab-in-ssh misdiagnosed: $out"
unset -f claude-nlnl claude-tabby 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-nlnl] )) && fail "newline-in-ssh peer got a launcher"
(( $+functions[claude-tabby] )) && fail "tab-in-ssh peer got a launcher"
pairs=$(_claude_fleet_host_pairs)
[[ $pairs != *nlnl* && $pairs != *tabby* ]] || fail "whitespace target offered by completion"

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

# Cache, v2 single file: identical content hits (no jq), content change
# regenerates, the collision guard in cached lines fires, and a peer whose
# collision disappeared is defined by its (previously inert) cached line.
print -r -- '{"hosts":[{"name":"cachey","ssh":"c@x"}]}' > "$tmp/cfg/fleet.json"
unset -f claude-cachey 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-cachey] )) || fail "cache write did not define launcher"
cachefile="$tmp/cache/claude-provider/fleet/launchers.zsh"
[[ -r "$cachefile" ]] || fail "cache file missing"
local -a cl; cl=("${(f)"$(<$cachefile)"}")
[[ ${cl[1]} == "# fleet-launchers cache v2" ]] || fail "cache version line wrong: ${cl[1]}"
[[ ! -e "$tmp/cache/claude-provider/fleet/fleet.json" ]] || fail "v1 snapshot file still written"
unset -f claude-cachey 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-cachey] )) || fail "cache hit did not define launcher"
out=$(claude-cachey)
[[ $out == *"ssh-host: c@x"* ]] || fail "cached launcher broken: $out"
# Guard baked into the cached line: a function defined AFTER the cache was
# written must still win over the cached definition.
claude-cachey() { echo LOCAL-WINS; }
source "$repo/zsh/functions/claude/fleet.zsh"
[[ $(claude-cachey) == LOCAL-WINS ]] || fail "cached line bypassed collision guard"
# Content change regenerates (byte-exact embedded snapshot, not mtime).
print -r -- '{"hosts":[{"name":"cachey","ssh":"c2@x"}]}' > "$tmp/cfg/fleet.json"
unset -f claude-cachey 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
out=$(claude-cachey)
[[ $out == *"ssh-host: c2@x"* ]] || fail "content change served stale cache: $out"
# A peer omitted at write time for a collision is defined by its inert
# cached line once the collision disappears: write the cache while
# claude-ghost collides, then remove the collision.
print -r -- '{"hosts":[{"name":"ghost","ssh":"g@x"}]}' > "$tmp/cfg/fleet.json"
claude-ghost() { echo COLLIDING; }
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-ghost] )) || fail "collision function clobbered by generation"
unset -f claude-ghost
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-ghost] )) || fail "disappeared collision not regenerated from cache"
out=$(claude-ghost)
[[ $out == *"ssh-host: g@x"* ]] || fail "regenerated ghost launcher broken: $out"

# Cache version gate: a cache with a stale/missing version line is
# regenerated even when fleet.json content matches.
print -r -- '{"hosts":[{"name":"vercheck","ssh":"v@x"}]}' > "$tmp/cfg/fleet.json"
unset -f claude-vercheck 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
cachefile="$tmp/cache/claude-provider/fleet/launchers.zsh"
[[ "$(head -n 1 -- "$cachefile")" == "# fleet-launchers cache v2" ]] || fail "version line missing from cache"
# Corrupt the version line, keep content identical -> must regenerate.
# (Portable rewrite — GNU-only `sed -i` syntax breaks BSD/macOS sed.)
{ print -r -- '# fleet-launchers cache v0'; sed -n '2,$p' -- "$cachefile"; } > "$cachefile.new"
# 0600 so the ONLY defect is the stale version line: under the suite's
# umask 002 the rewrite lands 0664 and the trust gate would reject it on
# mode before the version compare ever runs — coverage by accident.
chmod 600 "$cachefile.new"
mv -f -- "$cachefile.new" "$cachefile"
unset -f claude-vercheck 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
[[ "$(head -n 1 -- "$cachefile")" == "# fleet-launchers cache v2" ]] || fail "stale-version cache not regenerated"
(( $+functions[claude-vercheck] )) || fail "regeneration after version mismatch failed"

# Convergence: after a content change, the rewritten cache must contain
# EVERY peer, not just the delta the old cache had not defined (sourcing
# the old cache first would make its definitions look like collisions).
print -r -- '{"hosts":[{"name":"conv-a","ssh":"a@x"},{"name":"conv-b","ssh":"b@x"}]}' > "$tmp/cfg/fleet.json"
unset -f claude-conv-a claude-conv-b 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
print -r -- '{"hosts":[{"name":"conv-a","ssh":"a2@x"},{"name":"conv-b","ssh":"b@x"},{"name":"conv-c","ssh":"c@x"}]}' > "$tmp/cfg/fleet.json"
source "$repo/zsh/functions/claude/fleet.zsh"
for fn in claude-conv-a claude-conv-b claude-conv-c; do
    (( $+functions[$fn] )) || fail "$fn missing after content-change regeneration"
done
unset -f claude-conv-a claude-conv-b claude-conv-c 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
for fn in claude-conv-a claude-conv-b claude-conv-c; do
    (( $+functions[$fn] )) || fail "$fn missing on the cache hit after regeneration"
done
out=$(claude-conv-a)
[[ $out == *"ssh-host: a2@x"* ]] || fail "converged launcher wrong target: $out"

# A t3-* peer never generates a launcher that would shadow the
# claude-t3-* PATH commands (which load after this file in .zshrc).
print -r -- '{"hosts":[{"name":"t3-openai","ssh":"t@x"},{"name":"plainpeer","ssh":"p@x"}]}' > "$tmp/cfg/fleet.json"
unset -f claude-t3-openai claude-plainpeer 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-t3-openai] )) && fail "t3-* peer generated a shadowing launcher"
(( $+functions[claude-plainpeer] )) || fail "unrelated peer skipped by t3- guard"

# A pretty-printed (multi-line) fleet.json must hit the cache: the quoted
# snapshot embeds newlines, and a line-based compare would never match.
printf '{\n  "hosts": [\n    {"name": "prettypeer", "ssh": "pp@x"}\n  ]\n}\n' > "$tmp/cfg/fleet.json"
unset -f claude-prettypeer 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-prettypeer] )) || fail "pretty-printed fleet.json did not generate"
unset -f claude-prettypeer 2>/dev/null || true
# jq fork counter: a cache hit must NOT fork jq (marker compare only).
# Fork detector via a FILE side channel: the generator points jq's own
# stderr at /dev/null, so a stderr marker can never surface — assert on
# a touched file instead.
real_jq=$(whence -p jq)
cat > "$tmp/bin/jq" <<JQ
#!/bin/sh
touch "$tmp/JQ-FORKED"
exec $real_jq "\$@"
JQ
chmod +x "$tmp/bin/jq"
rehash
rm -f "$tmp/JQ-FORKED"
source "$repo/zsh/functions/claude/fleet.zsh"
[[ -e "$tmp/JQ-FORKED" ]] && fail "cache MISS for pretty-printed fleet.json (jq forked)"
(( $+functions[claude-prettypeer] )) || fail "pretty-printed cache hit did not define launcher"

# An all-local-state fleet.json (zero launcher names) still caches: the
# next shell must be a fork-free hit.
print -r -- '{"hosts":[{"name":"onlylocal","dir":"/tmp"}]}' > "$tmp/cfg/fleet.json"
source "$repo/zsh/functions/claude/fleet.zsh"
[[ -r "$tmp/cache/claude-provider/fleet/launchers.zsh" ]] || fail "zero-names config wrote no cache"
rm -f "$tmp/JQ-FORKED"
source "$repo/zsh/functions/claude/fleet.zsh"
[[ -e "$tmp/JQ-FORKED" ]] && fail "zero-names config re-forked jq on cache hit"

# A transient jq failure is not cached: the unlucky shell defines nothing,
# but no cache is written, so the next shell retries.
print -r -- '{"hosts":[{"name":"jqfail","ssh":"j@x"}]}' > "$tmp/cfg/fleet.json"
cat > "$tmp/bin/jq" <<'JQ'
#!/bin/sh
exit 3
JQ
chmod +x "$tmp/bin/jq"
unset -f claude-jqfail 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-jqfail] )) && fail "failing jq still defined launchers"
[[ -e "$tmp/cache/claude-provider/fleet/launchers.zsh" ]]     && grep -q "jqfail" "$tmp/cache/claude-provider/fleet/launchers.zsh"     && fail "jq failure was cached"
# Working jq again: the next shell generates normally.
rm -f "$tmp/bin/jq"
rehash
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-jqfail] )) || fail "recovery after jq failure failed"

# The fork detector itself must fire on a genuine miss (guard the guard):
print -r -- '{"hosts":[{"name":"forkcanary","ssh":"f@x"}]}' > "$tmp/cfg/fleet.json"
cat > "$tmp/bin/jq" <<JQ
#!/bin/sh
touch "$tmp/JQ-FORKED"
exec $real_jq "\$@"
JQ
chmod +x "$tmp/bin/jq"
rehash
rm -f "$tmp/JQ-FORKED"
source "$repo/zsh/functions/claude/fleet.zsh"
[[ -e "$tmp/JQ-FORKED" ]] || fail "fork detector did not fire on a genuine miss"

# Trust gate: a tampered cache (world-writable, or a symlink) is rejected
# and regenerated, never evaluated.
print -r -- '{"hosts":[{"name":"trustpeer","ssh":"t@x"}]}' > "$tmp/cfg/fleet.json"
unset -f claude-trustpeer 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
chmod 666 "$tmp/cache/claude-provider/fleet/launchers.zsh"
unset -f claude-trustpeer 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-trustpeer] )) || fail "world-writable cache rejected the peer entirely"
zstat -A m +mode "$tmp/cache/claude-provider/fleet/launchers.zsh"
(( (m & 8#22) == 0 )) || fail "world-writable cache not regenerated (mode $m)"
rm -f "$tmp/cache/claude-provider/fleet/launchers.zsh"
ln -s /etc/hostname "$tmp/cache/claude-provider/fleet/launchers.zsh"
unset -f claude-trustpeer 2>/dev/null || true
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-trustpeer] )) || fail "symlink cache rejected the peer entirely"
[[ ! -L "$tmp/cache/claude-provider/fleet/launchers.zsh" ]] || fail "symlink cache not replaced"

# Resolution-aware walk: a USER-OWNED symlink (trusted lexically) whose
# target lives under an ancestor that turns untrusted must be rejected —
# the walk recurses into the resolved target's ancestors. The suite
# cannot create a foreign-owned dir unprivileged, so "untrusted" is
# simulated by mode: a group-writable non-sticky ancestor.
# (Fixture dirs are created under umask 002; normalize them first so the
# positive control is actually trusted.)
shared="$tmp/sharedroot"
mkdir -p "$shared/inside/claude-provider/fleet" "$tmp/mylinkhome"
chmod 755 "$shared" "$shared/inside" "$shared/inside/claude-provider" \
    "$shared/inside/claude-provider/fleet" "$tmp/mylinkhome"
print -r -- '{"hosts":[{"name":"viagymlink","ssh":"v@x"}]}' > "$tmp/cfg/fleet.json"
print -r -- "# cache" > "$shared/inside/claude-provider/fleet/launchers.zsh"
chmod 600 "$shared/inside/claude-provider/fleet/launchers.zsh"
ln -sfn "$shared/inside/claude-provider/fleet" "$tmp/mylinkhome/cachelink"
_claude-fleet-path-trusted "$tmp/mylinkhome/cachelink/launchers.zsh" 0 2>/dev/null \
    || fail "clean user-owned symlinked path rejected by the trust walk"
# Untrusted resolved ancestor: group-writable non-sticky target ancestor
# must fail the walk even though the lexical path is entirely user-owned.
chmod 775 "$shared"
_claude-fleet-path-trusted "$tmp/mylinkhome/cachelink/launchers.zsh" 0 2>/dev/null \
    && fail "group-writable resolved ancestor passed the trust walk"
chmod 755 "$shared"

# Write-side symlink hardening: a pre-planted temp-file symlink must not
# be followed. rm -f unlinks it (rm never follows symlinks) and the
# sysopen O_EXCL|O_NOFOLLOW create would refuse it even without the rm,
# so the canary file survives AND the cache is still written. The canary
# is deliberately EMPTY and CLOBBER_EMPTY is turned on: zsh 5.9's
# noclobber fallback follows symlinks to empty files, so this pins the
# attack that motivated dropping noclobber for sysopen.
print -r -- '{"hosts":[{"name":"tmpsymlink","ssh":"t@x"}]}' > "$tmp/cfg/fleet.json"
rm -f "$cachefile"
mkdir -p "$tmp/cache/claude-provider/fleet"
: > "$tmp/canary"
setopt clobber_empty 2>/dev/null
ln -s "$tmp/canary" "$tmp/cache/claude-provider/fleet/launchers.zsh.tmp.$$"
source "$repo/zsh/functions/claude/fleet.zsh"
[[ "$(cat "$tmp/canary")" == "" ]] || fail "temp-file symlink was followed (canary clobbered)"
[[ -r "$cachefile" ]] || fail "pre-planted temp symlink suppressed the cache write"
[[ ! -L "$cachefile" ]] || fail "cache file is a symlink"

# Existing-path refusal at the temp name WITHOUT the rm in front: a
# DIRECTORY at the temp path survives rm -f (which cannot remove
# directories), so the O_EXCL create itself must refuse it — write
# skipped, launcher still defined, the directory untouched.
print -r -- '{"hosts":[{"name":"tmpdir","ssh":"t@x"}]}' > "$tmp/cfg/fleet.json"
rm -f "$cachefile"
mkdir -p "$tmp/cache/claude-provider/fleet/launchers.zsh.tmp.$$"
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-tmpdir] )) || fail "existing-path temp file rejected the launcher entirely"
[[ -d "$tmp/cache/claude-provider/fleet/launchers.zsh.tmp.$$" ]] || fail "pre-planted temp directory was disturbed"
[[ -e "$cachefile" ]] && fail "cache written despite existing-path temp collision"
rmdir "$tmp/cache/claude-provider/fleet/launchers.zsh.tmp.$$"

# Symlink present AT OPEN TIME: rm is stubbed out for the temp path so
# the pre-planted symlink survives to the sysopen itself, which must
# refuse it (O_EXCL|O_NOFOLLOW) — canary intact, symlink untouched,
# write skipped, launcher still defined. This isolates the open's own
# guarantee from the rm -f defense in front of it.
print -r -- '{"hosts":[{"name":"tmpsymlink2","ssh":"t@x"}]}' > "$tmp/cfg/fleet.json"
rm -f "$cachefile"
: > "$tmp/canary2"
ln -s "$tmp/canary2" "$tmp/cache/claude-provider/fleet/launchers.zsh.tmp.$$"
rm() { [[ "$*" == *".tmp.$$" ]] && return 0; command rm "$@"; }
source "$repo/zsh/functions/claude/fleet.zsh"
unfunction rm
[[ "$(cat "$tmp/canary2")" == "" ]] || fail "sysopen followed a symlink at open time (canary clobbered)"
[[ -L "$tmp/cache/claude-provider/fleet/launchers.zsh.tmp.$$" ]] || fail "pre-planted temp symlink disturbed before open"
(( $+functions[claude-tmpsymlink2] )) || fail "symlink-at-open rejected the launcher entirely"
[[ -e "$cachefile" ]] && fail "cache written despite symlink at the temp path at open time"
rm -f "$tmp/cache/claude-provider/fleet/launchers.zsh.tmp.$$"

# Confused-deputy chmod guard: an attacker-controlled symlink at a
# cache-tree level must NOT make the permission fixup chmod the
# symlink's destination (chmod follows symlinks). fleet-as-symlink to a
# user-owned 755 canary dir: the mode must stay 755, no cache appears
# inside the canary, and the launcher still defines.
print -r -- '{"hosts":[{"name":"chmodguard","ssh":"c@x"}]}' > "$tmp/cfg/fleet.json"
mkdir -p "$tmp/xdg2/claude-provider" "$tmp/owntarget"
chmod 755 "$tmp/owntarget" "$tmp/xdg2/claude-provider"
ln -s "$tmp/owntarget" "$tmp/xdg2/claude-provider/fleet"
save_xdg=$XDG_CACHE_HOME
XDG_CACHE_HOME="$tmp/xdg2"
source "$repo/zsh/functions/claude/fleet.zsh"
XDG_CACHE_HOME="$save_xdg"
zstat -A m +mode "$tmp/owntarget"
(( (m & 8#7777) == 8#755 )) || fail "chmod followed the fleet symlink (target mode $(printf %o $m))"
[[ ! -e "$tmp/owntarget/launchers.zsh" ]] || fail "cache written through the fleet symlink"
(( $+functions[claude-chmodguard] )) || fail "chmod guard rejected the launcher entirely"

# The permission-change path is GONE, not just guarded: the walk-to-chmod
# race an ancestor-swapping attacker could win is closed by removing the
# operation. A chmod stub records any invocation during a full
# generate-and-write cycle; it must stay silent.
rm -f "$tmp/chmod-log"
chmod() { print -r -- "$*" >> "$tmp/chmod-log"; command chmod "$@"; }
print -r -- '{"hosts":[{"name":"nochmod","ssh":"n@x"}]}' > "$tmp/cfg/fleet.json"
rm -f "$tmp/cache/claude-provider/fleet/launchers.zsh"
source "$repo/zsh/functions/claude/fleet.zsh"
unfunction chmod
[[ ! -e "$tmp/chmod-log" ]] || fail "cache write path invoked chmod: $(cat "$tmp/chmod-log")"
[[ -r "$tmp/cache/claude-provider/fleet/launchers.zsh" ]] || fail "chmod-free write did not produce a cache"
zstat -A m +mode "$tmp/cache/claude-provider/fleet/launchers.zsh"
(( (m & 8#777) == 8#600 )) || fail "cache file mode not 600 ($(printf %o $m))"

# mkdir must be invoked WITHOUT -m: Apple's mkdir implements -m as a
# pathname chmod AFTER creation, which reopens the ancestor-swap race
# the chmod removal closed. The directory mode must come from the
# umask-077 creation subshell instead — observable as: no -m flag on
# any mkdir call, and fresh tree levels land 0700 under the suite's
# umask 002.
rm -rf "$tmp/cache"
rm -f "$tmp/mkdir-log"
mkdir() { print -r -- "$*" >> "$tmp/mkdir-log"; command mkdir "$@"; }
source "$repo/zsh/functions/claude/fleet.zsh"
unfunction mkdir
if [[ -e "$tmp/mkdir-log" ]] && grep -qE '(^|[[:space:]])-m' "$tmp/mkdir-log"; then
    fail "mkdir invoked with -m: $(cat "$tmp/mkdir-log")"
fi
for d in "$tmp/cache" "$tmp/cache/claude-provider" "$tmp/cache/claude-provider/fleet"; do
    zstat -A m +mode "$d"
    (( (m & 8#777) == 8#700 )) || fail "$d not 0700 ($(printf %o $m))"
done

# Write gate: an untrusted ancestor ABOVE the XDG root (group-writable,
# and the go-w fix only touches the XDG root itself, so it stays
# unfixable) must suppress the cache write — launchers still defined.
print -r -- '{"hosts":[{"name":"gatedpeer","ssh":"g@x"}]}' > "$tmp/cfg/fleet.json"
rm -f "$cachefile"
chmod 775 "$tmp"
source "$repo/zsh/functions/claude/fleet.zsh"
(( $+functions[claude-gatedpeer] )) || fail "write gate rejected the launcher entirely"
[[ -e "$cachefile" ]] && fail "cache written through an untrusted ancestor"
chmod 700 "$tmp"

print -- "ok claude-fleet"
