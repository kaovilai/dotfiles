#!/usr/bin/env zsh
# context-mode-daemon-sync: make this machine serve every Claude session from
# the one shared context-mode daemon (kaovilai/context-mode fork, 2.2.x) instead
# of a per-session stdio server. Idempotent, run by fleet-sync on every pass:
# the plugin's versioned cache path moves with every update, so the daemon
# unit's ExecStart is re-pointed whenever the installed version changes.
#
#   scripts/context-mode-daemon-sync.zsh [--dry-run] [--quiet]
#
# Steps (each a no-op when already current):
#   1. node >= 24.15  the daemon refuses to run below it (the v2 plugin is
#      degraded there too). Looked up: $PATH node, then a stable per-user copy
#      at ~/.local/lib/node-v24 (any 24.x), then Homebrew's node@24. Still
#      missing: installed automatically (Homebrew node@24 on macOS; the
#      sha256-verified official nodejs.org tarball into ~/.local/lib/node-v24
#      elsewhere), unless CONTEXT_MODE_DAEMON_NODE_AUTOINSTALL=0. An install
#      that cannot happen is a warning, not an error: the machine still runs,
#      just without the shared daemon.
#   2. daemon unit    Linux+systemd: `daemon.mjs --install` (writes, enables,
#      restarts the user unit) when the unit is missing, inactive, or its
#      ExecStart names a different daemon.mjs than the newest installed one.
#      macOS: a LaunchAgent (com.kaovilai.context-mode-daemon.plist, KeepAlive)
#      managed the same way. Anything else: skip with a note.
#   3. registration   the user-scope HTTP server (context-mode ->
#      http://127.0.0.1:8790/mcp) is added when `claude mcp get` cannot find
#      it; an existing entry with a different URL is left alone with a warning.
# Port: the daemon default (8790); override with CONTEXT_MODE_DAEMON_PORT
# before this script (the unit and the registration both read it).
emulate -LR zsh
setopt err_exit pipe_fail typeset_silent
typeset root="${0:A:h:h}" dry=0 quiet=0 arg daemon_port="${CONTEXT_MODE_DAEMON_PORT:-8790}"
typeset BLUE=$'\e[1;34m' GREEN=$'\e[1;32m' YELLOW=$'\e[1;33m' RED=$'\e[1;31m' NC=$'\e[0m'
[[ -t 2 ]] || { BLUE=""; GREEN=""; YELLOW=""; RED=""; NC=""; }
for arg; do
    case $arg in
        --dry-run) dry=1 ;;
        --quiet) quiet=1 ;;
        *) print -u2 "usage: ${0:t} [--dry-run] [--quiet]"; exit 2 ;;
    esac
done
# progress/success/warning/error inlined from zsh/functions/migrate-laptop.zsh
# instead of sourcing it: the sourced file pulls the interactive shell env with
# it, which can rebuild PATH (a precommand hook: vite-plus does this), dropping
# the PATH this script was deliberately given. fleet-sync and the tests both
# depend on that PATH.
progress() { print -- "${BLUE}==>${NC} $1"; }
success() { print -- "${GREEN}✓${NC} $1"; }
warning() { print -- "${YELLOW}⚠${NC} $1" >&2; }
error()   { print -- "${RED}✗${NC} $1" >&2; }
(( quiet )) && { progress() { :; }; success() { :; } }

typeset claude="${CLAUDE_PROVIDER_NATIVE_BINARY:-$HOME/.local/bin/claude}"
typeset cache="$HOME/.claude/plugins/cache/context-mode/context-mode"
typeset -a problems=()

