# ---------------------------------------------------------------------------
# claude-vertex-native-adc: raw claude binary, routed through Google Vertex
# AI via Claude Code's own built-in CLAUDE_CODE_USE_VERTEX integration — no
# local gateway process, Claude Code talks to Vertex directly. Requires
# CLOUD_ML_REGION and ANTHROPIC_VERTEX_PROJECT_ID already exported in the
# shell (same vars computer-use-claude/cecon/claude-container use elsewhere
# in this repo) and gcloud ADC set up (`gcloud auth application-default
# login`).
#
# Trade-off vs. claude-vertex() (the default, proxy-based path below):
# Monitor tool (https://code.claude.com/docs/en/tools-reference#monitor-tool)
# is unconditionally unavailable whenever CLAUDE_CODE_USE_VERTEX is set — no
# override flag exists, per the docs. Use this native-ADC path only when you
# specifically don't want the local litellm proxy dependency (e.g. no `uv`
# available, or troubleshooting whether an issue is proxy-side) and don't
# need Monitor.
claude-vertex-native-adc() {
    if [[ -z "$CLOUD_ML_REGION" || -z "$ANTHROPIC_VERTEX_PROJECT_ID" ]]; then
        echo "❌ CLOUD_ML_REGION and ANTHROPIC_VERTEX_PROJECT_ID must be exported to use Vertex AI." >&2
        return 1
    fi
    _claude_copilot_unset_env
    # Subshell scopes CLAUDE_CODE_USE_VERTEX (and the re-exports below) to this
    # one invocation only — parent shell's env is untouched once claude exits.
    (
        export CLAUDE_CODE_USE_VERTEX=1
        export CLOUD_ML_REGION ANTHROPIC_VERTEX_PROJECT_ID
        [[ -n "$ANTHROPIC_VERTEX_BASE_URL" ]] && export ANTHROPIC_VERTEX_BASE_URL
        export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-sonnet-5[1m]}"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="${ANTHROPIC_DEFAULT_OPUS_MODEL:-claude-opus-4-8[1m]}"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="${ANTHROPIC_DEFAULT_SONNET_MODEL:-claude-sonnet-5[1m]}"
        command claude "$@"
    )
}

# ---------------------------------------------------------------------------
# claude-vertex-dashboard: open the Google Cloud console dashboard for the
# Vertex AI project Claude Code routes through (ANTHROPIC_VERTEX_PROJECT_ID —
# same var claude-vertex()/claude-vertex-native-adc() require), via the comet
# skill's opener script so it's a single call instead of manually building/
# opening the URL.
claude-vertex-dashboard() {
    if [[ -z "$ANTHROPIC_VERTEX_PROJECT_ID" ]]; then
        echo "❌ ANTHROPIC_VERTEX_PROJECT_ID must be exported to open its dashboard." >&2
        return 1
    fi
    local script="$HOME/.claude/skills/comet/scripts/comet.sh"
    if [[ ! -x "$script" ]]; then
        echo "❌ comet skill script not found or not executable at ${script}." >&2
        return 1
    fi
    "$script" "https://console.cloud.google.com/home/dashboard?project=${ANTHROPIC_VERTEX_PROJECT_ID}"
}

