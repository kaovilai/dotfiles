# Check for existing clusters and prompt user before proceeding
znap function check-for-existing-clusters() {
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: check-for-existing-clusters [CLOUD_PROVIDER] [PATTERN]"
        echo "Check for existing OpenShift clusters and prompt for action"
        echo ""
        echo "Parameters:"
        echo "  CLOUD_PROVIDER  Optional: Filter by provider (aws, gcp, azure, rosa, all)"
        echo "  PATTERN         Optional: Pattern to match in cluster names"
        echo ""
        echo "Pattern examples:"
        echo "  20250417        Match clusters created on April 17, 2025"
        echo "  arm64           Match AWS/ROSA ARM64 architecture clusters"
        echo "  amd64           Match AWS/ROSA AMD64 architecture clusters"
        echo "  wif             Match GCP WIF clusters"
        echo "  sts             Match Azure/ROSA STS clusters"
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
    local debug_mode=${DEBUG_CLUSTER_CHECK:-false}
    
    # Debug function
    debug() {
        if [[ "$debug_mode" == "true" ]]; then
            echo "DEBUG: $1"
        fi
    }
    
    echo "Checking for existing clusters..."
    debug "Provider: $provider, Pattern: $pattern"
    
    # Validate OCP_MANIFESTS_DIR
    if [[ -z "$OCP_MANIFESTS_DIR" ]]; then
        echo "WARNING: OCP_MANIFESTS_DIR is not set or empty. This may cause issues with cluster detection."
        debug "OCP_MANIFESTS_DIR is not set or empty"
    else
        debug "OCP_MANIFESTS_DIR: $OCP_MANIFESTS_DIR"
        if [[ ! -d "$OCP_MANIFESTS_DIR" ]]; then
            echo "WARNING: OCP_MANIFESTS_DIR ($OCP_MANIFESTS_DIR) does not exist or is not a directory."
            debug "OCP_MANIFESTS_DIR does not exist or is not a directory"
        fi
    fi

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
                if [[ "$provider" == "azure" && ! "$cluster_name" =~ "azure" ]]; then
                    continue
                fi
                if [[ "$provider" == "rosa" && ! "$cluster_name" =~ "rosa" ]]; then
                    continue
                fi
                
                # Apply pattern filter if provided
                if [[ -z $pattern || $cluster_name == *$pattern* ]]; then
                    # Validate that both directory and name are non-empty
                    if [[ -n "$cluster_dir" && -n "$cluster_name" ]]; then
                        debug "Adding cluster: $cluster_name at $cluster_dir"
                        cluster_dirs+=("$cluster_dir")
                        cluster_names+=("$cluster_name")
                        found=true
                    else
                        echo "WARNING: Found cluster with empty directory or name, skipping: dir='$cluster_dir', name='$cluster_name'"
                    fi
                fi
            fi
        done
        
        # Check for ROSA clusters without kubeconfig files
        if [[ "$provider" == "all" || "$provider" == "rosa" ]]; then
            for dir in $(find $OCP_MANIFESTS_DIR -type d -name "*-rosa-sts-*" 2>/dev/null | sort); do
                if [[ ! -f "$dir/auth/kubeconfig" && -f "$dir/cluster-admin.txt" ]]; then
                    local cluster_name=$(basename "$dir")
                    
                    # Apply pattern filter if provided
                    if [[ -z $pattern || $cluster_name == *$pattern* ]]; then
                        debug "Adding ROSA cluster: $cluster_name at $dir"
                        cluster_dirs+=("$dir")
                        cluster_names+=("$cluster_name (ROSA)")
                        found=true
                    fi
                fi
            done
        fi
        
        # Also check for legacy clusters with empty TODAY variable
        # Check for -gcp-wif directory (empty TODAY with GCP WIF)
        if [[ "$provider" == "all" || "$provider" == "gcp" ]]; then
            local legacy_gcp_dir="$OCP_MANIFESTS_DIR/-gcp-wif"
            if [[ -d "$legacy_gcp_dir" ]]; then
                echo "Found legacy GCP WIF cluster with empty TODAY variable: $legacy_gcp_dir"
                # Validate that directory is non-empty
                if [[ -n "$legacy_gcp_dir" ]]; then
                    debug "Adding legacy GCP WIF cluster: -gcp-wif (legacy) at $legacy_gcp_dir"
                    cluster_dirs+=("$legacy_gcp_dir")
                    cluster_names+=("-gcp-wif (legacy)")
                    found=true
                else
                    echo "WARNING: Found legacy GCP WIF cluster with empty directory, skipping"
                fi
            fi
        fi
        
        # Check for -aws-arm64 and -aws-amd64 directories (empty TODAY with AWS)
        if [[ "$provider" == "all" || "$provider" == "aws" ]]; then
            local legacy_aws_arm64_dir="$OCP_MANIFESTS_DIR/-aws-arm64"
            if [[ -d "$legacy_aws_arm64_dir" ]]; then
                echo "Found legacy AWS ARM64 cluster with empty TODAY variable: $legacy_aws_arm64_dir"
                # Validate that directory is non-empty
                if [[ -n "$legacy_aws_arm64_dir" ]]; then
                    debug "Adding legacy AWS ARM64 cluster: -aws-arm64 (legacy) at $legacy_aws_arm64_dir"
                    cluster_dirs+=("$legacy_aws_arm64_dir")
                    cluster_names+=("-aws-arm64 (legacy)")
                    found=true
                else
                    echo "WARNING: Found legacy AWS ARM64 cluster with empty directory, skipping"
                fi
            fi
            
            local legacy_aws_amd64_dir="$OCP_MANIFESTS_DIR/-aws-amd64"
            if [[ -d "$legacy_aws_amd64_dir" ]]; then
                echo "Found legacy AWS AMD64 cluster with empty TODAY variable: $legacy_aws_amd64_dir"
                # Validate that directory is non-empty
                if [[ -n "$legacy_aws_amd64_dir" ]]; then
                    debug "Adding legacy AWS AMD64 cluster: -aws-amd64 (legacy) at $legacy_aws_amd64_dir"
                    cluster_dirs+=("$legacy_aws_amd64_dir")
                    cluster_names+=("-aws-amd64 (legacy)")
                    found=true
                else
                    echo "WARNING: Found legacy AWS AMD64 cluster with empty directory, skipping"
                fi
            fi
        fi
        
        # Check for -azure-sts directory (empty TODAY with Azure STS)
        if [[ "$provider" == "all" || "$provider" == "azure" ]]; then
            local legacy_azure_dir="$OCP_MANIFESTS_DIR/-azure-sts"
            if [[ -d "$legacy_azure_dir" ]]; then
                echo "Found legacy Azure STS cluster with empty TODAY variable: $legacy_azure_dir"
                # Validate that directory is non-empty
                if [[ -n "$legacy_azure_dir" ]]; then
                    debug "Adding legacy Azure STS cluster: -azure-sts (legacy) at $legacy_azure_dir"
                    cluster_dirs+=("$legacy_azure_dir")
                    cluster_names+=("-azure-sts (legacy)")
                    found=true
                else
                    echo "WARNING: Found legacy Azure STS cluster with empty directory, skipping"
                fi
            fi
        fi
    fi
    
    # Check local clusters
    if [ -d "$HOME/clusters" ]; then
        for dir in $(find $HOME/clusters -type d -name "auth" 2>/dev/null | sort); do
            if [[ -f "$dir/kubeconfig" ]]; then
                local cluster_dir=$(dirname "$dir")
                local cluster_name=$(basename "$cluster_dir")
                
                # Apply pattern filter if provided
                if [[ -z $pattern || $cluster_name == *$pattern* ]]; then
                    # Validate that both directory and name are non-empty
                    if [[ -n "$cluster_dir" && -n "$cluster_name" ]]; then
                        debug "Adding local cluster: $cluster_name at $cluster_dir"
                        cluster_dirs+=("$cluster_dir")
                        cluster_names+=("$cluster_name")
                        found=true
                    else
                        echo "WARNING: Found local cluster with empty directory or name, skipping: dir='$cluster_dir', name='$cluster_name'"
                    fi
                fi
            fi
        done
    fi
    
    # If no clusters found, proceed silently
    if [[ "$found" == "false" ]]; then
        echo "No existing clusters found. Proceeding with creation."
        return 0
    fi
    
    # Clean up arrays to remove any invalid entries
    debug "Before cleanup: ${#cluster_dirs[@]} directories, ${#cluster_names[@]} names"
    
    # Dump array contents for debugging
    if [[ "$debug_mode" == "true" ]]; then
        echo "DEBUG: Dumping array contents before cleanup:"
        for ((i=0; i<${#cluster_dirs[@]}; i++)); do
            echo "DEBUG: cluster_dirs[$i]='${cluster_dirs[$i]}', cluster_names[$i]='${cluster_names[$i]}'"
        done
    fi
    
    local valid_cluster_dirs=()
    local valid_cluster_names=()
    local valid_count=0
    
    # Only keep entries where both directory and name are non-empty
    for ((i=0; i<${#cluster_dirs[@]}; i++)); do
        if [[ -n "${cluster_dirs[$i]}" && -n "${cluster_names[$i]}" ]]; then
            # Additional validation: ensure directory exists
            if [[ -d "${cluster_dirs[$i]}" ]]; then
                valid_cluster_dirs+=("${cluster_dirs[$i]}")
                valid_cluster_names+=("${cluster_names[$i]}")
                ((valid_count++))
                debug "Valid cluster found: ${cluster_names[$i]} at ${cluster_dirs[$i]}"
            else
                debug "Directory does not exist, skipping: ${cluster_dirs[$i]}"
            fi
        else
            debug "Invalid entry at index $i: dir='${cluster_dirs[$i]}', name='${cluster_names[$i]}'"
        fi
    done
    
    # Replace original arrays with cleaned arrays
    cluster_dirs=("${valid_cluster_dirs[@]}")
    cluster_names=("${valid_cluster_names[@]}")
    
    debug "After cleanup: ${#cluster_dirs[@]} directories, ${#cluster_names[@]} names"
    
    # Dump array contents after cleanup for debugging
    if [[ "$debug_mode" == "true" ]]; then
        echo "DEBUG: Dumping array contents after cleanup:"
        for ((i=0; i<${#cluster_dirs[@]}; i++)); do
            echo "DEBUG: cluster_dirs[$i]='${cluster_dirs[$i]}', cluster_names[$i]='${cluster_names[$i]}'"
        done
    fi
    
    # If all entries were invalid, proceed silently
    if [[ ${#cluster_dirs[@]} -eq 0 || ${#cluster_names[@]} -eq 0 ]]; then
        echo "No valid clusters found after validation. Proceeding with creation."
        return 0
    fi
    
    # Show detected clusters
    echo "Found existing clusters:"
    
    for i in $(seq 1 ${#cluster_names[@]}); do
        # Additional validation to ensure array indices are valid
        if [[ -n "${cluster_names[$i-1]}" && -n "${cluster_dirs[$i-1]}" ]]; then
            echo "$i. ${cluster_names[$i-1]} ($([ -f "${cluster_dirs[$i-1]}/metadata.json" ] && jq -r '.status // "unknown"' "${cluster_dirs[$i-1]}/metadata.json" || echo "unknown")) [Install Dir: ${cluster_dirs[$i-1]}]"
        else
            echo "$i. WARNING: Invalid cluster entry at index $((i-1))"
        fi
    done
    
    # Check if force flag is set
    if [[ "$FORCE_NEW_CLUSTER" == "true" ]]; then
        echo ""
        echo "Force flag detected. Automatically proceeding with creation alongside existing clusters."
        echo "WARNING: This may cause resource conflicts or increased costs."
        # Set a global flag that we're proceeding with existing clusters
        export PROCEED_WITH_EXISTING_CLUSTERS="true"
        return 0
    fi
    
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
                # Skip empty directories
                if [[ -z "$dir" ]]; then
                    echo "WARNING: Empty directory entry found in cluster_dirs array, skipping"
                    continue
                fi
                
                local dir_name=$(basename "$dir")
                if [[ "$dir" == "$OCP_MANIFESTS_DIR/-aws-arm64" ]]; then
                    echo "Destroying legacy AWS ARM64 cluster: $dir_name"
                    if [ -d "$dir" ]; then
                        delete-ocp-aws-arm64 "cleanup-legacy"
                    else
                        echo "WARNING: Directory $dir does not exist, skipping deletion"
                    fi
                elif [[ "$dir" == "$OCP_MANIFESTS_DIR/-aws-amd64" ]]; then
                    echo "Destroying legacy AWS AMD64 cluster: $dir_name"
                    if [ -d "$dir" ]; then
                        delete-ocp-aws-amd64 "cleanup-legacy"
                    else
                        echo "WARNING: Directory $dir does not exist, skipping deletion"
                    fi
                elif [[ "$dir" == "$OCP_MANIFESTS_DIR/-gcp-wif" ]]; then
                    echo "Destroying legacy GCP-WIF cluster: $dir_name"
                    if [ -d "$dir" ]; then
                        delete-ocp-gcp-wif "cleanup-legacy"
                    else
                        echo "WARNING: Directory $dir does not exist, skipping deletion"
                    fi
                elif [[ "$dir" == "$OCP_MANIFESTS_DIR/-azure-sts" ]]; then
                    echo "Destroying legacy Azure STS cluster: $dir_name"
                    if [ -d "$dir" ]; then
                        delete-ocp-azure-sts "cleanup-legacy"
                    else
                        echo "WARNING: Directory $dir does not exist, skipping deletion"
                    fi
                elif [[ "$dir" == *"-aws-"* ]]; then
                    echo "Destroying AWS cluster: $dir_name"
                    # Ensure the directory exists before attempting to delete
                    if [ -d "$dir" ]; then
                        delete-ocp-aws-dir "$dir"
                    else
                        echo "WARNING: Directory $dir does not exist, skipping deletion"
                    fi
                elif [[ "$dir" == *"-gcp-wif"* ]]; then
                    echo "Destroying GCP-WIF cluster: $dir_name"
                    # Ensure the directory exists before attempting to delete
                    if [ -d "$dir" ]; then
                        delete-ocp-gcp-wif-dir "$dir"
                    else
                        echo "WARNING: Directory $dir does not exist, skipping deletion"
                    fi
                elif [[ "$dir" == *"-azure-sts"* ]]; then
                    echo "Destroying Azure STS cluster: $dir_name"
                    # Ensure the directory exists before attempting to delete
                    if [ -d "$dir" ]; then
                        delete-ocp-azure-sts-dir "$dir"
                    else
                        echo "WARNING: Directory $dir does not exist, skipping deletion"
                    fi
                elif [[ "$dir" == *"-rosa-sts-"* ]]; then
                    echo "Destroying ROSA STS cluster: $dir_name"
                    # Extract architecture from directory name
                    local arch_suffix=""
                    if [[ "$dir_name" == *"-arm64" ]]; then
                        arch_suffix="arm64"
                    elif [[ "$dir_name" == *"-amd64" ]]; then
                        arch_suffix="amd64"
                    fi
                    
                    if [[ -n "$arch_suffix" ]]; then
                        delete-rosa-sts "$arch_suffix"
                    else
                        echo "WARNING: Could not determine architecture for ROSA cluster, skipping deletion"
                    fi
                else
                    echo "Unknown cluster type, using generic destroy: $dir_name"
                    local EC_VERSION=${OCP_LATEST_EC_VERSION:-$(get_latest_ec_version)}
                    local OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-openshift-install-${EC_VERSION}}
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
