# ---------------------------------------------------------------------------
# claude-enmass: raw claude binary routed through the EnMaaS gateway via one
# shared loopback LiteLLM proxy (default :4146, CLAUDE_ENMASS_PROXY_PORT).
# Requires ENMASS_API_BASE_URL (gateway root, or its /v1) and ENMASS_API_KEY
# exported in the shell. Caller env, saved claude-mode and persistent Claude
# settings stay intact; a caller's final --settings object/file is merged
# under the wrapper's transport/picker fields.
#
# Models: Anthropic (x-api-key) and gateway Bearer catalogs, plus the OpenAI
# upstream catalog reached through the same gateway/key (see
# _claude_enmass_discover), newest Claude per tier, Sonnet default. Overrides:
#   CLAUDE_ENMASS_MODEL                         default model
#   CLAUDE_ENMASS_{OPUS,SONNET,HAIKU,FABLE}_MODEL  per-tier
#   CLAUDE_ENMASS_MODEL_DIALECTS='id=responses other=chat'  exact ids needing
#     a dialect (anthropic -> /v1/messages, chat -> /v1/chat/completions,
#     responses -> /v1/responses); confirm gateway support first.
# A catalog entry is a selectable candidate, not proof of entitlement.
#
# Lifecycle: first launch starts the proxy, later launches reuse it; session
# exit leaves it running. Private runtime dir
# /tmp/claude-enmass-proxy-<uid>-<port> (0700/0600); config references
# os.environ/ENMASS_API_KEY and Claude children only get the local token.
# Gateway/key/dependency/route changes fail with a restart instruction
# instead of disrupting active sessions. claude-enmass-kill stops only the
# recorded, birth-time-verified proxy process group (disconnects every
# session using it).
source "${${(%):-%N}:A:h}/enmass-proxy.zsh"

_claude_enmass_root() {
    python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit
try:
    value = sys.argv[1]
    if any(ord(c) <= 32 or ord(c) == 127 for c in value) or any(c in value for c in ('\\', '?', '#')):
        raise ValueError()
    u = urlsplit(value)
    host = u.hostname
    port = u.port
    if not host or u.username is not None or u.password is not None or u.query or u.fragment:
        raise ValueError()
    if u.scheme not in ('https', 'http'):
        raise ValueError()
    # Cleartext is only appropriate for a deliberately local test gateway.
    if u.scheme == 'http' and host.lower() not in ('localhost', '127.0.0.1', '::1'):
        raise ValueError()
    if any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:' for c in host):
        raise ValueError()
    if port is not None and not 1 <= port <= 65535:
        raise ValueError()
    path = u.path.rstrip('/')
    if path not in ('', '/v1', '/v1/models', '/v1/messages', '/v1/chat/completions', '/v1/responses'):
        raise ValueError()
    print(f'{u.scheme}://{u.netloc}')
except (ValueError, UnicodeError):
    print('claude-enmass: invalid ENMASS_API_BASE_URL; use an HTTPS gateway root or /v1 endpoint (HTTP only on loopback), without credentials, query, or fragment.', file=sys.stderr)
    sys.exit(1)
PY
}

_claude_enmass_port() {
    python3 - "${CLAUDE_ENMASS_PROXY_PORT-}" <<'PY'
import socket, sys
explicit = sys.argv[1]
try:
    if explicit and (not explicit.isascii() or not explicit.isdecimal() or not 1 <= int(explicit) <= 65535):
        raise ValueError()
    # The shared service owns one fixed loopback port. Its authenticated
    # startup controller, not this validator, checks listener ownership.
    print(int(explicit) if explicit else 4146)
except ValueError:
    print('claude-enmass: CLAUDE_ENMASS_PROXY_PORT must be an integer from 1 to 65535.', file=sys.stderr)
    sys.exit(1)
PY
}

