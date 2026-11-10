# ---------------------------------------------------------------------------
# claude-mlx: raw claude binary, routed through a local MLX model server
# (mlx-lm's `mlx_lm.server`, Apple Silicon only) via the shared Go proxy's
# "mlx" flavor (scripts/hosted-only-go, port 4144) -- same reason
# claude-openai needs one: mlx_lm.server only speaks OpenAI's
# /v1/chat/completions shape, not Anthropic's /v1/messages, unlike Ollama's
# server (which speaks Anthropic's shape natively, why claude-ollama above
# talks to it directly with no proxy in front). The LiteLLM proxy this used
# to spawn is retired -- same retirement the hosted-only and enmaas
# launchers already made (~377 MB and a slow cold start saved).
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
# The litellm/fastapi pins this file used to carry (BerriAI/litellm#24518,
# see claude-vertex's comment above) died with the retired LiteLLM proxy;
# the Go proxy needs none.
typeset -g _claude_mlx_model_file="${XDG_CONFIG_HOME:-$HOME/.config}/claude-mlx-model"
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

# mlx_lm.server answers /health BEFORE the weights are resident -- it binds
# its socket first and loads the model lazily on the first completion (a
# freshly-started server idles at ~100MB RSS while "Fetching 15 files").
# Probe the listener's RSS instead: already multi-GB means the weights are
# in (or loading into) RAM and no forcing is needed; otherwise send a
# 1-token completion so the download/load happens here, in the wrapper,
# instead of inside Claude's first API request where it would look like a
# hung turn. CLAUDE_MLX_LOAD_TIMEOUT (default 600s) bounds a first-ever
# 15-20GB+ download.
_claude_mlx_wait_loaded() {
    local model="$1" base="$2" pid rss
    pid=$(_claude_listen_pids "${CLAUDE_MLX_PORT:-4143}" | head -1)
    if [[ -n "$pid" ]]; then
        rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
        # rss is in KB; the smallest useful 4bit weights are multiple GB.
        [[ -n "$rss" && "$rss" -gt 10000000 ]] && return 0
    fi
    local timeout="${CLAUDE_MLX_LOAD_TIMEOUT:-600}"
    echo "Loading ${model} into RAM (first run downloads it -- up to ${timeout}s)..." >&2
    if curl -sf --max-time "$timeout" "${base}/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" \
        -o /dev/null; then
        return 0
    fi
    echo "❌ ${model} failed to load within ${timeout}s." >&2
    echo "   Check the log: tail -f ${TMPDIR:-/tmp}/mlx-lm-server.log" >&2
    return 1
}

# The mlx_lm.server start command and log, shared by the Go proxy's warm gate
# (scripts/hosted-only-go/warm.go) and the optional blocking preload below.
_claude_mlx_server_cmd() {
    local model="$1" port="${CLAUDE_MLX_PORT:-4143}"
    print -r -- "uvx --from mlx-lm mlx_lm.server --model ${(q)model} --port ${port}"
}
_claude_mlx_server_log() { print -r -- "${TMPDIR:-/tmp}/mlx-lm-server.log" }

# Ensure a local mlx_lm.server is reachable, auto-starting one if not.
# Mirrors _claude_ollama_ensure_server's shape exactly (detached subshell +
# up-to-60s poll loop + log-file-under-TMPDIR idiom) -- only the readiness
# probe path differs (/health, not Ollama's /api/tags).
#
# NOTHING here may start mlx_lm.server unless CLAUDE_MLX_PRELOAD=1: the server
# loads its ~17 GB of weights at STARTUP (observed 2026-11-10), and everything
# that spawns this wrapper -- T3's periodic provider capability probe above
# all -- would otherwise pull the model into RAM to read an account name. The
# Go proxy's warm gate owns the start: the first REAL API request through
# :4144 spawns the server and answers 429 + retry-after until the weights are
# resident, so a cold turn retries instead of timing out and probes load
# nothing.
_claude_mlx_ensure_server() {
    local model="$1"
    local base="$(_claude_mlx_base)"

    if [[ "${CLAUDE_MLX_PRELOAD:-0}" == 0 ]]; then
        return 0
    fi

    local port="${CLAUDE_MLX_PORT:-4143}"
    local log="$(_claude_mlx_server_log)"

    if ! curl -sf --max-time 2 "${base}/health" -o /dev/null; then
        if ! command -v uv &>/dev/null; then
            echo "❌ uv not found. Install it with: $(_claude_pkg_install_hint uv 'curl -LsSf https://astral.sh/uv/install.sh | sh')" >&2
            return 1
        fi

        echo "Starting mlx_lm.server (model: ${model}) on ${base} (log: ${log})..." >&2
        (uvx --from mlx-lm mlx_lm.server --model "$model" --port "$port" >> "${log}" 2>&1 &)
        local SECONDS=0
        while (( SECONDS < 60 )); do
            curl -sf --max-time 2 "${base}/health" -o /dev/null && break
            sleep 1
        done
        if ! curl -sf --max-time 2 "${base}/health" -o /dev/null; then
            echo "❌ mlx_lm.server not ready on ${base} after 60s (still downloading the model?)." >&2
            echo "   Check the log: tail -f ${log}" >&2
            return 1
        fi
    fi

    _claude_mlx_wait_loaded "$model" "$base"
}

