#!/bin/zsh
# DNS resilience: scripts/dns_fallback.py (DoH fallback for allow-listed hosts
# only, after the system resolver already failed) and the matching restart
# pre-flight. Offline: the "DoH server" is a file:// URL or a stubbed curl, so
# nothing here touches the network or this machine's DNS.
emulate -LR zsh
setopt err_exit pipe_fail

local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { print -ru2 -- "FAIL: $*"; exit 1; }

mkdir -p "$tmp/shim" "$tmp/empty"
cp "$repo/scripts/dns_fallback.py" "$tmp/shim/sitecustomize.py"
print -r -- '{"Status":0,"Answer":[{"name":"gw.invalid.","type":5,"TTL":60,"data":"alias.invalid."},{"name":"alias.invalid.","type":1,"TTL":60,"data":"203.0.113.9"}]}' > "$tmp/answer.json"
print -r -- '{"Status":0,"Answer":[]}' > "$tmp/empty/answer.json"

# resolves the allow-listed name through DoH after the system resolver fails,
# following the CNAME in the same answer
out=$(PYTHONPATH="$tmp/shim" ENMAAS_DNS_FALLBACK_HOSTS='gw.invalid' \
      ENMAAS_DNS_DOH_URLS="file://$tmp/answer.json" \
      python3 -c 'import socket; print(socket.getaddrinfo("gw.invalid", 443)[0][4][0])') \
    || fail "allow-listed name did not fall back"
[[ "$out" == 203.0.113.9 ]] || fail "fallback returned '$out', want 203.0.113.9"

# a name that is not allow-listed keeps failing: no silent bypass of the
# system resolver for anything else
PYTHONPATH="$tmp/shim" ENMAAS_DNS_FALLBACK_HOSTS='gw.invalid' \
    ENMAAS_DNS_DOH_URLS="file://$tmp/answer.json" \
    python3 -c 'import socket; socket.getaddrinfo("other.invalid", 443)' 2>/dev/null \
    && fail "non-allow-listed name was resolved"

# no DoH answer means the original resolution error stands
PYTHONPATH="$tmp/shim" ENMAAS_DNS_FALLBACK_HOSTS='gw.invalid' \
    ENMAAS_DNS_DOH_URLS="file://$tmp/empty/answer.json" \
    python3 -c 'import socket; socket.getaddrinfo("gw.invalid", 443)' 2>/dev/null \
    && fail "unanswered DoH still produced an address"

# an empty allow-list disables the shim entirely
PYTHONPATH="$tmp/shim" ENMAAS_DNS_DOH_URLS="file://$tmp/answer.json" \
    python3 -c 'import socket; socket.getaddrinfo("gw.invalid", 443)' 2>/dev/null \
    && fail "empty allow-list still resolved"

# a broken shim must never break the interpreter (bad DoH URL, no crash)
out=$(PYTHONPATH="$tmp/shim" ENMAAS_DNS_FALLBACK_HOSTS='gw.invalid' \
      ENMAAS_DNS_DOH_URLS='not-a-url' \
      python3 -c 'print("import ok")') || fail "shim broke the interpreter"
[[ "$out" == "import ok" ]] || fail "unexpected output: $out"

# Restart pre-flight: the system resolver is gone, so it must consult DoH
# before declaring the gateway unreachable (the proxy shim covers the proxy
# itself; this covers the restart command that gates on the name).
local dbin="$tmp/bin"
mkdir -p "$dbin"
cat > "$dbin/curl" <<'SH'
#!/bin/zsh
[[ -z "$DOH_EMPTY" ]] || exit 0
cat "$DOH_JSON"
SH
cat > "$dbin/scutil" <<'SH'
#!/bin/zsh
print -r -- '  nameserver[0] : 192.168.1.1'
SH
cat > "$dbin/networksetup" <<'SH'
#!/bin/zsh
case "$1" in
  -listallnetworkservices) print -r -- note; print -r -- Wi-Fi ;;
  *) print -r -- "There aren't any DNS Servers set on Wi-Fi." ;;
esac
SH
chmod +x "$dbin"/*
(
    path=("$dbin" $path)
    rehash
    source "$repo/zsh/functions/claude/load.zsh" >/dev/null 2>&1
    export DOH_JSON="$tmp/answer.json"
    _llm_proxy_dns_addresses() { return 2; }   # system resolver cannot answer
    local out='' rc=0   # explicit: `local out` alone echoes a pre-set value
    out=$(_llm_proxy_dns_probe gw.invalid enmaas 2>&1) || rc=$?
    [[ $rc == 0 && "$out" == *203.0.113.9*DoH* ]] || fail "pre-flight ignored DoH (rc=$rc): $out"
    export DOH_EMPTY=1
    rc=0 out=$(_llm_proxy_dns_probe gw.invalid enmaas 2>&1) || rc=$?
    [[ $rc == 1 && "$out" == *"does not resolve"* ]] || fail "both resolvers failing must block (rc=$rc): $out"
    exit 0
) || exit 1

print -r -- "dns fallback tests passed"
