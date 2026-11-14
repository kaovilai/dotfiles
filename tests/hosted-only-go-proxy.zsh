#!/bin/zsh
# Offline end-to-end tests for scripts/hosted-only-go (HOSTED_ONLY_PROXY_IMPL=go):
# build/integration with the launcher, auth, alias, pass-through, the 429/402
# rewrites and the llm-usage JSONL. A stub upstream stands in for EnMaaS: no
# network, no real key, no LiteLLM. Skipped when `go` is not installed.
emulate -LR zsh
setopt err_exit pipe_fail
local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
local stub= proxy= eproxy=
cleanup() {
    [[ -n "$proxy" ]] && kill "$proxy" 2>/dev/null
    [[ -n "$eproxy" ]] && kill "$eproxy" 2>/dev/null
    [[ -n "$stub" ]] && kill "$stub" 2>/dev/null
    # ensure/watch-started listeners are not tracked in a pid variable; stop
    # them by identity so a failed run does not leak them past the tempdir
    [[ -n "${pport-}" ]] && pkill -f "hosted-only-proxy --flavor claude --port $pport" 2>/dev/null
    rm -rf "$tmp"
}
trap cleanup EXIT
fail() { print -ru2 -- "FAIL: $*"; exit 1; }

if ! command -v go >/dev/null; then
    print -ru2 -- "skip: go not installed"
    exit 0
fi

export XDG_STATE_HOME="$tmp/state"
source "$repo/scripts/hosted-only-proxy.zsh"

# --- launcher contract -------------------------------------------------------
# The Go proxy is the only impl: the default is go and the retired
# HOSTED_ONLY_PROXY_IMPL / LLM_PROXY_IMPL=litellm knobs fail loudly (covered in
# tests/hosted-only-proxy.zsh); GO / " go " / auto normalize to go.
unset HOSTED_ONLY_PROXY_IMPL GLM_HYBRID_PROXY_IMPL LLM_PROXY_IMPL
_hosted_only_proxy_vars claude
[[ "$_hop_impl" == go ]] || fail "default impl should be go: $_hop_impl"
HOSTED_ONLY_PROXY_IMPL=GO _hosted_only_proxy_vars claude
[[ "$_hop_impl" == go ]] || fail "HOSTED_ONLY_PROXY_IMPL=GO not normalized to go: $_hop_impl"
HOSTED_ONLY_PROXY_IMPL=' go ' _hosted_only_proxy_vars claude
[[ "$_hop_impl" == go ]] || fail "a padded ' go ' must mean go: $_hop_impl"
HOSTED_ONLY_PROXY_IMPL=auto _hosted_only_proxy_vars claude
[[ "$_hop_impl" == go ]] || fail "auto must mean go: $_hop_impl"
GLM_HYBRID_PROXY_IMPL=go _hosted_only_proxy_vars claude
[[ "$_hop_impl" == go ]] || fail "retired GLM_HYBRID_PROXY_IMPL ignored"
_hosted_only_proxy_vars claude

# The fp helper runs inside a command substitution, so every field the spawn
# path needs travels on its stdout line; the globals cannot cross back.
(
    export ENMAAS_API_KEY=test-key
    _hosted_only_proxy_vars claude
    fp_line=$(_hosted_only_proxy_fp) || exit 1
    _hosted_only_proxy_fp_load "$fp_line"
    [[ -n "$_hop_fp" && -n "$_hop_token_fp" ]] || exit 2
    [[ "$_hop_dns_host" == api.enmaas.devshift.net ]] || exit 3
) || fail "fp helper contract broken: fields do not reach the caller"

