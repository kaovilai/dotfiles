# ---------------------------------------------------------------------------
# openshell-copilot / openshell-vertex / openshell-enmaas / openshell-openai:
# the matching claude-<backend> wrapper, with Claude Code running inside an
# NVIDIA OpenShell sandbox instead of on the host.
#
# Requirements: openshell >= 0.1 (Brewfile: nvidia/openshell/openshell) with
# its local gateway registered as "openshell" (podman compute driver), podman,
# jq, git, and the image built from ../openshell/Containerfile
# (openshell-claude-image-build).
#
# The claude-<backend> function runs unchanged on the host (proxy start, hot
# reload, model detection, /model picker) inside a subshell whose
# _claude_invoke is replaced by _claude_openshell_invoke -- the bridge hook
# common.zsh documents. Instead of `command claude` that:
#   1. creates a sandbox labelled managed-by=claude-openshell, uploading the
#      current git work tree (gitignore-filtered; .git is not uploaded) to
#      /sandbox/<repo>, under a policy that allows only the proxy's port on
#      host.openshell.internal (the sandbox's name for this machine);
#   2. snapshots the upload into a hidden git dir, /sandbox/.claude-openshell;
#   3. uploads a 0600 settings file there carrying the provider's transport
#      env (localhost/127.0.0.1 rewritten to host.openshell.internal, also in
#      a caller --settings env block, where claude-enmaas pins it), so no
#      token appears on any process argv, then runs
#      `claude --bare --settings <that file>` via `sandbox exec`;
#   4. on exit saves claude's changes as a patch under
#      ~/.local/state/claude-openshell/<sandbox>.patch (never applied to the
#      repo automatically), then deletes the sandbox. If saving the patch
#      fails the sandbox is kept; openshell-claude-clean retries later.
#
# Env: CLAUDE_OPENSHELL_GATEWAY (default openshell), CLAUDE_OPENSHELL_IMAGE
# (localhost/openshell-claude:latest), CLAUDE_OPENSHELL_KEEP=1 keeps the
# sandbox after exit, CLAUDE_OPENSHELL_BARE=0 drops --bare,
# CLAUDE_OPENSHELL_NO_UPLOAD=1 starts with an empty workspace (discarded on
# exit), CLAUDE_OPENSHELL_ALLOW_UNFILTERED=1 permits uploading a non-git
# directory, CLAUDE_OPENSHELL_INCLUDE_IGNORED=1 saves gitignored files claude
# created into the patch, CLAUDE_OPENSHELL_ENV adds exported env var names to
# forward, CLAUDE_OPENSHELL_BINARIES overrides the policy's client binaries.
# Verified behavior, design notes and deferred work: ../openshell/README.md.

typeset -g _claude_openshell_dir="${${(%):-%N}:A:h:h}/openshell"
typeset -g _claude_openshell_label="managed-by=claude-openshell"
# Sandbox-side scratch dir: outside the uploaded repo so it never lands in the
# patch, and under /sandbox because `sandbox download` refuses other paths.
typeset -g _claude_openshell_meta="/sandbox/.claude-openshell"

# Forwarded into the sandbox when exported and non-empty (via the settings
# file's env block; COLORTERM, not a secret, via --env so the TUI sees it at
# startup): what the provider wrappers export, so the sandbox env stays clean
# of caller-shell leftovers
# such as ANTHROPIC_SMALL_FAST_MODEL or CLAUDE_CODE_SUBAGENT_MODEL pinned for
# another gateway (add names with CLAUDE_OPENSHELL_ENV). TERM is left to
# OpenShell (it sets xterm-256color; the image lacks e.g. xterm-ghostty).
# Monitor needs DISABLE_NON_ESSENTIAL_MODEL_CALLS and
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC unset (see common.zsh), so they
# are deliberately not listed.
typeset -ga _claude_openshell_env_names=(
    ANTHROPIC_BASE_URL
    ANTHROPIC_AUTH_TOKEN
    ANTHROPIC_API_KEY
    ANTHROPIC_MODEL
    ANTHROPIC_DEFAULT_OPUS_MODEL
    ANTHROPIC_DEFAULT_SONNET_MODEL
    ANTHROPIC_DEFAULT_HAIKU_MODEL
    ANTHROPIC_DEFAULT_FABLE_MODEL
    CLAUDE_CODE_AUTO_MODE_SERVER
    ENABLE_TOOL_SEARCH
    CLAUDE_CODE_USE_VERTEX
    CLAUDE_CODE_USE_BEDROCK
    CLAUDE_CODE_USE_FOUNDRY
    CLAUDE_CODE_ATTRIBUTION_HEADER
    CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION
    CLAUDE_CODE_DISABLE_TERMINAL_TITLE
    CLAUDE_CODE_ENABLE_AWAY_SUMMARY
    COLORTERM
)

