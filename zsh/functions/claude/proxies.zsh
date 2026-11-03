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
#                              restarts only the ones currently listening.
#                              A proxy whose restart fails is retried until it
#                              comes up (round-robin, per-proxy exponential
#                              backoff 2s..60s, e.g. flaky wifi); a leading
#                              --no-retry makes it fail once instead.
#   llm-proxy-restart required [name ...]     restarts only the listening proxies
#                              whose running process is behind what a launch
#                              would start now (config, hooks, knobs, key,
#                              versions), using each launcher's own fingerprint
#                              check in dry-run mode; up-to-date ones are left
#                              serving
#   llm-proxy-restart required-on-idle [name ...]   same selection, but each
#                              stale proxy is cut only at a moment with no
#                              request in flight (no ESTABLISHED client socket
#                              on its port), polled every half second, so a
#                              session waiting on a response is not cut off.
#                              Gives up on a proxy still busy after
#                              LLM_PROXY_RESTART_IDLE_TIMEOUT seconds
#                              (default 1800) and reports it.
#
# Every EnMaaS-backed restart (enmaas, glm-claude, glm-codex) resolves the
# gateway name before it stops anything: a stale manual DNS server left on one
# network service outranks the router's DHCP answer and breaks only that name,
# so a restart would swap a working proxy for one that cannot reach the
# gateway. When the name does not resolve, the command prints the resolvers in
# use and each service's own DNS setting instead.

# _llm_proxy_gateway_host [url]: host[:port] of the gateway the EnMaaS
# proxies talk to; defaults to the shared ENMAAS_API_BASE_URL.
_llm_proxy_gateway_host() {
    local url="${1:-${ENMAAS_API_BASE_URL:-https://api.enmaas.devshift.net}}"
    url="${url#*://}"
    print -r -- "${url%%/*}"
}

# _llm_proxy_dns_addresses <host>: one resolved address per line, via libc
# getaddrinfo because that is what the proxies themselves resolve with.
# Exit 2 when the name does not resolve, 3 when it could not be checked at
# all (that must not block a restart, unlike an answer of "no such host").
_llm_proxy_dns_addresses() {
    command -v python3 >/dev/null 2>&1 || return 3
    python3 - "$1" <<'PY'
import socket, sys
try:
    infos = socket.getaddrinfo(sys.argv[1], None, proto=socket.IPPROTO_TCP)
except socket.gaierror:
    sys.exit(2)
except Exception:
    sys.exit(3)
seen = []
for info in infos:
    addr = info[4][0]
    if addr not in seen:
        seen.append(addr)
print('\n'.join(seen))
PY
}

# _llm_proxy_dns_doh <host>: addresses from DNS-over-HTTPS, for the case the
# system resolver cannot answer. Same servers the proxy shim uses.
_llm_proxy_dns_doh() {
    local host="$1" url answer addrs
    for url in "https://1.1.1.1/dns-query?name=$host&type=A" \
               "https://1.0.0.1/dns-query?name=$host&type=A" \
               "https://dns.google/resolve?name=$host&type=A"; do
        answer=$(command curl -sS --max-time 5 -H 'accept: application/dns-json' "$url" 2>/dev/null) || continue
        addrs=$(print -r -- "$answer" | jq -r '(.Answer // [])[] | select(.type == 1 or .type == 28) | .data' 2>/dev/null \
            | awk '!seen[$0]++')
        [[ -n "$addrs" ]] || continue
        print -r -- "$addrs"
        return 0
    done
    return 1
}

# _llm_proxy_dns_report <host>: why a name is not resolving, and the fix.
_llm_proxy_dns_report() {
    local host="$1" svc servers forwarders
    local -a services manual
    print -ru2 -- "restart: dns $host does not resolve"
    forwarders=$(scutil --dns 2>/dev/null | awk -F': ' '/nameserver\[[0-9]+\]/{print $2}' \
        | awk '!seen[$0]++' | tr '\n' ' ')
    print -ru2 -- "  forwarders in use: ${${forwarders% }:-unknown}"
    print -ru2 -- '  per-service DNS (networksetup; (DHCP) = taken from the router):'
    services=(${(f)"$(networksetup -listallnetworkservices 2>/dev/null)"})
    for svc in $services[2,-1]; do
        [[ -n "$svc" ]] || continue
        servers=$(networksetup -getdnsservers "$svc" 2>/dev/null | tr '\n' ' ')
        servers=${servers% }
        if [[ -z "$servers" || "$servers" == "There aren't any DNS Servers set on"* ]]; then
            print -ru2 -- "    $svc: (DHCP)"
        else
            print -ru2 -- "    $svc: $servers  (manual)"
            manual+=("$svc")
        fi
    done
    print -ru2 -- '  fix: a manual server on an active service outranks DHCP. Reset the flagged one to a'
    print -ru2 -- '       known-good resolver, or to the router, then flush the cache:'
    print -ru2 -- "    networksetup -setdnsservers \"${manual[1]:-Wi-Fi}\" 1.1.1.1 8.8.8.8"
    print -ru2 -- "    networksetup -setdnsservers \"${manual[1]:-Wi-Fi}\" Empty   # back to DHCP"
    print -ru2 -- '    sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder'
}

