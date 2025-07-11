znap function delete-rosa-sts() {
    # Delete a ROSA STS cluster and all associated resources
    # Parameters:
    #   $1 - Architecture suffix (arm64 or amd64)
    
    local ARCH_SUFFIX=$1
    
    # Safety check - ensure TODAY is not empty
    if [[ -z "$TODAY" ]]; then
        echo "WARNING: TODAY variable is empty, using current date"
        TODAY=$(date +%Y%m%d)
    fi
    
    # Set cluster name and directory
    local CLUSTER_NAME="rosa-$TODAY-$ARCH_SUFFIX"
    local ROSA_DIR="$OCP_MANIFESTS_DIR/$TODAY-rosa-sts-$ARCH_SUFFIX"
    
    echo "Preparing to delete ROSA cluster: $CLUSTER_NAME"
    echo "This will delete:"
    echo "  - The ROSA cluster and all its resources"
    echo "  - Associated IAM roles and policies"
    echo "  - OIDC provider"
    echo "  - Local directory: $ROSA_DIR"
    echo ""
    echo -n "Are you sure you want to proceed? (yes/no): "
    read confirmation
    
    if [[ "$confirmation" != "yes" ]]; then
        echo "Deletion cancelled"
        return 0
    fi
    
    # Check if cluster exists
    if rosa describe cluster --cluster "$CLUSTER_NAME" &>/dev/null; then
        echo "Found ROSA cluster: $CLUSTER_NAME"
        
        # Get cluster ID for cleanup
        local cluster_id=$(rosa describe cluster --cluster "$CLUSTER_NAME" -o json | jq -r '.id // empty')
        
        # Delete the cluster
        echo "Deleting ROSA cluster: $CLUSTER_NAME"
        rosa delete cluster --cluster "$CLUSTER_NAME" --yes --watch || {
            echo "WARNING: Failed to delete cluster, continuing with cleanup..."
        }
        
        # Wait a bit for cluster deletion to register
        echo "Waiting for cluster deletion to complete..."
        local wait_count=0
        while rosa describe cluster --cluster "$CLUSTER_NAME" &>/dev/null && [[ $wait_count -lt 60 ]]; do
            echo -n "."
            sleep 10
            ((wait_count++))
        done
        echo ""
        
        # Clean up operator roles
        echo "Deleting operator roles..."
        if [[ -n "$cluster_id" ]]; then
            rosa delete operator-roles -c "$cluster_id" --yes --mode auto 2>/dev/null || {
                echo "INFO: Operator roles may have already been deleted"
            }
        else
            rosa delete operator-roles -c "$CLUSTER_NAME" --yes --mode auto 2>/dev/null || {
                echo "INFO: Operator roles may have already been deleted"
            }
        fi
        
        # Clean up OIDC provider
        echo "Deleting OIDC provider..."
        if [[ -n "$cluster_id" ]]; then
            rosa delete oidc-provider -c "$cluster_id" --yes --mode auto 2>/dev/null || {
                echo "INFO: OIDC provider may have already been deleted"
            }
        else
            rosa delete oidc-provider -c "$CLUSTER_NAME" --yes --mode auto 2>/dev/null || {
                echo "INFO: OIDC provider may have already been deleted"
            }
        fi
        
        echo "ROSA cluster deletion initiated"
    else
        echo "No ROSA cluster found with name: $CLUSTER_NAME"
    fi
    
    # Clean up local directory
    if [[ -d "$ROSA_DIR" ]]; then
        echo "Removing local directory: $ROSA_DIR"
        rm -rf "$ROSA_DIR" && echo "Directory removed successfully"
    else
        echo "No local directory found at: $ROSA_DIR"
    fi
    
    # List remaining ROSA clusters
    echo ""
    echo "Remaining ROSA clusters:"
    rosa list clusters --output table
    
    # Check for orphaned resources
    echo ""
    echo "Checking for orphaned account roles..."
    local orphan_roles=$(rosa list account-roles | grep -v "Cluster ID" | grep -E "^\s*$" | wc -l)
    if [[ $orphan_roles -gt 0 ]]; then
        echo "WARNING: Found orphaned account roles. You may want to review and clean them up:"
        echo "rosa list account-roles"
    fi
    
    echo ""
    echo "Deletion process completed for cluster: $CLUSTER_NAME"
    
    # Unset environment variables if this was the current cluster
    if [[ "$CURRENT_ROSA_CLUSTER" == "$CLUSTER_NAME" ]]; then
        unset CURRENT_ROSA_CLUSTER
        unset CURRENT_ROSA_ARCH
        echo "Cleared current ROSA cluster environment variables"
    fi
}

znap function delete-rosa-sts-arm64() {
    delete-rosa-sts "arm64"
}

znap function delete-rosa-sts-amd64() {
    delete-rosa-sts "amd64"
}