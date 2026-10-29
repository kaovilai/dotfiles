#!/bin/zsh
# Offline tests for scripts/hosted-only-proxy.zsh and scripts/hosted_only_hooks.py:
# generated config, hosted-only/legacy knob names, runtime dirs, stop-helper
# identity checks, retired-name aliases, and the hook helpers. No network, no
# real proxy (a stub process stands in for the listener).
emulate -LR zsh
setopt err_exit pipe_fail
local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { print -ru2 -- "FAIL: $*"; exit 1; }

export XDG_STATE_HOME="$tmp/state"
unset HOSTED_ONLY_CLAUDE_PROXY_PORT HOSTED_ONLY_CODEX_PROXY_PORT HOSTED_ONLY_GLM_MODEL HOSTED_ONLY_PROXY_TOKEN \
    GLM_HYBRID_CLAUDE_PROXY_PORT GLM_HYBRID_CODEX_PROXY_PORT GLM_HYBRID_MODEL GLM_HYBRID_PROXY_TOKEN
source "$repo/scripts/hosted-only-proxy.zsh"

# Defaults
_hosted_only_proxy_vars codex
[[ "$_hop_port" == 4147 && "$_hop_runtime" == "$tmp/state/hosted-only-codex-4147" ]] || fail "codex defaults: $_hop_port $_hop_runtime"
[[ "$_hop_legacy_runtime" == "$tmp/state/glm-hybrid-codex-4147" ]] || fail "legacy dir: $_hop_legacy_runtime"
[[ "$_hop_token" == hosted-only-local ]] || fail "token default: $_hop_token"
_hosted_only_proxy_vars claude
[[ "$_hop_port" == 4148 ]] || fail "claude port: $_hop_port"
_hosted_only_proxy_vars bogus 2>/dev/null && fail "bogus flavor accepted"

# Config: both models, hooks callback, no OpenAI/luna route, claude sonnet alias
local cfg
cfg=$(_hosted_only_proxy_config)
[[ "$cfg" == *'"anthropic/rits/zai-org/glm-5-3"'* && "$cfg" == *'DeepSeek-V4.1-Flash-1017'* ]] || fail "claude config lacks hosted models: $cfg"
[[ "$cfg" == *'hosted_only_hooks.proxy_handler_instance'* && "$cfg" == *'litellm_usage_log.proxy_handler_instance'* ]] || fail "callbacks missing"
[[ "$cfg" == *'os.environ/HOSTED_ONLY_PROXY_TOKEN'* && "$cfg" == *'claude-sonnet-5-5'* ]] || fail "claude config shape"
[[ "$cfg" != *luna* && "$cfg" != *OPENAI* && "$cfg" != *api.openai.com* ]] || fail "OpenAI route leaked into config"
_hosted_only_proxy_vars codex
cfg=$(_hosted_only_proxy_config)
[[ "$cfg" == *'"openai/rits/zai-org/glm-5-3"'* && "$cfg" == *'/v1"'* && "$cfg" != *claude-sonnet-5-5* ]] || fail "codex config shape: $cfg"

# LiteLLM upstream retries: router_settings.num_retries (default 0), knob changes config
[[ "$cfg" == *$'router_settings:\n  num_retries: 0'* ]] || fail "router retry setting missing: $cfg"
local cfg_retries
HOSTED_ONLY_UPSTREAM_RETRIES=2 _hosted_only_proxy_vars codex
cfg_retries=$(_hosted_only_proxy_config)
[[ "$cfg_retries" == *$'router_settings:\n  num_retries: 2'* && "$cfg_retries" != "$cfg" ]] || fail "HOSTED_ONLY_UPSTREAM_RETRIES not applied: $cfg_retries"
GLM_HYBRID_UPSTREAM_RETRIES=1 _hosted_only_proxy_vars codex
cfg_retries=$(_hosted_only_proxy_config)
[[ "$cfg_retries" == *'num_retries: 1'* ]] || fail "retired GLM_HYBRID_UPSTREAM_RETRIES ignored"
# knob is read in _hosted_only_proxy_vars and part of the fingerprint input
HOSTED_ONLY_UPSTREAM_RETRIES=5 _hosted_only_proxy_vars codex
[[ "$_hop_upstream_retries" == 5 ]] || fail "upstream retries var: $_hop_upstream_retries"
_hosted_only_proxy_vars codex
[[ "$_hop_upstream_retries" == 0 ]] || fail "upstream retries default: $_hop_upstream_retries"
[[ "$(<"$repo/scripts/hosted-only-proxy.zsh")" == *'$_hop_client_retry $_hop_upstream_retries $_hop_image_budget $_hop_image_cache_days"'* ]] || fail "upstream retries / image knobs not in fingerprint"
HOSTED_ONLY_IMAGE_BUDGET_BYTES=123 HOSTED_ONLY_IMAGE_CACHE_DAYS=2 _hosted_only_proxy_vars codex
[[ "$_hop_image_budget" == 123 && "$_hop_image_cache_days" == 2 ]] || fail "image knobs: $_hop_image_budget $_hop_image_cache_days"
_hosted_only_proxy_vars codex
[[ "$_hop_image_budget" == 8388608 && "$_hop_image_cache_days" == 5 ]] || fail "image knob defaults: $_hop_image_budget $_hop_image_cache_days"

