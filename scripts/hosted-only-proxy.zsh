# Sourced library (not executable): the hosted-only LiteLLM proxies.
#
# Hosted-only = EnMaaS-hosted free models only: GLM 5.3 (text) and DeepSeek
# V4.1 Flash (1M context, vision). Codex's auto-review and Claude Code's
# auto-mode classifier send their review request to the same endpoint as the
# main model, so one local endpoint routes by model id and every tier, reviewer
# and helper call stays on the two hosted models (no paid side-channel calls,
# no OpenAI key). One proxy per client flavor, because each needs the models
# under the same ids on a different dialect:
#
#   codex   127.0.0.1:${HOSTED_ONLY_CODEX_PROXY_PORT:-4147}   models -> openai/
#           Responses passthrough on EnMaaS /v1. Used by
#           scripts/codex-provider.zsh hosted-only.
#   claude  127.0.0.1:${HOSTED_ONLY_CLAUDE_PROXY_PORT:-4148}  models -> anthropic/
#           Messages on the EnMaaS root, same as claude-enmaas. Used by
#           claude-hosted-only (zsh/functions/claude/providers/hosted-only.zsh).
# Both load hosted_only_hooks.py (rits/ models only): strips the grammar vLLM
# rejects from Codex's apply_patch, cuts default reasoning on Messages requests
# that send no thinking field (Claude Code's auto-mode classifier), sends GLM
# requests that carry an image (GLM 400s on any image in history) to DeepSeek
# (HOSTED_ONLY_VISION_FALLBACK=0 disables), and rewrites EnMaaS 429s so T3 Code
# can auto-resume a limited thread (see hosted_only_hooks.py item 5;
# HOSTED_ONLY_LIMIT_REWRITE=0 disables, per-minute default wait
# HOSTED_ONLY_RATE_LIMIT_DEFAULT_RETRY_SECONDS (60), waits longer than
# HOSTED_ONLY_CLIENT_RETRY_MAX_SECONDS (60) fail fast to T3).
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
# each routed model). HOSTED_ONLY_MODEL (main model pick), HOSTED_ONLY_REVIEW_MODEL,
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

typeset -g _HOSTED_ONLY_SCRIPTS="${${(%):-%x}:A:h}"

# _hosted_only_knob <NAME> <default>: $HOSTED_ONLY_<NAME>, else the retired
# $GLM_HYBRID_<NAME>, else the default.
_hosted_only_knob() {
    local new="HOSTED_ONLY_$1" old="GLM_HYBRID_$1"
    print -r -- "${${(P)new}:-${${(P)old}:-$2}}"
}

# _hosted_only_proxy_vars <flavor>: sets _hop_* globals for the flavor.
_hosted_only_proxy_vars() {
    case "$1" in
        codex)  typeset -g _hop_port="$(_hosted_only_knob CODEX_PROXY_PORT 4147)" ;;
        claude) typeset -g _hop_port="$(_hosted_only_knob CLAUDE_PROXY_PORT 4148)" ;;
        *) print -ru2 -- 'hosted-only: flavor must be codex or claude.'; return 1 ;;
    esac
    typeset -g _hop_flavor="$1"
    local state="${XDG_STATE_HOME:-$HOME/.local/state}"
    typeset -g _hop_runtime="$state/hosted-only-$1-$_hop_port"
    typeset -g _hop_legacy_runtime="$state/glm-hybrid-$1-$_hop_port"   # pre-rename dir
    typeset -g _hop_base="http://127.0.0.1:$_hop_port"
    typeset -g _hop_token="$(_hosted_only_knob PROXY_TOKEN hosted-only-local)"
    typeset -g _hop_glm="$(_hosted_only_knob GLM_MODEL "${GLM_HYBRID_MODEL:-rits/zai-org/glm-5-3}")"
    typeset -g _hop_deepseek="$(_hosted_only_knob DEEPSEEK_MODEL rits/deepseek-ai/DeepSeek-V4.1-Flash-1017)"
    typeset -g _hop_vision_fallback="$(_hosted_only_knob VISION_FALLBACK 1)"
    typeset -g _hop_limit_rewrite="$(_hosted_only_knob LIMIT_REWRITE 1)"
    typeset -g _hop_limit_retry="$(_hosted_only_knob RATE_LIMIT_DEFAULT_RETRY_SECONDS 60)"
    typeset -g _hop_client_retry="$(_hosted_only_knob CLIENT_RETRY_MAX_SECONDS 60)"
}

