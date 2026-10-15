# Sourced library (not executable): the "GLM hybrid" LiteLLM proxies.
#
# GLM on EnMaaS is the main model; an OpenAI model (default gpt-6-luna)
# reviews permission/approval requests. Codex's auto-review and Claude Code's
# auto-mode classifier both send their review request to the same endpoint as
# the main model, the EnMaaS key only serves GLM, and the OpenAI key cannot
# serve GLM -- so one local endpoint routes by model id. One proxy per client
# flavor, because each needs GLM under the same id on a different dialect:
#
#   codex   127.0.0.1:${GLM_HYBRID_CODEX_PROXY_PORT:-4147}   GLM -> openai/ Responses
#           passthrough on EnMaaS /v1. Used by scripts/codex-provider.zsh glm-hybrid.
#   claude  127.0.0.1:${GLM_HYBRID_CLAUDE_PROXY_PORT:-4148}  GLM -> anthropic/
#           Messages on the EnMaaS root, same as claude-enmass. Used by
#           claude-glm-hybrid (zsh/functions/claude/providers/glm-hybrid.zsh).
# Both load glm_hybrid_hooks.py (GLM only): strips the grammar vLLM rejects
# from Codex's apply_patch, and disables GLM's default reasoning on Messages
# requests that send no thinking field (Claude Code's auto-mode classifier).
#
# Upstream keys: ENMAAS_API_KEY (caller loads it, e.g. from ~/secrets.zsh) and
# OPENAI_API_KEY, else ${GLM_HYBRID_OPENAI_AUTH_FILE:-~/.codex/auth.json} (not
# $CODEX_HOME: hosts like T3 may point Codex at a shadow home). Only the proxy
# gets them; clients get the local token ${GLM_HYBRID_PROXY_TOKEN:-glm-hybrid-local}.
# Other knobs: GLM_HYBRID_MODEL, GLM_HYBRID_REVIEW_MODEL,
# GLM_HYBRID_ENMAAS_BASE_URL (gateway root), GLM_HYBRID_LITELLM_VERSION,
# GLM_HYBRID_FASTAPI_VERSION, GLM_HYBRID_LITELLM_LOG (default ERROR; INFO logs
# each routed model, e.g. to confirm the review model is being called).
#
# Lifecycle: started on demand as a detached session (outlives the client),
# state in ~/.local/state/glm-hybrid-<flavor>-<port>/ (0700). A running proxy
# whose config/keys/versions differ is never restarted under active
# sessions; the caller gets an error naming the stop command:
#   zsh -f <dotfiles>/scripts/codex-provider.zsh glm-hybrid --stop-proxy   (codex)
#   claude-glm-hybrid-kill                                                  (claude)

typeset -g _GLM_HYBRID_SCRIPTS="${${(%):-%x}:A:h}"

# _glm_hybrid_proxy_vars <flavor>: sets _ghp_* globals for the flavor.
_glm_hybrid_proxy_vars() {
    case "$1" in
        codex)  typeset -g _ghp_port="${GLM_HYBRID_CODEX_PROXY_PORT:-4147}" ;;
        claude) typeset -g _ghp_port="${GLM_HYBRID_CLAUDE_PROXY_PORT:-4148}" ;;
        *) print -ru2 -- 'glm-hybrid: flavor must be codex or claude.'; return 1 ;;
    esac
    typeset -g _ghp_flavor="$1"
    typeset -g _ghp_runtime="${XDG_STATE_HOME:-$HOME/.local/state}/glm-hybrid-$1-$_ghp_port"
    typeset -g _ghp_base="http://127.0.0.1:$_ghp_port"
    typeset -g _ghp_token="${GLM_HYBRID_PROXY_TOKEN:-glm-hybrid-local}"
    typeset -g _ghp_glm="${GLM_HYBRID_MODEL:-rits/zai-org/glm-5-3}"
    typeset -g _ghp_review="${GLM_HYBRID_REVIEW_MODEL:-gpt-6-luna}"
}

_glm_hybrid_proxy_config() {
    local enmaas="${GLM_HYBRID_ENMAAS_BASE_URL:-https://api.enmaas.devshift.net}"
    enmaas="${enmaas%/}"
    local glm_params
    if [[ "$_ghp_flavor" == codex ]]; then
        glm_params="      model: \"openai/$_ghp_glm\"
      api_base: \"$enmaas/v1\""
    else
        glm_params="      model: \"anthropic/$_ghp_glm\"
      api_base: \"$enmaas\""
    fi
    print -r -- "model_list:
  - model_name: \"$_ghp_glm\"
    litellm_params:
$glm_params
      api_key: os.environ/ENMAAS_API_KEY
  - model_name: \"$_ghp_review\"
    litellm_params:
      model: \"openai/$_ghp_review\"
      api_key: os.environ/OPENAI_API_KEY
litellm_settings:
  drop_params: true"
    print -r -- '  callbacks: ["glm_hybrid_hooks.proxy_handler_instance"]'
    print -r -- "general_settings:
  master_key: os.environ/GLM_HYBRID_PROXY_TOKEN"
}