# _llm_proxy_dns_probe <host> <label>: gate a restart on the gateway name.
_llm_proxy_dns_probe() {
    local host="$1" label="$2" addrs rc=0
    addrs=$(_llm_proxy_dns_addresses "$host") || rc=$?
    case "$rc" in
        0) print -ru2 -- "restart: dns $host -> ${(j:, :)${(f)addrs}}"; return 0 ;;
        2) if addrs=$(_llm_proxy_dns_doh "$host"); then
               print -ru2 -- "restart: dns $host -> ${(j:, :)${(f)addrs}} (system resolver failed; DoH)"
               return 0
           fi
           _llm_proxy_dns_report "$host"
           print -ru2 -- "restart: not restarting $label while its gateway name is unresolvable"
           return 1 ;;
    esac
    # Cannot tell (resolver tools unavailable, e.g. a locked-down sandbox):
    # say so and let the restart try, instead of blocking on a guess.
    print -ru2 -- "restart: could not check dns for $host; restarting $label anyway"
    return 0
}

# _llm_proxy_wait_down <port>: up to 15s for the listener to go away, one dot
# per half-second so the wait is visible.
_llm_proxy_wait_down() {
    local i waiting=0
    for i in {1..30}; do
        [[ -z "$(_claude_listen_pids "$1")" ]] && { (( waiting )) && print -u2; return 0; }
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
        [[ -n "$(_claude_listen_pids "$1")" ]] && { (( waiting )) && print -u2; print -ru2 -- "restart: $2 up on :$1"; return 0; }
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
    ( _CLAUDE_COPILOT_RESTART_ONLY=1 claude-copilot --version >/dev/null ) || return 1
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
    local host rc
    host=$(_llm_proxy_gateway_host)
    _llm_proxy_dns_probe "$host" enmaas || return 1
    claude-enmaas-kill >/dev/null 2>&1  # non-zero when nothing runs; a stuck listener is caught below
    _llm_proxy_wait_down "$(_claude_enmaas_port)" || return 1
    # Model discovery (three catalog fetches) runs before the proxy boots, so
    # this step is the slow one; keep the user informed instead of blanking.
    print -ru2 -- 'restart: enmaas starting (model discovery, then proxy boot)'
    claude-enmaas --version >/dev/null || {
        # A launcher failure is usually config, but DNS can change between the
        # probe above and here; only re-explain it when that is what broke.
        rc=0; _llm_proxy_dns_addresses "$host" >/dev/null || rc=$?
        if (( rc == 2 )); then _llm_proxy_dns_report "$host"; fi
        return 1
    }
    _llm_proxy_wait_up "$(_claude_enmaas_port)" enmaas
}

claude-hosted-only-restart() {
    _llm_proxy_dns_probe "$(_llm_proxy_gateway_host "${HOSTED_ONLY_ENMAAS_BASE_URL:-}")" 'hosted-only claude' || return 1
    _hosted_only_proxy_stop claude || return 1
    _llm_proxy_wait_down "$(_hosted_only_knob CLAUDE_PROXY_PORT 4148)" || return 1
    print -ru2 -- 'restart: hosted-only claude starting'
    ( _hosted_only_proxy_ensure claude ) || return 1
    _llm_proxy_wait_up "$(_hosted_only_knob CLAUDE_PROXY_PORT 4148)" 'hosted-only claude'
}
claude-glm-hybrid-restart() { claude-hosted-only-restart; }
claude-glm-only-restart() { claude-hosted-only-restart; }

