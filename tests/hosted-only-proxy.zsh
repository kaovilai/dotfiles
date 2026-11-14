#!/bin/zsh
# Offline tests for scripts/hosted-only-proxy.zsh (the Go impl is the only
# impl): generated config, hosted-only/legacy knob names, runtime dirs, the
# impl-retirement errors, retired-name aliases, and the launcher contracts.
# The Go proxy itself is exercised by tests/hosted-only-go-proxy.zsh. No
# network, no real key. Skipped when `go` is not installed.
emulate -LR zsh
setopt err_exit pipe_fail
local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { print -ru2 -- "FAIL: $*"; exit 1; }

if ! command -v go >/dev/null; then
    print -ru2 -- "skip: go not installed"
    exit 0
fi

export XDG_STATE_HOME="$tmp/state"
unset HOSTED_ONLY_CLAUDE_PROXY_PORT HOSTED_ONLY_CODEX_PROXY_PORT HOSTED_ONLY_GLM_MODEL HOSTED_ONLY_PROXY_TOKEN \
    GLM_HYBRID_CLAUDE_PROXY_PORT GLM_HYBRID_CODEX_PROXY_PORT GLM_HYBRID_MODEL GLM_HYBRID_PROXY_TOKEN \
    HOSTED_ONLY_PROXY_IMPL GLM_HYBRID_PROXY_IMPL LLM_PROXY_IMPL
source "$repo/scripts/hosted-only-proxy.zsh"
source "$repo/zsh/functions/claude/common.zsh"   # _claude_auto_compact_window for the launcher block

# Defaults
_hosted_only_proxy_vars codex
[[ "$_hop_port" == 4148 && "$_hop_runtime" == "$tmp/state/hosted-only-4148" ]] || fail "codex defaults (shared port, #599): $_hop_port $_hop_runtime"
[[ "${_hop_legacy_runtimes[2]}" == "$tmp/state/hosted-only-codex-4148" ]] || fail "legacy flavor dir: ${_hop_legacy_runtimes[*]}"
[[ "$_hop_token" == hosted-only-local ]] || fail "token default: $_hop_token"
_hosted_only_proxy_vars claude
[[ "$_hop_port" == 4148 ]] || fail "claude port: $_hop_port"
HOSTED_ONLY_CODEX_PROXY_PORT=4147 _hosted_only_proxy_vars codex
[[ "$_hop_port" == 4147 && "$_hop_runtime" == "$tmp/state/hosted-only-4147" ]] || fail "split-mode codex port: $_hop_port $_hop_runtime"
unset HOSTED_ONLY_CODEX_PROXY_PORT
_hosted_only_proxy_vars bogus 2>/dev/null && fail "bogus flavor accepted"

# The Go proxy is the only impl: the default is go, and the retired
# HOSTED_ONLY_PROXY_IMPL / LLM_PROXY_IMPL=litellm knobs fail loudly.
[[ "$_hop_impl" == go ]] || fail "default impl should be go: $_hop_impl"
HOSTED_ONLY_PROXY_IMPL=go _hosted_only_proxy_vars claude
[[ "$_hop_impl" == go ]] || fail "HOSTED_ONLY_PROXY_IMPL=go not read: $_hop_impl"
GLM_HYBRID_PROXY_IMPL=go _hosted_only_proxy_vars claude
[[ "$_hop_impl" == go ]] || fail "retired GLM_HYBRID_PROXY_IMPL=go ignored: $_hop_impl"
HOSTED_ONLY_PROXY_IMPL=LITELLM _hosted_only_proxy_vars claude 2>/dev/null && fail "HOSTED_ONLY_PROXY_IMPL=litellm must fail"
LLM_PROXY_IMPL=litellm _hosted_only_proxy_vars claude 2>/dev/null && fail "LLM_PROXY_IMPL=litellm must fail"
HOSTED_ONLY_PROXY_IMPL=bogus _hosted_only_proxy_vars claude 2>/dev/null && fail "an unknown impl value must fail"
_hosted_only_proxy_vars claude

