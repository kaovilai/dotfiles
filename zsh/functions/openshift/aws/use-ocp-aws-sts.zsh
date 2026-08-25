# Function to copy kubeconfig from AWS STS OpenShift clusters to the default location
use-ocp-aws-sts() {
    # Core implementation for copying AWS STS OpenShift kubeconfig
    # Parameters:
    #   $1 - Command/option (help) or directory suffix
    #   $2 - Architecture (arm64 or amd64)

    local ARCH_SUFFIX=${2:-$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')}

    if [[ $1 == "help" ]]; then
        echo "Usage: use-ocp-aws-sts-$ARCH_SUFFIX [directory-suffix]"
        echo "Copy kubeconfig from the AWS STS OpenShift cluster ($ARCH_SUFFIX architecture) to the default location (~/.kube/config)"
        echo ""
        echo "Arguments:"
        echo "  directory-suffix    Optional suffix if a numbered directory was created (e.g., 1, 2)"
        echo ""
        echo "Examples:"
        echo "  use-ocp-aws-sts-$ARCH_SUFFIX         # Use the default installation directory"
        echo "  use-ocp-aws-sts-$ARCH_SUFFIX 2       # Use the installation directory with suffix '-2'"
        echo ""
        return 0
    fi

    local SUFFIX=""
    if [[ -n "$1" && "$1" != "help" ]]; then
        SUFFIX="-$1"
    fi

    local OCP_CREATE_DIR="$OCP_MANIFESTS_DIR/$TODAY-aws-sts-$ARCH_SUFFIX$SUFFIX"

    if [[ ! -d "$OCP_CREATE_DIR" ]]; then
        echo "ERROR: Installation directory not found at $OCP_CREATE_DIR"
        echo "Try specifying the correct suffix or check if the cluster was created today"
        return 1
    fi

    if [[ ! -f "$OCP_CREATE_DIR/auth/kubeconfig" ]]; then
        echo "ERROR: kubeconfig not found at $OCP_CREATE_DIR/auth/kubeconfig"
        echo "Check if the cluster was created successfully"
        return 1
    fi

    mkdir -p ~/.kube || { echo "✗ Failed to create ~/.kube directory" >&2; return 1; }

    if [[ -f ~/.kube/config ]]; then
        local backup_ts; backup_ts=$(date +%Y%m%d%H%M%S)
        if cp ~/.kube/config ~/.kube/config.backup.${backup_ts}; then
            echo "Backed up existing kubeconfig to ~/.kube/config.backup.${backup_ts}"
        else
            echo "ERROR: Failed to back up ~/.kube/config; refusing to overwrite it" >&2
            return 1
        fi
    fi

    cp "$OCP_CREATE_DIR/auth/kubeconfig" ~/.kube/config || {
        echo "ERROR: Failed to copy kubeconfig to ~/.kube/config" >&2
        return 1
    }

    echo "Successfully copied kubeconfig to ~/.kube/config"

    echo "Testing connection to the cluster..."
    KUBECONFIG=~/.kube/config oc whoami
    KUBECONFIG=~/.kube/config oc cluster-info

    return 0
}

function use-ocp-aws-sts-arm64() {
    use-ocp-aws-sts "$1" "arm64"
}

function use-ocp-aws-sts-amd64() {
    use-ocp-aws-sts "$1" "amd64"
}

use-ocp-aws-sts-dir() {
    # Use AWS STS OpenShift cluster based on a directory path
    # Parameters:
    #   $1 - Directory name (e.g., ~/OCP/manifests/20250410-aws-sts-arm64)

    if [[ $1 == "help" ]]; then
        echo "Usage: use-ocp-aws-sts-dir DIRECTORY_PATH"
        echo "Use an OpenShift cluster on AWS (STS) based on the directory path"
        echo ""
        echo "Parameters:"
        echo "  DIRECTORY_PATH  Path to the cluster directory (e.g., ~/OCP/manifests/20250410-aws-sts-arm64)"
        return 0
    fi

    if [[ ! -d "$1" ]]; then
        echo "ERROR: Directory $1 does not exist"
        return 1
    fi

    if [[ ! -f "$1/auth/kubeconfig" ]]; then
        echo "ERROR: kubeconfig not found at $1/auth/kubeconfig"
        echo "Check if the cluster was created successfully"
        return 1
    fi

    mkdir -p ~/.kube || { echo "✗ Failed to create ~/.kube directory" >&2; return 1; }

    if [[ -f ~/.kube/config ]]; then
        local backup_ts; backup_ts=$(date +%Y%m%d%H%M%S)
        if cp ~/.kube/config ~/.kube/config.backup.${backup_ts}; then
            echo "Backed up existing kubeconfig to ~/.kube/config.backup.${backup_ts}"
        else
            echo "ERROR: Failed to back up ~/.kube/config; refusing to overwrite it" >&2
            return 1
        fi
    fi

    cp "$1/auth/kubeconfig" ~/.kube/config || {
        echo "ERROR: Failed to copy kubeconfig to ~/.kube/config" >&2
        return 1
    }

    local dir_basename="${1:t}"
    echo "Successfully copied kubeconfig from $dir_basename to ~/.kube/config"

    echo "Testing connection to the cluster..."
    KUBECONFIG=~/.kube/config oc whoami
    KUBECONFIG=~/.kube/config oc cluster-info

    return 0
}