# ---------------------------------------------------------------------------
# claude-vertex: raw claude binary, routed through Google Vertex AI's native
# Claude models via a local LiteLLM proxy, instead of Claude Code's built-in
# CLAUDE_CODE_USE_VERTEX integration (see claude-vertex-native-adc() above).
# This is the DEFAULT vertex path — pick this unless you have a specific
# reason to use the native-ADC one instead.
#
# Why this exists: Claude Code's Monitor tool
# (https://code.claude.com/docs/en/tools-reference#monitor-tool) is
# unconditionally unavailable whenever CLAUDE_CODE_USE_VERTEX is set (also
# Bedrock, MS Foundry) — there is no override flag, per the docs. LiteLLM's
# proxy speaks Anthropic's own /v1/messages shape on the client side while
# translating to Vertex's native streamRawPredict shape upstream, so from
# Claude Code's perspective this looks like a direct-API-shaped backend
# (ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN, same as claude-copilot()) and
# Monitor stays enabled.
#
# Vetted alternative considered and rejected: 1rgs/claude-code-proxy. Its
# README's "USE_VERTEX_AUTH" mode only maps to Gemini models via Vertex, not
# Anthropic/Claude models — it has no path to Claude-on-Vertex at all, so it
# can't do this job. LiteLLM does (vertex_ai/claude-* model routing).
#
# Pinned to litellm==1.97.0, NOT "latest": PyPI releases 1.82.7/1.82.8
# shipped credential-stealing malware (BerriAI/litellm#24518). 1.97.0 is
# well past that and the current stable release as of this writing — bump
# deliberately, don't float.
#
# ALSO pinned: fastapi==0.136.3 (litellm's own declared minimum for the
# proxy extra). Verified by actually running this exact command: litellm
# 1.97.0's fastapi dependency spec is `fastapi<1.0,>=0.136.3` — unbounded
# above — so an unpinned install resolves today's newest fastapi (0.141.1),
# which has removed the private `fastapi.dependencies.utils.get_flat_dependant`
# that litellm's proxy imports internally, crashing the server on startup
# with `ImportError: cannot import name 'get_flat_dependant'` before falling
# through to a second, more confusing `ModuleNotFoundError: No module named
# 'proxy_server'`. Confirmed fastapi 0.136.3 through at least 0.140.x still
# has this symbol; only pin it away from "latest", don't remove the pin.
#
# Requires: uv (runs litellm via `uv tool run --from`, with fastapi pinned
# via `--with`, so no separate venv management is needed), gcloud ADC
# (`gcloud auth application-default login`), and CLOUD_ML_REGION /
# ANTHROPIC_VERTEX_PROJECT_ID already exported (same vars claude-vertex()
# requires above).
#
# Known caveats from LiteLLM's own issue tracker (not hypothetical):
#   - Extended-thinking can break on Vertex (beta headers dropped upstream,
#     litellm#15299) — if you hit a "max_tokens must be greater than
#     thinking.budget_tokens" error, this is why.
#   - Cost-logging can crash on web-search tool use via Vertex (litellm#12063).
# Prompt-caching parity with the raw Anthropic API is unverified either way.
#
# Model IDs: base names come from ANTHROPIC_MODEL/ANTHROPIC_DEFAULT_*_MODEL,
# same as claude-vertex() — with any "[1m]" 1M-context suffix stripped for
# BOTH the litellm model_list model_name key AND the litellm_params.model
# backend value. Confirmed by testing: Claude Code strips "[1m]" before
# putting the model name in the actual request body it sends to the
# proxy — registering model_name with the bracket suffix still attached
# caused a 400 "Invalid model name passed in model=claude-sonnet-5" because
# the wire request used the bracket-free name and matched nothing in the
# config. ANTHROPIC_MODEL etc. still keep the "[1m]" suffix when exported
# below (that's what tells the CLI itself to request 1M-context mode); only
# the proxy's own config needs the stripped form.
#
# Model ID format verified end-to-end (real /v1/messages round-trip against
# live Vertex, not just docs): plain aliases like "claude-sonnet-5" DO
# resolve as a Vertex publisher model ID — no "@YYYYMMDD" dated-snapshot
# suffix needed, despite LiteLLM's own Vertex-partner docs
# (https://docs.litellm.ai/docs/providers/vertex_partner) only listing
# older dated-snapshot examples (that page is simply stale for newer
# models). If a future model alias 404s, check the Vertex AI Model Garden
# console for that project/region and override via ANTHROPIC_MODEL etc.
# before calling this function.
typeset -g CLAUDE_VERTEX_PROXY_LITELLM_VERSION="1.97.0"
typeset -g CLAUDE_VERTEX_PROXY_FASTAPI_VERSION="0.136.3"
typeset -g _claude_vertex_proxy_config="${XDG_CONFIG_HOME:-$HOME/.config}/claude-vertex-proxy.yaml"

