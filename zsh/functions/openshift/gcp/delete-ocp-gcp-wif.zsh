znap function delete-ocp-gcp-wif(){
    # Use specified openshift-install or default to 4.19.0-ec.4
    local OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-openshift-install-4.19.0-ec.4}

    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: delete-ocp-gcp-wif [CLUSTER_NAME]"
        echo "Delete an OpenShift cluster on GCP that was created with Workload Identity Federation"
        echo ""
        echo "Options:"
        echo "  help          Display this help message"
        echo "  CLUSTER_NAME  Optional: Specify a custom cluster name (default: tkaovila-YYYYMMDD-wif)"
        echo ""
        echo "This function:"
        echo "  - Destroys the cluster using openshift-install"
        echo "  - Deletes the GCP WIF resources using ccoctl"
        echo "  - Removes the installation directory"
        echo ""
        echo "Directory used: $OCP_MANIFESTS_DIR/$TODAY-gcp-wif"
        return 0
    fi

    OCP_CREATE_DIR=$OCP_MANIFESTS_DIR/$TODAY-gcp-wif
    CLUSTER_NAME=tkaovila-$TODAY-wif
    if [[ -n $1 ]]; then
        CLUSTER_NAME=$1
    fi
    $OPENSHIFT_INSTALL destroy cluster --dir $OCP_CREATE_DIR || echo "no existing cluster"
    $OPENSHIFT_INSTALL destroy bootstrap --dir $OCP_CREATE_DIR || echo "no existing bootstrap"
    (ccoctl gcp delete \
    --name $CLUSTER_NAME \
    --project $GCP_PROJECT_ID \
    --credentials-requests-dir $OCP_CREATE_DIR/credentials-requests && echo "cleaned up ccoctl gcp resources") || true
    ((rm -r $OCP_CREATE_DIR && echo "removed existing create dir") || (true && echo "no existing install dir")) || return 1
}

znap function delete-ocp-gcp-wif-dir() {
    # Delete GCP-WIF OpenShift cluster based on a directory name
    # This extracts the date (TODAY) from the directory name
    # Parameters:
    #   $1 - Directory name (e.g., ~/OCP/manifests/20250410-gcp-wif)
    
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: delete-ocp-gcp-wif-dir DIRECTORY_PATH"
        echo "Delete an OpenShift cluster on GCP with Workload Identity Federation based on the directory name"
        echo ""
        echo "Parameters:"
        echo "  DIRECTORY_PATH  Path to the cluster directory (e.g., ~/OCP/manifests/20250410-gcp-wif)"
        echo ""
        echo "This function:"
        echo "  - Extracts the date from the directory name"
        echo "  - Calls the delete-ocp-gcp-wif function with the extracted date"
        echo ""
        echo "Example:"
        echo "  delete-ocp-gcp-wif-dir ~/OCP/manifests/20250410-gcp-wif"
        return 0
    fi
    
    # Check if directory exists
    if [ ! -d "$1" ]; then
        echo "ERROR: Directory $1 does not exist"
        return 1
    fi
    
    # Extract basename from the directory
    local dir_basename=$(basename "$1")
    
    # Extract date from directory name
    # Assuming format like 20250410-gcp-wif
    if [[ $dir_basename =~ ([0-9]{8})-gcp-wif ]]; then
        local extracted_date=${BASH_REMATCH[1]}
        
        echo "Extracted date: $extracted_date"
        
        # Temporarily set TODAY to the extracted date
        local original_today=$TODAY
        TODAY=$extracted_date
        
        # Call the delete function
        echo "Calling delete-ocp-gcp-wif"
        delete-ocp-gcp-wif
        
        # Restore original TODAY
        TODAY=$original_today
    else
        echo "ERROR: Directory name format not recognized: $dir_basename"
        echo "Expected format: YYYYMMDD-gcp-wif (e.g., 20250410-gcp-wif)"
        return 1
    fi
}
