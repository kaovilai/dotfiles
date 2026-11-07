#!/bin/zsh
# Offline tests for llm-proxy-sync and llm-proxy-watch (zsh/functions/claude/
# proxies.zsh): which listening proxies are restarted, left alone or handed to
# the idle watcher, and what the watcher does. Everything the functions call is
# stubbed (a fake clock replaces real waiting), so no real proxy, port, launcher
# or process is touched.
emulate -LR zsh
local repo="${0:A:h:h}"
fail() { print -ru2 -- "FAIL: $*"; exit 1; }
source "$repo/zsh/functions/claude/common.zsh" || fail "common.zsh does not source"   # the real _claude_port_serving
source "$repo/zsh/functions/claude/proxies.zsh" || fail "proxies.zsh does not source"
source "$repo/scripts/hosted-only-proxy.zsh" || fail "hosted-only-proxy.zsh does not source"   # _hosted_only_knob, as load.zsh provides it

# The EnMaaS impl helper: the Go proxy is the only impl. GO and a padded
# " go " normalize to go; the retired =litellm knobs fail loudly instead of
# sending the proxy down a path that no longer exists.
( unset CLAUDE_ENMAAS_PROXY_IMPL LLM_PROXY_IMPL
  if (( $+commands[go] )); then
    [[ "$(_claude_enmaas_impl)" == go ]] || exit 1
    [[ "$(CLAUDE_ENMAAS_PROXY_IMPL=auto _claude_enmaas_impl)" == go ]] || exit 2
    [[ "$(CLAUDE_ENMAAS_PROXY_IMPL=GO _claude_enmaas_impl)" == go ]] || exit 3
    [[ "$(CLAUDE_ENMAAS_PROXY_IMPL=' go ' _claude_enmaas_impl)" == go ]] || exit 4
    [[ "$(LLM_PROXY_IMPL=Go _claude_enmaas_impl)" == go ]] || exit 5
  else
    # no toolchain: the helper must refuse with the guidance, not pick an impl,
    # and the rest of the suite still runs
    local err
    err=$(_claude_enmaas_impl 2>&1); [[ $? -ne 0 && "$err" == *"go not found"* ]] || exit 1
    err=$(CLAUDE_ENMAAS_PROXY_IMPL=auto _claude_enmaas_impl 2>&1); [[ $? -ne 0 && "$err" == *"go not found"* ]] || exit 2
    err=$(CLAUDE_ENMAAS_PROXY_IMPL=go _claude_enmaas_impl 2>&1); [[ $? -ne 0 && "$err" == *"go not found"* ]] || exit 3
  fi
  CLAUDE_ENMAAS_PROXY_IMPL=LiteLLM _claude_enmaas_impl 2>/dev/null && exit 6
  LLM_PROXY_IMPL=litellm _claude_enmaas_impl 2>/dev/null && exit 7
  exit 0
) || fail "_claude_enmaas_impl does not normalize like the controller (exit $?)"

# Fixed ports so the stubs can key on them; nothing real listens here.
export COPILOT_API_PORT=59000 CLAUDE_VERTEX_PROXY_PORT=59001 CLAUDE_OPENAI_PROXY_PORT=59002
export HOSTED_ONLY_CLAUDE_PROXY_PORT=59003 HOSTED_ONLY_CODEX_PROXY_PORT=59004
_claude_enmaas_port() { print 59005; }

local tmp
tmp=$(mktemp -d) || fail "mktemp"
trap 'rm -rf "$tmp"' EXIT
export XDG_STATE_HOME="$tmp/state"   # watcher pid files and logs