# Config: both models in BOTH dialects (#599 merge), no OpenAI/luna route,
# claude sonnet alias served regardless of flavor. The YAML is documentation
# and a fingerprint input now (the Go binary serves from routes.json).
local cfg
_hosted_only_proxy_vars claude
cfg=$(_hosted_only_proxy_config)
[[ "$cfg" == *'"anthropic/rits/deepseek-ai/DeepSeek-V4.1-Flash-1017"'* && "$cfg" == *'Muse-Spark-Open-816B-A42B-NVFP4'* ]] || fail "claude config lacks hosted models: $cfg"
[[ "$cfg" == *'os.environ/HOSTED_ONLY_PROXY_TOKEN'* && "$cfg" == *'claude-sonnet-5-5'* ]] || fail "claude config shape"
[[ "$cfg" != *luna* && "$cfg" != *api.openai.com* ]] || fail "OpenAI route leaked into config"
[[ "$cfg" != *callbacks* && "$cfg" != *router_settings* && "$cfg" != *litellm_settings* ]] || fail "LiteLLM-only config blocks survived the retirement: $cfg"
_hosted_only_proxy_vars codex
cfg=$(_hosted_only_proxy_config)
[[ "$cfg" == *'"openai/rits/deepseek-ai/DeepSeek-V4.1-Flash-1017"'* && "$cfg" == *'/v1"'* ]] || fail "codex dialect missing from merged config: $cfg"
[[ "$cfg" == *'DeepSeek-V4.1-Flash-1017#openai'* && "$cfg" == *'Muse-Spark-Open-816B-A42B-NVFP4#openai'* ]] || fail "suffixed groups missing: $cfg"
[[ "$cfg" == *'claude-sonnet-5-5'* ]] || fail "merged config must serve the claude alias for both flavors: $cfg"
[[ "${cfg##*model_name: \"rits/deepseek-ai/DeepSeek-V4.1-Flash-1017\"}" == *'#openai'* ]] || fail "bare primary group and suffixed group must be distinct entries: $cfg"
# the anthropic and openai deployments of the same model must not share a group
[[ "$(grep -c 'model_name:' <<< "$cfg")" == 5 ]] || fail "merged config must have 5 deployments (primary, primary#openai, fallback, fallback#openai, alias): $cfg"

# knob defaults and overrides (fingerprint inputs)
[[ "$_hop_fallback" == "1 1 60 600 1048576 512 3 16000" ]] || fail "fallback knob defaults: $_hop_fallback"
HOSTED_ONLY_FALLBACK=0 HOSTED_ONLY_MAX_MODEL_LEN=999999 _hosted_only_proxy_vars codex
[[ "$_hop_fallback" == "0 1 60 600 999999 512 3 16000" ]] || fail "HOSTED_ONLY_FALLBACK / MAX_MODEL_LEN not read: $_hop_fallback"
_hosted_only_proxy_vars codex
# The merged config serves the claude alias for both flavors, so the alias knob
# (and the fingerprint it feeds) is flavor-independent
[[ "$_hop_aliases" == "claude-sonnet-5-5,rits/zai-org/glm-5-3" ]] || fail "codex flavor alias default (merged): $_hop_aliases"
[[ "$_hop_request_timeout" == 180 ]] || fail "request timeout default: $_hop_request_timeout"
_hosted_only_proxy_vars claude
[[ "$_hop_aliases" == "claude-sonnet-5-5,rits/zai-org/glm-5-3" ]] || fail "claude flavor alias default: $_hop_aliases"
HOSTED_ONLY_ALIAS_MODELS=x,y _hosted_only_proxy_vars claude
[[ "$_hop_aliases" == "x,y" ]] || fail "HOSTED_ONLY_ALIAS_MODELS not read: $_hop_aliases"
HOSTED_ONLY_REQUEST_TIMEOUT=99 _hosted_only_proxy_vars claude
[[ "$_hop_request_timeout" == 99 ]] || fail "HOSTED_ONLY_REQUEST_TIMEOUT not read: $_hop_request_timeout"
_hosted_only_proxy_vars codex
HOSTED_ONLY_IMAGE_BUDGET_BYTES=123 HOSTED_ONLY_IMAGE_CACHE_DAYS=2 _hosted_only_proxy_vars codex
[[ "$_hop_image_budget" == 123 && "$_hop_image_cache_days" == 2 ]] || fail "image knobs: $_hop_image_budget $_hop_image_cache_days"
_hosted_only_proxy_vars codex
[[ "$_hop_image_budget" == 2500000 && "$_hop_image_cache_days" == 1 ]] || fail "image knob defaults: $_hop_image_budget $_hop_image_cache_days"
[[ "$(<"$repo/scripts/hosted-only-proxy.zsh")" == *'$_hop_client_retry $_hop_fallback $_hop_aliases $_hop_request_timeout $(_hosted_only_knob STREAM_IDLE_TIMEOUT 300) $_hop_image_budget $_hop_image_cache_days $(_hosted_only_knob IMAGE_WINDOW_TURNS 6) $_hop_dialect $dns_host'* ]] || fail "fingerprint knob list changed without this test following"

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

