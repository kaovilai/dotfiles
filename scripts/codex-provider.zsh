#!/bin/zsh -f
# Symlink as codex-t3-enmaas or codex-t3-hosted-only (codex-t3-glm-hybrid and
# codex-t3-glm-only = retired names, compat aliases of hosted-only). Never load
# .zshrc.
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
# enmaas: adds nothing but credentials. Codex talks to the gateway directly
# (Responses API); no local proxy.
#
# hosted-only: EnMaaS-hosted free models for everything, auto-review included
# (the retired "glm-hybrid" mode gave GLM an OpenAI reviewer; DeepSeek now does
# that job). Models: GLM 5.3 (text-only) and DeepSeek V4.1 Flash
# (1M context, vision), both served by the same :4147 proxy (route per model
# id). Codex's guardian reuses the main model's provider with only the model
# swapped, so the reviewer (HOSTED_ONLY_REVIEW_MODEL, default DeepSeek) must be a
# model the proxy routes too. Main model: HOSTED_ONLY_MODEL (default GLM). Proxy
# + upstream knobs: scripts/hosted-only-proxy.zsh (old GLM_HYBRID_* names still read).
# Codex gets only the local proxy token as HOSTED_ONLY_PROXY_TOKEN, never the
# upstream key. Session exit leaves the proxy running; a changed config or key
# refuses to start until it is stopped.
# This launcher adds the provider wiring itself (-c overrides before the
# caller's arguments) and generates a two-entry catalog
# from the Codex binary's bundled catalog (`codex debug models --bundled`,
# regenerated when the Codex version or catalog shape changes): every entry
# auto_review_model_override = reviewer, tool_mode direct, no search tool.
# apply_patch stays: the proxy hook strips the grammar EnMaaS's vLLM rejects.
# Hosted web_search is disabled (both models are vLLM-served). Interactive use:
# `codex-hosted-only` (zsh/functions/codex.zsh).
#
#   codex-provider.zsh hosted-only --stop-proxy
#   codex-t3-enmaas --version   bypasses credentials entirely
emulate -L zsh
unsetopt xtrace verbose
typeset backend="${0:t}"
backend="${backend#codex-t3-}"
if [[ "$backend" == codex-provider.zsh ]]; then
    backend="${1-}"
    (( $# )) && shift
fi
[[ "$backend" == enmass ]] && backend=enmaas   # pre-rename launcher name
[[ "$backend" == glm-only || "$backend" == glm-hybrid || "$backend" == hybrid ]] && backend=hosted-only   # retired launcher names
case "$backend" in
    enmaas|hosted-only) ;;
    *) print -ru2 -- 'Usage: codex-provider.zsh <enmaas|hosted-only> [Codex arguments]'; exit 2 ;;
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

source "${0:A:h}/hosted-only-proxy.zsh" || exit 1

if [[ "$backend" != enmaas && "${1-}" == --stop-proxy ]]; then
    _hosted_only_proxy_stop codex
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

if [[ "$backend" == enmaas ]]; then
    export ENMAAS_API_KEY
    exec "$native" "$@"
fi

# hosted-only
_hosted_only_proxy_ensure codex || {
    _hosted_only_proxy_has_state || exit 1
    print -ru2 -- "codex-provider: to restart it: codex-provider.zsh hosted-only --stop-proxy"
    exit 1
}
unset ENMAAS_API_KEY OPENAI_API_KEY
export HOSTED_ONLY_PROXY_TOKEN="$_hop_token"

# hosted-only: catalog from the bundled one, keyed on Codex version + shape.
# DeepSeek id: the shared lib's _hop_deepseek, else its knob/default.
typeset ds="${_hop_deepseek:-${HOSTED_ONLY_DEEPSEEK_MODEL:-${GLM_HYBRID_DEEPSEEK_MODEL:-rits/deepseek-ai/DeepSeek-V4.1-Flash-1017}}}"
typeset reviewer="${HOSTED_ONLY_REVIEW_MODEL:-$ds}"
typeset main="${HOSTED_ONLY_MODEL:-$_hop_glm}"
typeset -i glm_ctx="${HOSTED_ONLY_GLM_CONTEXT:-272000}" ds_ctx="${HOSTED_ONLY_DEEPSEEK_CONTEXT:-1048576}"
if [[ "$reviewer" != "$_hop_glm" && "$reviewer" != "$ds" ]]; then
    print -ru2 -- "codex-provider: HOSTED_ONLY_REVIEW_MODEL must be $_hop_glm or $ds (the proxy routes only those)."
    exit 1
fi
typeset catalog="$_hop_runtime/hosted-only-models.json" version shape
version=$("$native" --version 2>/dev/null) || version=unknown
shape="$version|shape2|$_hop_glm|$ds|$reviewer|$glm_ctx|$ds_ctx"
if [[ ! -s "$catalog" || "$(<"$catalog.version" 2>/dev/null)" != "$shape" ]]; then
    "$native" debug models --bundled 2>/dev/null | jq --arg glm "$_hop_glm" --arg ds "$ds" \
        --arg review "$reviewer" --argjson gctx "$glm_ctx" --argjson dctx "$ds_ctx" '
        [.models[] | select(.slug == "gpt-5.5")] + [.models[] | select(.visibility == "list")]
        | first // error("no bundled model to clone")
        | . as $base
        | def common: .auto_review_model_override = $review | .tool_mode = "direct"
            | .supports_search_tool = false | .upgrade = null;
        {models: [
            ($base | common | .slug = $glm | .display_name = "GLM 5.3" | .priority = 13
                | .input_modalities = ["text"]
                | .context_window = $gctx | .max_context_window = $gctx),
            ($base | common | .slug = $ds | .display_name = "DeepSeek V4.1 Flash" | .priority = 14
                | .input_modalities = ["text", "image"]
                | .context_window = $dctx | .max_context_window = $dctx)]}' \
        > "$catalog.tmp" && mv -f "$catalog.tmp" "$catalog" && print -r -- "$shape" >| "$catalog.version" || {
        rm -f "$catalog.tmp"
        print -ru2 -- 'codex-provider: could not generate the hosted-only model catalog from `codex debug models --bundled`.'
        exit 1
    }
fi
typeset -a wiring=(
    -c model_provider=glmonly
    -c 'model_providers.glmonly.name="RH Hosted Only"'
    -c "model_providers.glmonly.base_url=\"$_hop_base/v1\""
    -c 'model_providers.glmonly.env_key="HOSTED_ONLY_PROXY_TOKEN"'
    -c 'model_providers.glmonly.wire_api="responses"'
    -c model_providers.glmonly.requires_openai_auth=false
    -c "model_catalog_json=\"$catalog\""
    -c 'web_search="disabled"'
    -c "model=\"$main\""
)
# Overrides placed before a session subcommand are not applied to it (seen with
# `exec`, Codex 0.162.1), so put them right after it, where T3 puts its own
# launch args (`app-server <args>`, `exec <args>`). Bare/TUI use: in front.
case "${1-}" in
    exec|e|review|app-server|resume|fork) exec "$native" "$1" "${wiring[@]}" "${@:2}" ;;
    *) exec "$native" "${wiring[@]}" "$@" ;;
esac