# --- 0. the newest installed daemon bundle ------------------------------------
# Selected first: without a bundle there is nothing to serve, and node would be
# downloaded for nothing (the plugin install may simply not have run yet).
typeset -a versions=("$cache"/*(N/))
(( ${#versions} )) || { progress "context-mode: plugin not installed yet; nothing to sync"; exit 0; }
typeset newest="" v
_cm_ver_key() {  # 2.2.10 -> 2000002000010: one integer, numeric ordering (lexicographic sorts 2.2.9 higher)
    local -a parts=(${=1//./ })
    printf '%d%06d%06d' "${parts[1]:-0}" "${parts[2]:-0}" "${parts[3]:-0}"
}
for v in "${versions[@]}"; do
    [[ -f "$v/daemon.mjs" ]] || continue
    if [[ -z "$newest" ]] || (( $(_cm_ver_key "${v:t}") > $(_cm_ver_key "${newest:t}") )); then
        newest="$v"
    fi
done
[[ -n "$newest" ]] || { progress "context-mode: no daemon.mjs in the installed plugin (pre-2.2 cache only); nothing to sync"; exit 0; }
typeset daemon="$newest/daemon.mjs"

# --- 1. node >= 24.15 ----------------------------------------------------------
# The daemon needs it and the v2 plugin is degraded below it; a per-user copy
# keeps the unit independent of whichever node a shell happens to expose.
typeset node_bin="" ver
_cm_node_ok() {  # node binary path -> 0 when its version is >= 24.15 (numeric, not v24.*)
    [[ -x "$1" ]] || return 1
    local v maj min
    v=$("$1" --version 2>/dev/null) || return 1
    [[ "$v" == v*.*.* ]] || return 1
    maj=${v#v}; maj=${maj%%.*}
    min=${v#v*${maj}.}; min=${min%%.*}
    (( maj > 24 )) || (( maj == 24 && min >= 15 ))
}
if _cm_node_ok "$(command -v node)"; then
    node_bin="$(command -v node)"
elif [[ -d "$HOME/.local/lib" ]]; then
    for ver in "$HOME/.local/lib"/node-v24*(N/); do
        # Dirs in the autoinstall layout (node-v<ver>-<plat>-<arch>) are only
        # trusted with the completion marker: a partial extraction can leave a
        # runnable bin/node behind, and selecting it would skip the retry
        # forever. Manually placed dirs without the platform suffix are trusted
        # as-is — the marker is ours, not theirs.
        if [[ "$ver" == *-linux-* || "$ver" == *-darwin-* ]]; then
            [[ -f "$ver/.cm-node-installed" ]] || continue
        fi
        if _cm_node_ok "$ver/bin/node"; then node_bin="$ver/bin/node"; break; fi
    done
fi
if [[ -z "$node_bin" ]] && command -v brew >/dev/null; then
    for ver in "$(brew --prefix 2>/dev/null)"/opt/node@24/bin/node(N) "$(brew --prefix 2>/dev/null)"/opt/node/bin/node(N); do
        [[ -n "$ver" ]] && _cm_node_ok "$ver" && { node_bin="$ver"; break; }
    done
fi
if [[ -z "$node_bin" ]] && [[ "${CONTEXT_MODE_DAEMON_NODE_AUTOINSTALL:-1}" != 0 ]] && command -v curl >/dev/null; then
    # Install the prerequisite ourselves: nodejs.org's official tarball, sha256-verified
    # against the published SHASUMS256.txt, extracted to ~/.local/lib/node-v<ver> (the
    # layout probed above, so the unit never depends on a shell's PATH). macOS prefers
    # brew when present (the tarball works there too, but brew is the house style).
    typeset nv="24.15.0" sys="$(uname -s)" arch="$(uname -m)" plat="" base="$HOME/.local/lib"
    case "$sys" in
        Darwin) plat="darwin" ;;
        Linux) plat="linux" ;;
    esac
    case "$arch" in
        x86_64) arch="x64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) plat="" ;;
    esac
    if [[ -n "$plat" ]] && command -v brew >/dev/null 2>&1 && [[ "$sys" == "Darwin" ]]; then
        progress "context-mode daemon: no node >= 24.15; brew install node@24"
        (( dry )) || brew install node@24 >/dev/null 2>&1 || true
        for ver in "$(brew --prefix 2>/dev/null)"/opt/node@24/bin/node(N); do
            [[ -n "$ver" ]] && _cm_node_ok "$ver" && node_bin="$ver"
        done
    elif [[ -n "$plat" ]]; then
        typeset tgz="node-v${nv}-${plat}-${arch}.tar.xz" dest="$base/node-v${nv}-${plat}-${arch}"
        # A complete install is marked, not merely present: a failed extraction that
        # left the directory behind must retry, not block every later run.
        if [[ ! -f "$dest/.cm-node-installed" ]]; then
            progress "context-mode daemon: no node >= 24.15; installing ${tgz} from nodejs.org"
            if ! (( dry )); then
                # inside the guard: a dry run must not delete a partial install
                # it then declines to replace
                rm -rf "$dest"
                typeset dl=$(mktemp -d "${TMPDIR:-/tmp}/cm-node.XXXXXX") shas=""
                {
                    # bounded: a stalled transfer must not hang fleet-sync
                    curl -fsSL --connect-timeout 10 --max-time 180 -o "$dl/$tgz" "https://nodejs.org/dist/v${nv}/${tgz}" &&
                        shas=$(curl -fsSL --connect-timeout 10 --max-time 60 "https://nodejs.org/dist/v${nv}/SHASUMS256.txt" | grep -F " $tgz" | awk '{print $1}') &&
                        [[ -n "$shas" ]] &&
                        if command -v shasum >/dev/null 2>&1; then
                            printf '%s  %s\n' "$shas" "$dl/$tgz" | shasum -a 256 -c - >/dev/null 2>&1
                        else
                            printf '%s  %s\n' "$shas" "$dl/$tgz" | sha256sum -c - >/dev/null 2>&1
                        fi &&
                        mkdir -p "$base" && tar -xJf "$dl/$tgz" -C "$base" && : >| "$dest/.cm-node-installed"
                } || warning "context-mode daemon: node ${nv} download/install failed (needs curl, a sha256 checker, tar with xz)"
                rm -rf "$dl"
            fi
        fi
        # marker-gated here too: an incomplete extraction must not be used even
        # on the run that created it
        [[ -f "$dest/.cm-node-installed" ]] && _cm_node_ok "$dest/bin/node" && node_bin="$dest/bin/node"
    fi
fi
if [[ -z "$node_bin" ]]; then
    warning "context-mode daemon: no node >= 24.15 found (needed by the daemon; the v2 plugin is degraded below it); the daemon step was skipped. Auto-install needs curl (and CONTEXT_MODE_DAEMON_NODE_AUTOINSTALL not 0): the official nodejs.org tarball lands in ~/.local/lib"
    exit 0   # not an error: the machine still runs, just without the shared daemon
fi

# --- 2. the unit ---------------------------------------------------------------
typeset want_url="http://127.0.0.1:${daemon_port}/mcp"
typeset -i daemon_ready=0   # the registration move only runs once the daemon is confirmed on $daemon_port
if [[ "$(uname -s)" == "Linux" ]] && command -v systemctl >/dev/null && systemctl --user list-units >/dev/null 2>&1; then
    typeset unit="$HOME/.config/systemd/user/context-mode-daemon.service" exec_line
    exec_line=$(grep -m1 '^ExecStart=' "$unit" 2>/dev/null || true)   # a missing unit must not trip err_exit
    # the node the unit would start: first ExecStart token, quotes stripped — a
    # removed binary (cleaned-up autoinstall dir) must re-install the unit, not
    # stay "current" until the next KeepAlive restart fails
    typeset exec_node="${exec_line#ExecStart=}"
    exec_node="${exec_node%%[[:space:]]*}"
    exec_node="${exec_node//\"/}"
    # ~/.claude is a symlink into ~/.config/claude: the unit may carry either
    # spelling, so compare against both the raw and the resolved path. The saved
    # port is compared too: a CONTEXT_MODE_DAEMON_PORT change must re-install,
    # not leave the daemon on the old port while the registration points at the new one.
    typeset daemon_real="${daemon:A}" unit_text=""
    if [[ -f "$unit" ]]; then unit_text=$(<"$unit"); fi
    if [[ ! -f "$unit" ]] || ! systemctl --user is-active --quiet context-mode-daemon.service 2>/dev/null ||
        { [[ "$exec_line" != *"$daemon"* ]] && [[ "$exec_line" != *"$daemon_real"* ]]; } ||
        [[ -z "$exec_node" || ! -x "$exec_node" ]] ||
        # the closing quote makes the port compare exact: 879 must not match 8790
        [[ "$unit_text" != *"CONTEXT_MODE_DAEMON_PORT=${daemon_port}\""* ]]; then
        progress "context-mode daemon: installing the systemd unit for ${newest:t}"
        if (( dry )); then
            :
        elif "$node_bin" "$daemon" --install >/dev/null; then
            systemctl --user is-active --quiet context-mode-daemon.service 2>/dev/null && daemon_ready=1
        else
            warning "context-mode daemon: --install failed"
            problems+=('unit')
        fi
    else
        daemon_ready=1   # current and active — both verified by the staleness check above
    fi
elif [[ "$(uname -s)" == "Darwin" ]] && command -v launchctl >/dev/null; then
    typeset plist="$HOME/Library/LaunchAgents/com.kaovilai.context-mode-daemon.plist" label=com.kaovilai.context-mode-daemon
    # plist strings are XML: & < > in $HOME or the paths would break the document
    _cm_plist_escape() { print -r -- "${1//&/&amp;}" | sed -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
    typeset need=0 stored_node
    [[ -f "$plist" ]] || need=1
    # the plist stores XML-escaped paths: compare against the escaped spelling,
    # or a HOME containing & or < never matches and every pass re-loads a valid agent
    [[ "$need" -eq 0 ]] && ! grep -qF "$(_cm_plist_escape "$daemon")" "$plist" && need=1
    [[ "$need" -eq 0 ]] && ! grep -q "<string>${daemon_port}</string>" "$plist" && need=1
    # a stored node path that no longer exists (cleaned up, moved) must re-install,
    # or the next KeepAlive restart fails silently
    if [[ "$need" -eq 0 ]]; then
        stored_node=$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$plist" | sed -n 's/.*<string>\([^<]*\)<\/string>.*/\1/p' | head -1)
        # decode the writer's XML entities before testing the real path
        stored_node="${stored_node//&amp;/&}"
        stored_node="${stored_node//&lt;/<}"
        stored_node="${stored_node//&gt;/>}"
        [[ -n "$stored_node" && -x "$stored_node" ]] || need=1
    fi
    [[ "$need" -eq 0 ]] && ! launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 && need=1
    if (( need )); then
        progress "context-mode daemon: installing the LaunchAgent for ${newest:t}"
        (( dry )) || {
            mkdir -p "${plist:h}" || { warning "context-mode daemon: cannot create ${plist:h}"; problems+=('unit'); }
            print -r -- "$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(_cm_plist_escape "$node_bin")</string>
        <string>$(_cm_plist_escape "$daemon")</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>CONTEXT_MODE_DAEMON_PORT</key><string>${daemon_port}</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$(_cm_plist_escape "$HOME")/.local/state/context-mode-daemon.log</string>
    <key>StandardErrorPath</key><string>$(_cm_plist_escape "$HOME")/.local/state/context-mode-daemon.log</string>
</dict>
</plist>
EOF
)" >| "$plist" || { warning "context-mode daemon: cannot write $plist"; problems+=('unit'); }
            # launchd opens the log files before starting node: the directory must exist
            mkdir -p "$HOME/.local/state" 2>/dev/null
            # boot out the loaded job first: kickstart alone would restart the OLD
            # in-memory definition instead of the rewritten plist
            # || true: on a first install there is no loaded job to boot out, and a
            # failing bare command would end the script under err_exit
            launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
            if launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null; then
                launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 && daemon_ready=1
            else
                warning "context-mode daemon: launchctl failed"
                problems+=('unit')
            fi
        }
    else
        daemon_ready=1   # plist current, node present, agent loaded — all verified above
    fi
