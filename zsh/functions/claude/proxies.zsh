# Restart commands for the local gateways/proxies behind the Claude and Codex
# wrappers: stop the listener, wait for the port to free, start it again with
# the current config (so e.g. new usage logging, keys or model routes apply)
# without launching a client. Each provider's own *-kill stays the stop-only
# command. Loaded after providers/ (uses their kill and start helpers).
#
# Restarting cuts off sessions using that proxy: in-flight requests error and
# the client reconnects to the new process. Run it when those sessions are idle.
#
#   claude-copilot-restart     copilot-api gateway         :4141
#   claude-vertex-restart      LiteLLM -> Vertex           :4142
#   claude-openai-restart      LiteLLM -> OpenAI           :4145
#   claude-enmaas-restart      LiteLLM -> EnMaaS           :4146
#   claude-hosted-only-restart hosted-only, Claude flavor  :4148 (= claude-{glm-hybrid,glm-only}-restart)
#   codex-hosted-only-restart  hosted-only, Codex flavor   :4147 (= codex-{glm-hybrid,glm-only}-restart)
#   llm-proxy-restart [name ...|all|--list]   several at once; no args or `all`
#                              restarts only the ones currently listening

# _llm_proxy_wait_down <port>: up to 15s for the listener to go away, one dot
# per half-second so the wait is visible.
_llm_proxy_wait_down() {
    local i waiting=0
    for i in {1..30}; do
        [[ -z "$(lsof -ti "tcp:$1" -sTCP:LISTEN 2>/dev/null)" ]] && { (( waiting )) && print -u2; return 0; }
        (( waiting )) || { print -nu2 -- "restart: waiting for :$1 to free "; waiting=1; }
        print -nu2 -- .
        sleep 0.5
    done
    (( waiting )) && print -u2
    print -ru2 -- "restart: port $1 is still held after 15s; not starting a replacement."
    return 1
}

# _llm_proxy_wait_up <port> <label>: confirm the fresh listener exists and say
# so, so a restart never ends in silence whether it worked or not. The start
# paths health-check internally, so this normally confirms instantly and only
# polls when something is off.
_llm_proxy_wait_up() {
    local i waiting=0
    for i in {1..30}; do
        [[ -n "$(lsof -ti "tcp:$1" -sTCP:LISTEN 2>/dev/null)" ]] && { (( waiting )) && print -u2; print -ru2 -- "restart: $2 up on :$1"; return 0; }
        (( waiting )) || { print -nu2 -- "restart: waiting for $2 on :$1 "; waiting=1; }
        print -nu2 -- .
        sleep 0.5
    done
    (( waiting )) && print -u2
    print -ru2 -- "restart: $2 not listening on :$1"
    return 1
}

claude-copilot-restart() {
    claude-copilot-kill >/dev/null
    _llm_proxy_wait_down "${COPILOT_API_PORT:-4141}" || return 1
    # claude-copilot exports into the calling shell, so run it in a subshell;
    # starting the gateway happens before `claude --version` runs.
    print -ru2 -- 'restart: copilot starting'
    ( claude-copilot --version >/dev/null ) || return 1
    _llm_proxy_wait_up "${COPILOT_API_PORT:-4141}" copilot
}

claude-vertex-restart() {
    claude-vertex-kill >/dev/null
    _llm_proxy_wait_down "${CLAUDE_VERTEX_PROXY_PORT:-4142}" || return 1
    print -ru2 -- 'restart: vertex starting'
    ( _claude_vertex_prepare ) || return 1
    _llm_proxy_wait_up "${CLAUDE_VERTEX_PROXY_PORT:-4142}" vertex
}

claude-openai-restart() {
    claude-openai-kill >/dev/null
    _llm_proxy_wait_down "${CLAUDE_OPENAI_PROXY_PORT:-4145}" || return 1
    print -ru2 -- 'restart: openai starting'
    ( _claude_openai_prepare ) || return 1
    _llm_proxy_wait_up "${CLAUDE_OPENAI_PROXY_PORT:-4145}" openai
}

