#!/bin/zsh
# Offline tests for scripts/fleet-sync.zsh: three checkouts of local bare
# "upstream" repos, a throwaway HOME, and stub claude/bun binaries that log
# their arguments (the claude stub also edits settings.json the way
# `claude plugin marketplace add` does, to prove the file is put back).
emulate -LR zsh
setopt err_exit pipe_fail
local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
local gw= client=
trap 'kill $gw $client 2>/dev/null; rm -rf "$tmp"' EXIT
fail() { print -ru2 -- "FAIL: $*"; exit 1; }

local -a G=(git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c advice.detachedHead=false)
# mkrepo <name>: bare upstream + working clone at $tmp/<name>, one commit
mkrepo() {
    $G init -q --bare "$tmp/up-$1.git"
    $G clone -q "$tmp/up-$1.git" "$tmp/$1" 2>/dev/null
    print -r -- one > "$tmp/$1/file"
    $G -C "$tmp/$1" add file && $G -C "$tmp/$1" commit -qm one && $G -C "$tmp/$1" push -q origin main 2>/dev/null
    $G clone -q "$tmp/up-$1.git" "$tmp/other-$1" 2>/dev/null   # pushes "from another machine"
}
# upstream <name> <file> <content>: commit + push from the other clone
upstream() {
    print -r -- "$3" > "$tmp/other-$1/$2"
    $G -C "$tmp/other-$1" add "$2" && $G -C "$tmp/other-$1" commit -qm "$2" && $G -C "$tmp/other-$1" push -q origin main 2>/dev/null
}
head_of() { git -C "$tmp/$1" rev-parse HEAD; }
up_head() { git -C "$tmp/up-$1.git" rev-parse main; }

mkrepo dot; mkrepo cfg; mkrepo capi
export HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" COPILOT_API_PORT=59997
# The LLM proxies fleet-sync may restart: point them at ports nothing uses so a
# developer's real :4146/:4147/:4148 proxies are never looked at, let alone restarted.
export CLAUDE_VERTEX_PROXY_PORT=59991 CLAUDE_OPENAI_PROXY_PORT=59992 CLAUDE_ENMAAS_PROXY_PORT=59993
export HOSTED_ONLY_CODEX_PROXY_PORT=59994 HOSTED_ONLY_CLAUDE_PROXY_PORT=59995
export FLEET_DOTFILES_DIR="$tmp/dot" FLEET_CLAUDE_DIR="$tmp/cfg" COPILOT_API_DIR="$tmp/capi"
export CLAUDE_PROVIDER_NATIVE_BINARY="$HOME/.local/bin/claude" STUB_LOG="$tmp/calls"
mkdir -p "$HOME/.claude/plugins" "$HOME/.local/bin" "$HOME/.bun/bin"
mkdir -p "$tmp/dot/.codex/skills/example"
print -r -- "example skill" > "$tmp/dot/.codex/skills/example/SKILL.md"
mkdir -p "$tmp/dot/.codex" "$tmp/cfg/skills/skills-compress/scripts"
print -r -- '{"hooks":{"PreToolUse":[{"matcher":"exec_command","hooks":[{"type":"command","command":"true"}]}]}}' > "$tmp/dot/.codex/hooks.json"
print -r -- $'#!/bin/sh\necho "sync-harnesses $*" >> "$STUB_LOG"' > "$tmp/cfg/skills/skills-compress/scripts/sync-harnesses.sh"
chmod +x "$tmp/cfg/skills/skills-compress/scripts/sync-harnesses.sh"
print -r -- '{"enabledPlugins":{"x@m":true,"off@m":false},"extraKnownMarketplaces":{"m":{"source":{"source":"github","repo":"o/m"}}}}' > "$HOME/.claude/settings.json"
cp "$HOME/.claude/settings.json" "$tmp/settings.orig"
cat > "$HOME/.local/bin/claude" <<'EOF'
#!/bin/sh
echo "claude $*" >> "$STUB_LOG"
case "$*" in
    "plugin marketplace add"*)
        jq '.extraKnownMarketplaces.m.source.repo = "rewritten"' "$HOME/.claude/settings.json" > "$HOME/.claude/s.tmp" &&
            mv "$HOME/.claude/s.tmp" "$HOME/.claude/settings.json" ;;
