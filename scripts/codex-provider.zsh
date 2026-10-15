#!/bin/zsh -f
# Symlink as codex-t3-enmass, codex-t3-glm-hybrid or codex-t3-glm-only. Never load .zshrc.
#
# Executable launcher for apps (e.g. T3 Code) that need a binary path instead
# of an interactive shell function. Fixed backend per symlink, independent of
# claude-mode. Sources the credential file (CLAUDE_PROVIDER_CREDENTIALS_FILE,
# default ~/secrets.zsh, output suppressed) for ENMAAS_API_KEY, then the
# native Codex CLI (CODEX_PROVIDER_NATIVE_BINARY, default ~/.local/bin/codex)
# starts with its arguments unchanged. Provider, model, and reasoning wiring
# travels in T3's per-instance launchArgs as `-c` config overrides, the same
# mechanism T3's own managed Codex runtime uses.
#
# enmass: adds nothing but credentials. Codex talks to the gateway directly
# (Responses API); no local proxy.
#
# glm-hybrid: GLM on EnMaaS as the main model, an OpenAI model (default
# gpt-6-luna) as the auto-review model. Codex sends the auto-review request
# to the same model_provider as the main model, so both go through the local
# "codex" GLM hybrid LiteLLM proxy (scripts/glm-hybrid-proxy.zsh, port 4147),
# which routes by model id. Codex gets only the local proxy token as
# GLM_HYBRID_PROXY_TOKEN, never the upstream keys. Session exit leaves the
# proxy running; a changed config or key refuses to start until stopped:
#
# glm-only: GLM for everything, auto-review included; no OpenAI key needed.
# Same proxy; this launcher adds the provider wiring itself (-c overrides
# before the caller's arguments) and generates a GLM catalog entry from the
# Codex binary's bundled catalog (`codex debug models --bundled`, regenerated
# when the Codex version changes): auto_review_model_override = GLM,
# tool_mode direct, no hosted web search, text-only. apply_patch stays: the
# proxy hook strips the grammar EnMaaS's vLLM rejects. Interactive use:
# `codex-glm-only` (zsh/functions/codex.zsh).
#
#   codex-provider.zsh glm-hybrid --stop-proxy   (also glm-only; same proxy)
#   codex-t3-enmass --version   bypasses credentials entirely
emulate -L zsh
unsetopt xtrace verbose
typeset backend="${0:t}"
backend="${backend#codex-t3-}"
if [[ "$backend" == codex-provider.zsh ]]; then
    backend="${1-}"
    (( $# )) && shift
fi
case "$backend" in
    enmass|glm-hybrid|glm-only) ;;
    *) print -ru2 -- 'Usage: codex-provider.zsh <enmass|glm-hybrid|glm-only> [Codex arguments]'; exit 2 ;;
esac
typeset native="${CODEX_PROVIDER_NATIVE_BINARY:-$HOME/.local/bin/codex}"
[[ -x "$native" && "${native:A}" != "${0:A}" ]] || {
    print -ru2 -- 'codex-provider: native Codex executable is missing or points at the bridge.'
    exit 1
}
# T3's four-second version check must not source credentials or start services.
if (( $# == 1 )) && [[ "$1" == --version || "$1" == --help || "$1" == -h ]]; then
    exec "$native" "$@"
fi
typeset -U path
path=(/opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.bun/bin" $path)

source "${0:A:h}/glm-hybrid-proxy.zsh" || exit 1

if [[ "$backend" == glm-* && "${1-}" == --stop-proxy ]]; then
    _glm_hybrid_proxy_stop codex
    exit $?
fi

[[ -n "${ENMAAS_API_KEY-}" ]] || {
    typeset credentials="${CLAUDE_PROVIDER_CREDENTIALS_FILE:-$HOME/secrets.zsh}"
    [[ -r "$credentials" ]] && source "$credentials" >/dev/null
}
[[ -n "${ENMAAS_API_KEY-}" ]] || {
    print -ru2 -- 'codex-provider: ENMAAS_API_KEY is not set and no credential file provided it.'
    exit 1
}

if [[ "$backend" == enmass ]]; then
    export ENMAAS_API_KEY
    exec "$native" "$@"
fi

# glm-hybrid / glm-only
typeset need_review=''
[[ "$backend" == glm-hybrid ]] && need_review=review
_glm_hybrid_proxy_ensure codex $need_review || {
    [[ -f "$_ghp_runtime/fingerprint" ]] || exit 1
    print -ru2 -- "codex-provider: to restart it: codex-provider.zsh $backend --stop-proxy"
    exit 1
}
unset ENMAAS_API_KEY OPENAI_API_KEY
export GLM_HYBRID_PROXY_TOKEN="$_ghp_token"
[[ "$backend" == glm-hybrid ]] && exec "$native" "$@"

# glm-only: catalog from the bundled one, keyed on the Codex version.
typeset catalog="$_ghp_runtime/glm-only-models.json" version
version=$("$native" --version 2>/dev/null) || version=unknown
if [[ ! -s "$catalog" || "$(<"$catalog.version" 2>/dev/null)" != "$version" ]]; then
    "$native" debug models --bundled 2>/dev/null | jq --arg glm "$_ghp_glm" '
        [.models[] | select(.slug == "gpt-5.5")] + [.models[] | select(.visibility == "list")]
        | first // error("no bundled model to clone")
        | {models: [.slug = $glm | .display_name = "GLM 5.3"
            | .auto_review_model_override = $glm | .tool_mode = "direct"
            | .supports_search_tool = false | .input_modalities = ["text"]]}' \
        > "$catalog.tmp" && mv -f "$catalog.tmp" "$catalog" && print -r -- "$version" >| "$catalog.version" || {
        rm -f "$catalog.tmp"
        print -ru2 -- 'codex-provider: could not generate the GLM-only model catalog from `codex debug models --bundled`.'
        exit 1
    }
fi
typeset -a wiring=(
    -c model_provider=glmonly
    -c 'model_providers.glmonly.name="RH GLM Only"'
    -c "model_providers.glmonly.base_url=\"$_ghp_base/v1\""
    -c 'model_providers.glmonly.env_key="GLM_HYBRID_PROXY_TOKEN"'
    -c 'model_providers.glmonly.wire_api="responses"'
    -c model_providers.glmonly.requires_openai_auth=false
    -c "model_catalog_json=\"$catalog\""
    -c 'web_search="disabled"'
    -c "model=\"$_ghp_glm\""
)
# Overrides placed before a session subcommand are not applied to it (seen with
# `exec`, Codex 0.162.1), so put them right after it, where T3 puts its own
# launch args (`app-server <args>`, `exec <args>`). Bare/TUI use: in front.
case "${1-}" in
    exec|e|review|app-server|resume|fork) exec "$native" "$1" "${wiring[@]}" "${@:2}" ;;
    *) exec "$native" "${wiring[@]}" "$@" ;;
esac
