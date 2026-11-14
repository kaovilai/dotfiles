#!/bin/zsh -f
#
# Takes effect: see docs/notes/change-take-effect.md. Launcher logic applies on the NEXT codex launch (next T3
# turn); the generated model catalog regenerates when its shape hash changes.
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
# enmaas: all EnMaaS models through the shared local LiteLLM proxy that
# claude-enmaas uses (default 127.0.0.1:4146, CLAUDE_ENMAAS_PROXY_PORT; started on
# demand by _claude_enmaas_codex_proxy, zsh/functions/claude/providers/enmaas.zsh,
# which also documents its hooks). GPT/Gemini ids pass through as on the direct
# route; GLM and DeepSeek get the vLLM workarounds (grammar strip for apply_patch,
# empty developer item filter, thinking default, hosted web_search dropped, GLM
# image -> DeepSeek, 429 reset rewrite incl. x-codex-* headers). The launcher
# generates a Codex model catalog = the bundled one + GLM (text) + DeepSeek
# (text+image) entries (tool_mode direct, no search tool), regenerated when the
# Codex version or shape changes, and wires provider `enmaas` to the proxy with
# `-c` overrides right after the session subcommand. T3's launchArgs (the old
# direct-to-gateway provider keys) are filtered where they collide, everything
# else (review_model, approvals_reviewer, model_context_window, ...) stays.
# Codex gets only the proxy's local token as ENMAAS_API_KEY, never the gateway
# key. CODEX_ENMAAS_DIRECT=1 skips the proxy (old behavior: the caller's
# launchArgs talk to the gateway directly). A running proxy whose routes, hooks
# or key differ is never restarted under live sessions: stop it with
# claude-enmaas-kill. CODEX_ENMAAS_REVIEW_MODEL (default the DeepSeek id) is the
# auto_review model of the GLM/DeepSeek catalog entries.
#
# hosted-only: EnMaaS-hosted free models for everything, auto-review included
# (the retired "glm-hybrid" mode gave GLM an OpenAI reviewer; the fallback slot
# now does that job — Muse Spark Open since the 2026-11-14 pair swap). Models:
# DeepSeek V4.1 Flash (primary, the stronger coder) and
# Muse Spark Open (816B-A42B, multimodal, fallback + vision target), both 1M
# context, both served by the shared :4148 proxy (#599 merge: one
# LiteLLM, openai-dialect groups suffixed #openai, chosen by the pre-call hook;
# the catalog and wiring below keep the bare ids). Codex's guardian reuses the
# main model's provider with only the model swapped, so the reviewer
# (HOSTED_ONLY_REVIEW_MODEL, default the fallback slot, Muse Spark) must be a model the proxy routes
# too. Main model: HOSTED_ONLY_MODEL (default the primary slot, DeepSeek V4.1
# Flash; the slots keep their old names, see zsh/functions/claude/providers/
# hosted-only.zsh). Proxy
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

if [[ "$backend" == enmaas && "${CODEX_ENMAAS_DIRECT-}" == 1 ]]; then
    export ENMAAS_API_KEY
    exec "$native" "$@"
fi