typeset -A listening stub_verdict serving restart_rc
typeset -a restarted confirmed watch_started watch_killed
integer WATCH_ALIVE=0 WATCH_START_RC=0 FAKE_NOW=1000 BUSY_UNTIL=0
# The real helpers are tested at the end; the sync tests use stubs for them.
functions[_real_port_serving]=$functions[_claude_port_serving]
functions[_real_watch_alive]=$functions[_llm_proxy_watch_alive]
functions[_real_watch_kill]=$functions[_llm_proxy_watch_kill]
functions[_real_watch_start]=$functions[_llm_proxy_watch_start]
functions[_real_sync_confirm]=$functions[_llm_proxy_sync_confirm]
# listening: port -> 1; stub_verdict: name -> fresh|stale: why|down|unknown; serving: port -> 1
_claude_listen_pids() { [[ -n "${listening[$1]-}" ]] && print 1234; return 0; }
_claude_port_serving() { [[ -n "${serving[$1]-}" ]] || (( FAKE_NOW < BUSY_UNTIL )); }
_llm_proxy_check_copilot() { print -r -- "${stub_verdict[copilot]-fresh}"; }
_llm_proxy_check_vertex() { print -r -- "${stub_verdict[vertex]-fresh}"; }
_llm_proxy_check_openai() { print -r -- "${stub_verdict[openai]-fresh}"; }
_llm_proxy_check_enmaas() { print -r -- "${stub_verdict[enmaas]-fresh}"; }
_llm_proxy_check_glm_claude() { print -r -- "${stub_verdict[glm-claude]-fresh}"; }
_llm_proxy_check_glm_codex() { print -r -- "${stub_verdict[glm-codex]-fresh}"; }
claude-copilot-restart() { restarted+=(copilot); return ${restart_rc[copilot]-0}; }
claude-vertex-restart() { restarted+=(vertex); return ${restart_rc[vertex]-0}; }
claude-openai-restart() { restarted+=(openai); return ${restart_rc[openai]-0}; }
claude-enmaas-restart() { restarted+=(enmaas); return ${restart_rc[enmaas]-0}; }
claude-hosted-only-restart() { restarted+=(glm-claude); return ${restart_rc[glm-claude]-0}; }
codex-hosted-only-restart() { restarted+=(glm-codex); return ${restart_rc[glm-codex]-0}; }
_llm_proxy_sync_confirm() { confirmed+=($1); [[ "${CONFIRM_RESULT-1}" == 1 ]]; }
_llm_proxy_watch_alive() { (( WATCH_ALIVE )); }
_llm_proxy_watch_start() { watch_started+=($1); return $WATCH_START_RC; }
_llm_proxy_watch_kill() { watch_killed+=($1); return 0; }
# fake clock: every poll pause is one second
_llm_proxy_now() { print -r -- $FAKE_NOW; }
_llm_proxy_watch_pause() { (( FAKE_NOW++ )); }

local out rc outfile="$tmp/out"
reset() {
    listening=(); stub_verdict=(); serving=(); restart_rc=(); restarted=(); confirmed=(); watch_started=(); watch_killed=()
    unset CONFIRM_RESULT LLM_PROXY_WATCH_TIMEOUT
    WATCH_ALIVE=0 WATCH_START_RC=0 FAKE_NOW=1000 BUSY_UNTIL=0
    rm -rf "$XDG_STATE_HOME"
}
# Not `$(...)`: a subshell would lose what the stubs record in $restarted/$confirmed.
sync() { llm-proxy-sync "$@" >"$outfile" 2>&1; rc=$?; out=$(<"$outfile"); }
watch() { llm-proxy-watch "$@" >"$outfile" 2>&1; rc=$?; out=$(<"$outfile"); }