_claude_vertex_proxy_write_config() {
    local master_key="$1"
    shift
    # $@ = alternating model_name/backend_model pairs
    mkdir -p "${_claude_vertex_proxy_config:h}"
    {
        echo "model_list:"
        # wildcard so any Claude id picked in /model routes to Vertex, not just
        # the pinned tiers (exact model_name entries below still win)
        cat <<EOF
  - model_name: "claude-*"
    litellm_params:
      model: vertex_ai/claude-*
      vertex_ai_project: "${ANTHROPIC_VERTEX_PROJECT_ID}"
      vertex_ai_location: "${CLOUD_ML_REGION}"
EOF
        while (( $# >= 2 )); do
            local model_name="$1" backend_model="$2"
            shift 2
            # vertex_ai_project/vertex_ai_location, NOT vertex_project/
            # vertex_location -- those latter two are the field names for
            # litellm's generic Gemini vertex_ai/ route; the Anthropic
            # partner-model route
            # (https://docs.litellm.ai/docs/providers/vertex_partner)
            # documents this different pair for claude-on-vertex specifically.
            cat <<EOF
  - model_name: ${model_name}
    litellm_params:
      model: vertex_ai/${backend_model}
      vertex_ai_project: "${ANTHROPIC_VERTEX_PROJECT_ID}"
      vertex_ai_location: "${CLOUD_ML_REGION}"
EOF
        done
        echo "litellm_settings:"
        echo "  master_key: \"${master_key}\""
    } >| "$_claude_vertex_proxy_config"
}

# ---------------------------------------------------------------------------
# claude-vertex model auto-pick: some corp Vertex AI orgs block specific
# Claude models via org policy (surfaces only as a 403 PERMISSION_DENIED at
# request time -- there's no separate "list what my org allows" API on
# Vertex). These helpers list every Claude id Model Garden offers in the
# region, then probe each one newest-first via Vertex's free count-tokens
# endpoint (no generation cost, unlike a real predict call -- see
# https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/partner-models/claude/count-tokens)
# until one actually works, so claude-vertex() degrades to e.g.
# claude-opus-4-8 automatically when claude-opus-5 is blocked, instead of
# hard-failing at session start on a hardcoded id that may not be allowed.
# Resolved picks are cached in $_claude_vertex_models_file (keyed by
# project+region) so this only re-probes once per
# CLAUDE_VERTEX_MODEL_CACHE_TTL, not on every claude-vertex launch.

typeset -g _claude_vertex_models_file="${XDG_CONFIG_HOME:-$HOME/.config}/claude-vertex-models"

_claude_vertex_access_token() {
    gcloud auth application-default print-access-token 2>/dev/null
}

# List every Anthropic publisher model Model Garden offers in
# $CLOUD_ML_REGION -- the region-wide catalog, NOT filtered by this
# project's org policy (Vertex has no API for that; see the probe step
# below for the actual access check). The list response's array field name
# ("publisherModels" vs "models") isn't independently confirmed from
# Google's docs, so this accepts either key defensively rather than
# asserting one.
_claude_vertex_publisher_models() {
    local token
    token=$(_claude_vertex_access_token) || return 1
    [[ -z "$token" ]] && return 1
    curl -sf --max-time 10 \
        -H "Authorization: Bearer ${token}" \
        "https://${CLOUD_ML_REGION}-aiplatform.googleapis.com/v1/publishers/anthropic/models"
}

# Version-descending list of bare model ids (no "publishers/anthropic/models/"
# prefix) for one family (opus|sonnet|haiku) from a publisher-models list
# response. Reuses the same numeric major-then-minor version compare as
# _claude_copilot_latest_model above, generalized to keep every match
# sorted instead of collapsing to the top one -- callers still resolve to
# exactly one id (see _claude_vertex_resolve_tier_model below), this just
# gives the probe loop an order to walk.
_claude_vertex_ranked_candidates() {
    local family="$1" models_json="$2"
    jq -r --arg fam "$family" '
        (.publisherModels // .models // [])
        | map(.name // empty)
        | map(select(test("claude"; "i") and test($fam; "i")))
        | map(sub("^publishers/anthropic/models/"; ""))
        | map({id: .,
               v: ((try (capture("(?<maj>[0-9]+)(?:[.-](?<min>[0-9]+))?")) catch null) as $m
                   | if $m == null then 0
                     else (($m.maj | tonumber) * 1000) + (($m.min // "0") | tonumber)
                     end)})
        | sort_by(.v) | reverse | .[].id
    ' <<< "$models_json"
}

# Probe one model id via Vertex's free count-tokens endpoint. Model id must
# be bare (no "@version" suffix) per the docs linked above.
# Returns: 0 = usable, 1 = blocked (403 PERMISSION_DENIED), 2 = other error
# (network/4xx/5xx -- treated as "try the next candidate" too, but logged
# distinctly so a real outage doesn't read as a policy block).
_claude_vertex_probe_model() {
    local model_id="$1"
    local token
    token=$(_claude_vertex_access_token) || return 2
    [[ -z "$token" ]] && return 2
    local http_code
    http_code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg m "$model_id" '{anthropic_version:"vertex-2023-10-16", model:$m, messages:[{role:"user",content:"hi"}]}')" \
        "https://${CLOUD_ML_REGION}-aiplatform.googleapis.com/v1/projects/${ANTHROPIC_VERTEX_PROJECT_ID}/locations/${CLOUD_ML_REGION}/publishers/anthropic/models/count-tokens:rawPredict")
    case "$http_code" in
        200) return 0 ;;
        403) return 1 ;;
        *)   return 2 ;;
    esac
}

# Resolve one tier (opus|sonnet|haiku) to the newest model id Model Garden
# offers in this region that this project's org policy actually allows --
# walks the ranked candidate list newest-first (e.g. claude-opus-5, then
# claude-opus-4-9, then claude-opus-4-8, ...), stopping at the first one
# that probes successfully. Falls back to $2 (this tier's historical
# hardcoded default) if the publisher list is empty/unreachable, or every
# candidate is blocked/errors.
_claude_vertex_resolve_tier_model() {
    local family="$1" fallback="$2" models_json="$3"
    local -a candidates
    candidates=("${(@f)$(_claude_vertex_ranked_candidates "$family" "$models_json")}")
    candidates=("${(@)candidates:#}")
    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo "⚠️  No '${family}' models found in Model Garden for region ${CLOUD_ML_REGION} -- using fallback ${fallback}." >&2
        print -r -- "$fallback"
        return 0
    fi
    local c
    for c in "${candidates[@]}"; do
        _claude_vertex_probe_model "$c"
        case $? in
            0) print -r -- "$c"; return 0 ;;
            1) echo "⚠️  '${c}' blocked by org policy for this project -- trying next ${family} candidate." >&2 ;;
            2) echo "⚠️  Couldn't probe '${c}' (network/API error) -- trying next ${family} candidate." >&2 ;;
        esac
    done
    echo "❌ No usable '${family}' model found (all candidates blocked or errored) -- falling back to ${fallback}. Check IAM/org policy." >&2
    print -r -- "$fallback"
}

