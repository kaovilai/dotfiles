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
    # Legacy cleanup for sessions sourced before the cache rework: the old
    # zle-idle deferral registered a /dev/null fd that nothing unregisters
    # in this version — close it so it cannot re-fire the deleted handler.
    if [[ -n ${_CLAUDE_FLEET_FD-} ]]; then
        zle -F $_CLAUDE_FLEET_FD 2>/dev/null
        exec {_CLAUDE_FLEET_FD}>&-
        unset _CLAUDE_FLEET_FD
    fi
    local cfg="${LLM_USAGE_CONFIG_DIR:-$HOME/.config/llm-usage}/fleet.json"
    [[ -r $cfg ]] || return 0
    # ONE read of fleet.json feeds the jq filter, the cache snapshot and
    # the content check: separate reads could race an edit in between.
    local cfg_content="$(<$cfg)"
    # Cache, v2: ONE file — version line, a guarded launcher line for
    # EVERY candidate peer, and the fleet.json snapshot as a quoted
    # assignment — renamed in a single mv, so no interleave can pair
    # launchers with a foreign snapshot. Steady state is fork-free (builtin
    # reads only). The guards baked into each cached line re-evaluate on
    # every source: a collision present in this shell makes the line
    # inert, a collision that has disappeared lets it define the launcher
    # (self-healing).
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-provider/fleet"
    local cache="$cache_dir/launchers.zsh"
    local -r cache_version="# fleet-launchers cache v2"
    # Decide BEFORE sourcing: if the cache were sourced first, its
    # definitions would look like collisions to the generation guard below
    # and the rewritten cache would record only the delta — oscillating
    # forever on every fleet.json edit. The snapshot comparison is
    # marker-based, NOT line-based: a pretty-printed fleet.json embeds
    # newlines in the quoted snapshot value, so it spans many lines and a
    # last-line compare can never match (every shell would then fork jq
    # and rewrite). Strip everything through the LAST marker occurrence
    # (the marker line is always the file's final line) and compare the
    # remainder as a literal string.
    local -a cache_file_lines
    local _claude_fleet_cache_snapshot
    local cache_content snap_rest
    if [[ -r $cache ]] && cache_file_lines=("${(f)"$(<$cache)"}") \
       && [[ ${cache_file_lines[1]} == "$cache_version" ]]; then
        cache_content="$(<$cache)"
        snap_rest="${cache_content##*_claude_fleet_cache_snapshot=}"
        snap_rest="${snap_rest%$'\n'}"
        if [[ "$snap_rest" == "${(qq)cfg_content}" ]] && source "$cache"; then
            return 0
        fi
    fi
    # Only connectable peers get launchers: the llm-usage fleet format also
    # carries local-state peers (no .ssh), and a hand-edited entry can carry
    # an empty, non-string, whitespace-bearing or dash-prefixed .ssh — none
    # of those can connect, and the filter must match what
    # _claude_fleet_target accepts. Name predicate mirrors it too: string +
    # label chars, \z-anchored (Oniguruma's $ matches before a trailing
    # newline, which would make jq -r split the name into phantom peers),
    # duplicate names dropped (resolution refuses them as ambiguous).
    local -a names
    names=("${(@f)$(print -r -- "$cfg_content" | jq -r '.hosts | map(select((.ssh|type) == "string" and .ssh != "" and ((.ssh | startswith("-")) | not) and (.ssh | test("^[^[:space:]]+$"))) | select((.name|type) == "string" and (.name | test("^[A-Za-z0-9_-]+\\z")))) | group_by(.name) | map(select(length == 1) | .[0]) | .[] | .name' 2>/dev/null)}") || return 0
    (( $#names )) || return 0
    # Pass 1 — full names; pass 2 — short aliases: a dashed peer earlier in
    # the file must not shadow a real peer whose full name IS the short form
    # (ryzen-wsl first would otherwise steal claude-ryzen from a later
    # "ryzen" peer). Aliases parse-expand before functions can run and
    # functions shadow PATH commands, so both join functions in the guard.
    # The cache serializes a guarded line for EVERY candidate — including
    # names omitted here because of a live collision: the guard makes the
    # line inert where the collision exists and defines the launcher in a
    # later shell where it has gone, so a disappeared collision self-heals
    # on the next cache hit instead of regenerating (an omission-based
    # cache thrashed: each regeneration dropped the peer the previous
    # shell had just installed from the cached line).
    local -a cache_fns cache_fleets
    local name short
    for name in $names; do
        [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || continue
        # claude-t3-* launchers live in ~/.local/bin, which paths.zsh puts
        # on PATH AFTER this file runs — $+commands cannot see them yet,
        # and a function would shadow them. Skip the family by name.
        [[ $name == t3-* ]] && continue
        cache_fns+=("claude-$name") cache_fleets+=("${(q)name}")
        if (( ! $+functions[claude-$name] && ! $+aliases[claude-$name]
              && ! $+commands[claude-$name] )); then
            functions[claude-$name]='claude-fleet '"${(q)name}"' "$@"'
        fi
    done
    for name in $names; do
        [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || continue
        short=${name%%-*}
        if [[ -n $short && $short != $name ]] && [[ $name != t3-* ]]; then
            cache_fns+=("claude-$short") cache_fleets+=("${(q)name}")
            if (( ! $+functions[claude-$short] && ! $+aliases[claude-$short]
                  && ! $+commands[claude-$short] )); then
                functions[claude-$short]='claude-fleet '"${(q)name}"' "$@"'
            fi
        fi
    done
    # Cache write: 0700 dir (chmod'd — mkdir -m is a no-op on an existing
    # one), umask 077 BEFORE the redirection opens the temp file (peer
    # hostnames must never be world-readable, not even briefly), one temp
    # + one mv so the whole cache is atomic.
    if mkdir -m 700 -p "$cache_dir" 2>/dev/null || [[ -d $cache_dir ]]; then
        chmod 700 -- "$cache_dir" 2>/dev/null
        local i line
        # Raw string, NOT typeset -i: umask prints zero-padded octal, and
        # an integer re-parse turns "022" into octal 18 (bad umask on
        # restore); umask's own parser wants the leading-zero form.
        local old_umask=$(umask)
        umask 077
        {
            print -r -- "$cache_version"
            # {1..0} counts DOWN in zsh (1, 0) — guard the empty case or
            # two empty-subscript lines land in the cache.
            if (( $#cache_fns )); then
                for i in {1..$#cache_fns}; do
                    line="(( ! \$+functions[${cache_fns[i]}] && ! \$+aliases[${cache_fns[i]}] && ! \$+commands[${cache_fns[i]}] )) && functions[${cache_fns[i]}]='claude-fleet ${cache_fleets[i]} \"\$@\"'"
                    print -r -- "$line"
                done
            fi
            print -r -- "_claude_fleet_cache_snapshot=${(qq)cfg_content}"
        } > "$cache.tmp.$$"
        mv -f -- "$cache.tmp.$$" "$cache"
        umask $old_umask
    fi
    return 0
}
# Generate at source time in every context (see the cache note above).
_claude-fleet-generate

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
