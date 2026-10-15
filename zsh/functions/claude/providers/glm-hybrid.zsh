# ---------------------------------------------------------------------------
# claude-glm-hybrid / claude-glm-only: GLM 5.3 on EnMaaS as the main model.
#   claude-glm-hybrid  auto-mode classifier on an OpenAI model (default
#                      gpt-6-luna; needs an OpenAI key)
#   claude-glm-only    GLM for everything, classifier included (no OpenAI key)
#
# Claude Code picks the auto-mode classifier from ANTHROPIC_DEFAULT_SONNET_MODEL
# (claude-sonnet-5-5 / claude-opus-5-5 ids are refused there) and sends it to
# the same ANTHROPIC_BASE_URL as the main model. GLM-only access (e.g. over the
# monthly EnMaaS budget) cannot reach Claude/GPT through EnMaaS, so both go
# through the local "claude" GLM hybrid LiteLLM proxy (scripts/glm-hybrid-proxy.zsh,
# port 4148): GLM -> anthropic/ Messages on the EnMaaS root (same as
# claude-enmaas), review model -> OpenAI. The proxy's hook cuts GLM's default
# reasoning on requests without a thinking field (GLM 5.3 is thinking-only:
# thinking disabled leaves ~one sentence of reasoning, not none); without it
# the classifier times out on GLM. Every other tier, subagents (forced) and
# background small-fast calls stay on GLM; the picker lists GLM only.
# CLAUDE_CODE_AUTO_MODE_SERVER=0 keeps auto-mode review client-side, where
# the classifier model above applies.
#
# Keys: ENMAAS_API_KEY and, for the hybrid, OPENAI_API_KEY / the Codex CLI's
# ~/.codex/auth.json, passed only to the proxy. Both share one proxy; stop it
# with claude-glm-hybrid-kill (= claude-glm-only-kill; identity-checked; only
# after sessions finish).
source "${${(%):-%x}:A:h:h:h:h:h}/scripts/glm-hybrid-proxy.zsh"

# _claude_glm_launch <hybrid|only> [Claude arguments]
_claude_glm_launch() (
    emulate -L zsh
    local variant="$1"; shift
    local need_review=''
    [[ "$variant" == hybrid ]] && need_review=review
    _glm_hybrid_proxy_ensure claude $need_review || {
        [[ -f "$_ghp_runtime/fingerprint" ]] && print -ru2 -- "claude-glm-$variant: to restart it: claude-glm-hybrid-kill"
        return 1
    }
    local glm="$_ghp_glm"
    # "[1m]" opts the unknown GLM id into a 1M window (EnMaaS: 1,000,000-token
    # context) and silences Claude Code's "isn't recognized · context assumed to
    # be 200k" warning; Claude Code strips it before the request, so the proxy
    # still sees the bare id. modelSettings keys use the bare id.
    local glm1m="${glm}[1m]" classifier="${glm}[1m]"
    [[ "$variant" == hybrid ]] && classifier="$_ghp_review"
    local -a reply
    _claude_picker_args "fable=${glm1m}|GLM 5.3" "opus=${glm1m}|GLM 5.3" "haiku=${glm1m}|GLM 5.3"
    local settings='{}'
    (( ${#reply} )) && settings="$reply[2]"
    settings=$(jq -c --arg glm "$glm" --arg glm1m "$glm1m" '. + {
        apiKeyHelper: "",
        env: {ANTHROPIC_CUSTOM_HEADERS: "", CLAUDE_CODE_USE_VERTEX: "0", CLAUDE_CODE_USE_BEDROCK: "0",
          CLAUDE_CODE_USE_FOUNDRY: "0", CLAUDE_CODE_AUTO_MODE_SERVER: "0",
          ANTHROPIC_SMALL_FAST_MODEL: $glm1m, CLAUDE_CODE_SUBAGENT_MODEL: $glm1m,
          CLAUDE_CODE_SUBAGENT_MODEL_FORCE: "1", CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL: $glm1m},
        modelSettings: {($glm): {effortLevel: "medium"}}
      }' <<< "$settings") || return 1
    _claude_copilot_unset_env
    unset ENMAAS_API_KEY OPENAI_API_KEY ANTHROPIC_FOUNDRY_API_KEY \
        ANTHROPIC_FOUNDRY_RESOURCE ANTHROPIC_FOUNDRY_BASE_URL CLAUDE_CODE_API_KEY_HELPER
    export ANTHROPIC_BASE_URL="$_ghp_base" ANTHROPIC_API_KEY='' ANTHROPIC_AUTH_TOKEN="$_ghp_token" \
        ANTHROPIC_MODEL="$glm1m" ANTHROPIC_DEFAULT_OPUS_MODEL="$glm1m" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="$classifier" ANTHROPIC_DEFAULT_HAIKU_MODEL="$glm1m" \
        ANTHROPIC_DEFAULT_FABLE_MODEL="$glm1m" CLAUDE_CODE_USE_VERTEX=0 \
        CLAUDE_CODE_USE_BEDROCK=0 CLAUDE_CODE_USE_FOUNDRY=0 ANTHROPIC_CUSTOM_HEADERS=''
    _claude_invoke --settings "$settings" "$@"
)

claude-glm-hybrid() { _claude_glm_launch hybrid "$@"; }
claude-glm-only() { _claude_glm_launch only "$@"; }

claude-glm-hybrid-kill() {
    _glm_hybrid_proxy_stop claude
}
claude-glm-only-kill() { claude-glm-hybrid-kill; }
