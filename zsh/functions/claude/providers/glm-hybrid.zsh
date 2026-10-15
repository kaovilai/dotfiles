# ---------------------------------------------------------------------------
# claude-glm-hybrid: GLM 5.3 on EnMaaS as the main model, an OpenAI model
# (default gpt-6-luna) as Claude Code's auto-mode classifier.
#
# Claude Code picks the auto-mode classifier from ANTHROPIC_DEFAULT_SONNET_MODEL
# (claude-sonnet-5-5 / claude-opus-5-5 ids are refused there) and sends it to
# the same ANTHROPIC_BASE_URL as the main model. The EnMaaS key only serves
# GLM, so the sonnet tier points at the review model and both go through the
# local "claude" GLM hybrid LiteLLM proxy (scripts/glm-hybrid-proxy.zsh, port
# 4148): GLM -> anthropic/ Messages on the EnMaaS root (same as claude-enmass),
# review model -> OpenAI. Every other tier, subagents (forced) and background
# small-fast calls stay on GLM; the picker lists GLM only.
# CLAUDE_CODE_AUTO_MODE_SERVER=0 keeps auto-mode review client-side, where
# the classifier model above applies.
#
# GLM_HYBRID_CLAUDE_CLASSIFIER_MODEL overrides the classifier (sonnet tier)
# without touching the shared proxy config; it must be a model the proxy
# routes (the review model or GLM). Set it to GLM for a GLM-only setup.
#
# Keys: ENMAAS_API_KEY (else ENMASS_API_KEY) and OPENAI_API_KEY / the Codex
# CLI's ~/.codex/auth.json, passed only to the proxy. Stop the proxy with
# claude-glm-hybrid-kill (identity-checked; only after sessions finish).
source "${${(%):-%x}:A:h:h:h:h:h}/scripts/glm-hybrid-proxy.zsh"

claude-glm-hybrid() (
    emulate -L zsh
    [[ -n "${ENMAAS_API_KEY-}" ]] || ENMAAS_API_KEY="${ENMASS_API_KEY-}"
    _glm_hybrid_proxy_ensure claude || {
        [[ -f "$_ghp_runtime/fingerprint" ]] && print -ru2 -- 'claude-glm-hybrid: to restart it: claude-glm-hybrid-kill'
        return 1
    }
    local glm="$_ghp_glm" review="${GLM_HYBRID_CLAUDE_CLASSIFIER_MODEL:-$_ghp_review}"
    local -a reply
    _claude_picker_args "fable=${glm}|GLM 5.3" "opus=${glm}|GLM 5.3" "haiku=${glm}|GLM 5.3"
    local settings='{}'
    (( ${#reply} )) && settings="$reply[2]"
    settings=$(jq -c --arg glm "$glm" '. + {
        apiKeyHelper: "",
        env: {ANTHROPIC_CUSTOM_HEADERS: "", CLAUDE_CODE_USE_VERTEX: "0", CLAUDE_CODE_USE_BEDROCK: "0",
          CLAUDE_CODE_USE_FOUNDRY: "0", CLAUDE_CODE_AUTO_MODE_SERVER: "0",
          ANTHROPIC_SMALL_FAST_MODEL: $glm, CLAUDE_CODE_SUBAGENT_MODEL: $glm,
          CLAUDE_CODE_SUBAGENT_MODEL_FORCE: "1", CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL: $glm},
        modelSettings: {($glm): {effortLevel: "medium"}}
      }' <<< "$settings") || return 1
    _claude_copilot_unset_env
    unset ENMAAS_API_KEY ENMASS_API_KEY OPENAI_API_KEY ANTHROPIC_FOUNDRY_API_KEY \
        ANTHROPIC_FOUNDRY_RESOURCE ANTHROPIC_FOUNDRY_BASE_URL CLAUDE_CODE_API_KEY_HELPER
    export ANTHROPIC_BASE_URL="$_ghp_base" ANTHROPIC_API_KEY='' ANTHROPIC_AUTH_TOKEN="$_ghp_token" \
        ANTHROPIC_MODEL="$glm" ANTHROPIC_DEFAULT_OPUS_MODEL="$glm" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="$review" ANTHROPIC_DEFAULT_HAIKU_MODEL="$glm" \
        ANTHROPIC_DEFAULT_FABLE_MODEL="$glm" CLAUDE_CODE_USE_VERTEX=0 \
        CLAUDE_CODE_USE_BEDROCK=0 CLAUDE_CODE_USE_FOUNDRY=0 ANTHROPIC_CUSTOM_HEADERS=''
    _claude_invoke --settings "$settings" "$@"
)

claude-glm-hybrid-kill() {
    _glm_hybrid_proxy_stop claude
}
