# Sourced library (not executable): the hosted-only Go proxies.
#
# Takes effect: see docs/notes/change-take-effect.md. Source edits change the
# fingerprint, so an IDLE proxy restarts on the next launch or fleet-sync run;
# a busy one waits for the watcher. Sourced functions are live in NEW shells
# only.
#
# Hosted-only = EnMaaS-hosted free models only: GLM 5.3 (text) and DeepSeek
# V4.1 Flash (1M context, vision). Codex's auto-review and Claude Code's
# auto-mode classifier send their review request to the same endpoint as the
# main model, so one local endpoint routes by model id and every tier, reviewer
# and helper call stays on the two hosted models (no paid side-channel calls,
# no OpenAI key). One shared proxy serves BOTH client flavors (#599): each
# model gets an anthropic/ deployment (Messages, bare group name) and an
# openai/ deployment (Responses/chat, group name suffixed #openai), and the
# proxy picks the dialect from the call type, so the clients keep their bare
# model ids:
#
#   shared  127.0.0.1:${HOSTED_ONLY_CLAUDE_PROXY_PORT:-4148}  used by
#           claude-hosted-only (zsh/functions/claude/providers/hosted-only.zsh)
#           and scripts/codex-provider.zsh hosted-only alike.
#           HOSTED_ONLY_CODEX_PROXY_PORT splits a second proxy off (same merged
#           config) for testing.
#
# The Go binary (scripts/hosted-only-go, stdlib only) is the ONLY impl: the
# LiteLLM impl is retired (a go toolchain is required; the openai/vertex
# launchers still run LiteLLM for their own flavors). It does what the old
# Python hooks did inside the proxy: strips the grammar vLLM rejects from
# Codex's apply_patch, cuts default reasoning on Messages requests that send
# no thinking field, reroutes GLM image requests to DeepSeek, image budget
# pruning with a disk cache, the 429/quota/outage rewrites T3 Code auto-resumes
# on, model fallback, and the per-request JSONL for `llm-usage`.
#
# Upstream key: ENMAAS_API_KEY (caller loads it, e.g. from ~/secrets.zsh); only
# the proxy gets it, clients get the local token
# ${HOSTED_ONLY_PROXY_TOKEN:-hosted-only-local}.
#
# Knobs (every one also reads its retired GLM_HYBRID_* name as a fallback, so
# old shells keep working): HOSTED_ONLY_{CODEX,CLAUDE}_PROXY_PORT,
# HOSTED_ONLY_PROXY_TOKEN, HOSTED_ONLY_GLM_MODEL (route id of GLM; old name
# GLM_HYBRID_MODEL), HOSTED_ONLY_DEEPSEEK_MODEL (default
# rits/deepseek-ai/DeepSeek-V4.1-Flash-1017), HOSTED_ONLY_ENMAAS_BASE_URL
# (gateway root; default $ENMAAS_API_BASE_URL). HOSTED_ONLY_MODEL (main model
# pick), HOSTED_ONLY_REVIEW_MODEL, HOSTED_ONLY_CLASSIFIER_MODEL,
# HOSTED_ONLY_SMALL_FAST_MODEL are read by the launchers, not here. The full
# Go-side knob list is in scripts/hosted-only-go/config.go and mirrored by
# _hosted_only_go_env below.
#
# History: a "GLM hybrid" mode once added an OpenAI reviewer (gpt-6-luna) to
# this proxy. DeepSeek V4.1 Flash now covers reviewer, classifier and vision
# inside hosted-only, so that mode is retired; its old names are aliases. The
# LiteLLM impl (HOSTED_ONLY_PROXY_IMPL=litellm / LLM_PROXY_IMPL=litellm) was
# the escape hatch before the Go proxy reached parity; both knobs now error.
#
# Lifecycle: started on demand as a detached session (outlives the client),
# state in ~/.local/state/hosted-only-<flavor>-<port>/ (0700; proxies started
# before the rename keep running from the legacy glm-hybrid-<flavor>-<port>/ dir
# and the stop helper handles both). A running proxy whose config/key/code
# differs is never restarted under active sessions; the caller gets an error
# naming the stop command:
#   zsh -f <dotfiles>/scripts/codex-provider.zsh hosted-only --stop-proxy   (codex)
#   claude-hosted-only-kill                                                  (claude)
# The mechanics (lock, stale/busy decision, zero-refuse swap spawn, health
# wait, stop, idle watcher) live in the binary's ensure/stop/watch
# subcommands; the fingerprint inputs stay here (see
# docs/notes/hosted-only-go-proxy.md).

