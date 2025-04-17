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
    
    OCP_CREATE_DIR=$OCP_MANIFESTS_DIR/$TODAY-aws-$ARCH_SUFFIX
    CLUSTER_NAME=tkaovila-$TODAY-$ARCH_SUFFIX
    
    if [[ -n $1 ]]; then
        CLUSTER_NAME=$1
    fi
    
    $OPENSHIFT_INSTALL destroy cluster --dir $OCP_CREATE_DIR || echo "no existing cluster"
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
    
    # Extract date and architecture from directory name
    # Assuming format like 20250410-aws-arm64 or 20250410-aws-amd64
    if [[ $dir_basename =~ ([0-9]{8})-aws-(arm64|amd64) ]]; then
        local extracted_date=${BASH_REMATCH[1]}
        local extracted_arch=${BASH_REMATCH[2]}
        
        echo "Extracted date: $extracted_date, architecture: $extracted_arch"
        
        # Temporarily set TODAY to the extracted date
        local original_today=$TODAY
        TODAY=$extracted_date
        
        # Call the appropriate delete function based on the architecture
        if [[ "$extracted_arch" == "arm64" ]]; then
            echo "Calling delete-ocp-aws-arm64"
            delete-ocp-aws-arm64
        elif [[ "$extracted_arch" == "amd64" ]]; then
            echo "Calling delete-ocp-aws-amd64"
            delete-ocp-aws-amd64
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
        return 1
    fi
}