# 1. nothing listening: silent no-op, nothing restarted
reset; sync
(( rc == 0 )) && [[ -z "$out" && ${#restarted} -eq 0 ]] || fail "idle host not a no-op: rc=$rc out=$out"

# 2. listening and fresh: left alone, reported (unless --quiet); copilot is in
# the default order too (first: its fingerprint covers the source bun runs)
reset; listening=(59000 1 59005 1 59003 1)
sync
(( rc == 0 )) && [[ "$out" == *"copilot (:59000) up to date"* && "$out" == *"enmaas (:59005) up to date"* && "$out" == *"glm-claude (:59003) up to date"* && ${#restarted} -eq 0 ]] || fail "fresh proxies touched: rc=$rc out=$out"
sync --quiet
[[ -z "$out" ]] || fail "--quiet still printed: $out"

# 2b. copilot stale and idle: restarted like the LiteLLM proxies
reset; listening=(59000 1); stub_verdict=(copilot "stale: source hash")
sync
(( rc == 0 )) && [[ "${restarted[*]}" == copilot && "$out" == *"copilot (:59000) changed: source hash; idle, restarting"* ]] || fail "stale copilot not restarted: rc=$rc restarted=$restarted out=$out"

# 3. stale and idle: restarted, with the reason; the fresh neighbour is left alone
reset; listening=(59005 1 59003 1); stub_verdict=(enmaas "stale: hooks, knobs")
sync
(( rc == 0 )) && [[ "${restarted[*]}" == enmaas ]] || fail "stale idle proxy not (only) restarted: restarted=$restarted out=$out"
[[ "$out" == *"enmaas (:59005) changed: hooks, knobs; idle, restarting"* && "$out" == *"enmaas (:59005) restarted with the current code"* ]] || fail "restart not reported: $out"
[[ ${#confirmed} -eq 0 && ${#watch_started} -eq 0 ]] || fail "confirm polled / watcher started for an idle proxy: $confirmed $watch_started"

# 4. stale but serving a request: not cut off; a watcher is started for it
reset; listening=(59004 1); stub_verdict=(glm-codex "stale: hooks"); serving=(59004 1)
sync
(( rc == 0 && ${#restarted} == 0 )) || fail "busy proxy was restarted: rc=$rc restarted=$restarted"
[[ "${watch_started[*]}" == glm-codex ]] || fail "no watcher started for the busy proxy: $watch_started"
[[ "$out" == *"glm-codex (:59004) changed: hooks; serving a request, watcher started: restarts it at the first idle moment (log: "*"watch-glm-codex.log)"* ]] || fail "busy proxy not reported: $out"

# 4b. a watcher is already waiting: none is started twice
reset; listening=(59004 1); stub_verdict=(glm-codex "stale: hooks"); serving=(59004 1); WATCH_ALIVE=1
sync
(( rc == 0 && ${#watch_started} == 0 && ${#restarted} == 0 )) && [[ "$out" == *"a watcher is already waiting for an idle moment"* ]] || fail "duplicate watcher: rc=$rc started=$watch_started out=$out"

# 4c. the watcher cannot start: failure reported with the manual command
reset; listening=(59004 1); stub_verdict=(glm-codex "stale: hooks"); serving=(59004 1); WATCH_START_RC=1
sync
(( rc == 1 && ${#restarted} == 0 )) && [[ "$out" == *"no watcher could start; run when idle: llm-proxy-restart required-on-idle glm-codex"* ]] || fail "watcher start failure not reported: rc=$rc out=$out"

# 4d. a fresh proxy that is busy needs nothing: no watcher
reset; listening=(59004 1); serving=(59004 1)
sync
(( rc == 0 && ${#watch_started} == 0 && ${#restarted} == 0 )) || fail "busy but current proxy got a watcher: started=$watch_started"

# 5. --dry-run: says it would restart / would start a watcher, does neither
reset; listening=(59005 1); stub_verdict=(enmaas "stale: key")
sync --dry-run
(( rc == 0 && ${#restarted} == 0 )) && [[ "$out" == *"idle, would restart"* ]] || fail "dry run acted or stayed silent: rc=$rc restarted=$restarted out=$out"
reset; listening=(59005 1); stub_verdict=(enmaas "stale: key"); serving=(59005 1)
sync --dry-run
(( rc == 0 && ${#restarted} == 0 && ${#watch_started} == 0 )) && [[ "$out" == *"would start a watcher that restarts it when idle"* ]] || fail "dry run started a watcher: started=$watch_started out=$out"

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

# 12. was-up marker: a recorded always-on proxy whose listener is gone is
# restarted; an on-demand proxy (vertex) with the same marker is not
reset; listening=(59005 1); sync
[[ -s "$XDG_STATE_HOME/llm-proxy-sync/up-enmaas" ]] || fail "up-marker not recorded while listening"
reset; listening=()
mkdir -p "$XDG_STATE_HOME/llm-proxy-sync"
print -r -- 59005 > "$XDG_STATE_HOME/llm-proxy-sync/up-enmaas"
print -r -- 59001 > "$XDG_STATE_HOME/llm-proxy-sync/up-vertex"
sync
(( rc == 0 )) && [[ "${restarted[*]}" == enmaas && "$out" == *"enmaas (:59005) was up last sync, listener gone; restarted"* ]] || fail "crashed always-on proxy not restarted: rc=$rc restarted=$restarted out=$out"
[[ -s "$XDG_STATE_HOME/llm-proxy-sync/up-enmaas" ]] || fail "marker dropped on a successful restart"

# 12b. marker restart that fails: rc 1, reported, marker kept for the next sync
reset; listening=()
mkdir -p "$XDG_STATE_HOME/llm-proxy-sync"
print -r -- 59003 > "$XDG_STATE_HOME/llm-proxy-sync/up-glm-claude"; restart_rc=(glm-claude 1); CONFIRM_RESULT=0
sync
(( rc == 1 )) && [[ "$out" == *"was up last sync, listener gone; restart did not bring it back; run: claude-hosted-only-restart"* ]] || fail "failed marker restart mishandled: rc=$rc out=$out"
[[ -s "$XDG_STATE_HOME/llm-proxy-sync/up-glm-claude" ]] || fail "marker dropped on a failed restart"

# 12c. dry-run reports the would-be marker restart, does not run it
reset; listening=()
mkdir -p "$XDG_STATE_HOME/llm-proxy-sync"; print -r -- 59005 > "$XDG_STATE_HOME/llm-proxy-sync/up-enmaas"
sync --dry-run
(( rc == 0 && ${#restarted} == 0 )) && [[ "$out" == *"was up last sync, listener gone; would restart it"* ]] || fail "dry-run restarted a dead proxy: rc=$rc out=$out"

# 13. one restart per port: with the #599 shared port (both hosted-only flavors
# on :59003) a stale listener gets ONE watcher / ONE restart from the first
# target; the second flavor is reported as covered, never armed alongside it
# (two watchers on one port retire each other's fresh proxy mid-swap). The env
# prefix scopes the shared port to these sync calls only.
reset; listening=(59003 1)
stub_verdict=(glm-codex "stale: hooks" glm-claude "stale: hooks"); serving=(59003 1)
HOSTED_ONLY_CODEX_PROXY_PORT=59003 sync
(( rc == 0 )) && [[ "${watch_started[*]}" == glm-codex && ${#restarted} -eq 0 ]] || fail "shared port armed more than one watcher: started=$watch_started restarted=$restarted"
[[ "$out" == *"glm-claude (:59003) shares :59003 with the target handled above; covered by its restart"* ]] || fail "covered flavor not reported: $out"
reset; listening=(59003 1)
stub_verdict=(glm-codex "stale: hooks" glm-claude "stale: hooks")
HOSTED_ONLY_CODEX_PROXY_PORT=59003 sync
(( rc == 0 )) && [[ "${restarted[*]}" == glm-codex ]] || fail "shared port restarted twice: restarted=$restarted"
[[ "$out" == *"covered by its restart"* ]] || fail "covered flavor not reported when idle: $out"
# --quiet stays silent about the covered flavor too
reset; listening=(59003 1)
stub_verdict=(glm-codex "stale: hooks" glm-claude "stale: hooks")
HOSTED_ONLY_CODEX_PROXY_PORT=59003 sync --quiet
[[ "$out" == *"glm-claude"* ]] && fail "--quiet reported the covered flavor: $out"
# 13b. the covered flavor's recovery marker is still refreshed (a later sync,
# or the flavors split onto separate ports again, relies on it to restart a
# crashed always-on proxy), and a watcher it still has waiting — armed before
# the ports were shared or by an older sync, baking an old fingerprint — is
# stopped instead of left to restart the shared proxy to stale config
reset; listening=(59003 1); WATCH_ALIVE=1
stub_verdict=(glm-codex "stale: hooks" glm-claude "stale: hooks"); serving=(59003 1)
HOSTED_ONLY_CODEX_PROXY_PORT=59003 sync
[[ -s "$XDG_STATE_HOME/llm-proxy-sync/up-glm-claude" ]] || fail "covered flavor's up-marker not refreshed"
[[ "$(<"$XDG_STATE_HOME/llm-proxy-sync/up-glm-claude")" == 59003 ]] || fail "covered flavor's up-marker has the wrong port"
[[ "${watch_killed[*]}" == glm-claude ]] || fail "covered flavor's stale watcher not stopped: killed=$watch_killed"
[[ "$out" == *"stale watcher stopped; the target handled above owns the port"* ]] || fail "watcher stop not reported: $out"
# no live watcher for the covered flavor: nothing to stop, still covered
reset; listening=(59003 1)
stub_verdict=(glm-codex "stale: hooks" glm-claude "stale: hooks")
HOSTED_ONLY_CODEX_PROXY_PORT=59003 sync
(( rc == 0 )) && [[ ${#watch_killed} -eq 0 ]] || fail "stopped a watcher that was not alive: killed=$watch_killed"

# --- llm-proxy-watch (the detached watcher) ---------------------------------

# W1. busy for a while, then idle: restarted at the first idle moment (two quiet
# polls), still stale at that point, pid file gone afterwards, log written
reset; listening=(59005 1); stub_verdict=(enmaas "stale: hooks"); BUSY_UNTIL=1005
watch enmaas
(( rc == 0 )) && [[ "${restarted[*]}" == enmaas ]] || fail "watcher did not restart once idle: rc=$rc restarted=$restarted out=$out"
(( FAKE_NOW >= 1006 && FAKE_NOW <= 1008 )) || fail "watcher restarted at the wrong moment (clock $FAKE_NOW; busy until 1005)"
[[ "$out" == *"waiting for an idle moment"* && "$out" == *"idle; restarting (stale: hooks)"* && "$out" == *"restarted with the current code"* ]] || fail "watcher log incomplete: $out"
[[ ! -e "$XDG_STATE_HOME/llm-proxy-sync/watch-enmaas.pid" ]] || fail "pid file left behind"
[[ "$(<"$XDG_STATE_HOME/llm-proxy-sync/watch-enmaas.log")" == *"restarted with the current code"* ]] || fail "log file not written"

# W2. never restarts while a request is in flight
reset; listening=(59005 1); stub_verdict=(enmaas "stale: hooks"); BUSY_UNTIL=1500; LLM_PROXY_WATCH_TIMEOUT=100
watch enmaas
(( rc == 1 && ${#restarted} == 0 )) && [[ "$out" == *"still busy at the deadline; giving up"* ]] || fail "watcher cut a busy proxy or hid the give-up: rc=$rc restarted=$restarted out=$out"

# W3. someone restarted it meanwhile: nothing left to do
reset; listening=(59005 1); stub_verdict=(enmaas fresh); BUSY_UNTIL=1003
watch enmaas
(( rc == 0 && ${#restarted} == 0 )) && [[ "$out" == *"already restarted with the current code; nothing to do"* ]] || fail "watcher restarted a current proxy: rc=$rc restarted=$restarted out=$out"

# W4. the proxy went away while waiting
reset; stub_verdict=(enmaas "stale: hooks")
watch enmaas
(( rc == 0 && ${#restarted} == 0 )) && [[ "$out" == *"proxy is not running any more"* ]] || fail "watcher acted on a dead proxy: rc=$rc out=$out"

# W5. restart fails and the port stays dead: rc 1, the manual command
reset; listening=(59005 1); stub_verdict=(enmaas "stale: hooks"); restart_rc=(enmaas 1); CONFIRM_RESULT=0
watch enmaas
(( rc == 1 )) && [[ "$out" == *"restart did not bring it back; run: claude-enmaas-restart"* ]] || fail "watcher hid a failed restart: rc=$rc out=$out"

# W6. slow boot (restart helper gives up early, port answers later): success
reset; listening=(59005 1); stub_verdict=(enmaas "stale: hooks"); restart_rc=(enmaas 1)
watch enmaas
(( rc == 0 )) && [[ "${confirmed[*]}" == 59005 && "$out" == *"restarted with the current code"* ]] || fail "slow boot counted as failure by the watcher: rc=$rc out=$out"

# W7. launcher cannot compare: gives up, does not restart blindly
reset; listening=(59005 1); stub_verdict=(enmaas unknown)
watch enmaas
(( rc == 1 && ${#restarted} == 0 )) && [[ "$out" == *"could not be checked (unknown); giving up"* ]] || fail "watcher restarted without a verdict: rc=$rc restarted=$restarted"

# W8. one watcher per proxy: another live one makes this exit at once
reset; listening=(59005 1); stub_verdict=(enmaas "stale: hooks"); WATCH_ALIVE=1
mkdir -p "$XDG_STATE_HOME/llm-proxy-sync"; print -r -- 999999 > "$XDG_STATE_HOME/llm-proxy-sync/watch-enmaas.pid"
watch enmaas
(( rc == 0 && ${#restarted} == 0 )) && [[ "$out" == *"another watcher is already waiting"* ]] || fail "second watcher ran: rc=$rc restarted=$restarted"
[[ "$(<"$XDG_STATE_HOME/llm-proxy-sync/watch-enmaas.pid")" == 999999 ]] || fail "second watcher clobbered the first one's pid file"
WATCH_ALIVE=0

# W9. unknown proxy name
reset
watch bogus
(( rc == 2 )) && [[ "$out" == *"unknown proxy 'bogus'"* ]] || fail "bad proxy name accepted: rc=$rc out=$out"

# --- real helpers -----------------------------------------------------------

# H1. the real confirm helper polls the health URL and gives up at its timeout
functions[_llm_proxy_sync_confirm]=$functions[_real_sync_confirm]
mkdir -p "$tmp/bin"
print -r -- $'#!/bin/sh\nexit 22' > "$tmp/bin/curl"; chmod +x "$tmp/bin/curl"
LLM_PROXY_SYNC_UP_TIMEOUT=2 PATH="$tmp/bin:$PATH" _llm_proxy_sync_confirm 59999 && fail "dead port confirmed"
print -r -- $'#!/bin/sh\nexit 0' > "$tmp/bin/curl"
LLM_PROXY_SYNC_UP_TIMEOUT=2 PATH="$tmp/bin:$PATH" _llm_proxy_sync_confirm 59999 || fail "live port not confirmed"

# H2. the real alive check: no pid file, dead pid, live non-watcher pid, live watcher
functions[_llm_proxy_watch_alive]=$functions[_real_watch_alive]
functions[_llm_proxy_watch_kill]=$functions[_real_watch_kill]
reset
_llm_proxy_watch_alive enmaas && fail "alive with no pid file"
mkdir -p "$XDG_STATE_HOME/llm-proxy-sync"
print -r -- 2147483646 > "$XDG_STATE_HOME/llm-proxy-sync/watch-enmaas.pid"
_llm_proxy_watch_alive enmaas && fail "alive with a dead pid"
sleep 30 & local sleeper=$!
print -r -- $sleeper > "$XDG_STATE_HOME/llm-proxy-sync/watch-enmaas.pid"
_llm_proxy_watch_alive enmaas && fail "a live process that is not a watcher counted (recycled pid)"
kill $sleeper 2>/dev/null; wait $sleeper 2>/dev/null
print -r -- $'#!/bin/sh\nsleep 30' > "$tmp/bin/llm-proxy-watch-fake.sh"; chmod +x "$tmp/bin/llm-proxy-watch-fake.sh"
sh "$tmp/bin/llm-proxy-watch-fake.sh" & local fake=$!
print -r -- $fake > "$XDG_STATE_HOME/llm-proxy-sync/watch-enmaas.pid"
sleep 0.3
_llm_proxy_watch_alive enmaas || { kill $fake 2>/dev/null; fail "live watcher not recognised"; }
# the real kill helper TERMs that watcher (same identity check) ...
_llm_proxy_watch_kill enmaas || { kill $fake 2>/dev/null; fail "kill helper did not signal the live watcher"; }
wait $fake 2>/dev/null; local wrc=$?
(( wrc == 143 )) || fail "watcher exited with $wrc, expected SIGTERM (143)"
# ... and never signals a dead pid or a non-watcher process
_llm_proxy_watch_kill enmaas && fail "kill helper signalled a dead pid"
print -r -- $$ > "$XDG_STATE_HOME/llm-proxy-sync/watch-enmaas.pid"
_llm_proxy_watch_kill enmaas && fail "kill helper signalled a non-watcher process"

# H3. the real start helper: detaches the watcher script with the proxy name...
functions[_llm_proxy_watch_start]=$functions[_real_watch_start]
reset
export _CLAUDE_SCRIPTS_DIR="$tmp/scripts"; mkdir -p "$_CLAUDE_SCRIPTS_DIR"
print -r -- $'emulate -L zsh\nprint -r -- "args=$*" >> "$XDG_STATE_HOME/ran"' > "$_CLAUDE_SCRIPTS_DIR/llm-proxy-watch.zsh"
_llm_proxy_watch_start enmaas || fail "start helper failed"
for i in {1..50}; do [[ -s "$XDG_STATE_HOME/ran" ]] && break; sleep 0.1; done
[[ "$(<"$XDG_STATE_HOME/ran")" == "args=enmaas" ]] || fail "watcher script did not run with the proxy name: $(<"$XDG_STATE_HOME/ran" 2>/dev/null)"
# ...as a transient systemd user unit when fleet-sync itself runs as one
rm -f "$XDG_STATE_HOME/ran"
print -r -- $'#!/bin/sh\necho "$*" >> "$XDG_STATE_HOME/systemd-run"\nexit 0' > "$tmp/bin/systemd-run"; chmod +x "$tmp/bin/systemd-run"
rehash
INVOCATION_ID=abc PATH="$tmp/bin:$PATH" _llm_proxy_watch_start glm-claude || fail "start under systemd failed"
[[ "$(<"$XDG_STATE_HOME/systemd-run")" == *"--user"*"--unit=llm-proxy-watch-glm-claude"*"llm-proxy-watch.zsh glm-claude"* ]] || fail "systemd-run not used as a user unit: $(<"$XDG_STATE_HOME/systemd-run")"
sleep 0.5
[[ ! -e "$XDG_STATE_HOME/ran" ]] || fail "also ran the script directly although systemd-run took it"
# a failing systemd-run falls back to nohup
print -r -- $'#!/bin/sh\nexit 1' > "$tmp/bin/systemd-run"
rehash
INVOCATION_ID=abc PATH="$tmp/bin:$PATH" _llm_proxy_watch_start glm-claude || fail "no fallback when systemd-run fails"
for i in {1..50}; do [[ -s "$XDG_STATE_HOME/ran" ]] && break; sleep 0.1; done
[[ "$(<"$XDG_STATE_HOME/ran")" == "args=glm-claude" ]] || fail "fallback did not run the watcher"
# a missing script is a failure the caller can report
rm -f "$_CLAUDE_SCRIPTS_DIR/llm-proxy-watch.zsh"
_llm_proxy_watch_start enmaas && fail "start helper succeeded without a watcher script"

# H5. the real serving check: in-flight files decide, sockets are the fallback
functions[_claude_port_serving]=$functions[_real_port_serving]
mkdir -p "$XDG_STATE_HOME/llm-usage"
print -r -- "{\"pid\": $$, \"port\": \"59005\", \"requests\": {\"r1\": {\"t\": 1}}}" > "$XDG_STATE_HOME/llm-usage/inflight-59005-$$.json"
_claude_port_serving 59005 || fail "live in-flight file not seen as busy"
print -r -- "{\"pid\": $$, \"port\": \"59005\", \"requests\": {}}" >| "$XDG_STATE_HOME/llm-usage/inflight-59005-$$.json"
_claude_port_serving 59005 && fail "empty in-flight table counted as busy (the keep-alive stall)"
print -r -- "{\"pid\": $$, \"port\": \"59005\", \"requests\": {\"r1\": {\"t\": 1}}}" >| "$XDG_STATE_HOME/llm-usage/inflight-59005-999999999.json"
_claude_port_serving 59005 && fail "dead-pid in-flight file counted as busy"
rm -f "$XDG_STATE_HOME/llm-usage"/inflight-59005-*.json
_claude_port_serving 59998 && fail "socket fallback saw busy with no listener and no in-flight files"

# H4. the real watcher script bootstraps (sources load.zsh) and finds the function
env -i HOME="$tmp/home" PATH="$PATH" XDG_STATE_HOME="$tmp/state2" zsh "$repo/scripts/llm-proxy-watch.zsh" bogus >"$outfile" 2>&1
rc=$?; out=$(<"$outfile")
(( rc == 2 )) && [[ "$out" == *"unknown proxy 'bogus'"* ]] || fail "scripts/llm-proxy-watch.zsh does not reach llm-proxy-watch: rc=$rc out=$out"

print -r -- "ok llm-proxy-sync"
