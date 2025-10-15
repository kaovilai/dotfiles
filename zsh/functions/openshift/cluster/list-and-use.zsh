# OpenShift Cluster Listing and Selection Functions
#
# Functions for discovering and switching between installed OpenShift clusters
#
# Functions provided:
#   - list-ocp-clusters: List all installed OpenShift clusters across all providers
#   - use-ocp-cluster: Interactively select and set KUBECONFIG to a cluster
#   - copyKUBECONFIG: Copy current KUBECONFIG to ~/.kube/config

# List all installed OpenShift clusters
# Usage: list-ocp-clusters [--full]
#        list-ocp-clusters help
# Description: Scans directories for OpenShift cluster installations and lists them
#              by cloud provider (AWS, GCP, Azure, ROSA, Local, CRC)
# Parameters:
#   --full - Show full paths to auth directory and kubeconfig
#   help   - Display detailed help message
# Searches:
#   - $OCP_MANIFESTS_DIR for cloud provider clusters
#   - ~/clusters for local installations
#   - ~/.crc/machines/crc for CodeReady Containers
# Example:
#   list-ocp-clusters
#   list-ocp-clusters --full
znap function list-ocp-clusters() {
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: list-ocp-clusters [OPTIONS]"
        echo "List all installed OpenShift clusters"
        echo ""
        echo "Options:"
        echo "  help     Display this help message"
        echo "  --full   Show full path to auth directory and kubeconfig"
        echo ""
        echo "This function searches for OpenShift clusters in the following locations:"
        echo "  - $OCP_MANIFESTS_DIR (AWS and GCP installations)"
        echo "  - ~/clusters (using installClusterOpenshiftInstall function)"
        echo "  - ~/.crc/machines/crc (CodeReady Containers)"
        echo ""
        return 0
    fi

    local show_full=false
    if [[ "$1" == "--full" ]]; then
        show_full=true
    fi
    
    echo "=== OpenShift Clusters ==="
    echo ""
    
    # Check AWS, GCP, Azure, and ROSA cluster directories
    if [ -d "$OCP_MANIFESTS_DIR" ]; then
        echo "Cloud Provider Clusters:"
        local count=0
        
        # Find all directories with auth/kubeconfig files
        for dir in $(find $OCP_MANIFESTS_DIR -type d -name "auth" 2>/dev/null | sort); do
            if [[ -f "$dir/kubeconfig" ]]; then
                local cluster_dir=$(dirname "$dir")
                local cluster_name=$(basename "$cluster_dir")
                
                # Determine cluster type
                local cluster_type=""
                if [[ "$cluster_name" == *"-aws-"* ]]; then
                    cluster_type="AWS"
                elif [[ "$cluster_name" == *"-gcp-"* ]]; then
                    cluster_type="GCP"
                elif [[ "$cluster_name" == *"-azure-"* ]]; then
                    cluster_type="Azure"
                elif [[ "$cluster_name" == *"-rosa-"* ]]; then
                    cluster_type="ROSA"
                else
                    cluster_type="Unknown"
                fi
                
                count=$((count+1))
                
                if [ "$show_full" = true ]; then
                    echo "$count. $cluster_name ($cluster_type): $dir/kubeconfig"
                else
                    echo "$count. $cluster_name ($cluster_type)"
                fi
            fi
        done
        
        # Check for ROSA clusters that might not have kubeconfig files yet
        for dir in $(find $OCP_MANIFESTS_DIR -type d -name "*-rosa-sts-*" 2>/dev/null | sort); do
            if [[ ! -f "$dir/auth/kubeconfig" && -f "$dir/cluster-admin.txt" ]]; then
                local cluster_name=$(basename "$dir")
                count=$((count+1))
                
                if [ "$show_full" = true ]; then
                    echo "$count. $cluster_name (ROSA): $dir/cluster-admin.txt [No kubeconfig - use use-rosa-sts to connect]"
                else
                    echo "$count. $cluster_name (ROSA) [No kubeconfig - use use-rosa-sts to connect]"
                fi
            fi
        done
        
        if [ $count -eq 0 ]; then
            echo "   No cloud provider clusters found"
        fi
        echo ""
    fi
    
    # Check local clusters directory
    if [ -d "$HOME/clusters" ]; then
        echo "Local Clusters:"
        local count=0
        
        # Find all directories with auth/kubeconfig files
        for dir in $(find $HOME/clusters -type d -name "auth" 2>/dev/null | sort); do
            if [[ -f "$dir/kubeconfig" ]]; then
                local cluster_dir=$(dirname "$dir")
                local cluster_name=$(basename "$cluster_dir")
                count=$((count+1))
                
                if [ "$show_full" = true ]; then
                    echo "$count. $cluster_name: $dir/kubeconfig"
                else
                    echo "$count. $cluster_name"
                fi
            fi
        done
        
        if [ $count -eq 0 ]; then
            echo "   No local clusters found"
        fi
        echo ""
    fi
    
    # Check CRC
    if [ -f "$HOME/.crc/machines/crc/kubeconfig" ]; then
        echo "CodeReady Containers:"
        if [ "$show_full" = true ]; then
            echo "1. crc: $HOME/.crc/machines/crc/kubeconfig"
        else
            echo "1. crc"
        fi
        echo ""
    else
        echo "CodeReady Containers: Not installed"
        echo ""
    fi
}