esac
exit 0
EOF
print -r -- $'#!/bin/sh\necho "bun $*" >> "$STUB_LOG"' > "$HOME/.bun/bin/bun"
chmod +x "$HOME/.local/bin/claude" "$HOME/.bun/bin/bun"

local out rc
run() { : >| "$STUB_LOG"; out=$(zsh "$repo/scripts/fleet-sync.zsh" "$@" 2>&1); rc=$?; return $rc; }
calls() { cat "$STUB_LOG"; }

# 1. In sync, no plugin stamp yet: daily plugin pass adds the marketplace,
#    refreshes, installs the enabled plugin only; settings.json put back
run || fail "first run rc=$rc: $out"
[[ -L "$HOME/.codex/skills/example" ]] || fail "codex skill not linked: $out"
[[ -f "$HOME/.codex/hooks.json" ]] || fail "codex hooks.json not installed: $out"
cmp -s "$tmp/dot/.codex/hooks.json" "$HOME/.codex/hooks.json" || fail "codex hooks.json drifted: $(<"$HOME/.codex/hooks.json")"
[[ "$(calls)" == *"sync-harnesses"* ]] || fail "sync-harnesses not called: $(calls)"
[[ "$(calls)" == *"plugin marketplace add o/m"* ]] || fail "marketplace not added: $(calls)"
[[ "$(calls)" == *"plugin marketplace update"* ]] || fail "marketplaces not refreshed: $(calls)"
[[ "$(calls)" == *"plugin install x@m"* && "$(calls)" != *"off@m"* ]] || fail "plugin install wrong: $(calls)"
cmp -s "$tmp/settings.orig" "$HOME/.claude/settings.json" || fail "settings.json not restored: $(<"$HOME/.claude/settings.json")"
[[ -f "$XDG_STATE_HOME/fleet-sync/plugins-updated" ]] || fail "plugin stamp not written"

# 2. In sync, stamp fresh: nothing to do — no plugin calls, no harness re-link
run || fail "second run rc=$rc: $out"
[[ -z "$(calls)" ]] || fail "idle run did work: $(calls)"

# 2b. Corrupted installed hooks.json: reinstalled, sync-harnesses re-run
print -r -- '{"hooks":' >| "$HOME/.codex/hooks.json"
run || fail "hooks reinstall run rc=$rc: $out"
cmp -s "$tmp/dot/.codex/hooks.json" "$HOME/.codex/hooks.json" || fail "corrupted hooks.json not restored: $(<"$HOME/.codex/hooks.json")"
[[ "$(calls)" == *"sync-harnesses"* ]] || fail "hooks.json install did not re-run sync-harnesses: $(calls)"

# 3. Claude config moved upstream: fast-forward, plugin sync without --update,
#    sync-harnesses re-run (its inputs live in the claude-config repo)
upstream cfg skills.md new-skill
run || fail "config run rc=$rc: $out"
[[ "$(head_of cfg)" == "$(up_head cfg)" ]] || fail "config not fast-forwarded"
[[ "$(calls)" == *"plugin install x@m"* && "$(calls)" != *"marketplace update"* ]] || fail "config change plugin pass wrong: $(calls)"
[[ "$(calls)" == *"sync-harnesses"* ]] || fail "config change did not re-run sync-harnesses: $(calls)"

# 3b. All three repos behind at once: one run catches up all. A git shim in
#     front of fetch holds each fetch until all three have started, so serial
#     fetches (the old behavior) cannot pass — the barrier times out instead.
mkdir -p "$tmp/fbin" "$tmp/fetchbar"
real_git=$(command -v git)
cat > "$tmp/fbin/git" <<EOF
#!/bin/sh
case "\$*" in
  *fetch*)
    echo start >> "\$FETCH_BARRIER/started"
    i=0
    while [ "\$(wc -l < "\$FETCH_BARRIER/started")" -lt 3 ] && [ "\$i" -lt 200 ]; do
        sleep 0.05; i=\$((i + 1))
    done
    [ "\$i" -lt 200 ] || echo serial >> "\$FETCH_BARRIER/serial"
    ;;
