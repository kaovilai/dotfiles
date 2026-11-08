#!/bin/zsh
# Offline tests for scripts/context-mode-daemon-sync.zsh: a throwaway HOME, a
# fake plugin cache with a daemon.mjs, stub node/claude/systemctl binaries that
# log their arguments, and the three decisions the script makes (node lookup,
# unit currency, registration presence). No real daemon, no network.
emulate -LR zsh
setopt err_exit pipe_fail
local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { print -ru2 -- "FAIL: $*"; exit 1; }

export HOME="$tmp/home"
mkdir -p "$HOME/bin" "$HOME/.claude/plugins/cache/context-mode/context-mode/2.2.1"

# stub node: prints a pinned version, logs its invocation
cat > "$HOME/bin/node" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then echo "${NODE_STUB_VERSION:-v24.15.0}"; exit 0; fi
echo "node $*" >> "$NODE_LOG"
STUB
chmod +x "$HOME/bin/node"

# stub claude: logs the mcp subcommand; `mcp get context-mode` exits 1 unless
# CLAUDE_STUB_HAS_CONTEXT_MODE says the entry exists
cat > "$HOME/bin/claude" <<'STUB'
#!/bin/sh
echo "claude $*" >> "$CLAUDE_LOG"
if [ "$1" = "mcp" ] && [ "$2" = "get" ]; then
    if [ "$3" = "context-mode" ] && [ "${CLAUDE_STUB_HAS_CONTEXT_MODE:-}" = 1 ]; then
        echo "context-mode:"
        echo "  Scope: User config (available in all your projects)"
        echo "  URL: http://127.0.0.1:8790/mcp"
        exit 0
    fi
    exit 1
fi
exit 0
STUB
chmod +x "$HOME/bin/claude"

# stub systemctl: unit state from files the test controls
cat > "$HOME/bin/systemctl" <<'STUB'
#!/bin/sh
echo "systemctl $*" >> "$SYSTEMCTL_LOG"
case "$1 $2" in
    "--user list-units") exit 0 ;;
    "--user is-active") [ "${UNIT_STUB_ACTIVE:-}" = 1 ] && exit 0; exit 3 ;;
esac
exit 0
STUB
chmod +x "$HOME/bin/systemctl"

# uname stub: the suite must be platform-independent — on macOS the real uname
# would route the unit step into launchd and touch the host's agents
cat > "$HOME/bin/uname" <<'STUB'
#!/bin/sh
[ "$1" = "-m" ] && echo x86_64 || echo Linux
STUB
chmod +x "$HOME/bin/uname"
# brew stub: a host with a real node@24 under brew would satisfy the node
# lookup and break the no-compatible-node cases; point it at nothing
cat > "$HOME/bin/brew" <<'STUB'
#!/bin/sh
echo "$CM_TEST_FAKE_BREW_PREFIX"
STUB
chmod +x "$HOME/bin/brew"
export CM_TEST_FAKE_BREW_PREFIX="$tmp/no-brew"
# -f on every invocation: a plain zsh sources ~/.zshenv, whose shell env can
# rebuild PATH (vite-plus does, nondeterministically from this harness's view)
# and drop the stub directory — one run then fetched the real nodejs.org
# tarball. -f starts the child with no rc files; the script's own PATH
# save/restore covers what it sources itself.
export PATH="$HOME/bin:$PATH" NODE_LOG="$tmp/node.log" CLAUDE_LOG="$tmp/claude.log" SYSTEMCTL_LOG="$tmp/systemctl.log"
export CLAUDE_PROVIDER_NATIVE_BINARY="$HOME/bin/claude"
: >| "$NODE_LOG"; : >| "$CLAUDE_LOG"; : >| "$SYSTEMCTL_LOG"

unit="$HOME/.config/systemd/user/context-mode-daemon.service"
daemon="$HOME/.claude/plugins/cache/context-mode/context-mode/2.2.1/daemon.mjs"
print -r -- '# stub bundle' > "$daemon"
typeset -a args=(--quiet)

