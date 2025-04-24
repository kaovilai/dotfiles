znap function delete-ocp-aws() {
    # Core implementation for AWS OpenShift cluster deletion
    # Parameters:
    #   $1 - Cluster name or help
    #   $2 - Architecture suffix (arm64 or amd64)
    
    # Use specified openshift-install or default to 4.19.0-ec.4
    local OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-openshift-install-4.19.0-ec.4}
    local ARCH_SUFFIX=$2
    
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: delete-ocp-aws-$ARCH_SUFFIX [CLUSTER_NAME]"
        echo "Delete an OpenShift cluster on AWS that was created with $ARCH_SUFFIX architecture"
        echo ""
        echo "Options:"
        echo "  help          Display this help message"
        echo "  CLUSTER_NAME  Optional: Specify a custom cluster name (default: tkaovila-YYYYMMDD-$ARCH_SUFFIX)"
        echo ""
        echo "This function:"
        echo "  - Destroys the cluster using openshift-install"
        echo "  - Removes the installation directory"
        echo ""
        echo "Directory used: $OCP_MANIFESTS_DIR/$TODAY-aws-$ARCH_SUFFIX"
        return 0
    fi
    
    # Safety check - ensure TODAY is not empty
    if [[ -z "$TODAY" ]]; then
        echo "WARNING: TODAY variable is empty, using current date"
        TODAY=$(date +%Y%m%d)
    fi
    
    OCP_CREATE_DIR=$OCP_MANIFESTS_DIR/$TODAY-aws-$ARCH_SUFFIX
    CLUSTER_NAME=tkaovila-$TODAY-$ARCH_SUFFIX
    
    if [[ -n $1 ]]; then
        CLUSTER_NAME=$1
    fi
    
    # Check if we need to clean up a cluster created with empty TODAY variable
    local EMPTY_TODAY_DIR="$OCP_MANIFESTS_DIR/-aws-$ARCH_SUFFIX"
    if [[ -d "$EMPTY_TODAY_DIR" && "$1" == "cleanup-legacy" ]]; then
        echo "INFO: Cleaning up legacy $ARCH_SUFFIX cluster with empty TODAY variable at $EMPTY_TODAY_DIR"
        local LEGACY_CLUSTER_NAME="tkaovila--$ARCH_SUFFIX"
        
        echo "Destroying AWS cluster in legacy directory: $EMPTY_TODAY_DIR"
        $OPENSHIFT_INSTALL destroy cluster --dir $EMPTY_TODAY_DIR || echo "no existing cluster in legacy directory"
        echo "Destroying AWS bootstrap in legacy directory: $EMPTY_TODAY_DIR"
        $OPENSHIFT_INSTALL destroy bootstrap --dir $EMPTY_TODAY_DIR || echo "no existing bootstrap in legacy directory"
        
        ((rm -r $EMPTY_TODAY_DIR && echo "removed legacy create dir") || (true && echo "no legacy install dir")) || true
        
        # If we're only cleaning up legacy clusters, return here
        if [[ "$1" == "cleanup-legacy" ]]; then
            return 0
        fi
    fi
    
    echo "Destroying AWS cluster in directory: $OCP_CREATE_DIR"
    $OPENSHIFT_INSTALL destroy cluster --dir $OCP_CREATE_DIR || echo "no existing cluster"
    echo "Destroying AWS bootstrap in directory: $OCP_CREATE_DIR"
    $OPENSHIFT_INSTALL destroy bootstrap --dir $OCP_CREATE_DIR || echo "no existing bootstrap"
    ((rm -r $OCP_CREATE_DIR && echo "removed existing create dir") || (true && echo "no existing install dir")) || return 1
}

znap function delete-ocp-aws-arm64() {
    # ARM64 deletion wrapper function
    delete-ocp-aws "$1" "arm64"
}

znap function delete-ocp-aws-amd64() {
    # AMD64 deletion wrapper function
    delete-ocp-aws "$1" "amd64"
}