# Resolve (and cache) all three tiers in one go. Prints "opus sonnet haiku"
# (space-separated bare ids) on stdout. Reuses the cache in
# $_claude_vertex_models_file when it matches this project+region and is
# under CLAUDE_VERTEX_MODEL_CACHE_TTL seconds old (default 1h) -- pass
# force="force" to bypass the cache and re-probe unconditionally (see
# claude-vertex-models below).
_claude_vertex_get_models() {
    local force="$1"
    local ttl="${CLAUDE_VERTEX_MODEL_CACHE_TTL:-3600}"

    if [[ -z "$force" && -r "$_claude_vertex_models_file" ]]; then
        local cached_project cached_region cached_ts now
        cached_project=$(awk -F= '$1=="PROJECT"{print $2; exit}' "$_claude_vertex_models_file")
        cached_region=$(awk -F= '$1=="REGION"{print $2; exit}' "$_claude_vertex_models_file")
        cached_ts=$(awk -F= '$1=="TIMESTAMP"{print $2; exit}' "$_claude_vertex_models_file")
        now=$(date +%s)
        if [[ "$cached_project" == "$ANTHROPIC_VERTEX_PROJECT_ID" && "$cached_region" == "$CLOUD_ML_REGION" \
              && -n "$cached_ts" && $(( now - cached_ts )) -lt $ttl ]]; then
            local o s h
            o=$(awk -F= '$1=="OPUS"{print $2; exit}' "$_claude_vertex_models_file")
            s=$(awk -F= '$1=="SONNET"{print $2; exit}' "$_claude_vertex_models_file")
            h=$(awk -F= '$1=="HAIKU"{print $2; exit}' "$_claude_vertex_models_file")
            if [[ -n "$o" && -n "$s" && -n "$h" ]]; then
                print -r -- "${o} ${s} ${h}"
                return 0
            fi
        fi
    fi

    local models_json
    models_json=$(_claude_vertex_publisher_models) || echo "⚠️  Couldn't fetch Model Garden catalog -- using hardcoded fallbacks per tier." >&2

    local opus sonnet haiku
    opus=$(_claude_vertex_resolve_tier_model opus "claude-opus-4-8" "$models_json")
    sonnet=$(_claude_vertex_resolve_tier_model sonnet "claude-sonnet-5" "$models_json")
    haiku=$(_claude_vertex_resolve_tier_model haiku "claude-haiku-4-5" "$models_json")

    mkdir -p "${_claude_vertex_models_file:h}"
    {
        echo "PROJECT=${ANTHROPIC_VERTEX_PROJECT_ID}"
        echo "REGION=${CLOUD_ML_REGION}"
        echo "TIMESTAMP=$(date +%s)"
        echo "OPUS=${opus}"
        echo "SONNET=${sonnet}"
        echo "HAIKU=${haiku}"
    } >| "$_claude_vertex_models_file"

    print -r -- "${opus} ${sonnet} ${haiku}"
}

