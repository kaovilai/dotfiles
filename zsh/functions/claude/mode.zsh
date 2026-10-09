# ---------------------------------------------------------------------------
# claude mode switching: `claude` dispatches to the raw claude binary through
# a local LiteLLM proxy fronting Google Vertex AI's Claude models with
# Monitor tool support (vertex, DEFAULT), Claude Code's built-in
# CLAUDE_CODE_USE_VERTEX native integration with no Monitor support
# (vertex-native-adc), the copilot-api gateway (copilot), the EnMaaS gateway
# (enmass), or a local Ollama server (ollama). Persisted in ~/.config/claude-mode so the choice survives
# across shells.

typeset -g _claude_mode_file="${XDG_CONFIG_HOME:-$HOME/.config}/claude-mode"

_claude_mode_get() {
    local mode=""
    [[ -r "$_claude_mode_file" ]] && IFS= read -r mode < "$_claude_mode_file"
    case "$mode" in
        copilot)           print -r -- copilot ;;
        enmass)            print -r -- enmass ;;
        ollama)            print -r -- ollama ;;
        vertex-native-adc) print -r -- vertex-native-adc ;;
        # "vertex-proxy" is a pre-rename persisted value from before
        # claude-vertex() itself became the proxy-based default -- treat it
        # the same as "vertex" rather than erroring on an old config file.
        *)                 print -r -- vertex ;;   # missing/unknown fails safe to vertex
    esac
}

claude-mode() {
    if (( $# > 1 )); then
        echo "Usage: claude-mode [copilot|enmass|vertex|vertex-native-adc|ollama]" >&2
        return 1
    fi
    case "$1" in
        copilot|enmass|vertex|vertex-native-adc|ollama)
            # >| overrides NO_CLOBBER; fail loudly if persistence fails
            if ! mkdir -p "${_claude_mode_file:h}" ||
               ! print -r -- "$1" >| "$_claude_mode_file"; then
                echo "❌ Failed to persist claude mode in ${_claude_mode_file}" >&2
                return 1
            fi
            echo "claude mode: $1"
            ;;
        "")
            echo "claude mode: $(_claude_mode_get)"
            echo "usage: claude-mode [copilot|enmass|vertex|vertex-native-adc|ollama]"
            ;;
        *)
            echo "Usage: claude-mode [copilot|enmass|vertex|vertex-native-adc|ollama]" >&2
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
    echo "claude mode: ${mode} (switch: claude-mode copilot|enmass|vertex|vertex-native-adc|ollama)" >&2
    case "$mode" in
        copilot)           claude-copilot "$@" ;;
        enmass)            claude-enmass "$@" ;;
        ollama)            claude-ollama "$@" ;;
        vertex-native-adc) claude-vertex-native-adc "$@" ;;
        *)                 claude-vertex "$@" ;;
    esac
}
