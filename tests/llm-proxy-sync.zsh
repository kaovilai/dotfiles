#!/bin/zsh
# Offline tests for llm-proxy-sync (zsh/functions/claude/proxies.zsh): which
# listening proxies are restarted, left alone or reported. Everything the
# function calls is stubbed, so no real proxy, port or launcher is touched.
emulate -LR zsh
local repo="${0:A:h:h}"
fail() { print -ru2 -- "FAIL: $*"; exit 1; }
source "$repo/zsh/functions/claude/proxies.zsh" || fail "proxies.zsh does not source"
source "$repo/scripts/hosted-only-proxy.zsh" || fail "hosted-only-proxy.zsh does not source"   # _hosted_only_knob, as load.zsh provides it

# Fixed ports so the stubs can key on them; nothing real listens here.
export CLAUDE_VERTEX_PROXY_PORT=59001 CLAUDE_OPENAI_PROXY_PORT=59002
export HOSTED_ONLY_CLAUDE_PROXY_PORT=59003 HOSTED_ONLY_CODEX_PROXY_PORT=59004
_claude_enmaas_port() { print 59005; }

typeset -A listening stub_verdict serving restart_rc
typeset -a restarted confirmed
# listening: port -> 1; stub_verdict: name -> fresh|stale: why|down|unknown; serving: port -> 1
_claude_listen_pids() { [[ -n "${listening[$1]-}" ]] && print 1234; return 0; }
_claude_port_serving() { [[ -n "${serving[$1]-}" ]]; }
_llm_proxy_check_vertex() { print -r -- "${stub_verdict[vertex]-fresh}"; }
_llm_proxy_check_openai() { print -r -- "${stub_verdict[openai]-fresh}"; }
_llm_proxy_check_enmaas() { print -r -- "${stub_verdict[enmaas]-fresh}"; }
_llm_proxy_check_glm_claude() { print -r -- "${stub_verdict[glm-claude]-fresh}"; }
_llm_proxy_check_glm_codex() { print -r -- "${stub_verdict[glm-codex]-fresh}"; }
claude-vertex-restart() { restarted+=(vertex); return ${restart_rc[vertex]-0}; }
claude-openai-restart() { restarted+=(openai); return ${restart_rc[openai]-0}; }
claude-enmaas-restart() { restarted+=(enmaas); return ${restart_rc[enmaas]-0}; }
claude-hosted-only-restart() { restarted+=(glm-claude); return ${restart_rc[glm-claude]-0}; }
codex-hosted-only-restart() { restarted+=(glm-codex); return ${restart_rc[glm-codex]-0}; }
_llm_proxy_sync_confirm() { confirmed+=($1); [[ "${CONFIRM_RESULT-1}" == 1 ]]; }

local out rc outfile
outfile=$(mktemp) || fail "mktemp"
reset() { listening=(); stub_verdict=(); serving=(); restart_rc=(); restarted=(); confirmed=(); unset CONFIRM_RESULT; }
# Not `$(...)`: a subshell would lose what the stubs record in $restarted/$confirmed.
sync() { llm-proxy-sync "$@" >"$outfile" 2>&1; rc=$?; out=$(<"$outfile"); }