if [[ "$backend" == enmaas ]]; then
    source "${0:A:h:h}/zsh/functions/claude/providers/enmaas.zsh" || exit 1
    typeset service token port glm_id ds_id
    service=$(_claude_enmaas_codex_proxy) || {
        print -ru2 -- 'codex-provider: EnMaaS proxy unavailable (claude-enmaas-kill stops a stale one; CODEX_ENMAAS_DIRECT=1 bypasses it).'
        exit 1
    }
    token=$(jq -er '.token' <<< "$service") && port=$(jq -er '.port' <<< "$service") \
        && glm_id=$(jq -er '.glm' <<< "$service") && ds_id=$(jq -er '.deepseek' <<< "$service") || exit 1
    typeset review="${CODEX_ENMAAS_REVIEW_MODEL:-$ds_id}"
    # With the proxy's web-search shim on (HOSTED_ONLY_SEARCH_SHIM), the
    # hosted web_search tool works again: Codex must offer it, or the shim is
    # dead code on this path (docs/notes/web-search-shim.md item 8).
    typeset -i shim="${HOSTED_ONLY_SEARCH_SHIM:-0}"
    typeset catalog_dir="${XDG_STATE_HOME:-$HOME/.local/state}/codex-enmaas"
    typeset catalog="$catalog_dir/models.json" version shape
    mkdir -p "$catalog_dir" && chmod 700 "$catalog_dir" || exit 1
    version=$("$native" --version 2>/dev/null) || version=unknown
    # shape2 (2026-11-14): the shape must change when entry CONTENT changes,
    # not just the ids — a catalog generated between the pair-swap revision
    # that mislabeled the EnMaaS entries and its revert carried the same
    # shape1 inputs, so it would never have regenerated.
    shape="$version|shape2|$glm_id|$ds_id|$review|$shim"
    if [[ ! -s "$catalog" || "$(<"$catalog.version" 2>/dev/null)" != "$shape" ]]; then
        "$native" debug models --bundled 2>/dev/null | jq --arg glm "$glm_id" --arg ds "$ds_id" --arg review "$review" \
            --argjson shim "$shim" '
            ([.models[] | select(.slug == "gpt-5.5")] + [.models[] | select(.visibility == "list")]
                | first // error("no bundled model to clone")) as $base
            | def hosted: .auto_review_model_override = $review | .tool_mode = "direct"
                | .supports_search_tool = ($shim == 1) | .upgrade = null;
            {models: ([.models[] | select(.slug != $glm and .slug != $ds)] + [
                ($base | hosted | .slug = $glm | .display_name = "GLM 5.3" | .priority = 13
                    | .input_modalities = ["text"] | .context_window = 1048576 | .max_context_window = 1048576),
                ($base | hosted | .slug = $ds | .display_name = "DeepSeek V4.1 Flash" | .priority = 14
                    | .input_modalities = ["text", "image"] | .context_window = 1048576 | .max_context_window = 1048576)])}' \
            > "$catalog.tmp" && mv -f "$catalog.tmp" "$catalog" && print -r -- "$shape" >| "$catalog.version" || {
            rm -f "$catalog.tmp"
            print -ru2 -- 'codex-provider: could not generate the EnMaaS model catalog from `codex debug models --bundled`.'
            exit 1
        }
    fi
    # Codex's key for the provider is the proxy's local token, not the gateway key.
    export ENMAAS_API_KEY="$token"
    # Hosted rits/* models have no server-side web search (vLLM ignores it).
    # Hook ~/.claude/hooks/nudge-web-search-via-luna.sh reads this route.
    export T3_WEB_SEARCH_DELEGATE="codex_rh_codex_api:gpt-5.6-luna"
    # Web search for the search-less gateway upstream: the Parallel MCP (same
    # registration the Claude flavors get; empty URL disables).
    typeset search_mcp_url="${ENMAAS_SEARCH_MCP_URL-https://mcp.parallel.ai/mcp}"
    [[ -n "$search_mcp_url" ]] && export T3_WEB_SEARCH_MCP="parallel"
    typeset -a wiring=(
        -c model_provider=enmaas
        -c 'model_providers.enmaas.name="EnMaaS"'
        -c "model_providers.enmaas.base_url=\"http://127.0.0.1:$port/v1\""
        -c 'model_providers.enmaas.env_key="ENMAAS_API_KEY"'
        -c 'model_providers.enmaas.wire_api="responses"'
        -c model_providers.enmaas.requires_openai_auth=false
        -c "model_catalog_json=\"$catalog\""
    )
    [[ -n "$search_mcp_url" ]] && wiring+=(-c "mcp_servers.parallel.url=\"$search_mcp_url\"")
    # Drop the caller's -c/--config overrides of the keys wired above (T3's
    # launchArgs point the provider straight at the gateway), then put ours in.
    typeset -a rest=() kept=()
    typeset sub="${1-}" arg key i
    case "$sub" in
        exec|e|review|app-server|resume|fork) shift ;;
        *) sub= ;;
    esac
    rest=("$@")
    typeset -i skip
    for (( i = 1; i <= $#rest; i++ )); do
        arg="${rest[i]}" skip=0
        case "$arg" in
            -c|--config) (( i < $#rest )) && { key="${rest[i+1]%%=*}"; skip=2; } ;;
            --config=*) key="${${arg#--config=}%%=*}"; skip=1 ;;
            -c=*) key="${${arg#-c=}%%=*}"; skip=1 ;;
        esac
        if (( skip )) && [[ "$key" == (model_provider|model_catalog_json|model_providers.enmaas.*) ]]; then
            (( i += skip - 1 ))
            continue
        fi
        kept+=("$arg")
    done
    if [[ -n "$sub" ]]; then
        exec "$native" "$sub" "${wiring[@]}" "${kept[@]}"
    fi
    exec "$native" "${wiring[@]}" "${kept[@]}"
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
# Fallback slot: the shared lib's _hop_deepseek, else its knob/default — the
# last resort must match the lib's default (Muse Spark Open), not the pre-swap
# one, or a taken chain would target an id the proxy no longer routes.
typeset ds="${_hop_deepseek:-${HOSTED_ONLY_DEEPSEEK_MODEL:-${GLM_HYBRID_DEEPSEEK_MODEL:-rits/meta-models/Muse-Spark-Open-816B-A42B-NVFP4}}}"
typeset reviewer="${HOSTED_ONLY_REVIEW_MODEL:-$ds}"
typeset main="${HOSTED_ONLY_MODEL:-$_hop_glm}"
# Both hosted models serve the same window on EnMaaS (vLLM max_model_len
# 1048576; verified 2026-11-05: GLM took 300k and 900k prompts, 1.1M answered
# 400 "maximum context length is 1048576 tokens").
# 1,000,000 (1M) leaves ~48k of output headroom: vLLM rejects input+max_tokens
# over its 1,048,576 window, and Codex would otherwise fill the window to the
# edge and fail the last turn.
# COUPLED to the Go proxy's clamp (scripts/hosted-only-go: MAX_MODEL_LEN, MIN_OUTPUT)
# and Claude Code's 128000 output cap (HOSTED_ONLY_MAX_OUTPUT_TOKENS): Codex
# compacts at its own share of THIS number; the proxy hook then trims max_tokens
# or answers a compaction-hint 400 near the real 1,048,576 edge. Change them together.
typeset -i glm_ctx="${HOSTED_ONLY_GLM_CONTEXT:-1000000}" ds_ctx="${HOSTED_ONLY_DEEPSEEK_CONTEXT:-1000000}"
# Web-search shim (docs/notes/web-search-shim.md item 8): when the proxy's
# HOSTED_ONLY_SEARCH_SHIM is on, Codex offers its global web_search and the
# proxy serves it; otherwise it stays disabled per-model.
typeset -i shim="${HOSTED_ONLY_SEARCH_SHIM:-0}"
if [[ "$reviewer" != "$_hop_glm" && "$reviewer" != "$ds" ]]; then
    print -ru2 -- "codex-provider: HOSTED_ONLY_REVIEW_MODEL must be $_hop_glm or $ds (the proxy routes only those)."
    exit 1
fi
typeset catalog="$_hop_runtime/hosted-only-models.json" version shape
version=$("$native" --version 2>/dev/null) || version=unknown
shape="$version|shape2|$_hop_glm|$ds|$reviewer|$glm_ctx|$ds_ctx|$shim"
if [[ ! -s "$catalog" || "$(<"$catalog.version" 2>/dev/null)" != "$shape" ]]; then
    "$native" debug models --bundled 2>/dev/null | jq --arg glm "$_hop_glm" --arg ds "$ds" \
        --arg review "$reviewer" --argjson gctx "$glm_ctx" --argjson dctx "$ds_ctx" --argjson shim "$shim" '
        [.models[] | select(.slug == "gpt-5.5")] + [.models[] | select(.visibility == "list")]
        | first // error("no bundled model to clone")
        | . as $base
        | def common: .auto_review_model_override = $review | .tool_mode = "direct"
            | .supports_search_tool = ($shim == 1) | .upgrade = null;
        {models: [
            ($base | common | .slug = $glm | .display_name = "DeepSeek V4.1 Flash" | .priority = 13
                | .input_modalities = ["text", "image"]
                | .context_window = $gctx | .max_context_window = $gctx),
            ($base | common | .slug = $ds | .display_name = "Muse Spark Open" | .priority = 14
                | .input_modalities = ["text", "image"]
                | .context_window = $dctx | .max_context_window = $dctx)]}' \
        > "$catalog.tmp" && mv -f "$catalog.tmp" "$catalog" && print -r -- "$shape" >| "$catalog.version" || {
        rm -f "$catalog.tmp"
        print -ru2 -- 'codex-provider: could not generate the hosted-only model catalog from `codex debug models --bundled`.'
        exit 1
    }