# --- 1. no daemon bundle in the cache: a clean skip ---------------------------------
rm -rf "$HOME/.claude/plugins/cache/context-mode/context-mode/2.2.1"
zsh -f "$repo/scripts/context-mode-daemon-sync.zsh" "${args[@]}" || fail "no-cache run must exit 0"
[[ ! -s "$NODE_LOG" ]] || fail "no-cache run must not invoke node"
mkdir -p "$HOME/.claude/plugins/cache/context-mode/context-mode/2.2.1"
print -r -- '# stub bundle' > "$daemon"

# --- 2. node too old, autoinstall off: the daemon step is skipped, not failed ----------
export NODE_STUB_VERSION=v22.23.1 CONTEXT_MODE_DAEMON_NODE_AUTOINSTALL=0
zsh -f "$repo/scripts/context-mode-daemon-sync.zsh" "${args[@]}" || fail "old-node run must exit 0"
[[ ! -s "$NODE_LOG" ]] || fail "old-node run must not invoke the daemon"
unset CONTEXT_MODE_DAEMON_NODE_AUTOINSTALL
export NODE_STUB_VERSION=v24.15.0

# --- 2b. no node at all: the official tarball is fetched, verified and extracted -------
# (curl is stubbed to serve a fixture tarball + its real sha; tar and the sha
# checker run for real, so the extraction and verification paths are live)
rm -rf "$HOME/.local/lib"
typeset fixture="$tmp/nodefixture"
typeset fdir="$fixture/node-v24.15.0-linux-x64"
mkdir -p "$fdir/bin"
print -r -- '#!/bin/sh
[ "$1" = "--version" ] && { echo v24.15.0; exit 0; }
echo "node $*" >> "$NODE_LOG"' >| "$fdir/bin/node"
chmod +x "$fdir/bin/node"
tar -cJf "$fixture/node-v24.15.0-linux-x64.tar.xz" -C "$fixture" node-v24.15.0-linux-x64
typeset fsha
if command -v shasum >/dev/null 2>&1; then
    fsha=$(shasum -a 256 "$fixture/node-v24.15.0-linux-x64.tar.xz" | awk '{print $1}')
else
    fsha=$(sha256sum "$fixture/node-v24.15.0-linux-x64.tar.xz" | awk '{print $1}')
fi
cat > "$HOME/bin/node" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then echo "${NODE_STUB_VERSION:-v24.15.0}"; exit 0; fi
echo "node $*" >> "$NODE_LOG"
STUB
chmod +x "$HOME/bin/node"
cat > "$HOME/bin/curl" <<'STUB'
#!/bin/sh
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -fsSL) shift ;;
        *) url="$1"; shift ;;
    esac
done
case "$url" in
    *SHASUMS256.txt*) echo "$CM_TEST_SHA  node-v24.15.0-linux-x64.tar.xz" ;;
    *) cp "$CM_TEST_FIXTURE/node-v24.15.0-linux-x64.tar.xz" "$out" ;;
esac
STUB
chmod +x "$HOME/bin/curl"
export CM_TEST_SHA="$fsha" CM_TEST_FIXTURE="$fixture"
rehash   # the sourced shell env may have hashed curl/node from the real PATH; the stubs must win
export NODE_STUB_VERSION=v18.0.0   # PATH node is useless; the tarball must win
zsh -f "$repo/scripts/context-mode-daemon-sync.zsh" "${args[@]}" || fail "autoinstall run must exit 0"
[[ -x "$HOME/.local/lib/node-v24.15.0-linux-x64/bin/node" ]] || fail "the tarball must be extracted to ~/.local/lib"
export NODE_STUB_VERSION=v24.15.0
# the curl stub stays installed: later cases (the bad-checksum run) vary
# CM_TEST_SHA instead, and without the stub the real curl would fetch
# nodejs.org from inside the offline suite

