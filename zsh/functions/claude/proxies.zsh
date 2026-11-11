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
#   claude-vertex-restart      Go proxy -> Vertex           :4142
#   claude-mlx-restart         Go proxy -> mlx_lm.server    :4144
#   claude-openai-restart      Go proxy -> OpenAI           :4145
#   claude-enmaas-restart      Go proxy -> EnMaaS          :4146
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
    local port="${COPILOT_API_PORT:-4141}" pid i
    local -a old_pids all_pids new_pids remain
    old_pids=($(_claude_listen_pids "$port"))
    # capability check: the gateway's source binds SO_REUSEPORT (the fork's
    # serve options) — bun runs the TS directly, so the checkout IS the runtime
    local swap=0
    if (( ${#old_pids} )) && grep -q "reusePort" \
        "${COPILOT_API_DIR:-$HOME/git/copilot-api}/src/start.ts" 2>/dev/null; then
        swap=1
    fi
    if (( ! swap )); then
        # nothing to swap against, or the checkout predates SO_REUSEPORT:
        # the original stop-then-start path
        (( ${#old_pids} )) && claude-copilot-kill >/dev/null
        _llm_proxy_wait_down "$port" || return 1
        print -ru2 -- 'restart: copilot starting'
        ( _CLAUDE_COPILOT_RESTART_ONLY=1 claude-copilot --version >/dev/null ) || return 1
        _llm_proxy_wait_up "$port" copilot
        return $?
    fi
    # Zero-gap swap: start the replacement ALONGSIDE the still-serving old
    # gateway — both listeners bind SO_REUSEPORT (kaovilai/copilot-api dev),
    # and the kernel keeps routing new connections to the old listener until
    # it closes. Once the new pid holds the port, SIGTERM the old ones: they
    # stop accepting, drain their in-flight requests (capped), and exit. A
    # request arriving mid-restart is never refused and none is cut.
    print -ru2 -- "restart: copilot starting alongside :$port (zero-gap swap)"
    ( _CLAUDE_COPILOT_RESTART_ONLY=1 _CLAUDE_COPILOT_FORCE_START=1 claude-copilot --version >/dev/null ) || return 1
    for i in {1..30}; do
        all_pids=($(_claude_listen_pids "$port"))
        new_pids=()
        for pid in "${all_pids[@]}"; do
            [[ " ${old_pids[*]} " == *" $pid "* ]] || new_pids+=("$pid")
        done
        (( ${#new_pids} )) && break
        sleep 0.5
    done
    if (( ${#new_pids} == 0 )); then
        # the overlap start did not take (the running gateway predates
        # SO_REUSEPORT and holds the port exclusively) — stop-then-start once
        print -ru2 -- 'restart: overlap start did not take; stopping the old gateway first'
        claude-copilot-kill >/dev/null
        _llm_proxy_wait_down "$port" || return 1
        ( _CLAUDE_COPILOT_RESTART_ONLY=1 claude-copilot --version >/dev/null ) || return 1
        _llm_proxy_wait_up "$port" copilot
        return $?
    fi
    curl -sf --max-time 2 "http://127.0.0.1:${port}/v1/models" -o /dev/null || true  # sanity: the port serves
    for pid in "${old_pids[@]}"; do
        kill "$pid" 2>/dev/null  # SIGTERM: stop accepting, drain in-flight, exit
    done
    for i in {1..60}; do
        all_pids=($(_claude_listen_pids "$port"))
        remain=()
        for pid in "${all_pids[@]}"; do
            [[ " ${old_pids[*]} " == *" $pid "* ]] && remain+=("$pid")
        done
        (( ${#remain} == 0 )) && break  # retired (drained) or only new pids left
        sleep 0.5  # an old pid still listening is draining long requests
    done
    _llm_proxy_wait_up "$port" copilot
    print -ru2 -- "restart: copilot up on :$port (zero-gap swap)"
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

# _claude_enmaas_impl: the EnMaaS proxy impl (the controller resolves the same
# way). The Go proxy is the only impl (it translates Messages <-> Chat/Responses
# itself, translate*.go, so Claude Code keeps working with the non-Anthropic
# models in the EnMaaS catalog); the retired CLAUDE_ENMAAS_PROXY_IMPL /
# LLM_PROXY_IMPL=litellm escape hatch errors instead of silently using a path
# that no longer exists.
_claude_enmaas_impl() {
    local impl="${CLAUDE_ENMAAS_PROXY_IMPL:-${LLM_PROXY_IMPL:-go}}"
    impl="${${(L)impl}//[[:space:]]/}"   # lowercase + trim, like the controller (GO and " go " mean go)
    if [[ -z "$impl" || "$impl" == auto || "$impl" == go ]]; then
        (( $+commands[go] )) || {
            print -ru2 -- 'claude-enmaas: go not found (the Go proxy is the only impl; install a go toolchain).'
            return 1
        }
        print -r -- go
        return 0
    fi
    print -ru2 -- "claude-enmaas: the LiteLLM impl is retired; the Go proxy is the only impl (install a go toolchain). CLAUDE_ENMAAS_PROXY_IMPL must be go, got '$impl'."
    return 1
}

claude-enmaas-restart() {
    local host rc
    host=$(_llm_proxy_gateway_host)
    _llm_proxy_dns_probe "$host" enmaas || return 1
    _claude_enmaas_impl >/dev/null || return 1
    # The controller swaps (the new proxy starts alongside the old one, the old
    # retires once the new answers) instead of kill-then-start, so a request
    # arriving mid-restart is never refused. Nothing running just starts.
    print -ru2 -- 'restart: enmaas swapping (model discovery, then zero-gap swap)'
    ( CLAUDE_ENMAAS_FORCE_RESTART=1 claude-enmaas --version >/dev/null ) || {
        rc=0; _llm_proxy_dns_addresses "$host" >/dev/null || rc=$?
        if (( rc == 2 )); then _llm_proxy_dns_report "$host"; fi
        return 1
    }
    _llm_proxy_wait_up "$(_claude_enmaas_port)" enmaas
}

claude-hosted-only-restart() {
    _llm_proxy_dns_probe "$(_llm_proxy_gateway_host "${HOSTED_ONLY_ENMAAS_BASE_URL:-}")" 'hosted-only claude' || return 1
    # Force + ensure = the zero-refuse restart path: the new proxy starts
    # alongside the old one (SO_REUSEPORT) and the old retires once the new
    # listener answers, instead of stop-then-start refusing connections during
    # the boot window (2026-11-06, RH Career ECONNREFUSED).
    ( HOSTED_ONLY_FORCE_RESTART=1 _hosted_only_proxy_ensure claude ) || return 1
    _llm_proxy_wait_up "$(_hosted_only_knob CLAUDE_PROXY_PORT 4148)" 'hosted-only claude'
}
claude-glm-hybrid-restart() { claude-hosted-only-restart; }
claude-glm-only-restart() { claude-hosted-only-restart; }

codex-hosted-only-restart() {
    # shared port since the #599 merge: CODEX_PROXY_PORT defaults to the claude
    # port, so wait on the resolved port, not the old 4147 literal
    local port="$(_hosted_only_knob CODEX_PROXY_PORT "$(_hosted_only_knob CLAUDE_PROXY_PORT 4148)")"
    _llm_proxy_dns_probe "$(_llm_proxy_gateway_host "${HOSTED_ONLY_ENMAAS_BASE_URL:-}")" 'hosted-only codex' || return 1
    # zero-refuse restart, see claude-hosted-only-restart
    ( HOSTED_ONLY_FORCE_RESTART=1 _hosted_only_proxy_ensure codex ) || return 1
    _llm_proxy_wait_up "$port" 'hosted-only codex'
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
_llm_proxy_check_vertex() { _llm_proxy_check_via CLAUDE_GO_PROXY_CHECK_OUT _claude_vertex_prepare; }
_llm_proxy_check_mlx() { _llm_proxy_check_via CLAUDE_GO_PROXY_CHECK_OUT _claude_mlx_prepare; }
_llm_proxy_check_openai() { _llm_proxy_check_via CLAUDE_GO_PROXY_CHECK_OUT _claude_openai_prepare; }
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
        mlx claude-mlx-restart
        enmaas claude-enmaas-restart glm-claude claude-hosted-only-restart glm-codex codex-hosted-only-restart)
    local -A chk=(
        copilot _llm_proxy_check_copilot vertex _llm_proxy_check_vertex openai _llm_proxy_check_openai
        mlx _llm_proxy_check_mlx
        enmaas _llm_proxy_check_enmaas glm-claude _llm_proxy_check_glm_claude glm-codex _llm_proxy_check_glm_codex)
    local -A port=(
        copilot "${COPILOT_API_PORT:-4141}" vertex "${CLAUDE_VERTEX_PROXY_PORT:-4142}"
        mlx "${CLAUDE_MLX_PROXY_PORT:-4144}"
        openai "${CLAUDE_OPENAI_PROXY_PORT:-4145}" enmaas "$(_claude_enmaas_port 2>/dev/null || print 4146)"
        glm-claude "$(_hosted_only_knob CLAUDE_PROXY_PORT 4148)" glm-codex "$(_hosted_only_knob CODEX_PROXY_PORT 4147)")
    local -a order=(copilot vertex mlx openai enmaas glm-codex glm-claude) targets
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

# _llm_proxy_sync_confirm <port>: true once the proxy on <port> answers its
# health check, waiting up to LLM_PROXY_SYNC_UP_TIMEOUT seconds (default 180).
# A restart helper gives up after 15 s, but a LiteLLM proxy can need well over a
# minute to boot on a small host (EnMaaS on WSL took 96 s), so a "failed"
# restart is only failed if the port stays dead past this.
_llm_proxy_sync_confirm() {
    local port="$1" i max="${LLM_PROXY_SYNC_UP_TIMEOUT:-180}"
    [[ "$max" == <-> ]] || max=180
    for (( i = 0; i < max; i += 2 )); do
        curl -sf --max-time 2 "http://127.0.0.1:$port/health/liveliness" -o /dev/null && return 0
        sleep 2
    done
    return 1
}

# _llm_proxy_sync_tables: fills the CALLER's `fn` (restart command), `chk`
# (staleness check) and `port` associative arrays for the LiteLLM proxies that
# llm-proxy-sync and llm-proxy-watch manage (declare them `local -A` first).
_llm_proxy_sync_tables() {
    fn=(
        copilot claude-copilot-restart
        vertex claude-vertex-restart openai claude-openai-restart enmaas claude-enmaas-restart
        mlx claude-mlx-restart
        glm-claude claude-hosted-only-restart glm-codex codex-hosted-only-restart)
    chk=(
        copilot _llm_proxy_check_copilot
        vertex _llm_proxy_check_vertex openai _llm_proxy_check_openai enmaas _llm_proxy_check_enmaas
        mlx _llm_proxy_check_mlx
        glm-claude _llm_proxy_check_glm_claude glm-codex _llm_proxy_check_glm_codex)
    local _ho_shared_port="$(_hosted_only_knob CLAUDE_PROXY_PORT 4148)"
    port=(
        copilot "${COPILOT_API_PORT:-4141}"
        vertex "${CLAUDE_VERTEX_PROXY_PORT:-4142}" openai "${CLAUDE_OPENAI_PROXY_PORT:-4145}"
        mlx "${CLAUDE_MLX_PROXY_PORT:-4144}"
        enmaas "$(_claude_enmaas_port 2>/dev/null || print 4146)"
        glm-claude "$_ho_shared_port" glm-codex "$(_hosted_only_knob CODEX_PROXY_PORT "$_ho_shared_port")")
}

# llm-proxy-sync [--dry-run] [--quiet]
# The unattended cousin of `llm-proxy-restart required`, run by
# scripts/fleet-sync.zsh: a pulled hook or config change reaches a running proxy
# only when it restarts, and a T3 session that is already running never launches
# anything, so a stale proxy kept serving the old code. For every proxy
# (copilot-api, vertex, mlx, openai, enmaas, hosted-only codex and claude) that is
# listening and behind what a launch would start now (the same fingerprint
# check as `required`; copilot-api's includes a hash of the source bun runs):
# restart it when no request is in flight. One that is serving a request is not
# cut off: a detached watcher (llm-proxy-watch) waits for the first idle moment
# and restarts it then, however long that takes up to its deadline, so the
# change lands without anyone coming back to it. One restart per port: targets
# that resolve to the same listener (the hosted-only flavors share one proxy
# since #599) are handled by the first of them alone. Returns 1 when a restart
# did not bring the proxy back or a watcher could not start, 2 on a bad option;
# a proxy that cannot be checked is reported and left running.
llm-proxy-sync() {
    local dry=0 quiet=0 a
    for a in "$@"; do
        case "$a" in
            --dry-run) dry=1 ;;
            --quiet) quiet=1 ;;
            *) print -ru2 -- "llm-proxy-sync: unknown option '$a' (--dry-run, --quiet)"; return 2 ;;
        esac
    done
    local -A fn chk port
    _llm_proxy_sync_tables
    local -a order=(copilot vertex mlx openai enmaas glm-codex glm-claude)
    # the always-on set: a sync records who was listening, and the next sync
    # restarts a recorded proxy whose listener is gone (crash, OOM kill, a
    # failed boot). vertex/mlx/openai are on demand, so they only get the marker,
    # never a restart from it (2026-11-06 audit: a dead proxy was invisible to
    # fleet-sync; nothing supervises the detached processes)
    local -a always_on=(copilot enmaas glm-codex glm-claude)
    local dir; dir=$(_llm_proxy_watch_dir)
    mkdir -p "$dir" || return 1
    local t verdict why rc=0
    # Port -> 1 once a target this run handled that listener. The hosted-only
    # flavors share one proxy since #599, so glm-codex and glm-claude usually
    # resolve to the same port: the first target's restart or watcher already
    # covers the listener, and a second one must not be armed — two concurrent
    # forced swaps on one port retire each other's freshly-started proxy
    # mid-swap and refuse requests arriving in the crossfire (2026-11-07
    # ECONNREFUSED on a T3 run).
    local -A covered
    for t in $order; do
        if [[ -n "$(_claude_listen_pids "${port[$t]}")" ]]; then
            if (( $+covered[${port[$t]}] )); then
                # The listener is up, so its recovery marker must still be
                # refreshed: a later sync — or the flavors split onto separate
                # ports again — relies on up-<t> to restart a proxy it
                # remembers as always-on.
                print -r -- "${port[$t]}" >| "$dir/up-$t"
                # A watcher the skipped flavor still has waiting (armed before
                # the ports were shared, or by an older sync) bakes the
                # fingerprint it was started with and would restart the shared
                # proxy to that stale config after the target above made it
                # current: stop it — the target above owns the port.
                if _llm_proxy_watch_alive "$t" && _llm_proxy_watch_kill "$t"; then
                    _llm_proxy_watch_log "$t" "stopped: the port is handled by another target this sync"
                    (( quiet )) || print -ru2 -- "== $t (:${port[$t]}) stale watcher stopped; the target handled above owns the port"
                fi
                (( quiet )) || print -ru2 -- "== $t (:${port[$t]}) shares :${port[$t]} with the target handled above; covered by its restart"
                continue
            fi
            covered[${port[$t]}]=1
            print -r -- "${port[$t]}" >| "$dir/up-$t"   # non-empty: the port it was listening on
        elif [[ -s "$dir/up-$t" ]] && (( $(_llm_proxy_now) - $(_llm_marker_mtime "$dir/up-$t") <= 90000 )); then
            # marker fresh (<= 25 h: the hourly sync rewrites it while up, so a
            # crash leaves one at most an hour old). Older = a deliberate stop
            # that has aged out; leave it down.
            if (( ${always_on[(Ie)$t]} )); then
                if (( dry )); then
                    print -ru2 -- "== $t (:${port[$t]}) was up last sync, listener gone; would restart it"
                elif ${fn[$t]} || _llm_proxy_sync_confirm "${port[$t]}"; then
                    print -ru2 -- "== $t (:${port[$t]}) was up last sync, listener gone; restarted"
                    print -r -- "${port[$t]}" >| "$dir/up-$t"
                else
                    print -ru2 -- "== $t (:${port[$t]}) was up last sync, listener gone; restart did not bring it back; run: ${fn[$t]}"
                    rc=1
                fi
            fi
            continue
        else
            continue
        fi
        verdict=$(${chk[$t]})
        case "$verdict" in
            fresh) (( quiet )) || print -ru2 -- "== $t (:${port[$t]}) up to date"; continue ;;
            stale*) why="changed${verdict#stale}" ;;
            down) why="listener does not answer its health check" ;;
            *) print -ru2 -- "== $t (:${port[$t]}) could not be checked ($verdict; run its launcher by hand for the error); left running"; continue ;;
        esac
        if _claude_port_serving "${port[$t]}"; then
            if (( dry )); then
                print -ru2 -- "== $t (:${port[$t]}) $why; serving a request, would start a watcher that restarts it when idle"
            elif _llm_proxy_watch_alive "$t"; then
                # A Go watcher bakes its target fingerprint at start (the zsh
                # loop recomputed it at the idle moment). When a newer sync
                # arrives, replace the live watcher so the idle restart applies
                # THIS config instead of reverting to the one it was started
                # with; a mismatched or dead pid falls back to keeping it.
                if [[ "$t" == glm-claude || "$t" == glm-codex ]] && [[ "$(_hosted_only_impl)" == go ]]; then
                    local wpid wargs
                    wpid="$(<"$dir/watch-$t.pid" 2>/dev/null)"
                    wargs="$(ps -p "$wpid" -o args= 2>/dev/null)"
                    if [[ "$wpid" == <-> && "$wargs" == *hosted-only-proxy*watch* ]] && kill "$wpid" 2>/dev/null; then
                        _llm_proxy_watch_log "$t" "replaced by a newer sync with the current config"
                        if _llm_proxy_watch_start "$t"; then
                            print -ru2 -- "== $t (:${port[$t]}) $why; serving a request, watcher replaced with the current config (log: $dir/watch-$t.log)"
                            continue
                        fi
                    fi
                fi
                print -ru2 -- "== $t (:${port[$t]}) $why; serving a request, a watcher is already waiting for an idle moment (log: $(_llm_proxy_watch_dir)/watch-$t.log)"
            elif _llm_proxy_watch_start "$t"; then
                print -ru2 -- "== $t (:${port[$t]}) $why; serving a request, watcher started: restarts it at the first idle moment (log: $(_llm_proxy_watch_dir)/watch-$t.log)"
            else
                print -ru2 -- "== $t (:${port[$t]}) $why; serving a request and no watcher could start; run when idle: llm-proxy-restart required-on-idle $t"
                rc=1
            fi
            continue
        fi
        if (( dry )); then
            print -ru2 -- "== $t (:${port[$t]}) $why; idle, would restart"
            continue
        fi
        print -ru2 -- "== $t (:${port[$t]}) $why; idle, restarting"
        if ${fn[$t]} || _llm_proxy_sync_confirm "${port[$t]}"; then
            print -ru2 -- "== $t (:${port[$t]}) restarted with the current code"
        else
            print -ru2 -- "== $t (:${port[$t]}) restart did not bring it back; run: ${fn[$t]}"
            rc=1
        fi
    done
    return $rc
}

# --- idle watcher -----------------------------------------------------------
# State (one pid file and log per proxy) lives in the llm-proxy-sync state dir.
_llm_proxy_watch_dir() { print -r -- "${XDG_STATE_HOME:-$HOME/.local/state}/llm-proxy-sync"; }
# _llm_marker_mtime <file>: epoch mtime, portable across BSD/Linux stat. Each
# attempt is captured: a failed GNU `stat -f` still prints filesystem info on
# stdout, and concatenating that with the fallback's epoch breaks the age math.
_llm_marker_mtime() {
    local stamp
    stamp=$(stat -f %m "$1" 2>/dev/null)         || stamp=$(stat -c %Y "$1" 2>/dev/null)         || stamp=0
    print -r -- "$stamp"
}
_llm_proxy_now() { zmodload zsh/datetime 2>/dev/null; print -r -- "$EPOCHSECONDS"; }
# 2 s, not 0.5: each poll spawns lsof (~0.08 s CPU each), and the loop needs
# two consecutive idle polls anyway, so detection moves 2 s -> 4 s next to a
# 15-90 s restart. ~0.04 core per watcher instead of ~0.16 (2026-11-06 audit).
_llm_proxy_watch_pause() { sleep 2; }

# _llm_proxy_watch_alive <name>: true while a watcher for <name> runs. The pid
# must also still be a watcher process (the zsh loop or the Go binary's watch
# subcommand), so a recycled pid does not count.
_llm_proxy_watch_alive() {
    local pid args file="$(_llm_proxy_watch_dir)/watch-$1.pid"
    [[ -r "$file" ]] || return 1
    pid=$(<"$file")
    args="$(ps -p "$pid" -o args= 2>/dev/null)"
    [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null \
        && [[ "$args" == *llm-proxy-watch* || "$args" == *hosted-only-proxy*watch* ]]
}

# _llm_proxy_watch_kill <name>: TERM the watcher recorded for <name>, under the
# same identity check as _llm_proxy_watch_alive (a recycled pid is never
# signalled). Returns 0 when a watcher was signalled.
_llm_proxy_watch_kill() {
    local pid args file="$(_llm_proxy_watch_dir)/watch-$1.pid"
    [[ -r "$file" ]] || return 1
    pid=$(<"$file")
    args="$(ps -p "$pid" -o args= 2>/dev/null)"
    [[ "$pid" == <-> ]] && [[ "$args" == *llm-proxy-watch* || "$args" == *hosted-only-proxy*watch* ]] \
        && kill "$pid" 2>/dev/null
}

# _llm_proxy_watch_log <name> <message...>: timestamped line in the watcher log,
# echoed to stderr too (visible when run by hand, in the journal when run as a unit).
_llm_proxy_watch_log() {
    local t="$1"; shift
    local line
    zmodload zsh/datetime 2>/dev/null
    line="$(strftime '%Y-%m-%dT%H:%M:%S%z' $EPOCHSECONDS) $t: $*"
    print -ru2 -- "$line"
    print -r -- "$line" >> "$(_llm_proxy_watch_dir)/watch-$t.log" 2>/dev/null
    return 0
}

# _llm_proxy_notify <title> <message>: desktop notification, best effort.
# LLM_PROXY_NOTIFY_LOG=<file> appends instead (tests, headless hosts).
_llm_proxy_notify() {
    local title="$1" message="$2"
    if [[ -n "${LLM_PROXY_NOTIFY_LOG-}" ]]; then
        print -r -- "$title: $message" >> "$LLM_PROXY_NOTIFY_LOG" 2>/dev/null
        return 0
    fi
    if [[ "$(uname)" == Darwin ]] && (( $+commands[osascript] )); then
        local esc_t="${title//\"/\\\"}" esc_m="${message//\"/\\\"}"
        osascript -e "display notification \"${esc_m}\" with title \"${esc_t}\"" >/dev/null 2>&1
    elif (( $+commands[notify-send] )); then
        notify-send --app-name=llm-proxy-sync "$title" "$message" >/dev/null 2>&1
    fi
    return 0
}

# _llm_proxy_watch_start <name>: start a detached `llm-proxy-watch <name>`.
# Under a systemd service (the fleet-sync timer is a oneshot unit) children die
# with the unit, so the watcher goes out as its own transient user unit; anywhere
# else it is detached with nohup and outlives the shell.
_llm_proxy_watch_start() {
    local t="$1" dir
    dir=$(_llm_proxy_watch_dir)
    mkdir -p "$dir" || return 1
    local -a cmd=(zsh "${_CLAUDE_SCRIPTS_DIR}/llm-proxy-watch.zsh" "$t")
    [[ -r "${cmd[2]}" ]] || return 1
    if [[ -n "${INVOCATION_ID-}" ]] && (( $+commands[systemd-run] )); then
        systemd-run --user --quiet --collect --unit="llm-proxy-watch-$t" -- "${cmd[@]}" >/dev/null 2>&1 && return 0
    fi
    # stderr to /dev/null: llm-proxy-watch logs to the file itself, and nohup
    # redirecting stderr into the same file would write every line twice.
    ( nohup "${cmd[@]}" >>"$dir/watch-$t.log" 2>/dev/null </dev/null & )
}

# llm-proxy-watch <name>
# What the detached watcher runs (scripts/llm-proxy-watch.zsh). Polls the
# proxy's port twice a second; the first moment with no request in flight (two
# polls in a row) it checks the proxy is still behind the current code, since
# someone may have restarted it meanwhile, and restarts it. Ends when the proxy
# is current, gone, restarted, or still busy at LLM_PROXY_WATCH_TIMEOUT seconds
# (default 43200, 12 h); the next fleet-sync starts a new watcher in that case.
# One watcher per proxy.
llm-proxy-watch() {
    local t="${1-}"
    local -A fn chk port
    _llm_proxy_sync_tables
    [[ -n "${fn[$t]-}" ]] || { print -ru2 -- "llm-proxy-watch: unknown proxy '$t' (choose: ${(kj: :)fn})"; return 2; }
    local dir pidfile
    dir=$(_llm_proxy_watch_dir)
    mkdir -p "$dir" || return 1
    # Go impl (hosted-only flavors): hand the whole wait-and-restart loop to
    # the proxy binary — one static process, inflight-file idle detection with
    # no per-poll lsof/jq spawns, no zsh to keep alive in bare systemd
    # environments. The fingerprint is computed here so the watcher restarts
    # to the code fleet-sync just pulled; the binary owns the pid/log files.
    if [[ "$t" == glm-claude || "$t" == glm-codex ]] && [[ "$(_hosted_only_impl)" == go ]]; then
        local flavor=claude gobin fp_line
        [[ "$t" == glm-codex ]] && flavor=codex
        _hosted_only_proxy_vars "$flavor" || return 1
        gobin=$(_hosted_only_go_bin) || { _llm_proxy_watch_log "$t" "go proxy binary build failed"; return 1; }
        fp_line=$(_hosted_only_proxy_fp) || { _llm_proxy_watch_log "$t" "fingerprint computation failed"; return 1; }
        _hosted_only_proxy_fp_load "$fp_line"
        _hosted_only_go_env
        local -a legacy=()
        local d
        for d in $_hop_legacy_runtimes; legacy+=(--legacy-runtime "$d")
        exec env "${_hop_go_env[@]}" "$gobin" watch \
            --flavor "$flavor" --port "$_hop_port" --runtime-dir "$_hop_runtime" \
            --fingerprint "$_hop_fp" --token-fp "$_hop_token_fp" \
            --name "$t" --state-dir "$dir" "${legacy[@]}"
    fi
    pidfile="$dir/watch-$t.pid"
    if _llm_proxy_watch_alive "$t" && [[ "$(<"$pidfile")" != "$$" ]]; then
        _llm_proxy_watch_log "$t" "another watcher is already waiting; this one exits"
        return 0
    fi
    print -r -- "$$" >| "$pidfile"
    local timeout="${LLM_PROXY_WATCH_TIMEOUT:-43200}" idle=0 verdict
    [[ "$timeout" == <-> ]] || timeout=43200
    local deadline=$(( $(_llm_proxy_now) + timeout ))
    local rc=0
    {
        _llm_proxy_watch_log "$t" "serving a request; waiting for an idle moment (gives up after ${timeout}s)"
        local -i iter=0
        while true; do
            # the listener check spawns lsof like the serving check does, so it
            # runs every 10th iteration only (the health check below already
            # reports a dead proxy); iter is the poll counter
            if (( iter % 10 == 0 )) && [[ -z "$(_claude_listen_pids "${port[$t]}")" ]]; then
                _llm_proxy_watch_log "$t" "proxy is not running any more; nothing to do"
                break
            fi
            if (( $(_llm_proxy_now) >= deadline )); then
                _llm_proxy_watch_log "$t" "still busy at the deadline; giving up (the next fleet-sync starts a new watcher)"
                _llm_proxy_notify "Proxy update deferred" "$t (:${port[$t]}) stayed busy for the whole watch window; the next fleet-sync retries"
                rc=1
                break
            fi
            (( ++iter ))
            if _claude_port_serving "${port[$t]}"; then idle=0; else (( ++idle )); fi
            if (( idle >= 2 )); then
                verdict=$(${chk[$t]})
                case "$verdict" in
                    fresh) _llm_proxy_watch_log "$t" "already restarted with the current code; nothing to do"; break ;;
                    stale*|down) ;;
                    *) _llm_proxy_watch_log "$t" "could not be checked ($verdict); giving up"; rc=1; break ;;
                esac
                _llm_proxy_watch_log "$t" "idle; restarting ($verdict)"
                if ${fn[$t]} || _llm_proxy_sync_confirm "${port[$t]}"; then
                    _llm_proxy_watch_log "$t" "restarted with the current code"
                    _llm_proxy_notify "Proxy updated" "$t (:${port[$t]}) restarted at the first idle moment with the pulled code"
                else
                    _llm_proxy_watch_log "$t" "restart did not bring it back; run: ${fn[$t]}"
                    _llm_proxy_notify "Proxy restart FAILED" "$t (:${port[$t]}) — run ${fn[$t]}"
                    rc=1
                fi
                break
            fi
            _llm_proxy_watch_pause
        done
    } always {
        [[ -r "$pidfile" && "$(<"$pidfile")" == "$$" ]] && rm -f "$pidfile"
    }
    return $rc
}