_claude_openshell_state() {
    print -r -- "${XDG_STATE_HOME:-$HOME/.local/state}/claude-openshell"
}

# Always pin the gateway: the active one can be a remote gateway, where
# host.openshell.internal would not mean this machine.
_claude_openshell_cli() {
    command openshell -g "${CLAUDE_OPENSHELL_GATEWAY:-openshell}" "$@"
}

_claude_openshell_preflight() {
    local dep
    for dep in openshell jq git; do
        command -v "$dep" &>/dev/null && continue
        if [[ "$dep" == openshell ]]; then
            echo "❌ openshell not found. Install it with: brew install nvidia/openshell/openshell" >&2
        else
            echo "❌ ${dep} not found. Install it with: $(_claude_pkg_install_hint "$dep")" >&2
        fi
        return 1
    done
    # 0.1.0 removed inference.local and broke 0.0.x wire compatibility. An old
    # install.sh copy earlier in PATH (~/.local/bin) misreads 0.1.x CLI state
    # and fails with "workspace_scope is required".
    local ver
    ver=$(command openshell --version 2>/dev/null)
    ver="${ver##* }"
    if [[ ! "$ver" =~ '^([0-9]+)\.([0-9]+)' ]] || (( match[1] == 0 && match[2] < 1 )); then
        echo "❌ $(command -v openshell) is openshell ${ver:-(unknown version)}; need >= 0.1. Remove the stale binary or put Homebrew's first in PATH." >&2
        return 1
    fi
    # `status` exits 0 even for an unknown gateway name; match its output.
    if [[ "$(_claude_openshell_cli status 2>/dev/null)" != *'Status: Connected'* ]]; then
        echo "❌ OpenShell gateway '${CLAUDE_OPENSHELL_GATEWAY:-openshell}' unreachable. Try: brew services restart openshell" >&2
        return 1
    fi
    # The podman driver runs sandboxes in the podman machine, which can stop
    # on its own between sessions.
    if command -v podman &>/dev/null; then
        if ! podman info &>/dev/null; then
            echo "❌ podman is not running. Try: podman machine start" >&2
            return 1
        fi
        local img="${CLAUDE_OPENSHELL_IMAGE:-localhost/openshell-claude:latest}"
        if ! podman image exists "$img"; then
            echo "❌ Sandbox image ${img} not found. Build it with: openshell-claude-image-build" >&2
            return 1
        fi
    fi
}

# Maps a URL for use inside the sandbox; sets reply=(url host port).
# Loopback hosts become host.openshell.internal. The host goes into policy
# YAML, so anything beyond a plain DNS name or IPv4 address is rejected.
_claude_openshell_endpoint() {
    reply=()
    [[ "$1" =~ '^(https?)://(\[::1\]|[A-Za-z0-9.-]+)(:([0-9]{1,5}))?(/[^[:space:]]*)?$' ]] || return 1
    local scheme="$match[1]" host="$match[2]" port="$match[4]" rest="$match[5]"
    [[ -n "$port" ]] || { [[ "$scheme" == https ]] && port=443 || port=80; }
    case "$host" in
        localhost|127.0.0.1|'[::1]') host=host.openshell.internal ;;
    esac
    reply=("${scheme}://${host}:${port}${rest}" "$host" "$port")
}

