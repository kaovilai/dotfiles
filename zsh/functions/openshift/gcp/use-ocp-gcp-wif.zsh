# Function to copy kubeconfig from the GCP WIF cluster to the default location
znap function use-ocp-gcp-wif(){
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: use-ocp-gcp-wif [directory-suffix]"
        echo "Copy kubeconfig from the GCP WIF cluster to the default location (~/.kube/config)"
        echo ""
        echo "Arguments:"
        echo "  directory-suffix    Optional suffix if a numbered directory was created (e.g., 1, 2)"
        echo ""
        echo "Examples:"
        echo "  use-ocp-gcp-wif         # Use the default installation directory"
        echo "  use-ocp-gcp-wif 2       # Use the installation directory with suffix '-2'"
        echo ""
        return 0
    fi
    
    # Determine the correct installation directory
    local SUFFIX=""
    if [[ -n "$1" && "$1" != "help" ]]; then
        SUFFIX="-$1"
    fi
    
    local OCP_CREATE_DIR="$OCP_MANIFESTS_DIR/$TODAY-gcp-wif$SUFFIX"
    
    # Check if the directory exists
    if [[ ! -d "$OCP_CREATE_DIR" ]]; then
        echo "ERROR: Installation directory not found at $OCP_CREATE_DIR"
        echo "Try specifying the correct suffix or check if the cluster was created today"
        return 1
    fi
    
    # Check if kubeconfig exists in the installation directory
    if [[ ! -f "$OCP_CREATE_DIR/auth/kubeconfig" ]]; then
        echo "ERROR: kubeconfig not found at $OCP_CREATE_DIR/auth/kubeconfig"
        echo "Check if the cluster was created successfully"
        return 1
    fi
    
    # Create ~/.kube directory if it doesn't exist
    mkdir -p ~/.kube
    
    # Backup existing kubeconfig if it exists
    if [[ -f ~/.kube/config ]]; then
        cp ~/.kube/config ~/.kube/config.backup.$(date +%Y%m%d%H%M%S)
        echo "Backed up existing kubeconfig to ~/.kube/config.backup.$(date +%Y%m%d%H%M%S)"
    fi
    
    # Copy the kubeconfig
    cp "$OCP_CREATE_DIR/auth/kubeconfig" ~/.kube/config
    
    # Show success message with cluster details
    echo "Successfully copied kubeconfig to ~/.kube/config"
    
    # Test the connection
    echo "Testing connection to the cluster..."
    oc whoami
    oc cluster-info
    
    return 0
}

# Function to use a specific GCP WIF cluster from a directory path
znap function use-ocp-gcp-wif-dir() {
    # Use GCP WIF OpenShift cluster based on a directory name
    # Parameters:
    #   $1 - Directory name (e.g., ~/OCP/manifests/20250410-gcp-wif)
    
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: use-ocp-gcp-wif-dir DIRECTORY_PATH"
        echo "Use an OpenShift cluster on GCP with WIF based on the directory path"
        echo ""
        echo "Parameters:"
        echo "  DIRECTORY_PATH  Path to the cluster directory (e.g., ~/OCP/manifests/20250410-gcp-wif)"
        echo ""
        echo "This function:"
        echo "  - Copies the kubeconfig to ~/.kube/config"
        echo ""
        echo "Example:"
        echo "  use-ocp-gcp-wif-dir ~/OCP/manifests/20250410-gcp-wif"
        return 0
    fi
    
    # Check if directory exists
    if [ ! -d "$1" ]; then
        echo "ERROR: Directory $1 does not exist"
        return 1
    fi
    
    # Check if kubeconfig exists in the specified directory
    if [[ ! -f "$1/auth/kubeconfig" ]]; then
        echo "ERROR: kubeconfig not found at $1/auth/kubeconfig"
        echo "Check if the cluster was created successfully"
        return 1
    fi
    
    # Create ~/.kube directory if it doesn't exist
    mkdir -p ~/.kube
    
    # Backup existing kubeconfig if it exists
    if [[ -f ~/.kube/config ]]; then
        cp ~/.kube/config ~/.kube/config.backup.$(date +%Y%m%d%H%M%S)
        echo "Backed up existing kubeconfig to ~/.kube/config.backup.$(date +%Y%m%d%H%M%S)"
    fi
    
    # Copy the kubeconfig
    cp "$1/auth/kubeconfig" ~/.kube/config
    
    # Extract basename from the directory
    local dir_basename=$(basename "$1")
    
    # Show success message
    echo "Successfully copied kubeconfig from $dir_basename to ~/.kube/config"
    
    # Test the connection
    echo "Testing connection to the cluster..."
    oc whoami
    oc cluster-info
    
    return 0
}
