znap function select-rosa-cluster() {
    # Interactively select and connect to a ROSA cluster
    # Uses fzf if available, otherwise provides numbered menu

    echo "Checking for available ROSA clusters..."

    # Get list of ROSA clusters
    local clusters=$(rosa list clusters --output json 2>/dev/null | jq -r '.[] | .name' 2>/dev/null)

    if [[ -z "$clusters" ]]; then
        echo "No ROSA clusters found in AWS"

        # Check for local directories
        echo ""
        echo "Local ROSA cluster directories found (may be stale):"
        local found_local=false
        # Use nullglob to handle the case when no matches are found
        setopt local_options nullglob
        for dir in $OCP_MANIFESTS_DIR/*-rosa-sts-*/; do
            if [[ -d "$dir" ]]; then
                found_local=true
                local dir_name=$(basename "$dir")
                echo "  - $dir_name"
            fi
        done

        if [[ "$found_local" == "false" ]]; then
            echo "  No local ROSA directories found"
        else
            echo ""
            echo "These directories appear to be from deleted clusters."
            echo "Consider cleaning them up with: rm -rf $OCP_MANIFESTS_DIR/*-rosa-sts-*/"
        fi

        return 1
    fi

    # Count clusters
    local cluster_count=$(echo "$clusters" | wc -l | tr -d ' ')

    if [[ $cluster_count -eq 1 ]]; then
        # Only one cluster, connect to it automatically
        local cluster_name=$(echo "$clusters" | head -n 1)
        echo "Found one ROSA cluster: $cluster_name"
        echo "Connecting..."
        use-rosa-sts "$cluster_name"
        return $?
    fi

    # Multiple clusters, let user select
    local selected=""

    # Check if fzf is available
    if command -v fzf &>/dev/null; then
        echo "Select a ROSA cluster:"
        selected=$(echo "$clusters" | fzf --prompt="ROSA Cluster> " --height=10 --layout=reverse)

        if [[ -z "$selected" ]]; then
            echo "No cluster selected"
            return 1
        fi
    else
        # Use numbered menu
        echo "Available ROSA clusters:"
        local i=1
        local cluster_array=()

        while IFS= read -r cluster; do
            echo "  $i) $cluster"
            cluster_array+=("$cluster")
            ((i++))
        done <<< "$clusters"

        echo ""
        read "?Select cluster number (1-$cluster_count): " choice

        if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt $cluster_count ]]; then
            echo "Invalid selection"
            return 1
        fi

        selected="${cluster_array[$choice]}"
    fi

    echo "Connecting to $selected..."
    use-rosa-sts "$selected"
}

# Alias for convenience
alias rosa-select='select-rosa-cluster'