# New knob names win; retired GLM_HYBRID_* names still work
HOSTED_ONLY_CODEX_PROXY_PORT=4157 _hosted_only_proxy_vars codex
[[ "$_hop_port" == 4157 && "$_hop_runtime" == *hosted-only-codex-4157 ]] || fail "HOSTED_ONLY port: $_hop_port"
GLM_HYBRID_CODEX_PROXY_PORT=4167 GLM_HYBRID_MODEL=rits/x/old GLM_HYBRID_PROXY_TOKEN=oldtok _hosted_only_proxy_vars codex
[[ "$_hop_port" == 4167 && "$_hop_glm" == rits/x/old && "$_hop_token" == oldtok ]] || fail "legacy knobs ignored: $_hop_port $_hop_glm $_hop_token"
GLM_HYBRID_CODEX_PROXY_PORT=4167 HOSTED_ONLY_CODEX_PROXY_PORT=4177 HOSTED_ONLY_GLM_MODEL=rits/x/new GLM_HYBRID_MODEL=rits/x/old _hosted_only_proxy_vars codex
[[ "$_hop_port" == 4177 && "$_hop_glm" == rits/x/new ]] || fail "new knob should beat legacy: $_hop_port $_hop_glm"

# Stop helper: kills a listener whose command line names the new OR the legacy
# config path, leaves foreign listeners alone.
local port=4197 base="$tmp/state"
export HOSTED_ONLY_CODEX_PROXY_PORT=$port
_hosted_only_proxy_vars codex
local dir pid i
for dir in "$_hop_runtime" "$_hop_legacy_runtime"; do
    mkdir -p "$dir"; : > "$dir/config.yaml"; print x > "$dir/fingerprint"
    python3 - "$port" "$dir/config.yaml" <<'EOF' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(60)
EOF
    pid=$!
    for i in {1..30}; do lsof -ti "tcp:$port" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.1; done
    _hosted_only_proxy_stop codex 2>/dev/null || fail "stop failed for $dir"
    for i in {1..30}; do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
    kill -0 $pid 2>/dev/null && { kill $pid; fail "listener under $dir survived stop"; }
    [[ ! -f "$dir/fingerprint" ]] || fail "fingerprint left in $dir"
    wait $pid 2>/dev/null || true
done
python3 -c 'import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1",'$port')); s.listen(); time.sleep(60)' &
pid=$!
for i in {1..30}; do lsof -ti "tcp:$port" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.1; done
if _hosted_only_proxy_stop codex 2>/dev/null; then kill $pid; fail "stop killed a foreign listener"; fi
kill -0 $pid 2>/dev/null || fail "foreign listener was killed"
kill $pid; wait $pid 2>/dev/null || true
unset HOSTED_ONLY_CODEX_PROXY_PORT

# Retired names stay defined
local fn
source "$repo/zsh/functions/claude/providers/hosted-only.zsh"
for fn in claude-hosted-only claude-glm-hybrid claude-glm-only claude-hosted-only-kill claude-glm-hybrid-kill claude-glm-only-kill; do
    (( $+functions[$fn] )) || fail "missing function $fn"
done
[[ "$(whence -f claude-glm-hybrid)" == *claude-hosted-only* ]] || fail "claude-glm-hybrid is not an alias of claude-hosted-only"

# Claude launcher: CLAUDE_CODE_MAX_RETRIES in settings env (default 3, knob override)
_hosted_only_proxy_ensure() { _hosted_only_proxy_vars "$1"; }
_claude_picker_args() { reply=(); }
_claude_copilot_unset_env() { :; }
_claude_invoke() { print -r -- "$2"; }
local launched
launched=$(_claude_hosted_launch) || fail "launcher stub run"
[[ "$(jq -r .env.CLAUDE_CODE_MAX_RETRIES <<< "$launched")" == 3 ]] || fail "CLAUDE_CODE_MAX_RETRIES default: $launched"
launched=$(HOSTED_ONLY_CLIENT_MAX_RETRIES=7 _claude_hosted_launch) || fail "launcher stub run (knob)"
[[ "$(jq -r .env.CLAUDE_CODE_MAX_RETRIES <<< "$launched")" == 7 ]] || fail "HOSTED_ONLY_CLIENT_MAX_RETRIES ignored: $launched"

# Hook helpers (python), including the retired env-name fallback
GLM_HYBRID_VISION_FALLBACK=0 GLM_HYBRID_MODEL=rits/x/old python3 -I - "$repo/scripts" <<'EOF' || fail "hook module"
import json, sys, time, types
sys.path.insert(0, sys.argv[1])
# stub the two third-party imports (litellm / fastapi are not installed here)
fa = types.ModuleType("fastapi")
class HTTPException(Exception):
    def __init__(self, status_code, detail=None, headers=None):
        self.status_code, self.detail, self.headers = status_code, detail, headers
fa.HTTPException = HTTPException
cl = types.ModuleType("litellm.integrations.custom_logger")
cl.CustomLogger = object
for name, mod in (("fastapi", fa), ("litellm", types.ModuleType("litellm")),
                  ("litellm.integrations", types.ModuleType("litellm.integrations")),
                  ("litellm.integrations.custom_logger", cl)):
    sys.modules[name] = mod
import hosted_only_hooks as h
assert h.GLM_MODEL == "rits/x/old", h.GLM_MODEL          # retired GLM_HYBRID_MODEL still read
assert h.VISION_FALLBACK is False                         # retired GLM_HYBRID_VISION_FALLBACK still read
assert h.has_image({"messages": [{"content": [{"type": "image"}]}]})
assert not h.has_image({"messages": [{"content": "hi"}]})
assert h.is_empty_instruction({"role": "developer", "content": [{"type": "input_text", "text": " "}]})
assert not h.is_empty_instruction({"role": "user", "content": ""})

# Image budget prune (item 6): oldest inline images -> path notes until the body fits
import base64, hashlib, os, tempfile
assert h.IMAGE_BUDGET_BYTES == 8 * 1024 * 1024 and h.IMAGE_CACHE_DAYS == 5
work = tempfile.mkdtemp()
cache_dir, att_dir = os.path.join(work, "cache"), os.path.join(work, "attachments")
os.mkdir(att_dir)
def png(seed, size=4000):
    return b"\x89PNG" + bytes([seed]) * size
