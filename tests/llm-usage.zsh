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

# Short DeepSeek names, vision-reroute label, status/error classification, spikes.
local errdir="$tmp/state-errors"
mkdir -p "$errdir"
python3 - "$errdir/events-$month.jsonl" <<'PY'
import json, sys, datetime as dt
now = dt.datetime.now(dt.timezone.utc)
def ts(minutes, sec=0):
    t = (now - dt.timedelta(minutes=minutes)).replace(second=sec, microsecond=0)
    return t.strftime("%Y-%m-%dT%H:%M:%S.000Z")
DS = "rits/deepseek-ai/DeepSeek-V4.1-Flash-1017[1m]"
GLM = "rits/zai-org/glm-5-3"
base = {"port": "4148", "client": "claude-code", "ms": 40, "in": 0, "out": 0}
rows = [
    # vision fallback: glm requested, deepseek served
    {**base, "ts": ts(50), "requested": GLM, "served": DS, "ok": True, "status": 200, "ms": 2500, "in": 10, "out": 20},
    # EnMaaS rate limit, rewritten for Codex (stays 429), with reset hint
    {**base, "ts": ts(45), "requested": GLM, "served": GLM, "ok": False, "status": 429, "upstream_status": 429, "rewritten": True,
     "retry_after": 60, "error_type": "RateLimitError", "error": "RateLimitError: OpenAIException - slow down"},
    # EnMaaS quota 429 rewritten to 503 for Claude
    {**base, "ts": ts(40), "requested": GLM, "served": GLM, "ok": False, "status": 503, "upstream_status": 429, "rewritten": True,
     "retry_after": 3723, "quota": True, "error_type": "RateLimitError", "error": "token budget exhausted"},
    # legacy event (no status fields): class inferred from text
    {**base, "ts": ts(35), "requested": GLM, "served": GLM, "ok": False,
     "error": "litellm.RateLimitError: RateLimitError: OpenAIException - token budget exhausted"},
    # one stray 4xx
    {**base, "ts": ts(30), "requested": GLM, "served": GLM, "ok": False, "status": 400, "upstream_status": 400, "error": "bad request shape"},
] + [
    # 500 burst inside one minute
    {**base, "ts": ts(20, 5 + i), "requested": GLM, "served": GLM, "ok": False, "status": 500, "upstream_status": 500,
     "error_type": "InternalServerError", "error": "InternalServerError: upstream exploded"}
    for i in range(12)
] + [{**base, "ts": ts(m), "requested": GLM, "served": GLM, "ok": True, "status": 200, "ms": 900, "in": 5, "out": 5} for m in (55, 25, 15, 10, 5)]
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
out=$(LLM_USAGE_DIR=$errdir $usage routes --since 2h)
[[ "$out" == *"glm-5.3"*"deepseek-v4.1-flash"*REROUTED* ]] || fail "glm->deepseek vision fallback not flagged: $out"
[[ "$out" != *"1017"* && "$out" != *"[1m]"* ]] || fail "deepseek id not shortened: $out"
[[ "$out" == *429*5XX*OTH*ERR%* ]] || fail "routes lacks error columns: $out"
out=$(LLM_USAGE_DIR=$errdir $usage summary --since 2h --by route --json)
print -r -- "$out" | python3 -c '
import json, sys
r = {x["key"]["route"]: x for x in json.load(sys.stdin)}
assert "glm->deepseek-v4.1-flash" in r, list(r)
g = r["glm-5.3"]
assert (g["e429"], g["e5xx"], g["eoth"], g["err"]) == (3, 12, 1, 16), g
assert round(g["err_rate"], 2) == round(16 / 21, 2), g
' || fail "error aggregation: $out"
out=$(LLM_USAGE_DIR=$errdir $usage summary --since 2h)
[[ "$out" == *"429"*"5XX"*"ERR%"* && "$out" == *"errors/min"*"spike window"* ]] || fail "summary lacks error columns/sparkline: $out"
out=$(LLM_USAGE_DIR=$errdir $usage errors --since 2h)
[[ "$out" == *"rate-limit"* && "$out" == *"quota (budget exhausted)"* && "$out" == *server* ]] || fail "error kinds missing: $out"
[[ "$out" == *"503<-429"* ]] || fail "rewritten 503<-429 not shown: $out"
[[ "$out" == *"429*"* && "$out" == *"inferred"* ]] || fail "legacy status not inferred/flagged: $out"
[[ "$out" == *"reset 1h 2m 3s"* ]] || fail "retry_after not shown: $out"
out=$(LLM_USAGE_DIR=$errdir $usage errors --since 2h --spikes)
[[ "$out" == *"per-minute"* && "$out" == *"█"* ]] || fail "spike sparkline missing: $out"
[[ "$(print -r -- "$out" | grep -cE '^[0-9]{2}-[0-9]{2} [0-9:]+ +[0-9]{2}-[0-9]{2}')" == 1 ]] || fail "expected exactly 1 spike window (the 500 burst): $out"
[[ "$out" == *" 12  "* ]] || fail "spike window should hold the 12 errors: $out"
# transcripts have no status codes: never fabricate errors
out=$(LLM_USAGE_DIR=$errdir LLM_USAGE_CLAUDE_DIRS="$tmp/claude" $usage errors --since 6h --source claude)
[[ "$out" == *"failed: 0"* && "$out" != *"429"* ]] || fail "transcript errors fabricated: $out"
# logger records status classes (stub litellm so it runs without the proxy venv)
python3 -I - "$repo/scripts" <<'PY' || fail "usage logger error fields"
import datetime as dt, sys, types
sys.path.insert(0, sys.argv[1])
for name in ("litellm", "litellm.integrations", "litellm.integrations.custom_logger"):
    sys.modules[name] = types.ModuleType(name)
