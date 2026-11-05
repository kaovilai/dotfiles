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
# The LiteLLM proxies fleet-sync may restart: point them at ports nothing uses so a
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

# 2. In sync, stamp fresh: nothing to do, no plugin calls
run || fail "second run rc=$rc: $out"
local idle_calls; idle_calls=$(calls | grep -v '^sync-harnesses ' || true)
[[ -z "$idle_calls" ]] || fail "idle run touched plugins: $idle_calls"

# 3. Claude config moved upstream: fast-forward, plugin sync without --update
upstream cfg skills.md new-skill
run || fail "config run rc=$rc: $out"
[[ "$(head_of cfg)" == "$(up_head cfg)" ]] || fail "config not fast-forwarded"
[[ "$(calls)" == *"plugin install x@m"* && "$(calls)" != *"marketplace update"* ]] || fail "config change plugin pass wrong: $(calls)"

# 4. copilot-api moved with bun.lock: dependencies reinstalled; gateway not running
upstream capi bun.lock lock2
run || fail "copilot run rc=$rc: $out"
[[ "$(head_of capi)" == "$(up_head capi)" ]] || fail "copilot-api not fast-forwarded"
[[ "$(calls)" == *"bun install --cwd $tmp/capi --frozen-lockfile"* ]] || fail "bun install not run: $(calls)"
[[ "$out" == *"gateway not running"* ]] || fail "gateway state not reported: $out"
upstream capi README notes
run || fail "copilot no-lock run rc=$rc"
[[ "$(calls)" != *"bun install"* ]] || fail "bun install ran without a lockfile change"

# 5. Uncommitted change + upstream ahead: skipped, nothing lost, exit 1
upstream dot zshrc remote-edit
print -r -- local-edit > "$tmp/dot/file"
local before_head; before_head=$(head_of dot)
if run; then fail "dirty repo passed: $out"; fi
[[ "$out" == *"dotfiles: uncommitted changes; skipped (1 upstream commit(s) waiting)"* ]] || fail "dirty not reported: $out"
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
[[ "$out" != *"claude-config: up to date"* && "$(<"$tmp/cfg/file")" == local-edit ]] || fail "dirty-only run misreported or touched the edit: $out"
git -C "$tmp/cfg" checkout -q -- file

# 9. copilot-api moved while a gateway listens: busy -> left running; idle -> stopped
python3 -m http.server "$COPILOT_API_PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
gw=$!
for i in {1..50}; do curl -s -o /dev/null "http://127.0.0.1:$COPILOT_API_PORT/" && break; sleep 0.1; done
# a request in flight: connected, headers not finished
python3 -c "import socket,time; s=socket.create_connection(('127.0.0.1',$COPILOT_API_PORT)); s.send(b'GET / HTTP/1.1\r\n'); time.sleep(6)" &
client=$!
sleep 1
upstream capi src change-1
run || fail "busy gateway run rc=$rc: $out"
[[ "$out" == *"gateway is serving a request"* ]] && kill -0 $gw 2>/dev/null || fail "busy gateway not left alone: $out"
kill $client 2>/dev/null; wait $client 2>/dev/null || true
sleep 1
upstream capi src change-2
run || fail "idle gateway run rc=$rc: $out"
[[ "$out" == *"gateway stopped"* ]] || fail "idle gateway not stopped: $out"
sleep 1
if kill -0 $gw 2>/dev/null; then kill $gw; fail "gateway process still alive"; fi
wait $gw 2>/dev/null || true

# 10. LiteLLM proxies: the step is wired in and --help documents it; with nothing
# listening on the (isolated) proxy ports it is silent and changes nothing
[[ "$(<"$repo/scripts/fleet-sync.zsh")" == *'llm-proxy-sync $args'* ]] || fail "proxy sync step not wired into fleet-sync"
run --help || fail "--help rc=$rc"
[[ "$out" == *"LiteLLM proxies"* && "$out" == *"restarted when idle"* ]] || fail "--help does not describe the proxy step: $out"
run || fail "run with no proxies rc=$rc: $out"
[[ "$out" != *"== "* ]] || fail "proxy sync spoke with nothing listening: $out"
run --dry-run || fail "dry run with no proxies rc=$rc: $out"
[[ "$out" != *"== "* ]] || fail "proxy sync (dry run) spoke with nothing listening: $out"

print -r -- "ok fleet-sync"