# Resolves the model, ensures mlx_lm.server + the Go proxy are both up,
# hands the result back via globals (_cmx_*) -- same zsh `local`-doesn't-
# cross-function-boundaries reason _claude_vertex_prepare uses _cv_* above.
#
# The proxy is the shared Go binary's "mlx" flavor (_claude_go_proxy_ensure,
# common.zsh): it reads a LiteLLM-shaped route table with ONE entry -- the
# shared model, openai dialect, mlx_lm.server's /v1 -- and translates
# Anthropic /v1/messages <-> OpenAI chat with the same chatTranslator the
# enmaas flavor runs. Port 4144, the master key and the stop command are
# unchanged from the LiteLLM era. mlx_lm.server itself still runs via uvx
# (Apple Silicon only, gated by _claude_mlx_supported above) -- only the
# proxy in front of it changed.
_claude_mlx_prepare() {
    local model
    model=$(_claude_mlx_resolve_model)

    # Staleness check (llm-proxy-restart required, CLAUDE_GO_PROXY_CHECK_OUT):
    # the proxy half only -- starting mlx_lm.server (possibly a multi-GB model
    # download) is not part of a check.
    if [[ -z "${CLAUDE_GO_PROXY_CHECK_OUT-}" ]]; then
        _claude_mlx_ensure_server "$model" || return 1
    fi

    local port="${CLAUDE_MLX_PROXY_PORT:-4144}"
    local base="http://127.0.0.1:${port}"
    local master_key="${CLAUDE_MLX_PROXY_TOKEN:-mlx-proxy-local}"
    local runtime="${XDG_STATE_HOME:-$HOME/.local/state}/claude-mlx-proxy"
    local routes="$runtime/routes.json"

    # Route table for the Go proxy. A changed model (env var or
    # claude-mlx-models) changes the table, which the Go ensure restarts on
    # at the first idle moment -- the same hot-reload contract the
    # _claude_proxy_sync kill + restart used to provide.
    mkdir -p "$runtime"
    {
        print -r -- '{"model_list": ['
        print -r -- "  {\"model_name\": \"${model}\", \"litellm_params\": {\"model\": \"openai/${model}\", \"api_base\": \"$(_claude_mlx_base)/v1\"}}"
        print -r -- "], \"general_settings\": {\"master_key\": \"${master_key}\"}}"
    } >| "$routes" || { echo "❌ Failed to write ${routes}." >&2; return 1; }

    # mlx_lm.server ignores Authorization, but the Go proxy wants a non-empty
    # upstream key. No image prune (HOSTED_ONLY_IMAGE_BUDGET_BYTES=0): a
    # local model has no gateway body cap, and LiteLLM never pruned here.
    # Warm gate: the Go proxy owns the mlx_lm.server start (warm.go) because
    # the server loads its ~17 GB of weights at startup and nothing that only
    # probes must trigger that. Knobs travel as fingerprint extras too, so a
    # change restarts the idle proxy (the same contract as every other knob).
    local warm_rss="${CLAUDE_MLX_LOADED_RSS_KB:-10485760}"
    local warm_retry="${CLAUDE_MLX_WARM_RETRY_AFTER:-30}"
    local warm_max="${CLAUDE_MLX_WARM_MAX_SECONDS:-900}"
    local warm_cmd
    warm_cmd="$(_claude_mlx_server_cmd "$model")"
    local warm_log
    warm_log="$(_claude_mlx_server_log)"
    _claude_go_proxy_retire_litellm "$port"
    HOSTED_ONLY_UPSTREAM_KEY=mlx-local HOSTED_ONLY_IMAGE_BUDGET_BYTES=0 \
        CLAUDE_MLX_SERVER_CMD="$warm_cmd" CLAUDE_MLX_SERVER_LOG="$warm_log" \
        _claude_go_proxy_ensure mlx "$port" "$routes" "$master_key" \
        "warm=$warm_rss/$warm_retry/$warm_max" || return 1

    _claude_mlx_watch_start

    typeset -g _cmx_base="$base" _cmx_master_key="$master_key" _cmx_model="$model"
}