# Rewrites one --settings value (inline JSON or a host file, which would not
# exist in the sandbox) into inline JSON in $REPLY, remapping
# env.ANTHROPIC_BASE_URL. Appends that endpoint to the caller's `endpoints`.
_claude_openshell_settings() {
    local src="$1" json url
    if [[ -f "$src" ]]; then
        json=$(jq -ce 'select(type == "object")' "$src" 2>/dev/null)
    else
        json=$(jq -ce 'select(type == "object")' <<< "$src" 2>/dev/null)
    fi
    [[ -n "$json" ]] || {
        echo "❌ claude-openshell: --settings must be a JSON object or a readable JSON file." >&2
        return 1
    }
    url=$(jq -r '.env.ANTHROPIC_BASE_URL? // empty | strings' <<< "$json")
    if [[ -n "$url" ]]; then
        _claude_openshell_endpoint "$url" || {
            echo "❌ claude-openshell: unsupported env.ANTHROPIC_BASE_URL in --settings: ${url}" >&2
            return 1
        }
        endpoints+=("${reply[2]}:${reply[3]}")
        json=$(jq -c --arg url "$reply[1]" '.env.ANTHROPIC_BASE_URL = $url' <<< "$json") || return 1
    fi
    REPLY="$json"
}

# Writes the sandbox policy for the given host:port endpoints; prints its path.
# Filesystem rules mirror OpenShell's default policy (workdir + /tmp writable;
# HOME is /sandbox). No `protocol` on the endpoint = L4 passthrough, which the
# plain-HTTP local proxies need.
_claude_openshell_policy() {
    local state file ep bin
    local -a bins=(${=CLAUDE_OPENSHELL_BINARIES:-/usr/local/bin/claude})
    for bin in "${bins[@]}"; do
        [[ "$bin" =~ '^/[A-Za-z0-9._/*+-]+$' ]] || {
            echo "❌ claude-openshell: invalid CLAUDE_OPENSHELL_BINARIES entry: ${bin}" >&2
            return 1
        }
    done
    state=$(_claude_openshell_state)
    file="${state}/policy-${(j:_:)${@//[^A-Za-z0-9.]/-}}.yaml"
    mkdir -p -m 700 "$state" || return 1
    {
        print -r -- 'version: 1'
        print -r -- 'filesystem_policy:'
        print -r -- '  include_workdir: true'
        print -r -- '  read_only: [/bin, /usr, /lib, /etc, /proc, /dev/urandom, /var/log]'
        print -r -- '  read_write: [/sandbox, /tmp, /dev/null]'
        print -r -- 'landlock:'
        print -r -- '  compatibility: best_effort'
        print -r -- 'network_policies:'
        print -r -- '  claude_provider:'
        print -r -- '    name: claude-provider'
        print -r -- '    endpoints:'
        for ep in "$@"; do
            print -r -- "      - host: \"${ep%:*}\""
            print -r -- "        port: ${ep##*:}"
        done
        print -r -- '    binaries:'
        for bin in "${bins[@]}"; do
            print -r -- "      - path: ${bin}"
        done
    } >| "$file" || return 1
    print -r -- "$file"
}

