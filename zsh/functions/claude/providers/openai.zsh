# ---------------------------------------------------------------------------
# claude-openai: raw claude binary routed through OpenAI's API via a local
# LiteLLM proxy -- same reason as claude-vertex/claude-mlx: OpenAI doesn't
# speak Anthropic's /v1/messages shape, so litellm translates it. API key:
# $OPENAI_API_KEY, else Codex CLI's ~/.codex/auth.json (passed to the proxy
# at start; run claude-openai-kill after changing it). Three tiers map independently:
#   CLAUDE_OPENAI_FABLE_MODEL / _OPUS_MODEL / _SONNET_MODEL / _HAIKU_MODEL
# Unset tiers are detected (see _claude_openai_autopick): each tier's variant
# (CLAUDE_OPENAI_TIER_MAP, default fable=astra opus=sol sonnet=terra,sol
# haiku=luna) at the newest version the key can see.
typeset -g CLAUDE_OPENAI_PROXY_LITELLM_VERSION="1.97.0"
typeset -g CLAUDE_OPENAI_PROXY_FASTAPI_VERSION="0.136.3"
typeset -g _claude_openai_proxy_config="${XDG_CONFIG_HOME:-$HOME/.config}/claude-openai-proxy.yaml"

# Key lookup, same store as Codex CLI: $OPENAI_API_KEY, else the
# OPENAI_API_KEY field of ${CODEX_HOME:-~/.codex}/auth.json.
_claude_openai_key() {
    local key="$OPENAI_API_KEY" f="${CODEX_HOME:-$HOME/.codex}/auth.json"
    if [[ -z "$key" && -r "$f" ]] && command -v jq &>/dev/null; then
        key=$(jq -r '.OPENAI_API_KEY // empty' "$f" 2>/dev/null)
    fi
    [[ -n "$key" ]] || return 1
    print -r -- "$key"
}

# Chat-capable models from OpenAI's /v1/models as "id<TAB>created" lines,
# cached 6h (stale cache served if the API is unreachable). Filters out
# embeddings/audio/image/realtime/moderation/etc. -- not usable via Claude Code
# -- and dated snapshots (gpt-4-0613, ...-2025-08-07), whose undated alias is listed.
_claude_openai_list_models() {
    local key="$1" cache="${XDG_CACHE_HOME:-$HOME/.cache}/claude-openai-models-v2.tsv"
    if [[ ! -s "$cache" || -n "$(find "$cache" -mmin +360 2>/dev/null)" ]]; then
        local out
        out=$(curl -sf --max-time 10 -H "Authorization: Bearer ${key}" https://api.openai.com/v1/models 2>/dev/null \
            | jq -r '[.data[]
                | select(.id | test("^(gpt-|chatgpt-|o[0-9])"))
                | select(.id | test("audio|realtime|transcribe|tts|image|embedding|moderation|search|instruct|diarize"; "i") | not)
                | select(.id | test("-[0-9]{4}(-[0-9]{2}-[0-9]{2})?$|-[0-9]{8}$") | not)]
                | sort_by(.id)[] | "\(.id)\t\(.created // 0)"' 2>/dev/null)
        if [[ -n "$out" ]]; then
            mkdir -p "${cache:h}" && print -r -- "$out" >| "$cache"
        fi
    fi
    [[ -r "$cache" ]] && cat "$cache"
}

