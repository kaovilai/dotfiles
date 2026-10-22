# ---------------------------------------------------------------------------
# claude-hosted-only: EnMaaS-hosted free models only (GLM 5.3 main; DeepSeek
# V4.1 Flash selectable with --model rits/deepseek-ai/DeepSeek-V4.1-Flash-1017[1m]).
# Retired names stay as aliases: claude-glm-hybrid, claude-glm-only (the old
# "hybrid" mode put the auto-mode classifier on an OpenAI model; DeepSeek now
# covers classifier, helpers and vision, so no OpenAI key or route is used).
#
# Claude Code picks the auto-mode classifier from ANTHROPIC_DEFAULT_SONNET_MODEL
# (claude-sonnet-5-5 / claude-opus-5-5 ids are refused there) and sends it to
# the same ANTHROPIC_BASE_URL as the main model. Hosted-only access (e.g. over
# the monthly EnMaaS budget) cannot reach Claude/GPT through EnMaaS, so all
# models go through the local "claude" hosted-only LiteLLM proxy
# (scripts/hosted-only-proxy.zsh, port 4148): GLM and DeepSeek -> anthropic/
# Messages on the EnMaaS root (same as claude-enmaas).
# The proxy's hook cuts reasoning on requests without a thinking field (GLM 5.3
# is thinking-only: thinking disabled leaves ~one sentence of reasoning, not
# none); without it the classifier times out on GLM. It also sends GLM requests
# that contain an image (GLM 400s on any) to DeepSeek. Main model and the
# opus/haiku/fable tiers stay on GLM.
# Knobs: HOSTED_ONLY_CLASSIFIER_MODEL (sonnet tier = auto-mode classifier),
# HOSTED_ONLY_SMALL_FAST_MODEL and HOSTED_ONLY_SUBAGENT_MODEL (subagents,
# forced; workflow subagents too), all default DeepSeek: 2-4x faster than GLM,
# thinking:disabled removes its reasoning entirely, and it takes images, which
# subagents (screenshots, UI checks) may need
# (docs/notes/deepseek-v41-flash-vs-glm.md). Values: glm, deepseek, or an id.
# HOSTED_ONLY_CLIENT_MAX_RETRIES (default 3) sets CLAUDE_CODE_MAX_RETRIES (Claude
# Code default 10). Per-minute limits reach it as 503 + retry-after 60, which it
# sleeps through, so 10 retries stall a turn ~10 min before T3 sees the limit;
# 3 caps that near 3 min. It also bounds retries of real 5xx errors.
# CLAUDE_CODE_AUTO_MODE_SERVER=0 keeps auto-mode review client-side, where
# the classifier model above applies.
#
# Key: ENMAAS_API_KEY, passed only to the proxy. Stop it with
# claude-hosted-only-kill (identity-checked; only after sessions finish).
source "${${(%):-%x}:A:h:h:h:h:h}/scripts/hosted-only-proxy.zsh"

