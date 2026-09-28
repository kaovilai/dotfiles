# Hermes Agent (desktop/CLI) session management functions

# List running Hermes bot-chat delivery processes (the `hermes -p <profile> chat ...`
# child processes spawned by message_agent deliveries / desktop sessions), and let you
# pick one to kill interactively. This is the fix for the "This chat is open in another
# Hermes window/terminal" stale-lease lock: the offending process is almost always one
# of these still-running `hermes chat` invocations holding the profile's turn lock.
#
# Uses pgrep (one PID per line) rather than parsing `ps aux` output directly: several
# Hermes child processes embed literal newlines in their own command line (multi-line
# `python -c` launchers), which silently splits a single process across multiple lines
# under naive `ps aux | while read` / `${(@f)}` parsing. pgrep sidesteps this entirely.
_hermes_session_list() {
    pgrep -f 'hermes.*chat|hermes_cli\.main|\.hermes/(hermes-agent|installs)' 2>/dev/null
}

_hermes_session_summary() {
    local pid=$1
    # -o args= gives the full command; flatten any embedded newlines before display
    local args
    args=$(ps -p "$pid" -o args= 2>/dev/null | tr '\n' ' ')
    local start
    start=$(ps -p "$pid" -o lstart= 2>/dev/null)
    local short
    short=$(echo "$args" | grep -oE "\-p [a-zA-Z0-9_-]+ chat.*|profile-home [^ ]+" | head -c 100)
    [[ -z "$short" ]] && short=$(echo "$args" | head -c 100)
    echo "${start} | ${short}"
}