# Every image knob reaches the Go child's environment, so each must also change
# the fingerprint: otherwise an idle proxy keeps the old token price / cache
# directory after the setting changes (2026-11-06 review: IMAGE_TOKENS and
# IMAGE_CACHE_DIR were forwarded but not fingerprinted).
fp_with() {   # fp_with VAR=VALUE... -> the fingerprint line under the Go impl
    (
        export HOSTED_ONLY_PROXY_IMPL=go ENMAAS_API_KEY=test-key "$@"
        _hosted_only_proxy_vars claude
        _hosted_only_proxy_fp
    )
}
local base_fp="$(fp_with HOSTED_ONLY_IMAGE_TOKENS=2500)" changed_fp
[[ -n "$base_fp" ]] || fail "fp_with produced no fingerprint"
[[ "$(fp_with HOSTED_ONLY_IMAGE_CACHE_DIR=.)" != "$base_fp" ]] || fail "an explicit IMAGE_CACHE_DIR=. hashes like an unset dir"
for knob in IMAGE_BUDGET_BYTES=123456 IMAGE_CACHE_DAYS=7 IMAGE_TOKENS=3100 IMAGE_CACHE_DIR=/tmp/other-image-cache CLASSIFIER_ROUTE_MODEL=rits/google/diffusiongemma-26B-A4B-it; do
    changed_fp="$(fp_with HOSTED_ONLY_$knob)"
    [[ "$changed_fp" != "$base_fp" ]] || fail "changing HOSTED_ONLY_$knob does not change the proxy fingerprint"
done

local bin
bin=$(_hosted_only_go_bin) || fail "go build failed"
[[ -x "$bin" ]] || fail "no binary at $bin"
[[ "$bin" == "$tmp/state/hosted-only-go/hosted-only-proxy" ]] || fail "binary path: $bin"