# Prints the proxy config (the caller writes it and fingerprints it).
# Per-tier picks from "id<TAB>created" lines on stdin. $1 = tier map,
# "tier=variant[,variant...] ..." (default CLAUDE_OPENAI_TIER_MAP, else
# "fable=astra opus=sol sonnet=terra,sol haiku=luna"); the VERSION is always
# detected, only the variant-to-tier mapping is configured.
#
# Why sonnet=terra,sol and not plain terra (checked 2026-10-08): Terra's newest
# model is gpt-5.6-terra at $2/$12 per Mtok (in/out), vs gpt-6.1-sol at $2/$10
# with near-Astra intelligence (Artificial Analysis: ~1 point under Astra,
# ~5 over 5.6 Sol) -- Sol is equal-or-cheaper AND smarter, and no GPT-6 Terra
# exists, so Terra sits two generations back. A list is a preference order:
# the winner is the alternative whose newest model has the highest MAJOR
# version, ties going to the earliest listed. So today sonnet resolves to Sol,
# and the moment a gpt-6-terra (same major as Sol) appears in the key's model
# list, Sonnet switches to Terra automatically. To force a variant regardless,
# set CLAUDE_OPENAI_SONNET_MODEL or a one-variant map entry (sonnet=terra).
#
# RE-EVALUATING THE MAP (for future maintainers/agents): the mapping assumes
# astra > sol > terra > luna in capability/price. Re-check when a new GPT
# generation ships, when prices change, or when a variant is added/renamed:
#   - What exists / is new: the key's own model list (GET /v1/models, cached by
#     _claude_openai_list_models) -- the source of truth for availability --
#     and https://platform.openai.com/docs/models
#   - Price (in/out per Mtok), machine-readable, no auth, and they agreed on
#     every GPT-6 model on 2026-10-08 (one-liners: jq '.["gpt-6.1-sol"] |
#     {input_cost_per_token, output_cost_per_token}' on the first; each
#     openrouter.ai model has .pricing.prompt/.completion per token):
#       https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json
#       https://openrouter.ai/api/v1/models        (ids are "openai/<id>")
#     Human-readable: https://platform.openai.com/docs/pricing
#     Beware stale secondary articles -- one cited Terra at $2.5/$15 after the
#     price had already dropped to $2/$12.
#   - Intelligence per cost: https://artificialanalysis.ai/leaderboards/models
#     (per-model pages like https://artificialanalysis.ai/models/gpt-6-1-sol
#     show the intelligence index, price and cost-to-run side by side).
#     openai.com announcement pages return 403 to scripts; use the above.
# Re-pick a tier's variant when another variant is equal-or-cheaper AND at
# least as capable at the same or newer generation (that is why Sol replaced
# Terra for Sonnet); flip it back when a same-generation Terra is cheaper per
# unit of intelligence than Sol.
#
# Each id is parsed as <family><version><rest> (gpt-6.1-sol -> gpt, 6.1,
# "-sol"); dated snapshots are skipped. A variant's newest model = highest
# version (component-wise, so 6.1 > 6 and 5.10 > 5.9), then newest `created`,
# then id. A tier with no matching variant falls back to the greatest-latest
# model overall. Prints one id per line in map order.
_claude_openai_autopick() {
    local map="${1:-${CLAUDE_OPENAI_TIER_MAP:-fable=astra opus=sol sonnet=terra,sol haiku=luna}}"
    jq -Rrn --arg map "$map" '
        [inputs | split("\t") | {id: .[0], created: ((.[1] // "0") | tonumber? // 0)}
         | . as $m
         | (.id | capture("^(?<f>[a-z]+)-?(?<v>[0-9]+(\\.[0-9]+)*)(?<rest>.*)$")?) as $c
         | select($c != null)
         | select($c.rest | test("(^|-)[0-9]{4}(-[0-9]{2}-[0-9]{2})?$|(^|-)[0-9]{8}$") | not)
         | {id: $m.id, rest: $c.rest, v: ($c.v | split(".") | map(tonumber)), created: $m.created}] as $all
        | ($all | sort_by([.v, .created, .id]) | last | .id // "") as $top
        | if $top == "" then empty else
            $map | split(" ") | map(select(length > 0) | split("=")[1] | split(",")) | .[]
            | . as $alts
            | ([$alts | to_entries[] | . as $a
                | ([$all[] | select(.rest == "-" + $a.value)] | sort_by([.v, .created, .id]) | last) as $w
                | select($w != null)
                | {idx: $a.key, major: $w.v[0], id: $w.id}]
               | sort_by([(.major * -1), .idx]) | first | .id) // $top
          end' 2>/dev/null
}

_claude_openai_proxy_config_text() {
    local master_key="$1"; shift
    local m
    {
        print -r -- "model_list:"
        # wildcard so any model id picked in /model routes to OpenAI, not
        # just the three pinned tiers
        print -r -- "  - model_name: \"*\""
        print -r -- "    litellm_params:"
        print -r -- "      model: openai/*"
        print -r -- "      api_key: os.environ/OPENAI_API_KEY"
        for m in "$@"; do
            print -r -- "  - model_name: ${m}"
            print -r -- "    litellm_params:"
            print -r -- "      model: openai/${m}"
            print -r -- "      api_key: os.environ/OPENAI_API_KEY"
        done
        print -r -- "litellm_settings:"
        print -r -- "  drop_params: true"
        print -r -- "  master_key: \"${master_key}\""
    }
}

# Hands results back via globals (_cop_*) -- zsh `local` doesn't cross
# function boundaries (same as _claude_mlx_prepare's _cmx_*).
_claude_openai_prepare() {
    local key
    key=$(_claude_openai_key) || {
        echo "❌ No OpenAI API key: set OPENAI_API_KEY or run 'codex login --with-api-key' (stored in ${CODEX_HOME:-$HOME/.codex}/auth.json)." >&2
        return 1
    }
    if ! command -v uv &>/dev/null; then
        echo "❌ uv not found. Install it with: $(_claude_pkg_install_hint uv 'curl -LsSf https://astral.sh/uv/install.sh | sh')" >&2
        return 1
    fi

    # Defaults: newest version of each tier's variant in the model list the
    # key can see (see _claude_openai_autopick); CLAUDE_OPENAI_*_MODEL overrides
    # per tier; gpt-5/gpt-5-mini only if the list is unreachable.
    local models_tsv picks
    local -a pick
    models_tsv=$(_claude_openai_list_models "$key")
    picks=$(print -r -- "$models_tsv" | _claude_openai_autopick)
    pick=("${(@f)picks}")
    local fable="${CLAUDE_OPENAI_FABLE_MODEL:-${pick[1]:-gpt-5}}"
    local opus="${CLAUDE_OPENAI_OPUS_MODEL:-${pick[2]:-gpt-5}}"
    local sonnet="${CLAUDE_OPENAI_SONNET_MODEL:-${pick[3]:-gpt-5}}"
    local haiku="${CLAUDE_OPENAI_HAIKU_MODEL:-${pick[4]:-gpt-5-mini}}"
    local port="${CLAUDE_OPENAI_PROXY_PORT:-4145}"
    local base="http://127.0.0.1:${port}"
    local log="${TMPDIR:-/tmp}/claude-openai-proxy-${port}.log"
    local master_key="${CLAUDE_OPENAI_PROXY_TOKEN:-openai-proxy-local}"

    # Hot reload -- see _claude_proxy_sync. A running proxy with no recorded
    # fingerprint (older version) is restarted (adopt=0).
    local -a models=(${(u)=:-$fable $opus $sonnet $haiku})
    local cfg fp
    cfg=$(_claude_openai_proxy_config_text "$master_key" "${models[@]}")
    fp=$(_claude_proxy_fp "$cfg" "$key" "$CLAUDE_OPENAI_PROXY_LITELLM_VERSION")
    _claude_proxy_sync claude-openai openai-proxy "${base}/health/liveliness" "$fp" claude-openai-kill 0 || return 1

    if ! curl -sf --max-time 2 "${base}/health/liveliness" -o /dev/null; then
        print -r -- "$cfg" > "$_claude_openai_proxy_config" || {
            echo "❌ Failed to write ${_claude_openai_proxy_config}." >&2
            return 1
        }
        echo "Starting claude-openai proxy (litellm ${CLAUDE_OPENAI_PROXY_LITELLM_VERSION}) on ${base} (log: ${log})..." >&2
        OPENAI_API_KEY="$key" _claude_proxy_start "$log" uv tool run --with "fastapi==${CLAUDE_OPENAI_PROXY_FASTAPI_VERSION}" \
            --from "litellm[proxy]==${CLAUDE_OPENAI_PROXY_LITELLM_VERSION}" litellm \
            --config "$_claude_openai_proxy_config" --port "$port" --host 127.0.0.1 || return 1
        local i
        for i in {1..60}; do
            curl -sf --max-time 2 "${base}/health/liveliness" -o /dev/null && break
            sleep 1
        done
        if ! curl -sf --max-time 2 "${base}/health/liveliness" -o /dev/null; then
            echo "❌ claude-openai proxy not ready on ${base} after 60s." >&2
            echo "   Check the log: tail -f ${log}" >&2
            return 1
        fi
        _claude_proxy_record openai-proxy "$fp"
    fi

    typeset -g _cop_base="$base" _cop_master_key="$master_key" \
        _cop_fable="$fable" _cop_opus="$opus" _cop_sonnet="$sonnet" _cop_haiku="$haiku"
    typeset -ga _cop_extras
    _cop_extras=(${(f)"$(print -r -- "$models_tsv" | cut -f1 | _claude_picker_extras)"})
}

# "[1m]" for models with a ~1M context window (GPT-6+: 1,050,000), else "".
# Claude Code reads the suffix to size its window; wrong on a smaller model
# means it never compacts before the API rejects the request.
_claude_openai_ctx_suffix() {
    [[ "${1#openai/}" =~ '^gpt-([6-9]|[1-9][0-9])([.-]|$)' ]] && print -rn -- '[1m]'
    return 0
}

claude-openai() {
    _claude_openai_prepare || return 1
    _claude_copilot_unset_env

    local -a envs
    envs=(
        ANTHROPIC_BASE_URL="${_cop_base}"
        ANTHROPIC_AUTH_TOKEN="${_cop_master_key}"
        ANTHROPIC_API_KEY=""
        ANTHROPIC_MODEL="${_cop_sonnet}$(_claude_openai_ctx_suffix "${_cop_sonnet}")"
        ANTHROPIC_DEFAULT_OPUS_MODEL="${_cop_opus}$(_claude_openai_ctx_suffix "${_cop_opus}")"
        ANTHROPIC_DEFAULT_SONNET_MODEL="${_cop_sonnet}$(_claude_openai_ctx_suffix "${_cop_sonnet}")"
        ANTHROPIC_DEFAULT_HAIKU_MODEL="${_cop_haiku}$(_claude_openai_ctx_suffix "${_cop_haiku}")"
        ANTHROPIC_DEFAULT_FABLE_MODEL="${_cop_fable}$(_claude_openai_ctx_suffix "${_cop_fable}")"
    )
    export "${envs[@]}"
    # "[1m]" (GPT-6+ only, see _claude_openai_ctx_suffix) makes Claude Code treat the window as ~1M;
    # it strips the suffix before the wire request, so the proxy still sees bare ids.
    _claude_picker_args fable="${_cop_fable}$(_claude_openai_ctx_suffix "${_cop_fable}")" opus="${_cop_opus}$(_claude_openai_ctx_suffix "${_cop_opus}")" sonnet="${_cop_sonnet}$(_claude_openai_ctx_suffix "${_cop_sonnet}")" haiku="${_cop_haiku}$(_claude_openai_ctx_suffix "${_cop_haiku}")" "${_cop_extras[@]}"
    _claude_invoke "${reply[@]}" "$@"
}

# claude-openai-kill: stop the litellm proxy claude-openai started.
claude-openai-kill() {
    local port="${CLAUDE_OPENAI_PROXY_PORT:-4145}" pids
    pids=("${(f)$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null)}")
    if [[ -z "${pids[1]}" ]]; then
        echo "No process listening on port ${port} (claude-openai proxy)."
        return 0
    fi
    echo "Killing claude-openai proxy on port ${port} (pid: ${pids[*]})..."
    kill "${pids[@]}" 2>/dev/null
    sleep 1
    pids=("${(f)$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null)}")
    [[ -n "${pids[1]}" ]] && kill -9 "${pids[@]}" 2>/dev/null
    return 0
}