# --- 3. everything current: no unit install, no registration add ---------------------
: >| "$NODE_LOG"; : >| "$CLAUDE_LOG"
mkdir -p "${unit:h}"
print -r -- "ExecStart=\"$daemon\"\nEnvironment=\"CONTEXT_MODE_DAEMON_PORT=8790\"" >| "$unit"
export UNIT_STUB_ACTIVE=1 CLAUDE_STUB_HAS_CONTEXT_MODE=1
zsh -f "$repo/scripts/context-mode-daemon-sync.zsh" "${args[@]}" || fail "current run must exit 0"
grep -q -- "--install" "$NODE_LOG" && fail "current unit must not be reinstalled"
grep -q -- "mcp add" "$CLAUDE_LOG" && fail "current registration must not be re-added"

# --- 4. a stale unit path: the install is re-run --------------------------------------
print -r -- "ExecStart=\"/old/path/2.2.0/daemon.mjs\"" >| "$unit"
: >| "$NODE_LOG"
zsh -f "$repo/scripts/context-mode-daemon-sync.zsh" "${args[@]}" || fail "stale-unit run must exit 0"
grep -q -- "$daemon --install" "$NODE_LOG" || fail "a stale unit must be reinstalled against the current bundle"

# --- 5. no registration: the add runs with user scope and the daemon URL --------------
unset CLAUDE_STUB_HAS_CONTEXT_MODE
export UNIT_STUB_ACTIVE=1
: >| "$CLAUDE_LOG"
zsh -f "$repo/scripts/context-mode-daemon-sync.zsh" "${args[@]}" || fail "no-registration run must exit 0"
grep -q -- "mcp add --scope user --transport http context-mode http://127.0.0.1:8790/mcp" "$CLAUDE_LOG" || fail "the registration must be added at user scope with the daemon URL"

# --- 6. a foreign registration with the same name: left alone with a warning -----------
export CLAUDE_STUB_HAS_CONTEXT_MODE=1
cat > "$HOME/bin/claude" <<'STUB'
#!/bin/sh
echo "claude $*" >> "$CLAUDE_LOG"
if [ "$1" = "mcp" ] && [ "$2" = "get" ]; then
    if [ "$3" = "context-mode" ]; then
        echo "context-mode:"
        echo "  Scope: User config (available in all your projects)"
        echo "  URL: http://elsewhere.example/mcp"
        exit 0
    fi
    exit 1
fi
exit 0
STUB
chmod +x "$HOME/bin/claude"
: >| "$CLAUDE_LOG"
zsh -f "$repo/scripts/context-mode-daemon-sync.zsh" "${args[@]}" || fail "foreign-registration run must exit 0"
grep -q -- "mcp add" "$CLAUDE_LOG" && fail "a foreign registration must be left alone"

# --- 7. numeric orderings: 2.2.10 beats 2.2.9; node 24.14 is not 24.15 -----------------
mkdir -p "$HOME/.claude/plugins/cache/context-mode/context-mode/2.2.9" "$HOME/.claude/plugins/cache/context-mode/context-mode/2.2.10"
print -r -- '# stub bundle' >| "$HOME/.claude/plugins/cache/context-mode/context-mode/2.2.9/daemon.mjs"
print -r -- '# stub bundle' >| "$HOME/.claude/plugins/cache/context-mode/context-mode/2.2.10/daemon.mjs"
: >| "$NODE_LOG"
zsh -f "$repo/scripts/context-mode-daemon-sync.zsh" "${args[@]}" || fail "version-order run must exit 0"
grep -q "context-mode/context-mode/2.2.10/daemon.mjs --install" "$NODE_LOG" || fail "2.2.10 must win over 2.2.9 (lexicographic sorts them backwards)"
export NODE_STUB_VERSION=v24.14.0 CONTEXT_MODE_DAEMON_NODE_AUTOINSTALL=0
rm -rf "$HOME/.local/lib"   # 2b's extracted node would (correctly) satisfy the lookup
: >| "$NODE_LOG"
zsh -f "$repo/scripts/context-mode-daemon-sync.zsh" "${args[@]}" || fail "node-24.14 run must exit 0"
[[ ! -s "$NODE_LOG" ]] || fail "node 24.14 is below the daemon's 24.15 minimum and must not be used"
export NODE_STUB_VERSION=v24.15.0
unset CONTEXT_MODE_DAEMON_NODE_AUTOINSTALL

