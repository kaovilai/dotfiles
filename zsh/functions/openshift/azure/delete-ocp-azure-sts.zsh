znap function delete-ocp-azure-sts(){
    # Unset SSH_AUTH_SOCK on Darwin systems to avoid SSH errors
    if [[ "$(uname)" == "Darwin" ]]; then
        unset SSH_AUTH_SOCK
    fi
    
    # Use specified openshift-install or default to latest EC version
    local EC_VERSION=${OCP_LATEST_EC_VERSION:-$(get_latest_ec_version)}
    local OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-openshift-install-${EC_VERSION}}

    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: delete-ocp-azure-sts [CLUSTER_NAME]"
        echo "Delete an OpenShift cluster on Azure that was created with Workload Identity (STS)"
        echo ""
        echo "Options:"
        echo "  help          Display this help message"
        echo "  CLUSTER_NAME  Optional: Specify a custom cluster name (default: tkaovila-YYYYMMDD-sts)"
        echo ""
        echo "This function:"
        echo "  - Destroys the cluster using openshift-install"
        echo "  - Deletes the Azure STS resources using ccoctl"
        echo "  - Removes the installation directory"
        echo ""
        echo "Directory used: $OCP_MANIFESTS_DIR/$TODAY-azure-sts"
        return 0
    fi

    # Safety check - ensure TODAY is not empty
    if [[ -z "$TODAY" ]]; then
        echo "WARNING: TODAY variable is empty, using current date"
        TODAY=$(date +%Y%m%d)
    fi
    
    OCP_CREATE_DIR=$OCP_MANIFESTS_DIR/$TODAY-azure-sts
    CLUSTER_NAME=tkaovila-$TODAY-sts
    if [[ -n $1 ]]; then
        CLUSTER_NAME=$1
    fi
    
    # Check if we need to clean up a cluster created with empty TODAY variable
    local EMPTY_TODAY_DIR="$OCP_MANIFESTS_DIR/-azure-sts"
    if [[ -d "$EMPTY_TODAY_DIR" && "$1" == "cleanup-legacy" ]]; then
        echo "INFO: Cleaning up legacy cluster with empty TODAY variable at $EMPTY_TODAY_DIR"
        local LEGACY_CLUSTER_NAME="tkaovila--sts"
        
        echo "Destroying Azure cluster in legacy directory: $EMPTY_TODAY_DIR"
        $OPENSHIFT_INSTALL destroy cluster --dir $EMPTY_TODAY_DIR || echo "no existing cluster in legacy directory"
        echo "Destroying Azure bootstrap in legacy directory: $EMPTY_TODAY_DIR"
        $OPENSHIFT_INSTALL destroy bootstrap --dir $EMPTY_TODAY_DIR || echo "no existing bootstrap in legacy directory"
        
        (ccoctl azure delete \
        --name $LEGACY_CLUSTER_NAME \
        --subscription-id $AZURE_SUBSCRIPTION_ID \
        --tenant-id $AZURE_TENANT_ID \
        --resource-group $AZURE_RESOURCE_GROUP \
        --credentials-requests-dir $EMPTY_TODAY_DIR/credentials-requests && echo "cleaned up legacy ccoctl azure resources") || true
        
        ((rm -r $EMPTY_TODAY_DIR && echo "removed legacy create dir") || (true && echo "no legacy install dir")) || true
        
        # If we're only cleaning up legacy clusters, return here
        if [[ "$1" == "cleanup-legacy" ]]; then
            return 0
        fi
    fi
echo "Destroying Azure cluster in directory: $OCP_CREATE_DIR"
$OPENSHIFT_INSTALL destroy cluster --dir $OCP_CREATE_DIR || echo "no existing cluster"
echo "Destroying Azure bootstrap in directory: $OCP_CREATE_DIR"
$OPENSHIFT_INSTALL destroy bootstrap --dir $OCP_CREATE_DIR || echo "no existing bootstrap"
    (ccoctl azure delete \
    --name $CLUSTER_NAME \
    --subscription-id $AZURE_SUBSCRIPTION_ID \
    --tenant-id $AZURE_TENANT_ID \
    --resource-group $AZURE_RESOURCE_GROUP \
    --credentials-requests-dir $OCP_CREATE_DIR/credentials-requests && echo "cleaned up ccoctl azure resources") || true
    ((rm -r $OCP_CREATE_DIR && echo "removed existing create dir") || (true && echo "no existing install dir")) || return 1
}

