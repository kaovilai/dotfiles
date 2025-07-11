znap function create-rosa-sts() {
    # Core implementation for ROSA STS cluster creation
    # Parameters:
    #   $1 - Command/option (help, delete, no-delete, --force-new)
    #   $2 - Architecture (arm64 or amd64)
    
    # Unset SSH_AUTH_SOCK on Darwin systems to avoid SSH errors
    if [[ "$(uname)" == "Darwin" ]]; then
        unset SSH_AUTH_SOCK
    fi
    
    local ARCHITECTURE=$2
    local ARCH_SUFFIX=${2}
    
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: create-rosa-sts-$ARCH_SUFFIX [OPTION] [FLAGS]"
        echo "Create a Red Hat OpenShift Service on AWS (ROSA) cluster with STS using $ARCHITECTURE architecture"
        echo ""
        echo "Options:"
        echo "  help        Display this help message"
        echo "  delete      Just delete the cluster without recreating it"
        echo "  no-delete   Skip deletion of existing cluster before creation"
        echo ""
        echo "Flags (can be combined):"
        echo "  --force-new Force creation alongside existing clusters (skip prompt)"
        echo "  --multi-az  Create a multi-AZ cluster (default is single-AZ)"
        echo "  --private   Create a private cluster (private API and ingress)"
        echo ""
        echo "Examples:"
        echo "  create-rosa-sts-$ARCH_SUFFIX --force-new --multi-az"
        echo "  create-rosa-sts-$ARCH_SUFFIX no-delete --private"
        echo ""
        echo "Prerequisites:"
        echo "  - AWS_REGION environment variable (defaults to us-east-1 if not set)"
        echo "  - AWS credentials must be configured"
        echo "  - ROSA CLI must be installed (rosa)"
        echo "  - Red Hat account logged in via 'rosa login'"
        echo "  - Account-wide STS roles created via 'rosa create account-roles --mode auto'"
        echo ""
        echo "Directory:"
        echo "  Installation files will be created in: $OCP_MANIFESTS_DIR/$TODAY-rosa-sts-$ARCH_SUFFIX"
        echo ""
        echo "Note:"
        echo "  ROSA CLI 1.3.0+ defaults to STS mode for enhanced security"
        echo "  The cluster will be created with auto mode for automatic IAM role creation"
        return 0
    fi
    
    # Set default values for AWS_REGION if not already set
    if [[ -z "$AWS_REGION" ]]; then
        echo "INFO: AWS_REGION not set, defaulting to us-east-1"
        AWS_REGION="us-east-1"
    fi
    
    # Validate AWS credentials are configured
    if ! aws sts get-caller-identity &>/dev/null; then
        echo "ERROR: AWS credentials not configured. Please run 'aws configure' or set AWS credentials"
        return 1
    fi
    
    # Check if ROSA CLI is installed
    if ! command -v rosa &>/dev/null; then
        echo "ERROR: ROSA CLI not found. Please install ROSA CLI from https://console.redhat.com/openshift/downloads"
        return 1
    fi
    
    # Check if logged into ROSA
    if ! rosa whoami &>/dev/null; then
        echo "ERROR: Not logged into ROSA. Please run 'rosa login' first"
        return 1
    fi
    
    # Verify account-wide roles exist
    local account_roles=$(rosa list account-roles 2>/dev/null | grep -E "Installer|Support|Worker|ControlPlane" | wc -l)
    if [[ $account_roles -lt 4 ]]; then
        echo "WARNING: Account-wide STS roles not found or incomplete"
        echo "Creating account-wide roles..."
        rosa create account-roles --mode auto --yes || {
            echo "ERROR: Failed to create account-wide roles"
            return 1
        }
    else
        echo "INFO: Account-wide STS roles verified"
    fi
    
    # Safety check - ensure TODAY is not empty
    if [[ -z "$TODAY" ]]; then
        echo "WARNING: TODAY variable is empty, using current date"
        TODAY=$(date +%Y%m%d)
    fi
    
    # Set initial cluster name and directory
    local CLUSTER_BASE_NAME="rosa-$TODAY-$ARCH_SUFFIX"
    local ROSA_CREATE_DIR="$OCP_MANIFESTS_DIR/$TODAY-rosa-sts-$ARCH_SUFFIX"
    
    # Generate unique cluster name if needed
    local unique_result=$(generate_unique_cluster_name "$CLUSTER_BASE_NAME" "$ROSA_CREATE_DIR")
    [[ -z "$unique_result" ]] && return 1
    local CLUSTER_NAME=$(echo "$unique_result" | grep "cluster_name:" | cut -d: -f2)
    local ROSA_CREATE_DIR=$(echo "$unique_result" | grep "cluster_dir:" | cut -d: -f2)
    
    # Handle deletion if requested
    if [[ $1 != "no-delete" ]]; then
        if rosa describe cluster --cluster "$CLUSTER_NAME" &>/dev/null; then
            echo "Deleting existing ROSA cluster: $CLUSTER_NAME"
            rosa delete cluster --cluster "$CLUSTER_NAME" --yes || echo "Failed to delete cluster"
            
            # Wait for cluster deletion to complete
            echo "Waiting for cluster deletion to complete..."
            while rosa describe cluster --cluster "$CLUSTER_NAME" &>/dev/null; do
                echo -n "."
                sleep 30
            done
            echo " Done"
            
            # Delete operator roles and OIDC provider
            echo "Cleaning up operator roles and OIDC provider..."
            rosa delete operator-roles -c "$CLUSTER_NAME" --yes --mode auto 2>/dev/null || true
            rosa delete oidc-provider -c "$CLUSTER_NAME" --yes --mode auto 2>/dev/null || true
        else
            echo "No existing ROSA cluster found with name: $CLUSTER_NAME"
        fi
        
        # Clean up directory
        if [[ -d "$ROSA_CREATE_DIR" ]]; then
            rm -rf "$ROSA_CREATE_DIR" && echo "Removed existing directory: $ROSA_CREATE_DIR"
        fi
    fi
    
    # If param is delete then stop here
    if [[ $1 == "delete" ]]; then
        return 0
    fi
    
    # Parse command line flags
    local force_new=false
    local multi_az=false
    local private=false
    
    for arg in "$@"; do
        case "$arg" in
            --force-new)
                force_new=true
                ;;
            --multi-az)
                multi_az=true
                ;;
            --private)
                private=true
                ;;
        esac
    done
    
    # Set environment variables based on flags
    if [[ "$force_new" == "true" ]]; then
        export FORCE_NEW_CLUSTER="true"
    fi
    
    # Check for existing clusters before proceeding
    check-for-existing-clusters "rosa-sts" "$ARCH_SUFFIX" || return 1
    
    # Unset the force flag after use
    [[ -n "$FORCE_NEW_CLUSTER" ]] && unset FORCE_NEW_CLUSTER
    
    # Create directory for logs and configuration
    mkdir -p "$ROSA_CREATE_DIR" || return 1
    
    # Build ROSA create cluster command
    local rosa_cmd="rosa create cluster --sts --mode auto --yes"
    rosa_cmd+=" --cluster-name $CLUSTER_NAME"
    rosa_cmd+=" --region $AWS_REGION"
    
    # Add architecture support
    if [[ "$ARCHITECTURE" == "arm64" ]]; then
        rosa_cmd+=" --compute-machine-type m6g.xlarge"
    else
        rosa_cmd+=" --compute-machine-type m5.xlarge"
    fi
    
    # Add multi-AZ flag if requested
    if [[ "$multi_az" == "true" ]]; then
        rosa_cmd+=" --multi-az"
        echo "INFO: Creating multi-AZ cluster"
    else
        echo "INFO: Creating single-AZ cluster"
    fi
    
    # Add private cluster flag if requested
    if [[ "$private" == "true" ]]; then
        rosa_cmd+=" --private"
        echo "INFO: Creating private cluster (private API and ingress)"
    else
        echo "INFO: Creating public cluster"
    fi
    
    # Set default compute nodes
    rosa_cmd+=" --replicas 3"
    
    # Log the command to file
    echo "ROSA Create Command: $rosa_cmd" > "$ROSA_CREATE_DIR/rosa-create-command.txt"
    
    # Create the cluster
    echo "Creating ROSA STS cluster: $CLUSTER_NAME"
    echo "This process may take 30-45 minutes..."
    
    if ! eval "$rosa_cmd" 2>&1 | tee "$ROSA_CREATE_DIR/rosa-create.log"; then
        echo "ERROR: Failed to create ROSA cluster"
        echo "Check logs at: $ROSA_CREATE_DIR/rosa-create.log"
        cleanup_on_failure "$ROSA_CREATE_DIR" "$CLUSTER_NAME" "rosa-sts"
        return 1
    fi
    
    # Wait for cluster to be ready
    echo "Waiting for cluster to become ready..."
    rosa describe cluster --cluster "$CLUSTER_NAME" > "$ROSA_CREATE_DIR/cluster-info.txt"
    
    # Get cluster API URL and console URL
    local api_url=$(rosa describe cluster --cluster "$CLUSTER_NAME" -o json | jq -r '.api.url // empty')
    local console_url=$(rosa describe cluster --cluster "$CLUSTER_NAME" -o json | jq -r '.console.url // empty')
    
    if [[ -n "$api_url" ]]; then
        echo "Cluster API URL: $api_url" | tee -a "$ROSA_CREATE_DIR/cluster-info.txt"
    fi
    
    if [[ -n "$console_url" ]]; then
        echo "Console URL: $console_url" | tee -a "$ROSA_CREATE_DIR/cluster-info.txt"
    fi
    
    # Create cluster-admin user
    echo "Creating cluster-admin user..."
    rosa create admin --cluster "$CLUSTER_NAME" > "$ROSA_CREATE_DIR/cluster-admin.txt" 2>&1
    
    echo ""
    echo "ROSA STS cluster '$CLUSTER_NAME' created successfully!"
    echo "Cluster information saved to: $ROSA_CREATE_DIR/"
    echo ""
    echo "To access the cluster:"
    echo "1. Check cluster-admin credentials: cat $ROSA_CREATE_DIR/cluster-admin.txt"
    echo "2. Use 'rosa describe cluster --cluster $CLUSTER_NAME' for cluster details"
    echo "3. Use 'use-rosa-sts-$ARCH_SUFFIX' to configure kubectl access"
    
    # Cleanup
    [[ -n "$PROCEED_WITH_EXISTING_CLUSTERS" ]] && unset PROCEED_WITH_EXISTING_CLUSTERS
}

znap function create-rosa-sts-arm64() {
    # ARM64 wrapper function
    create-rosa-sts "$1" "arm64"
}

znap function create-rosa-sts-amd64() {
    # AMD64 wrapper function
    create-rosa-sts "$1" "amd64"
}