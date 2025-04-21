# Function to copy kubeconfig from AWS OpenShift clusters to the default location
znap function use-ocp-aws() {
    # Core implementation for copying AWS OpenShift kubeconfig
    # Parameters:
    #   $1 - Command/option (help) or directory suffix
    #   $2 - Architecture (arm64 or amd64)
    
    local ARCH_SUFFIX=$2
    
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: use-ocp-aws-$ARCH_SUFFIX [directory-suffix]"
        echo "Copy kubeconfig from the AWS OpenShift cluster ($ARCH_SUFFIX architecture) to the default location (~/.kube/config)"
        echo ""
        echo "Arguments:"
        echo "  directory-suffix    Optional suffix if a numbered directory was created (e.g., 1, 2)"
        echo ""
        echo "Examples:"
        echo "  use-ocp-aws-$ARCH_SUFFIX         # Use the default installation directory"
        echo "  use-ocp-aws-$ARCH_SUFFIX 2       # Use the installation directory with suffix '-2'"
        echo ""
        return 0
    fi
    
    # Determine the correct installation directory
    local SUFFIX=""
    if [[ -n "$1" && "$1" != "help" ]]; then
        SUFFIX="-$1"
    fi
    
    local OCP_CREATE_DIR="$OCP_MANIFESTS_DIR/$TODAY-aws-$ARCH_SUFFIX$SUFFIX"
    
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

znap function use-ocp-aws-arm64() {
    # ARM64 wrapper function
    use-ocp-aws "$1" "arm64"
}

znap function use-ocp-aws-amd64() {
    # AMD64 wrapper function
    use-ocp-aws "$1" "amd64"
}

# Function to use a specific AWS OpenShift cluster from a directory path
znap function use-ocp-aws-dir() {
    # Use AWS OpenShift cluster based on a directory name
    # This extracts the date (TODAY) and architecture from the directory name
    # Parameters:
    #   $1 - Directory name (e.g., ~/OCP/manifests/20250410-aws-arm64)
    
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: use-ocp-aws-dir DIRECTORY_PATH"
        echo "Use an OpenShift cluster on AWS based on the directory path"
        echo ""
        echo "Parameters:"
        echo "  DIRECTORY_PATH  Path to the cluster directory (e.g., ~/OCP/manifests/20250410-aws-arm64)"
        echo ""
        echo "This function:"
        echo "  - Extracts the date and architecture from the directory name"
        echo "  - Copies the kubeconfig to ~/.kube/config"
        echo ""
        echo "Example:"
        echo "  use-ocp-aws-dir ~/OCP/manifests/20250410-aws-arm64"
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