sys.modules["litellm"].callbacks = []
class CustomLogger:
    def __init__(self, *a, **k): pass
sys.modules["litellm.integrations.custom_logger"].CustomLogger = CustomLogger
import litellm_usage_log as u
now = dt.datetime.now(dt.timezone.utc)
class Exc(Exception):
    status_code = 429
class Hooks:
    LIMIT_REWRITE = True
    @staticmethod
    def limit_reset(exc, model, t): return t + 90, False
hooks = types.ModuleType("fake_hooks"); hooks.LIMIT_REWRITE = True; hooks.limit_reset = Hooks.limit_reset
sys.modules["fake_hooks"] = hooks
cls = type("HostedOnlyHooks", (CustomLogger,), {"__module__": "fake_hooks"})
sys.modules["litellm"].callbacks = [cls()]
info = {"error_code": "429", "error_class": "RateLimitError", "error_message": "RateLimitError: slow down"}
kw = {"model": "glm", "exception": Exc(), "proxy_server_request": {"url": "http://x/v1/messages"}, "standard_logging_object": {"error_information": info}}
ev = u.build_event(kw, None, now, now, False)
assert (ev["upstream_status"], ev["status"], ev["rewritten"], ev["error_type"]) == (429, 503, True, "RateLimitError"), ev
assert 89 <= ev["retry_after"] <= 91, ev
# logger ran after the rewrite: exception already carries the 503 + reset text
late = {"model": "glm", "exception": Exc(), "standard_logging_object": {"error_information": {
    "error_code": "503", "error_message": '[glm] [429]: {"error":{"message":"x"}} (reset after 1h 2m 3s)'}}}
ev = u.build_event(late, None, now, now, False)
assert (ev["upstream_status"], ev["status"], ev["rewritten"], ev["retry_after"]) == (429, 503, True, 3723), ev
ev = u.build_event({"model": "glm"}, None, now, now, True)
assert ev["status"] == 200 and "upstream_status" not in ev, ev
PY

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
assert b"llm-usage" in html and b"ch-errtime" in html and b"ch-errmodel" in html
assert sum(d["err_series"]["oth"]) == 1 and sum(d["err_series"]["5xx"]) == 0, d["err_series"]
assert set(d["err_series"]) == {"429", "5xx", "oth"} and all(len(v) == len(d["buckets"]) for v in d["err_series"].values())
assert d["errors"][0]["status"] and d["errors"][0]["kind"], d["errors"]
assert all("e429" in r and "err_rate" in r for r in d["model_table"])
req = urllib.request.Request(f"http://127.0.0.1:{port}/api/data", headers={"Host": "evil.example"})
try:
    urllib.request.urlopen(req); raise SystemExit("rebinding host accepted")
except urllib.error.HTTPError as err:
    assert err.code == 403
PY
kill $server 2>/dev/null

# Dashboard error panel data on the error fixture (separate state dir, own port).
local eport=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
LLM_USAGE_DIR=$errdir python3 "$usage" serve --port $eport >/dev/null 2>&1 &
server=$!
python3 -I - $eport <<'PY' || fail "dashboard error panel"
import json, sys, time, urllib.request
port = sys.argv[1]
for _ in range(50):
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=1); break
    except Exception:
        time.sleep(0.1)
d = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/api/data?since=2h&source=proxy", timeout=10))
assert {k: sum(v) for k, v in d["err_series"].items()} == {"429": 3, "5xx": 12, "oth": 1}, d["err_series"]
assert len(d["spikes"]) == 1 and d["spikes"][0]["e5xx"] == 12 and d["spikes"][0]["n"] == 12, d["spikes"]
kinds = {(e["status"], e["kind"]) for e in d["errors"]}
assert ("503<-429", "quota (budget exhausted)") in kinds and ("500", "server") in kinds and ("429", "rate-limit") in kinds, kinds
glm = next(r for r in d["model_table"] if r["model"] == "glm-5.3")
assert glm["e429"] == 3 and glm["e5xx"] == 12 and glm["eoth"] == 1, glm
assert any(r["rerouted"] and r["served"] == "deepseek-v4.1-flash" for r in d["routes"]), d["routes"]
PY
kill $server 2>/dev/null

# Wiring: hosted-only proxy config and vertex/openai generators load the usage callback.
source "$repo/scripts/hosted-only-proxy.zsh"
local flavor
for flavor in codex claude; do
    _hosted_only_proxy_vars $flavor
    typeset -gi _hop_with_review=1
    [[ "$(_hosted_only_proxy_config)" == *litellm_usage_log.proxy_handler_instance* ]] || fail "$flavor hosted-only config lacks usage callback"
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
              claude-hosted-only-restart codex-hosted-only-restart llm-proxy-restart; do
        (( $+functions[$fn] )) || { print -ru2 -- "FAIL: $fn not defined"; exit 1; }
    done
    llm-proxy-restart --list >/dev/null || { print -ru2 -- "FAIL: llm-proxy-restart --list"; exit 1; }
    llm-proxy-restart nope 2>/dev/null && { print -ru2 -- "FAIL: unknown target accepted"; exit 1; }
    exit 0
) || exit 1

print -r -- "llm-usage tests passed"