# Starts the idle reaper (scripts/mlx-idle-watch.zsh) unless one is already
# running, so the model weights only stay in RAM while a client is actually
# connected -- see that script's header for why ESTABLISHED-on-the-proxy-port
# is the idle signal. CLAUDE_MLX_IDLE_TIMEOUT (seconds, default 120) both
# tunes the reaper and disables it at 0; CLAUDE_MLX_IDLE_KEEP_PROXY=1 keeps
# the Go proxy resident and only stops mlx_lm.server. A changed timeout
# takes effect on the next cold start, not on a live watcher.
_claude_mlx_watch_start() {
    local timeout="${CLAUDE_MLX_IDLE_TIMEOUT:-120}"
    (( timeout > 0 )) || return 0
    local state="${XDG_STATE_HOME:-$HOME/.local/state}/claude-mlx"
    local pidfile="$state/watch.pid"
    if [[ -r "$pidfile" ]] && kill -0 "$(<"$pidfile")" 2>/dev/null; then
        return 0
    fi
    mkdir -p "$state"
    _claude_proxy_start "$state/watch.log" zsh "${_CLAUDE_SCRIPTS_DIR}/mlx-idle-watch.zsh" \
        "$timeout" "${CLAUDE_MLX_PORT:-4143}" "${CLAUDE_MLX_PROXY_PORT:-4144}" \
        "${CLAUDE_MLX_IDLE_KEEP_PROXY:-0}"
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
        ANTHROPIC_DEFAULT_FABLE_MODEL="${_cmx_model}"
        # Background small/fast calls (session titles, client-side
        # classifiers) and subagents otherwise resolve against ~/.claude's
        # global model -- an id the mlx route table does not carry, so those
        # calls 404. Pin everything to the one local model, same pinning
        # claude-hosted-only does for its single-endpoint world.
        ANTHROPIC_SMALL_FAST_MODEL="${_cmx_model}"
        CLAUDE_CODE_SUBAGENT_MODEL="${_cmx_model}"
        CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1
        CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL="${_cmx_model}"
        # Claude Code doesn't recognize mlx-community ids, so without this it
        # assumes 200k -- more than this 48GB Mac can hold: the default model
        # tops out at 262144 positions (config.json max_position_embeddings)
        # and its KV cache costs ~96KB/token (2 * 48 layers * 4 kv-heads *
        # 128 dim * 2B fp16), so a 200k window would demand ~20GB of cache on
        # top of the ~17GB weights. 64k keeps the whole serving footprint
        # around 23GB; raise via CLAUDE_MLX_CONTEXT_TOKENS (128k = ~30GB
        # total, only on an otherwise-light machine; 262144 = the model's
        # hard ceiling).
        CLAUDE_CODE_MAX_CONTEXT_TOKENS="${CLAUDE_MLX_CONTEXT_TOKENS:-65536}"
        # A runaway generation on local hardware (~60 tok/s) takes minutes
        # and grows the KV cache; cap it well under the context window.
        CLAUDE_CODE_MAX_OUTPUT_TOKENS="${CLAUDE_MLX_MAX_OUTPUT_TOKENS:-16384}"
        # Local-pair hiccups should fail fast, not stall the turn through
        # Claude Code's default 10 retries with long backoffs (same rationale
        # as claude-hosted-only's client retry cap).
        CLAUDE_CODE_MAX_RETRIES="${CLAUDE_MLX_MAX_RETRIES:-3}"
        # Parallel subagents are separate conversations on the one local
        # server; each brings its own KV cache, so cap the fan-out (2 * 64k
        # window ≈ 12.6GB cache worst case).
        CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS="${CLAUDE_MLX_MAX_CONCURRENT_SUBAGENTS:-2}"
        # Unrecognized ids compact AT the context limit by default; on a 64k
        # window one large tool result (~10-25k tokens for a file read) can
        # overshoot the limit in a single step and error out before
        # compaction fires. Compact at 80% (~52k) instead, keeping ~12k of
        # overshoot headroom. CLAUDE_CODE_AUTO_COMPACT_WINDOW is useless
        # here (its 100k-1M range gets capped to the model window), and
        # idle compaction never applies (its 100k floor exceeds 64k) --
        # which also spares a cold model reload just to summarize an idle
        # session.
        CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="${CLAUDE_MLX_AUTOCOMPACT_PCT:-80}"
    )

    # --bare by default -- same rationale as claude-ollama above: a small
    # local model gets overwhelmed by full session context. Opt back in via
    # CLAUDE_MLX_FULL_CONTEXT=1.
    local -a bare_flag=(--bare)
    [[ -n "$CLAUDE_MLX_FULL_CONTEXT" && "$CLAUDE_MLX_FULL_CONTEXT" != 0 ]] && bare_flag=()
    export "${envs[@]}"
    _claude_picker_args opus="${_cmx_model}" sonnet="${_cmx_model}" haiku="${_cmx_model}"
    _claude_invoke "${reply[@]}" "${bare_flag[@]}" "$@"
}

