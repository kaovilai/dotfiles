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
_claude_invoke() {
    command claude "$@"
}

_claude_proxy_start() {
    local log="$1"; shift
    ("$@" >> "$log" 2>&1 &)
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

# sha256 over the args (unit-separator joined).
_claude_proxy_fp() {
    local IFS=$'\x1f'
    print -rn -- "$*" | shasum -a 256 | cut -d' ' -f1
}

# Combined hash of the given files' contents; missing files hash as "missing".
_claude_file_hash() {
    local f
    for f in "$@"; do
        if [[ -r "$f" ]]; then shasum -a 256 < "$f" | cut -d' ' -f1; else print -r -- "missing"; fi
    done | shasum -a 256 | cut -d' ' -f1
}

# _claude_proxy_sync <label> <name> <health-url> <fingerprint> <kill-fn> <adopt>
# Running + fingerprint differs -> kill via <kill-fn> and wait for the port to
# free so the caller's normal start path relaunches it. Running with no
# recorded fingerprint: adopt=1 records the current one and leaves the process
# alone; adopt=0 treats it as stale and restarts.
_claude_proxy_sync() {
    local label="$1" name="$2" health="$3" fp="$4" killfn="$5" adopt="$6"
    local state="${XDG_STATE_HOME:-$HOME/.local/state}/claude-${name}.fingerprint"
    curl -sf --max-time 2 "$health" -o /dev/null || return 0
    local recorded
    recorded=$(cat "$state" 2>/dev/null)
    [[ "$recorded" == "$fp" ]] && return 0
    if [[ -z "$recorded" && "$adopt" == 1 ]]; then
        mkdir -p "${state:h}" && print -r -- "$fp" >| "$state"
        return 0
    fi
    if [[ "${CLAUDE_PROVIDER_NO_RESTART-}" == 1 ]]; then
        echo "${label}: running proxy configuration differs; restart it explicitly after active sessions finish." >&2
        return 1
    fi
    echo "${label}: config or credentials changed -- restarting..." >&2
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