# claude-vertex-models: force re-probe of all three tiers (or one, if
# passed), bypassing the cache TTL. Optional convenience, not a
# prerequisite -- claude-vertex() auto-probes on its own the first time,
# or once the cache goes stale. Mirrors claude-ollama-models's shape.
claude-vertex-models() {
    if [[ -z "$CLOUD_ML_REGION" || -z "$ANTHROPIC_VERTEX_PROJECT_ID" ]]; then
        echo "❌ CLOUD_ML_REGION and ANTHROPIC_VERTEX_PROJECT_ID must be exported to probe Vertex models." >&2
        return 1
    fi
    case "$1" in
        ""|opus|sonnet|haiku) ;;
        *)
            echo "Usage: claude-vertex-models [opus|sonnet|haiku]" >&2
            return 1
            ;;
    esac
    if (( $# > 1 )); then
        echo "Usage: claude-vertex-models [opus|sonnet|haiku]" >&2
        return 1
    fi
    local resolved opus sonnet haiku
    resolved=$(_claude_vertex_get_models force) || return 1
    opus="${resolved%% *}"
    local rest="${resolved#* }"
    sonnet="${rest%% *}"
    haiku="${rest#* }"
    case "$1" in
        opus)   echo "opus: ${opus}" ;;
        sonnet) echo "sonnet: ${sonnet}" ;;
        haiku)  echo "haiku: ${haiku}" ;;
        "")
            echo "opus: ${opus}"
            echo "sonnet: ${sonnet}"
            echo "haiku: ${haiku}"
            ;;
        *)
            echo "Usage: claude-vertex-models [opus|sonnet|haiku]" >&2
            return 1
            ;;
    esac
}