# Saves the sandbox's changes since the baseline snapshot to
# <state>/<name>.patch. Returns non-zero only when the changes could not be
# read, downloaded or saved (the caller then keeps the sandbox).
# Gitignored files claude created (never uploaded, so absent from the
# baseline) are listed rather than saved, so e.g. node_modules/ doesn't swamp
# the patch; CLAUDE_OPENSHELL_INCLUDE_IGNORED=1 saves them too.
_claude_openshell_harvest() {
    local name="$1" root="$2" state out tmp patch force=""
    local -a lines ignored
    [[ "${CLAUDE_OPENSHELL_INCLUDE_IGNORED-}" == 1 ]] && force=-f
    state=$(_claude_openshell_state)
    out=$(_claude_openshell_cli sandbox exec "$name" --no-tty --no-login-shell -- sh -c '
        g="$1/baseline.git" w="$2" p="$1/changes.patch"
        git --git-dir="$g" --work-tree="$w" add -A $3 || exit 1
        git --git-dir="$g" --work-tree="$w" status --porcelain --ignored | sed -n "s/^!! /ignored: /p"
        if git --git-dir="$g" --work-tree="$w" diff --cached --quiet HEAD; then
            echo none
        else
            git --git-dir="$g" --work-tree="$w" diff --cached --binary HEAD > "$p" && echo patch
        fi' sh "$_claude_openshell_meta" "/sandbox/${root:t}" "$force" </dev/null 2>&1)
    # Status is the last line (an array var: a quoted nested ${...[-1]} on a
    # one-line value subscripts characters, not lines).
    lines=("${(@f)out}")
    ignored=(${${(M)lines:#ignored: *}#ignored: })
    if (( ${#ignored} )); then
        echo "⚠️  claude-openshell: gitignored files created in ${name} are not in the patch" \
            "(CLAUDE_OPENSHELL_INCLUDE_IGNORED=1 saves them):" >&2
        print -rl -- "     ${^ignored[1,10]}" >&2
        (( ${#ignored} > 10 )) && echo "     ... and $(( ${#ignored} - 10 )) more" >&2
    fi
    case "${lines[-1]}" in
        none)
            echo "claude-openshell: no changes in ${name}." >&2
            return 0 ;;
        patch) ;;
        *)
            echo "❌ claude-openshell: could not read changes from ${name}: ${out}" >&2
            return 1 ;;
    esac
    tmp=$(command mktemp -d "${TMPDIR:-/tmp}/claude-openshell.XXXXXXXX") || return 1
    if ! _claude_openshell_cli sandbox download "$name" "${_claude_openshell_meta}/changes.patch" "$tmp" \
            </dev/null >/dev/null 2>&1 || [[ ! -s "$tmp/changes.patch" ]]; then
        command rm -rf -- "$tmp"
        echo "❌ claude-openshell: could not download changes from ${name}." >&2
        return 1
    fi
    patch="${state}/${name}.patch"
    if ! { mkdir -p -m 700 "$state" && command mv -f -- "$tmp/changes.patch" "$patch" &&
            command chmod 600 "$patch"; }; then
        command rm -rf -- "$tmp"
        echo "❌ claude-openshell: could not save the patch to ${patch}." >&2
        return 1
    fi
    command rm -rf -- "$tmp"
    echo "claude-openshell: changes saved to ${patch}" >&2
    git -C "$root" apply --stat "$patch" >&2 2>/dev/null
    echo "  apply with: git -C ${(q-)root} apply ${(q-)patch}" >&2
}

# Harvest, then delete unless CLAUDE_OPENSHELL_KEEP=1 or the harvest failed.
_claude_openshell_finish() {
    local name="$1" root="$2" state
    state=$(_claude_openshell_state)
    if [[ -n "$root" ]] && ! _claude_openshell_harvest "$name" "$root"; then
        echo "   Sandbox ${name} kept; retry with: openshell-claude-clean ${name}" >&2
        return 1
    fi
    if [[ "${CLAUDE_OPENSHELL_KEEP-}" == 1 ]]; then
        echo "claude-openshell: kept ${name}; delete with: openshell-claude-clean ${name}" >&2
        return 0
    fi
    # No upload means no baseline to diff against.
    [[ -n "$root" ]] ||
        echo "claude-openshell: ${name} had no uploaded repo; its contents are discarded (CLAUDE_OPENSHELL_KEEP=1 keeps the sandbox)." >&2
    _claude_openshell_cli sandbox delete "$name" </dev/null >/dev/null 2>&1 ||
        echo "⚠️  claude-openshell: deleting ${name} failed; retry with: openshell-claude-clean ${name}" >&2
    command rm -f -- "${state}/${name}.session"
}

# Replacement for common.zsh's _claude_invoke, run inside a provider wrapper
# that already exported its transport env.
_claude_openshell_invoke() {
    emulate -L zsh
    _claude_endpoint_guard
    setopt localtraps
    # The exec child must stay in the terminal's process group (same reason
    # as claude-enmaas) while this shell waits on it interruptibly.
    unsetopt monitor
    zmodload zsh/datetime zsh/system || return 1
    local backend="${_claude_openshell_backend:-claude}"
    local img="${CLAUDE_OPENSHELL_IMAGE:-localhost/openshell-claude:latest}"
    local state name base="" settings='{}' envjson
    local -a args endpoints colorterm
    state=$(_claude_openshell_state)

    # The transport (token included) reaches claude through the env block of
    # a 0600 settings file uploaded into the sandbox, never through
    # `sandbox exec --env` argv, which `ps` shows for the whole session and
    # which the CLI reserves for non-secrets. Values are read by jq from its
    # environment, so they never land on any argv. Verified: `claude --bare
    # --settings <file>` takes base URL, token and model from that block alone.
    if [[ -n "${ANTHROPIC_BASE_URL-}" ]]; then
        _claude_openshell_endpoint "$ANTHROPIC_BASE_URL" || {
            echo "❌ claude-openshell: unsupported ANTHROPIC_BASE_URL: ${ANTHROPIC_BASE_URL}" >&2
            return 1
        }
        base="$reply[1]"
        endpoints+=("${reply[2]}:${reply[3]}")
    fi
    (( ${#endpoints} )) || {
        echo "❌ claude-openshell: the provider exported no ANTHROPIC_BASE_URL." >&2
        return 1
    }
    envjson=$(jq -nc --arg base "$base" '
        [$ARGS.positional[] | select(. != "COLORTERM" and (env[.] // "") != "") | {(.): env[.]}]
        | add // {} | .ANTHROPIC_BASE_URL = $base' \
        --args "${_claude_openshell_env_names[@]}" ${=CLAUDE_OPENSHELL_ENV}) || return 1
    [[ -n "${COLORTERM-}" ]] && colorterm=(--env "COLORTERM=${COLORTERM}")

    # Claude honors only the last --settings, so keep only the last one too.
    while (( $# )); do
        case "$1" in
            --settings)
                (( $# >= 2 )) || {
                    echo "❌ claude-openshell: --settings requires a file or JSON object." >&2
                    return 1
                }
                _claude_openshell_settings "$2" || return 1
                settings="$REPLY"; shift 2 ;;
            --settings=*)
                _claude_openshell_settings "${1#--settings=}" || return 1
                settings="$REPLY"; shift ;;
            --) args+=("$@"); break ;;
            *) args+=("$1"); shift ;;
        esac
    done
    # Settings-layer env wins over process env in Claude Code; keep that order.
    settings=$(jq -c --argjson env "$envjson" '.env = ($env + (.env // {}))' <<< "$settings") || return 1
    args=(--settings "${_claude_openshell_meta}/settings.json" "${args[@]}")
    [[ "${CLAUDE_OPENSHELL_BARE:-1}" == 0 ]] || args=(--bare "${args[@]}")

    # Upload the git work tree containing $PWD; claude starts in the matching
    # subdirectory. Outside a work tree OpenShell would upload everything
    # (dotfiles, keys), so that needs an explicit opt-in.
    local root="" workdir=/sandbox
    if [[ "${CLAUDE_OPENSHELL_NO_UPLOAD-}" != 1 ]]; then
        if ! root=$(git rev-parse --show-toplevel 2>/dev/null); then
            if [[ "${CLAUDE_OPENSHELL_ALLOW_UNFILTERED-}" != 1 ]]; then
                echo "❌ claude-openshell: ${PWD} is not in a git work tree, so its upload would be unfiltered." \
                    "Set CLAUDE_OPENSHELL_ALLOW_UNFILTERED=1 to upload it anyway, or CLAUDE_OPENSHELL_NO_UPLOAD=1." >&2
                return 1
            fi
            root="$PWD"
        fi
        root="${root:A}"
        if [[ "$root" == "${HOME:A}" || "$root" == / ]]; then
            echo "❌ claude-openshell: refusing to upload ${root}; cd into a project or set CLAUDE_OPENSHELL_NO_UPLOAD=1." >&2
            return 1
        fi
        [[ "$root" != *:* ]] || {
            echo "❌ claude-openshell: cannot upload a path containing ':' (${root})." >&2
            return 1
        }
        workdir="/sandbox/${root:t}${${PWD:A}#$root}"
    fi

    # Gateway 0.1.3 caps sandbox names at 19 characters, so the repo goes in
    # a label; the suffix mixes time and pid to keep concurrent runs apart.
    local slug="${(L)${root:t}:-workspace}"
    slug="${${slug//[^a-z0-9]/-}[1,40]}"
    while [[ "$slug" == *- ]]; do slug="${slug%-}"; done
    while [[ "$slug" == -* ]]; do slug="${slug#-}"; done
    local suffix="${(L)$(( [##36] (EPOCHSECONDS * 99991 + sysparams[pid]) % 36**6 ))}"
    name="cl-${backend[1,8]}-${(l:6::0:)suffix}"

    local policy
    policy=$(_claude_openshell_policy "${(u)endpoints[@]}") || return 1
    local -a create=(sandbox create --name "$name" --from "$img" --policy "$policy"
        --no-auto-providers --no-tty --detach
        --label "$_claude_openshell_label" --label "backend=${backend}"
        --label "repo=${slug:-workspace}")
    [[ -n "$root" ]] && create+=(--upload "${root}:/sandbox")

    # Traps only record the signal and stop the exec child (with TERM:
    # background jobs ignore SIGINT without job control); the flow below
    # returns. A `return` inside the trap would lose its status when the
    # signal interrupts `wait ... || rc=$?`.
    local rc=0 child="" created=0 sig=0 out tmp=""
    local -a lines
    trap 'sig=143; [[ -n "$child" ]] && kill -TERM "$child" 2>/dev/null' TERM
    trap 'sig=129; [[ -n "$child" ]] && kill -TERM "$child" 2>/dev/null' HUP
    trap 'sig=130; [[ -n "$child" ]] && kill -TERM "$child" 2>/dev/null' INT
    {
        echo "claude-openshell: creating sandbox ${name} (${backend} via ${(j:, :)${(@u)endpoints}})..." >&2
        mkdir -p -m 700 "$state" && print -rl -- "$sysparams[pid]" "$root" >| "${state}/${name}.session"
        _claude_openshell_cli "${create[@]}" </dev/null >&2 || {
            echo "❌ claude-openshell: sandbox create failed." >&2
            return 1
        }
        created=1
        (( sig )) && return "$sig"
        # Scratch dir, plus a hidden baseline snapshot of the upload: the upload
        # has no .git, and a git dir outside the work tree is one claude
        # cannot disturb.
        out=$(_claude_openshell_cli sandbox exec "$name" --no-tty --no-login-shell -- sh -c '
            g="$1/baseline.git" w="$2"
            mkdir -p "$1" || exit 1
            if [ -n "$w" ]; then
                git init -q --bare "$g" &&
                git --git-dir="$g" --work-tree="$w" add -A &&
                git --git-dir="$g" --work-tree="$w" -c user.name=claude-openshell \
                    -c user.email=claude-openshell@localhost commit -q --allow-empty -m baseline ||
                    exit 1
            fi
            if [ -d "$3" ]; then echo ok; else echo missing-workdir; fi' \
            sh "$_claude_openshell_meta" "${root:+/sandbox/${root:t}}" "$workdir" </dev/null 2>&1)
        lines=("${(@f)out}")
        case "${lines[-1]}" in
            ok) ;;
            missing-workdir) workdir="/sandbox/${root:t}" ;;
            *)
                echo "❌ claude-openshell: sandbox setup failed: ${out}" >&2
                root=""  # nothing to harvest; let cleanup delete the sandbox
                return 1 ;;
        esac
        tmp=$(command mktemp -d "${TMPDIR:-/tmp}/claude-openshell.XXXXXXXX") &&
            print -r -- "$settings" >| "$tmp/settings.json" &&
            command chmod 600 "$tmp/settings.json" &&
            _claude_openshell_cli sandbox upload "$name" "$tmp/settings.json" "${_claude_openshell_meta}/" \
                </dev/null >/dev/null 2>&1 || {
            echo "❌ claude-openshell: could not upload settings to ${name}." >&2
            return 1
        }
        command rm -rf -- "$tmp"; tmp=""
        (( sig )) && return "$sig"
        _claude_openshell_cli sandbox exec "$name" --workdir "$workdir" "${colorterm[@]}" \
            -- claude "${args[@]}" <&0 &
        child=$!
        wait "$child" || rc=$?
        # A trapped signal interrupts wait; let the stopped child finish.
        (( sig )) && { wait "$child" 2>/dev/null; rc=$sig; }
        child=""
        return "$rc"
    } always {
        [[ -n "$tmp" ]] && command rm -rf -- "$tmp"
        if (( created )); then
            _claude_openshell_finish "$name" "$root"
        else
            # A failed create can still leave a sandbox behind (e.g. upload failed).
            _claude_openshell_cli sandbox delete "$name" </dev/null &>/dev/null
            command rm -f -- "${state}/${name}.session"
        fi
    }
}

_claude_openshell_wrap() {
    local backend="$1"; shift
    (( $+functions[claude-${backend}] )) || {
        echo "❌ claude-${backend} is not loaded; source zsh/functions/claude/load.zsh." >&2
        return 1
    }
    _claude_openshell_preflight || return 1
    # Subshell: the override stays local, and wrappers that export into the
    # calling shell (claude-copilot, claude-openai) cannot leak. umask keeps
    # state, policy and settings files private whatever the caller's is.
    (
        umask 077
        _claude_openshell_backend="$backend"
        _claude_invoke() { _claude_openshell_invoke "$@"; }
        "claude-${backend}" "$@"
    )
}

openshell-copilot() { _claude_openshell_wrap copilot "$@"; }
openshell-vertex()  { _claude_openshell_wrap vertex "$@"; }
openshell-enmaas()  { _claude_openshell_wrap enmaas "$@"; }
alias openshell-enmass='openshell-enmaas'   # pre-rename name
openshell-openai()  { _claude_openshell_wrap openai "$@"; }

# openshell-claude-ls: list sandboxes these wrappers created and saved patches.
openshell-claude-ls() {
    _claude_openshell_cli sandbox list --selector "$_claude_openshell_label" -o json 2>/dev/null |
        jq -r '(if type == "array" then . else (.sandboxes // .items // []) end)
            | (["NAME", "BACKEND", "REPO", "PHASE", "CREATED"] | @tsv),
              (.[] | [.name, .labels.backend, .labels.repo, .phase, .created_at] | map(. // "-") | @tsv)' |
        column -t -s $'\t'
    local state
    state=$(_claude_openshell_state)
    local -a patches=("${state}"/*.patch(N))
    (( ${#patches} )) && print -rl -- "Saved patches:" "${patches[@]}"
    return 0
}

# openshell-claude-clean [name...]: save each sandbox's changes, then delete
# it. Only sandboxes carrying the wrappers' label are touched. With no names:
# every such sandbox not in use by a running session (its recorded pid is
# gone). Naming one overrides the in-use check, e.g. for a hung session.
openshell-claude-clean() {
    local state name pid root
    local -a owned names info
    state=$(_claude_openshell_state)
    owned=(${(f)"$(_claude_openshell_cli sandbox list --selector "$_claude_openshell_label" --names 2>/dev/null)"})
    if (( $# )); then
        names=("$@")
    else
        names=("${owned[@]}")
    fi
    for name in "${names[@]}"; do
        if (( ! ${owned[(Ie)$name]} )); then
            echo "skip ${name}: not a sandbox created by these wrappers (no ${_claude_openshell_label} label)" >&2
            continue
        fi
        if [[ ! -r "${state}/${name}.session" ]]; then
            # No record of the uploaded repo: a patch can't be located, so
            # delete only when named explicitly.
            if (( ! ARGC )); then
                echo "skip ${name}: no session record; run: openshell-claude-clean ${name}" >&2
                continue
            fi
            info=()
        else
            info=("${(@f)$(<"${state}/${name}.session")}")
        fi
        pid="${info[1]-}" root="${info[2]-}"
        if (( ! ARGC )) && [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then
            echo "skip ${name}: in use by pid ${pid}" >&2
            continue
        fi
        echo "cleaning ${name}..." >&2
        CLAUDE_OPENSHELL_KEEP=0 _claude_openshell_finish "$name" "$root"
    done
}

# openshell-claude-image-build [podman build args...]: build the sandbox image,
# pinning Claude Code to the host's version so sandbox and host behave alike
# (CLAUDE_OPENSHELL_CLAUDE_VERSION overrides: an exact version, latest, stable).
openshell-claude-image-build() {
    command -v podman &>/dev/null || {
        echo "❌ podman not found (https://podman.io)." >&2
        return 1
    }
    local img="${CLAUDE_OPENSHELL_IMAGE:-localhost/openshell-claude:latest}"
    local ver="${CLAUDE_OPENSHELL_CLAUDE_VERSION-}"
    if [[ -z "$ver" ]]; then
        ver=$(command claude --version 2>/dev/null)
        ver="${ver%% *}"
        [[ "$ver" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || ver=latest
    fi
    echo "Building ${img} (Claude Code ${ver})..." >&2
    podman build --build-arg "CLAUDE_VERSION=${ver}" -t "$img" "$@" \
        -f "${_claude_openshell_dir}/Containerfile" "$_claude_openshell_dir"
}
