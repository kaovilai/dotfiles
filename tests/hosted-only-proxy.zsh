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

# Hook helpers (python), including the retired env-name fallback
GLM_HYBRID_VISION_FALLBACK=0 GLM_HYBRID_MODEL=rits/x/old python3 -I - "$repo/scripts" <<'EOF' || fail "hook module"
import sys, types
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
class E(Exception):
    status_code = 429
out = h.rewrite_limit(E("token budget exhausted"), {"model": "m", "proxy_server_request": {"url": "/v1/responses"}}, now=1_700_000_000)
assert out.status_code == 429 and out.headers["x-codex-primary-used-percent"] == "100", out.headers
out = h.rewrite_limit(E("slow down"), {"model": "m", "proxy_server_request": {"url": "/v1/messages"}}, now=1_700_000_000)
assert out.status_code == 503 and "reset after 1m" in out.detail, out.detail
assert h.rewrite_limit(Exception("boom"), {}) is None
EOF

print -r -- "ok hosted-only-proxy"