_claude_vertex_prepare() {
    if [[ -z "$CLOUD_ML_REGION" || -z "$ANTHROPIC_VERTEX_PROJECT_ID" ]]; then
        echo "❌ CLOUD_ML_REGION and ANTHROPIC_VERTEX_PROJECT_ID must be exported to use Vertex AI." >&2
        return 1
    fi
    if ! command -v uv &>/dev/null; then
        echo "❌ uv not found. Install it with: $(_claude_pkg_install_hint uv 'curl -LsSf https://astral.sh/uv/install.sh | sh')" >&2
        return 1
    fi

    local port="${CLAUDE_VERTEX_PROXY_PORT:-4142}"
    local base="http://127.0.0.1:${port}"
    local log="${TMPDIR:-/tmp}/claude-vertex-proxy-${port}.log"
    local master_key="${CLAUDE_VERTEX_PROXY_TOKEN:-vertex-proxy-local}"

    # Auto-pick the newest AVAILABLE (org-policy-unrestricted) model per
    # tier when the caller hasn't explicitly pinned it -- see the
    # _claude_vertex_* helpers above. Only probes when at least one of the
    # four vars below is unset; if the caller already exported all four,
    # this whole block (and the network calls it'd trigger) is skipped and
    # their explicit values win, unchanged from prior behavior.
    local opus_bare="" sonnet_bare="" haiku_bare=""
    if [[ -z "$ANTHROPIC_MODEL" || -z "$ANTHROPIC_DEFAULT_OPUS_MODEL" \
          || -z "$ANTHROPIC_DEFAULT_SONNET_MODEL" || -z "$ANTHROPIC_DEFAULT_HAIKU_MODEL" ]]; then
        local resolved
        resolved=$(_claude_vertex_get_models) || return 1
        opus_bare="${resolved%% *}"
        local _rest="${resolved#* }"
        sonnet_bare="${_rest%% *}"
        haiku_bare="${_rest#* }"
    fi

    # "[1m]" is a Claude-Code-level suffix requesting the 1M-context variant
    # -- inherited from this function's previous hardcoded opus/sonnet
    # defaults, not independently verified for whichever version auto-pick
    # lands on. Override via ANTHROPIC_DEFAULT_*_MODEL/ANTHROPIC_MODEL if a
    # resolved version doesn't actually support it.
    local main_model="${ANTHROPIC_MODEL:-${sonnet_bare}[1m]}"
    local opus_model="${ANTHROPIC_DEFAULT_OPUS_MODEL:-${opus_bare}[1m]}"
    local sonnet_model="${ANTHROPIC_DEFAULT_SONNET_MODEL:-${sonnet_bare}[1m]}"
    # Unlike opus/sonnet, claude-vertex-native-adc() and the CLI's own
    # built-in default both leave haiku unset -- fine for those paths (the
    # native Vertex integration resolves the CLI's baked-in default itself),
    # but litellm's proxy strictly validates the request's model against
    # its registered model_list (same failure mode we hit with sonnet), so
    # background/Auto-Mode calls defaulting to haiku 400 here unless it's
    # explicitly registered too, same as opus/sonnet already are.
    # "claude-haiku-4-5-20251001" (dated) 404s against Vertex; a bare alias
    # like "claude-haiku-4-5" is what actually resolves -- verified live,
    # Vertex itself reports back model="claude-haiku-4-5-20251001" once
    # resolved. Auto-pick above already returns bare ids (see
    # _claude_vertex_ranked_candidates), so this still holds.
    local haiku_model="${ANTHROPIC_DEFAULT_HAIKU_MODEL:-${haiku_bare}}"

    # Claude Code strips any "[1m]" 1M-context suffix before putting the
    # model name in the actual request body sent to the proxy -- confirmed
    # by testing: a config registering "claude-sonnet-5[1m]" as model_name
    # got a 400 "Invalid model name passed in model=claude-sonnet-5" because
    # the wire request used the bracket-free name. So model_name here must
    # be the stripped name (what the CLI actually sends), not the
    # bracket-suffixed value from ANTHROPIC_MODEL/ANTHROPIC_DEFAULT_*_MODEL.
    # haiku_model has no "[1m]" suffix by default, but strip defensively in
    # case a caller overrides ANTHROPIC_DEFAULT_HAIKU_MODEL with one.
    local main_stripped="${main_model%\[*}"
    local opus_stripped="${opus_model%\[*}"
    local sonnet_stripped="${sonnet_model%\[*}"
    local haiku_stripped="${haiku_model%\[*}"

    # Confirmed live (proxy log from an already-running claude session):
    # Auto Mode's background classifier request arrived with
    # model=claude-haiku-4-5-20251001 -- the CLI's own built-in dated
    # default -- even though ANTHROPIC_DEFAULT_HAIKU_MODEL wasn't exported
    # by that (older) session yet. Register the dated ID as an extra alias
    # to the same working backend, alongside the resolved haiku_stripped
    # value, so this doesn't silently break again for any session that
    # predates a haiku_model default change, or if the CLI ever sends the
    # dated form regardless of the exported override.
    local -a vproxy_models=(
        "${main_stripped}"           "${main_stripped}"
        "${opus_stripped}"           "${opus_stripped}"
        "${sonnet_stripped}"         "${sonnet_stripped}"
        "${haiku_stripped}"          "${haiku_stripped}"
        "claude-haiku-4-5-20251001"  "${haiku_stripped}"
    )
    # Hot reload -- see _claude_proxy_sync. Credentials come from the
    # Application Default Credentials file (gcloud auth application-default
    # login), so its contents are part of the fingerprint. A running proxy
    # with no recorded fingerprint is adopted, not restarted.
    local vfp
    vfp=$(_claude_proxy_fp wildcard-v1 "${vproxy_models[@]}" "$ANTHROPIC_VERTEX_PROJECT_ID" "$CLOUD_ML_REGION" \
        "$CLAUDE_VERTEX_PROXY_LITELLM_VERSION" "$master_key" \
        "$(_claude_file_hash "${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcloud/application_default_credentials.json}")")
    _claude_proxy_sync claude-vertex vertex-proxy "${base}/health/liveliness" "$vfp" claude-vertex-kill 1 || return 1

    if ! curl -sf --max-time 2 "${base}/health/liveliness" -o /dev/null; then
        _claude_vertex_proxy_write_config "$master_key" "${vproxy_models[@]}"
        echo "Starting claude-vertex proxy (litellm ${CLAUDE_VERTEX_PROXY_LITELLM_VERSION}) on ${base} (log: ${log})..." >&2
        # "google" extra pulls google-cloud-aiplatform -- without it litellm
        # fails at request time with "Google Cloud SDK not found", since
        # "proxy" alone doesn't include it (confirmed by testing).
        _claude_proxy_start "$log" uv tool run --with "fastapi==${CLAUDE_VERTEX_PROXY_FASTAPI_VERSION}" \
            --from "litellm[proxy,google]==${CLAUDE_VERTEX_PROXY_LITELLM_VERSION}" litellm \
            --config "$_claude_vertex_proxy_config" --port "$port" --host 127.0.0.1 || return 1
        local i
        for i in {1..60}; do
            curl -sf --max-time 2 "${base}/health/liveliness" -o /dev/null && break
            sleep 1
        done
        if ! curl -sf --max-time 2 "${base}/health/liveliness" -o /dev/null; then
            echo "❌ claude-vertex proxy not ready on ${base} after 60s." >&2
            echo "   Check the log: tail -f ${log}" >&2
            return 1
        fi
        _claude_proxy_record vertex-proxy "$vfp"
    fi

    # Hand the resolved proxy/model config back to the caller (claude-vertex
    # / omni-claude-vertex) as globals -- zsh `local` doesn't cross function
    # boundaries, and both wrappers need these to export before launching.
    typeset -g _cv_base="$base" _cv_master_key="$master_key" \
        _cv_main_model="$main_model" _cv_opus_model="$opus_model" \
        _cv_sonnet_model="$sonnet_model" _cv_haiku_model="$haiku_model"
}

