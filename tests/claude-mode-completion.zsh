#!/bin/zsh
# Offline tests for the claude-mode tab completion in mode.zsh: compdef
# registration, candidate list staying in sync with the accepted case
# pattern (drift guard when providers are added), current-mode tagging
# (including the fail-safe unknown -> vertex read), and no completion past
# the single optional argument.
emulate -LR zsh
setopt err_exit pipe_fail extendedglob  # extendedglob: [[:space:]]## prefix trim below
local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { print -ru2 -- "FAIL: $*"; exit 1 }

# compdef stub: capture the registration mode.zsh makes at source time
typeset -ga registered
compdef() { registered+=("$@") }
print -r -- vertex > "$tmp/mode"
source "$repo/zsh/functions/claude/mode.zsh"
_claude_mode_file="$tmp/mode"

(( $+functions[_claude-mode] )) || fail 'completion function _claude-mode not defined'
(( ${#registered} == 2 )) || fail "expected one compdef registration, got: $registered"
[[ $registered[1] == _claude-mode && $registered[2] == claude-mode ]] ||
    fail "wrong compdef registration: $registered"

# _describe stub: resolve the array name passed as the last argument (zsh
# dynamic scoping makes _claude-mode's local visible here) and capture it
typeset -ga described
_describe() { described=("${(@P)@[-1]}") }

# comp <CURRENT> — simulate the completion widget calling _claude-mode
comp() {
    described=()
    CURRENT=$1
    words=(claude-mode '')
    _claude-mode
}

# First word must offer exactly the modes claude-mode()'s case pattern
# accepts (parsed from the source so adding a provider without updating the
# completion fails here, not at the keyboard). Anchor is any line that is
# ONLY an alternation pattern (order-independent — reordering the case
# alternatives is behavior-neutral and must not break this test).
comp 2
(( ${#described} == 10 )) || fail "expected 10 mode candidates, got ${#described}: $described"
local -a offered accepted
offered=(${described%%:*})
local case_line
case_line=$(grep -E '^[[:space:]]+[a-z0-9-]+(\|[a-z0-9-]+)+\)$' \
    "$repo/zsh/functions/claude/mode.zsh" | grep -m1 -F vertex) ||
    fail 'accepted-mode case pattern not found in mode.zsh'
accepted=(${(s:|:)${${case_line%%\)*}##[[:space:]]##}})
[[ ${(j.:.)${(on)offered}} == ${(j.:.)${(on)accepted}} ]] ||
    fail "offered modes drift from accepted case pattern: $offered vs $accepted"
[[ -n ${(M)offered:#enmass} ]] && fail 'pre-rename spelling enmass must not be suggested'

# Exactly the persisted mode is tagged [current]; descriptions survive
local -a tagged
tagged=(${(M)described:#*\[current\]})
(( ${#tagged} == 1 )) || fail "expected exactly one [current] tag, got: $tagged"
[[ ${tagged[1]%%:*} == vertex ]] || fail "vertex not tagged current: $tagged"
[[ ${tagged[1]#vertex:} == *'local LiteLLM proxy'*'[current]' ]] ||
    fail 'current tag appended without description: '"$tagged[1]"

# Unknown persisted value fails safe to vertex, so vertex gets the tag
print -r -- bogus-mode >! "$tmp/mode"
comp 2
tagged=(${(M)described:#*\[current\]})
(( ${#tagged} == 1 )) && [[ ${tagged[1]%%:*} == vertex ]] ||
    fail 'unknown persisted mode should tag the fail-safe vertex'

# Single optional argument: nothing offered past the first word
print -r -- vertex >! "$tmp/mode"
comp 3
(( ${#described} == 0 )) || fail "completion offered past first word: $described"

# Sourcing mode.zsh in a bare zsh WITHOUT compdef must exit 0: the real
# consumers (mlx-idle-watch.zsh, llm-proxy-watch.zsh, fleet-sync.zsh) do
# `source ... || exit/return 1`, and the compdef registration line is the
# file's last statement — a bare `(( $+functions[compdef] )) && compdef`
# there would leak a nonzero status and kill those scripts at startup.
# Runs in a subshell so the stub above stays for the other cases.
( unset -f compdef
  source "$repo/zsh/functions/claude/mode.zsh" ) ||
    fail 'sourcing mode.zsh without compdef must exit 0 (scripts gate on it)'

print 'PASS: claude-mode completion registers, matches accepted modes, tags current, stops at one arg'
