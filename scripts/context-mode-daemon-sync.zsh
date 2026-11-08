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
for arg; do
    case $arg in
        --dry-run) dry=1 ;;
        --quiet) quiet=1 ;;
        *) print -u2 "usage: ${0:t} [--dry-run] [--quiet]"; exit 2 ;;
    esac
done
source "$root/zsh/functions/migrate-laptop.zsh"   # progress/success/warning/error
(( quiet )) && { progress() { :; }; success() { :; } }

typeset claude="${CLAUDE_PROVIDER_NATIVE_BINARY:-$HOME/.local/bin/claude}"
typeset cache="$HOME/.claude/plugins/cache/context-mode/context-mode"
typeset -a problems=()

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
        if [[ ! -d "$dest" ]]; then
            progress "context-mode daemon: no node >= 24.15; installing ${tgz} from nodejs.org"
            if ! (( dry )); then
                typeset dl=$(mktemp -d "${TMPDIR:-/tmp}/cm-node.XXXXXX") shas=""
                {
                    curl -fsSL -o "$dl/$tgz" "https://nodejs.org/dist/v${nv}/${tgz}" &&
                        shas=$(curl -fsSL "https://nodejs.org/dist/v${nv}/SHASUMS256.txt" | grep -F " $tgz" | awk '{print $1}') &&
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
        _cm_node_ok "$dest/bin/node" && node_bin="$dest/bin/node"
    fi
fi
if [[ -z "$node_bin" ]]; then
    warning "context-mode daemon: no node >= 24.15 found (needed by the daemon; the v2 plugin is degraded below it); the daemon step was skipped. Auto-install needs curl (and CONTEXT_MODE_DAEMON_NODE_AUTOINSTALL not 0): the official nodejs.org tarball lands in ~/.local/lib"
    exit 0   # not an error: the machine still runs, just without the shared daemon
fi

# --- the newest installed daemon bundle ---------------------------------------
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

# --- 2. the unit ---------------------------------------------------------------
typeset want_url="http://127.0.0.1:${daemon_port}/mcp"
if [[ "$(uname -s)" == "Linux" ]] && command -v systemctl >/dev/null && systemctl --user list-units >/dev/null 2>&1; then
    typeset unit="$HOME/.config/systemd/user/context-mode-daemon.service" exec_line
    exec_line=$(grep -m1 '^ExecStart=' "$unit" 2>/dev/null || true)   # a missing unit must not trip err_exit
    # ~/.claude is a symlink into ~/.config/claude: the unit may carry either
    # spelling, so compare against both the raw and the resolved path. The saved
    # port is compared too: a CONTEXT_MODE_DAEMON_PORT change must re-install,
    # not leave the daemon on the old port while the registration points at the new one.
    typeset daemon_real="${daemon:A}" unit_text
    unit_text=$(<"$unit" 2>/dev/null || true)
    if [[ ! -f "$unit" ]] || ! systemctl --user is-active --quiet context-mode-daemon.service 2>/dev/null ||
        { [[ "$exec_line" != *"$daemon"* ]] && [[ "$exec_line" != *"$daemon_real"* ]]; } ||
        [[ "$unit_text" != *"CONTEXT_MODE_DAEMON_PORT=${daemon_port}"* ]]; then
        progress "context-mode daemon: installing the systemd unit for ${newest:t}"
        (( dry )) || { "$node_bin" "$daemon" --install >/dev/null || { warning "context-mode daemon: --install failed"; problems+=('unit'); } }
    fi
elif [[ "$(uname -s)" == "Darwin" ]] && command -v launchctl >/dev/null; then
    typeset plist="$HOME/Library/LaunchAgents/com.kaovilai.context-mode-daemon.plist" label=com.kaovilai.context-mode-daemon
    typeset need=0
    [[ -f "$plist" ]] || need=1
    [[ "$need" -eq 0 ]] && ! grep -q "$daemon" "$plist" && need=1
    [[ "$need" -eq 0 ]] && ! grep -q "<string>${daemon_port}</string>" "$plist" && need=1
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
        <string>${node_bin}</string>
        <string>${daemon}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>CONTEXT_MODE_DAEMON_PORT</key><string>${daemon_port}</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>${HOME}/.local/state/context-mode-daemon.log</string>
    <key>StandardErrorPath</key><string>${HOME}/.local/state/context-mode-daemon.log</string>
</dict>
</plist>
EOF
)" >| "$plist" || { warning "context-mode daemon: cannot write $plist"; problems+=('unit'); }
            # launchd opens the log files before starting node: the directory must exist
            mkdir -p "$HOME/.local/state" 2>/dev/null
            # boot out the loaded job first: kickstart alone would restart the OLD
            # in-memory definition instead of the rewritten plist
            launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
            launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || { warning "context-mode daemon: launchctl failed"; problems+=('unit'); }
        }
    fi
else
    progress "context-mode daemon: no systemd user session or launchd; run '$node_bin $daemon' yourself"
fi

# --- 3. the user-scope registration --------------------------------------------
if [[ -x "$claude" ]]; then
    typeset have
    have=$(cd ~ && "$claude" mcp get context-mode 2>/dev/null || true)   # a missing entry must not trip err_exit
    if [[ -z "$have" ]]; then
        progress "context-mode daemon: registering $want_url at user scope"
        (( dry )) || (cd ~ && "$claude" mcp add --scope user --transport http context-mode "$want_url" >/dev/null 2>&1) || { warning "context-mode daemon: claude mcp add failed"; problems+=('mcp'); }
    elif [[ "$have" != *"$want_url"* ]]; then
        warning "context-mode daemon: an existing 'context-mode' MCP entry does not point at $want_url; left as-is"
    fi
else
    warning "context-mode daemon: Claude Code not found at $claude; registration skipped"
fi

(( ${#problems} )) && { error "context-mode daemon sync: ${#problems} problem(s) above"; exit 1; }
success "context-mode daemon: current (node ${node_bin:h:h:t}, unit and registration checked)"
exit 0
