# Description: Podman and container build utilities

# Usage: check-qemu-stuck
# Check for stuck QEMU processes in podman builds (futex deadlocks)
check-qemu-stuck() {
    local machine_name="${1:-podman-machine-default}"

    if ! command -v podman &>/dev/null; then
        echo "❌ podman not found. Install it with: brew install podman"
        return 1
    fi

    echo "🔍 Checking for stuck QEMU processes..."
    echo

    # Check if podman machine is running
    if ! podman machine list | grep -q "Currently running"; then
        echo "❌ No podman machine is running"
        return 1
    fi

    # Get QEMU processes
    local qemu_procs=$(podman machine ssh -- 'ps -eo pid,ppid,etime,stat,wchan:30,cmd | grep "qemu-.*-static" | grep -v grep')

    if [[ -z "$qemu_procs" ]]; then
        echo "✅ No QEMU emulation processes found"
        return 0
    fi

    echo "📊 QEMU Processes:"
    while IFS= read -r line; do
        echo "  $line"
    done <<< "$qemu_procs"
    echo

    # Check for futex_wait (deadlock indicator)
    local stuck_procs=$(grep "futex_wait_queue" <<< "$qemu_procs")

    if [[ -n "$stuck_procs" ]]; then
        echo "⚠️  STUCK PROCESSES DETECTED (futex_wait_queue):"
        while IFS= read -r line; do
            local pid=$(awk '{print $1}' <<< "$line")
            local etime=$(awk '{print $3}' <<< "$line")
            local cmd=$(awk '{for(i=6;i<=NF;i++) printf $i" "; print ""}' <<< "$line")
            echo "  PID: $pid | Runtime: $etime | Cmd: $cmd"

            # Get process state details
            local state=$(podman machine ssh -- "cat /proc/$pid/status 2>/dev/null | grep -E '(State|Threads)'" 2>/dev/null)
            echo "    State: $(tr '\n' ' ' <<< "$state")"
        done <<< "$stuck_procs"
        echo
        echo "💡 Known issue: QEMU user-mode emulation futex deadlock with Go builds"
        echo "   This is an intermittent race condition (happens ~1 in 10 builds)"
        echo
        echo "🔧 Recommended actions:"
        echo "   1. Kill stuck build: kill <podman-build-pid>"
        echo "   2. Retry (90% chance of success)"
        echo "   3. Skip problematic arch: --platform linux/amd64,linux/arm64,linux/ppc64le"
        echo "   4. Try workaround: export QEMU_CPU='qemu,vx=off'"
        echo
        echo "📚 References:"
        echo "   - https://github.com/golang/go/issues/67355"
        echo "   - https://bugs.launchpad.net/qemu/+bug/1893040"
        echo "   - https://github.com/multiarch/qemu-user-static/issues/110"
        return 2
    else
        echo "✅ No stuck processes detected (all QEMU processes responsive)"
        return 0
    fi
}