# _claude_hosted_launch [Claude arguments]
_claude_hosted_launch() (
    emulate -L zsh
    _hosted_only_proxy_ensure claude || {
        _hosted_only_proxy_has_state && print -ru2 -- "claude-hosted-only: to restart it: claude-hosted-only-kill"
        return 1
    }
    local glm="$_hop_glm" ds="$_hop_deepseek"
    # "[1m]" opts the unknown hosted ids into a 1M window (EnMaaS: 1,000,000-token
    # context) and silences Claude Code's "isn't recognized · context assumed to
    # be 200k" warning; Claude Code strips it before the request, so the proxy
    # still sees the bare id. modelSettings keys use the bare id.
    local glm1m="${glm}[1m]" ds1m="${ds}[1m]"
    local -a picks=("fable=${glm1m}|GLM 5.3" "opus=${glm1m}|GLM 5.3" "haiku=${glm1m}|GLM 5.3" "=${ds1m}|DeepSeek V4.1 Flash")   # DeepSeek: picker entry only, no tier
    local classifier small subagent
    classifier="$(_claude_hosted_ref "${HOSTED_ONLY_CLASSIFIER_MODEL:-$ds}" "$glm" "$ds")"
    small="$(_claude_hosted_ref "${HOSTED_ONLY_SMALL_FAST_MODEL:-$ds}" "$glm" "$ds")"
    subagent="$(_claude_hosted_ref "${HOSTED_ONLY_SUBAGENT_MODEL:-$ds}" "$glm" "$ds")"
    local -a reply
    _claude_picker_args "${picks[@]}"
    local settings='{}'
    (( ${#reply} )) && settings="$reply[2]"
    local max_retries="${HOSTED_ONLY_CLIENT_MAX_RETRIES:-${GLM_HYBRID_CLIENT_MAX_RETRIES:-3}}"
    settings=$(jq -c --arg glm "$glm" --arg ds "$ds" --arg small "$small" --arg sub "$subagent" --arg retries "$max_retries" '. + {
        apiKeyHelper: "",
        env: {ANTHROPIC_CUSTOM_HEADERS: "", CLAUDE_CODE_USE_VERTEX: "0", CLAUDE_CODE_USE_BEDROCK: "0",
          CLAUDE_CODE_USE_FOUNDRY: "0", CLAUDE_CODE_AUTO_MODE_SERVER: "0",
          CLAUDE_CODE_MAX_RETRIES: $retries,
          ANTHROPIC_SMALL_FAST_MODEL: $small, CLAUDE_CODE_SUBAGENT_MODEL: $sub,
          CLAUDE_CODE_SUBAGENT_MODEL_FORCE: "1", CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL: $sub},
        modelSettings: {($glm): {effortLevel: "medium"}, ($ds): {effortLevel: "medium"}}
      }' <<< "$settings") || return 1
    _claude_copilot_unset_env
    unset ENMAAS_API_KEY OPENAI_API_KEY ANTHROPIC_FOUNDRY_API_KEY \
        ANTHROPIC_FOUNDRY_RESOURCE ANTHROPIC_FOUNDRY_BASE_URL CLAUDE_CODE_API_KEY_HELPER
    export ANTHROPIC_BASE_URL="$_hop_base" ANTHROPIC_API_KEY='' ANTHROPIC_AUTH_TOKEN="$_hop_token" \
        ANTHROPIC_MODEL="$glm1m" ANTHROPIC_DEFAULT_OPUS_MODEL="$glm1m" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="$classifier" ANTHROPIC_DEFAULT_HAIKU_MODEL="$glm1m" \
        ANTHROPIC_DEFAULT_FABLE_MODEL="$glm1m" CLAUDE_CODE_USE_VERTEX=0 \
        CLAUDE_CODE_USE_BEDROCK=0 CLAUDE_CODE_USE_FOUNDRY=0 ANTHROPIC_CUSTOM_HEADERS=''
    _claude_invoke --settings "$settings" "$@"
)

# _claude_hosted_ref <glm|deepseek|id> <glm-id> <deepseek-id>: knob value ->
# "[1m]" model ref (short names glm / deepseek accepted).
_claude_hosted_ref() {
    case "$1" in
        glm) print -r -- "${2}[1m]" ;;
        deepseek) print -r -- "${3}[1m]" ;;
        *\[1m\]) print -r -- "$1" ;;
        *) print -r -- "${1}[1m]" ;;
    esac
}


# Retired names (hybrid / glm-only) and the stop helper.
claude-hosted-only() { _claude_hosted_launch "$@"; }
claude-glm-hybrid() { claude-hosted-only "$@"; }
claude-glm-only() { claude-hosted-only "$@"; }

claude-hosted-only-kill() { _hosted_only_proxy_stop claude; }
claude-glm-hybrid-kill() { claude-hosted-only-kill; }
claude-glm-only-kill() { claude-hosted-only-kill; }
