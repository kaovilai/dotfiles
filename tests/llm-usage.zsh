#!/bin/zsh
# llm-usage CLI against synthetic proxy events + proxy wiring checks.
emulate -LR zsh
setopt err_exit pipe_fail

local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export LLM_USAGE_DIR="$tmp/state"
mkdir -p "$LLM_USAGE_DIR" "$tmp/no-claude" "$tmp/no-codex"
# hermetic: `--source auto` must not merge this machine's real Claude/Codex transcripts into the synthetic numbers
export LLM_USAGE_CLAUDE_DIRS="$tmp/no-claude" LLM_USAGE_CODEX_DIRS="$tmp/no-codex"

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

# errors: closing "Code needs updating" block when the proxy logger attached drift notes (absent field = no block)
local driftdir="$tmp/driftstate"
mkdir -p "$driftdir"
cat > "$driftdir/events-$month.jsonl" <<JSON
{"ts":"$now","port":"4148","served":"rits/zai-org/glm-5-3","ok":false,"status":429,"upstream_status":429,"error":"rate limited","retry_after":30,"reset_at":$(date +%s),"reset_source":"upstream-header:retry-after","drift":[{"kind":"unhandled_header","detail":"x-new-reset","hint":"parse x-new-reset in hosted_only_hooks.py"}]}
{"ts":"$now","port":"4148","served":"rits/zai-org/glm-5-3","ok":false,"status":500,"error":"boom","drift":[{"kind":"unhandled_header","detail":"x-new-reset","hint":"parse x-new-reset in hosted_only_hooks.py"}, "junk", {"kind":"x"}]}
JSON
out=$(LLM_USAGE_DIR=$driftdir $usage errors --since 1h --source proxy)
[[ "$out" == *"Code needs updating"*"unhandled_header  x-new-reset  x2"*"hint: parse x-new-reset in hosted_only_hooks.py"* ]] || fail "errors drift block: $out"
out=$($usage errors --since 1h)
[[ "$out" != *"Code needs updating"* ]] || fail "no drift field -> no block: $out"

