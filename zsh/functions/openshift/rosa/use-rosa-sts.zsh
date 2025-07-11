znap function use-rosa-sts() {
    # Configure kubectl to use a ROSA STS cluster
    # Parameters:
    #   $1 - Architecture suffix (arm64 or amd64)
    
    local ARCH_SUFFIX=$1
    
    # Safety check - ensure TODAY is not empty
    if [[ -z "$TODAY" ]]; then
        echo "WARNING: TODAY variable is empty, using current date"
        TODAY=$(date +%Y%m%d)
    fi
    
    # Set cluster name
    local CLUSTER_NAME="rosa-$TODAY-$ARCH_SUFFIX"
    local ROSA_DIR="$OCP_MANIFESTS_DIR/$TODAY-rosa-sts-$ARCH_SUFFIX"
    
    # Check if cluster exists
    if ! rosa describe cluster --cluster "$CLUSTER_NAME" &>/dev/null; then
        echo "ERROR: ROSA cluster '$CLUSTER_NAME' not found"
        echo "Available ROSA clusters:"
        rosa list clusters --output table
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
    
    # Get cluster API URL
    local api_url=$(rosa describe cluster --cluster "$CLUSTER_NAME" -o json | jq -r '.api.url // empty')
    
    if [[ -z "$api_url" ]]; then
        echo "ERROR: Could not retrieve API URL for cluster '$CLUSTER_NAME'"
        return 1
    fi
    
    # Check if we have cluster-admin credentials
    if [[ -f "$ROSA_DIR/cluster-admin.txt" ]]; then
        echo "Found cluster-admin credentials"
        local admin_password=$(grep "password:" "$ROSA_DIR/cluster-admin.txt" | awk '{print $2}')
        local admin_user="cluster-admin"
        
        if [[ -n "$admin_password" ]]; then
            echo "Logging in as cluster-admin..."
            oc login "$api_url" --username="$admin_user" --password="$admin_password" --insecure-skip-tls-verify=true
        else
            echo "WARNING: Could not extract admin password from $ROSA_DIR/cluster-admin.txt"
            echo "You may need to create a new admin user with: rosa create admin --cluster $CLUSTER_NAME"
        fi
    else
        echo "No cluster-admin credentials found at $ROSA_DIR/cluster-admin.txt"
        echo "Creating new cluster-admin user..."
        rosa create admin --cluster "$CLUSTER_NAME" | tee "$ROSA_DIR/cluster-admin.txt"
        
        # Extract and use the new credentials
        local admin_password=$(grep "password:" "$ROSA_DIR/cluster-admin.txt" | awk '{print $2}')
        local admin_user="cluster-admin"
        
        if [[ -n "$admin_password" ]]; then
            echo "Logging in as cluster-admin..."
            oc login "$api_url" --username="$admin_user" --password="$admin_password" --insecure-skip-tls-verify=true
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