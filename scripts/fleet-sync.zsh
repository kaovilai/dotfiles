#!/usr/bin/env zsh
# Keep this machine in step with the fleet: fast-forward the dotfiles, Claude
# config (~/.config/claude, behind ~/.claude) and copilot-api checkouts from
# their upstreams, then apply what changed. Never commits, merges or discards:
# a repo with uncommitted changes, unpushed commits or a diverged branch is
# skipped with a warning. Edit on one machine, push, and the others follow.
#
#   zsh ~/git/dotfiles/scripts/fleet-sync.zsh [--dry-run] [--quiet] [--update-plugins]
#   zsh ~/git/dotfiles/scripts/fleet-sync.zsh --install-timer   # Linux: hourly systemd user timer
#   zsh ~/git/dotfiles/scripts/fleet-sync.zsh --remove-timer
#
# After a fast-forward:
#   Claude config  install newly enabled plugins (sync-claude-plugins)
#   copilot-api    bun install when bun.lock changed; stop the gateway if it
#                  is idle so the next session starts the new code. Not
#                  restarted here: under the timer a process started by this
#                  run dies with it, and claude-t3-copilot starts it on demand.
#   dotfiles       import new or changed T3 provider instances
#                  (import-t3-providers); shells and launchers read it in place.
# Marketplace refresh + plugin updates (network-heavy) run once a day, or now
# with --update-plugins. --dry-run fetches but changes nothing.
# Exit status: 0 when everything is in sync or was updated, 1 when a repo was
# skipped or a step failed (the timer's journal shows which).
# Repo paths: FLEET_DOTFILES_DIR, FLEET_CLAUDE_DIR, COPILOT_API_DIR.
emulate -L zsh
setopt pipe_fail

typeset root="${0:A:h:h}" dry=0 quiet=0 update_plugins=0 timer= arg
for arg in "$@"; do
    case $arg in
        --dry-run) dry=1 ;;
        --quiet) quiet=1 ;;
        --update-plugins) update_plugins=1 ;;
        --install-timer) timer=install ;;
        --remove-timer) timer=remove ;;
        -h|--help) sed -n '2,24p' "${0:A}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print -ru2 -- "fleet-sync: unknown option $arg (see --help)"; exit 2 ;;
    esac
done

source "$root/zsh/functions/migrate-laptop.zsh"   # progress/success/warning/error, sync-claude-plugins
path=(~/.local/bin ~/.bun/bin $path)

# --- timer ------------------------------------------------------------------
typeset unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
if [[ $timer == install ]]; then
    [[ "$OSTYPE" == linux* && -d /run/systemd/system ]] || { error "--install-timer needs Linux with systemd"; exit 1; }
    mkdir -p "$unit_dir" || exit 1
    print -r -- "[Unit]
Description=fleet-sync: fast-forward dotfiles, Claude config and copilot-api

[Service]
Type=oneshot
ExecStart=${commands[zsh]} ${root}/scripts/fleet-sync.zsh --quiet" >| "$unit_dir/fleet-sync.service"
    print -r -- "[Unit]
Description=Run fleet-sync hourly

[Timer]
OnBootSec=5min
OnCalendar=hourly
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target" >| "$unit_dir/fleet-sync.timer"
    systemctl --user daemon-reload && systemctl --user enable --now fleet-sync.timer || exit 1
    success "fleet-sync.timer enabled (logs: journalctl --user -u fleet-sync)"
    exit 0
elif [[ $timer == remove ]]; then
    systemctl --user disable --now fleet-sync.timer 2>/dev/null
    rm -f "$unit_dir/fleet-sync.service" "$unit_dir/fleet-sync.timer"
    systemctl --user daemon-reload 2>/dev/null
    success "fleet-sync.timer removed"
    exit 0
fi

# --- repos ------------------------------------------------------------------
typeset -i problems=0
typeset -A before=()   # label -> HEAD before a fast-forward

_note() { (( quiet )) || success "$@"; }