# --- 8. a mismatched checksum: no extraction, no use -------------------------------
rm -rf "$HOME/.local/lib"
export CM_TEST_SHA="0000000000000000000000000000000000000000000000000000000000000000"
export NODE_STUB_VERSION=v18.0.0
zsh -f "$repo/scripts/context-mode-daemon-sync.zsh" "${args[@]}" || fail "bad-checksum run must exit 0"
[[ ! -d "$HOME/.local/lib/node-v24.15.0-linux-x64" ]] || fail "a mismatched checksum must not extract"
export NODE_STUB_VERSION=v24.15.0

# --- 9. our registration on another port is re-pointed -------------------------------
cat > "$HOME/bin/claude" <<'STUB'
#!/bin/sh
echo "claude $*" >> "$CLAUDE_LOG"
if [ "$1" = "mcp" ] && [ "$2" = "get" ]; then
    echo "context-mode:"
    echo "  Scope: User config (available in all your projects)"
    echo "  URL: http://127.0.0.1:8791/mcp"
    echo "  Status: ✔ Connected"
    echo ""
    echo "To remove this server, run: claude mcp remove context-mode -s user"
    exit 0
fi
exit 0
STUB
chmod +x "$HOME/bin/claude"
: >| "$CLAUDE_LOG"
zsh -f "$repo/scripts/context-mode-daemon-sync.zsh" "${args[@]}" || fail "port-move run must exit 0"
grep -q -- "mcp remove context-mode" "$CLAUDE_LOG" || fail "an entry on our old port must be removed"
grep -q -- "mcp add --scope user --transport http context-mode http://127.0.0.1:8790/mcp" "$CLAUDE_LOG" || fail "the registration must be re-added at the current port"

# --- 10. a foreign path on our host is not ours; a project-scoped entry is not moved ----
# restore a usable node: case 8 left none installed and a poisoned digest
export NODE_STUB_VERSION=v24.15.0
cat > "$HOME/bin/node" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then echo "${NODE_STUB_VERSION:-v24.15.0}"; exit 0; fi
echo "node $*" >> "$NODE_LOG"
STUB
chmod +x "$HOME/bin/node"
for scope_url in "User config|http://127.0.0.1:8791/mcp-other" "User config|http://127.0.0.1:8791/other/mcp" "Local config|http://127.0.0.1:8791/mcp"; do
    got_scope="${scope_url%%|*}"
    got_url="${scope_url#*|}"
    cat > "$HOME/bin/claude" <<STUB
#!/bin/sh
echo "claude \$*" >> "\$CLAUDE_LOG"
if [ "\$1" = "mcp" ] && [ "\$2" = "get" ]; then
    echo "context-mode:"
    echo "  Scope: ${got_scope}"
    echo "  URL: ${got_url}"
    exit 0
fi
exit 0
STUB
    chmod +x "$HOME/bin/claude"
    : >| "$CLAUDE_LOG"
    zsh -f "$repo/scripts/context-mode-daemon-sync.zsh" "${args[@]}" || fail "no-move run ($got_scope $got_url) must exit 0"
    if [[ "$got_scope" == "User config" ]]; then
        # a foreign path at user scope: a warning, never a remove
        grep -q -- "mcp remove" "$CLAUDE_LOG" && fail "a foreign path must not be removed"
    else
        # a project/local entry with our URL: not moved, only the user-scope add runs
        grep -q -- "mcp remove" "$CLAUDE_LOG" && fail "a non-user-scoped entry must not be removed"
        grep -q -- "mcp add --scope user" "$CLAUDE_LOG" || fail "the user-scope registration must still be added"
    fi
done

print -- "PASS: context-mode-daemon-sync (skip, node gate, autoinstall, current, stale unit, add, foreign, numeric orderings, bad checksum, port move, scope+path guards)"