# Dry run (HOSTED_ONLY_CHECK_OUT): "down|fresh|stale <fp> <token hash>", return 1, nothing started or written.
(
    chk_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
    export HOSTED_ONLY_CODEX_PROXY_PORT=$chk_port ENMAAS_API_KEY=check-key HOSTED_ONLY_CHECK_OUT="$tmp/check-out"
    _hosted_only_proxy_vars codex
    _hosted_only_proxy_ensure codex 2>/dev/null && fail "dry run must return 1"
    read -r verdict fp tokfp < "$tmp/check-out"
    [[ "$verdict" == down && ${#fp} == 64 && ${#tokfp} == 64 ]] || fail "down verdict: $(<"$tmp/check-out")"
    [[ ! -e "$_hop_runtime/routes.json" ]] || fail "dry run wrote a routes file"
    python3 -c 'import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()' "$chk_port" &
    srv=$!
    for i in {1..50}; do curl -sf --max-time 1 "http://127.0.0.1:$chk_port/health/liveliness" -o /dev/null && break; sleep 0.1; done
    _hosted_only_proxy_ensure codex 2>/dev/null
    [[ "$(cut -d' ' -f1 "$tmp/check-out")" == stale ]] || { kill $srv; fail "no fingerprint should read stale: $(<"$tmp/check-out")"; }
    mkdir -p "$_hop_runtime"; print -r -- "$fp $tokfp" > "$_hop_runtime/fingerprint"
    _hosted_only_proxy_ensure codex 2>/dev/null
    [[ "$(cut -d' ' -f1 "$tmp/check-out")" == fresh ]] || { kill $srv; fail "matching fingerprint should read fresh: $(<"$tmp/check-out")"; }
    print -r -- "$fp" > "$_hop_runtime/fingerprint"     # pre-split file: one field, token unknown -> unchanged
    _hosted_only_proxy_ensure codex 2>/dev/null
    [[ "$(cut -d' ' -f1 "$tmp/check-out")" == fresh ]] || { kill $srv; fail "one-field fingerprint should read fresh: $(<"$tmp/check-out")"; }
    print -r -- "$fp otherhash" > "$_hop_runtime/fingerprint"
    _hosted_only_proxy_ensure codex 2>/dev/null
    [[ "$(cut -d' ' -f1 "$tmp/check-out")" == stale ]] || { kill $srv; fail "token change should read stale: $(<"$tmp/check-out")"; }
    HOSTED_ONLY_IMAGE_BUDGET_BYTES=1 _hosted_only_proxy_ensure codex 2>/dev/null
    [[ "$(cut -d' ' -f1 "$tmp/check-out")" == stale ]] || { kill $srv; fail "knob change should read stale: $(<"$tmp/check-out")"; }
    kill $srv 2>/dev/null
    [[ "$(print -r -- "$fp $tokfp" >| "$_hop_runtime/fingerprint"; ls "$_hop_runtime")" == fingerprint ]] || fail "dry run left files: $(ls "$_hop_runtime")"
    exit 0
) || exit 1

# New knob names win; retired GLM_HYBRID_* names still work
HOSTED_ONLY_CODEX_PROXY_PORT=4157 _hosted_only_proxy_vars codex
[[ "$_hop_port" == 4157 && "$_hop_runtime" == *hosted-only-4157 ]] || fail "HOSTED_ONLY port: $_hop_port $_hop_runtime"
GLM_HYBRID_CODEX_PROXY_PORT=4167 GLM_HYBRID_MODEL=rits/x/old GLM_HYBRID_PROXY_TOKEN=oldtok _hosted_only_proxy_vars codex
[[ "$_hop_port" == 4167 && "$_hop_glm" == rits/x/old && "$_hop_token" == oldtok ]] || fail "legacy knobs ignored: $_hop_port $_hop_glm $_hop_token"
GLM_HYBRID_CODEX_PROXY_PORT=4167 HOSTED_ONLY_CODEX_PROXY_PORT=4177 HOSTED_ONLY_GLM_MODEL=rits/x/new GLM_HYBRID_MODEL=rits/x/old _hosted_only_proxy_vars codex
[[ "$_hop_port" == 4177 && "$_hop_glm" == rits/x/new ]] || fail "new knob should beat legacy: $_hop_port $_hop_glm"

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
[[ "$(jq -r .env.CLAUDE_CODE_RETRY_WATCHDOG <<< "$launched")" == 1 ]] || fail "CLAUDE_CODE_RETRY_WATCHDOG default: $launched"
launched=$(HOSTED_ONLY_CLIENT_MAX_RETRIES=7 _claude_hosted_launch) || fail "launcher stub run (knob)"
[[ "$(jq -r .env.CLAUDE_CODE_MAX_RETRIES <<< "$launched")" == 7 ]] || fail "HOSTED_ONLY_CLIENT_MAX_RETRIES ignored: $launched"
# Claude Code's own 32k output ceiling, raised for the hosted models
local launched_out
launched_out=$(_claude_hosted_launch) || fail "launcher stub run (max output)"
[[ "$(jq -r .env.CLAUDE_CODE_MAX_OUTPUT_TOKENS <<< "$launched_out")" == 128000 ]] || fail "CLAUDE_CODE_MAX_OUTPUT_TOKENS default: $launched_out"
launched_out=$(HOSTED_ONLY_MAX_OUTPUT_TOKENS=96000 _claude_hosted_launch) || fail "launcher stub run (max output knob)"
[[ "$(jq -r .env.CLAUDE_CODE_MAX_OUTPUT_TOKENS <<< "$launched_out")" == 96000 ]] || fail "HOSTED_ONLY_MAX_OUTPUT_TOKENS ignored: $launched_out"
# Claude Code compacts 33000 under CLAUDE_CODE_AUTO_COMPACT_WINDOW and reserves
# none of our 128000 output cap, so the launcher derives the window from it:
# 1048576 - 512 - 128000 - 45000 drift + 33000 = 908000 (see
# _claude_auto_compact_window in common.zsh for the arithmetic and coupling)
launched_out=$(_claude_hosted_launch) || fail "launcher stub run (compact window)"
[[ "$(jq -r .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW <<< "$launched_out")" == 908000 ]] || fail "CLAUDE_CODE_AUTO_COMPACT_WINDOW default: $launched_out"
launched_out=$(HOSTED_ONLY_MAX_OUTPUT_TOKENS=96000 _claude_hosted_launch) || fail "launcher stub run (compact window follows the output cap)"
[[ "$(jq -r .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW <<< "$launched_out")" == 940000 ]] || fail "window must follow HOSTED_ONLY_MAX_OUTPUT_TOKENS: $launched_out"
launched_out=$(HOSTED_ONLY_AUTO_COMPACT_WINDOW=650000 _claude_hosted_launch) || fail "launcher stub run (compact window override)"
[[ "$(jq -r .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW <<< "$launched_out")" == 650000 ]] || fail "HOSTED_ONLY_AUTO_COMPACT_WINDOW ignored: $launched_out"
launched_out=$(HOSTED_ONLY_AUTO_COMPACT_WINDOW=off _claude_hosted_launch) || fail "launcher stub run (compact window off)"
[[ "$(jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW // "absent"' <<< "$launched_out")" == absent ]] || fail "off must leave the window unset: $launched_out"
launched_out=$(HOSTED_ONLY_COMPACT_DRIFT_MARGIN=90000 _claude_hosted_launch) || fail "launcher stub run (drift margin)"
[[ "$(jq -r .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW <<< "$launched_out")" == 863000 ]] || fail "HOSTED_ONLY_COMPACT_DRIFT_MARGIN ignored: $launched_out"
# the helper's guard rails: floor on a mistyped knob, nothing on a non-number
[[ "$(_claude_auto_compact_window 9999999)" == 200000 && -z "$(_claude_auto_compact_window abc)" ]] || fail "compact window floor / bad input"

# the search-less upstream gets web search from the Parallel MCP (issue 602)
launched_out=$(_claude_hosted_launch) || fail "launcher stub run (search mcp)"
[[ "$(jq -r '.mcpServers.parallel.type' <<< "$launched_out")" == http && "$(jq -r '.mcpServers.parallel.url' <<< "$launched_out")" == https://mcp.parallel.ai/mcp ]] || fail "parallel MCP not registered by default: $launched_out"
launched_out=$(HOSTED_ONLY_SEARCH_MCP_URL=https://example.invalid/mcp _claude_hosted_launch) || fail "launcher stub run (search mcp knob)"
[[ "$(jq -r '.mcpServers.parallel.url' <<< "$launched_out")" == https://example.invalid/mcp ]] || fail "HOSTED_ONLY_SEARCH_MCP_URL ignored: $launched_out"
launched_out=$(HOSTED_ONLY_SEARCH_MCP_URL= _claude_hosted_launch) || fail "launcher stub run (search mcp off)"
[[ "$(jq -r '.mcpServers.parallel // "absent"' <<< "$launched_out")" == absent ]] || fail "empty HOSTED_ONLY_SEARCH_MCP_URL must disable the MCP: $launched_out"

print -r -- "ok hosted-only-proxy"
