#!/bin/zsh
# Offline tests for the t3-triage function (zsh/util.zsh): throwaway HOME with
# a stub shim and a stub npx that reports how `claude` resolves. Never touches
# the real ~/.local/share/t3-triage or the network.
emulate -LR zsh
setopt err_exit pipe_fail
local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { print -ru2 -- "FAIL: $*"; exit 1; }
# rc capture must not trip err_exit: `|| rc=$?` keeps failure in condition
# context. err goes to a file so stdout stays comparable.
rc=0
try() { rc=0; ( cd "$1" && t3-triage ) >"$tmp/out" 2>"$tmp/err" || rc=$? }

export HOME="$tmp/home"
mkdir -p "$HOME/.local/share/t3-triage" "$tmp/bin" "$tmp/work/clean"

# Stub shim: the dedicated claude the function must put first on PATH.
print -r -- $'#!/bin/sh\necho "shim $@"' > "$HOME/.local/share/t3-triage/claude"
chmod +x "$HOME/.local/share/t3-triage/claude"

# Stub npx: reports the claude it would launch plus the args it got.
print -r -- '#!/bin/sh
echo "npx claude=$(command -v claude 2>/dev/null || echo none) args=$*"' > "$tmp/bin/npx"
chmod +x "$tmp/bin/npx"
export PATH="$tmp/bin:$PATH"

source "$repo/zsh/util.zsh"

# Happy path: shim first on PATH (inside npx only), args pass through.
try "$tmp/work/clean"
[[ $rc -eq 0 ]] || fail "happy path failed (rc=$rc, err: $(cat "$tmp/err"))"
[[ "$(cat "$tmp/out")" == "npx claude=$HOME/.local/share/t3-triage/claude args=t3 triage --agent claude" ]] \
    || fail "happy path wrong: $(cat "$tmp/out")"

# Missing shim: warn on stderr, still run (falls back to claude-dispatch).
mv "$HOME/.local/share/t3-triage/claude" "$tmp/shim.bak"
try "$tmp/work/clean"
[[ $rc -eq 0 ]] || fail "missing shim should not be fatal (rc=$rc)"
grep -q "missing or not executable" "$tmp/err" || fail "missing shim did not warn"
mv "$tmp/shim.bak" "$HOME/.local/share/t3-triage/claude"

# Shadow fixtures: a project whose node_modules/.bin holds a claude.
mkdir -p "$tmp/work/proj/node_modules/.bin" "$tmp/work/proj/src"
print -r -- $'#!/bin/sh\necho fake' > "$tmp/work/proj/node_modules/.bin/claude"
chmod +x "$tmp/work/proj/node_modules/.bin/claude"

# Direct cwd shadow: fatal, message names the path.
try "$tmp/work/proj"
[[ $rc -eq 1 ]] || fail "direct shadow not fatal (rc=$rc)"
grep -q "$tmp/work/proj/node_modules/.bin/claude shadows" "$tmp/err" || fail "direct shadow message wrong"

# Ancestor shadow from a subdirectory: same fatal path.
try "$tmp/work/proj/src"
[[ $rc -eq 1 ]] || fail "ancestor shadow not fatal (rc=$rc)"
grep -q "$tmp/work/proj/node_modules/.bin/claude shadows" "$tmp/err" || fail "ancestor shadow message wrong"

# Symlinked entry: walk follows the physical path, still fatal.
ln -sfn "$tmp/work/proj/src" "$tmp/link-src"
try "$tmp/link-src"
[[ $rc -eq 1 ]] || fail "symlink entry bypassed the guard (rc=$rc)"
grep -q "shadows the shim" "$tmp/err" || fail "symlink entry message wrong"

# Logical-only ancestor (shadow beside the symlink, not the target) must NOT
# block: npm resolves cwd physically, so that bin dir is never prepended.
mkdir -p "$tmp/logical-anc/node_modules/.bin"
print -r -- $'#!/bin/sh\necho fake' > "$tmp/logical-anc/node_modules/.bin/claude"
chmod +x "$tmp/logical-anc/node_modules/.bin/claude"
ln -sfn "$tmp/work/clean" "$tmp/logical-anc/link-clean"
try "$tmp/logical-anc/link-clean"
[[ $rc -eq 0 ]] || fail "logical-only ancestor must not block (rc=$rc, err: $(cat "$tmp/err"))"

print -r -- "t3-triage: all tests passed"
