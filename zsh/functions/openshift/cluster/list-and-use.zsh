# List all installed OpenShift clusters
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
    
    # Check AWS and GCP cluster directories
    if [ -d "$OCP_MANIFESTS_DIR" ]; then
        echo "AWS/GCP Clusters:"
        local count=0
        
        # Find all directories with auth/kubeconfig files
        for dir in $(find $OCP_MANIFESTS_DIR -type d -name "auth" 2>/dev/null | sort); do
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
            echo "   No AWS/GCP clusters found"
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
    
    # Find all AWS/GCP clusters
    if [ -d "$OCP_MANIFESTS_DIR" ]; then
        for dir in $(find $OCP_MANIFESTS_DIR -type d -name "auth" 2>/dev/null | sort); do
            if [[ -f "$dir/kubeconfig" ]]; then
                local cluster_dir=$(dirname "$dir")
                local cluster_name=$(basename "$cluster_dir")
                
                # Apply pattern filter if provided
                if [[ -z $search_pattern || $cluster_name == *$search_pattern* ]]; then
                    kubeconfig_files+=("$dir/kubeconfig")
                    cluster_names+=("$cluster_name (AWS/GCP)")
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
    
    # Set KUBECONFIG
    export KUBECONFIG="${kubeconfig_files[$choice-1]}"
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

# cp KUBECONFIG to ~/.kube/config
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
