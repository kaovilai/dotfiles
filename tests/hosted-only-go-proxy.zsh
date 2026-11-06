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
_hosted_only_proxy_vars claude
[[ "$_hop_impl" == litellm ]] || fail "default impl should be litellm: $_hop_impl"
HOSTED_ONLY_PROXY_IMPL=go _hosted_only_proxy_vars claude
[[ "$_hop_impl" == go ]] || fail "HOSTED_ONLY_PROXY_IMPL=go not read"
GLM_HYBRID_PROXY_IMPL=go _hosted_only_proxy_vars claude
[[ "$_hop_impl" == go ]] || fail "retired GLM_HYBRID_PROXY_IMPL ignored"
_hosted_only_proxy_vars claude

local bin
bin=$(_hosted_only_go_bin) || fail "go build failed"
[[ -x "$bin" ]] || fail "no binary at $bin"
[[ "$bin" == "$tmp/state/hosted-only-go/hosted-only-proxy" ]] || fail "binary path: $bin"

# --- stub upstream -----------------------------------------------------------
local stub_port pport
stub_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
pport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

python3 - "$stub_port" <<'PY' >"$tmp/stub.log" 2>&1 &
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

# 429 -> 503 with a reset, retry-after and x-should-retry, in the Messages shape.
local hdr="$tmp/headers"
code=$(curl -s -D "$hdr" -o "$tmp/body429" -w '%{http_code}' -X POST "$url" -H 'content-type: application/json' -H 'x-api-key: test-token' \
    -d '{"model":"rits/zai-org/glm-5-3","max_tokens":16,"messages":[{"role":"user","content":"TRIGGER429"}]}')
[[ "$code" == 503 ]] || fail "429 rewrite status: $code ($(<"$tmp/body429"))"
grep -qi '^retry-after: 120' "$hdr" || fail "retry-after missing: $(<"$hdr")"
grep -qi '^x-should-retry: false' "$hdr" || fail "x-should-retry missing: $(<"$hdr")"
[[ "$(<"$tmp/body429")" == *'(reset after 2m)'* ]] || fail "reset text missing: $(<"$tmp/body429")"
[[ "$(<"$tmp/body429")" == *'[429]'* ]] || fail "429 tag missing: $(<"$tmp/body429")"
[[ "$(<"$tmp/body429")" == *'rate_limit_error'* ]] || fail "inner error shape: $(<"$tmp/body429")"

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
bad = [e for e in lines if e.get("upstream_status") == 429 and e.get("status") == 503]
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

# Stop helper finds the Go process by its runtime dir.
HOSTED_ONLY_CLAUDE_PROXY_PORT=$pport _hosted_only_proxy_stop claude >/dev/null 2>&1 || fail "stop helper failed"
sleep 0.3
curl -sf --max-time 1 "http://127.0.0.1:$pport/health/liveliness" -o /dev/null && fail "proxy still listening after stop"
proxy=

print -r -- "ok hosted-only-go-proxy"
