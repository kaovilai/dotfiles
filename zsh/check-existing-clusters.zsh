# Check for existing clusters and prompt user before proceeding
znap function check-for-existing-clusters() {
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: check-for-existing-clusters [CLOUD_PROVIDER] [PATTERN]"
        echo "Check for existing OpenShift clusters and prompt for action"
        echo ""
        echo "Parameters:"
        echo "  CLOUD_PROVIDER  Optional: Filter by provider (aws, gcp, all)"
        echo "  PATTERN         Optional: Pattern to match in cluster names"
        echo ""
        echo "Pattern examples:"
        echo "  20250417        Match clusters created on April 17, 2025"
        echo "  arm64           Match AWS ARM64 architecture clusters"
        echo "  amd64           Match AWS AMD64 architecture clusters"
        echo "  wif             Match GCP WIF clusters"
        echo "  -1              Match clusters with suffix -1 (created alongside others)"
        echo ""
        echo "Returns:"
        echo "  0 - User chose to proceed (no clusters found or user approved)"
        echo "  1 - User chose to cancel operation"
        return 0
    fi

    local provider=${1:-"all"}
    local pattern=${2:-""}
    local cluster_dirs=()
    local cluster_names=()
    local found=false
    
    echo "Checking for existing clusters..."

    # Find AWS and GCP cluster directories
    if [ -d "$OCP_MANIFESTS_DIR" ]; then
        for dir in $(find $OCP_MANIFESTS_DIR -type d -name "auth" 2>/dev/null | sort); do
            if [[ -f "$dir/kubeconfig" ]]; then
                local cluster_dir=$(dirname "$dir")
                local cluster_name=$(basename "$cluster_dir")
                
                # Filter by provider if specified
                if [[ "$provider" == "aws" && ! "$cluster_name" =~ "aws" ]]; then
                    continue
                fi
                if [[ "$provider" == "gcp" && ! "$cluster_name" =~ "gcp" ]]; then
                    continue
                fi
                
                # Apply pattern filter if provided
                if [[ -z $pattern || $cluster_name == *$pattern* ]]; then
                    cluster_dirs+=("$cluster_dir")
                    cluster_names+=("$cluster_name")
                    found=true
                fi
            fi
        done
    fi
    
    # Check local clusters
    if [ -d "$HOME/clusters" ]; then
        for dir in $(find $HOME/clusters -type d -name "auth" 2>/dev/null | sort); do
            if [[ -f "$dir/kubeconfig" ]]; then
                local cluster_dir=$(dirname "$dir")
                local cluster_name=$(basename "$cluster_dir")
                
                # Apply pattern filter if provided
                if [[ -z $pattern || $cluster_name == *$pattern* ]]; then
                    cluster_dirs+=("$cluster_dir")
                    cluster_names+=("$cluster_name")
                    found=true
                fi
            fi
        done
    fi
    
    # If no clusters found, proceed silently
    if [[ "$found" == "false" ]]; then
        echo "No existing clusters found. Proceeding with creation."
        return 0
    fi
    
    # Show detected clusters
    echo "Found existing clusters:"
    for i in $(seq 1 ${#cluster_names[@]}); do
        echo "$i. ${cluster_names[$i-1]} ($([ -f "${cluster_dirs[$i-1]}/metadata.json" ] && jq -r '.status // "unknown"' "${cluster_dirs[$i-1]}/metadata.json" || echo "unknown"))"
    done
    
    # Prompt for action
    echo ""
    echo "Options:"
    echo "1. Destroy existing cluster(s) and create new one"
    echo "2. Cancel operation"
    echo "3. Force continue (create alongside existing clusters)"
    echo ""
    read "choice?Enter choice (1-3): "
    
    case "$choice" in
        1)
            echo "Destroying existing cluster(s)..."
            for dir in "${cluster_dirs[@]}"; do
                local dir_name=$(basename "$dir")
                if [[ "$dir" == *"-aws-"* ]]; then
                    echo "Destroying AWS cluster: $dir_name"
                    delete-ocp-aws-dir "$dir"
                elif [[ "$dir" == *"-gcp-wif"* ]]; then
                    echo "Destroying GCP-WIF cluster: $dir_name"
                    delete-ocp-gcp-wif-dir "$dir"
                else
                    echo "Unknown cluster type, using generic destroy: $dir_name"
                    local OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-openshift-install-4.19.0-ec.4}
                    $OPENSHIFT_INSTALL destroy cluster --dir "$dir" || echo "Failed to destroy cluster: $dir_name"
                fi
            done
            return 0
            ;;
        2)
            echo "Operation cancelled."
            return 1
            ;;
        3)
            echo "Proceeding with creation alongside existing clusters."
            echo "WARNING: This may cause resource conflicts or increased costs."
            # Set a global flag that we're proceeding with existing clusters
            export PROCEED_WITH_EXISTING_CLUSTERS="true"
            return 0
            ;;
        *)
            echo "Invalid choice. Operation cancelled."
            return 1
            ;;
    esac
}
