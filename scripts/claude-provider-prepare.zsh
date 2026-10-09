# Loaded by the bridge with /bin/zsh -f -c, with protocol arguments untouched.
claude-provider-prepare() {
    emulate -L zsh
    unsetopt xtrace verbose monitor
    local root="$1" backend="$2"; shift 2
    local credentials="${CLAUDE_PROVIDER_CREDENTIALS_FILE:-$HOME/secrets.zsh}"
    local profile="$CLAUDE_PROVIDER_PROFILE"
    # Remove a transport inherited from another provider before credential
    # bootstrap. Wrapper-specific model settings from the source still apply.
    unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY \
        ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
        ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL \
        CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_FOUNDRY
    if [[ -r "$credentials" ]]; then
        source "$credentials" >/dev/null 2>&1 || {
            print -ru2 -- 'claude-provider: credential bootstrap failed.'; return 1
        }
    elif [[ -n "${CLAUDE_PROVIDER_CREDENTIALS_FILE-}" ]]; then
        print -ru2 -- 'claude-provider: configured credential source is unreadable.'; return 1
    fi
    unsetopt xtrace verbose
    source "$root/zsh/paths.zsh"
    path=(/opt/homebrew/bin /usr/local/bin "$HOME/.bun/bin" $path)
    source "$root/zsh/functions/claude/load.zsh"
    export CLAUDE_PROVIDER_NO_RESTART=1
    export CLAUDE_PROVIDER_CAPTURE_SCRIPT="$root/scripts/claude-provider.py"
    export CLAUDE_PROVIDER_PROFILE="$profile"
    unset ANTHROPIC_API_KEY
    # Preserve T3's config directory even if the credential source sets one.
    if [[ "${CLAUDE_PROVIDER_CONFIG_DIR_PRESENT-}" == 1 ]]; then
        export CLAUDE_CONFIG_DIR="$CLAUDE_PROVIDER_CONFIG_DIR"
    fi
    # The final invocation becomes a secure preparation result. Inline settings
    # travel on stdin, not a subprocess command line; Claude's stdin is untouched.
    _claude_invoke() {
        local arg
        for arg in "$@"; do print -rn -- "$arg"$'\0'; done |
            python3 "$CLAUDE_PROVIDER_CAPTURE_SCRIPT" --capture "$CLAUDE_PROVIDER_PROFILE"
    }
    # Shared proxies must outlive cancellation of this preparation subprocess.
    _claude_proxy_start() {
        python3 "$CLAUDE_PROVIDER_CAPTURE_SCRIPT" --background "$@"
    }
    # A warm Vertex proxy already has its configured tier inventory. Reuse it
    # instead of letting a temporarily unavailable Model Garden catalog select
    # fallback tiers and demand a restart of an otherwise healthy service.
    if [[ "$backend" == vertex ]]; then
        functions[_claude_provider_vertex_discover]="${functions[_claude_vertex_get_models]}"
        _claude_vertex_get_models() {
            local inventory opus sonnet haiku
            inventory=$(
                print -r -- "header = $(print -rn -- "Authorization: Bearer ${CLAUDE_VERTEX_PROXY_TOKEN:-vertex-proxy-local}" | jq -Rs .)" |
                    command curl --silent --fail --max-time 2 --config - \
                        "http://127.0.0.1:${CLAUDE_VERTEX_PROXY_PORT:-4142}/v1/models" 2>/dev/null
            )
            if [[ -n "$inventory" ]]; then
                opus=$(_claude_copilot_latest_model opus "$inventory")
                sonnet=$(_claude_copilot_latest_model sonnet "$inventory")
                haiku=$(_claude_copilot_latest_model haiku "$inventory")
                if [[ -n "$opus" && -n "$sonnet" && -n "$haiku" ]]; then
                    print -r -- "$opus $sonnet $haiku"
                    return 0
                fi
            fi
            _claude_provider_vertex_discover "$@"
        }
    fi
    # Cache credential-free catalog data briefly so the three EnMaaS inventories
    # don't consume every SDK initialization probe's deadline.
    if [[ "$backend" == enmass ]]; then
        if [[ "${CLAUDE_PROVIDER_PREPARATION_ONLY-}" != 1 ]]; then
            export CLAUDE_ENMASS_DISCOVERY_TIMEOUT="${CLAUDE_ENMASS_DISCOVERY_TIMEOUT:-6}"
            export CLAUDE_ENMASS_DISCOVERY_RETRIES="${CLAUDE_ENMASS_DISCOVERY_RETRIES:-0}"
        fi
        functions[_claude_provider_enmass_discover]="${functions[_claude_enmass_discover]}"
        _claude_enmass_discover() {
            local identity catalog
            identity=$(_claude_proxy_fp "$@")
            if catalog=$(python3 "$CLAUDE_PROVIDER_CAPTURE_SCRIPT" --catalog-read "$identity"); then
                print -r -- "$catalog"
                return 0
            fi
            catalog=$(_claude_provider_enmass_discover "$@") || return $?
            print -rn -- "$catalog" |
                python3 "$CLAUDE_PROVIDER_CAPTURE_SCRIPT" --catalog-write "$identity" || return 1
            print -r -- "$catalog"
        }
    fi
    "claude-${backend}" "$@"
}