codex-hosted-only-restart() {
    _llm_proxy_dns_probe "$(_llm_proxy_gateway_host "${HOSTED_ONLY_ENMAAS_BASE_URL:-}")" 'hosted-only codex' || return 1
    _hosted_only_proxy_stop codex || return 1
    _llm_proxy_wait_down "$(_hosted_only_knob CODEX_PROXY_PORT 4147)" || return 1
    print -ru2 -- 'restart: hosted-only codex starting'
    ( _hosted_only_proxy_ensure codex ) || return 1
    _llm_proxy_wait_up "$(_hosted_only_knob CODEX_PROXY_PORT 4147)" 'hosted-only codex'
}
codex-glm-hybrid-restart() { codex-hosted-only-restart; }
codex-glm-only-restart() { codex-hosted-only-restart; }

# Staleness checks for `llm-proxy-restart required`. Each prints one word
# (`down`, `fresh`, `stale`, or `unknown` when the launcher failed before it
# could compare), optionally followed by ": <reasons>".
# _llm_proxy_check_via <env-var> <launcher...>: run a launcher in its dry-run
# mode (the env var names the verdict file) and report the first word written.
_llm_proxy_check_via() {
    local var="$1" out verdict; shift
    out=$(command mktemp "${TMPDIR:-/tmp}/llm-proxy-check.XXXXXXXX") || { print -r -- unknown; return 1; }
    ( export "$var=$out"; "$@" >/dev/null 2>&1 )
    verdict=$(<"$out") 2>/dev/null
    command rm -f -- "$out"
    print -r -- "${${verdict%% *}:-unknown}"
}
_llm_proxy_check_copilot() { _llm_proxy_check_via _CLAUDE_PROXY_SYNC_CHECK claude-copilot --version; }
_llm_proxy_check_vertex() { _llm_proxy_check_via _CLAUDE_PROXY_SYNC_CHECK _claude_vertex_prepare; }
_llm_proxy_check_openai() { _llm_proxy_check_via _CLAUDE_PROXY_SYNC_CHECK _claude_openai_prepare; }
_llm_proxy_check_glm_claude() { _llm_proxy_check_via HOSTED_ONLY_CHECK_OUT _hosted_only_proxy_ensure claude; }
_llm_proxy_check_glm_codex() { _llm_proxy_check_via HOSTED_ONLY_CHECK_OUT _hosted_only_proxy_ensure codex; }
_llm_proxy_check_enmaas() {
    local report
    report=$(_claude_enmaas_check 2>/dev/null) || { print -r -- unknown; return 1; }
    jq -r '.state + (if (.changed // []) | length > 0 then ": " + (.changed | join(", ")) else "" end)' <<< "$report" 2>/dev/null \
        || print -r -- unknown
}