# Set KUBECONFIG to a cluster
# Usage: use-ocp-cluster [PATTERN]
#        use-ocp-cluster help
# Description: Interactively select an OpenShift cluster and set KUBECONFIG
#              If only one cluster found, uses it directly without prompting
#              For ROSA clusters without kubeconfig, shows instructions for use-rosa-sts
# Parameters:
#   PATTERN - Optional search pattern to filter clusters (substring match)
#   help    - Display detailed help message
# Environment:
#   KUBECONFIG - Will be exported with the selected cluster's kubeconfig path
# Example:
#   use-ocp-cluster                    # Show all clusters
#   use-ocp-cluster azure              # Show only Azure clusters
#   use-ocp-cluster 20250114           # Show clusters from specific date
# Note:
#   After setting KUBECONFIG, offers to copy to ~/.kube/config for persistence
znap function use-ocp-cluster() {
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: use-ocp-cluster [PATTERN]"
        echo "Set KUBECONFIG to a selected cluster"
        echo ""
        echo "Parameters:"
        echo "  PATTERN  Optional search pattern to filter clusters"
        echo "           If omitted, will show all available clusters"
        echo ""
        echo "This function searches for OpenShift clusters and prompts you to select one,"
        echo "then sets the KUBECONFIG environment variable to the selected cluster's kubeconfig."
        echo ""
        return 0
    fi

    local search_pattern=$1
    local kubeconfig_files=()
    local cluster_names=()
    
    # Find all cloud provider clusters
    if [ -d "$OCP_MANIFESTS_DIR" ]; then
        for dir in $(find $OCP_MANIFESTS_DIR -type d -name "auth" 2>/dev/null | sort); do
            if [[ -f "$dir/kubeconfig" ]]; then
                local cluster_dir=$(dirname "$dir")
                local cluster_name=$(basename "$cluster_dir")
                
                # Determine cluster type
                local cluster_type=""
                if [[ "$cluster_name" == *"-aws-"* ]]; then
                    cluster_type="AWS"
                elif [[ "$cluster_name" == *"-gcp-"* ]]; then
                    cluster_type="GCP"
                elif [[ "$cluster_name" == *"-azure-"* ]]; then
                    cluster_type="Azure"
                elif [[ "$cluster_name" == *"-rosa-"* ]]; then
                    cluster_type="ROSA"
                else
                    cluster_type="Unknown"
                fi
                
                # Apply pattern filter if provided
                if [[ -z $search_pattern || $cluster_name == *$search_pattern* ]]; then
                    kubeconfig_files+=("$dir/kubeconfig")
                    cluster_names+=("$cluster_name ($cluster_type)")
                fi
            fi
        done
        
        # Check for ROSA clusters that might not have kubeconfig files yet
        for dir in $(find $OCP_MANIFESTS_DIR -type d -name "*-rosa-sts-*" 2>/dev/null | sort); do
            if [[ ! -f "$dir/auth/kubeconfig" && -f "$dir/cluster-admin.txt" ]]; then
                local cluster_name=$(basename "$dir")
                
                # Apply pattern filter if provided
                if [[ -z $search_pattern || $cluster_name == *$search_pattern* ]]; then
                    # For ROSA clusters without kubeconfig, we'll add a special marker
                    kubeconfig_files+=("ROSA:$dir")
                    cluster_names+=("$cluster_name (ROSA - requires use-rosa-sts)")
                fi
            fi
        done
    fi
    
    # Find all local clusters
    if [ -d "$HOME/clusters" ]; then
        for dir in $(find $HOME/clusters -type d -name "auth" 2>/dev/null | sort); do
            if [[ -f "$dir/kubeconfig" ]]; then
                local cluster_dir=$(dirname "$dir")
                local cluster_name=$(basename "$cluster_dir")
                
                # Apply pattern filter if provided
                if [[ -z $search_pattern || $cluster_name == *$search_pattern* ]]; then
                    kubeconfig_files+=("$dir/kubeconfig")
                    cluster_names+=("$cluster_name (Local)")
                fi
            fi
        done
    fi
    
    # Check CRC
    if [[ -f "$HOME/.crc/machines/crc/kubeconfig" ]]; then
        if [[ -z $search_pattern || "crc" == *$search_pattern* ]]; then
            kubeconfig_files+=("$HOME/.crc/machines/crc/kubeconfig")
            cluster_names+=("crc (CodeReady Containers)")
        fi
    fi
    
    # If no clusters found
    if [[ ${#kubeconfig_files[@]} -eq 0 ]]; then
        echo "No OpenShift clusters found"
        if [[ -n $search_pattern ]]; then
            echo "Try without a search pattern or check if your clusters exist"
        fi
        return 1
    fi
    
    # If only one cluster found, use it directly
    if [[ ${#kubeconfig_files[@]} -eq 1 ]]; then
        export KUBECONFIG="${kubeconfig_files[0]}"
        echo "Using cluster: ${cluster_names[0]}"
        echo "KUBECONFIG set to: $KUBECONFIG"
        return 0
    fi
    
    # Show selection menu
    echo "Available clusters:"
    for i in $(seq 1 ${#kubeconfig_files[@]}); do
        echo "$i. ${cluster_names[$i-1]}"
    done
    
    # Prompt for selection
    echo ""
    read "choice?Enter cluster number (1-${#kubeconfig_files[@]}): "
    
    # Validate choice
    if [[ ! $choice =~ ^[0-9]+$ || $choice -lt 1 || $choice -gt ${#kubeconfig_files[@]} ]]; then
        echo "Invalid selection"
        return 1
    fi
    
    # Handle special ROSA clusters
    local selected_path="${kubeconfig_files[$choice-1]}"
    if [[ "$selected_path" == ROSA:* ]]; then
        echo ""
        echo "This is a ROSA cluster without a kubeconfig file."
        echo "You need to use the use-rosa-sts function to connect."
        echo ""
        local rosa_dir="${selected_path#ROSA:}"
        local rosa_cluster_name=$(basename "$rosa_dir")
        
        # Extract architecture from directory name
        if [[ "$rosa_cluster_name" == *"-arm64" ]]; then
            echo "To connect, run: use-rosa-sts-arm64"
        elif [[ "$rosa_cluster_name" == *"-amd64" ]]; then
            echo "To connect, run: use-rosa-sts-amd64"
        else
            echo "To connect, run: use-rosa-sts"
        fi
        return 0
    fi
    
    # Set KUBECONFIG
    export KUBECONFIG="$selected_path"
    echo "Using cluster: ${cluster_names[$choice-1]}"
    echo "KUBECONFIG set to: $KUBECONFIG"
    
    # Offer to copy to ~/.kube/config as well
    echo ""
    read "copy?Copy to ~/.kube/config? (y/n): "
    if [[ $copy == "y" || $copy == "Y" ]]; then
        mkdir -p ~/.kube
        cp "$KUBECONFIG" ~/.kube/config
        echo "Copied to ~/.kube/config"
    fi
}

# Copy KUBECONFIG to ~/.kube/config
# Usage: copyKUBECONFIG
# Description: Copies the current KUBECONFIG file to ~/.kube/config
#              Validates KUBECONFIG is set and file exists before copying
# Environment:
#   KUBECONFIG - Must be set to a valid kubeconfig file path
# Returns: 1 if KUBECONFIG not set or file doesn't exist, 0 on success
# Example:
#   export KUBECONFIG=/path/to/cluster/auth/kubeconfig
#   copyKUBECONFIG
znap function copyKUBECONFIG() {
    [ -f $KUBECONFIG ] || {
        echo "KUBECONFIG not set"
        return 1
    }
    [ -f $KUBECONFIG ] && {
        echo "KUBECONFIG set to $KUBECONFIG"
        echo "Copying to ~/.kube/config"
        cp $KUBECONFIG ~/.kube/config
    }
}
