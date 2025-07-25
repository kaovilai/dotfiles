znap function use-rosa-sts() {
    # Configure kubectl to use a ROSA STS cluster
    # Parameters:
    #   $1 - Architecture suffix (arm64 or amd64, defaults to amd64)
    
    local ARCH_SUFFIX=${1:-amd64}
    
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