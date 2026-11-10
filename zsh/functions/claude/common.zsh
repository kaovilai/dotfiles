# Helpers shared by every provider in providers/: env cleanup, model
# ranking, the /model picker, proxy start/hot-reload and install hints.
# Loaded first by load.zsh.
#
# We always want Monitor available for background watches and messaging.
# Keep DISABLE_NON_ESSENTIAL_MODEL_CALLS and
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC unset, not set to 0: disabling
# nonessential traffic makes Monitor unavailable. Every provider clears
# these variables via _claude_copilot_unset_env before launching Claude.
# https://code.claude.com/docs/en/tools-reference#monitor-tool

# Highest-versioned Claude model for a family from /v1/models JSON.
# Mirrors PR #2's getLatestModelForFamily: numeric major-then-minor compare,
# handles claude-opus-4.8, claude-opus-4-5-20251101, claude-3-opus-... forms.
# Outputs .claude_model_id (falls back to .id) so the 1M-context variant
# (e.g. "claude-sonnet-5[1m]") is preferred over the plain default-context id
# when the gateway advertises one for that model.
_claude_copilot_latest_model() {
    local family="$1" models_json="$2"
    jq -r --arg fam "$family" '
        [(.data // [])[]
         | select(((.id? // empty) | strings) as $i
                  | ($i | test("claude"; "i")) and ($i | test($fam; "i")))]
        | map({out: (.claude_model_id? // .id),
               v: ((try (.id | capture("(?<maj>[0-9]+)(?:[.-](?<min>[0-9]+))?")) catch null) as $m
                   | if $m == null then 0
                     else (($m.maj | tonumber) * 1000) + (($m.min // "0") | tonumber)
                     end)})
        | sort_by(.v) | last // {} | .out // empty
    ' <<< "$models_json"
}

# _claude_copilot_parse_models <models_json>: everything claude-copilot needs
# from /v1/models in ONE jq pass — the latest model per Claude family, the
# display names for those pinned tiers, and the non-embedding model list for
# the /model picker. Replaces nine separate jq spawns (4x latest-model, 4x
# per-tier display-name lookup, 1x extras) that cost ~15ms each on every
# claude-copilot launch (profiled 2026-11-07). Same per-family winner as
# _claude_copilot_latest_model. Prints tab-separated lines, pins before
# extras (the order _claude_picker_args received them before):
#   tier <family> <model-id>
#   pin  <family>=<model-id> <display name>
#   model <model-id>|<display name>
# Emitted ids/names pass through tsv_safe (tabs/newlines -> spaces): the
# fields come from the gateway's /v1/models response, and a raw control
# character in one could forge extra TSV rows that read as a tier/pin/model
# line (prompt-injection shaping the pinned tiers and the /model picker).
_claude_copilot_parse_models() {
    jq -r '
      def tsv_safe: tostring | gsub("[\t\r\n]"; " ");
      def vnum: (try (capture("(?<maj>[0-9]+)(?:[.-](?<min>[0-9]+))?")) catch null) as $m
                | if $m == null then 0
                  else (($m.maj | tonumber) * 1000) + (($m.min // "0") | tonumber) end;
      (.data // []) as $data
      | [$data[] | select(((.id? // empty) | strings) as $i | ($i | test("claude"; "i")))] as $claudes
      | def latest($fam):
          [$claudes[] | select((.id | test($fam; "i")))
           | {out: (.claude_model_id? // .id), v: (.id | vnum)}]
          | sort_by(.v) | last // {} | (.out // "");
      ({opus: latest("opus"), sonnet: latest("sonnet"),
        haiku: latest("haiku"), fable: latest("fable")}) as $t
      | ($t | to_entries[] | select(.value != "") | "tier\t\(.key)\t\(.value | tsv_safe)"),
        ($t | to_entries[] | select(.value != "")
         | (.value | split("[")[0]) as $bare
         | "pin\t\(.key)=\(.value | tsv_safe)\t\([$data[] | select(.id == $bare)][0] | (.display_name // .name // "") | tsv_safe)"),
        ($data[] | select(((.id? // empty) | strings) | test("embedding"; "i") | not)
         | "model\t\(.id | tsv_safe)|\((.display_name // .name // "") | tsv_safe)")
    ' <<< "$1"
}

# Names only (no values) — used to clean up when switching to `vertex` mode
# so gateway config doesn't leak across.
typeset -ga _claude_copilot_env_names=(
    ANTHROPIC_BASE_URL
    ANTHROPIC_AUTH_TOKEN
    ANTHROPIC_API_KEY
    ANTHROPIC_MODEL
    ENABLE_TOOL_SEARCH
    ANTHROPIC_DEFAULT_OPUS_MODEL
    ANTHROPIC_DEFAULT_SONNET_MODEL
    ANTHROPIC_DEFAULT_HAIKU_MODEL
    ANTHROPIC_DEFAULT_FABLE_MODEL
    CLAUDE_CODE_USE_VERTEX
    CLAUDE_CODE_USE_BEDROCK
    DISABLE_NON_ESSENTIAL_MODEL_CALLS
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
    CLAUDE_CODE_ATTRIBUTION_HEADER
    CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION
    CLAUDE_CODE_DISABLE_TERMINAL_TITLE
    CLAUDE_CODE_ENABLE_AWAY_SUMMARY
)

_claude_copilot_unset_env() {
    # Always allow the traffic Monitor needs; discard inherited disable flags.
    unset "${_claude_copilot_env_names[@]}"
}

# Machine-facing bridges can replace this final invocation to prepare a
# transport without launching a CLI. Interactive wrappers keep normal behavior.
# Every provider that overrides the endpoint (ANTHROPIC_BASE_URL) must keep
# auto-mode review client-side: without CLAUDE_CODE_AUTO_MODE_SERVER=0 Claude
# Code tries its server-side classifier path, which a gateway cannot serve
# (and the session is billed as before). One choke point for every wrapper,
# the T3 capture bridge and the openshell invoke; a non-zero inherited value
# is overridden on purpose.
_claude_endpoint_guard() {
    [[ -n "${ANTHROPIC_BASE_URL-}" || -n "${ANTHROPIC_VERTEX_BASE_URL-}" ]] && export CLAUDE_CODE_AUTO_MODE_SERVER=0
    return 0
}

_claude_invoke() {
    _claude_endpoint_guard
    # CLAUDE_PROVIDER_DISPATCHED tells the claude-dispatch PATH shim
    # (scripts/claude-dispatch.zsh) this invocation was already prepared by a
    # claude-<backend> wrapper, so it execs the native binary instead of
    # re-dispatching to a claude-t3-<backend> launcher. Env-prefix form: the
    # marker reaches the child tree only, never this shell (a leaked marker
    # would make a later `npx t3 triage` in the same shell bypass dispatch).
    CLAUDE_PROVIDER_DISPATCHED=1 command claude "$@"
}

typeset -g _CLAUDE_SCRIPTS_DIR="${${(%):-%x}:A:h:h:h:h}/scripts"

_claude_proxy_start() {
    local log="$1"; shift
    # scripts/ on PYTHONPATH lets configs load litellm_usage_log (llm-usage).
    (PYTHONPATH="$_CLAUDE_SCRIPTS_DIR${PYTHONPATH:+:$PYTHONPATH}" "$@" >> "$log" 2>&1 &)
}

# Builds a `--settings` arg (into $reply) so the /model picker lists only the
# models a wrapper actually pinned -- one row per distinct model, labelled with
# a display name plus the tiers it serves -- instead of Claude Code's built-in
# rows ("Custom Opus model" duplicates, an unusable Fable row).
# Args: role=model[|Display Name] ... for the pinned tiers, then
# =model[|Display Name] ... for extra models the backend offers. Newest Claude
# generation first, then current GPT variants and other alternatives, then older
# Claude/GPT choices. Versions compare numerically within those groups; all
# supplied ids and tier mappings stay intact. Empty models skipped. With no explicit
# display name the id is prettified (gpt-5-mini -> "GPT-5 Mini",
# qwen3-coder:30b -> "Qwen3 Coder 30B"); a "[1m]" suffix stays in the row's
# model id but shows as " 1M" in the label. Needs jq; without it $reply is
# empty and the default picker shows. Claude Code reads `modelPicker` from
# --settings (v2.1.242+).
_claude_picker_args() {
    reply=()
    command -v jq &>/dev/null || return 0
    local -a pairs=()
    local a
    for a in "$@"; do [[ "${${a%%|*}#*=}" == "" ]] || pairs+=("$a"); done
    (( ${#pairs} )) || return 0
    local json
    json=$(jq -nc --args '
        def pretty:
            sub("^(openai|anthropic|mlx-community)/"; "") | sub(":latest$"; "")
            | [match("[^-_: ]+"; "g").string]
            | map(if test("^gpt$"; "i") then "GPT"
                  elif test("^chatgpt$"; "i") then "ChatGPT"
                  elif test("^[0-9.]+[bB]$") then ascii_upcase
                  elif test("^[0-9]") or test("^o[0-9]") then .
                  else (.[0:1] | ascii_upcase) + .[1:] end)
            | join(" ") | gsub("(?<![0-9])(?<a>[0-9]{1,2}) (?<b>[0-9]{1,2})(?![0-9])"; "\(.a).\(.b)") | sub("^GPT "; "GPT-");
        reduce ($ARGS.positional[]
                | (index("|") as $i | if $i == null then [., ""] else [.[0:$i], .[$i+1:]] end) as $p
                | $p[0] | split("=") as $kv
                | {role: $kv[0], model: ($kv[1:] | join("=")), name: $p[1]}) as $e ([];
            ($e.role | if . == "" then [] else [.] end) as $r
            | if any(.[]; .model == $e.model)
              then map(if .model == $e.model then .roles += $r else . end)
              else . + [{model: $e.model, roles: $r, name: $e.name}] end)
        | def ver: ([match("[0-9]+([.-][0-9]{1,2}(?![0-9]))*").string] | first // "" | [scan("[0-9]+") | tonumber]);
          def identity:
            ascii_downcase | sub("\\[1m\\]$"; "")
            | if test("(^|/)claude-(opus|sonnet|haiku|fable)-[0-9]") then
                capture("(^|/)claude-(?<family>opus|sonnet|haiku|fable)-(?<v>[0-9]+([.-][0-9]{1,2}(?![0-9]))*)")
                | {kind: "claude", family, version: (.v | ver)}
              elif test("(^|/)(chat)?gpt-[0-9]") then
                capture("(^|/)(chat)?gpt-(?<v>[0-9]+([.-][0-9]{1,2}(?![0-9]))*)(?<suffix>.*)$")
                | {kind: "gpt", family: (.suffix | sub("-[0-9]{8}$"; "")), version: (.v | ver)}
              else {kind: "other", family: "", version: ver} end;
          to_entries | map(.value + {order: .key} + (.value.model | identity)) as $rows
        | ([$rows[] | select(.kind == "claude") | .version[0]] | max // 0) as $claude_major
        | ([$rows[] | select(.kind != "other")] | group_by([.kind, .family])
            | map({key: (.[0].kind + "/" + .[0].family), value: (map(.version) | max)}) | from_entries) as $latest
        | $rows | map(. + {rank:
            (if .kind == "claude" then
                if .version[0] == $claude_major and .version == $latest["claude/" + .family] then 0 else 3 end
             elif .kind == "gpt" then
                if .version == $latest["gpt/" + .family] then 1 else 4 end
             else 2 end)})
        | sort_by([.rank,
            (if .rank == 0 and (.roles | length > 0) then 0 else 1 end),
            (if .rank == 0 and (.roles | length > 0) then .order else 0 end),
            -(.version[0] // 0), -(.version[1] // 0), -(.version[2] // 0), .model])
        | {modelPicker: {replaceBuiltInOptions: true,
            options: map(
                (.model | endswith("[1m]")) as $big
                | (.model | sub("\\[1m\\]$"; "")) as $bare
                | ((if .name != "" and .name != .model and .name != $bare then .name else ($bare | pretty) end) + (if $big then " 1M" else "" end)) as $nm
                | {model, label: (if (.roles | length) > 0 then "\($nm) (\(.roles | join(", ")))" else $nm end)})}}' \
        "${pairs[@]}") || return 0
    reply=(--settings "$json")
}

# Prints "=model" args (one per line) for every id in a jq-extracted list on
# stdin, for _claude_picker_args' extras. Usage:
#   extras=(${(f)"$(print -r -- "$json" | jq -r '...ids...' | _claude_picker_extras)"})
_claude_picker_extras() {
    local id
    while IFS= read -r id; do [[ -n "$id" ]] && print -r -- "=${id}"; done
}

# --- proxy hot reload ------------------------------------------------------
# The local proxies/gateways read their config and credential files only at
# start. Each wrapper fingerprints everything that shapes the running process
# (generated config, API key or credential-file contents, versions) on every
# launch; _claude_proxy_sync restarts the process when the fingerprint differs
# from the one recorded when it was started, and _claude_proxy_record stores
# it once the new process is healthy. State: ~/.local/state/claude-<name>.fingerprint.

# sha256 hex of stdin. sha256sum (coreutils) where present, else openssl
# (C binary, faster to spawn than perl shasum), else shasum (macOS base
# system). Fedora ships no shasum unless perl-Digest-SHA is installed; without
# this fallback every fingerprint hashed to "" and matched, which silently
# disabled hot reload. Digest values are identical across all three.
_claude_sha256() {
    if (( $+commands[sha256sum] )); then
        sha256sum | cut -d' ' -f1
    elif (( $+commands[openssl] )); then
        openssl dgst -sha256 -r | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

# "<sha256> <path>" lines for every given path, in ONE process. A per-file
# hash spawn costs 15-25ms; hashing a 188-file checkout per-file cost ~2.8s
# and dominated every claude launch (profiled 2026-11-07). sha256sum (two
# spaces before the path) first, openssl ("*" separator), shasum last — the
# digest is the same, only the line format differs, which moves a fingerprint
# once per machine, not per call.
_claude_hash_paths() {
    if (( $+commands[sha256sum] )); then
        sha256sum -- "$@"
    elif (( $+commands[openssl] )); then
        openssl dgst -sha256 -r -- "$@"
    else
        shasum -a 256 -- "$@"
    fi
}

# sha256 over the args (unit-separator joined).
_claude_proxy_fp() {
    local IFS=$'\x1f'
    print -rn -- "$*" | _claude_sha256
}

# Combined hash of the given files' contents; missing files hash as "missing".
# One _claude_hash_paths process for all present files (see its comment); the
# per-file line now carries the path too, which moves each provider's
# fingerprint once, then stays stable.
_claude_file_hash() {
    local f
    local -a present=() missing=()
    for f in "$@"; do
        if [[ -r "$f" ]]; then present+=("$f"); else missing+=("$f"); fi
    done
    {
        (( ${#present} )) && _claude_hash_paths "${present[@]}"
        for f in "${missing[@]}"; do print -r -- "missing"; done
    } | _claude_sha256
}

# Port probes for the proxy kill/restart/hot-reload paths. lsof where
# installed (macOS base system), else ss (iproute, in Fedora's base install;
# lsof is not). ss -p only reports pids of processes this user owns, which
# covers every proxy these wrappers start.
# _claude_listen_pids <port>: pids listening on TCP <port>, one per line.
_claude_listen_pids() {
    if (( $+commands[lsof] )); then
        lsof -ti "tcp:$1" -sTCP:LISTEN 2>/dev/null
    elif (( $+commands[ss] )); then
        ss -Hltnp "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u
    else
        print -ru2 -- "neither lsof nor ss found; install one: $(_claude_pkg_install_hint lsof)"
        return 1
    fi
}

# _claude_port_serving <port>: true while a request is in flight on <port>.
# Preferred source: the port's inflight-<port>-<pid>.json (litellm_usage_log and
# the copilot-api monitor plugin write one per live proxy pid, removed when the
# pid dies). A keep-alive pool holds ESTABLISHED sockets between requests, so
# the socket test alone read "busy" forever and deferred restarts stalled
# (2026-11-06 audit); sockets remain the fallback for a port that reports
# nothing. Same live-pid rule as llm-usage's read_inflight.
_claude_port_serving() {
    local _cps_dir="${LLM_USAGE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/llm-usage}" _cps_f _cps_pid
    local -a _cps_files
    _cps_files=("$_cps_dir"/inflight-"$1"-*.json(N))
    if (( ${#_cps_files} )); then
        local -i _cps_reporter=0
        for _cps_f in $_cps_files; do
            _cps_pid="${${_cps_f:t}:r}"; _cps_pid="${_cps_pid##*-}"
            [[ "$_cps_pid" == <-> ]] && kill -0 "$_cps_pid" 2>/dev/null || continue
            _cps_reporter=1
            if jq -e '(.requests // {}) | length > 0' "$_cps_f" >/dev/null 2>&1; then
                return 0
            fi
        done
        # a live reporter with an empty table says idle; only dead-pid or
        # unreadable leftovers do not say anything — use the socket test
        (( _cps_reporter )) && return 1
    fi
    if (( $+commands[lsof] )); then
        lsof -nP -iTCP:"$1" -sTCP:ESTABLISHED -Fn 2>/dev/null | grep -q -- "^n.*:$1->"
    elif (( $+commands[ss] )); then
        [[ -n "$(ss -Htn state established "sport = :$1" 2>/dev/null)" ]]
    else
        return 1
    fi
}

# _claude_auto_compact_window <max-output-tokens> [<explicit-override>]
# Prints the CLAUDE_CODE_AUTO_COMPACT_WINDOW to set for a hosted (vLLM) session,
# or nothing when it should stay unset.
#
# WHY: Claude Code (2.1.319, read from the bundle) compacts at
#   threshold = min(model window, AUTO_COMPACT_WINDOW) - min(model max output, 20000) - 13000
# i.e. a fixed 33000 below the window, and it does NOT reserve the output cap we
# raise (CLAUDE_CODE_MAX_OUTPUT_TOKENS, default 128000). The proxy serves
# 1,048,576 and vLLM rejects input + max_tokens above it, so at the client's own
# threshold (~967k for a 1M window) a 128000 request overflows and the proxy
# has to trim max_tokens (the Go proxy's clamp) or, when drift eats
# the room, answer a compaction-hint 400. Setting the window so the threshold
# leaves room for the FULL output budget plus a token-count drift margin makes
# the client compact proactively instead:
#   window = MAX_MODEL_LEN - OUTPUT_RESERVE - max_output - DRIFT_MARGIN + 33000
# (128000 output, 45000 drift -> 908000; threshold 875000.) The clamp and hint
# stay as the backstop for what the margin does not cover.
#
# COUPLED (read the Go proxy's MIN_OUTPUT comment before changing any):
# MAX_MODEL_LEN / OUTPUT_RESERVE (hook knobs, same defaults), the output cap
# the caller passes, HOSTED_ONLY_COMPACT_DRIFT_MARGIN, and the 33000 client
# constant, which is Claude Code version specific - recheck after a client
# upgrade (tengu: resolveAutoCompactWindow / L4 / AZr in the bundle).
# <explicit-override>: a number sets the window verbatim; off/none/0 prints
# nothing. The client clamps it to the model window, so a gateway model with a
# smaller window than this value is unaffected.
_claude_auto_compact_window() {
    local out="$1" explicit="${2-}" len res margin window
    case "$explicit" in
        off|none|0) return 0 ;;
        <->) print -r -- "$explicit"; return 0 ;;
    esac
    [[ "$out" == <-> ]] || return 0
    len="${HOSTED_ONLY_MAX_MODEL_LEN:-1048576}"; [[ "$len" == <-> ]] || len=1048576
    res="${HOSTED_ONLY_OUTPUT_RESERVE:-512}"; [[ "$res" == <-> ]] || res=512
    margin="${HOSTED_ONLY_COMPACT_DRIFT_MARGIN:-45000}"; [[ "$margin" == <-> ]] || margin=45000
    window=$(( len - res - out - margin + 33000 ))
    window=$(( window / 1000 * 1000 ))
    (( window > 1000000 )) && window=1000000   # the [1m] model window; the client clamps anyway
    (( window < 200000 )) && window=200000     # never compact absurdly early on a mistyped knob
    print -r -- "$window"
}

# _claude_proxy_sync <label> <name> <health-url> <fingerprint> <kill-fn> <adopt> [assume-up]
# Running + fingerprint differs -> when idle, kill via <kill-fn> and wait for
# the port to free so the caller's normal start path relaunches it; while it is
# serving a request, reuse it (the change applies on a later idle launch). Running with no
# recorded fingerprint: adopt=1 records the current one and leaves the process
# alone; adopt=0 treats it as stale and restarts.
# assume-up=1 skips the initial health probe, for a caller that just confirmed
# the same URL itself (claude-copilot fetches /v1/models before syncing, so
# the probe would re-ask what it already knows). The fingerprint comparison
# still runs.
# Sets the global _CLAUDE_PROXY_SYNC_KILLED=1 when it killed the process, so
# a caller holding state fetched from the old process (e.g. a model list)
# knows to drop it and refetch after its start path relaunches.
# Dry run: with _CLAUDE_PROXY_SYNC_CHECK=<file> (set by `llm-proxy-restart
# required`) the verdict `down`, `fresh` or `stale` is written to that file and
# the function returns 1 so the launcher stops there; nothing is killed,
# recorded or started.
_claude_proxy_sync() {
    local label="$1" name="$2" health="$3" fp="$4" killfn="$5" adopt="$6" assume_up="${7:-0}"
    typeset -g _CLAUDE_PROXY_SYNC_KILLED=0
    local state="${XDG_STATE_HOME:-$HOME/.local/state}/claude-${name}.fingerprint"
    local check="${_CLAUDE_PROXY_SYNC_CHECK-}"
    if (( ! assume_up )) && ! curl -sf --max-time 2 "$health" -o /dev/null; then
        [[ -n "$check" ]] && { print -r -- down >| "$check"; return 1; }
        return 0
    fi
    local recorded
    recorded=$(cat "$state" 2>/dev/null)
    if [[ -n "$check" ]]; then
        if [[ "$recorded" == "$fp" || ( -z "$recorded" && "$adopt" == 1 ) ]]; then
            print -r -- fresh >| "$check"
        else
            print -r -- stale >| "$check"
        fi
        return 1
    fi
    [[ "$recorded" == "$fp" ]] && return 0
    if [[ -z "$recorded" && "$adopt" == 1 ]]; then
        mkdir -p "${state:h}" && print -r -- "$fp" >| "$state"
        return 0
    fi
    # Serving a request right now (ESTABLISHED socket on the proxy's port):
    # keep the running process rather than cut that request off. The change
    # applies on the first launch that finds the proxy idle. This is what
    # CLAUDE_PROVIDER_NO_RESTART (set by the T3 bridge) used to guard by
    # refusing every changed launch.
    local port="${${health#*://*:}%%/*}"
    if [[ "$port" == <-> ]] && _claude_port_serving "$port"; then
        echo "${label}: config or credentials changed, but the proxy is serving requests; reusing it until it is idle." >&2
        return 0
    fi
    echo "${label}: config or credentials changed -- restarting the idle proxy..." >&2
    _CLAUDE_PROXY_SYNC_KILLED=1
    "$killfn" >/dev/null 2>&1
    local j
    for j in {1..20}; do
        curl -sf --max-time 1 "$health" -o /dev/null || break
        sleep 0.5
    done
}

_claude_proxy_record() {
    local state="${XDG_STATE_HOME:-$HOME/.local/state}/claude-${1}.fingerprint"
    mkdir -p "${state:h}" && print -r -- "$2" >| "$state"
}

# --- Go proxy launch path (route-table flavors) -----------------------------
# _claude_go_proxy_ensure <flavor> <port> <routes.json> <master-key> [fp-extra...]
# Shared launcher path for the Go binary's route-table flavors (mlx, openai,
# vertex -- scripts/hosted-only-go, docs/notes/hosted-only-go-proxy.md): the
# caller has already written the LiteLLM-shaped route table; this folds it
# (plus the Go source hash, the upstream key and any caller extras like an
# ADC file hash) into the fingerprint the binary's `ensure` compares, then
# delegates process management (startup.lock, stale/busy decision,
# zero-refuse restart, health wait, fingerprint record) to the binary.
# The runtime dir is the route table's directory: the serve child names it
# (--runtime-dir/--config) on its command line, which is what the
# identity-checked `stop` matches.
#
# HOSTED_ONLY_UPSTREAM_KEY, set in the environment by the caller (zsh
# `VAR=x func` prefix form), reaches the serve child as the upstream bearer
# (mlx/openai) and is part of the fingerprint. Anything else the serve child
# must see (vertex: CLOUD_ML_REGION, ANTHROPIC_VERTEX_PROJECT_ID,
# GOOGLE_APPLICATION_CREDENTIALS) the caller exports around this call.
_claude_go_proxy_ensure() {
    local flavor="$1" port="$2" routes="$3" master_key="$4"; shift 4
    local gobin go_hash fp token_fp key="${HOSTED_ONLY_UPSTREAM_KEY-}"
    gobin=$(_hosted_only_go_bin) || return 1
    [[ -s "$routes" ]] || { print -ru2 -- "claude-${flavor}: route table ${routes} is missing."; return 1; }
    go_hash=$(_hosted_only_go_hash) || return 1
    fp=$( { cat -- "$routes"; print -rn -- $'\x1f'"claude-${flavor}"$'\x1f'"$go_hash"$'\x1f'"$key"$'\x1f'"$*" } \
        | _claude_sha256) || return 1
    token_fp=$(print -rn -- "$master_key" | _claude_sha256) || return 1
    mkdir -p -- "${routes:h}" || return 1

    # Dry run for `llm-proxy-restart required` (the Go path's equivalent of
    # _hosted_only_proxy_ensure's HOSTED_ONLY_CHECK_OUT): with
    # CLAUDE_GO_PROXY_CHECK_OUT=<file> the verdict `down`, `fresh` or `stale`
    # is written there and the function returns 1 so the launcher stops;
    # nothing is started, stopped or recorded.
    if [[ -n "${CLAUDE_GO_PROXY_CHECK_OUT-}" ]]; then
        local chk_fp= chk_token= verdict=down
        if curl -sf --max-time 2 "http://127.0.0.1:${port}/health/liveliness" -o /dev/null; then
            read -r chk_fp chk_token < "${routes:h}/fingerprint" 2>/dev/null
            if [[ "$chk_fp" == "$fp" && ( -z "$chk_token" || "$chk_token" == "$token_fp" ) ]]; then
                verdict=fresh
            else
                verdict=stale
            fi
        fi
        print -r -- "$verdict $fp $token_fp" >| "$CLAUDE_GO_PROXY_CHECK_OUT"
        return 1
    fi

    local -a envp=()
    [[ -n "$key" ]] && envp=("HOSTED_ONLY_UPSTREAM_KEY=$key")
    env "${envp[@]}" "$gobin" ensure \
        --flavor "$flavor" --port "$port" --runtime-dir "${routes:h}" \
        --config "$routes" --fingerprint "$fp" --token-fp "$token_fp"
}

# _claude_go_proxy_retire_litellm <port>: a LiteLLM listener from before the
# Go retirement answers the same /health path, so the Go `ensure` would refuse
# the port as "held by another process". Retire it by identity -- command
# line names litellm AND this port -- at migration; anything else on the port
# is left alone for `ensure`/`stop` to refuse loudly.
_claude_go_proxy_retire_litellm() {
    local port="$1" pid cmd j
    for pid in ${(f)"$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null)"}; do
        cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
        [[ "$cmd" == *litellm* ]] || continue
        print -ru2 -- "claude-go-proxy: retiring the pre-retirement litellm listener on :${port} (pid ${pid})."
        kill "$pid" 2>/dev/null
        for j in {1..20}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    done
    return 0
}

# Install-hint helper for the ❌-not-found messages below -- brew is
# Darwin-only, so a hardcoded "brew install X" is wrong on Linux (e.g.
# Fedora). Falls back to whatever package manager is actually on PATH;
# $2 overrides the hint entirely for a tool with no reliable distro
# package (e.g. ollama, installed via curl script on Linux regardless of
# distro).
_claude_pkg_install_hint() {
    local pkg="$1" linux_override="$2"
    if [[ "$(uname)" == "Darwin" ]]; then
        print -r -- "brew install ${pkg}"
        return 0
    fi
    if [[ -n "$linux_override" ]]; then
        print -r -- "$linux_override"
        return 0
    fi
    if command -v dnf &>/dev/null; then
        print -r -- "sudo dnf install ${pkg}"
    elif command -v apt-get &>/dev/null; then
        print -r -- "sudo apt install ${pkg}"
    elif command -v pacman &>/dev/null; then
        print -r -- "sudo pacman -S ${pkg}"
    elif command -v brew &>/dev/null; then
        print -r -- "brew install ${pkg}"
    else
        print -r -- "install ${pkg} via your package manager"
    fi
}