_hosted_only_proxy_config() {
    local enmaas="$(_hosted_only_knob ENMAAS_BASE_URL "${ENMAAS_API_BASE_URL:-https://api.enmaas.devshift.net}")"
    enmaas="${enmaas%/}"
    enmaas="${enmaas%/v1}"
    local glm_params
    if [[ "$_hop_flavor" == codex ]]; then
        glm_params="      model: \"openai/$_hop_glm\"
      api_base: \"$enmaas/v1\""
    else
        glm_params="      model: \"anthropic/$_hop_glm\"
      api_base: \"$enmaas\""
    fi
    local ds_params="${glm_params//$_hop_glm/$_hop_deepseek}"
    print -r -- "model_list:
  - model_name: \"$_hop_glm\"
    litellm_params:
$glm_params
      api_key: os.environ/ENMAAS_API_KEY
  - model_name: \"$_hop_deepseek\"
    litellm_params:
$ds_params
      api_key: os.environ/ENMAAS_API_KEY"
    # Claude Code only remaps aliases via ANTHROPIC_DEFAULT_*_MODEL; clients that
    # pass an explicit id (T3's picker sends claude-sonnet-5-5) would hit "Invalid
    # model name". Serve that id from GLM so the client keeps Sonnet 5.5 behavior.
    [[ "$_hop_flavor" == claude ]] && print -r -- "  - model_name: \"claude-sonnet-5-5\"
    litellm_params:
$glm_params
      api_key: os.environ/ENMAAS_API_KEY"
    print -r -- "litellm_settings:
  drop_params: true"
    print -r -- '  callbacks: ["hosted_only_hooks.proxy_handler_instance", "litellm_usage_log.proxy_handler_instance"]'
    print -r -- "general_settings:
  master_key: os.environ/HOSTED_ONLY_PROXY_TOKEN"
}

# _hosted_only_proxy_ensure <flavor>: proxy healthy with the current config, or
# return 1 (stderr says why). Sets _hop_base/_hop_token. Writes nothing to stdout.
_hosted_only_proxy_ensure() {
    _hosted_only_proxy_vars "$1" || return 1
    local health="$_hop_base/health/liveliness"
    local litellm_version="$(_hosted_only_knob LITELLM_VERSION 1.97.0)"
    local fastapi_version="$(_hosted_only_knob FASTAPI_VERSION 0.136.3)"
    local hooks="$_HOSTED_ONLY_SCRIPTS/hosted_only_hooks.py"
    local usage_log="$_HOSTED_ONLY_SCRIPTS/litellm_usage_log.py"
    [[ -n "${ENMAAS_API_KEY-}" ]] || { print -ru2 -- 'hosted-only: ENMAAS_API_KEY is not set.'; return 1; }
    command -v uv >/dev/null || { print -ru2 -- 'hosted-only: uv not found.'; return 1; }
    [[ -r "$hooks" ]] || { print -ru2 -- "hosted-only: missing $hooks"; return 1; }
    [[ -r "$usage_log" ]] || { print -ru2 -- "hosted-only: missing $usage_log"; return 1; }

    local config fp hooks_text
    config=$(_hosted_only_proxy_config)
    hooks_text="$(<"$hooks")$(<"$usage_log")"
    fp=$(print -rn -- "$config"$'\x1f'"$hooks_text"$'\x1f'"$ENMAAS_API_KEY"$'\x1f'"$_hop_token"$'\x1f'"$litellm_version $fastapi_version $_hop_vision_fallback $_hop_limit_rewrite $_hop_limit_retry $_hop_client_retry" \
        | shasum -a 256 | cut -d' ' -f1)

    local old_umask=$(umask) lockfd result=0
    umask 077
    {
        mkdir -p "$_hop_runtime" && : >> "$_hop_runtime/startup.lock" || return 1
        zmodload zsh/system || return 1
        zsystem flock -t 120 -f lockfd "$_hop_runtime/startup.lock" || {
            print -ru2 -- "hosted-only: timed out waiting for another $_hop_flavor proxy start."
            return 1
        }
        if curl -sf --max-time 2 "$health" -o /dev/null; then
            if [[ "$(<"$_hop_runtime/fingerprint" 2>/dev/null)" != "$fp" ]]; then
                print -ru2 -- "hosted-only: the running $_hop_flavor proxy on port $_hop_port has a different config or key (or predates the hosted-only rename); stop it after active sessions finish."
                result=1
            fi
        else
            print -r -- "$config" >| "$_hop_runtime/config.yaml" || return 1
            cp -f "$hooks" "$_hop_runtime/hosted_only_hooks.py" || return 1
            cp -f "$usage_log" "$_hop_runtime/litellm_usage_log.py" || return 1
            rm -f "$_hop_runtime/fingerprint"
            ENMAAS_API_KEY="$ENMAAS_API_KEY" HOSTED_ONLY_PROXY_TOKEN="$_hop_token" \
                HOSTED_ONLY_GLM_MODEL="$_hop_glm" HOSTED_ONLY_DEEPSEEK_MODEL="$_hop_deepseek" HOSTED_ONLY_VISION_FALLBACK="$_hop_vision_fallback" \
                HOSTED_ONLY_LIMIT_REWRITE="$_hop_limit_rewrite" HOSTED_ONLY_RATE_LIMIT_DEFAULT_RETRY_SECONDS="$_hop_limit_retry" HOSTED_ONLY_CLIENT_RETRY_MAX_SECONDS="$_hop_client_retry" LITELLM_LOG="$(_hosted_only_knob LITELLM_LOG ERROR)" \
                python3 "$_HOSTED_ONLY_SCRIPTS/claude-provider.py" --background "$_hop_runtime/proxy.log" \
                uv tool run --with "fastapi==$fastapi_version" --from "litellm[proxy]==$litellm_version" litellm \
                --config "$_hop_runtime/config.yaml" --host 127.0.0.1 --port "$_hop_port" --telemetry False || return 1
            local i
            for i in {1..90}; do
                curl -sf --max-time 2 "$health" -o /dev/null && break
                sleep 1
            done
            if curl -sf --max-time 2 "$health" -o /dev/null; then
                print -r -- "$fp" >| "$_hop_runtime/fingerprint"
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
# by _hosted_only_proxy_vars) left a fingerprint in either runtime dir, i.e. a
# start failed because a live proxy differs, not because of a missing key.
_hosted_only_proxy_has_state() {
    [[ -f "$_hop_runtime/fingerprint" || -f "$_hop_legacy_runtime/fingerprint" ]]
}

# _hosted_only_proxy_stop <flavor>: stops only a listener whose command line
# names this flavor's config, under the current or the legacy runtime dir.
_hosted_only_proxy_stop() {
    _hosted_only_proxy_vars "$1" || return 1
    local pid stopped=0 cmd
    for pid in ${(f)"$(lsof -ti "tcp:$_hop_port" -sTCP:LISTEN 2>/dev/null)"}; do
        cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
        if [[ "$cmd" == *"$_hop_runtime/config.yaml"* || "$cmd" == *"$_hop_legacy_runtime/config.yaml"* ]]; then
            kill "$pid" 2>/dev/null && stopped=1
        else
            print -ru2 -- "hosted-only: port $_hop_port is held by another process (pid $pid); leaving it alone."
            return 1
        fi
    done
    rm -f "$_hop_runtime/fingerprint" "$_hop_legacy_runtime/fingerprint"
    (( stopped )) && print -ru2 -- "hosted-only: stopped $_hop_flavor proxy on port $_hop_port."
    return 0
}
