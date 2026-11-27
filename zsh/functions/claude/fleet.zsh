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
    local target
    target=$(jq -r --arg n "$1" '.hosts[] | select(.name == $n) | .ssh // empty' "$cfg" 2>/dev/null)
    if [[ -z $target ]]; then
        print -ru2 -- "claude-fleet: no fleet host named '$1' in $cfg"
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
        remote+=" ${(q)a}"
    done
    command ssh -t "$target" "$remote"
}

# Generate claude-<name> (and the short alias) for every fleet.json peer.
# Guarded per name so a peer colliding with a real function (claude-copilot
# etc.) never overwrites it.
() {
    emulate -L zsh
    local cfg="${LLM_USAGE_CONFIG_DIR:-$HOME/.config/llm-usage}/fleet.json"
    [[ -r $cfg ]] || return 0
    local -a names
    names=("${(@f)$(jq -r '.hosts[].name // empty' "$cfg" 2>/dev/null)}") || return 0
    (( $#names )) || return 0
    local name short
    for name in $names; do
        [[ $name == */* || -z $name ]] && continue
        if (( ! $+functions[claude-$name] )); then
            eval "claude-$name() { claude-fleet $name \"\$@\"; }"
        fi
        short=${name%%-*}
        if [[ -n $short && $short != $name ]] && (( ! $+functions[claude-$short] )); then
            eval "claude-$short() { claude-fleet $name \"\$@\"; }"
        fi
    done
}
