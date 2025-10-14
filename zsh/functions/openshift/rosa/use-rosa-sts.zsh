znap function use-rosa-sts() {
    # Configure kubectl to use a ROSA STS cluster
    # Parameters:
    #   $1 - Can be:
    #        - Empty (lists clusters and uses most recent)
    #        - Architecture suffix (arm64 or amd64) - creates name with today's date
    #        - Date in YYYYMMDD format (e.g., 20250710)
    #        - Full cluster name (e.g., rosa-20250710-amd64)
    #   $2 - Architecture suffix if $1 is a date (defaults to amd64)

    local input=${1:-}
    local ARCH_SUFFIX="amd64"
    local DATE_PREFIX=""
    local CLUSTER_NAME=""

    # Parse input parameters
    if [[ -z "$input" ]]; then
        # No input, list clusters and use the most recent one
        echo "Checking for available ROSA clusters..."

        # Get list of ROSA clusters sorted by name (which includes date)
        local clusters=$(rosa list clusters --output json 2>/dev/null | jq -r '.[] | .name' 2>/dev/null | sort -r)

        if [[ -z "$clusters" ]]; then
            echo "No ROSA clusters found in AWS"

            # Check for any local ROSA directories
            echo ""
            echo "Local ROSA cluster directories found:"
            local found_local=false
            setopt local_options nullglob
            for dir in $OCP_MANIFESTS_DIR/*-rosa-sts-*/; do
                if [[ -d "$dir" ]]; then
                    found_local=true
                    local dir_name=$(basename "$dir")
                    echo "  - $dir_name (may be stale)"
                fi
            done

            if [[ "$found_local" == "false" ]]; then
                echo "  No local ROSA directories found"
            fi
            return 1
        fi

        # Get the most recent cluster (first in reverse sorted list)
        CLUSTER_NAME=$(echo "$clusters" | head -n 1)

        # Count clusters
        local cluster_count=$(echo "$clusters" | wc -l | tr -d ' ')

        if [[ $cluster_count -gt 1 ]]; then
            echo "Found $cluster_count ROSA clusters. Using most recent: $CLUSTER_NAME"
            echo "Other available clusters:"
            echo "$clusters" | tail -n +2 | while read -r cluster; do
                echo "  - $cluster"
            done
            echo ""
            echo "To use a different cluster, specify: use-rosa-sts <cluster-name>"
        else
            echo "Found ROSA cluster: $CLUSTER_NAME"
        fi

        # Extract date and arch from cluster name
        if [[ "$CLUSTER_NAME" =~ ^rosa-([0-9]{8})-(.*)$ ]]; then
            DATE_PREFIX=${match[1]}
            ARCH_SUFFIX=${match[2]}
        else
            echo "WARNING: Could not parse cluster name format: $CLUSTER_NAME"
            DATE_PREFIX=$(date +%Y%m%d)
        fi
    elif [[ "$input" == "arm64" || "$input" == "amd64" ]]; then
        # Input is architecture
        ARCH_SUFFIX=$input
        DATE_PREFIX=${TODAY:-$(date +%Y%m%d)}
        CLUSTER_NAME="rosa-$DATE_PREFIX-$ARCH_SUFFIX"
    elif [[ "$input" =~ ^[0-9]{8}$ ]]; then
        # Input is date in YYYYMMDD format
        DATE_PREFIX=$input
        ARCH_SUFFIX=${2:-amd64}
        CLUSTER_NAME="rosa-$DATE_PREFIX-$ARCH_SUFFIX"
    elif [[ "$input" =~ ^rosa-.*$ ]]; then
        # Input is full cluster name
        CLUSTER_NAME=$input
        # Extract date and arch from cluster name
        if [[ "$CLUSTER_NAME" =~ ^rosa-([0-9]{8})-(.*)$ ]]; then
            DATE_PREFIX=${match[1]}
            ARCH_SUFFIX=${match[2]}
        fi
    else
        echo "ERROR: Invalid input '$input'"
        echo "Usage: use-rosa-sts [arch|date|cluster-name] [arch-if-date-provided]"
        echo "  Examples:"
        echo "    use-rosa-sts                      # List clusters and use most recent"
        echo "    use-rosa-sts arm64                # Use today's date with arm64"
        echo "    use-rosa-sts 20250710             # Use specific date with amd64"
        echo "    use-rosa-sts 20250710 arm64      # Use specific date with arm64"
        echo "    use-rosa-sts rosa-20250710-amd64 # Use specific cluster name"
        return 1
    fi

    local ROSA_DIR="$OCP_MANIFESTS_DIR/$DATE_PREFIX-rosa-sts-$ARCH_SUFFIX"
    
    # Check if cluster exists
    if ! rosa describe cluster --cluster "$CLUSTER_NAME" &>/dev/null; then
        echo "ERROR: ROSA cluster '$CLUSTER_NAME' not found in AWS"

        # Check if local directory exists
        if [[ -d "$ROSA_DIR" ]]; then
            echo "Note: Local directory exists at $ROSA_DIR but cluster may have been deleted from AWS"
            echo ""
        fi

        echo "Available ROSA clusters in AWS:"
        local cluster_list=$(rosa list clusters --output json 2>/dev/null | jq -r '.[] | .name' 2>/dev/null)

        if [[ -z "$cluster_list" ]]; then
            echo "  No ROSA clusters found in AWS"

            # Check for any local ROSA directories
            echo ""
            echo "Local ROSA cluster directories found:"
            local found_local=false
            # Use nullglob to handle the case when no matches are found
            setopt local_options nullglob
            for dir in $OCP_MANIFESTS_DIR/*-rosa-sts-*/; do
                if [[ -d "$dir" ]]; then
                    found_local=true
                    local dir_name=$(basename "$dir")
                    echo "  - $dir_name (may be stale)"
                fi
            done

            if [[ "$found_local" == "false" ]]; then
                echo "  No local ROSA directories found"
            fi
        else
            echo "$cluster_list" | while read -r cluster; do
                echo "  - $cluster"
            done
            echo ""
            echo "Hint: Use 'use-rosa-sts <cluster-name>' to connect to a specific cluster"
        fi

        return 1
    fi
    
    # Get cluster state
    local cluster_state=$(rosa describe cluster --cluster "$CLUSTER_NAME" -o json | jq -r '.state // empty')
    
    if [[ "$cluster_state" != "ready" ]]; then
        echo "WARNING: Cluster '$CLUSTER_NAME' is in state: $cluster_state"
        echo "The cluster may not be fully operational"
    fi
    
    # Configure kubectl access
    echo "Configuring kubectl access for ROSA cluster: $CLUSTER_NAME"
    
    # Create directory if it doesn't exist
    mkdir -p "$ROSA_DIR"
    
    # Get cluster API URL
    local api_url=$(rosa describe cluster --cluster "$CLUSTER_NAME" -o json | jq -r '.api.url // empty')
    
    if [[ -z "$api_url" ]]; then
        echo "ERROR: Could not retrieve API URL for cluster '$CLUSTER_NAME'"
        return 1
    fi
    
    # Check if we have valid cluster-admin credentials
    local needs_new_admin=false
    
    if [[ -f "$ROSA_DIR/cluster-admin.txt" ]]; then
        echo "Found cluster-admin credentials file, checking validity..."
        
        # Check if the file contains an error or actual credentials
        if grep -q "ERR:" "$ROSA_DIR/cluster-admin.txt" || ! grep -q "password:" "$ROSA_DIR/cluster-admin.txt"; then
            echo "Existing cluster-admin.txt contains no valid credentials"
            needs_new_admin=true
        else
            local admin_password=$(grep "password:" "$ROSA_DIR/cluster-admin.txt" | awk '{print $2}')
            local admin_user="cluster-admin"
            
            if [[ -n "$admin_password" ]]; then
                echo "Logging in as cluster-admin..."
                if oc login "$api_url" --username="$admin_user" --password="$admin_password" --insecure-skip-tls-verify=true; then
                    echo "Successfully logged in"
                else
                    echo "Login failed, credentials may be expired"
                    needs_new_admin=true
                fi
            else
                echo "Could not extract admin password"
                needs_new_admin=true
            fi
        fi
    else
        echo "No cluster-admin credentials found"
        needs_new_admin=true
    fi
    
    # Create new admin if needed
    if [[ "$needs_new_admin" == "true" ]]; then
        echo "Creating new cluster-admin user..."
        rosa create admin --cluster "$CLUSTER_NAME" | tee "$ROSA_DIR/cluster-admin.txt"
        
        # Extract and use the new credentials
        local admin_password=$(grep "password:" "$ROSA_DIR/cluster-admin.txt" | awk '{print $2}')
        local admin_user="cluster-admin"
        
        if [[ -n "$admin_password" ]]; then
            echo "Logging in with new cluster-admin credentials..."
            oc login "$api_url" --username="$admin_user" --password="$admin_password" --insecure-skip-tls-verify=true
        else
            echo "ERROR: Failed to create cluster-admin user or extract credentials"
            return 1
        fi
    fi
    
    # Verify connection
    if oc whoami &>/dev/null; then
        echo "Successfully connected to ROSA cluster: $CLUSTER_NAME"
        echo "Current user: $(oc whoami)"
        echo "API URL: $api_url"
        
        # Show cluster info
        echo ""
        echo "Cluster nodes:"
        oc get nodes
        
        echo ""
        echo "Cluster version:"
        oc get clusterversion
    else
        echo "ERROR: Failed to connect to cluster"
        return 1
    fi
    
    # Export cluster name for other functions
    export CURRENT_ROSA_CLUSTER="$CLUSTER_NAME"
    export CURRENT_ROSA_ARCH="$ARCH_SUFFIX"
}

znap function use-rosa-sts-arm64() {
    use-rosa-sts "arm64"
}

znap function use-rosa-sts-amd64() {
    use-rosa-sts "amd64"
}