# menubar-data: one JSON endpoint for the menubar helper (synthetic state dirs, no probing, no real transcripts).
local mbjson="$tmp/mbjson"
mkdir -p "$mbjson"
python3 - "$usage" "$tmp" "$mbjson" <<'PY' || fail "menubar-data scenarios"
import datetime as dt, http.server, json, os, subprocess, sys, tempfile, threading
usage, tmp, outdir = sys.argv[1:4]
now = dt.datetime.now(dt.timezone.utc)
def ts(sec_ago): return (now - dt.timedelta(seconds=sec_ago)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
GLM, DS, SON = "rits/zai-org/glm-5-3", "rits/deepseek-ai/DeepSeek-V4.1-Flash-1017", "claude-sonnet-5-5"
def ev(sec_ago, port="4148", **kw):
    base = {"ts": ts(sec_ago), "port": port, "client": "claude-code", "requested": GLM, "served": GLM, "ok": True, "status": 200, "ms": 500, "in": 5, "out": 5}
    return {**base, **kw}
def err(sec_ago, code=429, **kw):
    return ev(sec_ago, **{"ok": False, "status": code, "upstream_status": code, "error": "boom", **kw})
copilot_server = {}
def run(name, events=(), up="4141,4147,4148", extra_env=None, inflight=None, timings=None, transcripts=None, raw_lines=None, state=None, cli=(), transcript_lines=None):
    state = state or tempfile.mkdtemp(dir=tmp)
    os.makedirs(state, exist_ok=True)
    lines = [json.dumps(e) for e in events] + list(raw_lines or [])
    if lines:
        with open(f"{state}/events-{now:%Y-%m}.jsonl", "w") as h: h.write("\n".join(lines) + "\n")
    for fname, doc in (inflight or {}).items():
        with open(f"{state}/{fname}", "w") as h: json.dump(doc, h)
    if timings:
        with open(f"{state}/timings-{now:%Y-%m}.jsonl", "w") as h:
            for rec in timings:
                h.write(json.dumps(rec) + "\n")
    claude = tempfile.mkdtemp(dir=tmp)
    if transcripts or transcript_lines:
        os.makedirs(f"{claude}/proj")
        with open(f"{claude}/proj/s.jsonl", "w") as h:
            for i, (sec_ago, model, out) in enumerate(transcripts or []):
                h.write(json.dumps({"type": "assistant", "timestamp": ts(sec_ago), "uuid": f"u{i}", "sessionId": "s",
                    "message": {"id": f"m{i}", "model": model, "usage": {"input_tokens": 10, "output_tokens": out, "cache_read_input_tokens": 1000}}}) + "\n")
            for row in transcript_lines or []:
                h.write(json.dumps(row) + "\n")
    env = {**os.environ, "LLM_USAGE_DIR": state, "LLM_USAGE_CLAUDE_DIRS": claude, "LLM_USAGE_CODEX_DIRS": tempfile.mkdtemp(dir=tmp),
           "LLM_USAGE_COPILOT_URL": "http://127.0.0.1:9/usage", **(extra_env or {})}
    res = subprocess.run([sys.executable, usage, "menubar-data", "--up-ports", up, *cli], capture_output=True, text=True, env=env, timeout=60)
    assert res.returncode == 0, (name, res.stderr)
    d = json.loads(res.stdout)
    json.dump(d, open(f"{outdir}/{name}.json", "w"))
    return d
def proxy(d, port): return next(p for p in d["proxies"] if p["port"] == port)

# normal
d = run("normal", [ev(30), ev(60), ev(120, port="4147"), err(200, 500)])
assert d["version"] == 2 and d["throttled"] is None and not d["spike"]["active"] and not d["any_down"], d
assert proxy(d, 4148)["m15"]["requests"] == 3 and proxy(d, 4148)["m15"]["errors"]["5xx"] == 1, proxy(d, 4148)
assert proxy(d, 4148)["state"] == "up" and proxy(d, 4142)["state"] == "down" and not proxy(d, 4142)["expected"]
assert d["totals"]["m15"]["requests"] == 4 and d["top_models"][0] == {"model": "glm-5.3", "requests": 4}, d["top_models"]
assert d["last_error"]["status"] == "500" and d["last_error"]["proxy"] == "claude-hosted-only", d["last_error"]
assert len(d["series"]["requests"]) == 60 and sum(d["series"]["requests"]) == 4 and sum(d["series"]["e5xx"]) == 1
assert d["reroutes"] == [] and d["reroutes_15m"] == 0 and d["by_model"][0]["reroutes"] == 0

# throttled: 429 with retry_after still in the future (estimate = event time + retry_after)
d = run("throttled", [ev(100), err(30, 429, retry_after=300, rewritten=True)])
t = d["throttled"]
assert t and t["kind"] == "rate-limit" and t["basis"] == "retry_after" and t["estimate"] and t["model"] == "glm-5.3", t
assert 265 <= t["seconds_left"] <= 271 and t["proxy"] == "claude-hosted-only", t
# a later success on the same proxy+model proves it is not blocked; an expired reset is not throttled either
assert run("throttled-cleared", [err(30, 429, retry_after=300), ev(10)])["throttled"] is None
assert run("throttled-expired", [err(600, 429, retry_after=60)])["throttled"] is None
t = run("throttled-assumed", [err(20, 429)])["throttled"]
assert t["basis"] == "assumed-60s" and 36 <= t["seconds_left"] <= 41, t

# quota 429 without retry_after: next UTC month start; with retry_after: that wins
d = run("quota", [err(60, 429, quota=True, error="token budget exhausted")])
nxt = (now.replace(day=1, hour=0, minute=0, second=0, microsecond=0) + dt.timedelta(days=32)).replace(day=1)
t = d["throttled"]
assert t["kind"] == "quota" and t["basis"] == "next-month-utc" and t["reset_at"] == nxt.strftime("%Y-%m-%dT%H:%M:%SZ"), t
t = run("quota-retry", [err(60, 503, upstream_status=429, quota=True, retry_after=3723)])["throttled"]
assert t["kind"] == "quota" and t["basis"] == "retry_after" and 3600 < t["seconds_left"] < 3700, t

# spike: 12 failures inside one minute; an old burst is not active
sparse = lambda *secs: [err(x, 500) for x in secs]  # single failures set the baseline the burst stands out from
d = run("spike", [ev(300 + i) for i in range(5)] + sparse(1500, 1200, 900, 700) + [err(10 + i % 3, 500) for i in range(12)])
assert d["spike"]["active"] and d["spike"]["errors"] >= 12, d["spike"]
d = run("spike-old", sparse(3500, 3300, 3000, 2800) + [err(2400 + i % 3, 500) for i in range(12)] + [ev(10)])
assert d["spike"]["windows"] == 1 and not d["spike"]["active"], d["spike"]

# proxy down: expected (logged this week) vs never seen
d = run("down", [ev(60), ev(60, port="4147")], up="4141,4147")
assert proxy(d, 4148)["state"] == "down" and proxy(d, 4148)["expected"] and d["any_down"], proxy(d, 4148)
assert not proxy(d, 4146)["expected"], "never-seen proxy must not count as down"
assert not run("not-expected", [], up="4141")["any_down"]

# throwaway test proxy on an ad-hoc port: its 429 / errors must not raise throttled, spike or down alarms
d = run("adhoc-port", [ev(100), err(30, 429, port="4157", retry_after=300), err(20, 500, port="4157"), err(10, 500, port="4157")], up="4141,4147,4148")
assert d["throttled"] is None and not d["any_down"] and all(p["port"] != 4157 for p in d["proxies"]), d["proxies"]

# empty log (state dir does not even exist) and all proxies down
d = run("empty", state=os.path.join(tmp, "does-not-exist"), up="")
assert d["totals"]["m15"]["requests"] == 0 and d["throttled"] is None and d["last_error"] is None and d["top_models"] == [] and not d["any_down"], d
assert d["inflight"]["available"] is False and d["inflight"]["count"] == 0 and d["copilot"]["quota"] is None, d["inflight"]

# old events: no status/upstream_status/retry_after/port/served fields, junk lines
old = [{"ts": ts(60), "port": "4148", "served": GLM, "ok": True},
       {"ts": ts(50), "port": "4148", "served": GLM, "ok": False, "error": "litellm.RateLimitError: OpenAIException - token budget exhausted"},
       {"ts": ts(40), "ok": True}, {"ts": ts(30), "port": "4147", "served": GLM, "ok": False}]
d = run("old", old, raw_lines=["not json", "{}", '{"ts": "garbage"}'])
assert d["throttled"] and d["throttled"]["kind"] == "quota" and d["throttled"]["basis"] == "next-month-utc", d["throttled"]
assert proxy(d, 4148)["h1"]["errors"]["429"] == 1 and proxy(d, 4147)["h1"]["errors"]["other"] == 1, (proxy(d, 4148), proxy(d, 4147))

# reroutes: alias (fake sonnet + classifier tier), vision, fallback, none
d = run("reroute-alias", [ev(60, requested=SON), ev(50, requested=SON), ev(40, requested="claude-sonnet-5-5", served=DS, role="classifier"), ev(30)])
kinds = {(r["from"], r["to"], r["kind"]): r["count"] for r in d["reroutes"]}
assert kinds == {("sonnet", "glm-5.3", "alias"): 2, ("sonnet", "deepseek-v4.1-flash", "alias"): 1}, kinds
assert d["reroutes_15m"] == 3 and next(m for m in d["by_model"] if m["model"] == "glm-5.3")["reroutes"] == 2, d["by_model"]
d = run("reroute-vision", [ev(60, served=DS), ev(30)])
assert [(r["from"], r["to"], r["kind"], r["count"]) for r in d["reroutes"]] == [("glm-5.3", "deepseek-v4.1-flash", "vision", 1)], d["reroutes"]
d = run("reroute-fallback", [ev(60, fallback=True), ev(30, served=SON, requested=SON, fallback=True), ev(20)])
assert {r["kind"] for r in d["reroutes"]} == {"fallback"} and sum(r["count"] for r in d["reroutes"]) == 2, d["reroutes"]
d = run("reroute-none", [ev(60), ev(30, port="4147", requested="gpt-6-luna", served="gpt-6-luna")])
assert d["reroutes"] == [] and d["reroutes_15m"] == 0
assert d["by_proxy"][0]["models"], d["by_proxy"]
d = run("reroute-other", [ev(60, requested="gemini-3", served="gpt-6-luna")])
assert d["reroutes"][0]["kind"] == "other", d["reroutes"]

# in-flight: live entries counted, oldest reported; dead-pid files evicted, but a
# live pid's long-running entry is kept (a stream must not vanish at 15 minutes)
dead = subprocess.Popen(["true"]); dead.wait()
t0 = now.timestamp()
fl = {
    "inflight-4148-%d.json" % os.getppid(): {"pid": os.getppid(), "port": "4148", "updated": t0, "requests": {
        "a": {"t": t0 - 42, "model": GLM, "requested": SON}, "b": {"t": t0 - 5, "model": DS},
        "stale": {"t": t0 - 1200, "model": GLM}}},
    "inflight-4147-%d.json" % dead.pid: {"pid": dead.pid, "port": "4147", "updated": t0, "requests": {"x": {"t": t0 - 3, "model": GLM}}},
    "inflight-4141-%d.json" % os.getppid(): {"pid": os.getppid(), "port": "4141", "updated": t0, "requests": {"c": {"t": t0 - 2, "model": "gpt-6-luna"},
        # copilot-api monitor plugin shape: "unknown" until the body is parsed
        "d": {"t": t0 - 1, "model": "unknown", "actual_model": "claude-haiku-5-5", "user_agent": "x", "session_id": None, "ttft_ms": None}}},
}
d = run("inflight", [ev(30)], inflight=fl)
f = d["inflight"]
assert f["available"] and f["count"] == 5 and 1190 <= f["oldest_s"] <= 1210, f
assert f["oldest"]["model"] == "glm-5.3" and f["oldest"]["proxy"] == "claude-hosted-only", f
assert f["by_model"] == {"glm-5.3": 2, "deepseek-v4.1-flash": 1, "gpt-6-luna": 1, "claude-haiku-5-5": 1}, f
assert proxy(d, 4148)["inflight"]["count"] == 3 and proxy(d, 4147)["inflight"] is None, (proxy(d, 4148)["inflight"], proxy(d, 4147)["inflight"])
assert proxy(d, 4141)["inflight"]["count"] == 2 and d["copilot"]["inflight"]["count"] == 2, (proxy(d, 4141)["inflight"], d["copilot"]["inflight"])
n = run("inflight-none", [ev(30)])
assert n["inflight"]["available"] is False and n["copilot"]["inflight"] is None, "no 4141 file must stay n/a, never invented"

# tokens/s: completion tokens per second per minute, same vendor/provider split as the request chart
t = run("tps", [ev(30, out=600)])
assert len(t["series"]["tps"]) == 60 and abs(max(t["series"]["tps"]) - 10.0) < 0.01, t["series"]["tps"]
assert abs(max(t["series"]["tps_by_vendor"]["glm"]) - 10.0) < 0.01, t["series"]["tps_by_vendor"]
assert abs(max(t["series_by_provider"]["providers"][0]["tps"]) - 10.0) < 0.01, t["series_by_provider"]
assert t["tokens"]["m15"] == {"in": 5, "out": 600}, t["tokens"]

# latency / ttft: per-minute median (ms) plus a one-hour p50/p95 summary
lt = run("latency", [ev(30, ms=800, ttft_ms=200)])
assert abs(max(lt["series"]["latency"]) - 800) < 0.01, lt["series"]["latency"]
assert abs(max(lt["series"]["ttft"]) - 200) < 0.01, lt["series"]["ttft"]
assert abs(max(lt["series"]["latency_by_vendor"]["glm"]) - 800) < 0.01, lt["series"]["latency_by_vendor"]
assert lt["latency"] == {"p50": 800, "p95": 800, "ttft_p50": 200, "ttft_p95": 200}, lt["latency"]
assert abs(max(lt["series"]["latency_by_provider"]["enmaas"]) - 800) < 0.01, lt["series"]["latency_by_provider"]
prov = lt["series_by_provider"]["providers"][0]
assert prov["key"] == "enmaas" and abs(max(prov["latency"]) - 800) < 0.01 and abs(max(prov["ttft"]) - 200) < 0.01, prov

# copilot-api timing rows: latency/TTFT only, never counted as extra requests
tw = run("timings", [ev(30)], timings=[{"t": now.timestamp() - 30, "port": "4141", "model": "gpt-6-luna", "ms": 900, "ttft_ms": 200}])
assert abs(max(tw["series"]["latency_by_provider"]["github-copilot"]) - 900) < 0.01, tw["series"]["latency_by_provider"]
assert tw["totals"]["m15"]["requests"] == 1, tw["totals"]

# copilot: transcript-derived usage (models absent from the proxy log), quota from /usage when reachable
tr = [(60, "claude-opus-5-5", 100), (120, "claude-opus-5-5", 50), (1800, "claude-opus-5-5", 25), (30, "zai-org/GLM-5.3", 999)]
d = run("copilot-noquota", [ev(30)], transcripts=tr)
c = d["copilot"]
assert c["source"] == "transcript" and c["m15"]["requests"] == 2 and c["h1"]["requests"] == 3, c
assert c["m15"]["tokens"]["out"] == 150 and c["models"] == [{"model": "claude-opus-5-5", "requests": 3}], c
assert c["quota"] is None and "unavailable" in c["quota_note"], c  # honest: no /usage endpoint, no quota invented
assert proxy(d, 4141)["source"] == "transcript" and proxy(d, 4141)["m15"]["requests"] == 2
assert any(p["proxy"] == "copilot-api" and p["source"] == "transcript" for p in d["by_proxy"]), d["by_proxy"]
assert any(m["model"] == "claude-opus-5-5" and m["sources"] == ["transcript"] for m in d["by_model"]), d["by_model"]
assert next(m for m in d["by_model"] if m["model"] == "glm-5.3")["requests"] == 1, "glm transcript call is already in the proxy log"
assert run("copilot-down", [ev(30)], transcripts=tr, up="4148")["copilot"]["quota_note"] == "copilot-api (:4141) is down"
usage_doc = {"copilot_plan": "enterprise", "quota_reset_date_utc": "2026-11-01T00:00:00.000Z", "token_based_billing": False,
             "quota_snapshots": {"premium_interactions": {"unlimited": False, "remaining": 120, "entitlement": 300, "percent_remaining": 40.0,
                                                          "credits_used": 0, "overage_count": 0}}}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = json.dumps(copilot_server["doc"]).encode()
        self.send_response(200); self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{srv.server_address[1]}/usage"
copilot_server["doc"] = usage_doc
q = run("copilot-quota", [ev(30)], transcripts=tr, extra_env={"LLM_USAGE_COPILOT_URL": url})["copilot"]["quota"]
assert q and not q["unlimited"] and q["remaining"] == 120 and q["entitlement"] == 300 and q["reset_date"].startswith("2026-11-01") and q["source"] == "copilot-api /usage", q
copilot_server["doc"] = {"copilot_plan": "enterprise", "token_based_billing": True, "quota_reset_date": "2026-11-01",
                         "quota_snapshots": {"premium_interactions": {"unlimited": True, "credits_used": 301558, "percent_remaining": 100}}}
q = run("copilot-unlimited", [ev(30)], extra_env={"LLM_USAGE_COPILOT_URL": url})["copilot"]["quota"]
assert q["unlimited"] and q["credits_used"] == 301558 and q["token_based_billing"], q
copilot_server["doc"] = {"unexpected": "shape"}  # reachable but no premium_interactions: no quota, not a crash
c = run("copilot-badshape", [ev(30)], extra_env={"LLM_USAGE_COPILOT_URL": url})["copilot"]
assert c["quota"] is None and c["quota_note"], c

# throttle spans + series_by_provider + drift. Copilot throttles come from Claude Code transcripts only:
# type=system/api_error (one per retried attempt, error.status + retryInMs) and type=assistant/isApiErrorMessage.
def apierr(sec_ago, status, text="upstream rate limited", attempt=1, retry_ms=2000, **kw):
    return {"type": "system", "subtype": "api_error", "level": "error", "timestamp": ts(sec_ago), "uuid": f"e{sec_ago}-{status}-{attempt}", "sessionId": "s",
            "retryAttempt": attempt, "maxRetries": 10, "retryInMs": retry_ms,
            "error": {"status": str(status), "message": f"{status} {text}", "formatted": f"{status} {text}", "rateLimits": None}, **kw}
trc = [(1800, "claude-opus-5-5", 25), (120, "claude-opus-5-5", 50), (60, "claude-opus-5-5", 100)]  # last model: a Copilot (non-proxy-log) one
trq = [(1800, "claude-opus-5-5", 25), (300, "claude-opus-5-5", 50)]  # no success after the errors below, so spans are not cut short
def spans_of(d, provider=None): return [x for x in d["throttle_spans"] if provider in (None, x["provider"])]
def secs(iso): return dt.datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp()
epoch = now.timestamp()

# Copilot retry chain (3 consecutive 429s) -> ONE span, ends at the last attempt + retryInMs (an estimate), transcript-derived
chain = [apierr(600, 429, attempt=1, retry_ms=2000), apierr(598, 429, attempt=2, retry_ms=4000), apierr(594, 429, attempt=3, retry_ms=8000)]
d = run("throttle-copilot", [ev(30)], transcripts=trc, transcript_lines=chain)
(cs,) = spans_of(d, "github-copilot")
assert cs["kind"] == "rate-limit" and cs["count"] == 3 and cs["source"] == "transcript" and cs["end_estimated"] and not cs["active"], cs
assert abs(secs(cs["start"]) - (epoch - 600)) < 3 and abs(secs(cs["end"]) - (epoch - 586)) < 3, cs
assert spans_of(d, "enmaas") == [] and "github-copilot" not in d["throttle_notes"] or "transcript-derived" in d["throttle_notes"]["github-copilot"], d["throttle_notes"]
# still going (retryInMs reaches past now) and no success since: active, end in the future
d = run("throttle-copilot-live", [ev(30)], transcripts=[(120, "claude-opus-5-5", 50)], transcript_lines=[apierr(20, 429, retry_ms=30000), apierr(18, 429, attempt=2, retry_ms=30000)])
(cs,) = spans_of(d, "github-copilot")
assert cs["active"] and cs["count"] == 2 and cs["end_estimated"] and 10 <= secs(cs["end"]) - epoch <= 14, cs
# a success after the last attempt ends the span at the success (observed, not estimated)
d = run("throttle-copilot-recovered", [ev(30)], transcripts=[(120, "claude-opus-5-5", 50), (10, "claude-opus-5-5", 50)],
        transcript_lines=[apierr(60, 429, retry_ms=600000)])
(cs,) = spans_of(d, "github-copilot")
assert not cs["end_estimated"] and not cs["active"] and abs(secs(cs["end"]) - (epoch - 10)) < 3, cs
# 402 = quota; 403 only when the body talks quota/limits; a plain 503 or 403 is not a throttle
d = run("throttle-copilot-quota", [ev(30)], transcripts=trq, transcript_lines=[apierr(100, 402, "You have exceeded your premium request allowance")])
(cs,) = spans_of(d, "github-copilot")
assert cs["kind"] == "quota" and cs["source"] == "transcript" and cs["end_estimated"] and cs["basis"] == "next-month-utc", cs
d = run("throttle-copilot-nonthrottle", [ev(30)], transcripts=trq, transcript_lines=[apierr(100, 503, "Service Unavailable"), apierr(90, 403, "forbidden"), apierr(80, 500, "boom"),
        apierr(70, 403, "quota exceeded for this model")])
assert [x["kind"] for x in spans_of(d, "github-copilot")] == ["quota"], spans_of(d)
# LiteLLM 429 ("No deployments available") is the hosted-only proxy's, never Copilot: not a Copilot span even when the session model is
# a Copilot one; the proxy log (4148, EnMaaS) owns it. Same for an untagged 429 whose session model is a proxy-log model (GLM).
litellm = apierr(100, 429, "No deployments available for selected model, Try again in 5 seconds. Passed model=rits/zai-org/glm-5-3", retry_ms=566)
d = run("throttle-litellm", [ev(300), err(100, 429, retry_after=60, error="No deployments available")], transcripts=trc, transcript_lines=[litellm])
assert spans_of(d, "github-copilot") == [] and [x["provider"] for x in spans_of(d)] == ["enmaas"], spans_of(d)
assert spans_of(d)[0]["source"] == "proxy-log" and spans_of(d)[0]["count"] == 1, spans_of(d)
assert d["throttle_notes"]["github-copilot"].startswith("no Copilot throttle data"), d["throttle_notes"]
d = run("throttle-glm-session", [ev(300)], transcripts=tr, transcript_lines=[apierr(100, 429, "Too Many Requests")])
assert spans_of(d, "github-copilot") == [], "429 in a session whose model the proxy log serves belongs to that proxy, not Copilot"
# a hard failure after retries are exhausted: assistant + isApiErrorMessage + apiErrorStatus
hard = {"type": "assistant", "timestamp": ts(40), "uuid": "hard1", "sessionId": "s", "isApiErrorMessage": True, "apiErrorStatus": 429, "error": "rate_limit",
        "message": {"model": "<synthetic>", "role": "assistant", "content": [{"type": "text", "text": "API Error: 429 Request rejected (429)"}]}}
d = run("throttle-copilot-hard", [ev(30)], transcripts=trc, transcript_lines=[hard])
assert [(x["kind"], x["count"]) for x in spans_of(d, "github-copilot")] == [("rate-limit", 1)], spans_of(d)
# no throttle anywhere: no spans, honest note (no invented Copilot throttle)
d = run("throttle-none", [ev(30)], transcripts=trc)
assert d["throttle_spans"] == [] and "no Copilot throttle data" in d["throttle_notes"]["github-copilot"], d["throttle_notes"]
# EnMaaS quota 429 (until next UTC month) overlapping a Copilot retry chain: two providers, two spans, overlapping in time
d = run("throttle-overlap", [ev(30, port="4147", requested="gpt-6-luna", served="gpt-6-luna"), err(400, 429, quota=True, error="Monthly token budget exhausted")], transcripts=trq,
        transcript_lines=[apierr(300, 429, retry_ms=240000), apierr(250, 429, attempt=2, retry_ms=270000)])
em, co = spans_of(d, "enmaas")[0], spans_of(d, "github-copilot")[0]
assert em["kind"] == "quota" and em["end_estimated"] and em["active"] and co["active"] and co["kind"] == "rate-limit", (em, co)
assert secs(em["start"]) < secs(co["start"]) < secs(em["end"]) and secs(co["end"]) < secs(em["end"]), (em, co)
# success ends a span (same provider + model); an unrelated model's success does not; repeated 429s inside one span merge
d = run("throttle-success", [err(300, 429, retry_after=3000), ev(200)])
(sp,) = spans_of(d)
assert not sp["end_estimated"] and abs(secs(sp["end"]) - (epoch - 200)) < 3 and not sp["active"] and sp["provider"] == "enmaas" and sp["count"] == 1, sp
d = run("throttle-other-model", [err(300, 429, retry_after=3000), ev(200, requested=DS, served=DS)])
(sp,) = spans_of(d)
assert sp["end_estimated"] and sp["active"], sp
d = run("throttle-merge", [err(300, 429, retry_after=3000), err(200, 429, retry_after=3000), err(100, 429, retry_after=3000)])
(sp,) = spans_of(d)
assert sp["count"] == 3 and sp["basis"] == "retry_after" and abs(secs(sp["end"]) - (epoch - 100 + 3000)) < 3, sp
# different proxies = different providers: two spans, one per provider
d = run("throttle-two-providers", [err(300, 429, retry_after=900, port="4142", requested=SON, served=SON), err(200, 429, retry_after=900)])
assert sorted(x["provider"] for x in spans_of(d)) == ["enmaas", "vertex"], spans_of(d)
# quota vs rate-limit stay separate kinds even on one provider
d = run("throttle-kinds", [err(300, 429, retry_after=900), err(250, 429, quota=True, error="token budget exhausted", requested=DS, served=DS)])
assert sorted(x["kind"] for x in spans_of(d)) == ["quota", "rate-limit"], spans_of(d)
# expired span (reset an hour+ ago, no success) is not reported; throwaway ports never appear
assert run("throttle-expired-spans", [err(7200, 429, retry_after=60), ev(30)])["throttle_spans"] == []
assert run("throttle-adhoc", [err(100, 429, port="4157", retry_after=300), ev(30)])["throttle_spans"] == []
# upstream-reported reset (logger fields reset_at + reset_source): not an estimate; the estimate sources stay estimates
d = run("throttle-upstream", [err(60, 429, retry_after=30, reset_at=epoch + 900, reset_source="upstream-header:retry-after")])
t = d["throttled"]
assert t["reset_source"] == "upstream-header:retry-after" and t["estimated"] is False and 880 <= t["seconds_left"] <= 905, t
(sp,) = spans_of(d)
assert sp["end_estimated"] is False and sp["reset_source"] == "upstream-header:retry-after" and sp["basis"] == "upstream-header:retry-after", sp
d = run("throttle-estimate-source", [err(60, 429, quota=True, reset_at=epoch + 5000, reset_source="estimate:next-month-utc")])
assert d["throttled"]["estimated"] is True and spans_of(d)[0]["end_estimated"] is True, d["throttled"]
# logger drift notes: deduplicated per (kind, detail, hint, proxy), counted, newest first; absent field = []
dr = {"kind": "unhandled_header", "detail": "x-new-reset", "hint": "parse x-new-reset in hosted_only_hooks.py"}
d = run("drift", [ev(100, drift=[dr]), ev(50, drift=[dr, {"kind": "shape_changed", "detail": "error.type", "hint": "update the 429 body shape check"}]),
                  ev(40, port="4147", drift=[dr]), ev(8 * 86400, drift=[{"kind": "estimate_mismatch", "detail": "old", "hint": "too old"}]),
                  ev(30, drift="not a list"), ev(20, drift=[{"kind": "x"}])])
assert d["drift"][0]["proxy"] == "codex-hosted-only", "newest first"
assert sorted((x["kind"], x["detail"], x["count"], x["proxy"]) for x in d["drift"]) == [
    ("shape_changed", "error.type", 1, "claude-hosted-only"), ("unhandled_header", "x-new-reset", 1, "codex-hosted-only"),
    ("unhandled_header", "x-new-reset", 2, "claude-hosted-only")], d["drift"]
assert all(x["hint"] and x["last_seen"].endswith("Z") for x in d["drift"]), d["drift"]
assert run("drift-none", [ev(30)])["drift"] == []
# series_by_provider: per-minute requests per provider (named proxies + Copilot transcripts), 60 buckets
d = run("series-providers", [ev(30), ev(40), ev(300, port="4142", requested=SON, served=SON), ev(1200, port="4147", requested="gpt-6-luna", served="gpt-6-luna")], transcripts=trc)
sbp = d["series_by_provider"]
rows = {r["key"]: r for r in sbp["providers"]}
assert sbp["bucket_s"] == 60 and set(rows) == {"enmaas", "vertex", "github-copilot"}, rows.keys()
assert all(len(r["requests"]) == 60 for r in rows.values()) and sum(rows["enmaas"]["requests"]) == 3 and sum(rows["github-copilot"]["requests"]) == 3, rows
assert rows["enmaas"]["label"] == "EnMaaS" and [r["key"] for r in sbp["providers"]][-1] == "vertex", sbp["providers"]
assert sum(sum(v) for v in d["series"]["by_vendor"].values()) == 7, d["series"]["by_vendor"]

# copilot quota used up (copilot-api /usage): premium + 5Hour/Weekly session limits become quota spans with GitHub's reset
copilot_server["doc"] = {"copilot_plan": "enterprise", "quota_reset_date": "2999-11-01",
    "quota_snapshots": {"premium_interactions": {"unlimited": False, "remaining": 0, "entitlement": 300, "percent_remaining": 0.0},
                        "5Hour-Session-RateLimits": {"percent_remaining": 0, "reset_date": "2999-10-30T05:00:00Z", "entitlement": 100},
                        "Weekly-Session-RateLimits": {"percent_remaining": 40, "reset_date": "2999-11-03T00:00:00Z"}}}
d = run("throttle-quota-usage", [ev(30)], transcripts=trq, extra_env={"LLM_USAGE_COPILOT_URL": url})
qs = spans_of(d, "github-copilot")
assert sorted(x["basis"] for x in qs) == ["copilot-api /usage: 5Hour-Session-RateLimits used up", "copilot-api /usage: premium interactions used up"], qs
assert all(x["kind"] == "quota" and x["source"] == "quota" and not x["end_estimated"] and x["start_estimated"] and x["active"] for x in qs), qs
assert {x["end"] for x in qs} == {"2999-11-02T00:00:00Z", "2999-10-30T05:00:00Z"}, qs  # bare date resets at the end of that UTC day
assert d["copilot"]["quota"]["limits"][1]["percent_remaining"] == 40, d["copilot"]["quota"]
# a 402 seen in a transcript lasts until GitHub's reset when /usage knows it
copilot_server["doc"] = {"quota_reset_date": "2999-11-01", "quota_snapshots": {"premium_interactions": {"unlimited": False, "remaining": 5, "entitlement": 300, "percent_remaining": 2}}}
d = run("throttle-402-reset", [ev(30)], transcripts=trq, transcript_lines=[apierr(100, 402, "premium requests exhausted")], extra_env={"LLM_USAGE_COPILOT_URL": url})
(cs,) = spans_of(d, "github-copilot")
assert cs["kind"] == "quota" and not cs["end_estimated"] and cs["end"] == "2999-11-02T00:00:00Z" and cs["reset_source"], cs
srv.shutdown()

# traffic share (status-item logos): vendors from the served model, providers from the proxy port
d = run("share-single", [ev(30), ev(60)])
sh = d["share"]
assert sh["window"] == "15m" and sh["metric"] == "requests" and sh["total"] == 2, sh
assert [(m["key"], m["vendor"], m["share"], m["requests"]) for m in sh["models"]] == [("glm", "glm", 1.0, 2)], sh["models"]
assert [(p["key"], p["label"], p["share"]) for p in sh["providers"]] == [("enmaas", "EnMaaS", 1.0)], sh["providers"]
assert sh["models"][0]["models"] == ["glm-5.3"] and sh["models"][0]["tokens"] == 20, sh["models"]
mix = [ev(30), ev(40), ev(50), ev(60, port="4142", requested=SON, served=SON), ev(70, port="4142", requested=SON, served=SON),
       ev(80, port="4147", requested="gpt-6-luna", served="gpt-6-luna")]
d = run("share-mix", mix)
sh = d["share"]
assert [m["key"] for m in sh["models"]] == ["glm", "claude", "openai"], sh["models"]
assert abs(sum(m["share"] for m in sh["models"]) - 1) < 1e-3 and abs(sum(p["share"] for p in sh["providers"]) - 1) < 1e-3, sh
assert [round(m["share"], 3) for m in sh["models"]] == [0.5, 0.333, 0.167], sh["models"]
assert [(p["key"], round(p["share"], 3)) for p in sh["providers"]] == [("enmaas", 0.667), ("vertex", 0.333)], sh["providers"]
# window / metric flags; events older than the window drop out, and an all-zero-token window falls back to requests
d = run("share-1h", [ev(30), ev(1800, port="4142", requested=SON, served=SON)], cli=["--share-window", "1h"])
assert d["share"]["window"] == "1h" and {m["key"] for m in d["share"]["models"]} == {"glm", "claude"}, d["share"]
assert [m["key"] for m in run("share-15m", [ev(30), ev(1800, port="4142", requested=SON, served=SON)])["share"]["models"]] == ["glm"]
tok = [ev(30, **{"in": 10, "out": 0}), ev(40, port="4142", requested=SON, served=SON, **{"in": 90, "out": 0})]
d = run("share-tokens", tok, cli=["--share-metric", "tokens"])
assert d["share"]["metric"] == "tokens" and [(m["key"], m["share"]) for m in d["share"]["models"]] == [("claude", 0.9), ("glm", 0.1)], d["share"]
assert run("share-requests", tok)["share"]["models"][0]["share"] == 0.5
d = run("share-tokens-none", [ev(30, **{"in": 0, "out": 0})], cli=["--share-metric", "tokens"])
assert d["share"]["metric"] == "requests" and d["share"]["metric_requested"] == "tokens", d["share"]
# copilot transcript calls (models absent from the proxy log) are attributed to github-copilot
d = run("share-copilot", [ev(30)], transcripts=tr)
sh = d["share"]
assert [(m["key"], m["requests"]) for m in sh["models"]] == [("claude", 2), ("glm", 1)], sh["models"]
assert [(p["key"], p["label"], p["requests"]) for p in sh["providers"]] == [("github-copilot", "GitHub Copilot", 2), ("enmaas", "EnMaaS", 1)], sh["providers"]
# idle: nothing in the window -> empty clusters, not an error
sh = run("share-idle", [])["share"]
assert sh["models"] == [] and sh["providers"] == [] and sh["total"] == 0, sh
# unknown model family -> other
sh = run("share-unknown", [ev(30, requested="mistral-large", served="mistral-large")])["share"]
assert [(m["key"], m["label"]) for m in sh["models"]] == [("other", "Other")], sh["models"]
# LLM_USAGE_PROVIDER_MAP: port or proxy name -> logo key[:label]; unmapped named ports keep the built-in table
d = run("share-provider-map", [ev(30), ev(40, port="4147"), ev(50, port="4142")],
        extra_env={"LLM_USAGE_PROVIDER_MAP": "4148=anthropic,codex-hosted-only=mine:My Proxy"})
assert {p["key"]: p["label"] for p in d["share"]["providers"]} == {"anthropic": "Anthropic", "mine": "My Proxy", "vertex": "Vertex AI"}, d["share"]["providers"]
# only the named proxies count: a throwaway test proxy on an ad-hoc port is not part of the share
assert run("share-adhoc", [ev(30, port="4999")])["share"]["total"] == 0

# in-flight tracking in the proxy logger (stub litellm so it runs without the proxy venv)
state = tempfile.mkdtemp(dir=tmp)
os.environ["LLM_USAGE_DIR"] = state
sys.path.insert(0, os.path.join(os.path.dirname(usage)))
import types, time
for name in ("litellm", "litellm.integrations", "litellm.integrations.custom_logger"):
    sys.modules[name] = types.ModuleType(name)
sys.modules["litellm"].callbacks = []
class CustomLogger:
    def __init__(self, *a, **k): pass
sys.modules["litellm.integrations.custom_logger"].CustomLogger = CustomLogger
sys.argv = ["litellm", "--port", "4999"]
import litellm_usage_log as u
dead_file = f"{state}/inflight-4999-{dead.pid}.json"
open(dead_file, "w").write("{}")
log = u.UsageLog()
assert not os.path.exists(dead_file), "dead-pid in-flight file of this port must be cleaned at startup"
path = f"{state}/inflight-4999-{os.getpid()}.json"
kw = {"litellm_call_id": "call-1", "litellm_params": {"metadata": {"model_group": "claude-sonnet-5-5"}}}
log.log_pre_api_call("glm", [], kw)
log.log_pre_api_call("glm", [], {"litellm_call_id": "call-2"})
doc = json.load(open(path))
assert set(doc["requests"]) == {"call-1", "call-2"} and doc["requests"]["call-1"]["requested"] == "claude-sonnet-5-5" and doc["pid"] == os.getpid(), doc
assert oct(os.stat(path).st_mode & 0o777) == "0o600"
log.log_success_event({"litellm_call_id": "call-1", "model": "glm"}, None, now, now)
assert set(json.load(open(path))["requests"]) == {"call-2"}, "success must clear the id"
log.log_failure_event({"standard_logging_object": {"id": "call-2"}, "model": "glm"}, None, now, now)
assert json.load(open(path))["requests"] == {}, "failure (id from standard_logging_object) must clear the id"
log._inflight["old"] = {"t": time.time() - u.INFLIGHT_STALE_S - 5, "model": "glm", "requested": "glm"}
log.log_pre_api_call("glm", [], {"litellm_call_id": "call-3"})
assert set(json.load(open(path))["requests"]) == {"call-3"}, "entries older than the stale limit are pruned on write"
log.log_pre_api_call("glm", [], None)  # malformed hook args never raise
PY

# Swift helper: compiles, and --dump-menu renders every scenario without a GUI.
if [[ -x /usr/bin/swiftc ]] || command -v swiftc >/dev/null; then
    local mbdir="$tmp/mbbin"
    LLM_USAGE_MENUBAR_DIR="$mbdir" $usage menubar build >/dev/null || fail "swiftc build of llm-usage-menubar"
    local mb="$mbdir/llm-usage-menubar" dump
    [[ -x "$mb" ]] || fail "menubar binary missing"
    LLM_USAGE_MENUBAR_DIR="$mbdir" $usage menubar build | grep -q "up to date" || fail "menubar rebuilt although source is unchanged"
    dump_of() { "$mb" --dump-menu --data-file "$mbjson/$1.json" "${@:2}"; }
    dump=$(dump_of normal)
    [[ "$dump" == "title: ● 4"$'\n'* ]] || fail "normal title: ${dump%%$'\n'*}"
    [[ "$dump" == *"PROXIES (15m / 1h)"* && "$dump" == *"claude-hosted-only :4148  up"* && "$dump" == *"Copy restart command: claude-hosted-only-restart"* ]] || fail "proxy rows/submenu missing: $dump"
    [[ "$dump" == *"[chart] requests/min"* && "$dump" == *"[chart] by model"* && "$dump" == *"[chart] by proxy"* ]] || fail "charts missing: $dump"
    [[ "$(dump_of normal --no-charts)" != *"[chart]"* && "$(dump_of normal --no-charts)" == *"Top models (1h): glm-5.3"* ]] || fail "--no-charts"
    [[ "$dump" == *"Open dashboard"* && "$dump" == *"Open logs folder"* && "$dump" == *"Refresh now"* && "$dump" == *"Copy status"* && "$dump" == *"Copy last error"* && "$dump" == *Quit* ]] || fail "actions missing"
    [[ "$dump" == *"Notifications"* && "$dump" == *"Launch at login"* ]] || fail "toggles/login row missing"
    [[ "$dump" == *"REROUTES (1h)"*"none"* ]] || fail "no-reroute row: $dump"
    dump=$(dump_of throttled)
    [[ "${dump%%$'\n'*}" == "title: ⚠ 429 5m" ]] || fail "throttled title: ${dump%%$'\n'*}"
    [[ "$dump" == *THROTTLED* && "$dump" == *"resets in 4m"* && "$dump" == *"ESTIMATE"* ]] || fail "throttled section: $dump"
    [[ "$(dump_of quota | head -1)" == "title: ⚠ 429 "[0-9]*d ]] || fail "quota title: $(dump_of quota | head -1)"
    [[ "$(dump_of quota)" == *"assumed next UTC month start"* ]] || fail "quota estimate label"
    [[ "$(dump_of spike | head -1)" == "title: ⚠ spike" ]] || fail "spike title: $(dump_of spike | head -1)"
    [[ "$(dump_of spike)" == *"Error spike"* ]] || fail "spike warning row"
    [[ "$(dump_of down | head -1)" == "title: ✖" ]] || fail "down title: $(dump_of down | head -1)"
    [[ "$(dump_of down)" == *"DOWN"* ]] || fail "down row"
    [[ "$(dump_of empty | head -1)" == "title: ● 0" && "$(dump_of empty)" == *"Last error: none logged"* ]] || fail "empty title/menu: $(dump_of empty | head -3)"
    [[ "$(dump_of old | head -1)" == "title: ⚠ 429 "* ]] || fail "old-events title: $(dump_of old | head -1)"
    dump=$(dump_of inflight)
    [[ "${dump%%$'\n'*}" == "title: ● 1 ⏳4" ]] || fail "in-flight title: ${dump%%$'\n'*}"
    [[ "$dump" == *"4 in flight · oldest glm-5.3 waiting"* ]] || fail "in-flight row: $dump"
    [[ "$(dump_of normal)" == *"n/a · no proxy reports in-flight"* ]] || fail "in-flight n/a row"
    dump=$(dump_of reroute-alias)
    [[ "${dump%%$'\n'*}" == "title: ● 4 ↪3" ]] || fail "reroute title: ${dump%%$'\n'*}"
    [[ "$dump" == *"sonnet→glm-5.3 ×2 alias"* && "$dump" == *"sonnet→deepseek-v4.1-flash ×1 alias"* ]] || fail "alias rows: $dump"
    [[ "$(dump_of reroute-vision)" == *"glm-5.3→deepseek-v4.1-flash ×1 vision"* ]] || fail "vision row"
    [[ "$(dump_of reroute-fallback)" == *"fallback 2"* ]] || fail "fallback row"
    dump=$(dump_of copilot-quota)
    [[ "$dump" == *"COPILOT-API (:4141) · TRANSCRIPT-DERIVED"* && "$dump" == *"premium: 120/300 left (40%)"* && "$dump" == *"resets 2026-11-01"* && "$dump" == *"in flight: n/a"* ]] || fail "copilot section: $dump"
    [[ "$(dump_of copilot-unlimited)" == *"premium: unlimited · 301.6k credits used"* ]] || fail "copilot unlimited row"
    [[ "$(dump_of copilot-noquota)" == *"quota: unavailable"* ]] || fail "copilot no-endpoint row"
    # traffic share: section, toggles, status-item image (light/dark PNGs at @2x), logo resolution
    dump=$(dump_of share-mix)
    [[ "$dump" == *"TRAFFIC SHARE (15m · requests)"* && "$dump" == *"Models"* && "$dump" == *"Providers"* ]] || fail "share section: $dump"
    [[ "$dump" == *"GLM "*"50%  3 req"* && "$dump" == *"Claude "*"33%  2 req"* && "$dump" == *"GPT "*"17%  1 req"* ]] || fail "share model rows: $dump"
    [[ "$dump" == *"EnMaaS "*"67%  4 req"* && "$dump" == *"Vertex AI "*"33%  2 req"* ]] || fail "share provider rows: $dump"
    [[ "$dump" == *"[x] Show logo image in menubar"* && "$dump" == *"[x] Show text next to the image"* \
        && "$dump" == *"[ ] Show 1h traffic window"* && "$dump" == *"[ ] Show tokens as traffic metric"* ]] || fail "share toggles: $dump"
    [[ "$(dump_of share-1h)" == *"TRAFFIC SHARE (1h · requests)"* && "$(dump_of share-1h)" == *"[x] Show 1h traffic window"* ]] || fail "1h toggle state"
    [[ "$(dump_of share-tokens)" == *"TRAFFIC SHARE (15m · tokens)"* && "$(dump_of share-tokens)" == *"[x] Show tokens as traffic metric"* ]] || fail "tokens toggle state"
    [[ "$(dump_of share-idle)" == *"idle: no traffic in the window"* ]] || fail "idle share row"
    [[ "$(dump_of share-tokens-none)" == *"no token counts in this window: showing requests"* ]] || fail "tokens fallback note"
    [[ "$(dump_of share-mix --no-image)" == *"[ ] Show logo image in menubar"* && "$(dump_of share-mix --no-text)" == *"[ ] Show text next to the image"* ]] || fail "image/text toggle flags"
    local png w h
    for png in share-mix share-single share-idle share-copilot throttled spike; do
        "$mb" --status-png "$tmp/$png-light.png" --data-file "$mbjson/$png.json" >/dev/null || fail "status-png light $png"
        "$mb" --status-png "$tmp/$png-dark.png" --dark --data-file "$mbjson/$png.json" >/dev/null || fail "status-png dark $png"
        read w h <<<"$(python3 -I -c 'import struct,sys;d=open(sys.argv[1],"rb").read(24);assert d[:8]==b"\x89PNG\r\n\x1a\n";print(*struct.unpack(">II",d[16:24]))' "$tmp/$png-light.png")" || fail "status-png $png not a PNG"
        (( w >= 100 && h == 48 )) || fail "status-png $png size ${w}x${h} (want @2x: height 48)"
        cmp -s "$tmp/$png-light.png" "$tmp/$png-dark.png" && fail "status-png $png: light and dark renders are identical"
    done
    [[ "$("$mb" --status-png "$tmp/x.png" --data-file "$mbjson/share-mix.json" | tail -1)" == *"Models: GLM 50%, Claude 33%, GPT 17% · Providers: EnMaaS 67%, Vertex AI 33%"* ]] || fail "status-png description"
    "$mb" --status-png "$tmp/notext.png" --no-text --data-file "$mbjson/share-single.json" >/dev/null
    [[ "$(stat -f %z "$tmp/notext.png")" != "$(stat -f %z "$tmp/share-single-light.png")" ]] || fail "--no-text should change the render"
    [[ "$("$mb" --status-png "$tmp/x.png" --data-file "$mbjson/throttled.json" | head -1)" == *'state=throttled text="429 '* ]] || fail "throttled status-png state/text"
    "$mb" --status-png "$tmp/bad.png" --data-file "$tmp/bad.json" 2>/dev/null && fail "status-png on invalid JSON should exit non-zero"
    # floating window: menu items (state flags for the persisted choices), throttle spans/drift rows, headless PNGs per layout
    dump=$(dump_of normal)
    [[ "$dump" == *"[ ] Floating Window"* && "$dump" == *"Window Layout"*"[x] Horizontal"*"[ ] Vertical"*"[ ] History"* \
        && "$dump" == *"Window Graph"*"[ ] Bars = models"*"[ ] Lines = providers"*"[x] Both"* \
        && "$dump" == *"Window Opacity"*"[x] 100%"*"[ ] 80%"*"[ ] 60%"*"[ ] 40%"* && "$dump" == *"[ ] Window Click-through"* ]] || fail "window menu items: $dump"
    dump=$(dump_of normal --window-visible --window-layout vertical --window-graph lines --window-opacity 0.6 --window-click-through)
    [[ "$dump" == *"[x] Floating Window"* && "$dump" == *"[x] Vertical"* && "$dump" == *"[ ] Horizontal"* && "$dump" == *"[x] Lines = providers"* \
        && "$dump" == *"[x] 60%"* && "$dump" == *"[ ] 100%"* && "$dump" == *"[x] Window Click-through"* ]] || fail "window menu state flags: $dump"
    dump=$(dump_of throttle-overlap)
    [[ "$dump" == *"THROTTLE SPANS (last 1h)"* && "$dump" == *"EnMaaS · quota · since"*"(est.)"* && "$dump" == *"GitHub Copilot · rate-limit · ×2"*"[transcript-derived]"* ]] || fail "throttle span rows: $dump"
    dump=$(dump_of throttle-copilot-quota)
    [[ "$dump" == *"GitHub Copilot · quota"*"[transcript-derived]"* ]] || fail "copilot quota span row: $dump"
    dump=$(dump_of throttle-quota-usage)
    [[ "$dump" == *"GitHub Copilot · quota"*"[copilot-api /usage]"* && "$dump" != *"[transcript-derived]"* ]] || fail "copilot /usage quota rows: $dump"
    [[ "$(dump_of throttle-none)" == *"THROTTLE SPANS"*"no Copilot throttle data"* ]] || fail "honest no-data note"
    [[ "$(dump_of throttle-none)" != *"THROTTLED"* ]] || fail "no throttle: no THROTTLED section"
    dump=$(dump_of drift)
    [[ "$dump" == *"⚠ code needs updating: parse x-new-reset in hosted_only_hooks.py  (×2)"* && "$dump" == *"update the 429 body shape check"* && "$dump" == *"click to copy the hint"* ]] || fail "drift rows: $dump"
    [[ "$(dump_of normal)" != *"code needs updating"* ]] || fail "no drift field -> no drift row"
    dump=$(dump_of throttle-upstream)
    [[ "$dump" == *THROTTLED* && "$dump" == *"reset reported by upstream (upstream-header:retry-after)"* && "$dump" != *ESTIMATE* ]] || fail "upstream reset: no ESTIMATE label: $dump"
    [[ "$(dump_of throttle-estimate-source)" == *"ESTIMATE ·"* ]] || fail "estimate:* reset_source keeps the ESTIMATE label"
    [[ "$(dump_of throttled)" == *"ESTIMATE ·"* ]] || fail "legacy events (no reset_source) stay estimates"
    local layout
    local -A sizes=(horizontal 220x120 vertical 120x260 history 220x84)
    for png in throttle-overlap throttle-copilot throttle-copilot-quota throttle-none throttle-upstream empty spike; do
        for layout in horizontal vertical history; do
            "$mb" --window-png "$tmp/win-$png-$layout-light.png" --layout $layout --size ${sizes[$layout]} --data-file "$mbjson/$png.json" >/dev/null || fail "window-png light $png $layout"
            "$mb" --window-png "$tmp/win-$png-$layout-dark.png" --dark --layout $layout --size ${sizes[$layout]} --data-file "$mbjson/$png.json" >/dev/null || fail "window-png dark $png $layout"
            read w h <<<"$(python3 -I -c 'import struct,sys;d=open(sys.argv[1],"rb").read(24);assert d[:8]==b"\x89PNG\r\n\x1a\n";print(*struct.unpack(">II",d[16:24]))' "$tmp/win-$png-$layout-light.png")" || fail "window-png $png $layout not a PNG"
            [[ "${w}x${h}" == "$(python3 -c 'import sys;a,b=sys.argv[1].split("x");print(f"{int(a)*2}x{int(b)*2}")' ${sizes[$layout]})" ]] || fail "window-png $png $layout size ${w}x${h}"
            cmp -s "$tmp/win-$png-$layout-light.png" "$tmp/win-$png-$layout-dark.png" && fail "window-png $png $layout: light and dark renders are identical"
        done
    done
    # throttle ribbons change the picture; graph modes differ; stale dims; default size/layout come out right
    cmp -s "$tmp/win-throttle-none-horizontal-light.png" "$tmp/win-throttle-overlap-horizontal-light.png" && fail "throttle spans did not change the render"
    "$mb" --window-png "$tmp/g-bars.png" --graph bars --data-file "$mbjson/throttle-overlap.json" >/dev/null
    "$mb" --window-png "$tmp/g-lines.png" --graph lines --data-file "$mbjson/throttle-overlap.json" >/dev/null
    "$mb" --window-png "$tmp/g-both.png" --graph both --data-file "$mbjson/throttle-overlap.json" >/dev/null
    cmp -s "$tmp/g-bars.png" "$tmp/g-lines.png" && fail "graph modes bars/lines render identically"
    cmp -s "$tmp/g-both.png" "$tmp/g-bars.png" && fail "graph modes both/bars render identically"
    "$mb" --window-png "$tmp/stale.png" --stale --data-file "$mbjson/throttle-overlap.json" >/dev/null
    cmp -s "$tmp/stale.png" "$tmp/g-both.png" && fail "--stale should dim the window"
    print -r -- 'not json' > "$tmp/bad.json"
    "$mb" --window-png "$tmp/bad-win.png" --data-file "$tmp/bad.json" 2>/dev/null && fail "window-png on invalid JSON should exit non-zero"
    # bad / missing data: error row, non-zero exit, no crash
    print -r -- 'not json' > "$tmp/bad.json"
    dump=$("$mb" --dump-menu --data-file "$tmp/bad.json") && fail "invalid JSON should exit non-zero"
    [[ "$dump" == "title: ?"* && "$dump" == *"poll failed"* && "$dump" == *Quit* ]] || fail "error menu: $dump"
    # single instance: a second helper exits at once while the first holds the lock (perl alarm = hang guard)
    local lockdir="$tmp/lock"; mkdir -p "$lockdir"
    python3 -c 'import fcntl,os,sys,time
fd=os.open(sys.argv[1]+"/menubar.lock",os.O_RDWR|os.O_CREAT,0o600);fcntl.flock(fd,fcntl.LOCK_EX);open(sys.argv[1]+"/ready","w").close();time.sleep(4)' "$lockdir" &
    local holder=$!
    local i; for i in {1..40}; do [[ -e "$lockdir/ready" ]] && break; sleep 0.1; done
    [[ "$(LLM_USAGE_DIR=$lockdir perl -e 'alarm 8; exec @ARGV' $mb 2>&1)" == *"already running"* ]] || { kill $holder 2>/dev/null; fail "second instance not refused"; }
    LLM_USAGE_DIR=$lockdir $usage menubar window show | grep -q "window show sent" && [[ "$(<$lockdir/menubar-window.cmd)" == show ]] || { kill $holder 2>/dev/null; fail "menubar window show did not write the command file"; }
    LLM_USAGE_DIR=$lockdir $usage menubar window | grep -q "window toggle sent" && [[ "$(<$lockdir/menubar-window.cmd)" == toggle ]] || { kill $holder 2>/dev/null; fail "menubar window default toggle"; }
    LLM_USAGE_DIR=$lockdir $usage menubar window bogus 2>/dev/null && { kill $holder 2>/dev/null; fail "bad window action must fail"; }
    kill $holder 2>/dev/null
else
    print -r -- "swiftc not found: skipping llm-usage-menubar compile/dump checks"
fi

# Logos: never in the repo; `menubar logos fetch` pins a commit + per-file sha256 (tests use local fixture PNGs, no network).
local notices="$repo/THIRD_PARTY_NOTICES.md" logo_sha logo_repo
logo_sha=$(sed -n 's/^LOGO_SHA = "\([0-9a-f]\{40\}\)"$/\1/p' "$usage")
logo_repo=$(sed -n 's/^LOGO_REPO = "\(.*\)"$/\1/p' "$usage")
[[ ${#logo_sha} == 40 && -n "$logo_repo" ]] || fail "LOGO_SHA / LOGO_REPO not found in llm-usage"
[[ -f "$notices" ]] || fail "THIRD_PARTY_NOTICES.md missing"
[[ "$(<$notices)" == *"https://github.com/$logo_repo"* && "$(<$notices)" == *"$logo_sha"* ]] || fail "THIRD_PARTY_NOTICES.md lacks the repo URL / pinned commit of llm-usage ($logo_repo @ $logo_sha)"
[[ "$(<$notices)" == *"MIT License"* && "$(<$notices)" == *"Copyright (c) 2023 LobeHub"* && "$(<$notices)" == *"trademarks"* ]] || fail "THIRD_PARTY_NOTICES.md lacks the license text / trademark note"
[[ "$(<$repo/README.md)" == *"THIRD_PARTY_NOTICES.md"* ]] || fail "README must credit the logo source and link THIRD_PARTY_NOTICES.md"
[[ -z "$(find "$repo/scripts" \( -name "*.png" -o -name "*.svg" \) -print)" ]] || fail "logo image files must not be committed under scripts/"
local logofix="$tmp/logo-fixture" lbase="$tmp/logo-menubar"
mkdir -p "$logofix/packages/static-png/light" "$lbase"
python3 -I - "$usage" "$logofix" <<'PYFIX' || fail "logo fixture"
import re, struct, sys, zlib
src = open(sys.argv[1]).read()
def png(rgba, n=8):
    raw = b"".join(b"\x00" + bytes(rgba) * n for _ in range(n))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
files = re.findall(r'^    "[a-z-]+": \("([a-z-]+)", (?:True|False), "[0-9a-f]{64}"\),$', src, re.M)
assert len(files) >= 8, files
for f in files:
    open(f"{sys.argv[2]}/packages/static-png/light/{f}.png", "wb").write(png((200, 100, 50, 255)))
open(f"{sys.argv[2]}/LICENSE", "w").write("MIT License\n\nCopyright (c) 2023 LobeHub\n")
PYFIX
out=$(LLM_USAGE_MENUBAR_DIR="$lbase" $usage menubar logos fetch --from-dir "$logofix" 2>&1) && fail "fetch of unpinned files must fail the sha256 check: $out"
[[ "$out" == *"sha256 mismatch"*"nothing written"* && ! -e "$lbase/logos" ]] || fail "sha mismatch handling: $out"
out=$(LLM_USAGE_MENUBAR_DIR="$lbase" $usage menubar logos fetch --from-dir "$logofix" --no-verify) || fail "logos fetch (fixture): $out"
[[ -f "$lbase/logos/claude.png" && -f "$lbase/logos/openai.mono.png" && -f "$lbase/logos/glm.mono.png" && -f "$lbase/logos/vertex.png" && ! -e "$lbase/logos/enmaas.png" ]] || fail "fetched files: $(ls $lbase/logos)"
[[ "$(<$lbase/logos/LICENSE)" == *"Copyright (c) 2023 LobeHub"* ]] || fail "LICENSE not copied next to the logos"
[[ "$(<$lbase/logos/SOURCES.md)" == *"https://github.com/$logo_repo"* && "$(<$lbase/logos/SOURCES.md)" == *"$logo_sha"* && "$(<$lbase/logos/SOURCES.md)" == *"MIT"* && "$(<$lbase/logos/SOURCES.md)" == *"trademarks"* ]] || fail "SOURCES.md incomplete"
if [[ -x /usr/bin/swiftc ]] || command -v swiftc >/dev/null; then
    local lcfg="$tmp/logo-cfg"; mkdir -p "$lcfg/logos" "$mbdir/logos"
    cp "$logofix/packages/static-png/light/claude-color.png" "$lcfg/logos/claude.png"
    cp "$logofix/packages/static-png/light/zai.png" "$lcfg/logos/deepseek.mono.png"
    cp "$lbase/logos/"*.png "$mbdir/logos/"  # the fetched dir lives next to the built binary
    out=$(LLM_USAGE_MENUBAR_DIR="$mbdir" LLM_USAGE_CONFIG_DIR="$lcfg" $usage menubar logos) || fail "menubar logos: $out"
    [[ "$out" == *"claude "*"color "*"user dir: $lcfg/logos/claude.png"* ]] || fail "user dir must win over fetched: $out"
    [[ "$out" == *"deepseek "*"mono "*"user dir (mono, tinted)"* ]] || fail "user mono logo: $out"
    [[ "$out" == *"openai "*"mono "*"fetched (mono, tinted): $mbdir/logos/openai.mono.png"* ]] || fail "fetched mono logo: $out"
    [[ "$out" == *"enmaas "*"monogram "*"generated monogram"* && "$out" == *"$lcfg/logos"* && "$out" == *"logos fetch"* ]] || fail "monogram / hints: $out"
    [[ "${out##*$'\n'}" == *"https://github.com/$logo_repo @ ${logo_sha[1,12]}"*"MIT"*"THIRD_PARTY_NOTICES.md"* ]] || fail "last line must credit the source: ${out##*$'\n'}"
    LLM_USAGE_MENUBAR_DIR="$mbdir" LLM_USAGE_CONFIG_DIR="$lcfg" "$mb" --status-png "$tmp/logo-render.png" --data-file "$mbjson/share-mix.json" >/dev/null || fail "status-png with logos"
    rm -rf "$mbdir/logos"
fi
# install/uninstall only describe themselves under --dry-run and never touch launchd
out=$($usage menubar install --dry-run)
[[ "$out" == *"RunAtLoad"*"<true/>"* && "$out" == *"com.kaovilai.llm-usage-menubar"* && "$out" == *"would run: launchctl bootstrap"* && "$out" == *"menubar.log"* ]] || fail "install --dry-run: $out"
[[ "$($usage menubar uninstall --dry-run)" == *"would run: launchctl bootout"* ]] || fail "uninstall --dry-run"
[[ "$(LLM_USAGE_MENUBAR_DIR=$tmp/none $usage menubar status)" == *"built:     no"* ]] || fail "menubar status"

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
    llm-proxy-restart required nope 2>/dev/null && { print -ru2 -- "FAIL: required: unknown target accepted"; exit 1; }

    # `required`: only listening proxies whose dry-run check says stale (or
    # whose listener fails its health check) restart; fresh ones stay; an
    # unanswerable check is reported and fails the command without restarting.
    _claude_listen_pids() { case "$1" in "${COPILOT_API_PORT:-4141}"|"${CLAUDE_OPENAI_PROXY_PORT:-4145}"|"$(_hosted_only_knob CODEX_PROXY_PORT 4147)"|"${CLAUDE_VERTEX_PROXY_PORT:-4142}") print 1 ;; esac; }
    _llm_proxy_check_copilot() { print fresh; }
    _llm_proxy_check_openai() { print "stale: hook code or knobs"; }
    _llm_proxy_check_glm_codex() { print down; }
    _llm_proxy_check_vertex() { print unknown; }
    _llm_proxy_check_enmaas() { print "FAIL: enmaas is not listening and must not be checked" >&2; print stale; }
    # the dispatcher runs inside $(...) below, so the stubs record to a file
    local log="$tmp/restarted"; : > "$log"
    restarted() { tr '\n' ' ' < "$log" | sed 's/ $//'; }
    claude-copilot-restart() { print -r -- copilot >> "$log"; }
    claude-openai-restart() { print -r -- openai >> "$log"; }
    codex-hosted-only-restart() { print -r -- glm-codex >> "$log"; }
    claude-vertex-restart() { print -r -- vertex >> "$log"; }
    claude-enmaas-restart() { print -r -- enmaas >> "$log"; }
    local out rc=0
    out=$(llm-proxy-restart required 2>&1) || rc=$?
    [[ "$rc" == 1 ]] || { print -ru2 -- "FAIL: required should fail when a check is unanswerable (rc=$rc): $out"; exit 1; }
    [[ "$(restarted)" == "openai glm-codex" ]] || { print -ru2 -- "FAIL: required restarted '$(restarted)', want 'openai glm-codex': $out"; exit 1; }
    [[ "$out" == *"copilot"*"up to date; left running"* && "$out" == *"openai"*"changed: hook code or knobs; restarting"* \
       && "$out" == *"glm-codex"*"health check; restarting"* && "$out" == *"vertex"*"could not be checked"* && "$out" != *FAIL* ]] || { print -ru2 -- "FAIL: required output: $out"; exit 1; }
    # explicit names: a non-listening one is skipped, not restarted
    : > "$log"
    out=$(llm-proxy-restart required enmaas openai 2>&1) || { print -ru2 -- "FAIL: required enmaas openai: $out"; exit 1; }
    [[ "$(restarted)" == openai && "$out" == *"enmaas"*"not running; skipped"* ]] || { print -ru2 -- "FAIL: required with names: '$(restarted)' $out"; exit 1; }
    # `required-on-idle`: stale proxies are cut only when no request is in
    # flight on their port; a proxy busy past the deadline is reported, not cut.
    : > "$log"
    typeset -gi serving_polls=0
    _claude_port_serving() { [[ "$1" == "${CLAUDE_OPENAI_PROXY_PORT:-4145}" ]] && (( ++serving_polls <= 3 )); }
    out=$(llm-proxy-restart required-on-idle openai glm-codex 2>&1) || { print -ru2 -- "FAIL: required-on-idle: $out"; exit 1; }
    [[ "$(restarted)" == "glm-codex openai" ]] || { print -ru2 -- "FAIL: on-idle restarted '$(restarted)', want 'glm-codex openai' (idle one first): $out"; exit 1; }
    [[ "$out" == *"openai"*"will restart at the next idle moment"* && "$out" == *"openai"*"waiting for an idle moment"* \
       && "$out" == *"openai"*"idle; restarting now"* && "$out" == *"glm-codex"*"idle; restarting now"* ]] || { print -ru2 -- "FAIL: on-idle output: $out"; exit 1; }
    : > "$log"
    _claude_port_serving() { [[ "$1" == "${CLAUDE_OPENAI_PROXY_PORT:-4145}" ]]; }   # never idle
    out=$(LLM_PROXY_RESTART_IDLE_TIMEOUT=1 llm-proxy-restart required-on-idle openai copilot 2>&1) && { print -ru2 -- "FAIL: busy past deadline must fail: $out"; exit 1; }
    [[ "$(restarted)" == "" && "$out" == *"openai"*"still serving requests at the deadline"*"not restarted"* && "$out" == *"copilot"*"up to date"* ]] || { print -ru2 -- "FAIL: deadline: '$(restarted)' $out"; exit 1; }
    _claude_port_serving() { return 1; }

    # `all` still restarts every listener without checking
    : > "$log"
    llm-proxy-restart all >/dev/null 2>&1
    [[ "$(restarted)" == "copilot vertex openai glm-codex" ]] || { print -ru2 -- "FAIL: all restarted '$(restarted)'"; exit 1; }
    exit 0
) || exit 1

# copilot records its fingerprint with the same inputs it compares against at
# launch; a narrower record formula made every launch see a stale gateway.
[[ "$(grep -cF 'cfp=$(_claude_proxy_fp "$(_claude_file_hash "${capi_data}/github_token" "${capi_data}/config.json" "$monitor")" "$port" "$plugins" "$monitor_dir")' "$repo/zsh/functions/claude/providers/copilot.zsh")" == 2 ]] \
    || fail "copilot launch-time and recorded fingerprints use different inputs"

# _claude_proxy_sync dry run (_CLAUDE_PROXY_SYNC_CHECK): verdict file, return 1, no kill.
(
    source "$repo/zsh/functions/claude/common.zsh" >/dev/null 2>&1
    export XDG_STATE_HOME="$tmp/sync-state"
    local verdict="$tmp/verdict" killed="$tmp/killed" port
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
    fakekill() { : > "$killed"; }
    export _CLAUDE_PROXY_SYNC_CHECK="$verdict"
    # nothing listening -> down
    _claude_proxy_sync t sync-test "http://127.0.0.1:$port/health" fp1 fakekill 1 && { print -ru2 -- "FAIL: dry run must return 1"; exit 1; }
    [[ "$(<"$verdict")" == down ]] || { print -ru2 -- "FAIL: down verdict: $(<"$verdict")"; exit 1; }
    python3 -c 'import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()' "$port" &
    local srv=$!
    for i in {1..50}; do curl -sf --max-time 1 "http://127.0.0.1:$port/health" -o /dev/null && break; sleep 0.1; done
    # running, no record: adopt=1 -> fresh, adopt=0 -> stale
    _claude_proxy_sync t sync-test "http://127.0.0.1:$port/health" fp1 fakekill 1; [[ "$(<"$verdict")" == fresh ]] || { kill $srv; print -ru2 -- "FAIL: adopt fresh: $(<"$verdict")"; exit 1; }
    _claude_proxy_sync t sync-test "http://127.0.0.1:$port/health" fp1 fakekill 0; [[ "$(<"$verdict")" == stale ]] || { kill $srv; print -ru2 -- "FAIL: no-record stale: $(<"$verdict")"; exit 1; }
    [[ ! -e "$XDG_STATE_HOME/claude-sync-test.fingerprint" ]] || { kill $srv; print -ru2 -- "FAIL: dry run recorded a fingerprint"; exit 1; }
    # recorded: same -> fresh, different -> stale; nothing killed either way
    _claude_proxy_record sync-test fp1
    _claude_proxy_sync t sync-test "http://127.0.0.1:$port/health" fp1 fakekill 1; [[ "$(<"$verdict")" == fresh ]] || { kill $srv; print -ru2 -- "FAIL: recorded fresh: $(<"$verdict")"; exit 1; }
    _claude_proxy_sync t sync-test "http://127.0.0.1:$port/health" fp2 fakekill 1; [[ "$(<"$verdict")" == stale ]] || { kill $srv; print -ru2 -- "FAIL: recorded stale: $(<"$verdict")"; exit 1; }
    [[ ! -e "$killed" ]] || { kill $srv; print -ru2 -- "FAIL: dry run killed the proxy"; exit 1; }
    # without the variable the live path still restarts a stale idle proxy
    unset _CLAUDE_PROXY_SYNC_CHECK
    _claude_proxy_sync t sync-test "http://127.0.0.1:$port/health" fp2 fakekill 1 2>/dev/null
    [[ -e "$killed" ]] || { kill $srv; print -ru2 -- "FAIL: live path did not restart the stale proxy"; exit 1; }
    kill $srv 2>/dev/null
    exit 0
) || exit 1

print -r -- "llm-usage tests passed"