# Every knob the Go config reads must be forwarded by _hosted_only_go_env: a
# setting made in .zshrc without `export` reaches _hosted_only_knob but not the
# child process, so a knob left out is silently ignored (the image budget and the
# outage retry knobs were, before this guard existed).
_hosted_only_proxy_vars claude
_hosted_only_go_env
local knobname missing=() hits
for knobname in $(grep -oE '(knob|intKnob|boolKnob|floatKnob)\("[A-Z_]+"' "$repo/scripts/hosted-only-go/config.go" | grep -oE '"[A-Z_]+"' | tr -d '"' | sort -u); do
    hits=(${(M)_hop_go_env:#HOSTED_ONLY_${knobname}=*})   # assign first: ${#${(M)...}} does not count elements
    (( ${#hits} )) || missing+=($knobname)
done
(( ${#missing} == 0 )) || fail "config.go reads knobs _hosted_only_go_env does not forward (ignored when set without export): ${missing[*]}"
# and a NON-exported setting actually lands in the child's environment
# a plain (non-exported) assignment models a .zshrc setting; the zsh
# VAR=x func prefix form is function-scoped and gone before _hosted_only_go_env
HOSTED_ONLY_IMAGE_CACHE_DAYS=0
_hosted_only_proxy_vars claude
_hosted_only_go_env
hits=(${(M)_hop_go_env:#HOSTED_ONLY_IMAGE_CACHE_DAYS=0})
(( ${#hits} )) || fail "a non-exported HOSTED_ONLY_IMAGE_CACHE_DAYS=0 was not forwarded"
_hosted_only_proxy_vars claude

# --- stub upstream -----------------------------------------------------------
local stub_port pport
stub_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
pport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

python3 - "$stub_port" "$tmp/slow.started" <<'PY' >"$tmp/stub.log" 2>&1 &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        payload = b'{"status":"ok"}'
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        n = int(self.headers.get('content-length') or 0)
        body = json.loads(self.rfile.read(n) or b'{}')
        text = json.dumps(body)
        if 'SLOW' in text:
            import time
            open(sys.argv[2], 'w').close()   # tell the test the request is in hand
            time.sleep(1.5)
        if 'MONTHLY' in text:
            payload = b'{"error":{"message":"monthly token budget exhausted","type":"insufficient_quota"}}'
            self.send_response(429)
            self.send_header('content-type', 'application/json')
            self.send_header('content-length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if 'TRIGGER429' in text:
            payload = b'{"error":{"message":"slow down"}}'
            self.send_response(429)
            self.send_header('content-type', 'application/json')
            self.send_header('retry-after', '120')
            self.send_header('x-ratelimit-limit-tokens', '1000')
            self.send_header('content-length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        payload = json.dumps({
            "id": "msg_stub", "type": "message", "role": "assistant",
            "model": body.get("model"), "path": self.path,
            "additional_tools": any(isinstance(i, dict) and i.get("type") == "additional_tools"
                                    for i in (body.get("input") or [])),
            "tool_search": any(isinstance(i, dict) and str(i.get("type") or "").startswith("tool_search_tool_")
                               for i in (body.get("tools") or [])),
            "deferred": sum(1 for i in (body.get("tools") or []) if isinstance(i, dict) and "defer_loading" in i),
            "tools": len(body.get("tools") or []),
            "content": [{"type": "text", "text": "ok"}],
            "usage": {"input_tokens": 7, "output_tokens": 3},
        }).encode()
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
stub=$!
for i in {1..50}; do
    curl -sf --max-time 1 -o /dev/null "http://127.0.0.1:$stub_port/" 2>/dev/null && break
    sleep 0.1
done

# --- start the Go proxy directly --------------------------------------------
local rtdir="$tmp/state/hosted-only-$pport"
mkdir -p "$rtdir"
local hcfg="$rtdir/routes.json"
cat >| "$hcfg" <<JSON
{"model_list":[
 {"model_name":"rits/zai-org/glm-5-3","litellm_params":{"model":"anthropic/rits/zai-org/glm-5-3","api_base":"http://127.0.0.1:$stub_port"}},
 {"model_name":"rits/zai-org/glm-5-3#openai","litellm_params":{"model":"openai/rits/zai-org/glm-5-3","api_base":"http://127.0.0.1:$stub_port/v1"}},
 {"model_name":"rits/deepseek-ai/DeepSeek-V4.1-Flash-1017","litellm_params":{"model":"anthropic/rits/deepseek-ai/DeepSeek-V4.1-Flash-1017","api_base":"http://127.0.0.1:$stub_port"}},
 {"model_name":"rits/deepseek-ai/DeepSeek-V4.1-Flash-1017#openai","litellm_params":{"model":"openai/rits/deepseek-ai/DeepSeek-V4.1-Flash-1017","api_base":"http://127.0.0.1:$stub_port/v1"}},
 {"model_name":"claude-sonnet-5-5","litellm_params":{"model":"anthropic/rits/zai-org/glm-5-3","api_base":"http://127.0.0.1:$stub_port"}},
 {"model_name":"claude-sonnet-5-5#openai","litellm_params":{"model":"openai/rits/zai-org/glm-5-3","api_base":"http://127.0.0.1:$stub_port/v1"}}
],"general_settings":{"master_key":"os.environ/HOSTED_ONLY_PROXY_TOKEN"}}
JSON
env ENMAAS_API_KEY=test-key HOSTED_ONLY_PROXY_TOKEN=test-token \
    HOSTED_ONLY_ENMAAS_BASE_URL="http://127.0.0.1:$stub_port" \
    HOSTED_ONLY_ALIAS_MODELS=claude-sonnet-5-5 \
    LLM_USAGE_DIR="$tmp/usage" \
    "$bin" --flavor claude --config "$hcfg" --port "$pport" --runtime-dir "$rtdir" >"$tmp/proxy.log" 2>&1 &
proxy=$!
for i in {1..50}; do
    curl -sf --max-time 1 "http://127.0.0.1:$pport/health/liveliness" -o /dev/null && break
    sleep 0.1
done
curl -sf --max-time 1 "http://127.0.0.1:$pport/health/liveliness" -o /dev/null || fail "proxy did not start: $(<"$tmp/proxy.log")"

local url="http://127.0.0.1:$pport/v1/messages"
local body='{"model":"claude-sonnet-5-5","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}'

# Auth: no token, wrong token, either header.
local code
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url" -H 'content-type: application/json' -d "$body")
[[ "$code" == 401 ]] || fail "missing token: $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url" -H 'content-type: application/json' -H 'x-api-key: nope' -d "$body")
[[ "$code" == 401 ]] || fail "wrong token: $code"

# Alias is served by GLM and the response passes through.
local out
out=$(curl -s -X POST "$url" -H 'content-type: application/json' -H 'x-api-key: test-token' -d "$body")
[[ "$out" == *'"model": "rits/zai-org/glm-5-3"'* ]] || fail "alias not served by GLM: $out"
out=$(curl -s -X POST "$url" -H 'content-type: application/json' -H 'authorization: Bearer test-token' -d "$body")
[[ "$out" == *'"usage"'* ]] || fail "bearer auth failed: $out"

# 429 stays 429 with a reset and retry-after, in the Messages shape; a
# watchdog-sized wait (default CLIENT_RETRY_MAX_SECONDS=21600) stays retryable.
local hdr="$tmp/headers"
code=$(curl -s -D "$hdr" -o "$tmp/body429" -w '%{http_code}' -X POST "$url" -H 'content-type: application/json' -H 'x-api-key: test-token' \
    -d '{"model":"rits/zai-org/glm-5-3","max_tokens":16,"messages":[{"role":"user","content":"TRIGGER429"}]}')
[[ "$code" == 429 ]] || fail "429 rewrite status: $code ($(<"$tmp/body429"))"
grep -qi '^retry-after: 120' "$hdr" || fail "retry-after missing: $(<"$hdr")"
if grep -qi '^x-should-retry:' "$hdr"; then fail "120s wait must stay retryable: $(<"$hdr")"; fi
[[ "$(<"$tmp/body429")" == *'(reset after 2m)'* ]] || fail "reset text missing: $(<"$tmp/body429")"
[[ "$(<"$tmp/body429")" == *'[429]'* ]] || fail "429 tag missing: $(<"$tmp/body429")"
[[ "$(<"$tmp/body429")" == *'[429]: {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":'* ]] || fail "inner error must be type-first: $(<"$tmp/body429")"

# Messages route: a monthly quota fails fast (x-should-retry:false) so T3
# snoozes on it instead of the client sleeping toward the month end.
code=$(curl -s -D "$hdr" -o "$tmp/bodyquota" -w '%{http_code}' -X POST "$url" -H 'content-type: application/json' -H 'x-api-key: test-token' \
    -d '{"model":"rits/zai-org/glm-5-3","max_tokens":16,"messages":[{"role":"user","content":"MONTHLY"}]}')
[[ "$code" == 429 ]] || fail "quota rewrite status: $code ($(<"$tmp/bodyquota"))"
grep -qi '^x-should-retry: false' "$hdr" || fail "quota must fail fast: $(<"$hdr")"
[[ "$(<"$tmp/bodyquota")" == *'Monthly token budget exhausted.'* ]] || fail "quota text: $(<"$tmp/bodyquota")"

# Chat route: rate limit stays 429 with the codex headers.
local chat="http://127.0.0.1:$pport/v1/chat/completions"
code=$(curl -s -D "$hdr" -o /dev/null -w '%{http_code}' -X POST "$chat" -H 'content-type: application/json' -H 'authorization: Bearer test-token' \
    -d '{"model":"rits/zai-org/glm-5-3","max_tokens":16,"messages":[{"role":"user","content":"TRIGGER429"}]}')
[[ "$code" == 429 ]] || fail "chat rate limit status: $code"
grep -qi '^x-codex-primary-reset-at: ' "$hdr" || fail "codex reset header missing: $(<"$hdr")"

# Chat route: monthly quota becomes 402 insufficient_quota with no retry-after.
code=$(curl -s -D "$hdr" -o "$tmp/body402" -w '%{http_code}' -X POST "$chat" -H 'content-type: application/json' -H 'authorization: Bearer test-token' \
    -d '{"model":"rits/zai-org/glm-5-3","max_tokens":16,"messages":[{"role":"user","content":"MONTHLY"}]}')
[[ "$code" == 402 ]] || fail "quota status: $code ($(<"$tmp/body402"))"
if grep -qi '^retry-after:' "$hdr"; then fail "quota answer must not carry retry-after"; fi
[[ "$(<"$tmp/body402")" == *insufficient_quota* ]] || fail "quota body: $(<"$tmp/body402")"

# Cost guard: the hosted-only flavor must refuse any model it does not serve,
# even though the upstream key would happily serve it.
code=$(curl -s -o "$tmp/bodyguard" -w '%{http_code}' -X POST "$chat" -H 'content-type: application/json' -H 'authorization: Bearer test-token' \
    -d '{"model":"gpt-6-luna","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}')
[[ "$code" == 400 ]] || fail "cost guard did not reject an unserved model: $code ($(<"$tmp/bodyguard"))"
[[ "$(<"$tmp/bodyguard")" == *"Invalid model name"* ]] || fail "cost guard body: $(<"$tmp/bodyguard")"

# Usage JSONL: an ok event and a rewritten 429 event, same schema llm-usage reads.
sleep 0.3
local events
events=$(ls "$tmp/usage"/events-*.jsonl 2>/dev/null | head -1)
[[ -n "$events" ]] || fail "no usage events written"
python3 - "$events" <<'PY'
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(lines) >= 3, lines
ok = [e for e in lines if e.get("ok") and e.get("status") == 200]
assert ok, "no successful event"
assert ok[0]["requested"] == "claude-sonnet-5-5", ok[0]
assert ok[0]["served"] == "rits/zai-org/glm-5-3", ok[0]
assert ok[0]["in"] == 7 and ok[0]["out"] == 3, ok[0]
assert ok[0]["port"] and ok[0]["client"] == "curl", ok[0]
bad = [e for e in lines if e.get("upstream_status") == 429 and e.get("status") == 429 and e.get("call_type") == "anthropic_messages"]
assert bad, [e for e in lines if not e.get("ok")]
assert bad[0]["rewritten"] is True and bad[0]["retry_after"] == 120, bad[0]
assert bad[0]["reset_source"] == "upstream-header:retry-after", bad[0]
quota = [e for e in lines if e.get("status") == 402]
assert quota and quota[0].get("quota") is True, quota
print("usage events ok")
PY

# --- enmaas flavor: config-driven routing ------------------------------------
local eport ecfg="$tmp/enmaas-config.json"
eport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
cat >| "$ecfg" <<JSON
{"model_list":[
 {"model_name":"*","litellm_params":{"model":"openai/*","api_base":"http://127.0.0.1:$stub_port/v1"}},
 {"model_name":"claude-x","litellm_params":{"model":"anthropic/claude-x","api_base":"http://127.0.0.1:$stub_port"}},
 {"model_name":"rits/anthropic-test","litellm_params":{"model":"anthropic/rits/anthropic-test","api_base":"http://127.0.0.1:$stub_port"}},
 {"model_name":"gpt-6","litellm_params":{"model":"openai/responses/gpt-6","api_base":"http://127.0.0.1:$stub_port/v1"}},
 {"model_name":"gpt-6#responses","litellm_params":{"model":"openai/gpt-6","api_base":"http://127.0.0.1:$stub_port/v1"}}
],"general_settings":{"master_key":"sk-enmaas-test"}}
JSON
env ENMAAS_API_KEY=test-key LLM_USAGE_DIR="$tmp/usage-enmaas" \
    "$bin" --flavor enmaas --config "$ecfg" --port "$eport" --runtime-dir "$tmp/state/enmaas-$eport" >"$tmp/enmaas.log" 2>&1 &
eproxy=$!
for i in {1..50}; do
    curl -sf --max-time 1 "http://127.0.0.1:$eport/health/liveliness" -o /dev/null && break
    sleep 0.1
done
curl -sf --max-time 1 "http://127.0.0.1:$eport/health/liveliness" -o /dev/null || fail "enmaas proxy did not start: $(<"$tmp/enmaas.log")"

local eurl="http://127.0.0.1:$eport"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$eurl/v1/messages" -H 'content-type: application/json' -H 'x-api-key: test-token' \
    -d '{"model":"claude-x","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}')
[[ "$code" == 401 ]] || fail "enmaas token must come from master_key: $code"

out=$(curl -s -X POST "$eurl/v1/messages" -H 'content-type: application/json' -H 'x-api-key: sk-enmaas-test' \
    -d '{"model":"claude-x","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}')
[[ "$out" == *'"path": "/v1/messages"'* && "$out" == *'"model": "claude-x"'* ]] || fail "anthropic route: $out"

out=$(curl -s -X POST "$eurl/v1/responses" -H 'content-type: application/json' -H 'authorization: Bearer sk-enmaas-test' \
    -d '{"model":"gpt-6","input":[{"role":"user","content":[{"type":"input_text","text":"hi"}]}],"max_output_tokens":8}')
[[ "$out" == *'"path": "/v1/responses"'* && "$out" == *'"model": "gpt-6"'* ]] || fail "#responses sibling route: $out"

out=$(curl -s -X POST "$eurl/v1/chat/completions" -H 'content-type: application/json' -H 'authorization: Bearer sk-enmaas-test' \
    -d '{"model":"something-new","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}')
[[ "$out" == *'"path": "/v1/chat/completions"'* && "$out" == *'"model": "something-new"'* ]] || fail "wildcard route: $out"

# additional_tools is flattened into tools for rits/ models (Codex item shape).
out=$(curl -s -X POST "$eurl/v1/chat/completions" -H 'content-type: application/json' -H 'authorization: Bearer sk-enmaas-test' \
    -d '{"model":"rits/zai-org/glm-5-3","max_tokens":8,"messages":[{"role":"user","content":"hi"}],"input":[{"type":"additional_tools","tools":[{"type":"function","name":"f"}]}]}')
[[ "$out" == *'"additional_tools": false'* && "$out" == *'"tools": 1'* ]] || fail "additional_tools not flattened: $out"

# Tool search (Claude Code's ToolSearch) is opened inline for rits/ models: the
# upstream cannot run the search server tool and rejects tool_reference blocks,
# so the search tool is dropped and every defer_loading cleared — the deferred
# definition reaches the model directly instead of a stripped placeholder.
out=$(curl -s -X POST "$eurl/v1/messages" -H 'content-type: application/json' -H 'x-api-key: sk-enmaas-test' \
    -d '{"model":"rits/anthropic-test","max_tokens":8,"messages":[{"role":"user","content":"hi"}],"tools":[{"type":"tool_search_tool_regex_20251119","name":"tool_search_tool_regex"},{"name":"Bash","input_schema":{"type":"object"}},{"name":"mcp__x__y","defer_loading":true,"input_schema":{"type":"object"}}]}')
[[ "$out" == *'"tool_search": false'* && "$out" == *'"deferred": 0'* && "$out" == *'"tools": 2'* ]] || fail "tool search not opened inline: $out"

# Graceful drain: SIGTERM stops accepting but lets an in-flight request finish
# (Close alone cut active streams mid-answer — a forced swap can retire a
# listener that is mid-request). The stub holds this one for 1.5 s.
local drain_code="$tmp/drain.code"
( curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST "$eurl/v1/chat/completions" -H 'content-type: application/json' \
    -H 'authorization: Bearer sk-enmaas-test' \
    -d '{"model":"something-new","max_tokens":8,"messages":[{"role":"user","content":"SLOW"}]}' >| "$drain_code" ) &
local drainer=$!
# Wait for the stub to hold the request (a fixed sleep let curl connect AFTER
# shutdown closed the listener on a loaded host); bounded.
for i in {1..200}; do [[ -e "$tmp/slow.started" ]] && break; sleep 0.05; done
[[ -e "$tmp/slow.started" ]] || fail "the stub never received the in-flight request"
kill -TERM "$eproxy"
wait $drainer
[[ "$(<"$drain_code")" == 200 ]] || fail "an in-flight request was cut by SIGTERM instead of drained: $(<"$drain_code")"
for i in {1..60}; do kill -0 "$eproxy" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$eproxy" 2>/dev/null; then fail "the proxy did not exit after draining"; fi
eproxy=

# Stop helper finds the Go process by its runtime dir.
HOSTED_ONLY_CLAUDE_PROXY_PORT=$pport _hosted_only_proxy_stop claude >/dev/null 2>&1 || fail "stop helper failed"
sleep 0.3
curl -sf --max-time 1 "http://127.0.0.1:$pport/health/liveliness" -o /dev/null && fail "proxy still listening after stop"
proxy=

# --- launcher go path: ensure / watch / stop -----------------------------------
# The whole start path now runs in the binary's ensure subcommand: routes.json
# generated from the knobs, detached spawn with log rotation, health wait,
# fingerprint record — and the stale/busy decision on later launches.
lp() { lsof -ti "tcp:$1" -sTCP:LISTEN 2>/dev/null | head -1 }
ensure_go() {
    ( export HOSTED_ONLY_PROXY_IMPL=go HOSTED_ONLY_CLAUDE_PROXY_PORT=$pport ENMAAS_API_KEY=test-key \
        HOSTED_ONLY_PROXY_TOKEN=test-token HOSTED_ONLY_ENMAAS_BASE_URL="http://127.0.0.1:$stub_port" \
        HOSTED_ONLY_ALIAS_MODELS=claude-sonnet-5-5 LLM_USAGE_DIR="$tmp/usage"
      _hosted_only_proxy_ensure "$@" )
}
stop_go() {
    ( export HOSTED_ONLY_PROXY_IMPL=go HOSTED_ONLY_CLAUDE_PROXY_PORT=$pport
      _hosted_only_proxy_stop "$@" )
}

ensure_go claude >/dev/null 2>"$tmp/ensure1.log" || fail "go ensure failed: $(<$tmp/ensure1.log)"
curl -sf --max-time 2 "http://127.0.0.1:$pport/health/liveliness" -o /dev/null || fail "ensure did not start a healthy proxy"
local rtdir2="$tmp/state/hosted-only-$pport"
[[ -s "$rtdir2/routes.json" ]] || fail "ensure must generate routes.json from the knobs"
[[ -s "$rtdir2/fingerprint" ]] || fail "ensure must record the fingerprint"
local pid1
pid1=$(lp $pport)
[[ -n "$pid1" ]] || fail "no listener after ensure"

# A second ensure with the same knobs finds it fresh: same pid, no restart.
ensure_go claude >/dev/null 2>&1 || fail "second ensure failed"
[[ "$(lp $pport)" == "$pid1" ]] || fail "a fresh ensure must not restart the proxy"

# A stale fingerprint on an idle proxy: ensure swaps it. Zero-refuse (#612): the
# replacement starts ALONGSIDE the old listener (SO_REUSEPORT) and the old pid
# retires only once the new one answers, so a health probe running every 50 ms
# through the whole restart must never be refused. One request first, so the
# proxy has an (empty) in-flight table and the idle check reads idle between the
# prober's connections.
curl -s -o /dev/null -X POST "http://127.0.0.1:$pport/v1/messages" -H 'content-type: application/json' -H 'x-api-key: test-token' \
    -d '{"model":"claude-sonnet-5-5","max_tokens":16,"messages":[{"role":"user","content":"warm"}]}'
print -r -- "bogus bogus" >| "$rtdir2/fingerprint"
local refused="$tmp/refused" probing="$tmp/probing"
: >| "$refused"; : >| "$probing"
(
    while [[ -e "$probing" ]]; do
        curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$pport/health/liveliness" || print -r -- x >> "$refused"
        sleep 0.05
    done
) &
local prober=$!
ensure_go claude >/dev/null 2>"$tmp/swap.log" || { rm -f "$probing"; wait $prober 2>/dev/null; fail "stale ensure failed: $(<$tmp/swap.log)"; }
rm -f "$probing"; wait $prober 2>/dev/null
# The prober alone cannot prove this (a Go proxy boots in ms, shorter than the
# probe interval), so pin the mechanism: the overlap swap ran and the
# stop-then-start fallback did not.
grep -q 'zero-gap swap' "$tmp/swap.log" || fail "stale restart did not use the zero-gap swap: $(<$tmp/swap.log)"
if grep -q 'overlap start did not take' "$tmp/swap.log"; then fail "swap fell back to stop-then-start (SO_REUSEPORT not shared): $(<$tmp/swap.log)"; fi
local pid3
pid3=$(lp $pport)
[[ -n "$pid3" && "$pid3" != "$pid1" ]] || fail "a stale idle proxy must be restarted"
[[ ! -s "$refused" ]] || fail "zero-refuse swap refused $(wc -l < "$refused") probe(s) mid-restart"
# tr: BSD wc -l pads the count with spaces ("       1" != 1)
[[ "$(lsof -ti "tcp:$pport" -sTCP:LISTEN 2>/dev/null | wc -l | tr -d " ")" == 1 ]] || fail "old listener not retired after the swap"
curl -sf --max-time 2 "http://127.0.0.1:$pport/health/liveliness" -o /dev/null || fail "restarted proxy not healthy"
[[ "$(<"$rtdir2/fingerprint")" != bogus* ]] || fail "ensure must repair the fingerprint file"
# The restarted proxy still serves: routes came from the knobs, not the file
# the test wrote by hand earlier.
out=$(curl -s -X POST "http://127.0.0.1:$pport/v1/messages" -H 'content-type: application/json' -H 'x-api-key: test-token' \
    -d '{"model":"claude-sonnet-5-5","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}')
[[ "$out" == *'"model": "rits/zai-org/glm-5-3"'* ]] || fail "ensured proxy does not serve the alias: $out"

# watch: the Go watcher restarts at the first idle moment and keeps the
# llm-proxy-sync pid/log contract.
local watchdir="$tmp/watch"
env HOSTED_ONLY_PROXY_IMPL=go HOSTED_ONLY_CLAUDE_PROXY_PORT=$pport ENMAAS_API_KEY=test-key \
    HOSTED_ONLY_PROXY_TOKEN=test-token HOSTED_ONLY_ENMAAS_BASE_URL="http://127.0.0.1:$stub_port" \
    HOSTED_ONLY_ALIAS_MODELS=claude-sonnet-5-5 LLM_USAGE_DIR="$tmp/usage" \
    "$bin" watch --flavor claude --port "$pport" --runtime-dir "$rtdir2" \
    --fingerprint bogus-watch --token-fp bogus-token --name glm-claude --state-dir "$watchdir" \
    --timeout 30s >/dev/null 2>&1 || fail "watch exited non-zero"
[[ "$(lp $pport)" != "$pid3" ]] || fail "watch must restart a stale proxy at the idle moment"
if [[ -f "$watchdir/watch-glm-claude.pid" ]]; then fail "watch must remove its pid file on exit"; fi
grep -q "restarted with the current code" "$watchdir/watch-glm-claude.log" || fail "watch log: $(<$watchdir/watch-glm-claude.log)"
curl -sf --max-time 2 "http://127.0.0.1:$pport/health/liveliness" -o /dev/null || fail "watch restart left no healthy proxy"

# The go branch of the zsh stop helper retires the listener.
stop_go claude >/dev/null 2>&1 || fail "go stop failed"
sleep 0.3
curl -sf --max-time 1 "http://127.0.0.1:$pport/health/liveliness" -o /dev/null && fail "proxy still listening after go stop"

print -r -- "ok hosted-only-go-proxy"