llm-proxy-restart() {
    zmodload zsh/datetime 2>/dev/null
    local -A fn=(
        copilot claude-copilot-restart vertex claude-vertex-restart openai claude-openai-restart
        enmaas claude-enmaas-restart glm-claude claude-hosted-only-restart glm-codex codex-hosted-only-restart)
    local -A chk=(
        copilot _llm_proxy_check_copilot vertex _llm_proxy_check_vertex openai _llm_proxy_check_openai
        enmaas _llm_proxy_check_enmaas glm-claude _llm_proxy_check_glm_claude glm-codex _llm_proxy_check_glm_codex)
    local -A port=(
        copilot "${COPILOT_API_PORT:-4141}" vertex "${CLAUDE_VERTEX_PROXY_PORT:-4142}"
        openai "${CLAUDE_OPENAI_PROXY_PORT:-4145}" enmaas "$(_claude_enmaas_port 2>/dev/null || print 4146)"
        glm-claude "$(_hosted_only_knob CLAUDE_PROXY_PORT 4148)" glm-codex "$(_hosted_only_knob CODEX_PROXY_PORT 4147)")
    local -a order=(copilot vertex openai enmaas glm-codex glm-claude) targets
    if [[ "${1-}" == --list ]]; then
        local n
        for n in $order; do
            print -r -- "$n :${port[$n]} $([[ -n "$(_claude_listen_pids "${port[$n]}")" ]] && print up || print down)"
        done
        return 0
    fi
    local required=0 on_idle=0 retry=1
    [[ "${1-}" == --no-retry ]] && { retry=0; shift; }
    case "${1-}" in
        required) required=1; shift ;;
        required-on-idle) required=1; on_idle=1; shift ;;
    esac
    if (( ! $# )) || [[ "$1" == all ]]; then
        local n
        for n in $order; do
            [[ -n "$(_claude_listen_pids "${port[$n]}")" ]] && targets+=($n)
        done
        (( ${#targets} )) || { print -ru2 -- "llm-proxy-restart: no proxy is listening; nothing to restart."; return 0; }
    else
        targets=("$@")
    fi
    local t rc=0 verdict why
    local -a pending failed
    for t in $targets; do
        [[ -n "${fn[$t]-}" ]] || { print -ru2 -- "llm-proxy-restart: unknown '$t' (choose: $order, all, required, required-on-idle, --list)"; rc=1; continue; }
        if (( required )); then
            [[ -n "$(_claude_listen_pids "${port[$t]}")" ]] || { print -ru2 -- "== $t (:${port[$t]}) not running; skipped"; continue; }
            verdict=$(${chk[$t]})
            case "$verdict" in
                fresh)  print -ru2 -- "== $t (:${port[$t]}) up to date; left running"; continue ;;
                stale*) why="changed${verdict#stale}" ;;
                down)   why="listener does not answer its health check" ;;
                *)      print -ru2 -- "== $t (:${port[$t]}) could not be checked (its launcher failed; run it by hand for the error); skipped"; rc=1; continue ;;
            esac
            if (( on_idle )); then
                print -ru2 -- "== $t (:${port[$t]}) $why; will restart at the next idle moment"
                pending+=($t)
                continue
            fi
            print -ru2 -- "== $t (:${port[$t]}) $why; restarting"
        else
            print -ru2 -- "== restarting $t (:${port[$t]})"
        fi
        ${fn[$t]} || { print -ru2 -- "llm-proxy-restart: $t failed"; failed+=($t); }
    done
    # required-on-idle: verdicts are in; now cut each pending proxy at the
    # first half-second poll that finds no request in flight on its port,
    # whichever goes quiet first, until the shared deadline.
    if (( ${#pending} )); then
        local timeout="${LLM_PROXY_RESTART_IDLE_TIMEOUT:-1800}" deadline started polls=0
        [[ "$timeout" == <-> ]] || timeout=1800
        started=$EPOCHSECONDS deadline=$(( started + timeout ))
        local -a still
        local -A announced
        while (( ${#pending} )); do
            still=()
            for t in $pending; do
                if _claude_port_serving "${port[$t]}"; then
                    if (( EPOCHSECONDS >= deadline )); then
                        print -ru2 -- "== $t (:${port[$t]}) still serving requests at the deadline (${timeout}s); not restarted (rerun later, or \`required\` to cut it now)"
                        rc=1
                        continue
                    fi
                    (( ${+announced[$t]} )) || { print -ru2 -- "== $t (:${port[$t]}) serving a request; waiting for an idle moment"; announced[$t]=1; }
                    still+=($t)
                    continue
                fi
                print -ru2 -- "== $t (:${port[$t]}) idle; restarting now"
                ${fn[$t]} || { print -ru2 -- "llm-proxy-restart: $t failed"; failed+=($t); }
            done
            pending=($still)
            if (( ${#pending} )); then
                sleep 0.5
                (( ++polls % 120 == 0 )) && print -ru2 -- "== still waiting for an idle moment on: $pending ($(( EPOCHSECONDS - started ))s)"
            fi
        done
    fi
    # A failed restart (typically a start step that needs the network) is
    # retried until it succeeds: round-robin over the failed proxies, each with
    # its own exponential backoff (2s doubling to a 60s cap), so one stuck
    # proxy never blocks the others. Ctrl-C aborts. --no-retry fails once.
    if (( ${#failed} && retry )); then
        local -A delay due
        local now
        for t in $failed; do delay[$t]=2; due[$t]=$(( EPOCHSECONDS + 2 )); done
        print -ru2 -- "== retrying with backoff until up: $failed (Ctrl-C to stop)"
        while (( ${#failed} )); do
            now=$EPOCHSECONDS
            for t in $failed; do
                (( now >= due[$t] )) || continue
                print -ru2 -- "== retry $t (:${port[$t]})"
                if ${fn[$t]}; then
                    failed=(${failed:#$t})
                else
                    delay[$t]=$(( delay[$t] * 2 > 60 ? 60 : delay[$t] * 2 ))
                    due[$t]=$(( EPOCHSECONDS + delay[$t] ))
                    print -ru2 -- "== $t still failing; next try in ${delay[$t]}s"
                fi
            done
            (( ${#failed} )) && sleep 1
        done
    fi
    (( ${#failed} )) && rc=1
    return $rc
}
