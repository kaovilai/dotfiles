# ---------------------------------------------------------------------------
# claude-mlx: raw claude binary, routed through a local MLX model server
# (mlx-lm's `mlx_lm.server`, Apple Silicon only) via a local LiteLLM proxy --
# same reason claude-vertex needs one (see its comment above): mlx_lm.server
# only speaks OpenAI's /v1/chat/completions shape, not Anthropic's /v1/messages,
# unlike Ollama's server (which speaks Anthropic's shape natively, why
# claude-ollama above talks to it directly with no proxy in front).
#
# Verified before writing this (uvx --from mlx-lm mlx_lm.server --help, plus
# reading the installed mlx_lm/server.py): --model takes exactly one model --
# there's no Ollama-style multi-model hot-swap-per-request server. So unlike
# claude-ollama's three independently resolved tiers, claude-mlx uses ONE
# shared model for opus/sonnet/haiku -- there is nothing to independently
# resolve. Real registered routes confirmed in server.py: /v1/chat/completions,
# /v1/completions, /v1/models (GET), /health (GET) -- /health is the readiness
# probe below, not Ollama's /api/tags. Tool-calling is real
# (ToolCallFormatter/tokenizer.has_tool_calling/tool_calls in responses) but
# gated on the model's own tokenizer/chat-template declaring tool-call
# support -- not guaranteed for every mlx-community conversion.
#
# No vetted, benchmark-backed curated model list exists here the way
# _claude_ollama_candidates claims to have above -- not fabricating one.
# Default is a single well-established model built for agentic/tool use;
# override via CLAUDE_MLX_MODEL or persist a different one via
# claude-mlx-models below.
#
# Same litellm/fastapi pins as claude-vertex (BerriAI/litellm#24518 --
# see its comment above), minus the "google" extra (Vertex-specific).
typeset -g CLAUDE_MLX_PROXY_LITELLM_VERSION="1.97.0"
typeset -g CLAUDE_MLX_PROXY_FASTAPI_VERSION="0.136.3"
typeset -g _claude_mlx_model_file="${XDG_CONFIG_HOME:-$HOME/.config}/claude-mlx-model"
typeset -g _claude_mlx_proxy_config="${XDG_CONFIG_HOME:-$HOME/.config}/claude-mlx-proxy.yaml"
typeset -g CLAUDE_MLX_DEFAULT_MODEL="mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"

# MLX (Apple's ML framework) only runs on Apple Silicon -- gates both
# claude-mlx() itself (hard error if unsupported) and claude-offline()'s
# dispatch decision below.
_claude_mlx_supported() {
    [[ "$(uname)" == "Darwin" && "$(uname -m)" == "arm64" ]]
}

_claude_mlx_base() {
    print -r -- "http://127.0.0.1:${CLAUDE_MLX_PORT:-4143}"
}

# Resolve the one shared MLX model: explicit env override, else whatever's
# persisted (via claude-mlx-models), else the curated default above.
_claude_mlx_resolve_model() {
    if [[ -n "$CLAUDE_MLX_MODEL" ]]; then
        print -r -- "$CLAUDE_MLX_MODEL"
        return 0
    fi
    if [[ -r "$_claude_mlx_model_file" ]]; then
        local persisted
        persisted=$(<"$_claude_mlx_model_file")
        [[ -n "$persisted" ]] && { print -r -- "$persisted"; return 0; }
    fi
    print -r -- "$CLAUDE_MLX_DEFAULT_MODEL"
}

# Ensure a local mlx_lm.server is reachable, auto-starting one if not.
# Mirrors _claude_ollama_ensure_server's shape exactly (detached subshell +
# up-to-60s poll loop + log-file-under-TMPDIR idiom) -- only the readiness
# probe path differs (/health, not Ollama's /api/tags).
_claude_mlx_ensure_server() {
    local model="$1"
    local base="$(_claude_mlx_base)"
    local port="${CLAUDE_MLX_PORT:-4143}"
    local log="${TMPDIR:-/tmp}/mlx-lm-server.log"

    curl -sf --max-time 2 "${base}/health" -o /dev/null && return 0

    if ! command -v uv &>/dev/null; then
        echo "❌ uv not found. Install it with: $(_claude_pkg_install_hint uv 'curl -LsSf https://astral.sh/uv/install.sh | sh')" >&2
        return 1
    fi

    echo "Starting mlx_lm.server (model: ${model}) on ${base} (log: ${log})..." >&2
    echo "First run downloads the model from Hugging Face -- can take several minutes for a 15-20GB+ 4bit repo." >&2
    (uvx --from mlx-lm mlx_lm.server --model "$model" --port "$port" >> "${log}" 2>&1 &)
    local SECONDS=0
    while (( SECONDS < 60 )); do
        curl -sf --max-time 2 "${base}/health" -o /dev/null && return 0
        sleep 1
    done
    echo "❌ mlx_lm.server not ready on ${base} after 60s (still downloading/loading the model?)." >&2
    echo "   Check the log: tail -f ${log}" >&2
    return 1
}