claude-enmaas-restart() {
    claude-enmaas-kill >/dev/null 2>&1  # non-zero when nothing runs; a stuck listener is caught below
    _llm_proxy_wait_down "$(_claude_enmaas_port)" || return 1
    # Model discovery (three catalog fetches) runs before the proxy boots, so
    # this step is the slow one; keep the user informed instead of blanking.
    print -ru2 -- 'restart: enmaas starting (model discovery, then proxy boot)'
    claude-enmaas --version >/dev/null || return 1
    _llm_proxy_wait_up "$(_claude_enmaas_port)" enmaas
}

claude-hosted-only-restart() {
    _hosted_only_proxy_stop claude || return 1
    _llm_proxy_wait_down "$(_hosted_only_knob CLAUDE_PROXY_PORT 4148)" || return 1
    print -ru2 -- 'restart: hosted-only claude starting'
    ( _hosted_only_proxy_ensure claude ) || return 1
    _llm_proxy_wait_up "$(_hosted_only_knob CLAUDE_PROXY_PORT 4148)" 'hosted-only claude'
}
claude-glm-hybrid-restart() { claude-hosted-only-restart; }
claude-glm-only-restart() { claude-hosted-only-restart; }

codex-hosted-only-restart() {
    _hosted_only_proxy_stop codex || return 1
    _llm_proxy_wait_down "$(_hosted_only_knob CODEX_PROXY_PORT 4147)" || return 1
    print -ru2 -- 'restart: hosted-only codex starting'
    ( _hosted_only_proxy_ensure codex ) || return 1
    _llm_proxy_wait_up "$(_hosted_only_knob CODEX_PROXY_PORT 4147)" 'hosted-only codex'
}
codex-glm-hybrid-restart() { codex-hosted-only-restart; }
codex-glm-only-restart() { codex-hosted-only-restart; }

llm-proxy-restart() {
    local -A fn=(
        copilot claude-copilot-restart vertex claude-vertex-restart openai claude-openai-restart
        enmaas claude-enmaas-restart glm-claude claude-hosted-only-restart glm-codex codex-hosted-only-restart)
    local -A port=(
        copilot "${COPILOT_API_PORT:-4141}" vertex "${CLAUDE_VERTEX_PROXY_PORT:-4142}"
        openai "${CLAUDE_OPENAI_PROXY_PORT:-4145}" enmaas "$(_claude_enmaas_port 2>/dev/null || print 4146)"
        glm-claude "$(_hosted_only_knob CLAUDE_PROXY_PORT 4148)" glm-codex "$(_hosted_only_knob CODEX_PROXY_PORT 4147)")
    local -a order=(copilot vertex openai enmaas glm-codex glm-claude) targets
    if [[ "${1-}" == --list ]]; then
        local n
        for n in $order; do
            print -r -- "$n :${port[$n]} $([[ -n "$(lsof -ti "tcp:${port[$n]}" -sTCP:LISTEN 2>/dev/null)" ]] && print up || print down)"
        done
        return 0
    fi
    if (( ! $# )) || [[ "$1" == all ]]; then
        local n
        for n in $order; do
            [[ -n "$(lsof -ti "tcp:${port[$n]}" -sTCP:LISTEN 2>/dev/null)" ]] && targets+=($n)
        done
        (( ${#targets} )) || { print -ru2 -- "llm-proxy-restart: no proxy is listening; nothing to restart."; return 0; }
    else
        targets=("$@")
    fi
    local t rc=0
    for t in $targets; do
        [[ -n "${fn[$t]-}" ]] || { print -ru2 -- "llm-proxy-restart: unknown '$t' (choose: $order, all, --list)"; rc=1; continue; }
        print -ru2 -- "== restarting $t (:${port[$t]})"
        ${fn[$t]} || { print -ru2 -- "llm-proxy-restart: $t failed"; rc=1; }
    done
    return $rc
}