# Usage: kill-stuck-qemu
# Kill stuck QEMU processes in podman machine (interactive with fzf)
kill-stuck-qemu() {
    if ! command -v podman &>/dev/null; then
        echo "❌ podman not found. Install it with: brew install podman"
        return 1
    fi

    echo "🔍 Finding stuck QEMU processes..."

    # Get detailed process info
    local stuck_procs=$(podman machine ssh -- 'ps -eo pid,ppid,etime,wchan:30,cmd | grep "futex_wait_queue" | grep "qemu-.*-static" | grep -v grep')

    if [[ -z "$stuck_procs" ]]; then
        echo "✅ No stuck QEMU processes found"
        return 0
    fi

    # Check if fzf is available
    if ! command -v fzf &> /dev/null; then
        echo "❌ fzf not found. Install it with: brew install fzf"
        return 1
    fi

    # Format processes for selection
    local formatted_procs=$(while IFS= read -r line; do
        local pid=$(awk '{print $1}' <<< "$line")
        local ppid=$(awk '{print $2}' <<< "$line")
        local etime=$(awk '{print $3}' <<< "$line")
        local cmd=$(awk '{for(i=5;i<=NF;i++) printf $i" "; print ""}' <<< "$line")

        # Extract architecture from qemu binary name
        local arch=$(grep -o 'qemu-[a-z0-9_]*-static' <<< "$cmd" | sed 's/qemu-//;s/-static//')

        # Format: arch | PID | runtime | command snippet
        printf "%-10s | PID: %-6s | %-10s | %s\n" "$arch" "$pid" "$etime" "$(cut -c1-80 <<< "$cmd")"
    done <<< "$stuck_procs")

    echo
    echo "📋 Select processes to kill (↑/↓ to navigate, TAB to select, ENTER to confirm):"
    echo

    # Use fzf for multi-select
    local selected=$(fzf --multi \
        --header="Select processes to kill (TAB to select multiple, ENTER to confirm, ESC to cancel)" \
        --header-first \
        --reverse \
        --height=80% \
        --border \
        --prompt="Select> " \
        --pointer="▶" \
        --marker="✓" \
        --color="header:italic:underline" <<< "$formatted_procs")

    if [[ -z "$selected" ]]; then
        echo "❌ No processes selected"
        return 1
    fi

    # Extract PIDs from selection
    local selected_pids=$(awk -F'PID: ' '{print $2}' <<< "$selected" | awk '{print $1}')

    echo
    echo "⚠️  Selected processes to kill:"
    echo "$selected"
    echo
    echo -n "Confirm kill? [y/N] "
    read -r confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        while read -r pid; do
            echo "  💀 Killing PID $pid..."
            podman machine ssh -- "kill -9 $pid" 2>/dev/null
        done <<< "$selected_pids"
        echo "✅ Selected processes killed"

        # Ask about parent buildah processes
        local buildah_pids=$(podman machine ssh -- 'ps -eo pid,wchan:30,cmd | grep "futex_wait_queue" | grep "buildah" | awk "{print \$1}"')
        if [[ -n "$buildah_pids" ]]; then
            echo
            echo "⚠️  Found stuck buildah parent processes: $buildah_pids"
            echo -n "Kill these too? [y/N] "
            read -r confirm_buildah
            if [[ "$confirm_buildah" =~ ^[Yy]$ ]]; then
                while read -r pid; do
                    echo "  💀 Killing buildah PID $pid..."
                    podman machine ssh -- "kill -9 $pid" 2>/dev/null
                done <<< "$buildah_pids"
                echo "✅ Buildah processes killed"
            fi
        fi
    else
        echo "❌ Cancelled"
        return 1
    fi
}

# Usage: podman-build-multiarch <dockerfile> <tag> [platforms]
# Build multi-arch image with stuck QEMU detection
podman-build-multiarch() {
    local dockerfile="${1:?Usage: podman-build-multiarch <dockerfile> <tag> [platforms]}"
    local tag="${2:?Usage: podman-build-multiarch <dockerfile> <tag> [platforms]}"
    local platforms="${3:-linux/amd64,linux/arm64,linux/ppc64le,linux/s390x}"

    echo "🏗️  Building multi-arch image:"
    echo "   Dockerfile: $dockerfile"
    echo "   Tag: $tag"
    echo "   Platforms: $platforms"
    echo

    # Check for existing stuck processes before starting
    check-qemu-stuck
    local _stuck_exit=$?
    if [[ $_stuck_exit -eq 2 ]]; then
        echo "⚠️  Found stuck processes. Clean up first with kill-stuck-qemu"
        return 1
    elif [[ $_stuck_exit -eq 1 ]]; then
        echo "⚠️  Pre-build check failed (podman not installed or machine not running)"
        return 1
    fi

    # Start build
    podman build -f "$dockerfile" . --platform "$platforms" -t "$tag"
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo
        echo "❌ Build failed. Checking for stuck QEMU processes..."
        check-qemu-stuck
    fi

    return $exit_code
}