# _glm_hybrid_proxy_ensure <flavor>: proxy healthy with the current config, or
# return 1 (stderr says why). Sets _ghp_base/_ghp_token. Writes nothing to stdout.
_glm_hybrid_proxy_ensure() {
    _glm_hybrid_proxy_vars "$1" || return 1
    local health="$_ghp_base/health/liveliness"
    local litellm_version="${GLM_HYBRID_LITELLM_VERSION:-1.97.0}"
    local fastapi_version="${GLM_HYBRID_FASTAPI_VERSION:-0.136.3}"
    local hooks="$_GLM_HYBRID_SCRIPTS/glm_hybrid_hooks.py"
    [[ -n "${ENMAAS_API_KEY-}" ]] || { print -ru2 -- 'glm-hybrid: ENMAAS_API_KEY is not set.'; return 1; }
    local openai_key="${OPENAI_API_KEY-}" auth="${GLM_HYBRID_OPENAI_AUTH_FILE:-$HOME/.codex/auth.json}"
    if [[ -z "$openai_key" && -r "$auth" ]]; then
        openai_key=$(jq -r '.OPENAI_API_KEY // empty' "$auth" 2>/dev/null)
    fi
    [[ -n "$openai_key" ]] || {
        print -ru2 -- 'glm-hybrid: no OpenAI key for the review model (set OPENAI_API_KEY or run codex login --with-api-key).'
        return 1
    }
    command -v uv >/dev/null || { print -ru2 -- 'glm-hybrid: uv not found.'; return 1; }
    [[ -r "$hooks" ]] || { print -ru2 -- "glm-hybrid: missing $hooks"; return 1; }

    local config fp hooks_text
    config=$(_glm_hybrid_proxy_config)
    hooks_text="$(<"$hooks")"
    fp=$(print -rn -- "$config"$'\x1f'"$hooks_text"$'\x1f'"$ENMAAS_API_KEY"$'\x1f'"$openai_key"$'\x1f'"$_ghp_token"$'\x1f'"$litellm_version $fastapi_version" \
        | shasum -a 256 | cut -d' ' -f1)

    local old_umask=$(umask) lockfd result=0
    umask 077
    {
        mkdir -p "$_ghp_runtime" && : >> "$_ghp_runtime/startup.lock" || return 1
        zmodload zsh/system || return 1
        zsystem flock -t 120 -f lockfd "$_ghp_runtime/startup.lock" || {
            print -ru2 -- "glm-hybrid: timed out waiting for another $_ghp_flavor proxy start."
            return 1
        }
        if curl -sf --max-time 2 "$health" -o /dev/null; then
            if [[ "$(<"$_ghp_runtime/fingerprint" 2>/dev/null)" != "$fp" ]]; then
                print -ru2 -- "glm-hybrid: the running $_ghp_flavor proxy on port $_ghp_port has a different config or key; stop it after active sessions finish."
                result=1
            fi
        else
            print -r -- "$config" >| "$_ghp_runtime/config.yaml" || return 1
            cp -f "$hooks" "$_ghp_runtime/glm_hybrid_hooks.py" || return 1
            rm -f "$_ghp_runtime/fingerprint"
            ENMAAS_API_KEY="$ENMAAS_API_KEY" OPENAI_API_KEY="$openai_key" GLM_HYBRID_PROXY_TOKEN="$_ghp_token" LITELLM_LOG="${GLM_HYBRID_LITELLM_LOG:-ERROR}" \
                python3 "$_GLM_HYBRID_SCRIPTS/claude-provider.py" --background "$_ghp_runtime/proxy.log" \
                uv tool run --with "fastapi==$fastapi_version" --from "litellm[proxy]==$litellm_version" litellm \
                --config "$_ghp_runtime/config.yaml" --host 127.0.0.1 --port "$_ghp_port" --telemetry False || return 1
            local i
            for i in {1..90}; do
                curl -sf --max-time 2 "$health" -o /dev/null && break
                sleep 1
            done
            if curl -sf --max-time 2 "$health" -o /dev/null; then
                print -r -- "$fp" >| "$_ghp_runtime/fingerprint"
            else
                print -ru2 -- "glm-hybrid: $_ghp_flavor proxy not ready on port $_ghp_port; see $_ghp_runtime/proxy.log"
                result=1
            fi
        fi
    } always {
        [[ -n "$lockfd" ]] && zsystem flock -u "$lockfd" 2>/dev/null
        umask "$old_umask"
    }
    return $result
}

# _glm_hybrid_proxy_stop <flavor>: stops only a listener whose command line
# names this flavor's config.
_glm_hybrid_proxy_stop() {
    _glm_hybrid_proxy_vars "$1" || return 1
    local pid stopped=0
    for pid in ${(f)"$(lsof -ti "tcp:$_ghp_port" -sTCP:LISTEN 2>/dev/null)"}; do
        if [[ "$(ps -o command= -p "$pid" 2>/dev/null)" == *"$_ghp_runtime/config.yaml"* ]]; then
            kill "$pid" 2>/dev/null && stopped=1
        else
            print -ru2 -- "glm-hybrid: port $_ghp_port is held by another process (pid $pid); leaving it alone."
            return 1
        fi
    done
    rm -f "$_ghp_runtime/fingerprint"
    (( stopped )) && print -ru2 -- "glm-hybrid: stopped $_ghp_flavor proxy on port $_ghp_port."
    return 0
}