typeset -g _HOSTED_ONLY_SCRIPTS="${${(%):-%x}:A:h}"

# _hosted_only_knob <NAME> <default>: $HOSTED_ONLY_<NAME>, else the retired
# $GLM_HYBRID_<NAME>, else the default.
_hosted_only_knob() {
    local new="HOSTED_ONLY_$1" old="GLM_HYBRID_$1"
    print -r -- "${${(P)new}:-${${(P)old}:-$2}}"
}

# _hosted_only_impl: the proxy impl for the hosted-only launchers. The Go
# proxy is the only impl; the retired HOSTED_ONLY_PROXY_IMPL / LLM_PROXY_IMPL
# knobs error on litellm so an old shell setting fails loudly instead of
# silently trying a path that no longer exists.
_hosted_only_impl() {
    local impl="$(_hosted_only_knob PROXY_IMPL "${LLM_PROXY_IMPL:-go}")"
    impl="${${(L)impl}//[[:space:]]/}"
    case "$impl" in
        ''|auto|go) ;;
        litellm)
            print -ru2 -- 'hosted-only: the LiteLLM impl is retired; the Go proxy is the only impl (install a go toolchain).'
            return 1
            ;;
        *)
            print -ru2 -- "hosted-only: HOSTED_ONLY_PROXY_IMPL must be go (got '$impl'); the LiteLLM impl is retired."
            return 1
            ;;
    esac
    (( $+commands[go] )) || {
        print -ru2 -- 'hosted-only: go not found (the Go proxy is the only impl; install a go toolchain).'
        return 1
    }
    print -r -- go
}

