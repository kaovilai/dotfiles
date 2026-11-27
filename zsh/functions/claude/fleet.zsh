# claude-<fleet-name>: interactive Claude Code on a fleet peer, over ssh.
#
# Hosts come from the machine-local fleet.json (llm-usage's peer list — the
# dotfiles repo is public, hostnames are not; see scripts/fleet.json.example).
# Two functions are generated per host at shell startup: the full name
# (claude-ryzen-wsl) and the first token before its first dash (claude-ryzen),
# so short names work; peers without a dash get one function. The remote side
# runs `zsh -ic 'claude ...'`, so the peer's own mode dispatch (claude-mode)
# picks its provider and its local proxies — the same session as sitting at
# that machine. New peers appear after fleet.json changes on the next shell.
# Peers declared only via llm-usage's LLM_USAGE_FLEET env overrides get no
# launcher: fleet.json is the machine-local standing list the launchers
# mirror; env overrides are per-invocation llm-usage configuration.
#
# Usage: claude-ryzen [claude args...]   /   claude-spectre -c 'hi'   etc.
# Manual form: claude-fleet <fleet-name> [claude args...]

# Resolve one peer's ssh target from fleet.json; errors go to stderr.
_claude_fleet_target() {
    emulate -L zsh
    local cfg="${LLM_USAGE_CONFIG_DIR:-$HOME/.config/llm-usage}/fleet.json"
    if [[ ! -r $cfg ]]; then
        print -ru2 -- "claude-fleet: $cfg not readable (see scripts/fleet.json.example)"
        return 1
    fi
    # Surface the real error instead of misdiagnosing it as a missing host
    # (repo precedent: merge-claude-settings' jq check).
    if ! command -v jq >/dev/null 2>&1; then
        print -ru2 -- "claude-fleet: jq is required to read $cfg"
        return 1
    fi
    local target
    # Same predicate as generation/completion: a non-string .ssh (jq -r
    # prints numbers verbatim) must fail resolution, not reach ssh.
    # Count ENTRIES in jq, not output lines: one hand-edited entry with an
    # embedded newline in .ssh would otherwise masquerade as "ambiguous".
    # stderr stays separate: merging it with 2>&1 pollutes the output on
    # success; parse failures keep their own channel below.
    local result count target
    if ! result=$(jq -r --arg n "$1" \
        '[.hosts[] | select(.name == $n) | select((.ssh|type) == "string" and .ssh != "") | .ssh] | "\(length)\t\(.[0] // "")"' \
        "$cfg" 2>/dev/null); then
        print -ru2 -- "claude-fleet: cannot parse $cfg"
        return 1
    fi
    count=${result%%$'\t'*}
    target=${result#*$'\t'}
    if (( count > 1 )); then
        print -ru2 -- "claude-fleet: '$1' is ambiguous: $count entries share that name in $cfg"
        return 1
    fi
    if (( count == 0 )); then
        print -ru2 -- "claude-fleet: no fleet host named '$1' in $cfg"
        return 1
    fi
    # Any whitespace (a tab is the nasty one: invisible in the terminal)
    # makes an unconnectable target — refuse with a diagnosable message.
    if [[ $target == *[[:space:]]* ]]; then
        print -ru2 -- "claude-fleet: '$1' has an invalid ssh target containing whitespace in $cfg"
        return 1
    fi
    if [[ -z $target ]]; then
        print -ru2 -- "claude-fleet: no fleet host named '$1' in $cfg"
        return 1
    fi
    # A dash-prefixed target would be parsed by ssh as an option
    # (-oProxyCommand=... is code execution); fleet.json is agent-editable,
    # so validate like the name field.
    if [[ $target == -* ]]; then
        print -ru2 -- "claude-fleet: refusing dash-prefixed ssh target for '$1'"
        return 1
    fi
    REPLY=$target
}

claude-fleet() {
    emulate -L zsh
    local target
    _claude_fleet_target "$1" || return 1
    target=$REPLY
    shift
    # ssh joins its command args with spaces and the REMOTE login shell
    # re-parses the line, so quoting must be baked in here: one command
    # string, the -c script single-quoted, every user arg ${(q)}-escaped.
    # Remote: zsh -ic 'claude "$@"' claude-fleet <args...> — $0 is skipped,
    # the user's args arrive at the peer's claude dispatch intact.
    local remote="zsh -ic 'claude \"\$@\"' claude-fleet" a
    for a in "$@"; do
        # ${(qq)} single-quote style: ${(q)} backslash-escapes an embedded
        # newline, which the remote re-parse eats as a line continuation.
        remote+=" ${(qq)a}"
    done
    command ssh -t -- "$target" "$remote"
}

# Generate claude-<name> (and the short alias) for every fleet.json peer.
# Names are validated against a strict label pattern and the functions are
# created via the functions associative array (never eval): fleet.json is
# machine-local but agent-editable, and a crafted name must not parse as
# shell code. A peer colliding with a real function (claude-copilot etc.) is
# skipped.
_claude-fleet-generate() {
    emulate -L zsh
    # One-shot FIRST, before any early return: /dev/null sits ready at EOF
    # forever, so the handler fires on every zle idle until unregistered —
    # each firing would fork another jq. Closing also must not redirect the
    # SHELL's stderr: `exec {fd}>&-` has no command word, so a stray
    # 2>/dev/null there persists for the whole session (only zle -F, which
    # has one, may carry it).
    if [[ -n ${_CLAUDE_FLEET_FD-} ]]; then
        zle -F $_CLAUDE_FLEET_FD 2>/dev/null
        exec {_CLAUDE_FLEET_FD}>&-
        unset _CLAUDE_FLEET_FD
    fi
    local cfg="${LLM_USAGE_CONFIG_DIR:-$HOME/.config/llm-usage}/fleet.json"
    [[ -r $cfg ]] || return 0
    # Only connectable peers get launchers: the llm-usage fleet format also
    # carries local-state peers (no .ssh), and a hand-edited entry can carry
    # an empty or non-string .ssh — none of those can connect, and the
    # filter must match what _claude_fleet_target accepts (string, nonempty).
    local -a names
    # Name predicate mirrors _claude_fleet_target: string + label chars,
    # \z-anchored (Oniguruma's $ matches before a trailing newline, which
    # would make jq -r split the name into phantom peers).
    # Shared predicate with _claude_fleet_target: resolution also refuses
    # dash-prefixed targets and ambiguous (duplicate) names, so those get no
    # launcher either — the generated set stays the resolvable set.
    names=("${(@f)$(jq -r '.hosts | map(select((.ssh|type) == "string" and .ssh != "" and ((.ssh | startswith("-")) | not) and (.ssh | test("^[^[:space:]]+$"))) | select((.name|type) == "string" and (.name | test("^[A-Za-z0-9_-]+\\z")))) | group_by(.name) | map(select(length == 1) | .[0]) | .[] | .name' "$cfg" 2>/dev/null)}") || return 0
    (( $#names )) || return 0
    local name short
    # Pass 1 — full names; pass 2 — short aliases: a dashed peer earlier in
    # the file must not shadow a real peer whose full name IS the short form
    # (ryzen-wsl first would otherwise steal claude-ryzen from a later
    # "ryzen" peer).
    for name in $names; do
        [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || continue
        # Aliases parse-expand before functions can run: the repo ships
        # claude-sonnet & co as aliases, and a peer with that name would get
        # a silently dead launcher.
        if (( ! $+functions[claude-$name] && ! $+aliases[claude-$name]
              && ! $+commands[claude-$name] )); then
            functions[claude-$name]='claude-fleet '"${(q)name}"' "$@"'
        fi
    done
    for name in $names; do
        [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || continue
        short=${name%%-*}
        if [[ -n $short && $short != $name ]] &&
           (( ! $+functions[claude-$short] && ! $+aliases[claude-$short]
              && ! $+commands[claude-$short] )); then
            functions[claude-$short]='claude-fleet '"${(q)name}"' "$@"'
        fi
    done
}
# The generator's jq is the only subprocess fork in the claude load chain —
# the prompt stays fork-free. Interactive shells defer it to zle idle (the
# znap /dev/null-fd pattern: no fork, fires right after the first prompt
# draws; by then every real claude-* function AND alias is in scope, which
# is also what the collision guard wants). Non-interactive sources (tests,
# scripts) generate immediately.
# tty-stdin discriminates a real terminal (defer; a human cannot type
# claude-ryzen before zle idles) from scripted shells like `zsh -ic
# 'claude-ryzen ...'`, whose -c command runs BEFORE zle idle fires — those
# must generate immediately or the launcher does not exist yet.
if [[ -o interactive && -t 0 ]]; then
    zle -N _claude-fleet-generate
    # Re-source cleanup: unregister and close a pending fd; NO 2>/dev/null
    # on the bare exec (it would redirect the shell's stderr for the rest
    # of the session).
    if [[ -n ${_CLAUDE_FLEET_FD-} ]]; then
        zle -F $_CLAUDE_FLEET_FD 2>/dev/null
        exec {_CLAUDE_FLEET_FD}>&-
    fi
    exec {_CLAUDE_FLEET_FD}< /dev/null
    zle -F $_CLAUDE_FLEET_FD _claude-fleet-generate
else
    _claude-fleet-generate
fi

# "name:ssh" pairs for completion — ssh-backed peers only (the set
# claude-fleet can actually resolve), one jq pass, read live from
# fleet.json so edits show without a new shell. Separate helper so tests can
# assert on exactly what the completion would offer.
_claude_fleet_host_pairs() {
    emulate -L zsh
    # Same .ssh predicate as resolution, newline exclusion included: an
    # entry with an embedded newline in .ssh is refused at call time, so it
    # must not be offered by completion either (jq -r would split the pair).
    jq -r '.hosts | map(select((.ssh|type) == "string" and .ssh != "" and ((.ssh | startswith("-")) | not) and (.ssh | test("^[^[:space:]]+$"))) | select((.name|type) == "string" and (.name | test("^[A-Za-z0-9_-]+\\z")))) | group_by(.name) | map(select(length == 1) | .[0]) | .[] | "\(.name):\(.ssh)"' \
        "${LLM_USAGE_CONFIG_DIR:-$HOME/.config/llm-usage}/fleet.json" 2>/dev/null
}

# Completion: the generated claude-<name> commands complete as command names
# on their own (defined functions); claude-fleet's FIRST argument is a fleet
# host.
_claude-fleet() {
    # Hosts only complete the FIRST argument (CURRENT == 2 in zle terms,
    # same guard as _claude-mode); later words are remote claude args.
    (( CURRENT == 2 )) || return 0
    local -a descs
    descs=("${(@f)$(_claude_fleet_host_pairs)}")
    (( $#descs )) && _describe -t fleet-hosts 'fleet host' descs
}
# $+functions guard, same reason as mode.zsh: this file also loads in bare
# zsh scripts where compdef does not exist yet.
if (( $+functions[compdef] )); then
    compdef _claude-fleet claude-fleet
fi