# Writes the litellm proxy config translating Anthropic's /v1/messages shape
# (what Claude Code speaks) to mlx_lm.server's OpenAI-compatible
# /v1/chat/completions -- mirrors _claude_vertex_proxy_write_config's shape,
# but a single model_name entry is enough here (one shared model, not three
# independently resolved tiers): claude-mlx() below exports the SAME resolved
# model id for ANTHROPIC_MODEL/ANTHROPIC_DEFAULT_OPUS_MODEL/
# ANTHROPIC_DEFAULT_SONNET_MODEL/ANTHROPIC_DEFAULT_HAIKU_MODEL.
_claude_mlx_proxy_write_config() {
    local model="$1" mlx_base="$2" master_key="$3"
    mkdir -p "${_claude_mlx_proxy_config:h}"
    cat > "$_claude_mlx_proxy_config" <<EOF
model_list:
  - model_name: ${model}
    litellm_params:
      model: openai/${model}
      api_base: ${mlx_base}/v1
      api_key: "mlx-local"
litellm_settings:
  master_key: "${master_key}"
EOF
}

# Resolves the model, ensures mlx_lm.server + the litellm proxy are both up,
# hands the result back via globals (_cmx_*) -- same zsh `local`-doesn't-
# cross-function-boundaries reason _claude_vertex_prepare uses _cv_* above.
_claude_mlx_prepare() {
    local model
    model=$(_claude_mlx_resolve_model)

    # Hot reload -- see _claude_proxy_sync. mlx_lm.server can't hot-swap
    # models, so a changed model (env var or claude-mlx-models) restarts it
    # together with its proxy (claude-mlx-kill kills both). No credentials
    # involved. A running pair with no recorded fingerprint is adopted.
    local mlx_master_key="${CLAUDE_MLX_PROXY_TOKEN:-mlx-proxy-local}"
    local mfp
    mfp=$(_claude_proxy_fp "$model" "$mlx_master_key" "$CLAUDE_MLX_PROXY_LITELLM_VERSION")
    _claude_proxy_sync claude-mlx mlx "$(_claude_mlx_base)/health" "$mfp" claude-mlx-kill 1

    _claude_mlx_ensure_server "$model" || return 1

    local port="${CLAUDE_MLX_PROXY_PORT:-4144}"
    local base="http://127.0.0.1:${port}"
    local log="${TMPDIR:-/tmp}/claude-mlx-proxy-${port}.log"
    local master_key="${CLAUDE_MLX_PROXY_TOKEN:-mlx-proxy-local}"

    if ! curl -sf --max-time 2 "${base}/health/liveliness" -o /dev/null; then
        if ! _claude_mlx_proxy_write_config "$model" "$(_claude_mlx_base)" "$master_key"; then
            echo "❌ Failed to write claude-mlx proxy config to ${_claude_mlx_proxy_config}." >&2
            return 1
        fi
        echo "Starting claude-mlx proxy (litellm ${CLAUDE_MLX_PROXY_LITELLM_VERSION}) on ${base} (log: ${log})..."
        (uv tool run --with "fastapi==${CLAUDE_MLX_PROXY_FASTAPI_VERSION}" \
            --from "litellm[proxy]==${CLAUDE_MLX_PROXY_LITELLM_VERSION}" litellm \
            --config "$_claude_mlx_proxy_config" --port "$port" --host 127.0.0.1 >> "${log}" 2>&1 &)
        local i
        for i in {1..60}; do
            curl -sf --max-time 2 "${base}/health/liveliness" -o /dev/null && break
            sleep 1
        done
        if ! curl -sf --max-time 2 "${base}/health/liveliness" -o /dev/null; then
            echo "❌ claude-mlx proxy not ready on ${base} after 60s." >&2
            echo "   Check the log: tail -f ${log}" >&2
            return 1
        fi
    fi
    _claude_proxy_record mlx "$mfp"

    typeset -g _cmx_base="$base" _cmx_master_key="$master_key" _cmx_model="$model"
}

