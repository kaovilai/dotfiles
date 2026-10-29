#!/bin/zsh
# Offline tests for the proxy hash and port helpers in
# zsh/functions/claude/common.zsh on hosts without macOS's tools: Fedora has
# sha256sum but no shasum, and ss but no lsof. Each case runs with PATH
# limited to a temp dir of real or stub tools.
emulate -LR zsh
setopt err_exit pipe_fail
local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
source "$repo/zsh/functions/claude/common.zsh"

fail() { print -ru2 -- "FAIL: $*"; exit 1; }
local abc=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
local t d out

# bindir <name> <tool...>: a directory holding the coreutils the helpers pipe
# through plus the named tools, each resolved from the current PATH.
bindir() {
    local dir="$tmp/$1" x; shift
    mkdir -p "$dir"
    for x in cut grep sort "$@"; do ln -sf "${commands[$x]}" "$dir/$x"; done
    print -r -- "$dir"
}

# Both hash tools give the same fingerprint, so a host switching between them
# does not restart its proxies.
local fp_seen=""
for t in sha256sum shasum; do
    (( $+commands[$t] )) || { print -r -- "skip: $t not installed"; continue; }
    d=$(bindir "hash-$t" "$t")
    out=$(path=("$d"); print -rn abc | _claude_sha256)
    [[ "$out" == "$abc" ]] || fail "_claude_sha256 via $t gave '$out'"
    out=$(path=("$d"); _claude_proxy_fp a b)
    [[ ${#out} == 64 ]] || fail "_claude_proxy_fp via $t gave '$out'"
    [[ -z "$fp_seen" || "$out" == "$fp_seen" ]] || fail "_claude_proxy_fp differs between tools"
    fp_seen=$out
done

# Stubs: ss -H output for a listener (pid in the users: column) and for an
# established connection; lsof prints pids itself.
mkdir -p "$tmp/stubs"
cat > "$tmp/stubs/ss" <<'EOF'
#!/bin/sh
case "$*" in
    *-Hltnp*) [ -n "$SS_LISTEN" ] && echo "LISTEN 0 511 *:4141 *:* users:((\"bun\",pid=4242,fd=13),(\"bun\",pid=4242,fd=14))" ;;
    *established*) [ -n "$SS_ESTAB" ] && echo "0 0 [::1]:4141 [::1]:51234" ;;
esac
exit 0
EOF
print -r -- $'#!/bin/sh\necho 777' > "$tmp/stubs/lsof"
chmod +x "$tmp/stubs/ss" "$tmp/stubs/lsof"

d=$(bindir ss-only)
ln -sf "$tmp/stubs/ss" "$d/ss"
out=$(path=("$d"); SS_LISTEN=1 _claude_listen_pids 4141)
[[ "$out" == 4242 ]] || fail "ss listener pid: '$out'"
# No match exits non-zero, like lsof; only the empty output matters.
out=$(path=("$d"); _claude_listen_pids 4141) || true
[[ -z "$out" ]] || fail "ss with no listener gave '$out'"
(path=("$d"); SS_ESTAB=1 _claude_port_serving 4141) || fail "ss established connection not seen"
if (path=("$d"); _claude_port_serving 4141); then fail "idle port reported as serving"; fi

# lsof wins when both are installed (the macOS path stays unchanged)
ln -sf "$tmp/stubs/lsof" "$d/lsof"
out=$(path=("$d"); SS_LISTEN=1 _claude_listen_pids 4141)
[[ "$out" == 777 ]] || fail "lsof not preferred over ss: '$out'"

# Neither tool: fail loudly instead of reporting "nothing listening"
d=$(bindir none)
if out=$(path=("$d"); _claude_listen_pids 4141 2>&1); then fail "no port tool returned success"; fi
[[ "$out" == *"neither lsof nor ss"* ]] || fail "missing-tool message absent: '$out'"

print -r -- "ok claude-proxy-portability"