znap function delete-ocp-azure-sts-dir() {
    # Delete Azure-STS OpenShift cluster based on a directory name
    # This extracts the date (TODAY) from the directory name
    # Parameters:
    #   $1 - Directory name (e.g., ~/OCP/manifests/20250410-azure-sts)
    
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: delete-ocp-azure-sts-dir DIRECTORY_PATH"
        echo "Delete an OpenShift cluster on Azure with Workload Identity (STS) based on the directory name"
        echo ""
        echo "Parameters:"
        echo "  DIRECTORY_PATH  Path to the cluster directory (e.g., ~/OCP/manifests/20250410-azure-sts)"
        echo ""
        echo "This function:"
        echo "  - Extracts the date from the directory name"
        echo "  - Calls the delete-ocp-azure-sts function with the extracted date"
        echo ""
        echo "Example:"
        echo "  delete-ocp-azure-sts-dir ~/OCP/manifests/20250410-azure-sts"
        return 0
    fi
    
    # Check if directory exists
    if [ ! -d "$1" ]; then
        echo "ERROR: Directory $1 does not exist"
        return 1
    fi
    
    # Extract basename from the directory
    local dir_basename=$(basename "$1")
    echo "DEBUG: Processing directory basename: $dir_basename"
    
    # Extract date from directory name
    # Assuming format like 20250410-azure-sts
    # Also handle numbered suffixes like 20250410-azure-sts-1
    if [[ $dir_basename =~ ^([0-9]{8})-azure-sts(-[0-9]+)?$ ]]; then
        local extracted_date=${BASH_REMATCH[1]}
        local extracted_suffix=${BASH_REMATCH[2]}
        
        echo "Extracted date: $extracted_date, suffix: ${extracted_suffix:-none}"
        
        # Safety check - ensure extracted_date is not empty
        if [[ -z "$extracted_date" ]]; then
            echo "ERROR: Failed to extract date from directory name: $dir_basename"
            echo "Using current date as fallback"
            extracted_date=$(date +%Y%m%d)
        fi
        
        # Temporarily set TODAY to the extracted date
        local original_today=$TODAY
        TODAY=$extracted_date
        
        # If we have a numbered suffix, adjust the directory and cluster name
        if [[ -n "$extracted_suffix" ]]; then
            # Use local variables to avoid polluting the global environment
            local ocp_create_dir="$OCP_MANIFESTS_DIR/$extracted_date-azure-sts$extracted_suffix"
            local cluster_name="tkaovila-$extracted_date-sts$extracted_suffix"
            echo "Using directory path: $ocp_create_dir"
            echo "Using cluster name: $cluster_name"
        else
            # Use local variables to avoid polluting the global environment
            local ocp_create_dir="$OCP_MANIFESTS_DIR/$extracted_date-azure-sts"
            local cluster_name="tkaovila-$extracted_date-sts"
            echo "Using directory path: $ocp_create_dir"
            echo "Using cluster name: $cluster_name"
        fi
        
        # Call the delete function with explicit parameters
        echo "Calling delete-ocp-azure-sts"
        OCP_CREATE_DIR="$ocp_create_dir" CLUSTER_NAME="$cluster_name" delete-ocp-azure-sts "$cluster_name"
        
        # Restore original TODAY
        TODAY=$original_today
    else
        echo "ERROR: Directory name format not recognized: $dir_basename"
        echo "Expected format: YYYYMMDD-azure-sts (e.g., 20250410-azure-sts)"
        echo "Using current date as fallback"
        
        # Use current date as fallback
        local fallback_date=$(date +%Y%m%d)
        local original_today=$TODAY
        TODAY=$fallback_date
        
        local fallback_dir="$OCP_MANIFESTS_DIR/$fallback_date-azure-sts"
        local fallback_cluster="tkaovila-$fallback_date-sts"
        echo "Using fallback directory path: $fallback_dir"
        echo "Using fallback cluster name: $fallback_cluster"
        
        # Call the delete function with explicit cluster name and local variables
        echo "Calling delete-ocp-azure-sts with fallback values"
        OCP_CREATE_DIR="$fallback_dir" CLUSTER_NAME="$fallback_cluster" delete-ocp-azure-sts "$fallback_cluster"
        
        # Restore original TODAY
        TODAY=$original_today
        
        return 1
    fi
}