claude-mlx() {
    if ! _claude_mlx_supported; then
        echo "❌ MLX requires Apple Silicon macOS. Use claude-ollama instead." >&2
        return 1
    fi
    _claude_mlx_prepare || return 1

    # Scrub any stale gateway/Vertex/Ollama config before routing to MLX --
    # same rationale as claude-ollama's use of this helper above.
    _claude_copilot_unset_env

    local -a envs
    envs=(
        ANTHROPIC_BASE_URL="${_cmx_base}"
        ANTHROPIC_AUTH_TOKEN="${_cmx_master_key}"
        # Explicitly blanked -- same reason claude-ollama does this above: a
        # real key exported elsewhere could otherwise take precedence and
        # silently defeat offline mode.
        ANTHROPIC_API_KEY=""
        ANTHROPIC_MODEL="${_cmx_model}"
        ANTHROPIC_DEFAULT_OPUS_MODEL="${_cmx_model}"
        ANTHROPIC_DEFAULT_SONNET_MODEL="${_cmx_model}"
        ANTHROPIC_DEFAULT_HAIKU_MODEL="${_cmx_model}"
    )

    # --bare by default -- same rationale as claude-ollama above: a small
    # local model gets overwhelmed by full session context. Opt back in via
    # CLAUDE_MLX_FULL_CONTEXT=1.
    local -a bare_flag=(--bare)
    [[ -n "$CLAUDE_MLX_FULL_CONTEXT" && "$CLAUDE_MLX_FULL_CONTEXT" != 0 ]] && bare_flag=()
    export "${envs[@]}"
    _claude_picker_args opus="${_cmx_model}" sonnet="${_cmx_model}" haiku="${_cmx_model}"
    command claude "${reply[@]}" "${bare_flag[@]}" "$@"
}

# claude-mlx-kill: stop both local processes claude-mlx starts -- the
# mlx_lm.server AND the litellm proxy in front of it. Unlike every other
# *-kill function in this file (one process each), MLX is the only backend
# needing two, since (unlike Ollama) it has no native Anthropic-compatible
# endpoint of its own to talk to directly.
claude-mlx-kill() {
    local -a ports=("${CLAUDE_MLX_PORT:-4143}" "${CLAUDE_MLX_PROXY_PORT:-4144}")
    local -a labels=("mlx_lm.server" "claude-mlx proxy")
    local i port label pids
    for i in {1..2}; do
        port="${ports[$i]}"
        label="${labels[$i]}"
        pids=("${(f)$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null)}")
        if [[ -z "${pids[1]}" ]]; then
            echo "No process listening on port ${port} (${label})."
            continue
        fi
        echo "Killing ${label} on port ${port} (pid: ${pids[*]})..."
        kill "${pids[@]}" 2>/dev/null
        sleep 1
        pids=("${(f)$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null)}")
        if [[ -n "${pids[1]}" ]]; then
            echo "Still alive, sending SIGKILL..."
            kill -9 "${pids[@]}" 2>/dev/null
        fi
    done
}

# claude-mlx-models: print (no arg) or persist (arg) the one shared MLX
# model. Much simpler than claude-ollama-models -- no fzf picker, no
# per-tier keys, since there's only one shared model slot (see
# claude-mlx's comment above on why: mlx_lm.server takes exactly one
# --model, no per-request hot-swap). A live mlx_lm.server can't hot-swap
# models, so this just warns to restart rather than attempting one.
claude-mlx-models() {
    if (( $# > 1 )); then
        echo "Usage: claude-mlx-models [mlx-community/<repo-id>]" >&2
        return 1
    fi
    if [[ -z "$1" ]]; then
        echo "$(_claude_mlx_resolve_model)"
        return 0
    fi
    mkdir -p "${_claude_mlx_model_file:h}"
    print -r -- "$1" >| "$_claude_mlx_model_file"
    echo "Persisted claude-mlx model: $1"
    if curl -sf --max-time 2 "$(_claude_mlx_base)/health" -o /dev/null; then
        echo "A mlx_lm.server is already running and can't hot-swap models -- run claude-mlx-kill before your next claude-mlx." >&2
    fi
}