esac
exec $real_git "\$@"
EOF
chmod +x "$tmp/fbin/git"
upstream dot file multi1
upstream cfg skills.md multi2
upstream capi bun.lock multi3
: >| "$STUB_LOG"
out=$(FETCH_BARRIER="$tmp/fetchbar" PATH="$tmp/fbin:$PATH" zsh "$repo/scripts/fleet-sync.zsh" 2>&1); rc=$?
[[ $rc -eq 0 ]] || fail "multi fast-forward run rc=$rc: $out"
[[ "$(head_of dot)" == "$(up_head dot)" && "$(head_of cfg)" == "$(up_head cfg)" && "$(head_of capi)" == "$(up_head capi)" ]] || fail "multi fast-forward incomplete: $out"
[[ "$(wc -l < "$tmp/fetchbar/started")" -eq 3 ]] || fail "expected 3 fetches, got $(wc -l < "$tmp/fetchbar/started")"
[[ ! -f "$tmp/fetchbar/serial" ]] || fail "fetches ran serially: barrier timed out waiting for all three"

# 3c. Failed sync-harnesses refresh: stamp dropped, so the next run retries
#     even without a new pull (the gate must not swallow the retry)
print -r -- $'#!/bin/sh\necho "sync-harnesses $*" >> "$STUB_LOG"\nexit 3' > "$tmp/cfg/skills/skills-compress/scripts/sync-harnesses.sh"
chmod +x "$tmp/cfg/skills/skills-compress/scripts/sync-harnesses.sh"
upstream dot file retry1
if run; then fail "failed sync-harnesses run passed: $out"; fi
[[ "$out" == *"codex hooks: sync-harnesses failed"* ]] || fail "sync-harnesses failure not reported: $out"
[[ ! -f "$XDG_STATE_HOME/fleet-sync/harnesses-synced" ]] || fail "stamp survived a failed refresh"
print -r -- $'#!/bin/sh\necho "sync-harnesses $*" >> "$STUB_LOG"' > "$tmp/cfg/skills/skills-compress/scripts/sync-harnesses.sh"
chmod +x "$tmp/cfg/skills/skills-compress/scripts/sync-harnesses.sh"
run || fail "retry run rc=$rc: $out"
[[ "$(calls)" == *"sync-harnesses"* ]] || fail "failed refresh not retried without a new pull: $(calls)"
[[ -f "$XDG_STATE_HOME/fleet-sync/harnesses-synced" ]] || fail "stamp not written after the successful retry"

# 4. copilot-api moved with bun.lock: dependencies reinstalled; gateway not running
# (a stray gateway from an earlier failed suite run would be adopted and break
# the silence assert below — the case-9 pkill is too late for this case)
pkill -f "gw.py $COPILOT_API_PORT" 2>/dev/null || true
for i in {1..20}; do [[ -z "$(lsof -ti "tcp:$COPILOT_API_PORT" -sTCP:LISTEN 2>/dev/null)" ]] && break; sleep 0.5; done
upstream capi bun.lock lock2
run || fail "copilot run rc=$rc: $out"
[[ "$(head_of capi)" == "$(up_head capi)" ]] || fail "copilot-api not fast-forwarded"
[[ "$(calls)" == *"bun install --cwd $tmp/capi --frozen-lockfile"* ]] || fail "bun install not run: $(calls)"
[[ "$out" != *"copilot (:"* ]] || fail "a gateway that is not running should be silently left alone: $out"
upstream capi README notes
run || fail "copilot no-lock run rc=$rc"
[[ "$(calls)" != *"bun install"* ]] || fail "bun install ran without a lockfile change"