# _hosted_only_proxy_vars <flavor>: sets _hop_* globals for the flavor.
_hosted_only_proxy_vars() {
    case "$1" in
        codex|claude) : ;;
        *) print -ru2 -- 'hosted-only: flavor must be codex or claude.'; return 1 ;;
    esac
    typeset -g _hop_flavor="$1"
    # One shared proxy serves both flavors (#599): the Go proxy routes
    # OpenAI-wire requests to the openai/ deployments with a #openai model-group
    # suffix, so both clients keep their bare model ids on one port.
    # HOSTED_ONLY_CODEX_PROXY_PORT still splits it off (defaults to the shared
    # claude port); a split-off proxy serves the same merged config.
    typeset -g _hop_port="$(_hosted_only_knob CLAUDE_PROXY_PORT 4148)"
    [[ "$1" == codex ]] && typeset -g _hop_port="$(_hosted_only_knob CODEX_PROXY_PORT "$_hop_port")"
    local state="${XDG_STATE_HOME:-$HOME/.local/state}"
    typeset -g _hop_runtime="$state/hosted-only-$_hop_port"
    # legacy runtime dirs (flavor-named before the merge, glm-hybrid before the
    # rename) whose listeners the stop helper still recognizes — BOTH flavors'
    # names, since the port is shared since #599 and either launcher must be
    # able to retire the other's pre-merge leftovers
    local other="$1"; [[ "$other" == claude ]] && other=codex || other=claude
    typeset -g -a _hop_legacy_runtimes
    _hop_legacy_runtimes=("$state/glm-hybrid-$1-$_hop_port" "$state/hosted-only-$1-$_hop_port"
        "$state/glm-hybrid-$other-$_hop_port" "$state/hosted-only-$other-$_hop_port")
    typeset -g _hop_base="http://127.0.0.1:$_hop_port"
    typeset -g _hop_token="$(_hosted_only_knob PROXY_TOKEN hosted-only-local)"
    # The Go proxy (scripts/hosted-only-go, stdlib only) is the only impl; a
    # missing go toolchain or a retired =litellm knob fails in _hosted_only_impl
    # — unless _HOP_STOP_MODE is set: the stop helper must reach the listener
    # even when launch-time validation would fail (an old shell still exporting
    # a retired knob, a broken toolchain). Same knobs, ports, token, fingerprint
    # protocol and stop command as always.
    # (A plain assignment: `typeset -g x=$(false)` swallows the failure.)
    typeset -g _hop_impl
    _hop_impl="$(_hosted_only_impl)" || {
        [[ -n "${_HOP_STOP_MODE:-}" ]] || return 1
        print -ru2 -- 'hosted-only: impl validation failed; continuing in stop mode.'
        _hop_impl=go
    }
    typeset -g _hop_glm="$(_hosted_only_knob GLM_MODEL "${GLM_HYBRID_MODEL:-rits/zai-org/glm-5-3}")"
    typeset -g _hop_deepseek="$(_hosted_only_knob DEEPSEEK_MODEL rits/deepseek-ai/DeepSeek-V4.1-Flash-1017)"
    typeset -g _hop_vision_fallback="$(_hosted_only_knob VISION_FALLBACK 1)"
    typeset -g _hop_limit_rewrite="$(_hosted_only_knob LIMIT_REWRITE 1)"
    typeset -g _hop_limit_retry="$(_hosted_only_knob RATE_LIMIT_DEFAULT_RETRY_SECONDS 60)"
    typeset -g _hop_client_retry="$(_hosted_only_knob CLIENT_RETRY_MAX_SECONDS 60)"
    # Model fallback GLM <-> DeepSeek and the outage rewrite it shares knobs
    # with (both live in the Go binary now). ALIAS_MODELS: ids served from the GLM
    # deployment (claude flavor's claude-sonnet-5-5 alias) that get GLM's vision
    # reroute and fallback target.
    typeset -g _hop_fallback="$(_hosted_only_knob FALLBACK 1) $(_hosted_only_knob OUTAGE_REWRITE 1) $(_hosted_only_knob OUTAGE_RETRY_SECONDS 60) $(_hosted_only_knob OUTAGE_RETRY_MAX_SECONDS 600) $(_hosted_only_knob MAX_MODEL_LEN 1048576) $(_hosted_only_knob OUTPUT_RESERVE 512) $(_hosted_only_knob BYTES_PER_TOKEN 3) $(_hosted_only_knob MIN_OUTPUT 16000)"
    # The merged config always serves the claude-sonnet-5-5 alias from the GLM
    # (anthropic) deployment, so both flavors record the same value and the
    # shared fingerprint stays flavor-independent.
    typeset -g _hop_aliases="$(_hosted_only_knob ALIAS_MODELS claude-sonnet-5-5)"
    # Dialect-suffix routing: this proxy turns it on for the #openai groups
    # (the EnMaaS flavor leaves it off and uses #responses siblings instead).
    typeset -g _hop_dialect="$(_hosted_only_knob DIALECT_SUFFIX "#openai")"
    # LiteLLM request_timeout per deployment: a hung upstream (connection up,
    # no answer, no gateway 504) is cut at this many seconds so the outage
    # rewrite and the model fallback can fire instead of stalling the turn for
    # LiteLLM's 600 s default. Generous enough for 1M-token prompts (a 900k
    # prefill took 98 s on the congested gateway). 300 made the first attempt
    # plus the same-timeout fallback ~10 min before the reset-bearing answer
    # (2026-11-06 audit); 180 keeps attempt + fallback inside client patience.
    typeset -g _hop_request_timeout="$(_hosted_only_knob REQUEST_TIMEOUT 180)"
    # Image budget prune: content bytes before old inline images become path
    # notes; days a pruned copy is kept.
    typeset -g _hop_image_budget="$(_hosted_only_knob IMAGE_BUDGET_BYTES 2500000)"
    typeset -g _hop_image_cache_days="$(_hosted_only_knob IMAGE_CACHE_DAYS 1)"
}