else
    progress "context-mode daemon: no systemd user session or launchd; run '$node_bin $daemon' yourself"
fi

# --- 3. the user-scope registration --------------------------------------------
if [[ -x "$claude" ]]; then
    typeset have
    have=$(cd ~ && "$claude" mcp get context-mode 2>/dev/null || true)   # a missing entry must not trip err_exit
    # The URL is matched as its own field (the "URL:" line), never as a substring of
    # the whole report: `mcp get` can print headers after the URL, and a substring
    # match would both accept foreign paths (/other/mcp, /mcp-other) as managed and
    # miss a managed entry whose URL is not the last line (A26-cr3).
    typeset entry_url=""
    # || true: with no registration there is no URL line, grep exits 1, and under
    # err_exit+pipe_fail the bare assignment would end the script — an absent
    # entry means "", not a failure
    entry_url=$(print -r -- "$have" | grep -m1 'URL:' | sed 's/.*URL:[[:space:]]*//') || true
    typeset -i ours_at_user=0
    [[ "$entry_url" == "$want_url" && "$have" == *"User config"* ]] && ours_at_user=1
    if (( ours_at_user )); then
        :   # current: the daemon's own entry, at user scope, on the right port
    elif [[ "$have" == *"User config"* ]] && [[ "$entry_url" =~ ^http://127\.0\.0\.1:[0-9]+/mcp$ ]]; then
        # OUR user-scoped entry on another port (CONTEXT_MODE_DAEMON_PORT moved):
        # re-point it, or sessions keep connecting to the port the daemon no longer
        # uses. The match is user scope + an exact /mcp path — a non-user entry or a
        # foreign path (/mcp-other) must not be removed (A26-cr2).
        if (( daemon_ready )); then
            progress "context-mode daemon: moving the registration to $want_url"
            if (( dry )); then
                :
            elif (cd ~ && "$claude" mcp remove context-mode -s user >/dev/null 2>&1); then
                if (cd ~ && "$claude" mcp add --scope user --transport http context-mode "$want_url" >/dev/null 2>&1); then
                    :   # moved
                elif (cd ~ && "$claude" mcp add --scope user --transport http context-mode "$entry_url" >/dev/null 2>&1); then
                    # transactional: restore what was removed rather than leave the
                    # fleet with no registration at all
                    warning "context-mode daemon: claude mcp add failed; the previous registration ($entry_url) was restored"
                    problems+=('mcp')
                else
                    warning "context-mode daemon: claude mcp add failed and the previous registration could not be restored; the next sync will retry"
                    problems+=('mcp')
                fi
            else
                warning "context-mode daemon: could not remove the old-port registration; left as-is"
                problems+=('mcp')
            fi
        else
            # the unit step could not confirm the daemon on $daemon_port (install
            # failed or the service is down): the old registration still points
            # where the daemon actually is, so it stays until the daemon catches up
            warning "context-mode daemon: daemon not confirmed on port ${daemon_port}; leaving the registration at $entry_url"
        fi
    elif [[ -z "$have" || "$have" != *"User config"* ]]; then
        # absent, or only a project/local-scoped entry (which `mcp get` can surface
        # and would wrongly read as ours): the user-scope entry is what the fleet uses
        progress "context-mode daemon: registering $want_url at user scope"
        (( dry )) || (cd ~ && "$claude" mcp add --scope user --transport http context-mode "$want_url" >/dev/null 2>&1) || { warning "context-mode daemon: claude mcp add failed"; problems+=('mcp'); }
    else
        warning "context-mode daemon: an existing user-scoped 'context-mode' entry does not point at $want_url; left as-is"
    fi
else
    warning "context-mode daemon: Claude Code not found at $claude; registration skipped"
fi

(( ${#problems} )) && { error "context-mode daemon sync: ${#problems} problem(s) above"; exit 1; }
success "context-mode daemon: current (node ${node_bin:h:h:t}, unit and registration checked)"
exit 0