# 5. Uncommitted change + upstream ahead: skipped, nothing lost, exit 1
upstream dot zshrc remote-edit
print -r -- local-edit > "$tmp/dot/file"
local before_head; before_head=$(head_of dot)
if run; then fail "dirty repo passed: $out"; fi
[[ "$out" == *"dotfiles: uncommitted changes; skipped (1 upstream commit(s) waiting)"* ]] || fail "dirty not reported: $out"
[[ -s "$XDG_STATE_HOME/fleet-sync/drift-dotfiles" ]] || fail "no drift marker for the skipped dirty repo"
[[ "$(head_of dot)" == "$before_head" && "$(<"$tmp/dot/file")" == local-edit ]] || fail "dirty repo was touched"
git -C "$tmp/dot" checkout -q -- file

# 6. --dry-run: reports, does not move
run --dry-run || fail "dry run rc=$rc: $out"
[[ "$out" == *"dotfiles: would fast-forward 1 commit(s)"* && "$(head_of dot)" == "$before_head" ]] || fail "dry run moved or misreported: $out"
run || fail "catch-up run rc=$rc"
[[ "$(head_of dot)" == "$(up_head dot)" ]] || fail "dotfiles not fast-forwarded after cleanup"

# 7. Local commit only: warned, still exit 0
print -r -- mine > "$tmp/cfg/mine"
$G -C "$tmp/cfg" add mine && $G -C "$tmp/cfg" commit -qm mine
run || fail "unpushed-only run rc=$rc: $out"
[[ "$out" == *"claude-config: 1 commit(s) not pushed"* ]] || fail "unpushed commit not reported: $out"

# 8. Diverged: skipped, exit 1, local commit kept
upstream cfg other-change x
if run; then fail "diverged repo passed: $out"; fi
[[ "$out" == *"claude-config: diverged"* ]] || fail "divergence not reported: $out"
[[ -f "$tmp/cfg/mine" ]] || fail "local commit lost"

git -C "$tmp/cfg" reset -q --hard origin/main   # clear case 8

# 8b. Current with upstream but holding an uncommitted edit: told to commit and
# push (the other machines cannot see it), exit 0, edit kept
print -r -- local-edit > "$tmp/cfg/file"
run || fail "dirty-only run rc=$rc: $out"
[[ "$out" == *"claude-config: 1 file(s) with uncommitted changes; commit and push"* ]] || fail "uncommitted work not reported: $out"
[[ -s "$XDG_STATE_HOME/fleet-sync/drift-claude-config" ]] || fail "no drift marker for dirty-in-step repo"
[[ "$out" != *"claude-config: up to date"* && "$(<"$tmp/cfg/file")" == local-edit ]] || fail "dirty-only run misreported or touched the edit: $out"
git -C "$tmp/cfg" checkout -q -- file

# 9. copilot-api is a proxy like the others now: a healthy stub gateway is
# adopted (up to date), a stale one that is busy gets the idle watcher, and the
# watcher restarts it for real once the request finishes. The stub bun spawns
# the stub gateway when asked to run the gateway source.
cat > "$tmp/gw.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"data":[]}'
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
export GW_STUB="$tmp/gw.py"
# a stray gateway from an earlier failed run would be adopted and break the
# case-4 silence assert below; clear the port first
pkill -f "gw.py $COPILOT_API_PORT" 2>/dev/null || true
for i in {1..20}; do [[ -z "$(lsof -ti "tcp:$COPILOT_API_PORT" -sTCP:LISTEN 2>/dev/null)" ]] && break; sleep 0.5; done
print -r -- $'#!/bin/sh\necho "bun $*" >> "$STUB_LOG"\ncase "$*" in *src/main.ts*) nohup python3 "$GW_STUB" "$COPILOT_API_PORT" >/dev/null 2>&1 & ;; esac\nexit 0' > "$HOME/.bun/bin/bun"
chmod +x "$HOME/.bun/bin/bun"
export PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"   # so the launcher picks the stub bun
python3 "$GW_STUB" "$COPILOT_API_PORT" >/dev/null 2>&1 &
gw=$!
for i in {1..50}; do curl -sf -o /dev/null "http://127.0.0.1:$COPILOT_API_PORT/v1/models" && break; sleep 0.1; done
upstream capi src change-1
run || fail "adopt run rc=$rc: $out"
[[ "$out" == *"copilot (:$COPILOT_API_PORT) up to date"* ]] || fail "healthy gateway not adopted: $out"
kill -0 $gw 2>/dev/null || fail "adopted gateway was touched: $out"
# now make it stale (recorded fingerprint != what a launch would start) and busy
print -r -- wrong-fp >| "${XDG_STATE_HOME}/claude-copilot-api.fingerprint"
python3 -c "import socket,time; s=socket.create_connection(('127.0.0.1',$COPILOT_API_PORT)); s.send(b'GET / HTTP/1.1\r\n'); time.sleep(30)" &
client=$!
sleep 1
upstream capi src change-2
run || fail "busy gateway run rc=$rc: $out"
[[ "$out" == *"copilot (:$COPILOT_API_PORT) changed; serving a request, watcher started"* ]] || fail "busy stale gateway did not get a watcher: $out"
kill -0 $gw 2>/dev/null || fail "busy gateway was cut off: $out"
watch_log="$XDG_STATE_HOME/llm-proxy-sync/watch-copilot.log"
kill $client 2>/dev/null; wait $client 2>/dev/null || true
watched=0
for i in {1..120}; do
    grep -q "restarted with the current code" "$watch_log" 2>/dev/null && { watched=1; break; }
    sleep 1