znap function delete-ocp-aws-dir() {
    # Delete AWS OpenShift cluster based on a directory name
    # This extracts the date (TODAY) and architecture from the directory name
    # Parameters:
    #   $1 - Directory name (e.g., ~/OCP/manifests/20250410-aws-arm64)
    
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: delete-ocp-aws-dir DIRECTORY_PATH"
        echo "Delete an OpenShift cluster on AWS based on the directory name"
        echo ""
        echo "Parameters:"
        echo "  DIRECTORY_PATH  Path to the cluster directory (e.g., ~/OCP/manifests/20250410-aws-arm64)"
        echo ""
        echo "This function:"
        echo "  - Extracts the date and architecture from the directory name"
        echo "  - Calls the appropriate delete function"
        echo ""
        echo "Example:"
        echo "  delete-ocp-aws-dir ~/OCP/manifests/20250410-aws-arm64"
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
    
    # Extract date and architecture from directory name
    # Assuming format like 20250410-aws-arm64 or 20250410-aws-amd64
    # Also handle numbered suffixes like 20250410-aws-arm64-1
    if [[ $dir_basename =~ ([0-9]{8})-aws-(arm64|amd64)(-[0-9]+)? ]]; then
        local extracted_date=${BASH_REMATCH[1]}
        local extracted_arch=${BASH_REMATCH[2]}
        local extracted_suffix=${BASH_REMATCH[3]}
        
        echo "Extracted date: $extracted_date, architecture: $extracted_arch, suffix: ${extracted_suffix:-none}"
        
        # Safety check - ensure extracted_date is not empty
        if [[ -z "$extracted_date" ]]; then
            echo "ERROR: Failed to extract date from directory name: $dir_basename"
            echo "Using current date as fallback"
            extracted_date=$(date +%Y%m%d)
        fi
        
        # Safety check - ensure extracted_arch is not empty
        if [[ -z "$extracted_arch" ]]; then
            echo "ERROR: Failed to extract architecture from directory name: $dir_basename"
            echo "Using arm64 as fallback architecture"
            extracted_arch="arm64"
        fi
        
        # Temporarily set TODAY to the extracted date
        local original_today=$TODAY
        TODAY=$extracted_date
        
        # If we have a numbered suffix, adjust the directory and cluster name
        if [[ -n "$extracted_suffix" ]]; then
            # Override the directory path to include the suffix
            export OCP_CREATE_DIR="$OCP_MANIFESTS_DIR/$extracted_date-aws-$extracted_arch$extracted_suffix"
            # Override the cluster name to include the suffix
            export CLUSTER_NAME="tkaovila-$extracted_date-$extracted_arch$extracted_suffix"
            echo "Using directory path: $OCP_CREATE_DIR"
            echo "Using cluster name: $CLUSTER_NAME"
        else
            # Explicitly set the directory path and cluster name for clarity
            export OCP_CREATE_DIR="$OCP_MANIFESTS_DIR/$extracted_date-aws-$extracted_arch"
            export CLUSTER_NAME="tkaovila-$extracted_date-$extracted_arch"
            echo "Using directory path: $OCP_CREATE_DIR"
            echo "Using cluster name: $CLUSTER_NAME"
        fi
        
        # Call the appropriate delete function based on the architecture
        if [[ "$extracted_arch" == "arm64" ]]; then
            echo "Calling delete-ocp-aws-arm64"
            delete-ocp-aws-arm64 "$CLUSTER_NAME"
        elif [[ "$extracted_arch" == "amd64" ]]; then
            echo "Calling delete-ocp-aws-amd64"
            delete-ocp-aws-amd64 "$CLUSTER_NAME"
        else
            echo "ERROR: Unknown architecture: $extracted_arch"
            # Restore original TODAY
            TODAY=$original_today
            return 1
        fi
        
        # Restore original TODAY
        TODAY=$original_today
    else
        echo "ERROR: Directory name format not recognized: $dir_basename"
        echo "Expected format: YYYYMMDD-aws-ARCH (e.g., 20250410-aws-arm64)"
        echo "Using current date and arm64 architecture as fallback"
        
        # Use current date and arm64 as fallback
        local fallback_date=$(date +%Y%m%d)
        local fallback_arch="arm64"
        local original_today=$TODAY
        TODAY=$fallback_date
        
        echo "Using fallback directory path: $OCP_MANIFESTS_DIR/$fallback_date-aws-$fallback_arch"
        echo "Using fallback cluster name: tkaovila-$fallback_date-$fallback_arch"
        
        # Call the delete function with explicit cluster name
        echo "Calling delete-ocp-aws-arm64 with fallback values"
        delete-ocp-aws-arm64 "tkaovila-$fallback_date-$fallback_arch"
        
        # Restore original TODAY
        TODAY=$original_today
        
        return 1
    fi
}
