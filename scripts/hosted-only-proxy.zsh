# Sourced library (not executable): the hosted-only LiteLLM proxies.
#
# Takes effect: see docs/notes/change-take-effect.md. Hook/config edits change the fingerprint, so an IDLE proxy
# restarts on the next launch or fleet-sync run; a busy one waits for the
# watcher. Sourced functions are live in NEW shells only.
#
# Hosted-only = EnMaaS-hosted free models only: GLM 5.3 (text) and DeepSeek
# V4.1 Flash (1M context, vision). Codex's auto-review and Claude Code's
# auto-mode classifier send their review request to the same endpoint as the
# main model, so one local endpoint routes by model id and every tier, reviewer
# and helper call stays on the two hosted models (no paid side-channel calls,
# no OpenAI key). One shared proxy serves BOTH client flavors (#599): each
# model gets an anthropic/ deployment (Messages, bare group name) and an
# openai/ deployment (Responses/chat, group name suffixed #openai), and the
# pre-call hook picks the dialect from the call type, so the clients keep
# their bare model ids:
#
#   shared  127.0.0.1:${HOSTED_ONLY_CLAUDE_PROXY_PORT:-4148}  used by
#           claude-hosted-only (zsh/functions/claude/providers/hosted-only.zsh)
#           and scripts/codex-provider.zsh hosted-only alike.
#           HOSTED_ONLY_CODEX_PROXY_PORT splits a second proxy off (same merged
#           config) for testing.
# Both load hosted_only_hooks.py (rits/ models only): strips the grammar vLLM
# rejects from Codex's apply_patch, cuts default reasoning on Messages requests
# that send no thinking field (Claude Code's auto-mode classifier), sends GLM
# requests that carry an image (GLM 400s on any image in history) to DeepSeek
# (HOSTED_ONLY_VISION_FALLBACK=0 disables), and rewrites EnMaaS 429s so T3 Code
# can auto-resume a limited thread (see hosted_only_hooks.py item 5;
# HOSTED_ONLY_LIMIT_REWRITE=0 disables, per-minute default wait
# HOSTED_ONLY_RATE_LIMIT_DEFAULT_RETRY_SECONDS (60), waits longer than
# HOSTED_ONLY_CLIENT_RETRY_MAX_SECONDS (60) fail fast to T3). Monthly quota on
# the OpenAI chat route (/v1/chat/completions, OpenCode) becomes HTTP 402
# insufficient_quota without retry-after, since OpenCode retries every 429.
# LiteLLM's own upstream retries are off (HOSTED_ONLY_UPSTREAM_RETRIES, 0).
# litellm_usage_log.py also loads (all models): per-request JSONL for
# `llm-usage` (requested vs served model, tokens, latency, errors).
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
# (gateway root; default $ENMAAS_API_BASE_URL), HOSTED_ONLY_LITELLM_VERSION,
# HOSTED_ONLY_FASTAPI_VERSION, HOSTED_ONLY_LITELLM_LOG (default ERROR; INFO logs
# each routed model). HOSTED_ONLY_UPSTREAM_RETRIES (default 0; router_settings
# num_retries). HOSTED_ONLY_CLIENT_MAX_RETRIES (Claude Code only) is read by
# the claude launcher, not here. HOSTED_ONLY_MODEL (main model pick), HOSTED_ONLY_REVIEW_MODEL,
# HOSTED_ONLY_CLASSIFIER_MODEL, HOSTED_ONLY_SMALL_FAST_MODEL are read by the
# launchers, not here.
#
# History: a "GLM hybrid" mode once added an OpenAI reviewer (gpt-6-luna) to
# this proxy. DeepSeek V4.1 Flash now covers reviewer, classifier and vision
# inside hosted-only, so that mode is retired; its old names are aliases.
#
# Lifecycle: started on demand as a detached session (outlives the client),
# state in ~/.local/state/hosted-only-<flavor>-<port>/ (0700; proxies started
# before the rename keep running from the legacy glm-hybrid-<flavor>-<port>/ dir
# and the stop helper handles both). A running proxy whose config/key/versions
# differ is never restarted under active sessions; the caller gets an error
# naming the stop command:
#   zsh -f <dotfiles>/scripts/codex-provider.zsh hosted-only --stop-proxy   (codex)
#   claude-hosted-only-kill                                                  (claude)
# On the Go impl the mechanics (lock, stale/busy decision, spawn, health wait,
# stop, idle watcher) live in the binary's ensure/stop/watch subcommands; the
# fingerprint inputs stay here (see docs/notes/hosted-only-go-proxy.md).

typeset -g _HOSTED_ONLY_SCRIPTS="${${(%):-%x}:A:h}"