# 1. nothing listening: silent no-op, nothing restarted
reset; sync
(( rc == 0 )) && [[ -z "$out" && ${#restarted} -eq 0 ]] || fail "idle host not a no-op: rc=$rc out=$out"

# 2. listening and fresh: left alone, reported (unless --quiet)
reset; listening=(59005 1 59003 1)
sync
(( rc == 0 )) && [[ "$out" == *"enmaas (:59005) up to date"* && "$out" == *"glm-claude (:59003) up to date"* && ${#restarted} -eq 0 ]] || fail "fresh proxies touched: rc=$rc out=$out"
sync --quiet
[[ -z "$out" ]] || fail "--quiet still printed: $out"

# 3. stale and idle: restarted, with the reason; the fresh neighbour is left alone
reset; listening=(59005 1 59003 1); stub_verdict=(enmaas "stale: hooks, knobs")
sync
(( rc == 0 )) && [[ "${restarted[*]}" == enmaas ]] || fail "stale idle proxy not (only) restarted: restarted=$restarted out=$out"
[[ "$out" == *"enmaas (:59005) changed: hooks, knobs; idle, restarting"* && "$out" == *"enmaas (:59005) restarted with the current code"* ]] || fail "restart not reported: $out"
[[ ${#confirmed} -eq 0 ]] || fail "confirm polled although the restart succeeded: $confirmed"

# 4. stale but serving a request: left running and said so, with the way to force it
reset; listening=(59004 1); stub_verdict=(glm-codex "stale: hooks"); serving=(59004 1)
sync
(( rc == 0 && ${#restarted} == 0 )) || fail "busy proxy was restarted: rc=$rc restarted=$restarted"
[[ "$out" == *"glm-codex (:59004) changed: hooks; serving a request, left running"* && "$out" == *"required-on-idle glm-codex"* ]] || fail "busy proxy not reported: $out"

# 5. --dry-run: says it would restart, restarts nothing
reset; listening=(59005 1); stub_verdict=(enmaas "stale: key")
sync --dry-run
(( rc == 0 && ${#restarted} == 0 )) && [[ "$out" == *"idle, would restart"* ]] || fail "dry run acted or stayed silent: rc=$rc restarted=$restarted out=$out"

# 6. a listener that does not answer its health check counts as needing a restart
reset; listening=(59003 1); stub_verdict=(glm-claude down)
sync
[[ "${restarted[*]}" == glm-claude && "$out" == *"listener does not answer its health check; idle, restarting"* ]] || fail "dead listener not restarted: $restarted / $out"

# 7. launcher could not compare: reported, left running, not a failure
reset; listening=(59005 1); stub_verdict=(enmaas unknown)
sync
(( rc == 0 && ${#restarted} == 0 )) && [[ "$out" == *"could not be checked (unknown"* ]] || fail "unknown stub_verdict mishandled: rc=$rc out=$out"

# 8. restart helper fails but the proxy comes up late (slow boot): success after confirm
reset; listening=(59005 1); stub_verdict=(enmaas "stale: hooks"); restart_rc=(enmaas 1)
sync
(( rc == 0 )) && [[ "${confirmed[*]}" == 59005 && "$out" == *"restarted with the current code"* ]] || fail "slow boot counted as failure: rc=$rc confirmed=$confirmed out=$out"

# 9. restart fails and the port stays dead: rc 1, the command to run by hand
reset; listening=(59005 1); stub_verdict=(enmaas "stale: hooks"); restart_rc=(enmaas 1); CONFIRM_RESULT=0
sync
(( rc == 1 )) && [[ "$out" == *"restart did not bring it back; run: claude-enmaas-restart"* ]] || fail "dead restart not reported: rc=$rc out=$out"

# 10. one failure does not stop the others (order: enmaas before glm-claude)
reset; listening=(59005 1 59003 1); stub_verdict=(enmaas "stale: a" glm-claude "stale: b"); restart_rc=(enmaas 1); CONFIRM_RESULT=0
sync
(( rc == 1 )) && [[ "${restarted[*]}" == "enmaas glm-claude" ]] || fail "later proxy skipped after a failure: rc=$rc restarted=$restarted"

# 11. bad option
reset
sync --nope
(( rc == 2 )) && [[ "$out" == *"unknown option '--nope'"* ]] || fail "bad option accepted: rc=$rc out=$out"

# 12. the real confirm helper polls the health URL and gives up at its timeout
unfunction _llm_proxy_sync_confirm
source "$repo/zsh/functions/claude/proxies.zsh"
tmpbin=$(mktemp -d); trap 'rm -rf "$tmpbin" "$outfile"' EXIT
print -r -- $'#!/bin/sh\nexit 22' > "$tmpbin/curl"; chmod +x "$tmpbin/curl"
LLM_PROXY_SYNC_UP_TIMEOUT=2 PATH="$tmpbin:$PATH" _llm_proxy_sync_confirm 59999 && fail "dead port confirmed"
print -r -- $'#!/bin/sh\nexit 0' > "$tmpbin/curl"
LLM_PROXY_SYNC_UP_TIMEOUT=2 PATH="$tmpbin:$PATH" _llm_proxy_sync_confirm 59999 || fail "live port not confirmed"

print -r -- "ok llm-proxy-sync"