# claude-vertex: Vertex AI via a local litellm proxy -- see
# _claude_vertex_prepare() above for model resolution / proxy bootstrap.
claude-vertex() {
    _claude_vertex_prepare || return 1
    _claude_copilot_unset_env
    (
        export ANTHROPIC_BASE_URL="${_cv_base}"
        export ANTHROPIC_AUTH_TOKEN="${_cv_master_key}"
        export ANTHROPIC_MODEL="${_cv_main_model}"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="${_cv_opus_model}"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="${_cv_sonnet_model}"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="${_cv_haiku_model}"
        # SDK disables tool search by default for any non-first-party
        # ANTHROPIC_BASE_URL (this local proxy included). Verified litellm
        # 1.97.0's vertex_ai anthropic-partner transformation.py has
        # first-class support: is_tool_search_used() detects deferred
        # tools and adds the required anthropic-beta header itself, plus
        # _expand_tool_references() to unpack tool_reference blocks in
        # responses. Safe to force back on.
        export ENABLE_TOOL_SEARCH=true
        # Pinned tiers only: Model Garden's catalog listing is often denied by
        # org policy, so there is no reliable "all models" list on Vertex (any
        # Claude id still routes via the proxy's wildcard entry, e.g. --model).
        _claude_picker_args opus="${_cv_opus_model}" sonnet="${_cv_sonnet_model}" haiku="${_cv_haiku_model}"
        _claude_invoke "${reply[@]}" "$@"
    )
}