fi
# Hosted rits/* models have no server-side web search (vLLM ignores it).
# Hook ~/.claude/hooks/nudge-web-search-via-luna.sh reads this route.
export T3_WEB_SEARCH_DELEGATE="codex_rh_codex_api:gpt-5.6-luna"
# Hook ~/.claude/hooks/shrink-view-image.sh shrinks images to this many px
# (EnMaaS 413s on large request bodies).
export T3_IMAGE_MAX_PX=1000
# Web search for the search-less hosted upstream: the Parallel MCP (free, no
# auth; codex lists it as an HTTP server). Codex exposes its tools in-session;
# the proxy note and the nudge hook point at them via T3_WEB_SEARCH_MCP.
typeset search_mcp_url="${HOSTED_ONLY_SEARCH_MCP_URL-https://mcp.parallel.ai/mcp}"
[[ -n "$search_mcp_url" ]] && export T3_WEB_SEARCH_MCP="parallel"
typeset -a wiring=(
    -c model_provider=glmonly
    -c 'model_providers.glmonly.name="RH Hosted Only"'
    -c "model_providers.glmonly.base_url=\"$_hop_base/v1\""
    -c 'model_providers.glmonly.env_key="HOSTED_ONLY_PROXY_TOKEN"'
    -c 'model_providers.glmonly.wire_api="responses"'
    -c model_providers.glmonly.requires_openai_auth=false
    -c "model_catalog_json=\"$catalog\""
    -c "web_search=\"$(( shim ? 'enabled' : 'disabled' ))\""
)
[[ -n "$search_mcp_url" ]] && wiring+=(-c "mcp_servers.parallel.url=\"$search_mcp_url\"")
wiring+=(-c "model=\"$main\"")
# Overrides placed before a session subcommand are not applied to it (seen with
# `exec`, Codex 0.162.1), so put them right after it, where T3 puts its own
# launch args (`app-server <args>`, `exec <args>`). Bare/TUI use: in front.
case "${1-}" in
    exec|e|review|app-server|resume|fork) exec "$native" "$1" "${wiring[@]}" "${@:2}" ;;
    *) exec "$native" "${wiring[@]}" "$@" ;;
esac