done
(( watched )) || fail "watcher did not restart the gateway once idle: $(tail -3 "$watch_log" 2>/dev/null)"
kill -0 $gw 2>/dev/null && fail "old gateway still alive after the watcher restart"
curl -sf -o /dev/null "http://127.0.0.1:$COPILOT_API_PORT/v1/models" || fail "no gateway listening after the watcher restart"
run || fail "post-restart run rc=$rc: $out"
[[ "$out" == *"copilot (:$COPILOT_API_PORT) up to date"* ]] || fail "restarted gateway not current: $out"
# the spawned gateway shows its resolved interpreter in ps, so match the script path
pkill -f "$GW_STUB" 2>/dev/null || true; sleep 0.5; wait $gw 2>/dev/null || true

# 10. LLM proxies: the step is wired in and --help documents it; with nothing
# listening on the (isolated) proxy ports it is silent and changes nothing
[[ "$(<"$repo/scripts/fleet-sync.zsh")" == *'llm-proxy-sync $args'* ]] || fail "proxy sync step not wired into fleet-sync"
run --help || fail "--help rc=$rc"
[[ "$out" == *"LLM proxies"* && "$out" == *"restarted when idle"* ]] || fail "--help does not describe the proxy step: $out"
# the case-9 gateway left a fresh up-marker; a recorded always-on proxy whose
# listener is gone is restarted (audit: a dead proxy was invisible before)
run || fail "run with a fresh up-marker rc=$rc: $out"
[[ "$out" == *"copilot (:$COPILOT_API_PORT) was up last sync, listener gone; restarted"* ]] || fail "recorded dead proxy not restarted: $out"
curl -sf -o /dev/null "http://127.0.0.1:$COPILOT_API_PORT/v1/models" || fail "marker restart left no gateway"
pkill -f "$GW_STUB" 2>/dev/null || true; sleep 0.5
rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/llm-proxy-sync/up-copilot"
run || fail "run with no proxies rc=$rc: $out"
[[ "$out" != *"== "* ]] || fail "proxy sync spoke with nothing listening: $out"
# a marker older than 25 h is a deliberate stop that aged out: left alone
mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/llm-proxy-sync"
print -r -- "$COPILOT_API_PORT" > "${XDG_STATE_HOME:-$HOME/.local/state}/llm-proxy-sync/up-copilot"
touch -t 202001010000 "${XDG_STATE_HOME:-$HOME/.local/state}/llm-proxy-sync/up-copilot"
run --dry-run || fail "dry run with a stale marker rc=$rc: $out"
[[ "$out" != *"was up last sync"* ]] || fail "stale marker restarted a deliberately stopped proxy: $out"
run --dry-run || fail "dry run with no proxies rc=$rc: $out"
[[ "$out" != *"== "* ]] || fail "proxy sync (dry run) spoke with nothing listening: $out"

print -r -- "ok fleet-sync"