kill-hermes-session() {
    local -a pids
    pids=("${(@f)$(_hermes_session_list)}")

    if [[ ${#pids[@]} -eq 0 || -z "${pids[1]}" ]]; then
        echo "No running Hermes chat/session processes found."
        return 0
    fi

    echo "Running Hermes processes:"
    echo
    local i=1
    local pid
    for pid in "${pids[@]}"; do
        printf "  [%d] pid=%-8s %s\n" "$i" "$pid" "$(_hermes_session_summary "$pid")"
        ((i++))
    done
    echo
    echo "  [a] kill ALL listed"
    echo "  [q] quit without killing anything"
    echo

    local choice
    read -r "choice?Select a process to kill (number, 'a' for all, 'q' to quit): "

    if [[ "$choice" == "q" ]]; then
        echo "No action taken."
        return 0
    fi

    local -a targets
    if [[ "$choice" == "a" ]]; then
        targets=("${pids[@]}")
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#pids[@]} )); then
        targets=("${pids[$choice]}")
    else
        echo "Invalid selection." >&2
        return 1
    fi

    local target
    for target in "${targets[@]}"; do
        if kill "$target" 2>/dev/null; then
            echo "✓ Sent SIGTERM to pid $target"
        else
            echo "✗ Failed to signal pid $target (already gone, or needs sudo?)" >&2
        fi
    done

    echo
    echo "If a process doesn't die within a few seconds, rerun with kill-hermes-session-9"
    echo "for SIGKILL, or call kill-hermes-session again to see if it's still listed."
}

# Clear a stale "This chat is open in another Hermes window/terminal" lease
# directly from active_sessions.json, without hunting for/killing a PID.
# Searches the root registry AND every profile's registry (each profile has
# its own runtime/active_sessions.json). Pass a session id substring (as
# shown in the refusal's "Details: session <id> ..." line); with no arg,
# lists all current leases across root + profiles so you can pick one.
unlock-hermes-session() {
    local target="$1"
    local -a registries
    registries=(~/.hermes/runtime/active_sessions.json ~/.hermes/profiles/*/runtime/active_sessions.json(N))

    if [[ -z "$target" ]]; then
        echo "Current Hermes session leases:"
        echo
        local reg
        for reg in "${registries[@]}"; do
            [[ -f "$reg" ]] || continue
            python3 -c "
import json, sys, time
path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception as e:
    sys.exit(0)
for e in data.get('entries', []):
    age = int(time.time() - e.get('started_at', time.time()))
    print(f\"  {path}\")
    print(f\"    session_id={e.get('session_id')} pid={e.get('pid')} surface={e.get('surface')} age={age}s\")
" "$reg"
        done
        echo
        echo "Run 'unlock-hermes-session <session_id_substring>' to clear one."
        return 0
    fi

    local found=0
    local reg
    for reg in "${registries[@]}"; do
        [[ -f "$reg" ]] || continue
        local result
        result=$(python3 -c "
import json, sys
path, target = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception:
    sys.exit(0)
entries = data.get('entries', [])
kept = [e for e in entries if target not in str(e.get('session_id', ''))]
if len(kept) != len(entries):
    data['entries'] = kept
    json.dump(data, open(path, 'w'))
    print('cleared')
" "$reg" "$target")
        if [[ "$result" == "cleared" ]]; then
            echo "✓ Cleared lease matching '$target' in $reg"
            found=1
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo "No lease matching '$target' found in any registry." >&2
        return 1
    fi
    echo "Note: if a real process still holds that session, it may re-claim the lease."
    echo "Use kill-hermes-session to also stop the underlying process if needed."
}

# Desktop ships as a compiled app.asar bundle (built by `npm run dist` under
# apps/desktop) — it is NOT the live source tree, so quitting/relaunching alone
# only re-reads whatever asar was last built. Returns 0 (stale, needs rebuild)
# or 1 (asar is newer than every tracked source/dep file) via return code.
_hermes_desktop_asar_is_stale() {
    local repo=~/.hermes/hermes-agent
    local asar="$repo/apps/desktop/release/mac-arm64/Hermes.app/Contents/Resources/app.asar"
    [[ -f "$asar" ]] || return 0   # never built — treat as stale

    local asar_mtime
    asar_mtime=$(stat -f %m "$asar" 2>/dev/null) || return 0

    # Newest mtime among tracked+dirty files under apps/desktop and apps/shared
    # (git ls-files -m/-o catches uncommitted edits too, not just commits).
    local newest
    newest=$(cd "$repo" && { git ls-files -z apps/desktop apps/shared; git ls-files -z -m -o --exclude-standard apps/desktop apps/shared; } \
        | xargs -0 stat -f '%m' 2>/dev/null | sort -rn | head -1)

    [[ -z "$newest" ]] && return 1   # couldn't determine — don't force a rebuild
    (( newest > asar_mtime ))
}

# Rebuild the Hermes Desktop app.asar (TS compile + electron-builder repackage)
# ONLY if source is newer than the last build. Safe to call unconditionally —
# no-ops when nothing changed. Pass -f to force a rebuild regardless.
rebuild-hermes-desktop-if-stale() {
    local force=0
    [[ "$1" == "-f" ]] && force=1

    if [[ $force -eq 0 ]] && ! _hermes_desktop_asar_is_stale; then
        echo "Desktop app.asar is up to date with apps/desktop + apps/shared — skipping rebuild."
        return 0
    fi

    echo "Desktop source is newer than the built app.asar — rebuilding (npm run dist)..."
    echo "This runs a TS compile + electron-builder repackage; can take a few minutes."
    (cd ~/.hermes/hermes-agent/apps/desktop && npm run dist)
    local status=$?
    if [[ $status -eq 0 ]]; then
        echo "✓ Desktop rebuild complete."
    else
        echo "✗ Desktop rebuild FAILED (exit $status) — desktop app still on the OLD build." >&2
    fi
    return $status
}

# Restart everything Hermes-related after a fork/code update so all surfaces
# pick up the new code. Two independent backends exist by design (see
# hermes-fork-inherit-pr skill): the launchd-managed gateway service (Telegram,
# cron, kanban — keeps running regardless of any UI, runs off the source tree
# directly so no rebuild needed) and the desktop app's own local `serve`
# backend, which is bundled into a compiled app.asar and DOES need a rebuild
# before a relaunch does anything. Neither restart implies the other, so both
# are needed, plus any live CLI sessions (which keep running whatever module
# versions they imported at launch and won't pick up new code just by existing).
restart-hermes-full() {
    echo "== Restarting launchd-managed Hermes gateway (ai.hermes.gateway) =="
    if launchctl kickstart -k "gui/$(id -u)/ai.hermes.gateway" 2>&1; then
        echo "✓ Gateway kickstarted"
    else
        echo "✗ launchctl kickstart failed — is the LaunchAgent loaded? Check:" >&2
        echo "    launchctl print gui/$(id -u)/ai.hermes.gateway" >&2
    fi
    echo
    echo "== Desktop app =="
    if ! rebuild-hermes-desktop-if-stale; then
        echo "Skipping desktop restart — fix the build failure above first." >&2
    else
        if pgrep -f "Hermes.app/Contents/MacOS/Hermes" >/dev/null 2>&1; then
            echo "Desktop app is running — quitting it now (Cmd+Q equivalent)."
            osascript -e 'tell application "Hermes" to quit' 2>/dev/null
            sleep 2
            echo "Relaunching..."
            open -a Hermes
            echo "✓ Desktop app relaunched (its own local backend respawns fresh on open)"
        else
            echo "Desktop app is not currently running — nothing to quit."
        fi
    fi
    echo
    echo "== Live CLI sessions =="
    local -a pids
    pids=("${(@f)$(_hermes_session_list)}")
    if [[ ${#pids[@]} -gt 0 && -n "${pids[1]}" ]]; then
        echo "Found $(echo ${#pids[@]}) live Hermes CLI-ish process(es) still holding OLD code:"
        local pid
        for pid in "${pids[@]}"; do
            printf "  pid=%-8s %s\n" "$pid" "$(_hermes_session_summary "$pid")"
        done
        echo "These won't pick up the update on their own — exit/relaunch them manually"
        echo "('/exit' then 'hermes' again), or run kill-hermes-session to end them."
    else
        echo "No live CLI sessions found."
    fi
    echo
    echo "Done. Verify gateway came back clean: tail -30 ~/.hermes/logs/gateway.log"
}

# Force-kill variant (SIGKILL immediately, for genuinely wedged processes)
kill-hermes-session-9() {
    local -a pids
    pids=("${(@f)$(_hermes_session_list)}")

    if [[ ${#pids[@]} -eq 0 || -z "${pids[1]}" ]]; then
        echo "No running Hermes chat/session processes found."
        return 0
    fi

    echo "Running Hermes processes:"
    echo
    local i=1
    local pid
    for pid in "${pids[@]}"; do
        printf "  [%d] pid=%-8s %s\n" "$i" "$pid" "$(_hermes_session_summary "$pid")"
        ((i++))
    done
    echo
    echo "  [a] force-kill ALL listed"
    echo "  [q] quit without killing anything"
    echo

    local choice
    read -r "choice?Select a process to FORCE-kill (number, 'a' for all, 'q' to quit): "

    if [[ "$choice" == "q" ]]; then
        echo "No action taken."
        return 0
    fi

    local -a targets
    if [[ "$choice" == "a" ]]; then
        targets=("${pids[@]}")
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#pids[@]} )); then
        targets=("${pids[$choice]}")
    else
        echo "Invalid selection." >&2
        return 1
    fi

    local target
    for target in "${targets[@]}"; do
        if kill -9 "$target" 2>/dev/null; then
            echo "✓ Sent SIGKILL to pid $target"
        else
            echo "✗ Failed to signal pid $target (already gone, or needs sudo?)" >&2
        fi
    done
}