imgs = [png(i) for i in range(4)]
b64 = [base64.b64encode(i).decode() for i in imgs]
# imgs[3] is a pasted T3 attachment (byte-identical file in the attachments dir)
with open(os.path.join(att_dir, "thread-att.png"), "wb") as f:
    f.write(imgs[3])
def data_url(s): return "data:image/png;base64," + s
def responses_req():
    return {"model": "rits/deepseek-ai/DeepSeek-V4.1-Flash-1017", "instructions": "sys", "input": [
        {"role": "user", "content": [{"type": "input_text", "text": "look"}]},
        {"type": "function_call", "name": "view_image", "call_id": "c1", "arguments": json.dumps({"path": "/tmp/slides/4.png"})},
        {"type": "function_call_output", "call_id": "c1", "output": [{"type": "input_image", "image_url": data_url(b64[0])}]},
        {"type": "function_call", "name": "view_image", "call_id": "c2", "arguments": json.dumps({"path": "/tmp/slides/5.png"})},
        {"type": "function_call_output", "call_id": "c2", "output": [{"type": "input_image", "image_url": data_url(b64[1])}]},
        {"type": "function_call", "name": "view_image", "call_id": "c3", "arguments": json.dumps({"path": "/tmp/slides/6.png"})},
        {"type": "function_call_output", "call_id": "c3", "output": [{"type": "input_image", "image_url": data_url(b64[2])}]},
        {"role": "user", "content": [{"type": "input_text", "text": "and this"}, {"type": "input_image", "image_url": data_url(b64[3])}]},
    ], "proxy_server_request": {"body": "x" * 100000}}   # LiteLLM bookkeeping must not count