# _hosted_only_knob <NAME> <default>: $HOSTED_ONLY_<NAME>, else the retired
# $GLM_HYBRID_<NAME>, else the default.
_hosted_only_knob() {
    local new="HOSTED_ONLY_$1" old="GLM_HYBRID_$1"
    print -r -- "${${(P)new}:-${${(P)old}:-$2}}"
}

# _hosted_only_resolve_impl <value>: `auto` (or empty) -> go when a go toolchain
# is installed, else litellm; anything else is returned as given (the caller
# validates it).
_hosted_only_resolve_impl() {
    case "${1:-auto}" in
        auto) (( $+commands[go] )) && print -r -- go || print -r -- litellm ;;
        *) print -r -- "$1" ;;
    esac
}

# _hosted_only_impl: the resolved proxy impl for the hosted-only launchers.
# Precedence: HOSTED_ONLY_PROXY_IMPL (or its retired GLM_HYBRID_ name), then
# LLM_PROXY_IMPL (flips every proxy), then auto.
_hosted_only_impl() {
    _hosted_only_resolve_impl "$(_hosted_only_knob PROXY_IMPL "${LLM_PROXY_IMPL:-auto}")"
}

# _hosted_only_proxy_vars <flavor>: sets _hop_* globals for the flavor.
_hosted_only_proxy_vars() {
    case "$1" in
        codex|claude) : ;;
        *) print -ru2 -- 'hosted-only: flavor must be codex or claude.'; return 1 ;;
    esac
    typeset -g _hop_flavor="$1"
    # One shared proxy serves both flavors (#599): the pre-call hook routes
    # OpenAI-wire requests to the openai/ deployments with a #openai model-group
    # suffix, so both clients keep their bare model ids on one port. Saves a
    # whole LiteLLM process (~58 MB idle, up to ~350 MB loaded, 3.7 s import)
    # per machine. HOSTED_ONLY_CODEX_PROXY_PORT still splits it off (defaults to
    # the shared claude port); a split-off proxy serves the same merged config.
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
    # The Go proxy (scripts/hosted-only-go, stdlib only) is the default; LiteLLM
    # stays the escape hatch (HOSTED_ONLY_PROXY_IMPL=litellm, or LLM_PROXY_IMPL=
    # litellm for every proxy at once). `auto` — the default — is go when a go
    # toolchain is installed, else litellm. Same knobs, ports, token, fingerprint
    # protocol and stop command on both; the knob is part of the fingerprint.
    typeset -g _hop_impl="$(_hosted_only_impl)"
    typeset -g _hop_glm="$(_hosted_only_knob GLM_MODEL "${GLM_HYBRID_MODEL:-rits/zai-org/glm-5-3}")"
    typeset -g _hop_deepseek="$(_hosted_only_knob DEEPSEEK_MODEL rits/deepseek-ai/DeepSeek-V4.1-Flash-1017)"
    typeset -g _hop_vision_fallback="$(_hosted_only_knob VISION_FALLBACK 1)"
    typeset -g _hop_limit_rewrite="$(_hosted_only_knob LIMIT_REWRITE 1)"
    typeset -g _hop_limit_retry="$(_hosted_only_knob RATE_LIMIT_DEFAULT_RETRY_SECONDS 60)"
    typeset -g _hop_client_retry="$(_hosted_only_knob CLIENT_RETRY_MAX_SECONDS 60)"
    typeset -g _hop_upstream_retries="$(_hosted_only_knob UPSTREAM_RETRIES 0)"
    # Model fallback GLM <-> DeepSeek (hosted_only_hooks.py item 7) and the
    # outage rewrite it shares knobs with. ALIAS_MODELS: ids served from the GLM
    # deployment (claude flavor's claude-sonnet-5-5 alias) that get GLM's vision
    # reroute and fallback target.
    typeset -g _hop_fallback="$(_hosted_only_knob FALLBACK 1) $(_hosted_only_knob OUTAGE_REWRITE 1) $(_hosted_only_knob OUTAGE_RETRY_SECONDS 60) $(_hosted_only_knob OUTAGE_RETRY_MAX_SECONDS 600) $(_hosted_only_knob MAX_MODEL_LEN 1048576) $(_hosted_only_knob OUTPUT_RESERVE 512) $(_hosted_only_knob BYTES_PER_TOKEN 3) $(_hosted_only_knob MIN_OUTPUT 16000)"
    # The merged config always serves the claude-sonnet-5-5 alias from the GLM
    # (anthropic) deployment, so both flavors record the same value and the
    # shared fingerprint stays flavor-independent.
    typeset -g _hop_aliases="$(_hosted_only_knob ALIAS_MODELS claude-sonnet-5-5)"
    # Dialect-suffix routing is opt-in in the hook (the EnMaaS proxy loads the
    # same file); this proxy turns it on.
    typeset -g _hop_dialect="$(_hosted_only_knob DIALECT_SUFFIX "#openai")"
    # LiteLLM request_timeout per deployment: a hung upstream (connection up,
    # no answer, no gateway 504) is cut at this many seconds so the outage
    # rewrite and the model fallback can fire instead of stalling the turn for
    # LiteLLM's 600 s default. Generous enough for 1M-token prompts (a 900k
    # prefill took 98 s on the congested gateway). 300 made the first attempt
    # plus the same-timeout fallback ~10 min before the reset-bearing answer
    # (2026-11-06 audit); 180 keeps attempt + fallback inside client patience.
    typeset -g _hop_request_timeout="$(_hosted_only_knob REQUEST_TIMEOUT 180)"
    # Image budget prune (hosted_only_hooks.py item 6): content bytes before
    # old inline images become path notes; days a pruned copy is kept.
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
    # by the pre-call hook for OpenAI-wire call types, so a bare model_name
    # shared by both dialects cannot make the router load-balance a Messages
    # request onto an openai deployment.
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
    print -r -- "litellm_settings:
  drop_params: true"
    print -r -- '  callbacks: ["hosted_only_hooks.proxy_handler_instance", "litellm_usage_log.proxy_handler_instance"]'
    # LiteLLM retries every failed upstream call (default 2, so each 429 costs 3
    # upstream hits and ~2.7 s) and the clients retry on their own. Verified in
    # litellm 1.97.0: router_settings keys become Router.__init__ args
    # (proxy/proxy_server.py:5170-5189, valid keys from router.py:807-815);
    # num_retries sets Router.num_retries (router.py:641-646, default 2 =
    # openai.DEFAULT_MAX_RETRIES), which async_function_with_retries uses when the
    # request carries none (router.py:6511-6516). /v1/chat/completions
    # (acompletion, router.py:2044), /v1/responses (aresponses ->
    # _ageneric_api_call_with_fallbacks, router.py:4645) and the /v1/messages
    # passthrough (anthropic_messages, router.py:5806-5832 ->
    # _ageneric_api_call_with_fallbacks) all reach it via
    # async_function_with_fallbacks. A per-deployment litellm_params.num_retries
    # would only apply when the request sets none (router.py:6540-6547).
    print -r -- "router_settings:
  num_retries: $_hop_upstream_retries"
    # Request-level fallbacks do not survive the anthropic /v1/messages
    # passthrough (it rebuilds the call kwargs), so Claude Code saw "No
    # fallback was attempted" on a Failoverable error. Router-level fallbacks
    # are honored on every route; the request-level list still wins where it
    # does apply (responses/chat), and skips images.
    if [[ "$_hop_glm" != "$_hop_deepseek" ]]; then
        print -r -- "  fallbacks: [{\"$_hop_glm\": [\"$_hop_deepseek\"]}, {\"$_hop_deepseek\": [\"$_hop_glm\"]}, {\"$_hop_glm#openai\": [\"$_hop_deepseek#openai\"]}, {\"$_hop_deepseek#openai\": [\"$_hop_glm#openai\"]}]"
    fi
    print -r -- "general_settings:
  master_key: os.environ/HOSTED_ONLY_PROXY_TOKEN"
}

