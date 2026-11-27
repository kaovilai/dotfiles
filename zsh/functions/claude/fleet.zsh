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
# Names are validated against a strict label pattern and the functions are
# created via the functions associative array (never eval): fleet.json is
# machine-local but agent-editable, and a crafted name must not parse as
# shell code. A peer colliding with a real function (claude-copilot etc.) is
# skipped.
() {
    emulate -L zsh
    local cfg="${LLM_USAGE_CONFIG_DIR:-$HOME/.config/llm-usage}/fleet.json"
    [[ -r $cfg ]] || return 0
    local -a names
    names=("${(@f)$(jq -r '.hosts[].name // empty' "$cfg" 2>/dev/null)}") || return 0
    (( $#names )) || return 0
    local name short
    for name in $names; do
        # [A-Za-z0-9_-] only — anything else (spaces, ;, $(), quotes) is a
        # skipped peer, never a function definition.
        [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || continue
        if (( ! $+functions[claude-$name] )); then
            functions[claude-$name]='claude-fleet '"${(q)name}"' "$@"'
        fi
        short=${name%%-*}
        if [[ -n $short && $short != $name ]] && (( ! $+functions[claude-$short] )); then
            functions[claude-$short]='claude-fleet '"${(q)name}"' "$@"'
        fi
    done
}

# Completion: the generated claude-<name> commands complete as command names
# on their own (defined functions); claude-fleet's FIRST argument is a fleet
# host, read live from fleet.json so edits show without a new shell.
_claude-fleet() {
    local -a hosts
    hosts=("${(@f)$(jq -r '.hosts[].name // empty' \
        "${LLM_USAGE_CONFIG_DIR:-$HOME/.config/llm-usage}/fleet.json" 2>/dev/null)}")
    # hosts as "name:description" pairs; ssh target is the useful description
    local -a descs
    local name target
    for name in $hosts; do
        target=$(jq -r --arg n "$name" '.hosts[] | select(.name == $n) | .ssh // empty' \
            "${LLM_USAGE_CONFIG_DIR:-$HOME/.config/llm-usage}/fleet.json" 2>/dev/null)
        descs+=("$name:${target:-$name}")
    done
    (( $#descs )) && _describe -t fleet-hosts 'fleet host' descs
}
# $+functions guard, same reason as mode.zsh: this file also loads in bare
# zsh scripts where compdef does not exist yet.
if (( $+functions[compdef] )); then
    compdef _claude-fleet claude-fleet
fi
