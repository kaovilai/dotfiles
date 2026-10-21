#!/bin/zsh
# llm-usage CLI against synthetic proxy events + proxy wiring checks.
emulate -LR zsh
setopt err_exit pipe_fail

local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export LLM_USAGE_DIR="$tmp/state"
mkdir -p "$LLM_USAGE_DIR"

fail() { print -ru2 -- "FAIL: $*"; exit 1; }

local now
now=$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')
local month=${now[1,7]}
cat > "$LLM_USAGE_DIR/events-$month.jsonl" <<JSON
{"ts":"$now","port":"4148","client":"claude-code","requested":"claude-sonnet-5-5","served":"rits/zai-org/glm-5-3","ok":true,"ms":900,"in":100,"out":50,"cache_read":300000,"cache_write":0,"role":"classifier"}
{"ts":"$now","port":"4148","client":"claude-code","requested":"claude-sonnet-5-5","served":"rits/zai-org/glm-5-3","ok":false,"error":"boom","ms":50,"in":0,"out":0}
{"ts":"$now","port":"4148","client":"claude-code","requested":"rits/zai-org/glm-5-3","served":"rits/zai-org/glm-5-3","ok":true,"ms":2000,"in":10,"out":500,"cache_read":1000}
{"ts":"$now","port":"4147","client":"codex","requested":"gpt-6-luna","served":"gpt-6-luna","ok":true,"ms":700,"in":10,"out":5,"cache_read":0}
JSON
local usage="$repo/scripts/llm-usage"

local out
out=$($usage routes --since 1h)
[[ "$out" == *"claude-sonnet-5-5"*"glm-5.3"*REROUTED* ]] || fail "sonnet->glm reroute not flagged: $out"
[[ "$out" == *"gpt-6-luna"*direct* ]] || fail "luna should be direct: $out"
[[ "$($usage routes --since 1h | grep -c direct)" == 2 ]] || fail "expected 2 direct routes"

out=$($usage summary --since 1h --by route --json)
[[ "$(print -r -- "$out" | python3 -c 'import json,sys;r={x["key"]["route"]:x for x in json.load(sys.stdin)};print(r["sonnet->glm-5.3"]["n"],r["sonnet->glm-5.3"]["err"],r["sonnet->glm-5.3"]["long"])')" == "2 1 1" ]] \
    || fail "route aggregation wrong: $out"

out=$($usage summary --since 1h --by role)
[[ "$out" == *classifier* ]] || fail "classifier role missing"
out=$($usage errors --since 1h)
[[ "$out" == *boom* ]] || fail "error not listed"
out=$($usage tail -n 2)
[[ "$out" == *"sonnet->glm-5.3"* || "$out" == *gpt-6-luna* ]] || fail "tail empty: $out"

# auto = proxy log + transcripts for earlier history / unseen models (not proxy-only).
mkdir -p "$tmp/claude/proj"
python3 - "$tmp/claude/proj/s.jsonl" <<'PY'
import json, sys, datetime as dt
now = dt.datetime.now(dt.timezone.utc)
def line(minutes, model, mid):
    ts = (now - dt.timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    return json.dumps({"type": "assistant", "timestamp": ts, "uuid": mid, "sessionId": "s",
                       "message": {"id": mid, "model": model, "usage": {"input_tokens": 5, "output_tokens": 7}}})
rows = [line(120, "zai-org/GLM-5.3", "old-glm"),   # before logging started, kept
        line(0, "zai-org/GLM-5.3", "new-glm"),   # model the proxy log covers, dropped
        line(0, "claude-opus-5-5", "new-opus")]  # model the proxy log has not seen, kept
open(sys.argv[1], "w").write("\n".join(rows) + "\n")
PY
out=$(LLM_USAGE_CLAUDE_DIRS="$tmp/claude" $usage summary --since 6h --by source,model --json)
[[ "$(print -r -- "$out" | python3 -c 'import json,sys;print(sorted((r["key"]["source"],r["key"]["model"],r["n"]) for r in json.load(sys.stdin)))')" == *"('claude', 'claude-opus-5-5', 1)"* ]] || fail "unseen model missing in auto merge: $out"
[[ "$out" == *'"claude"'* && "$(print -r -- "$out" | python3 -c 'import json,sys;print(sum(r["n"] for r in json.load(sys.stdin) if r["key"]["source"]=="claude" and r["key"]["model"]=="glm-5.3"))')" == 1 ]] || fail "glm transcripts after proxy logging began should be dropped, earlier kept: $out"
# ranges must change the result, not return one fixed set
[[ "$(LLM_USAGE_CLAUDE_DIRS="$tmp/claude" $usage summary --since 15m --json | python3 -c 'import json,sys;print(sum(r["n"] for r in json.load(sys.stdin)))')" != "$(LLM_USAGE_CLAUDE_DIRS="$tmp/claude" $usage summary --since 6h --json | python3 -c 'import json,sys;print(sum(r["n"] for r in json.load(sys.stdin)))')" ]] || fail "15m and 6h returned the same events"

# Dashboard server: JSON API, reroute flag, model hiding, host-header guard.
local port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$usage" serve --port $port >/dev/null 2>&1 &
local server=$!
trap 'kill $server 2>/dev/null; rm -rf "$tmp"' EXIT
python3 -I - $port <<'PY' || fail "dashboard API"
import json, sys, time, urllib.request
port = sys.argv[1]
for _ in range(50):
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=1); break
    except Exception:
        time.sleep(0.1)