_hosted_only_proxy_config() {
    local enmaas="$(_hosted_only_knob ENMAAS_BASE_URL "${ENMAAS_API_BASE_URL:-https://api.enmaas.devshift.net}")"
    enmaas="${enmaas%/}"
    enmaas="${enmaas%/v1}"
    # Both dialects of both models in one model_list (#599). The bare group
    # names carry the anthropic/ deployments (/v1/messages); the #openai-suffixed
    # groups carry the openai/ deployments (/v1, /v1/responses) and are chosen
    # by the Go proxy for OpenAI-wire call types, so a bare model_name shared by
    # both dialects cannot route a Messages request onto an openai deployment.
    local glm_anthropic="      model: \"anthropic/$_hop_glm\"
      api_base: \"$enmaas\""
    local glm_openai="      model: \"openai/$_hop_glm\"
      api_base: \"$enmaas/v1\""
    local ds_anthropic="${glm_anthropic//$_hop_glm/$_hop_deepseek}"
    local ds_openai="${glm_openai//$_hop_glm/$_hop_deepseek}"
    local timeout_line="      request_timeout: $_hop_request_timeout"
    print -r -- "model_list:
  - model_name: \"$_hop_glm\"
    litellm_params:
$glm_anthropic
      api_key: os.environ/ENMAAS_API_KEY
$timeout_line
  - model_name: \"$_hop_glm#openai\"
    litellm_params:
$glm_openai
      api_key: os.environ/ENMAAS_API_KEY
$timeout_line
  - model_name: \"$_hop_deepseek\"
    litellm_params:
$ds_anthropic
      api_key: os.environ/ENMAAS_API_KEY
$timeout_line
  - model_name: \"$_hop_deepseek#openai\"
    litellm_params:
$ds_openai
      api_key: os.environ/ENMAAS_API_KEY
$timeout_line"
    # Claude Code only remaps aliases via ANTHROPIC_DEFAULT_*_MODEL; clients that
    # pass an explicit id (T3's picker sends claude-sonnet-5-5) would hit "Invalid
    # model name". Serve that id from GLM so the client keeps Sonnet 5.5 behavior.
    print -r -- "  - model_name: \"claude-sonnet-5-5\"
    litellm_params:
$glm_anthropic
      api_key: os.environ/ENMAAS_API_KEY
$timeout_line"
    # The Go binary serves from the routes.json it writes itself; this YAML is
    # inert documentation and a fingerprint input (it tracks model/knob changes).
    print -r -- "general_settings:
  master_key: os.environ/HOSTED_ONLY_PROXY_TOKEN"
}

# _hosted_only_go_hash: sha256 over the Go module's sources.
_hosted_only_go_hash() {
    local src="$_HOSTED_ONLY_SCRIPTS/hosted-only-go"
    [[ -d "$src" ]] || { print -ru2 -- "hosted-only: missing $src"; return 1; }
    # Canonical source hash: sha256 over go.mod then every *.go in C-locale byte
    # order. The EnMaaS controller computes the same thing (go_source_hash), so
    # alternating hosted-only and EnMaaS launches share one source.sha stamp
    # instead of rebuilding the unchanged binary each time.
    ( cd "$src" && LC_ALL=C && cat go.mod *.go ) | shasum -a 256 | cut -d' ' -f1
}

# _hosted_only_go_bin: build (or reuse) the Go proxy binary in the state dir.
# Rebuilt when any module source changes, so an edit takes effect like a hook
# edit does on the LiteLLM path.
_hosted_only_go_bin() {
    local src="$_HOSTED_ONLY_SCRIPTS/hosted-only-go"
    [[ -d "$src" ]] || { print -ru2 -- "hosted-only: missing $src"; return 1; }
    command -v go >/dev/null || {
        print -ru2 -- 'hosted-only: go not found (needed for HOSTED_ONLY_PROXY_IMPL=go).'
        return 1
    }
    local out="${XDG_STATE_HOME:-$HOME/.local/state}/hosted-only-go"
    local bin="$out/hosted-only-proxy" stamp="$out/source.sha" want
    want=$(_hosted_only_go_hash) || return 1
    if [[ ! -x "$bin" || "$(<"$stamp" 2>/dev/null)" != "$want" ]]; then
        mkdir -p "$out" || return 1
        # Build to a private name and rename into place: go build -o removes
        # and rewrites its target, so two fleet-synced launches rebuilding at
        # once could otherwise exec a half-written binary.
        local tmpbin="$bin.$$"
        ( cd "$src" && go build -trimpath -o "$tmpbin" . ) || {
            rm -f "$tmpbin"
            print -ru2 -- 'hosted-only: go build failed; see the error above.'
            return 1
        }
        mv -f "$tmpbin" "$bin" || return 1
        print -r -- "$want" >| "$stamp" || return 1
    fi
    print -r -- "$bin"
}

# _hosted_only_proxy_fp [<config>]: prints one | -separated line
#   "<fingerprint>|<token-fp>|<dns-host>"
# for the current flavor (call _hosted_only_proxy_vars first). Same inputs as
# always — the generated config, the Go source hash, the DoH host, the key and
# the knobs. Everything travels on stdout: this runs inside a command
# substitution, so globals set here cannot reach the caller (the callers
# re-export the fields they need as _hop_* globals).
_hosted_only_proxy_fp() {
    local hooks_hash= dns_host=''
    hooks_hash=$(_hosted_only_go_hash) || return 1
    # The Go path resolves over DoH inside the binary; its fingerprint carries
    # the host (and DoH URL list), gated by the DNS_FALLBACK knob.
    if [[ "$(_hosted_only_knob DNS_FALLBACK 1)" != 0 ]]; then
        dns_host=$(_hosted_only_knob ENMAAS_BASE_URL "${ENMAAS_API_BASE_URL:-https://api.enmaas.devshift.net}")
        dns_host="${dns_host#*://}"
        dns_host="${dns_host%%/*}"
    fi
    local config="${1:-$(_hosted_only_proxy_config)}"
    # Every knob _hosted_only_go_env forwards is a fingerprint input: one left
    # out (IMAGE_TOKENS, IMAGE_CACHE_DIR, SEARCH_NUDGE) would let a running
    # proxy serve the old value as "fresh".
    local knobs="$(_hosted_only_knob OUTAGE_COALESCE_SECONDS 5) $_hop_vision_fallback $_hop_limit_rewrite $_hop_limit_retry $_hop_client_retry $_hop_fallback $_hop_aliases $_hop_request_timeout $(_hosted_only_knob STREAM_IDLE_TIMEOUT 300) $_hop_image_budget $_hop_image_cache_days $_hop_dialect $dns_host ${ENMAAS_DNS_DOH_URLS:-} $(_hosted_only_knob IMAGE_TOKENS 2500) $(_hosted_only_knob IMAGE_CACHE_DIR '') $(_hosted_only_knob SEARCH_NUDGE 1) $(_hosted_only_knob SEARCH_SHIM 0) $(_hosted_only_knob SEARCH_DAILY_CAP 500) $(_hosted_only_knob PARALLEL_BASE https://api.parallel.ai) $(_hosted_only_knob PARALLEL_PLATFORM https://platform.parallel.ai) $(_hosted_only_knob CLASSIFIER_ROUTE_MODEL '')"
    local fp token_fp
    fp=$(print -rn -- "$config"$'\x1f'"$hooks_hash"$'\x1f'"$ENMAAS_API_KEY"$'\x1f'"$knobs" \
        | shasum -a 256 | cut -d' ' -f1) || return 1
    token_fp=$(print -rn -- "$_hop_token" | shasum -a 256 | cut -d' ' -f1) || return 1
    print -r -- "$fp|$token_fp|$dns_host"
}

# _hosted_only_proxy_fp_load <line>: splits a _hosted_only_proxy_fp line and
# exports the fields as the _hop_* globals the spawn paths read (dns host).
_hosted_only_proxy_fp_load() {
    typeset -g _hop_fp= _hop_token_fp= _hop_dns_host=
    IFS='|' read -r _hop_fp _hop_token_fp _hop_dns_host <<< "$1"
}

# Every HOSTED_ONLY_* knob the Go config reads must be forwarded here: a setting
# made in .zshrc without `export` is visible to _hosted_only_knob but not to the
# child process, so a knob left out is silently ignored (tests/hosted-only-go-
# proxy.zsh fails when config.go reads one this list does not carry).
# _hosted_only_go_shared_env: fills _hog_shared (env-assignment words) with
# every Go-proxy knob that is NOT flavor- or deployment-specific. The
# hosted-only launcher (_hosted_only_go_env) AND the EnMaaS controller
# (_claude_enmaas_hook_env) forward this same list, so an improvement added
# here reaches every flavor of the one binary — the 2026-11-11 timeout knobs
# reached hosted-only and missed EnMaaS precisely because no such list existed.
# tests/go-proxy-knob-parity.zsh fails when config.go grows a HOSTED_ONLY_*
# knob this list does not carry, and when this list carries one config.go no
# longer reads.
#
# A flavor may pre-export HOSTED_ONLY_<NAME> (EnMaaS maps its
# ENMAAS_REQUEST_TIMEOUT / ENMAAS_STREAM_IDLE_TIMEOUT aliases onto the
# HOSTED_ONLY_ names before calling): _hosted_only_knob honors an already-set
# value over the default here.
_hosted_only_go_shared_env() {
    typeset -g -a _hog_shared
    _hog_shared=(
        "HOSTED_ONLY_VISION_FALLBACK=$(_hosted_only_knob VISION_FALLBACK 1)"
        "HOSTED_ONLY_FALLBACK=$(_hosted_only_knob FALLBACK 1)"
        "HOSTED_ONLY_OUTAGE_REWRITE=$(_hosted_only_knob OUTAGE_REWRITE 1)"
        "HOSTED_ONLY_OUTAGE_RETRY_SECONDS=$(_hosted_only_knob OUTAGE_RETRY_SECONDS 60)"
        "HOSTED_ONLY_OUTAGE_RETRY_MAX_SECONDS=$(_hosted_only_knob OUTAGE_RETRY_MAX_SECONDS 600)"
        "HOSTED_ONLY_OUTAGE_COALESCE_SECONDS=$(_hosted_only_knob OUTAGE_COALESCE_SECONDS 5)"
        "HOSTED_ONLY_IMAGE_BUDGET_BYTES=$(_hosted_only_knob IMAGE_BUDGET_BYTES 2500000)"
        "HOSTED_ONLY_IMAGE_CACHE_DAYS=$(_hosted_only_knob IMAGE_CACHE_DAYS 1)"
        "HOSTED_ONLY_IMAGE_TOKENS=$(_hosted_only_knob IMAGE_TOKENS 2500)"
        "HOSTED_ONLY_IMAGE_CACHE_DIR=$(_hosted_only_knob IMAGE_CACHE_DIR '')"
        "HOSTED_ONLY_LIMIT_REWRITE=$(_hosted_only_knob LIMIT_REWRITE 1)"
        "HOSTED_ONLY_RATE_LIMIT_DEFAULT_RETRY_SECONDS=$(_hosted_only_knob RATE_LIMIT_DEFAULT_RETRY_SECONDS 60)"
        "HOSTED_ONLY_CLIENT_RETRY_MAX_SECONDS=$(_hosted_only_knob CLIENT_RETRY_MAX_SECONDS 60)"
        "HOSTED_ONLY_MAX_MODEL_LEN=$(_hosted_only_knob MAX_MODEL_LEN 1048576)"
        "HOSTED_ONLY_OUTPUT_RESERVE=$(_hosted_only_knob OUTPUT_RESERVE 512)"
        "HOSTED_ONLY_BYTES_PER_TOKEN=$(_hosted_only_knob BYTES_PER_TOKEN 3)"
        "HOSTED_ONLY_MIN_OUTPUT=$(_hosted_only_knob MIN_OUTPUT 16000)"
        "HOSTED_ONLY_REQUEST_TIMEOUT=$(_hosted_only_knob REQUEST_TIMEOUT 300)"
        "HOSTED_ONLY_STREAM_IDLE_TIMEOUT=$(_hosted_only_knob STREAM_IDLE_TIMEOUT 300)"
        "HOSTED_ONLY_SEARCH_NUDGE=$(_hosted_only_knob SEARCH_NUDGE 1)"
        "HOSTED_ONLY_SEARCH_SHIM=$(_hosted_only_knob SEARCH_SHIM 0)"
        "HOSTED_ONLY_SEARCH_DAILY_CAP=$(_hosted_only_knob SEARCH_DAILY_CAP 500)"
        "HOSTED_ONLY_SEARCH_VERDICTS=$(_hosted_only_knob SEARCH_VERDICTS '')"
        "HOSTED_ONLY_PARALLEL_BASE=$(_hosted_only_knob PARALLEL_BASE https://api.parallel.ai)"
        "HOSTED_ONLY_PARALLEL_PLATFORM=$(_hosted_only_knob PARALLEL_PLATFORM https://platform.parallel.ai)"
        "HOSTED_ONLY_PARALLEL_STATE=$(_hosted_only_knob PARALLEL_STATE '')"
        "HOSTED_ONLY_PARALLEL_MCP=$(_hosted_only_knob PARALLEL_MCP https://mcp.parallel.ai/mcp)"
        "HOSTED_ONLY_PARALLEL_ACCOUNT=$(_hosted_only_knob PARALLEL_ACCOUNT https://api.parallel.ai/account)"
        "HOSTED_ONLY_CLASSIFIER_ROUTE_MODEL=$(_hosted_only_knob CLASSIFIER_ROUTE_MODEL '')"
        "HOSTED_ONLY_QUOTA_MONTH_TZ=$(_hosted_only_knob QUOTA_MONTH_TZ UTC)"
    )
}

# _hosted_only_go_env: fills _hop_go_env (env-assignment words) with the knobs
# the Go binary's serve child reads — the same set the LiteLLM branch pins —
# plus the Go-only pieces (outage-streak state file, DoH allow-list). Call
# _hosted_only_proxy_vars and _hosted_only_proxy_fp first.
_hosted_only_go_env() {
    _hosted_only_go_shared_env
    typeset -g -a _hop_go_env
    _hop_go_env=(
        "ENMAAS_API_KEY=$ENMAAS_API_KEY"
        "HOSTED_ONLY_ENMAAS_BASE_URL=$(_hosted_only_knob ENMAAS_BASE_URL "${ENMAAS_API_BASE_URL:-https://api.enmaas.devshift.net}")"
        "HOSTED_ONLY_PROXY_TOKEN=$_hop_token"
        "HOSTED_ONLY_GLM_MODEL=$_hop_glm"
        "HOSTED_ONLY_DEEPSEEK_MODEL=$_hop_deepseek"
        "HOSTED_ONLY_ALIAS_MODELS=$_hop_aliases"
        "${_hog_shared[@]}"
        "HOSTED_ONLY_OUTAGE_STATE=$_hop_runtime/outage-streak.json"
        "HOSTED_ONLY_DIALECT_SUFFIX=$_hop_dialect"
        "ENMAAS_DNS_FALLBACK_HOSTS=$_hop_dns_host"
    )
}

# _hosted_only_proxy_ensure <flavor>: proxy healthy with the current config, or
# return 1 (stderr says why). Sets _hop_base/_hop_token. Writes nothing to stdout.
#
# A running proxy whose recorded fingerprint differs (config, code, knobs, key)
# is restarted when no request is in flight. While it is serving one it is
# reused with a notice instead of failing the launch; only a token change,
# which the new client could not authenticate with, still refuses.
_hosted_only_proxy_ensure() {
    _hosted_only_proxy_vars "$1" || return 1
    local health="$_hop_base/health/liveliness"
    typeset -g _hop_gobin=
    local gobin
    gobin=$(_hosted_only_go_bin) || return 1
    [[ -n "${ENMAAS_API_KEY-}" ]] || { print -ru2 -- 'hosted-only: ENMAAS_API_KEY is not set.'; return 1; }

    local config fp token_fp fp_line
    config=$(_hosted_only_proxy_config)
    fp_line=$(_hosted_only_proxy_fp "$config") || return 1
    _hosted_only_proxy_fp_load "$fp_line"
    fp="$_hop_fp"
    token_fp="$_hop_token_fp"

    # Dry run for `llm-proxy-restart required`: HOSTED_ONLY_CHECK_OUT=<file>
    # gets "down|fresh|stale <fingerprint> <token hash>" and nothing is
    # touched; the return of 1 stops the launcher here.
    if [[ -n "${HOSTED_ONLY_CHECK_OUT-}" ]]; then
        local chk_fp= chk_token= verdict=down
        if curl -sf --max-time 2 "$health" -o /dev/null; then
            read -r chk_fp chk_token < "$_hop_runtime/fingerprint" 2>/dev/null
            if [[ "$chk_fp" == "$fp" && ( -z "$chk_token" || "$chk_token" == "$token_fp" ) ]]; then
                verdict=fresh
            else
                verdict=stale
            fi
        fi
        print -r -- "$verdict $fp $token_fp" >| "$HOSTED_ONLY_CHECK_OUT"
        return 1
    fi

    _hop_gobin="$gobin"

    # The binary's ensure subcommand owns the mechanics — startup.lock, the
    # stale/busy decision, the zero-refuse swap, detached spawn with log
    # rotation, the health wait and the fingerprint record — and takes the
    # lock itself.
    mkdir -p "$_hop_runtime" || return 1
    # Documents the merged config. The binary serves from routes.json, which
    # it writes itself from these knobs (so a watcher-driven restart never
    # pairs a new fingerprint with an old route table).
    print -r -- "$config" >| "$_hop_runtime/config.yaml" || return 1
    _hosted_only_go_env
    # One --legacy-runtime per directory: a single flag followed by several
    # words loses all but the first in the Go flag parser.
    local -a legacy=()
    local d
    for d in $_hop_legacy_runtimes; legacy+=(--legacy-runtime "$d")
    env "${_hop_go_env[@]}" "$gobin" ensure \
        --flavor "$_hop_flavor" --config "$_hop_runtime/routes.json" \
        --port "$_hop_port" --runtime-dir "$_hop_runtime" \
        --fingerprint "$fp" --token-fp "$token_fp" "${legacy[@]}" || return 1
    return 0
}

# _hosted_only_proxy_has_state: 0 when a proxy of the current flavor (set up
# by _hosted_only_proxy_vars) left a fingerprint in the current or a legacy
# runtime dir, i.e. a start failed because a live proxy differs, not because of
# a missing key.
_hosted_only_proxy_has_state() {
    local d
    [[ -f "$_hop_runtime/fingerprint" ]] && return 0
    for d in "${_hop_legacy_runtimes[@]}"; do
        [[ -f "$d/fingerprint" ]] && return 0
    done
    return 1
}

# _hosted_only_proxy_stop <flavor>: delegates to the binary's stop subcommand,
# which stops only a listener whose command line names this proxy's runtime
# (current or legacy dir: the flavor-named dirs before the merge, glm-hybrid
# before the rename; also retires a leftover LiteLLM listener from before the
# retirement). Stopping must not depend on launch prerequisites: _HOP_STOP_MODE
# skips impl validation, and when the binary cannot be built at all (no go
# toolchain, broken build) an identity-checked command-line match retires the
# listener instead, so a stale knob or a missing toolchain can never trap a
# running proxy.
_hosted_only_proxy_stop() {
    _HOP_STOP_MODE=1 _hosted_only_proxy_vars "$1" || return 1
    local gobin
    if ! gobin=$(_hosted_only_go_bin 2>/dev/null); then
        print -ru2 -- "hosted-only: Go binary unavailable; stopping $_hop_flavor proxy on :$_hop_port by config-path match."
        local pid stopped=0 cmd d
        local -a matches=("$_hop_runtime/config.yaml" "$_hop_runtime/routes.json")
        for d in "${_hop_legacy_runtimes[@]}"; do
            matches+=("$d/config.yaml" "$d/routes.json")
        done
        for pid in ${(f)"$(lsof -ti "tcp:$_hop_port" -sTCP:LISTEN 2>/dev/null)"}; do
            cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
            local hit=0 m
            for m in $matches; do
                [[ "$cmd" == *"$m"* ]] && hit=1
            done
            if (( hit )); then
                kill "$pid" 2>/dev/null && stopped=1
            else
                print -ru2 -- "hosted-only: port $_hop_port is held by another process (pid $pid); leaving it alone."
                return 1
            fi
        done
        rm -f "$_hop_runtime/fingerprint" 2>/dev/null
        for d in "${_hop_legacy_runtimes[@]}"; do
            rm -f "$d/fingerprint" 2>/dev/null
        done
        (( stopped )) && print -ru2 -- "hosted-only: stopped $_hop_flavor proxy on port $_hop_port."
        return 0
    fi
    local -a legacy=()
    local d
    for d in $_hop_legacy_runtimes; legacy+=(--legacy-runtime "$d")
    "$gobin" stop --flavor "$_hop_flavor" --port "$_hop_port" --runtime-dir "$_hop_runtime" "${legacy[@]}"
    return $?
}
