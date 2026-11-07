#!/usr/bin/env zsh
# Detached idle reaper for the claude-mlx pair (mlx_lm.server plus the Go
# proxy's mlx flavor in front of it). mlx_lm.server pins the full model
# weights in RAM for as long as it runs and nothing else in the pair ever
# stops it, so after any thread uses claude-mlx the memory stays allocated
# until claude-mlx-kill. T3 (and the SDK wrappers generally) run one Claude
# process per turn that exits at turn end, so "no ESTABLISHED client socket
# on the proxy's port" reliably means no thread is using the model -- the
# proxy's own upstream hop to mlx_lm.server lives on the model port, never
# on its own listening port. After <timeout> seconds of that, this script
# stops the pair so the weights leave RAM.
#
#   zsh scripts/mlx-idle-watch.zsh <timeout-s> <mlx-port> <proxy-port> <keep-proxy 0|1>
#
# Started by _claude_mlx_watch_start in zsh/functions/claude/providers/mlx.zsh
# via _claude_proxy_start, so it survives the preparation subprocess. No
# credentials are read here. The proxy half is stopped through
# claude-mlx-kill, which uses the Go binary's identity-checked stop; the
# mlx_lm.server half gets an explicit command-line identity check here
# because claude-mlx-kill stops it by port. keep-proxy=1 keeps the ~10MB Go
# shim warm and only stops mlx_lm.server, the process holding the
# multi-GB weights. Log + pid under
# ${XDG_STATE_HOME:-~/.local/state}/claude-mlx/.
emulate -L zsh
path=($path /opt/homebrew/bin /usr/local/bin)

timeout_s="$1"; mlx_port="$2"; proxy_port="$3"; keep_proxy="$4"
export CLAUDE_MLX_PORT="$mlx_port" CLAUDE_MLX_PROXY_PORT="$proxy_port"
state="${XDG_STATE_HOME:-$HOME/.local/state}/claude-mlx"
log="$state/watch.log"
root="${0:A:h:h}"
mkdir -p "$state"
print -r -- $$ > "$state/watch.pid"
trap 'rm -f "$state/watch.pid"' EXIT
source "$root/zsh/functions/claude/load.zsh" || exit 1

_listen_pids() {
    lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null
}

idle=0
while :; do
    sleep 15
    # Pair already stopped (claude-mlx-kill, reboot, ...): nothing to watch.
    [[ -n "$(_listen_pids "$proxy_port")" ]] || exit 0
    if [[ -n "$(lsof -nP -iTCP:"$proxy_port" -sTCP:ESTABLISHED 2>/dev/null)" ]]; then
        idle=0
    else
        (( idle += 15 ))
    fi
    (( idle < timeout_s )) && continue

    # Identity check before any kill (routing-notes kill discipline): only
    # touch a mlx_lm.server whose command line says it is one.
    pids=("${(f)$(_listen_pids "$mlx_port")}")
    if (( ${#pids} )); then
        for pid in $pids; do
            cmd="$(ps -p "$pid" -o command= 2>/dev/null)"
            if [[ "$cmd" != *mlx_lm.server* ]]; then
                print -r -- "$(date '+%F %T') port ${mlx_port} pid $pid is '${cmd}' -- not ours, leaving it alone" >> "$log"
                exit 1
            fi
        done
    fi
    if (( keep_proxy )); then
        for pid in $pids; do kill "$pid" 2>/dev/null; done
        sleep 2
        for pid in $pids; do kill -9 "$pid" 2>/dev/null; done
        print -r -- "$(date '+%F %T') idle ${timeout_s}s: stopped mlx_lm.server (port ${mlx_port}, pids ${pids[*]}), proxy kept warm" >> "$log"
    else
        print -r -- "$(date '+%F %T') idle ${timeout_s}s: stopping the claude-mlx pair" >> "$log"
        claude-mlx-kill >> "$log" 2>&1
    fi
    exit 0
done