req = responses_req()
full = h.content_size(req)
assert full > 4 * len(b64[0]), full
kw = dict(cache_dir=cache_dir, cache_days=5, attachments_dir=att_dir)
assert h.prune_images(responses_req(), budget=full, **kw) == 0        # fits: untouched
assert h.prune_images(responses_req(), budget=0, **kw) == 0           # 0 = off
# budget leaves room for exactly two images: the two oldest go, the two newest stay
budget = full - 2 * len(b64[0]) + 1000     # two notes (~330 B each) fit, a third image does not
req = responses_req()
assert h.prune_images(req, budget=budget, **kw) == 2
assert h.content_size(req) <= budget
out1, out2, out3, user = req["input"][2]["output"][0], req["input"][4]["output"][0], req["input"][6]["output"][0], req["input"][7]["content"][1]
assert out1["type"] == "input_text" and h.PRUNE_MARKER in out1["text"] and "source file /tmp/slides/4.png" in out1["text"], out1
assert out2["type"] == "input_text" and "source file /tmp/slides/5.png" in out2["text"], out2
assert out3["type"] == "input_image" and user["type"] == "input_image"
sha0 = hashlib.sha1(imgs[0]).hexdigest()
assert f"proxy copy {cache_dir}/{sha0}.png (kept 5 days)" in out1["text"], out1["text"]
assert open(f"{cache_dir}/{sha0}.png", "rb").read() == imgs[0]
# same request again (next turn replays history): same text, no new cache files, stable prefix
req2 = responses_req()
h.prune_images(req2, budget=budget, **kw)
assert req2["input"][2]["output"][0] == out1 and sorted(os.listdir(cache_dir)) == sorted(f"{hashlib.sha1(i).hexdigest()}.png" for i in imgs[:2])
# prune everything: the pasted image is named by its T3 attachment file; no tool path for it
req = responses_req()
assert h.prune_images(req, budget=1000, **kw) == 4
note = req["input"][7]["content"][1]
assert note["type"] == "input_text" and f"T3 attachment {att_dir}/thread-att.png" in note["text"] and "source file" not in note["text"], note
assert "View that path again" in note["text"]
# cache off: no copy, note still names the source file
req = responses_req()
h.prune_images(req, budget=1000, cache_dir=os.path.join(work, "nocache"), cache_days=0, attachments_dir=att_dir)
assert "proxy copy" not in req["input"][2]["output"][0]["text"] and not os.path.exists(os.path.join(work, "nocache"))
# no path known at all: generic note
req = {"model": "m", "input": [{"role": "user", "content": [{"type": "input_image", "image_url": data_url(b64[0])}]}]}
h.prune_images(req, budget=10, cache_dir=os.path.join(work, "nocache"), cache_days=0, attachments_dir=att_dir)
assert "Re-create and view it again" in req["input"][0]["content"][0]["text"]
# Anthropic /v1/messages shape: Read tool_use/tool_result pairs, image -> text block
msgs = {"model": "rits/zai-org/glm-5-3", "system": "s", "messages": [
    {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Read", "input": {"file_path": "/Users/x/shot.png"}}]},
    {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": [
        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": b64[0]}}]}]},
    {"role": "user", "content": [{"type": "text", "text": "hi"}, {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": b64[1]}}]},
]}
assert h.prune_images(msgs, budget=len(b64[1]) + 1500, **kw) == 1
blk = msgs["messages"][1]["content"][0]["content"][0]
assert blk["type"] == "text" and "source file /Users/x/shot.png" in blk["text"], blk
assert msgs["messages"][2]["content"][1]["type"] == "image"                 # newest survives
assert not h.has_image({"messages": msgs["messages"][:2]})                    # pruned block is no longer an image
# chat completions shape
chat_req = {"model": "m", "messages": [
    {"role": "assistant", "tool_calls": [{"id": "k1", "type": "function", "function": {"name": "shot", "arguments": json.dumps({"path": "/tmp/a.png"})}}]},
    {"role": "tool", "tool_call_id": "k1", "content": [{"type": "image_url", "image_url": {"url": data_url(b64[0])}}]},
]}
assert h.prune_images(chat_req, budget=10, **kw) == 1
assert chat_req["messages"][1]["content"][0]["type"] == "text"
# URL / file_id images carry no bytes and are never counted or replaced
ref = {"model": "m", "input": [{"role": "user", "content": [{"type": "input_image", "file_id": "f1"}, {"type": "input_image", "image_url": "https://x/y.png"}]}]}
assert h.prune_images(ref, budget=1, **kw) == 0 and ref["input"][0]["content"][0]["type"] == "input_image"
# expiry sweep: a stale copy goes, a fresh one stays
stale = os.path.join(cache_dir, "deadbeef.png"); open(stale, "wb").write(b"x"); os.utime(stale, (1, 1))
h._CACHE_SWEEP["at"] = 0
h.cache_image(imgs[2], hashlib.sha1(imgs[2]).hexdigest(), "image/png", cache_dir, 5)
assert not os.path.exists(stale) and os.path.exists(f"{cache_dir}/{sha0}.png")
class E(Exception):
    status_code = 429
out = h.rewrite_limit(E("token budget exhausted"), {"model": "m", "proxy_server_request": {"url": "/v1/responses"}}, now=1_700_000_000)
assert out.status_code == 429 and out.headers["x-codex-primary-used-percent"] == "100", out.headers
out = h.rewrite_limit(E("slow down"), {"model": "m", "proxy_server_request": {"url": "/v1/messages"}}, now=1_700_000_000)
assert out.status_code == 503 and "reset after 1m" in out.detail, out.detail
assert h.rewrite_limit(Exception("boom"), {}) is None

# OpenAI chat route: monthly quota -> 402 insufficient_quota, no retry-after
import re
chat = {"model": "m", "proxy_server_request": {"url": "/v1/chat/completions"}}
now = 1_793_000_000  # 2026-10-26; next UTC month = 2026-11-01T00:00:00Z
out = h.rewrite_limit(E("token budget exhausted"), chat, now=now)
assert out.status_code == 402 and out.type == "insufficient_quota", (out.status_code, out.type)
assert out.detail == "Monthly token budget exhausted. Quota resets 2026-11-01T00:00:00Z.", out.detail
assert not out.headers or not any(k.lower() == "retry-after" for k in out.headers), out.headers
# what the client sees: litellm body = {"error": {message, type, param, code=<status>}}
body = json.dumps({"error": {"message": out.detail, "type": out.type, "param": "None", "code": str(out.status_code)}})
# OpenCode session/retry.ts:33-41 retryable patterns (quoted from the report; case-insensitive)
OPENCODE_RETRY = [
    r"429|500|502|503|504|524",
    r"rate limit|rate_limit|too many requests",
    r"overloaded|service unavailable|internal error|server error",
    r"resource exhausted",
    r"try again (later|in)",
    r"at capacity",
]
for text in (out.detail, body):
    for rx in OPENCODE_RETRY:
        assert not re.search(rx, text, re.I), (rx, text)
# the old 429 body (control): the regexes do match it, so the check can fail
old_body = '{"error":{"message":"Monthly token budget exhausted. Try again in 100h.","type":"usage_limit_reached","param":"None","code":"429"}}'
assert sum(bool(re.search(rx, old_body, re.I)) for rx in OPENCODE_RETRY) == 2
# per-minute on the chat route stays 429 + retry-after seconds
out = h.rewrite_limit(E("slow down"), chat, now=now)
assert out.status_code == 429 and out.headers["retry-after"] == "60" and out.type == "usage_limit_reached", out.headers
# monthly on /v1/responses and /v1/messages keep their shapes
out = h.rewrite_limit(E("token budget exhausted"), {"model": "m", "proxy_server_request": {"url": "/v1/responses"}}, now=now)
assert out.status_code == 429 and out.type == "usage_limit_reached" and "retry-after" in out.headers
exc = E("token budget exhausted")
out = h.rewrite_limit(exc, {"model": "m", "proxy_server_request": {"url": "/v1/messages"}}, now=now)
assert out.status_code == 503 and "(reset after " in out.detail and "Monthly token budget exhausted." in out.detail

# ResetAfterHeaders with a fake ASGI app
import asyncio
def run(app_messages, scope_type="http"):
    sent = []
    async def inner(scope, receive, send):
        for m in app_messages:
            await send(m)
    async def send(m):
        sent.append(m)
    asyncio.run(h.ResetAfterHeaders(inner)({"type": scope_type}, None, send))
    return sent

reset = 1_793_491_200
err = {"error": {"message": "Monthly token budget exhausted. Try again in 100h.", "type": "usage_limit_reached", "param": "None", "code": "429"}}
raw = json.dumps(err).encode()
hdrs = [(b"content-type", b"application/json"), (b"content-length", str(len(raw)).encode()),
        (b"retry-after", b"100"), (b"x-codex-primary-reset-at", str(reset).encode())]
sent = run([{"type": "http.response.start", "status": 429, "headers": hdrs},
            {"type": "http.response.body", "body": raw}])
assert [m["type"] for m in sent] == ["http.response.start", "http.response.body"]
new_body = sent[1]["body"]
assert json.loads(new_body)["error"]["resets_at"] == reset, new_body
assert json.loads(new_body)["error"]["message"] == err["error"]["message"]
assert dict(sent[0]["headers"])[b"content-length"] == str(len(new_body)).encode(), sent[0]["headers"]
assert [k for k, _ in sent[0]["headers"]] == [k for k, _ in hdrs]            # same headers, same order
assert [v for k, v in sent[0]["headers"] if k != b"content-length"] == [v for k, v in hdrs if k != b"content-length"]
assert sent[0]["status"] == 429
# not ours: 429 without our header, wrong type, non-JSON body, streamed body, other statuses
def same(status, headers, body_msgs):
    start = {"type": "http.response.start", "status": status, "headers": headers}
    assert run([start, *body_msgs]) == [start, *body_msgs]
plain = json.dumps({"error": {"type": "rate_limit_error"}}).encode()
same(429, [(b"content-length", str(len(plain)).encode())], [{"type": "http.response.body", "body": plain}])
same(429, hdrs, [{"type": "http.response.body", "body": plain}])
same(429, hdrs, [{"type": "http.response.body", "body": b"token budget exhausted"}])
same(429, hdrs, [{"type": "http.response.body", "body": raw, "more_body": True}, {"type": "http.response.body", "body": b""}])
same(200, hdrs, [{"type": "http.response.body", "body": raw}])
same(500, hdrs, [{"type": "http.response.body", "body": raw}])
# 503 path still adds retry-after (+ x-should-retry when over the threshold)
msg = h.rewrite_limit(E("token budget exhausted"), {"model": "m", "proxy_server_request": {"url": "/v1/messages"}}, now=now).detail.encode()
sent = run([{"type": "http.response.start", "status": 503, "headers": []}, {"type": "http.response.body", "body": msg}])
hd = dict(sent[0]["headers"])
assert int(hd[b"retry-after"]) > 60 and hd[b"x-should-retry"] == b"false", hd
assert sent[1]["body"] == msg

# --- upstream reset shapes, drift, event fields (docs/notes/enmaas-reset-forward-compat.md)
import datetime, email.utils, logging
NOW = 1_793_000_000                                   # 2026-10-26T..Z
NEXT = h.month_bounds(NOW)[1]                         # 2026-11-01T00:00:00Z
iso = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def Ex(text="slow down", headers=None, body=None):
    e = E(text); e.headers = headers; e.body = body
    return e
def an(exc, model="m"):
    h.DRIFT_SEEN.clear(); h.LAST_LIMIT_RESET.clear(); h.LAST_LIMIT_KIND.clear()
    return h.analyze_limit(exc, model, NOW)
def check(info, reset, source, kind="rate-limit", drift=()):
    assert abs(info["reset"] - reset) < 0.01, (info["reset"] - NOW, reset - NOW, info)
    assert info["source"] == source and info["kind"] == kind, info
    assert [d["kind"] for d in info["drift"]] == list(drift), info["drift"]
    assert info["monthly"] == (kind == "quota")
# headers
check(an(Ex(headers={"Retry-After": "30"})), NOW + 30, "upstream-header:retry-after")
check(an(Ex(headers={"retry-after": email.utils.format_datetime(datetime.datetime.fromtimestamp(NOW + 120, datetime.timezone.utc), usegmt=True)})), NOW + 120, "upstream-header:retry-after")
check(an(Ex(headers={"retry-after": "30", "retry-after-ms": "1500"})), NOW + 1.5, "upstream-header:retry-after-ms")
check(an(Ex(headers={"x-ratelimit-reset-requests": "1s", "x-ratelimit-reset-tokens": "6m0s",
                     "x-ratelimit-remaining-requests": "5", "x-ratelimit-remaining-tokens": "0",
                     "x-ratelimit-limit-requests": "100"})), NOW + 360, "upstream-header:x-ratelimit-reset-tokens")
check(an(Ex(headers={"x-ratelimit-reset-requests": "1s", "x-ratelimit-reset-tokens": "6m0s"})), NOW + 1, "upstream-header:x-ratelimit-reset-requests")  # no remaining: earliest
check(an(Ex(headers={"x-ratelimit-reset-tokens": "1h2m3.5s"})), NOW + 3723.5, "upstream-header:x-ratelimit-reset-tokens")
check(an(Ex(headers={"x-ratelimit-reset-tokens": "250ms"})), NOW + 0.25, "upstream-header:x-ratelimit-reset-tokens")
# praxis token_rate_limit: Retry-After + X-RateLimit-{Limit,Remaining,Reset}-Tokens (reset = bare seconds)
check(an(Ex(headers={"Retry-After": "42", "X-RateLimit-Limit-Tokens": "1000000", "X-RateLimit-Remaining-Tokens": "0", "X-RateLimit-Reset-Tokens": "42"})), NOW + 42, "upstream-header:retry-after")
check(an(Ex(headers={"X-RateLimit-Limit-Tokens": "1000", "X-RateLimit-Remaining-Tokens": "0", "X-RateLimit-Reset-Tokens": "42"})), NOW + 42, "upstream-header:x-ratelimit-reset-tokens")
# LiteLLM: retry-after, x-ratelimit-*-input/output-tokens (seconds), reset_at, llm_provider- prefix
check(an(Ex(headers={"x-ratelimit-limit-input-tokens": "100", "x-ratelimit-remaining-input-tokens": "0", "x-ratelimit-reset-input-tokens": "17", "x-ratelimit-reset-output-tokens": "40", "rate_limit_type": "tokens"})), NOW + 17, "upstream-header:x-ratelimit-reset-input-tokens")
check(an(Ex(headers={"reset_at": str(NOW + 55)})), NOW + 55, "upstream-header:reset_at")
check(an(Ex(headers={"llm_provider-retry-after": "9"})), NOW + 9, "upstream-header:retry-after")
# IETF RateLimit
check(an(Ex(headers={"RateLimit": "limit=100, remaining=0, reset=30", "RateLimit-Policy": "100;w=60"})), NOW + 30, "upstream-header:ratelimit")
check(an(Ex(headers={"RateLimit": '"default";r=0;t=25', "RateLimit-Policy": '"default";q=100;w=60'})), NOW + 25, "upstream-header:ratelimit")
check(an(Ex(headers={"RateLimit-Reset": "12", "RateLimit-Limit": "5", "RateLimit-Remaining": "0"})), NOW + 12, "upstream-header:ratelimit-reset")
# Anthropic: RFC3339 or epoch
check(an(Ex(headers={"anthropic-ratelimit-unified-reset": iso(NOW + 600), "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-requests-reset": iso(NOW + 5)})), NOW + 600, "upstream-header:anthropic-ratelimit-unified-reset")
check(an(Ex(headers={"anthropic-ratelimit-unified-reset": str(NOW + 700)})), NOW + 700, "upstream-header:anthropic-ratelimit-unified-reset")
check(an(Ex(headers={"anthropic-ratelimit-tokens-reset": iso(NOW + 30), "anthropic-ratelimit-tokens-remaining": "0", "anthropic-ratelimit-requests-reset": iso(NOW + 5), "anthropic-ratelimit-requests-remaining": "9"})), NOW + 30, "upstream-header:anthropic-ratelimit-tokens-reset")
# JSON body fields (#107 proposal), via exc.body and via text
check(an(Ex(body={"error": {"type": "rate_limit_error", "reset_at": iso(NOW + 900)}})), NOW + 900, "upstream-body:reset_at")
check(an(Ex("litellm.RateLimitError: OpenAIException - " + json.dumps({"error": {"type": "rate_limit_exceeded", "resets_at": NOW + 800}}))), NOW + 800, "upstream-body:resets_at")
check(an(Ex(body={"error": {"type": "rate_limit_exceeded", "reset_after_seconds": 90}})), NOW + 90, "upstream-body:reset_after_seconds")
check(an(Ex(body={"error": {"code": "rate_limit_exceeded", "reason": "per_minute", "retry_after": 45}})), NOW + 45, "upstream-body:retry_after")
# header beats body; retry-after-ms beats everything
check(an(Ex(headers={"retry-after": "30"}, body={"error": {"type": "rate_limit_error", "reset_after_seconds": 90}})), NOW + 30, "upstream-header:retry-after")
# quota via body type/reason, exact reset at the UTC month boundary: no drift
qbody = {"error": {"type": "insufficient_quota", "reason": "monthly_tokens", "message": "token budget exhausted", "reset_at": iso(NEXT)}}
check(an(Ex(json.dumps(qbody), body=qbody)), NEXT, "upstream-body:reset_at", "quota")
check(an(Ex("OpenAIException - " + json.dumps(qbody))), NEXT, "upstream-body:reset_at", "quota")
# quota via a long Retry-After with the plain text body: kind from text, exact reset, no drift
check(an(Ex("token budget exhausted", headers={"retry-after": str(NEXT - NOW)})), NEXT, "upstream-header:retry-after", "quota")
# long wait without any kind signal counts as quota; inferred, so the month estimate is not compared
check(an(Ex(headers={"retry-after": str(5 * 86400)})), NOW + 5 * 86400, "upstream-header:retry-after", "quota")
# plain text unchanged: estimates, no drift
check(an(E("token budget exhausted")), NEXT, "estimate:next-month-utc", "quota")
check(an(E("slow down")), NOW + 60, "estimate:default")
# unknown header -> unhandled_header (value sample, hint names the parser); reset still used
info = an(Ex(headers={"retry-after": "30", "x-quota-window-end": "2026-11-01", "x-request-id": "abc", "x-litellm-key-spend": "1", "x-should-retry": "true"}))
assert info["reset"] == NOW + 30 and len(info["drift"]) == 1, info
d = info["drift"][0]
assert d == {"kind": "unhandled_header", "detail": "x-quota-window-end=2026-11-01",
             "hint": "update hosted_only_hooks.parse_reset_headers to parse x-quota-window-end"}, d
# unknown JSON key -> unhandled_body_field
info = an(Ex(body={"error": {"type": "rate_limit_error", "retry_hint_ms": 5, "reset_after_seconds": 90}}))
assert [(d["kind"], d["detail"]) for d in info["drift"]] == [("unhandled_body_field", "retry_hint_ms=5")], info["drift"]
assert "parse_reset_body" in info["drift"][0]["hint"] and info["reset"] == NOW + 90
# upstream month boundary in a non-UTC zone (America/Chicago CDT = 05:00Z) -> estimate_mismatch
chicago = {"error": {"type": "insufficient_quota", "message": "token budget exhausted", "reset_at": iso(NEXT + 5 * 3600)}}
info = an(Ex(json.dumps(chicago), body=chicago))
assert info["reset"] == NEXT + 5 * 3600 and info["kind"] == "quota", info
assert [d["kind"] for d in info["drift"]] == ["estimate_mismatch"], info["drift"]
assert iso(NEXT + 5 * 3600) in info["drift"][0]["hint"] and "update limit_reset" in info["drift"][0]["hint"]
# within tolerance (a few seconds of skew) -> no drift
check(an(Ex("token budget exhausted", headers={"retry-after": str(NEXT - NOW + 20)})), NEXT + 20, "upstream-header:retry-after", "quota")
# quota/rate-limit disagreement -> kind_mismatch, upstream kind wins
qb = {"error": {"type": "insufficient_quota", "reset_at": iso(NEXT)}}
info = an(Ex("slow down", body=qb))
assert info["kind"] == "quota" and [d["kind"] for d in info["drift"]] == ["kind_mismatch"], info
rb = {"error": {"type": "rate_limit_exceeded", "reset_after_seconds": 30}}
info = an(Ex("token budget exhausted", body=rb))
assert info["kind"] == "rate-limit" and [d["kind"] for d in info["drift"]] == ["kind_mismatch"], info
# JSON body we do not recognise -> shape_changed (once per distinct key set)
info = an(Ex("x " + json.dumps({"object": "error", "message": "nope", "code": 429})))
assert [d["kind"] for d in info["drift"]] == ["shape_changed"] and info["source"] == "estimate:default", info
# router cooldown reuses the last real reset, no drift
h.rewrite_limit(Ex("token budget exhausted"), {"model": "rc", "proxy_server_request": {"url": "/v1/responses"}}, now=NOW)
class RouterRateLimitError(E): pass
info = h.analyze_limit(RouterRateLimitError("No deployments available for selected model"), "rc", NOW + 5)
assert info["source"] == "reuse:last-reset" and info["reset"] == NEXT and info["kind"] == "quota" and not info["drift"], info

# WARNING once per (kind, key) per proxy lifetime
records = []
class Cap(logging.Handler):
    def emit(self, record): records.append(record.getMessage())
h.LOG.addHandler(Cap()); h.LOG.setLevel(logging.WARNING); h.LOG.propagate = False
h.DRIFT_SEEN.clear()
for value in ("1", "2", "3"):
    h.limit_reset(Ex(headers={"x-new-quota-window": value}), "m", NOW)
assert len(records) == 1 and "[unhandled_header] x-new-quota-window=1" in records[0] and "parse_reset_headers" in records[0], records
h.limit_reset(Ex(headers={"x-other-limit-thing": "v"}), "m", NOW)
assert len(records) == 2, records
h.limit_reset(Ex(headers={"retry-after": "30"}), "m", NOW)       # no drift, no warning
assert len(records) == 2, records

# client rewrite uses the upstream reset, passes upstream headers through
up = {"retry-after": "30", "retry-after-ms": "30000", "x-ratelimit-remaining-tokens": "0", "x-ratelimit-limit-tokens": "1000", "x-codex-primary-reset-at": "1"}
out = h.rewrite_limit(Ex(headers=up), {"model": "m", "proxy_server_request": {"url": "/v1/responses"}}, now=NOW)
assert out.headers["retry-after"] == "30" and out.headers["retry-after-ms"] == "30000", out.headers
assert out.headers["x-ratelimit-remaining-tokens"] == "0" and out.headers["x-ratelimit-limit-tokens"] == "1000", out.headers
assert out.headers["x-codex-primary-reset-at"] == str(NOW + 30), out.headers      # ours win
out = h.rewrite_limit(Ex(headers={"retry-after": "30"}), {"model": "m", "proxy_server_request": {"url": "/v1/responses"}}, now=NOW)
assert not any(k.startswith(("x-ratelimit", "retry-after-ms")) for k in out.headers), out.headers
out = h.rewrite_limit(Ex(body={"error": {"type": "rate_limit_error", "reset_after_seconds": 7200}}), {"model": "m", "proxy_server_request": {"url": "/v1/messages"}}, now=NOW)
assert out.status_code == 503 and "(reset after 2h)" in out.detail, out.detail
qex = Ex("token budget exhausted", body={"error": {"type": "insufficient_quota", "message": "token budget exhausted", "reset_at": iso(NEXT + 3600)}})
out = h.rewrite_limit(qex, chat, now=NOW)
assert out.status_code == 402 and out.detail == f"Monthly token budget exhausted. Quota resets {iso(NEXT + 3600)}.", out.detail
assert not out.headers, out.headers                                   # 402: nothing retry-like
out = h.rewrite_limit(Ex(headers={"retry-after": "60", "retry-after-ms": "60000", "x-ratelimit-remaining-tokens": "0"}), chat, now=NOW)
assert out.status_code == 429 and out.headers["retry-after-ms"] == "60000" and out.headers["x-ratelimit-remaining-tokens"] == "0", out.headers

# usage logger: reset_at / reset_source / drift in the event
import litellm_usage_log as ul
sys.modules["litellm"].callbacks = [h.HostedOnlyHooks()]
h.DRIFT_SEEN.clear()
exc = Ex(headers={"retry-after": "30", "x-quota-window-end": "z"})
ev = ul.error_fields({"exception": exc, "model": "m", "proxy_server_request": {"url": "/v1/messages"}}, {"error_information": {"error_code": "429"}})
assert ev["status"] == 503 and ev["upstream_status"] == 429 and ev["rewritten"] and 29 <= ev["retry_after"] <= 31, ev
assert ev["reset_source"] == "upstream-header:retry-after" and abs(ev["reset_at"] - time.time() - 30) < 5, ev
assert [d["kind"] for d in ev["drift"]] == ["unhandled_header"], ev
ev = ul.error_fields({"exception": E("token budget exhausted"), "model": "m", "proxy_server_request": {"url": "/v1/responses"}}, {"error_information": {"error_code": "429"}})
assert ev["reset_source"] == "estimate:next-month-utc" and ev["quota"] and "drift" not in ev and ev["reset_at"] > time.time(), ev
ev = ul.error_fields({"exception": Exception("[m] [429]: {} (reset after 1h 2m 3s)"), "model": "m"}, {})
assert ev["reset_source"] == "unknown:rewritten" and ev["retry_after"] == 3723, ev

# --- GitHub Copilot shapes (docs/notes/copilot-api-429-handling.md)
def St(status, text="", headers=None, body=None):
    e = type("St", (Exception,), {"status_code": status})(text)
    e.headers = headers; e.body = body
    return e
# x-usage-ratelimit-{session,weekly}: rem=<n>&rst=<ISO>; the exhausted one decides, else the earliest
check(an(St(429, headers={"x-usage-ratelimit-session": f"rem=0&rst={iso(NOW + 1800)}"})), NOW + 1800, "upstream-header:x-usage-ratelimit-session")
check(an(St(429, headers={"x-usage-ratelimit-session": f"rem=40&rst={iso(NOW + 18000)}", "x-usage-ratelimit-weekly": f"rem=0&rst={iso(NOW + 3 * 86400)}"})), NOW + 3 * 86400, "upstream-header:x-usage-ratelimit-weekly", "quota")
check(an(St(429, headers={"x-usage-ratelimit-session": f"rem=40&rst={iso(NOW + 18000)}", "x-usage-ratelimit-weekly": f"rem=90&rst={iso(NOW + 3 * 86400)}"})), NOW + 18000, "upstream-header:x-usage-ratelimit-session")
check(an(St(429, headers={"x-usage-ratelimit-session": "rem=50", "retry-after": "20"})), NOW + 20, "upstream-header:retry-after")   # no rst: informational
# unknown variants -> drift
info = an(St(429, headers={"x-usage-ratelimit-session": "garbage", "x-usage-ratelimit-monthly": "rem=0&rst=x", "retry-after": "20"}))
assert sorted(d["detail"].split("=")[0] for d in info["drift"]) == ["x-usage-ratelimit-monthly", "x-usage-ratelimit-session"], info["drift"]
assert all(d["kind"] == "unhandled_header" for d in info["drift"]) and info["reset"] == NOW + 20
# optional x-ratelimit-* beside them: informational, no drift
check(an(St(429, headers={"x-ratelimit-limit": "100", "x-ratelimit-remaining": "0", "retry-after": "20"})), NOW + 20, "upstream-header:retry-after")
# body error.code rate_limited, retry_after in error or top-level, any status
check(an(St(429, body={"error": {"code": "rate_limited", "message": "x", "retry_after": 12}})), NOW + 12, "upstream-body:retry_after")
check(an(St(429, body={"error": {"code": "rate_limited", "message": "x"}, "retry_after": 33})), NOW + 33, "upstream-body:retry_after")
check(an(St(500, "x " + json.dumps({"error": {"code": "rate_limited", "retry_after": 8}}))), NOW + 8, "upstream-body:retry_after")
check(an(St(429, body={"error": {"code": "rate_limited", "message": "x"}})), NOW + 60, "estimate:default")
info = an(St(429, body={"error": {"code": "rate_limited"}, "copilot_quota_reset": "tomorrow"}))
assert [(d["kind"], d["detail"]) for d in info["drift"]] == [("unhandled_body_field", "copilot_quota_reset=tomorrow")], info["drift"]
# 402 = quota used up (plain text, or with a reset); 503 `upstream rate limited` = rate limit
check(an(St(402, "payment required")), NEXT, "estimate:next-month-utc", "quota")
check(an(St(402, body={"error": {"message": "quota", "retry_after": NEXT - NOW}})), NEXT, "upstream-body:retry_after", "quota")
check(an(St(503, "Upstream rate limited, try later")), NOW + 60, "estimate:default")
check(an(St(503, "upstream rate limited", body={"error": {"code": "rate_limited", "retry_after": 20}})), NOW + 20, "upstream-body:retry_after")
# what counts as a limit answer
for status, text, body, want in (
    (429, "", None, True), (402, "", None, True), (503, "Upstream rate limited", None, True),
    (503, "metering system unavailable", None, False), (500, "boom", None, False), (400, "bad", None, False),
    (500, "", {"error": {"code": "rate_limited"}}, True), (200, "", {"error": {"code": "other"}}, False),
):
    assert h.is_limit_error(St(status, text, body=body)) is want, (status, text, body)
# client rewrite of those answers
msgs = {"model": "m", "proxy_server_request": {"url": "/v1/messages"}}
resp = {"model": "m", "proxy_server_request": {"url": "/v1/responses"}}
out = h.rewrite_limit(St(503, "upstream rate limited", body={"retry_after": 20}), msgs, now=NOW)
assert out.status_code == 503 and "(reset after 20s)" in out.detail and "Rate limit reached." in out.detail, out.detail
out = h.rewrite_limit(St(402, "payment required"), chat, now=NOW)
assert out.status_code == 402 and out.type == "insufficient_quota" and iso(NEXT) in out.detail, (out.status_code, out.detail)
out = h.rewrite_limit(St(402, "payment required"), resp, now=NOW)
assert out.status_code == 429 and out.type == "usage_limit_reached" and out.headers["x-codex-primary-reset-at"] == str(int(NEXT)), out.headers
assert h.rewrite_limit(St(503, "metering system unavailable"), msgs, now=NOW) is None
assert h.rewrite_limit(St(500, "boom"), msgs, now=NOW) is None
# usage logger: non-429 limit answers keep their real upstream status, client sees the rewrite
ev = ul.error_fields({"exception": St(503, "upstream rate limited", body={"retry_after": 20}), "model": "m", "proxy_server_request": {"url": "/v1/messages"}}, {"error_information": {"error_code": "503"}})
assert (ev["upstream_status"], ev["status"], ev["rewritten"]) == (503, 503, True) and ev["reset_source"] == "upstream-body:retry_after", ev
ev = ul.error_fields({"exception": St(402, "payment required"), "model": "m", "proxy_server_request": {"url": "/v1/chat/completions"}}, {"error_information": {"error_code": "402"}})
assert (ev["upstream_status"], ev["status"], ev.get("quota")) == (402, 402, True) and ev["reset_source"] == "estimate:next-month-utc", ev
ev = ul.error_fields({"exception": St(500, "boom"), "model": "m"}, {"error_information": {"error_code": "500"}})
assert "reset_source" not in ev and "rewritten" not in ev, ev
EOF

print -r -- "ok hosted-only-proxy"