# _sync_repo <label> <dir>: fast-forward <dir> to its upstream when that is
# safe; records the old HEAD in $before when it moved.
_sync_repo() {
    local label=$1 dir=$2 up remote ahead behind old
    if [[ ! -e "$dir/.git" ]]; then
        _note "$label: no checkout at $dir"
        return 0
    fi
    up=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
        || { warning "$label: $(git -C "$dir" branch --show-current 2>/dev/null || print detached HEAD) has no upstream; skipped"; return 1; }
    remote=${up%%/*}
    git -C "$dir" fetch --quiet "$remote" 2>/dev/null \
        || { warning "$label: fetch from $remote failed (offline, or no credentials for a private repo); skipped"; return 1; }
    read -r ahead behind < <(git -C "$dir" rev-list --left-right --count 'HEAD...@{u}')
    if (( ! behind )); then
        if (( ahead )); then warning "$label: $ahead commit(s) not pushed to $up"
        else _note "$label: up to date"; fi
        return 0
    fi
    if (( ahead )); then
        warning "$label: diverged from $up ($ahead local, $behind upstream); skipped, merge it by hand"
        return 1
    fi
    if ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
        warning "$label: uncommitted changes; skipped ($behind upstream commit(s) waiting)"
        return 1
    fi
    old=$(git -C "$dir" rev-parse HEAD)
    if (( dry )); then
        success "$label: would fast-forward $behind commit(s) from $up"
        return 0
    fi
    git -C "$dir" merge --ff-only --quiet '@{u}' \
        || { warning "$label: fast-forward failed (untracked files in the way?); skipped"; return 1; }
    before[$label]=$old
    success "$label: fast-forwarded $behind commit(s) from $up"
}

typeset dotfiles_dir="${FLEET_DOTFILES_DIR:-$root}"
typeset claude_dir="${FLEET_CLAUDE_DIR:-${${:-$HOME/.claude}:A}}"
typeset capi_dir="${COPILOT_API_DIR:-$HOME/git/copilot-api}"
_sync_repo dotfiles "$dotfiles_dir" || (( problems++ ))
_sync_repo claude-config "$claude_dir" || (( problems++ ))
_sync_repo copilot-api "$capi_dir" || (( problems++ ))

# --- apply ------------------------------------------------------------------
typeset state="${XDG_STATE_HOME:-$HOME/.local/state}/fleet-sync" stamp
stamp="$state/plugins-updated"
typeset -a plugin_args=()
(( dry )) && plugin_args+=(--dry-run)
# Daily: refresh marketplaces and update plugins even without a config change.
typeset -a stale=($stamp(N.mh+24))
if (( update_plugins )) || [[ ! -f "$stamp" ]] || (( ${#stale} )); then
    plugin_args+=(--update)
fi
if [[ -n "${before[claude-config]-}" || ${plugin_args[(I)--update]} -gt 0 ]]; then
    if sync-claude-plugins $plugin_args; then
        (( dry )) || [[ ${plugin_args[(I)--update]} -eq 0 ]] || { mkdir -p "$state" && : >| "$stamp"; }
    else
        (( problems++ ))
    fi
fi

# dotfiles carry the T3 provider instances (t3/provider-instances.json);
# import-t3-providers leaves instances edited on this machine alone.
if [[ -n "${before[dotfiles]-}" ]]; then
    import-t3-providers || (( problems++ ))
fi

if [[ -n "${before[copilot-api]-}" ]]; then
    if [[ -n "$(git -C "$capi_dir" diff --name-only "${before[copilot-api]}" HEAD -- bun.lock package.json)" ]]; then
        progress "copilot-api dependencies changed"
        bun install --cwd "$capi_dir" --frozen-lockfile --silent || { warning "bun install failed in $capi_dir"; (( problems++ )); }
    fi
    source "$root/zsh/functions/claude/load.zsh"
    typeset port="${COPILOT_API_PORT:-4141}"
    if [[ -z "$(_claude_listen_pids "$port" 2>/dev/null)" ]]; then
        _note "copilot-api gateway not running; the next session starts the new code"
    elif _claude_port_serving "$port"; then
        warning "copilot-api gateway is serving a request; new code applies after: llm-proxy-restart copilot"
    else
        claude-copilot-kill >/dev/null && success "copilot-api gateway stopped; the next session starts the new code"
    fi
fi

(( problems )) && exit 1
exit 0