# _hosted_only_code_hash <file...>: sha256 over the Python files' ASTs, so a
# comment, docstring or formatting edit to a hook does not count as a change.
_hosted_only_code_hash() {
    python3 -I - "$@" <<'PY'
import ast, hashlib, sys
digest = hashlib.sha256()
for path in sys.argv[1:]:
    data = open(path, 'rb').read()
    try:
        tree = ast.parse(data)
    except SyntaxError:
        digest.update(data)
        continue
    for node in ast.walk(tree):
        body = getattr(node, 'body', None)
        if (isinstance(body, list) and body and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, ast.Constant) and isinstance(body[0].value.value, str)):
            node.body = body[1:] or [ast.Pass()]
    digest.update(ast.dump(tree).encode() + b'\0')
print(digest.hexdigest())
PY
}

# _hosted_only_go_hash: sha256 over the Go module's sources.
_hosted_only_go_hash() {
    local src="$_HOSTED_ONLY_SCRIPTS/hosted-only-go"
    [[ -d "$src" ]] || { print -ru2 -- "hosted-only: missing $src"; return 1; }
    ( cd "$src" && cat go.mod *.go ) | shasum -a 256 | cut -d' ' -f1
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
#   "<fingerprint>|<token-fp>|<dns-hash>|<dns-host>|<litellm-version>|<fastapi-version>"
# for the current flavor and impl (call _hosted_only_proxy_vars first). Same
# inputs as always — the generated config, the impl's code hash, the DoH
# pieces, the key and the knobs — so a Go and a LiteLLM launch of the same
# knobs restart each other. Everything travels on stdout: this runs inside a
# command substitution, so globals set here cannot reach the caller (the
# callers re-export the fields they need as _hop_* globals).
_hosted_only_proxy_fp() {
    local impl="$_hop_impl" litellm_version= fastapi_version= hooks_hash= dns_hash='' dns_host=''
    if [[ "$impl" == go ]]; then
        hooks_hash=$(_hosted_only_go_hash) || return 1
    else
        litellm_version="$(_hosted_only_knob LITELLM_VERSION 1.97.0)"
        fastapi_version="$(_hosted_only_knob FASTAPI_VERSION 0.136.3)"
        hooks_hash=$(_hosted_only_code_hash "$_HOSTED_ONLY_SCRIPTS/hosted_only_hooks.py" "$_HOSTED_ONLY_SCRIPTS/litellm_usage_log.py") || return 1
    fi
    # The runtime shim (dns_fallback.py, installed as sitecustomize.py) is
    # hashed into the fingerprint for the LiteLLM impl: it carries the
    # SO_REUSEPORT patch the zero-refuse restart depends on plus the env-gated
    # DoH fallback for the gateway name. HOSTED_ONLY_DNS_FALLBACK=0 disables
    # just the DoH part (empty ENMAAS_DNS_FALLBACK_HOSTS) and changes the
    # fingerprint; the uvicorn patch is always on. The Go path resolves over
    # DoH inside the binary, so its fingerprint carries the host (and DoH URL
    # list) instead, still gated by the same knob.
    if [[ "$impl" == litellm ]]; then
        dns_hash=$(_hosted_only_code_hash "$_HOSTED_ONLY_SCRIPTS/dns_fallback.py") || return 1
    fi
    if [[ "$(_hosted_only_knob DNS_FALLBACK 1)" != 0 ]]; then
        dns_host=$(_hosted_only_knob ENMAAS_BASE_URL "${ENMAAS_API_BASE_URL:-https://api.enmaas.devshift.net}")
        dns_host="${dns_host#*://}"
        dns_host="${dns_host%%/*}"
    fi
    local config="${1:-$(_hosted_only_proxy_config)}"
    local knobs="$(_hosted_only_knob OUTAGE_COALESCE_SECONDS 5) $litellm_version $fastapi_version $_hop_vision_fallback $_hop_limit_rewrite $_hop_limit_retry $_hop_client_retry $_hop_upstream_retries $_hop_fallback $_hop_aliases $_hop_request_timeout $_hop_image_budget $_hop_image_cache_days $_hop_dialect"
    [[ "$impl" == go ]] && knobs="$knobs $dns_host ${ENMAAS_DNS_DOH_URLS:-}"
    local fp token_fp
    fp=$(print -rn -- "$config"$'\x1f'"$hooks_hash"$'\x1f'"$dns_hash"$'\x1f'"$ENMAAS_API_KEY"$'\x1f'"$knobs" \
        | shasum -a 256 | cut -d' ' -f1) || return 1
    token_fp=$(print -rn -- "$_hop_token" | shasum -a 256 | cut -d' ' -f1) || return 1
    print -r -- "$fp|$token_fp|$dns_hash|$dns_host|$litellm_version|$fastapi_version"
}

# _hosted_only_proxy_fp_load <line>: splits a _hosted_only_proxy_fp line and
# exports the fields as the _hop_* globals the spawn paths read (dns, versions).
_hosted_only_proxy_fp_load() {
    typeset -g _hop_fp= _hop_token_fp= _hop_dns_hash= _hop_dns_host= _hop_litellm_version= _hop_fastapi_version=
    IFS='|' read -r _hop_fp _hop_token_fp _hop_dns_hash _hop_dns_host _hop_litellm_version _hop_fastapi_version <<< "$1"
}

# Every HOSTED_ONLY_* knob the Go config reads must be forwarded here: a setting
# made in .zshrc without `export` is visible to _hosted_only_knob but not to the
# child process, so a knob left out is silently ignored (tests/hosted-only-go-
# proxy.zsh fails when config.go reads one this list does not carry).
# _hosted_only_go_env: fills _hop_go_env (env-assignment words) with the knobs
# the Go binary's serve child reads — the same set the LiteLLM branch pins —
# plus the Go-only pieces (outage-streak state file, DoH allow-list). Call
# _hosted_only_proxy_vars and _hosted_only_proxy_fp first.
_hosted_only_go_env() {
    typeset -g -a _hop_go_env
    _hop_go_env=(
        "ENMAAS_API_KEY=$ENMAAS_API_KEY"
        "HOSTED_ONLY_ENMAAS_BASE_URL=$(_hosted_only_knob ENMAAS_BASE_URL "${ENMAAS_API_BASE_URL:-https://api.enmaas.devshift.net}")"
        "HOSTED_ONLY_PROXY_TOKEN=$_hop_token"
        "HOSTED_ONLY_GLM_MODEL=$_hop_glm"
        "HOSTED_ONLY_DEEPSEEK_MODEL=$_hop_deepseek"
        "HOSTED_ONLY_VISION_FALLBACK=$_hop_vision_fallback"
        "HOSTED_ONLY_ALIAS_MODELS=$_hop_aliases"
        "HOSTED_ONLY_FALLBACK=$(_hosted_only_knob FALLBACK 1)"
        "HOSTED_ONLY_OUTAGE_REWRITE=$(_hosted_only_knob OUTAGE_REWRITE 1)"
        "HOSTED_ONLY_OUTAGE_STATE=$_hop_runtime/outage-streak.json"
        "HOSTED_ONLY_OUTAGE_RETRY_SECONDS=$(_hosted_only_knob OUTAGE_RETRY_SECONDS 60)"
        "HOSTED_ONLY_OUTAGE_RETRY_MAX_SECONDS=$(_hosted_only_knob OUTAGE_RETRY_MAX_SECONDS 600)"
        "HOSTED_ONLY_OUTAGE_COALESCE_SECONDS=$(_hosted_only_knob OUTAGE_COALESCE_SECONDS 5)"
        "HOSTED_ONLY_IMAGE_BUDGET_BYTES=$_hop_image_budget"
        "HOSTED_ONLY_IMAGE_CACHE_DAYS=$_hop_image_cache_days"
        "HOSTED_ONLY_IMAGE_TOKENS=$(_hosted_only_knob IMAGE_TOKENS 2500)"
        "HOSTED_ONLY_IMAGE_CACHE_DIR=$(_hosted_only_knob IMAGE_CACHE_DIR '')"
        "HOSTED_ONLY_LIMIT_REWRITE=$_hop_limit_rewrite"
        "HOSTED_ONLY_RATE_LIMIT_DEFAULT_RETRY_SECONDS=$_hop_limit_retry"
        "HOSTED_ONLY_CLIENT_RETRY_MAX_SECONDS=$_hop_client_retry"
        "HOSTED_ONLY_MAX_MODEL_LEN=$(_hosted_only_knob MAX_MODEL_LEN 1048576)"
        "HOSTED_ONLY_OUTPUT_RESERVE=$(_hosted_only_knob OUTPUT_RESERVE 512)"
        "HOSTED_ONLY_BYTES_PER_TOKEN=$(_hosted_only_knob BYTES_PER_TOKEN 3)"
        "HOSTED_ONLY_MIN_OUTPUT=$(_hosted_only_knob MIN_OUTPUT 16000)"
        "HOSTED_ONLY_REQUEST_TIMEOUT=$_hop_request_timeout"
        "HOSTED_ONLY_SEARCH_NUDGE=$(_hosted_only_knob SEARCH_NUDGE 1)"
        "HOSTED_ONLY_DIALECT_SUFFIX=$_hop_dialect"
        "ENMAAS_DNS_FALLBACK_HOSTS=$_hop_dns_host"
    )
}

# _hosted_only_busy <port>: 0 when a request is in flight on the port. Same
# in-flight-file idle test llm-proxy-sync uses (2026-11-06 audit): a keep-alive
# pool holds ESTABLISHED sockets between requests, so the old socket-only test
# read "busy" forever and blocked fingerprint restarts. Falls back to the
# socket test when the listener reports nothing (common.zsh not loaded).
_hosted_only_busy() {
    if (( $+functions[_claude_port_serving] )); then
        _claude_port_serving "$1"
    else
        lsof -nP -iTCP:"$1" -sTCP:ESTABLISHED -Fn 2>/dev/null | grep -q -- "^n.*:$1->"
    fi
}

# _hosted_only_proxy_launch: start the proxy for the current flavor/impl
# (globals from _hosted_only_proxy_vars + ensure's $config already written).
# _hosted_only_proxy_launch: start the LiteLLM proxy (globals from
# _hosted_only_proxy_vars + ensure's $config already written; the Go impl never
# reaches this — its ensure subcommand owns the whole start).
_hosted_only_proxy_launch() {
    cp -f "$_hop_hooks" "$_hop_runtime/hosted_only_hooks.py" || return 1
    cp -f "$_hop_usage_log" "$_hop_runtime/litellm_usage_log.py" || return 1
    # The runtime shim is ALWAYS installed: besides the env-gated DoH
    # fallback it forces uvicorn's SO_REUSEPORT, which the zero-refuse
    # restart below depends on. ENMAAS_DNS_FALLBACK_HOSTS stays empty to
    # disable just the DoH part.
    cp -f "$_HOSTED_ONLY_SCRIPTS/dns_fallback.py" "$_hop_runtime/sitecustomize.py" || return 1
    local -a dns_env=(PYTHONPATH="$_hop_runtime")
    [[ -n "$_hop_dns_host" ]] && dns_env+=(ENMAAS_DNS_FALLBACK_HOSTS="$_hop_dns_host")
    ENMAAS_API_KEY="$ENMAAS_API_KEY" HOSTED_ONLY_PROXY_TOKEN="$_hop_token" \
        HOSTED_ONLY_GLM_MODEL="$_hop_glm" HOSTED_ONLY_DEEPSEEK_MODEL="$_hop_deepseek" HOSTED_ONLY_VISION_FALLBACK="$_hop_vision_fallback" \
        HOSTED_ONLY_ALIAS_MODELS="$_hop_aliases" HOSTED_ONLY_OUTAGE_STATE="$_hop_runtime/outage-streak.json" \
        HOSTED_ONLY_LIMIT_REWRITE="$_hop_limit_rewrite" HOSTED_ONLY_RATE_LIMIT_DEFAULT_RETRY_SECONDS="$_hop_limit_retry" HOSTED_ONLY_CLIENT_RETRY_MAX_SECONDS="$_hop_client_retry" LITELLM_LOG="$(_hosted_only_knob LITELLM_LOG ERROR)" \
        HOSTED_ONLY_IMAGE_BUDGET_BYTES="$_hop_image_budget" HOSTED_ONLY_IMAGE_CACHE_DAYS="$_hop_image_cache_days" HOSTED_ONLY_DIALECT_SUFFIX="$_hop_dialect" \
        HOSTED_ONLY_MAX_MODEL_LEN="$(_hosted_only_knob MAX_MODEL_LEN 1048576)" HOSTED_ONLY_OUTPUT_RESERVE="$(_hosted_only_knob OUTPUT_RESERVE 512)" HOSTED_ONLY_BYTES_PER_TOKEN="$(_hosted_only_knob BYTES_PER_TOKEN 3)" HOSTED_ONLY_MIN_OUTPUT="$(_hosted_only_knob MIN_OUTPUT 16000)" \
        env "${dns_env[@]}" \
        python3 "$_HOSTED_ONLY_SCRIPTS/claude-provider.py" --background "$_hop_runtime/proxy.log" \
        uv tool run --with "fastapi==$_hop_fastapi_version" --from "litellm[proxy]==$_hop_litellm_version" litellm \
        --config "$_hop_runtime/config.yaml" --host 127.0.0.1 --port "$_hop_port" --telemetry False || return 1
}

# _hosted_only_boot_wait <port> [<old-pids>]: 0 once a listener that is not one
# of <old-pids> is up and health answers. During a zero-refuse swap the OLD
# proxy also answers health, so the listener set — not health — is the
# readiness signal for the new one.
_hosted_only_boot_wait() {
    local port="$1" old="${2-}" health="$_hop_base/health/liveliness"
    local boot_max="${LLM_PROXY_SYNC_UP_TIMEOUT:-180}"
    [[ "$boot_max" == <-> ]] || boot_max=180
    local -i i seen
    local pid
    local -a listeners oldlist=(${(f)old})
    print -nu2 -- "hosted-only: starting $_hop_flavor proxy on :$port "
    for (( i = 0; i < boot_max; i++ )); do
        listeners=(${(f)"$(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null)"})
        seen=0
        for pid in $listeners; do
            (( ${oldlist[(Ie)$pid]} )) && continue
            seen=1
            break
        done
        (( seen )) && break
        print -nu2 -- .
        sleep 1
    done
    print -u2
    # 90 s was not enough on a small host (the same LiteLLM took 96 s on
    # WSL, see proxies.zsh); a miss left no fingerprint so every later sync
    # re-labeled the proxy stale (2026-11-06 audit)
    (( seen )) || return 1
    curl -sf --max-time 5 "$health" -o /dev/null
}

# _hosted_only_retire <pids>: kill the old swap listener(s) by pid and wait.
# Never via _hosted_only_proxy_stop during a swap: both processes run the same
# config path, so the stop helper's identity check would match the new one too.
_hosted_only_retire() {
    local pid alive
    local -i i
    for pid in ${(f)${1-}}; do
        kill "$pid" 2>/dev/null
    done
    for (( i = 0; i < 30; i++ )); do
        alive=""
        for pid in ${(f)${1-}}; do
            kill -0 "$pid" 2>/dev/null && alive="$alive $pid"
        done
        [[ -z "$alive" ]] && return 0
        sleep 0.5
    done
    return 1
}

# _hosted_only_proxy_ensure <flavor>: proxy healthy with the current config, or
# return 1 (stderr says why). Sets _hop_base/_hop_token. Writes nothing to stdout.
#
# A running proxy whose recorded fingerprint differs (config, hooks, knobs,
# key, versions) is restarted when no request is in flight. While it is serving
# one it is reused with a notice instead of failing the launch; only a token
# change, which the new client could not authenticate with, still refuses.
_hosted_only_proxy_ensure() {
    _hosted_only_proxy_vars "$1" || return 1
    local health="$_hop_base/health/liveliness"
    local impl="$_hop_impl"
    # _hosted_only_proxy_launch (a separate function) needs these: function
    # locals do not cross the call, so they are globals like the _hop_* set.
    # The version and DNS globals come from _hosted_only_proxy_fp_load below.
    typeset -g _hop_hooks= _hop_usage_log= _hop_gobin=
    local hooks= usage_log= gobin=
    if [[ "$impl" == go ]]; then
        gobin=$(_hosted_only_go_bin) || return 1
    elif [[ "$impl" == litellm ]]; then
        hooks="$_HOSTED_ONLY_SCRIPTS/hosted_only_hooks.py"
        usage_log="$_HOSTED_ONLY_SCRIPTS/litellm_usage_log.py"
        command -v uv >/dev/null || { print -ru2 -- 'hosted-only: uv not found.'; return 1; }
        [[ -r "$hooks" ]] || { print -ru2 -- "hosted-only: missing $hooks"; return 1; }
        [[ -r "$usage_log" ]] || { print -ru2 -- "hosted-only: missing $usage_log"; return 1; }
    else
        print -ru2 -- "hosted-only: HOSTED_ONLY_PROXY_IMPL must be litellm or go (got '$impl')."
        return 1
    fi
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

    _hop_hooks="$hooks" _hop_usage_log="$usage_log" _hop_gobin="$gobin"

    # Go impl: the binary's ensure subcommand owns the mechanics — startup.lock,
    # the stale/busy decision, the zero-refuse swap, detached spawn with log
    # rotation, the health wait and the fingerprint record. It takes the lock
    # itself, so it must run OUTSIDE the zsh flock below; the LiteLLM path
    # keeps its own.
    if [[ "$impl" == go ]]; then
        mkdir -p "$_hop_runtime" || return 1
        # Kept for parity with the LiteLLM runtime dir: documents the merged
        # config. The binary serves from routes.json, which it writes itself
        # from these knobs (so a watcher-driven restart never pairs a new
        # fingerprint with an old route table).
        print -r -- "$config" >| "$_hop_runtime/config.yaml" || return 1
        _hosted_only_go_env
        # One --legacy-runtime per directory: a single flag followed by
        # several words loses all but the first in the Go flag parser.
        local -a legacy=()
        local d
        for d in $_hop_legacy_runtimes; legacy+=(--legacy-runtime "$d")
        env "${_hop_go_env[@]}" "$gobin" ensure \
            --flavor "$_hop_flavor" --config "$_hop_runtime/routes.json" \
            --port "$_hop_port" --runtime-dir "$_hop_runtime" \
            --fingerprint "$fp" --token-fp "$token_fp" "${legacy[@]}" || return 1
        return 0
    fi

    local old_umask=$(umask) lockfd result=0
    umask 077
    {
        mkdir -p "$_hop_runtime" && : >> "$_hop_runtime/startup.lock" || return 1
        zmodload zsh/system || return 1
        zsystem flock -t 120 -f lockfd "$_hop_runtime/startup.lock" || {
            print -ru2 -- "hosted-only: timed out waiting for another $_hop_flavor proxy start."
            return 1
        }
        local start=1 rec_fp= rec_token= swap_pids='' 
        if curl -sf --max-time 2 "$health" -o /dev/null; then
            start=0
            # "<fingerprint> <token hash>"; files from before the split hold one
            # field, and an unknown token hash is taken as unchanged.
            read -r rec_fp rec_token < "$_hop_runtime/fingerprint" 2>/dev/null
            if [[ "$rec_fp" != "$fp" || ( -n "$rec_token" && "$rec_token" != "$token_fp" ) || -n "${HOSTED_ONLY_FORCE_RESTART-}" ]]; then
                if ! _hosted_only_busy "$_hop_port" || [[ -n "${HOSTED_ONLY_FORCE_RESTART-}" ]]; then
                    # Zero-refuse restart (2026-11-06, RH Career ECONNREFUSED):
                    # start the new proxy ALONGSIDE the old one — both
                    # listeners set SO_REUSEPORT via the runtime shim — and
                    # retire the old pids only once the new listener is up, so
                    # a request arriving mid-restart is never refused. The
                    # first restart after rollout still stops first (the old
                    # listener predates the patch and cannot share the port);
                    # the boot-wait fallback below handles that case.
                    swap_pids=$(lsof -ti "tcp:$_hop_port" -sTCP:LISTEN 2>/dev/null)
                    print -ru2 -- "hosted-only: $_hop_flavor proxy config, hooks or key changed; restarting the proxy on :$_hop_port${swap_pids:+ (zero-gap swap)}."
                    start=1
                elif [[ -n "$rec_token" && "$rec_token" != "$token_fp" ]]; then
                    print -ru2 -- "hosted-only: the running $_hop_flavor proxy on :$_hop_port uses a different proxy token and is serving requests; run ${_hop_flavor}-hosted-only-restart once they finish."
                    result=1
                else
                    print -ru2 -- "hosted-only: $_hop_flavor proxy config, hooks or key changed, but it is serving requests; reusing it (${_hop_flavor}-hosted-only-restart applies the change now)."
                fi
            fi
        fi
        if (( start && ! result )); then
            print -r -- "$config" >| "$_hop_runtime/config.yaml" || return 1
            rm -f "$_hop_runtime/fingerprint"
            _hosted_only_proxy_launch || return 1
            if _hosted_only_boot_wait "$_hop_port" "$swap_pids"; then
                # new listener is up: retire the old one(s); requests were
                # never refused because both listeners held the port
                [[ -n "$swap_pids" ]] && _hosted_only_retire "$swap_pids"
                print -r -- "$fp $token_fp" >| "$_hop_runtime/fingerprint"
            elif [[ -n "$swap_pids" ]] && { local alive=""; local p; for p in ${(f)swap_pids}; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done; [[ -n "$alive" ]] }; then
                # overlap start did not take: the old listener predates the
                # SO_REUSEPORT patch and cannot share the port — fall back to
                # the stop-then-start order (one refuse window, legacy path)
                print -ru2 -- "hosted-only: overlap start did not take (old listener cannot share the port); stopping it first."
                local flavor="$_hop_flavor" p
                _hosted_only_proxy_stop "$flavor" >/dev/null || result=1
                _hosted_only_proxy_vars "$flavor"
                for (( i = 0; i < 30; i++ )); do
                    [[ -z "$(lsof -ti "tcp:$_hop_port" -sTCP:LISTEN 2>/dev/null)" ]] && break
                    sleep 0.5
                done
                (( result )) || _hosted_only_proxy_launch || return 1
                if _hosted_only_boot_wait "$_hop_port" ""; then
                    print -r -- "$fp $token_fp" >| "$_hop_runtime/fingerprint"
                else
                    print -ru2 -- "hosted-only: $_hop_flavor proxy not ready on port $_hop_port; see $_hop_runtime/proxy.log"
                    result=1
                fi
            else
                print -ru2 -- "hosted-only: $_hop_flavor proxy not ready on port $_hop_port; see $_hop_runtime/proxy.log"
                result=1
            fi
        fi
    } always {
        [[ -n "$lockfd" ]] && zsystem flock -u "$lockfd" 2>/dev/null
        umask "$old_umask"
    }
    return $result
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

# _hosted_only_proxy_stop <flavor>: stops only a listener whose command line
# names this proxy's config, under the current or a legacy runtime dir (the
# flavor-named dirs before the merge, glm-hybrid before the rename). The Go
# impl delegates to the binary's stop subcommand (same match set, so it also
# retires a stale LiteLLM listener after an impl switch).
_hosted_only_proxy_stop() {
    _hosted_only_proxy_vars "$1" || return 1
    if [[ "$_hop_impl" == go ]]; then
        local gobin
        gobin=$(_hosted_only_go_bin) || return 1
        local -a legacy=()
        local d
        for d in $_hop_legacy_runtimes; legacy+=(--legacy-runtime "$d")
        "$gobin" stop --flavor "$_hop_flavor" --port "$_hop_port" --runtime-dir "$_hop_runtime" "${legacy[@]}"
        return $?
    fi
    local pid stopped=0 cmd d
    local -a fingerprints=("$_hop_runtime/fingerprint")
    for d in "${_hop_legacy_runtimes[@]}"; do
        fingerprints+=("$d/fingerprint")
    done
    for pid in ${(f)"$(lsof -ti "tcp:$_hop_port" -sTCP:LISTEN 2>/dev/null)"}; do
        cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
        if [[ "$cmd" == *"$_hop_runtime/config.yaml"* ]] \
            || [[ "$cmd" == *"$_hop_runtime/routes.json"* ]] \
            || [[ "$cmd" == *"hosted-only-claude-$_hop_port/config.yaml"* ]] \
            || [[ "$cmd" == *"hosted-only-codex-$_hop_port/config.yaml"* ]] \
            || [[ "$cmd" == *"glm-hybrid-claude-$_hop_port/config.yaml"* ]] \
            || [[ "$cmd" == *"glm-hybrid-codex-$_hop_port/config.yaml"* ]]; then
            kill "$pid" 2>/dev/null && stopped=1
        else
            print -ru2 -- "hosted-only: port $_hop_port is held by another process (pid $pid); leaving it alone."
            return 1
        fi
    done
    rm -f "${fingerprints[@]}" 2>/dev/null
    (( stopped )) && print -ru2 -- "hosted-only: stopped $_hop_flavor proxy on port $_hop_port."
    return 0
}
