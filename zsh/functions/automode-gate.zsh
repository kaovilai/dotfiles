# automode-gate: deterministic-first-line tool for Claude Code auto mode
# (shadow logging + curation). Engine: ~/.claude/hooks/automode-gate — see its
# header for the full design. The shell wrapper only adds tab completion and a
# short help; everything runs in the engine.
#
# Usage: automode-gate [top [days] [min]] | allow-add 'Bash(...)' |
#                     allow-list [prefix] | allow-remove 'Bash(...)' |
#                     test < hook-json-on-stdin | report-json < hook-json
automode-gate() {
    local gate="${XDG_CONFIG_HOME:-$HOME/.config}/claude/hooks/automode-gate"
    if [[ ! -r "$gate" ]]; then
        echo "automode-gate: engine missing at $gate (git -C ~/.claude pull)" >&2
        return 1
    fi
    python3 "$gate" "$@"
}

_automode-gate() {
    local -a subcmds
    subcmds=(
        'top:pattern counts by requests (days min args), with allow-add candidates'
        'allow-add:add a permissions.allow rule, e.g. Bash(git status:*)'
        'allow-list:list permissions.allow entries (optional prefix)'
        'allow-remove:remove a permissions.allow rule'
        'test:decide one hook-JSON payload from stdin, no logging'
    )
    _arguments -C \
        '1:subcommand:->sub' \
        '*::arg:->args'
    case $state in
        sub) _describe 'subcommand' subcmds ;;
        args)
            case $words[1] in
                allow-add|allow-remove)
                    # suggest existing rules on remove, a shape example on add
                    if [[ $words[1] == allow-remove ]]; then
                        local -a rules
                        rules=(${(f)"$(automode-gate allow-list 2>/dev/null)"})
                        _describe 'rule' rules
                    else
                        _values 'rule' 'Bash(git status:*)' 'Bash(git diff:*)' 'Bash(go test:*)' 'Bash(ls:*)'
                    fi
                    ;;
                top) _message 'days (default 7)' ;;
            esac
            ;;
    esac
}
compdef _automode-gate automode-gate