# claude-mlx-kill: stop both local processes claude-mlx starts -- the
# mlx_lm.server (by port: a uvx python with no identity to match) AND the Go
# proxy in front of it (identity-checked via the binary's stop, which refuses
# foreign listeners). Unlike every other *-kill function in this file (one
# process each), MLX is the only backend needing two, since (unlike Ollama)
# it has no native Anthropic-compatible endpoint of its own to talk to
# directly. A leftover LiteLLM listener from before the Go retirement is
# retired by identity too (litellm on the port).
claude-mlx-kill() {
    local port="${CLAUDE_MLX_PORT:-4143}" pids
    pids=("${(f)$(_claude_listen_pids "${port}")}")
    if [[ -z "${pids[1]}" ]]; then
        echo "No process listening on port ${port} (mlx_lm.server)."
    else
        echo "Killing mlx_lm.server on port ${port} (pid: ${pids[*]})..."
        kill "${pids[@]}" 2>/dev/null
        sleep 1
        pids=("${(f)$(_claude_listen_pids "${port}")}")
        [[ -n "${pids[1]}" ]] && kill -9 "${pids[@]}" 2>/dev/null
    fi

    local proxy_port="${CLAUDE_MLX_PROXY_PORT:-4144}"
    local runtime="${XDG_STATE_HOME:-$HOME/.local/state}/claude-mlx-proxy"
    local gobin
    if gobin=$(_hosted_only_go_bin 2>/dev/null); then
        "$gobin" stop --flavor mlx --port "$proxy_port" --runtime-dir "$runtime"
    else
        echo "claude-mlx: Go binary unavailable; stopping the proxy on :${proxy_port} by litellm/port match." >&2
    fi
    _claude_go_proxy_retire_litellm "$proxy_port"
    return 0
}

# claude-mlx-restart: stop the proxy (not mlx_lm.server -- it survives, the
# model is unchanged) and bring it back via the normal prepare path. Same
# shape as claude-vertex-restart/claude-openai-restart (proxies.zsh uses
# these for the menubar's restart command and llm-proxy-restart).
claude-mlx-restart() {
    local port="${CLAUDE_MLX_PROXY_PORT:-4144}"
    local runtime="${XDG_STATE_HOME:-$HOME/.local/state}/claude-mlx-proxy"
    local gobin
    if gobin=$(_hosted_only_go_bin 2>/dev/null); then
        "$gobin" stop --flavor mlx --port "$port" --runtime-dir "$runtime" >/dev/null
    fi
    _claude_go_proxy_retire_litellm "$port"
    _llm_proxy_wait_down "$port" || return 1
    print -ru2 -- 'restart: mlx starting'
    ( _claude_mlx_prepare ) || return 1
    _llm_proxy_wait_up "$port" mlx
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
