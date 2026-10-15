# ---------------------------------------------------------------------------
# codex mode switching: `codex` dispatches to the native Codex CLI or the
# EnMaaS gateway. Persisted in ~/.config/codex-mode so the choice survives
# across shells.

typeset -g _codex_mode_file="${XDG_CONFIG_HOME:-$HOME/.config}/codex-mode"

_codex_mode_get() {
    local mode=""
    [[ -r "$_codex_mode_file" ]] && IFS= read -r mode < "$_codex_mode_file"
    case "$mode" in
        native) print -r -- native ;;
        enmass) print -r -- enmass ;;
        *)      print -r -- native ;;
    esac
}

codex-mode() {
    if (( $# > 1 )); then
        echo "Usage: codex-mode [native|enmass]" >&2
        return 1
    fi
    case "$1" in
        native|enmass)
            if ! mkdir -p "${_codex_mode_file:h}" ||
               ! print -r -- "$1" >| "$_codex_mode_file"; then
                echo "❌ Failed to persist codex mode in ${_codex_mode_file}" >&2
                return 1
            fi
            echo "codex mode: $1"
            ;;
        "")
            echo "codex mode: $(_codex_mode_get)"
            echo "usage: codex-mode [native|enmass]"
            ;;
        *)
            echo "Usage: codex-mode [native|enmass]" >&2
            return 1
            ;;
    esac
}

codex-enmass() {
    emulate -L zsh
    local native="${CODEX_NATIVE_BINARY:-$(whence -p codex)}"

    if (( $# == 1 )) && [[ "$1" == --version || "$1" == --help || "$1" == -h ]]; then
        "$native" "$@"
        return
    fi

    if [[ -z "${ENMAAS_API_KEY:-}" ]]; then
        local credentials="${CLAUDE_PROVIDER_CREDENTIALS_FILE:-$HOME/secrets.zsh}"
        [[ -r "$credentials" ]] && source "$credentials" >/dev/null
    fi
    [[ -n "${ENMAAS_API_KEY:-}" ]] || {
        print -ru2 -- 'codex-enmass: ENMAAS_API_KEY is not set and no credential file provided it.'
        return 1
    }

    local base_url="${ENMAAS_API_BASE_URL:-https://api.enmaas.devshift.net/v1}"
    [[ "$base_url" == */v1 ]] || base_url="${base_url%/}/v1"
    local model="${CODEX_ENMASS_MODEL:-rits/zai-org/glm-5-3}"
    local effort="${CODEX_ENMASS_REASONING_EFFORT:-high}"

    "$native" \
        -c model_provider=enmaas \
        -c model_providers.enmaas.name=EnMaaS \
        -c model_providers.enmaas.base_url="$base_url" \
        -c model_providers.enmaas.env_key=ENMAAS_API_KEY \
        -c model_providers.enmaas.wire_api=responses \
        -c model_providers.enmaas.requires_openai_auth=false \
        -c model="$model" \
        -c model_reasoning_effort="$effort" \
        "$@"
}

# codex-glm-only: GLM for everything (auto-review included) through the local
# GLM hybrid proxy; see scripts/codex-provider.zsh (backend glm-only) for the
# wiring. Stop the shared proxy: codex-glm-only --stop-proxy
typeset -g _codex_provider_script="${${(%):-%x}:A:h:h:h}/scripts/codex-provider.zsh"
codex-glm-only() {
    CODEX_PROVIDER_NATIVE_BINARY="${CODEX_NATIVE_BINARY:-$(whence -p codex)}" \
        /bin/zsh -f "$_codex_provider_script" glm-only "$@"
}

unalias codex 2>/dev/null || true
function codex {
    local mode="$(_codex_mode_get)"
    echo "codex mode: ${mode} (switch: codex-mode native|enmass)" >&2
    case "$mode" in
        enmass) codex-enmass "$@" ;;
        *)      command codex "$@" ;;
    esac
}
