# ---------------------------------------------------------------------------
# claude mode switching: `claude` dispatches to the raw claude binary through
# a local LiteLLM proxy fronting Google Vertex AI's Claude models with
# Monitor tool support (vertex, DEFAULT), Claude Code's built-in
# CLAUDE_CODE_USE_VERTEX native integration with no Monitor support
# (vertex-native-adc), the copilot-api gateway (copilot), the EnMaaS gateway
# (enmaas), EnMaaS-hosted free models through the local hosted-only proxy
# (hosted-only), a local Ollama server (ollama), or an OpenShell-sandboxed
# invocation (openshell-*). Persisted in ~/.config/claude-mode so the choice
# survives across shells.

typeset -g _claude_mode_file="${XDG_CONFIG_HOME:-$HOME/.config}/claude-mode"

_claude_mode_get() {
    local mode=""
    [[ -r "$_claude_mode_file" ]] && IFS= read -r mode < "$_claude_mode_file"
    case "$mode" in
        copilot)           print -r -- copilot ;;
        enmaas|enmass)     print -r -- enmaas ;;   # "enmass" = pre-rename persisted value
        hosted-only)       print -r -- hosted-only ;;
        ollama)            print -r -- ollama ;;
        vertex-native-adc) print -r -- vertex-native-adc ;;
        openshell-copilot) print -r -- openshell-copilot ;;
        openshell-vertex)  print -r -- openshell-vertex ;;
        openshell-enmaas|openshell-enmass) print -r -- openshell-enmaas ;;
        openshell-openai)  print -r -- openshell-openai ;;
        # "vertex-proxy" is a pre-rename persisted value from before
        # claude-vertex() itself became the proxy-based default -- treat it
        # the same as "vertex" rather than erroring on an old config file.
        *)                 print -r -- vertex ;;   # missing/unknown fails safe to vertex
    esac
}

claude-mode() {
    if (( $# > 1 )); then
        echo "Usage: claude-mode [copilot|enmaas|hosted-only|vertex|vertex-native-adc|ollama|openshell-copilot|openshell-vertex|openshell-enmaas|openshell-openai]" >&2
        return 1
    fi
    # Pre-rename spellings are accepted and stored under the current name.
    local requested="${1/enmass/enmaas}"
    case "$requested" in
        copilot|enmaas|hosted-only|vertex|vertex-native-adc|ollama|openshell-copilot|openshell-vertex|openshell-enmaas|openshell-openai)
            # >| overrides NO_CLOBBER; fail loudly if persistence fails
            if ! mkdir -p "${_claude_mode_file:h}" ||
               ! print -r -- "$requested" >| "$_claude_mode_file"; then
                echo "❌ Failed to persist claude mode in ${_claude_mode_file}" >&2
                return 1
            fi
            echo "claude mode: $requested"
            # Shells still running pre-hosted-only mode.zsh read the persisted
            # value as unknown and fail safe to vertex (paid) -- reload them.
            # `if` (not `[[ ]] && echo`) so other modes still exit 0.
            if [[ "$requested" == hosted-only ]]; then
                echo "⚠️ reload older shells (exec zsh) before invoking claude there: pre-hosted-only shells dispatch this mode as vertex" >&2
            fi
            ;;
        "")
            echo "claude mode: $(_claude_mode_get)"
            echo "usage: claude-mode [copilot|enmaas|hosted-only|vertex|vertex-native-adc|ollama|openshell-copilot|openshell-vertex|openshell-enmaas|openshell-openai]"
            ;;
        *)
            echo "Usage: claude-mode [copilot|enmaas|hosted-only|vertex|vertex-native-adc|ollama|openshell-copilot|openshell-vertex|openshell-enmaas|openshell-openai]" >&2
            return 1
            ;;
    esac
}

# Guard for live shells still carrying an old claude→happy alias; `function`
# keyword form: the name is never alias-expanded (at parse time or under
# zcompile), so this definition is safe even if the guard misses.
unalias claude 2>/dev/null || true   # tolerate missing alias under ERR_EXIT
function claude {
    local mode="$(_claude_mode_get)"
    # stderr so piped/scripted output (e.g. claude -p) stays clean
    echo "claude mode: ${mode} (switch: claude-mode copilot|enmaas|hosted-only|vertex|vertex-native-adc|ollama|openshell-copilot|openshell-vertex|openshell-enmaas|openshell-openai)" >&2
    case "$mode" in
        copilot)           claude-copilot "$@" ;;
        enmaas)            claude-enmaas "$@" ;;
        hosted-only)       claude-hosted-only "$@" ;;
        ollama)            claude-ollama "$@" ;;
        vertex-native-adc) claude-vertex-native-adc "$@" ;;
        openshell-copilot) openshell-copilot "$@" ;;
        openshell-vertex)  openshell-vertex "$@" ;;
        openshell-enmaas)  openshell-enmaas "$@" ;;
        openshell-openai)  openshell-openai "$@" ;;
        *)                 claude-vertex "$@" ;;
    esac
}

# Tab completion for claude-mode: the first word is a mode from the case
# pattern above (pre-rename spellings like enmass are intentionally NOT
# suggested), the persisted choice is tagged so `claude-mode <TAB>` shows
# where you are. Keep the candidate list in sync with claude-mode()'s case
# pattern when adding a provider.
_claude-mode() {
    # one optional argument only — nothing to complete past the first word
    (( CURRENT == 2 )) || return 0
    local -a modes
    modes=(
        'copilot:copilot-api gateway'
        'enmaas:EnMaaS gateway'
        'hosted-only:EnMaaS-hosted free models through the local proxy'
        'vertex:local LiteLLM proxy fronting Vertex AI Claude (default)'
        'vertex-native-adc:native CLAUDE_CODE_USE_VERTEX integration'
        'ollama:local Ollama server'
        'openshell-copilot:OpenShell-sandboxed copilot'
        'openshell-vertex:OpenShell-sandboxed vertex'
        'openshell-enmaas:OpenShell-sandboxed enmaas'
        'openshell-openai:OpenShell-sandboxed openai'
    )
    local current i
    current="$(_claude_mode_get 2>/dev/null)"
    for i in {1..$#modes}; do
        [[ ${modes[i]%%:*} == "$current" ]] && modes[i]+=' [current]'
    done
    _describe -t modes 'claude mode' modes
}
# $+functions guard: mode.zsh is also sourced by offline tests in bare zsh,
# where compdef does not exist yet (znap defines it before load.zsh runs in
# real shells; plain compinit shells define it at compinit time).
(( $+functions[compdef] )) && compdef _claude-mode claude-mode