# omni-claude-vertex: same Vertex proxy/model resolution as claude-vertex(),
# but launches through Omnigent's claude-native harness (native TUI, wrapped
# with Omnigent's collab/policy layer) instead of the bare `claude` binary --
# it inherits the same exported env vars either way, so Vertex routing is
# unaffected by which binary actually execs.
omni-claude-vertex() {
    if ! command -v omni &>/dev/null; then
        echo "❌ omni not found. Install: curl -fsSL https://omnigent.ai/install.sh | sh" >&2
        return 1
    fi
    _claude_vertex_prepare || return 1
    _claude_copilot_unset_env
    (
        export ANTHROPIC_BASE_URL="${_cv_base}"
        export ANTHROPIC_AUTH_TOKEN="${_cv_master_key}"
        export ANTHROPIC_MODEL="${_cv_main_model}"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="${_cv_opus_model}"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="${_cv_sonnet_model}"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="${_cv_haiku_model}"
        export ENABLE_TOOL_SEARCH=true
        omni claude-native "$@"
    )
}
# claude-vertex-proxy: pre-rename alias -- claude-vertex() is now the
# default vertex path (proxy-based); the old CLAUDE_CODE_USE_VERTEX-native
# path moved to claude-vertex-native-adc().
alias claude-vertex-proxy='claude-vertex'

# claude-vertex-kill: stop the detached litellm proxy started by
# claude-vertex(). Mirrors claude-copilot-kill/claude-ollama-kill.
claude-vertex-kill() {
    local port="${CLAUDE_VERTEX_PROXY_PORT:-4142}"
    local -a pids
    pids=("${(f)$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null)}")
    if [[ -z "${pids[1]}" ]]; then
        echo "No process listening on port ${port}."
        return 1
    fi
    echo "Killing claude-vertex proxy on port ${port} (pid: ${pids[*]})..."
    kill "${pids[@]}" 2>/dev/null
    sleep 1
    pids=("${(f)$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null)}")
    if [[ -n "${pids[1]}" ]]; then
        echo "Still alive, sending SIGKILL..."
        kill -9 "${pids[@]}" 2>/dev/null
    fi
}
alias claude-vertex-proxy-kill='claude-vertex-kill'
