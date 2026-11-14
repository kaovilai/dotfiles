# Takes effect: see docs/notes/change-take-effect.md. Launcher/settings logic applies on the NEXT claude launch
# (next T3 turn); the bridge exports the settings env into the client, so
# startup-read knobs (CLAUDE_CODE_MAX_OUTPUT_TOKENS) win there too.
# ---------------------------------------------------------------------------
# claude-hosted-only: EnMaaS-hosted free models only (DeepSeek V4.1 Flash
# main -- the stronger coder; Muse Spark Open selectable with --model
# rits/meta-models/Muse-Spark-Open-816B-A42B-NVFP4[1m], and the proxy's vision
# reroute sends image-carrying requests there).
# Retired names stay as aliases: claude-glm-hybrid, claude-glm-only (the old
# "hybrid" mode put the auto-mode classifier on an OpenAI model; DeepSeek now
# covers classifier and helpers, so no OpenAI key or route is used).
#
# Claude Code picks the auto-mode classifier from ANTHROPIC_DEFAULT_SONNET_MODEL
# (claude-sonnet-5-5 / claude-opus-5-5 ids are refused there) and sends it to
# the same ANTHROPIC_BASE_URL as the main model. Hosted-only access (e.g. over
# the monthly EnMaaS budget) cannot reach Claude/GPT through EnMaaS, so all
# models go through the local "claude" hosted-only Go proxy
# (scripts/hosted-only-proxy.zsh, port 4148): both slots -> anthropic/
# Messages on the EnMaaS root (same as claude-enmaas). The slots are named for
# the models they used to hold (2026-11-14 pair swap): "glm" = PRIMARY
# (DeepSeek V4.1 Flash), "deepseek" = FALLBACK + vision target (Muse Spark
# Open). Short-name knob values follow the SLOTS, not the names: a
# HOSTED_ONLY_*_MODEL=glm pin made before the swap now means DeepSeek Flash,
# and =deepseek means Muse Spark — pin a full id when the model must not move,
# but keep the two slots distinct: a pre-swap pin of the old fallback default
# (DEEPSEEK_MODEL=DeepSeek V4.1 Flash) now equals the primary, and a pair with
# one id in both slots has no outage fallback and no vision target (the
# launcher warns).
# The proxy's hook cuts reasoning on requests without a thinking field (the
# primary slot; Muse Spark reasons before every answer); without it the
# per-tool-call classifier calls get slow enough to stall a turn. It also sends
# primary-slot requests that contain an image to the fallback slot (Muse Spark,
# multimodal). Main model and the opus/haiku/fable tiers stay on the primary
# slot.
# Knobs: HOSTED_ONLY_CLASSIFIER_MODEL (sonnet tier = auto-mode classifier),
# HOSTED_ONLY_SMALL_FAST_MODEL and HOSTED_ONLY_SUBAGENT_MODEL (subagents,
# forced; workflow subagents too), all default the primary (DeepSeek V4.1
# Flash): the fast model, while Muse Spark reasons before every answer — the
# wrong latency profile for per-tool-call classification. Values: glm,
# deepseek, or an id.
# HOSTED_ONLY_CLIENT_MAX_RETRIES (default 3) sets CLAUDE_CODE_MAX_RETRIES (Claude
# Code default 10) — bounds retries of real 5xx errors. Rate-limit and outage
# answers arrive as 429 + retry-after: with CLAUDE_CODE_RETRY_WATCHDOG=1 (set
# below) Claude Code sleeps through any reset up to 6 h in-process instead of
# failing the turn, so per-minute limits and short outages no longer stall into
# an error at all; a month-end quota still fails fast (x-should-retry:false)
# for T3 to snooze on. Verified against claude 2.1.322
# (docs/notes/claude-code-429-503-handling.md).
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
    local -a picks=("fable=${glm1m}|DeepSeek V4.1 Flash" "opus=${glm1m}|DeepSeek V4.1 Flash" "haiku=${glm1m}|DeepSeek V4.1 Flash" "=${ds1m}|Muse Spark Open")   # Muse Spark: picker entry only, no tier
    local classifier small subagent
    # Auto-mode classification and the small/fast tier default to the PRIMARY
    # (DeepSeek Flash, the fast model, 2026-11-14): the classifier sees text
    # only, and Muse Spark always reasons before answering, which is the wrong
    # latency profile for a per-tool-call classification. A primary outage is
    # covered in-request by the proxy's pair fallback (classifier calls are
    # image-free and fail over to Muse Spark). Knobs override.
    classifier="$(_claude_hosted_ref "${HOSTED_ONLY_CLASSIFIER_MODEL:-$glm}" "$glm" "$ds")"
    small="$(_claude_hosted_ref "${HOSTED_ONLY_SMALL_FAST_MODEL:-$glm}" "$glm" "$ds")"
    # Subagents do the coding: the stronger coder, on the primary slot.
    subagent="$(_claude_hosted_ref "${HOSTED_ONLY_SUBAGENT_MODEL:-$glm}" "$glm" "$ds")"
    local -a reply
    _claude_picker_args "${picks[@]}"
    local settings='{}'
    (( ${#reply} )) && settings="$reply[2]"
    local max_retries="${HOSTED_ONLY_CLIENT_MAX_RETRIES:-${GLM_HYBRID_CLIENT_MAX_RETRIES:-3}}"
    # Claude Code caps one response at 32k output tokens by default and errors
    # ("exceeded the 32000 output token maximum") on a long tool call. The
    # hosted models take far more; the proxy clamps max_tokens at the window
    # edge, so a bigger budget is safe.
    # COUPLED to the Go proxy's clamp (scripts/hosted-only-go, MIN_OUTPUT, MAX_MODEL_LEN):
    # near the window edge the hook trims max_tokens, then refuses with a
    # compaction-hint 400. Changing this default means re-reading that block.
    local max_output="${HOSTED_ONLY_MAX_OUTPUT_TOKENS:-${GLM_HYBRID_MAX_OUTPUT_TOKENS:-128000}}"
    # Compaction window derived from the output cap: the client does not reserve
    # it, so without this the proxy trims max_tokens at the edge (see
    # _claude_auto_compact_window in common.zsh for the arithmetic and the
    # coupled settings). HOSTED_ONLY_AUTO_COMPACT_WINDOW=<n|off> overrides.
    local compact_window
    compact_window="$(_claude_auto_compact_window "$max_output" "${HOSTED_ONLY_AUTO_COMPACT_WINDOW-}")"
    # The hosted upstream (vLLM) has no server-side web search, so the session
    # gets one from the Parallel MCP instead (free, no auth; verified 2026-11-06:
    # web_search/web_fetch answer live queries). The proxy's strip-note and the
    # nudge hook route lookups there via T3_WEB_SEARCH_MCP; the paid delegate
    # stays as the fallback. Empty URL disables.
    local search_mcp_url="${HOSTED_ONLY_SEARCH_MCP_URL-https://mcp.parallel.ai/mcp}"
    settings=$(jq -c --arg glm "$glm" --arg ds "$ds" --arg small "$small" --arg sub "$subagent" --arg retries "$max_retries" --arg maxout "$max_output" --arg mcpurl "$search_mcp_url" '. + {
        apiKeyHelper: "",
        mcpServers: (if $mcpurl == "" then {} else {parallel: {type: "http", url: $mcpurl}} end),
        env: {ANTHROPIC_CUSTOM_HEADERS: "", CLAUDE_CODE_USE_VERTEX: "0", CLAUDE_CODE_USE_BEDROCK: "0",
          CLAUDE_CODE_USE_FOUNDRY: "0", CLAUDE_CODE_AUTO_MODE_SERVER: "0",
          CLAUDE_CODE_MAX_RETRIES: $retries, CLAUDE_CODE_RETRY_WATCHDOG: "1",
          CLAUDE_CODE_MAX_OUTPUT_TOKENS: $maxout,
          ANTHROPIC_SMALL_FAST_MODEL: $small, CLAUDE_CODE_SUBAGENT_MODEL: $sub,
          CLAUDE_CODE_SUBAGENT_MODEL_FORCE: "1", CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL: $sub},
        modelSettings: {($glm): {effortLevel: "high"}, ($ds): {effortLevel: "medium"}}
      }' <<< "$settings") || return 1
    # window derived above; absent when the knob says off
    [[ -n "$compact_window" ]] && settings=$(jq -c --arg cw "$compact_window" '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW = $cw' <<< "$settings")
    _claude_copilot_unset_env
    unset ENMAAS_API_KEY OPENAI_API_KEY ANTHROPIC_FOUNDRY_API_KEY \
        ANTHROPIC_FOUNDRY_RESOURCE ANTHROPIC_FOUNDRY_BASE_URL CLAUDE_CODE_API_KEY_HELPER
    export ANTHROPIC_BASE_URL="$_hop_base" ANTHROPIC_API_KEY='' ANTHROPIC_AUTH_TOKEN="$_hop_token" \
        ANTHROPIC_MODEL="$glm1m" ANTHROPIC_DEFAULT_OPUS_MODEL="$glm1m" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="$classifier" ANTHROPIC_DEFAULT_HAIKU_MODEL="$glm1m" \
        ANTHROPIC_DEFAULT_FABLE_MODEL="$glm1m" CLAUDE_CODE_USE_VERTEX=0 \
        CLAUDE_CODE_USE_BEDROCK=0 CLAUDE_CODE_USE_FOUNDRY=0 ANTHROPIC_CUSTOM_HEADERS=''
    # Hosted rits/* models have no server-side web search (vLLM ignores it).
    # Hook ~/.claude/hooks/nudge-web-search-via-luna.sh reads this route.
    export T3_WEB_SEARCH_DELEGATE="codex_rh_codex_api:gpt-5.6-luna"
    # Preferred search route: the Parallel MCP registered above. The hook and
    # the proxy's in-band note read this.
    [[ -n "$search_mcp_url" ]] && export T3_WEB_SEARCH_MCP="parallel"
    # Hook ~/.claude/hooks/shrink-view-image.sh shrinks images to this many px
    # (EnMaaS 413s on large request bodies).
    export T3_IMAGE_MAX_PX=1000
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