get = lambda q: json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/api/data?{q}", timeout=10))
d = get("since=1h&source=proxy")
assert d["events"] == 4 and d["source"] == "proxy", d["events"]
assert any(r["rerouted"] and r["requested"] == "claude-sonnet-5-5" and r["served"] == "glm-5.3" for r in d["routes"]), d["routes"]
assert d["kpi"]["long"] == 1 and d["kpi"]["classifier"] == 1 and d["kpi"]["err"] == 1
assert "glm-5.3" in d["chips"] and d["colors"]["glm-5.3"] >= 1
assert get("since=1h&source=proxy&hide=glm-5.3")["events"] == 1
html = urllib.request.urlopen(f"http://127.0.0.1:{port}/").read()
assert b"llm-usage" in html
req = urllib.request.Request(f"http://127.0.0.1:{port}/api/data", headers={"Host": "evil.example"})
try:
    urllib.request.urlopen(req); raise SystemExit("rebinding host accepted")
except urllib.error.HTTPError as err:
    assert err.code == 403
PY
kill $server 2>/dev/null

# Wiring: hybrid proxy config and vertex/openai generators load the usage callback.
source "$repo/scripts/glm-hybrid-proxy.zsh"
local flavor
for flavor in codex claude; do
    _glm_hybrid_proxy_vars $flavor
    typeset -gi _ghp_with_review=1
    [[ "$(_glm_hybrid_proxy_config)" == *litellm_usage_log.proxy_handler_instance* ]] || fail "$flavor hybrid config lacks usage callback"
done
[[ -r "$repo/scripts/litellm_usage_log.py" ]] || fail "usage log module missing"
grep -q litellm_usage_log "$repo/zsh/functions/claude/providers/vertex.zsh" || fail "vertex lacks callback"
grep -q litellm_usage_log "$repo/zsh/functions/claude/providers/openai.zsh" || fail "openai lacks callback"
python3 -m py_compile "$repo/scripts/litellm_usage_log.py" "$usage" || fail "py_compile"

# Restart commands exist for every proxy and the dispatcher rejects unknown names.
(
    source "$repo/zsh/functions/claude/load.zsh" >/dev/null 2>&1
    local fn
    for fn in claude-copilot-restart claude-vertex-restart claude-openai-restart claude-enmaas-restart \
              claude-glm-hybrid-restart claude-glm-only-restart codex-glm-hybrid-restart codex-glm-only-restart llm-proxy-restart; do
        (( $+functions[$fn] )) || { print -ru2 -- "FAIL: $fn not defined"; exit 1; }
    done
    llm-proxy-restart --list >/dev/null || { print -ru2 -- "FAIL: llm-proxy-restart --list"; exit 1; }
    llm-proxy-restart nope 2>/dev/null && { print -ru2 -- "FAIL: unknown target accepted"; exit 1; }
    exit 0
) || exit 1

print -r -- "llm-usage tests passed"