# Secrets go through curl's stdin config, not its argv or a saved config file.
# Do not follow redirects: discovery must not disclose the gateway key elsewhere.
_claude_enmass_discover() {
    local dialect="$1" root="$2" key="$3" endpoint='/v1/models'
    # The beta gateway's /v1/models inventory omits OpenAI. Its Responses
    # passthrough reaches the same key's upstream catalog with this raw path;
    # curl must not normalize it back to the incomplete gateway inventory.
    [[ "$dialect" == responses ]] && endpoint='/v1/responses/../models'
    if [[ "$dialect" == anthropic ]]; then
        print -r -- "header = $(print -rn -- "x-api-key: $key" | jq -Rs .)"
        print -r -- 'header = "anthropic-version: 2023-06-01"'
    else
        print -r -- "header = $(print -rn -- "Authorization: Bearer $key" | jq -Rs .)"
    fi | command curl --silent --fail --connect-timeout 10 --max-time "${CLAUDE_ENMASS_DISCOVERY_TIMEOUT:-15}" \
        --retry "${CLAUDE_ENMASS_DISCOVERY_RETRIES:-2}" --retry-delay 1 --retry-max-time 40 --path-as-is \
        --proto '=http,https' --config - "${root}${endpoint}" 2>/dev/null
}

_claude_enmass_models() {
    local anthropic_json="$1" bearer_json="$2" responses_json="${3-}"
    [[ -n "$responses_json" ]] || responses_json='{"data":[]}'
    jq -nc --argjson a "$anthropic_json" --argjson b "$bearer_json" --argjson r "$responses_json" '
        def rows: (.data // [])[] | select(.id? | type == "string")
          | select(.id | test("^[A-Za-z0-9][A-Za-z0-9._:/@+\\[\\]-]*$"));
        ([($a | rows | . + {_enmass_anthropic: true}),
          ($b | rows | . + {_enmass_anthropic: false}),
          ($r | rows | select(.id | test("^(gpt-|chatgpt-|o[0-9])"))
            | select(.id | test("audio|realtime|transcribe|tts|image|embedding|moderation|search|instruct|diarize"; "i") | not)
            | select(.id | test("-[0-9]{4}(-[0-9]{2}-[0-9]{2})?$|-[0-9]{8}$") | not)
            | . + {_enmass_anthropic: false, api_dialect: "responses"})]
         | group_by(.id)
         | map(.[0] + {
             _enmass_anthropic: any(.[]; ._enmass_anthropic),
             display_name: ([.[] | .display_name? | strings | select(length > 0)] | first // .[0].id),
             _enmass_metadata_dialect: ([.[] | (.api_dialect // .dialect) | strings
               | select(. == "anthropic" or . == "chat" or . == "responses")] | first // null)
           })) as $models
        | {data: $models}'
}

# Build JSON (also valid YAML) so model ids/labels/URLs cannot inject config.
# Anthropic-compatible IDs are deliberately determined by discovery membership,
# explicit dialect metadata/overrides, or Claude-family naming; never owned_by.
_claude_enmass_config() {
    local root="$1" token="$2" models="$3"; shift 3
    jq -nc --arg root "$root" --arg token "$token" \
        --argjson models "$models" --args '
        def claude: test("(^|/)claude([/_.-]|$)"; "i");
        def provider($d; $id):
          if $d == "anthropic" then "anthropic/" + $id
          elif $d == "responses" then "openai/responses/" + $id
          else "openai/" + $id end;
        def entry($id; $d): {model_name: $id, litellm_params: {
          model: provider($d; $id), api_key: "os.environ/ENMASS_API_KEY",
          api_base: ($root + (if $d == "anthropic" then "" else "/v1" end))}};
        ($models.data | map({key: .id, value: .}) | from_entries) as $known
        | ($ARGS.positional | unique | map(. as $id
            | ($known[$id] // {}) as $m
            | ($m._enmass_dialect // $m._enmass_metadata_dialect //
                (if $m._enmass_anthropic or ($id | claude) or $id == "rits/zai-org/glm-5-3"
                 then "anthropic" else "chat" end)) as $d
            | entry($id; $d))) as $entries
        | {model_list: ([entry("*"; "chat")] + $entries),
           general_settings: {master_key: $token},
           # Otherwise LiteLLM sends all openai/* Messages requests to Responses,
           # bypassing the per-model responses/ bridge and leaking its prefix.
           litellm_settings: {drop_params: true,
             use_chat_completions_url_for_anthropic_messages: true}}' "$@"
}

# Session cleanup only stops its Claude child; the shared proxy persists.
_claude_enmass_cleanup() {
    if [[ "${_claude_enmass_claude_pid-}" == <-> ]]; then
        kill -TERM "$_claude_enmass_claude_pid" 2>/dev/null
        wait "$_claude_enmass_claude_pid" 2>/dev/null
    fi
    [[ -n "${_claude_enmass_tmp-}" ]] && command rm -rf -- "$_claude_enmass_tmp"
    return 0
}

claude-enmass() (
    emulate -L zsh
    setopt localtraps
    # Keep invocation-owned children in the foreground terminal process group;
    # an interactive parent's job control must not stop Claude with SIGTTIN.
    unsetopt monitor
    umask 077
    local dep
    for dep in python3 jq curl uv claude lsof; do
        command -v "$dep" &>/dev/null || {
            print -ru2 -- "claude-enmass: missing dependency: ${dep}."
            return 1
        }
    done
    for dep in _claude_copilot_latest_model _claude_picker_args _claude_copilot_unset_env; do
        (( $+functions[$dep] )) || {
            print -ru2 -- 'claude-enmass: source zsh/functions/claude/load.zsh, not this provider file alone.'
            return 1
        }
    done
    [[ -n "${ENMASS_API_BASE_URL-}" && -n "${ENMASS_API_KEY-}" ]] || {
        print -ru2 -- 'claude-enmass: set ENMASS_API_BASE_URL and ENMASS_API_KEY in your environment.'
        return 1
    }
    # Reject control characters before handing the key to curl config parsing.
    [[ "$ENMASS_API_KEY" != *[[:cntrl:]]* ]] || {
        print -ru2 -- 'claude-enmass: ENMASS_API_KEY contains an invalid control character.'
        return 1
    }
    local root port
    root=$(_claude_enmass_root "$ENMASS_API_BASE_URL") || return 1
    port=$(_claude_enmass_port) || return 1

    local _claude_enmass_tmp="" _claude_enmass_claude_pid=""
    _claude_enmass_tmp=$(command mktemp -d "${TMPDIR:-/tmp}/claude-enmass.XXXXXXXX") || return 1
    trap '_claude_enmass_cleanup' EXIT
    command chmod 700 "$_claude_enmass_tmp" || return 1
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    # Claude uses only the last --settings argument. Fold that caller layer
    # into our single generated layer instead of letting it replace isolation.
    local caller_settings='{}' settings_source='' settings_seen=0
    local -a forwarded
    while (( $# )); do
        case "$1" in
            --settings)
                (( $# >= 2 )) || {
                    print -ru2 -- 'claude-enmass: --settings requires a file or JSON object.'
                    return 1
                }
                settings_source="$2"; settings_seen=1; shift 2 ;;
            --settings=*) settings_source="${1#--settings=}"; settings_seen=1; shift ;;
            --) forwarded+=("$@"); break ;;
            *) forwarded+=("$1"); shift ;;
        esac
    done
    set -- "${forwarded[@]}"
    if (( settings_seen )); then
        if [[ -f "$settings_source" ]]; then
            caller_settings=$(jq -ce 'select(type == "object")' "$settings_source" 2>/dev/null)
        else
            caller_settings=$(jq -ce 'select(type == "object")' <<< "$settings_source" 2>/dev/null)
        fi
        [[ -n "$caller_settings" ]] || {
            print -ru2 -- 'claude-enmass: --settings must contain a valid JSON object or name a readable JSON file.'
            return 1
        }
    fi

    local a='{"data":[]}' b='{"data":[]}' r='{"data":[]}' payload models
    payload=$(_claude_enmass_discover anthropic "$root" "$ENMASS_API_KEY")
    if jq -e '(.data | type == "array")' <<< "$payload" &>/dev/null; then a="$payload"; fi
    payload=$(_claude_enmass_discover chat "$root" "$ENMASS_API_KEY")
    if jq -e '(.data | type == "array")' <<< "$payload" &>/dev/null; then b="$payload"; fi
    payload=$(_claude_enmass_discover responses "$root" "$ENMASS_API_KEY")
    if jq -e '(.data | type == "array")' <<< "$payload" &>/dev/null; then
        r="$payload"
    else
        print -ru2 -- 'claude-enmass: OpenAI catalog discovery unavailable; GPT models may be omitted. Exact supported IDs can still be pinned with CLAUDE_ENMASS_MODEL_DIALECTS.'
    fi
    models=$(_claude_enmass_models "$a" "$b" "$r") || return 1
    local selected="${CLAUDE_ENMASS_MODEL-}" cli_model="" arg previous="" mapping id dialect
    local cli_seen=0
    for arg in "$@"; do
        if [[ "$previous" == --model ]]; then cli_model="$arg"; cli_seen=1; fi
        if [[ "$arg" == --model=* ]]; then cli_model="${arg#--model=}"; cli_seen=1; fi
        previous="$arg"
    done
    if [[ "$previous" == --model || ( "$cli_seen" == 1 && "$cli_model" == "" ) ]]; then
        print -ru2 -- 'claude-enmass: --model requires a model id.'
        return 1
    fi
    local opus sonnet haiku fable fallback
    sonnet="${CLAUDE_ENMASS_SONNET_MODEL:-$(_claude_copilot_latest_model sonnet "$models")}"
    opus="${CLAUDE_ENMASS_OPUS_MODEL:-$(_claude_copilot_latest_model opus "$models")}"
    haiku="${CLAUDE_ENMASS_HAIKU_MODEL:-$(_claude_copilot_latest_model haiku "$models")}"
    fable="${CLAUDE_ENMASS_FABLE_MODEL:-$(_claude_copilot_latest_model fable "$models")}"
    fallback="${selected:-${sonnet:-${opus:-${haiku:-${fable:-$(jq -r '.data[0].id // empty' <<< "$models")}}}}}"
    # Catalogs are advisory: an exact CLI model works even if discovery is empty.
    case "$cli_model" in
        opus|sonnet|haiku|fable|'') ;;
        *) fallback="${fallback:-$cli_model}" ;;
    esac
    if [[ -z "$fallback" ]]; then
        print -ru2 -- 'claude-enmass: no usable models discovered; set CLAUDE_ENMASS_MODEL or --model to a confirmed gateway model id.'
        return 1
    fi
    if ! jq -e '.data | length > 0' <<< "$models" &>/dev/null; then
        print -ru2 -- 'claude-enmass: model discovery is unavailable or empty; using explicit model configuration.'
    fi
    selected="${selected:-$fallback}"
    opus="${opus:-$fallback}" sonnet="${sonnet:-$fallback}"
    haiku="${haiku:-$fallback}" fable="${fable:-$fallback}"
    # CLI tier aliases still select their mapped tier without rewriting argv.
    case "$cli_model" in
        opus) selected="$opus" ;; sonnet) selected="$sonnet" ;;
        haiku) selected="$haiku" ;; fable) selected="$fable" ;;
        '') ;; *) selected="$cli_model" ;;
    esac

    # The PDF recipe's optional GLM id has an explicit Anthropic mapping.
    # Documented text-only context: 262144; output: 65536. These are model
    # metadata, not verified gateway transport limits or global Claude settings.
    local glm='rits/zai-org/glm-5-3'
    local -a ids pairs reply
    ids=("${(@f)$(jq -r '.data[].id' <<< "$models")}" "$selected" "$opus" "$sonnet" "$haiku" "$fable" "$glm")
    ids=("${(@)ids:#}")
    for mapping in ${=CLAUDE_ENMASS_MODEL_DIALECTS}; do
        id="${mapping%=*}" dialect="${mapping##*=}"
        if [[ "$mapping" != *=* || "$id" == "" || "$dialect" != (anthropic|chat|responses) ]]; then
            print -ru2 -- 'claude-enmass: CLAUDE_ENMASS_MODEL_DIALECTS must contain space-separated id=anthropic, id=chat, or id=responses mappings.'
            return 1
        fi
        ids+=("$id")
        models=$(jq -c --arg id "$id" --arg dialect "$dialect" '
            if any(.data[]; .id == $id) then .data |= map(if .id == $id then ._enmass_dialect = $dialect else . end)
            else .data += [{id: $id, _enmass_dialect: $dialect}] end' <<< "$models") || return 1
    done
    ids=("${(@u)ids}")
    for id in "${ids[@]}"; do
        if ! jq -en --arg id "$id" '$id | test("^[A-Za-z0-9][A-Za-z0-9._:/@+\\[\\]-]*$")' &>/dev/null; then
            print -ru2 -- 'claude-enmass: an override or CLI model id contains unsupported characters.'
            return 1
        fi
    done
    local label role
    pairs=()
    for role in fable opus sonnet haiku; do
        id="${(P)role}"
        label=$(jq -r --arg id "$id" '[.data[] | select(.id == $id) | .display_name // .id] | first // empty' <<< "$models")
        [[ "$id" == "$glm" ]] && label='GLM 5.3 (text-only recipe)'
        label="${label//|/ }"
        pairs+=("${role}=${id}|${label}")
    done
    for id in "${ids[@]}"; do
        label=$(jq -r --arg id "$id" '[.data[] | select(.id == $id) | .display_name // .id] | first // empty' <<< "$models")
        [[ "$id" == "$glm" ]] && label='GLM 5.3 (text-only recipe)'
        # The shared picker uses a pipe separator; never allow a label to inject it.
        label="${label//|/ }"
        pairs+=("=${id}|${label}")
    done
    _claude_picker_args "${pairs[@]}"
    local settings='{}'
    (( ${#reply} )) && settings="$reply[2]"
    settings=$(jq -c --arg glm "$glm" '. + {
        apiKeyHelper: "",
        env: {ANTHROPIC_CUSTOM_HEADERS: "", CLAUDE_CODE_USE_VERTEX: "0", CLAUDE_CODE_USE_BEDROCK: "0", CLAUDE_CODE_USE_FOUNDRY: "0"},
        modelSettings: {($glm): {effortLevel: "medium"}}
      }' <<< "$settings") || return 1

    local token base="http://127.0.0.1:${port}" config service
    local litellm_version="${CLAUDE_OPENAI_PROXY_LITELLM_VERSION:-1.97.0}"
    local fastapi_version="${CLAUDE_OPENAI_PROXY_FASTAPI_VERSION:-0.136.3}"
    local timeout="${CLAUDE_ENMASS_PROXY_START_TIMEOUT:-60}"
    [[ "$timeout" == <-> && "$timeout" -gt 0 && "$timeout" -le 600 ]] || {
        print -ru2 -- 'claude-enmass: CLAUDE_ENMASS_PROXY_START_TIMEOUT must be 1 through 600 seconds.'
        return 1
    }
    config=$(_claude_enmass_config "$root" '' "$models" "${ids[@]}") || return 1
    _claude_enmass_proxy_program > "${_claude_enmass_tmp}/proxy.py" || return 1
    export ENMASS_API_KEY
    service=$(print -rn -- "$config" | python3 "${_claude_enmass_tmp}/proxy.py" ensure \
        "$port" "$litellm_version" "$fastapi_version" "$timeout" "$selected" "$opus" "$sonnet" "$haiku" "$fable" "$glm" \
        ${${=CLAUDE_ENMASS_MODEL_DIALECTS}%=*}) || return 1
    token=$(jq -er '.token' <<< "$service") || return 1
    # A running proxy's frozen routes win over newly discovered dialects.
    settings=$(jq -c --argjson supported "$(jq -c '.models' <<< "$service")" '
        .modelPicker.options |= map(select(.model as $m | $supported | index($m)))' <<< "$settings") || return 1
    # Saved settings can also contain env overrides. Pin the child transport in
    # the inline settings layer as well as process env; never save either layer.
    settings=$(jq -c --arg base "$base" --arg token "$token" --arg selected "$selected" \
        --arg opus "$opus" --arg sonnet "$sonnet" --arg haiku "$haiku" --arg fable "$fable" '
        .env += {ANTHROPIC_BASE_URL: $base, ANTHROPIC_API_KEY: "", ANTHROPIC_AUTH_TOKEN: $token,
          ANTHROPIC_MODEL: $selected, ANTHROPIC_DEFAULT_OPUS_MODEL: $opus,
          ANTHROPIC_DEFAULT_SONNET_MODEL: $sonnet, ANTHROPIC_DEFAULT_HAIKU_MODEL: $haiku,
          ANTHROPIC_DEFAULT_FABLE_MODEL: $fable, CLAUDE_CODE_API_KEY_HELPER: ""}' <<< "$settings") || return 1
    settings=$(jq -nc --argjson caller "$caller_settings" --argjson wrapper "$settings" \
        '$caller * $wrapper') || return 1
    # Clean only this subshell. Unrelated parent/wrapper state remains intact.
    _claude_copilot_unset_env
    unset ENMASS_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_FOUNDRY_API_KEY \
        ANTHROPIC_FOUNDRY_RESOURCE ANTHROPIC_FOUNDRY_BASE_URL CLAUDE_CODE_API_KEY_HELPER
    export ANTHROPIC_BASE_URL="$base" ANTHROPIC_API_KEY='' ANTHROPIC_AUTH_TOKEN="$token" \
        ANTHROPIC_MODEL="$selected" ANTHROPIC_DEFAULT_OPUS_MODEL="$opus" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="$sonnet" ANTHROPIC_DEFAULT_HAIKU_MODEL="$haiku" \
        ANTHROPIC_DEFAULT_FABLE_MODEL="$fable" CLAUDE_CODE_USE_VERTEX=0 \
        CLAUDE_CODE_USE_BEDROCK=0 CLAUDE_CODE_USE_FOUNDRY=0 ANTHROPIC_CUSTOM_HEADERS=''
    # Preserve the terminal input while waiting on an owned child so TERM/HUP
    # traps run immediately even when Claude is still running interactively.
    _claude_invoke --settings "$settings" "$@" <&0 &
    _claude_enmass_claude_pid=$!
    local result=0
    wait "$_claude_enmass_claude_pid" || result=$?
    _claude_enmass_claude_pid=''
    return "$result"
)

# Live shells may still carry the pre-rename claude-enmass-kill alias, which
# would expand in the definition below and redefine kill-enmass-api instead.
unalias claude-enmass-kill 2>/dev/null || true
claude-enmass-kill() (
    emulate -L zsh
    umask 077
    local port tmp result=0
    port=$(_claude_enmass_port) || return 1
    tmp=$(command mktemp -d "${TMPDIR:-/tmp}/enmass-kill.XXXXXXXX") || return 1
    trap 'command rm -rf -- "$tmp"' EXIT
    _claude_enmass_proxy_program > "$tmp/proxy.py" || return 1
    python3 "$tmp/proxy.py" stop "$port" || result=$?
    return "$result"
)

# Pre-rename name -- claude-enmass-kill is the current name.
alias kill-enmass-api='claude-enmass-kill'
