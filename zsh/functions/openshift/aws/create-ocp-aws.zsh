znap function create-ocp-aws() {
    # Core implementation for AWS OpenShift cluster creation
    # Parameters:
    #   $1 - Command/option (help, gather, delete, no-delete)
    #   $2 - Architecture (arm64 or amd64)
    
    # Use specified openshift-install or default to 4.19.0-ec.4
    local OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-openshift-install-4.19.0-ec.4}
    local ARCHITECTURE=$2
    local ARCH_SUFFIX=${2}
    
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: create-ocp-aws-$ARCH_SUFFIX [OPTION]"
        echo "Create an OpenShift cluster on AWS using $ARCHITECTURE architecture"
        echo ""
        echo "Options:"
        echo "  help      Display this help message"
        echo "  gather    Gather bootstrap logs from the installation directory"
        echo "  delete    Just delete the cluster without recreating it"
        echo "  no-delete Skip deletion of existing cluster before creation"
        echo ""
        echo "Prerequisites:"
        echo "  - AWS_REGION environment variable (defaults to us-east-1 if not set)"
        echo "  - AWS_BASEDOMAIN environment variable (defaults to mg.dog8code.com if not set)"
        echo "  - AWS credentials must be configured"
        echo "  - SSH key must be added to the agent (ssh-add ~/.ssh/id_rsa)"
        echo "  - Pull secret must exist at ~/pull-secret.txt"
        echo ""
        echo "Directory:"
        echo "  Installation files will be created in: $OCP_MANIFESTS_DIR/$TODAY-aws-$ARCH_SUFFIX"
        return 0
    fi
    
    # Set default values for AWS_REGION and AWS_BASEDOMAIN if not already set
    if [[ -z "$AWS_REGION" ]]; then
        echo "INFO: AWS_REGION not set, defaulting to us-east-1"
        AWS_REGION="us-east-1"
    fi
    
    if [[ -z "$AWS_BASEDOMAIN" ]]; then
        echo "INFO: AWS_BASEDOMAIN not set, defaulting to mg.dog8code.com"
        AWS_BASEDOMAIN="mg.dog8code.com"
    fi
    
    # Verify that the requested architecture is supported by the installer
    if ! $OPENSHIFT_INSTALL version | grep -q "release architecture $ARCHITECTURE"; then
        echo "WARN: $ARCHITECTURE architecture not supported in current release payload"
        echo "WARN: To use $ARCHITECTURE, you need an openshift-install binary built for $ARCHITECTURE"
        echo "WARN: Run 'openshift-install version' to check if 'release architecture $ARCHITECTURE' is present"
        return 1
    else
        echo "INFO: Using $ARCHITECTURE architecture for cluster nodes (supported by current release payload)"
    fi
    
    OCP_CREATE_DIR=$OCP_MANIFESTS_DIR/$TODAY-aws-$ARCH_SUFFIX
    CLUSTER_NAME=tkaovila-$TODAY-$ARCH_SUFFIX #max 21 char allowed
    
    if [[ $1 == "gather" ]]; then
        $OPENSHIFT_INSTALL gather bootstrap --dir $OCP_CREATE_DIR || return 1
        return 0
    fi
    
    if [[ $1 != "no-delete" ]]; then
        $OPENSHIFT_INSTALL destroy cluster --dir $OCP_CREATE_DIR || echo "no existing cluster"
        $OPENSHIFT_INSTALL destroy bootstrap --dir $OCP_CREATE_DIR || echo "no existing bootstrap"
        ((rm -r $OCP_CREATE_DIR && echo "removed existing create dir") || (true && echo "no existing install dir")) || return 1
    fi
    
    # if param is delete then stop here
    if [[ $1 == "delete" ]]; then
        return 0
    fi
    
    # Check for existing clusters before proceeding
    check-for-existing-clusters "aws" "$ARCH_SUFFIX" || return 1
    
    mkdir -p $OCP_CREATE_DIR && \
    echo "additionalTrustBundlePolicy: Proxyonly
apiVersion: v1
baseDomain: $AWS_BASEDOMAIN
compute:
- architecture: $ARCHITECTURE
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 3
controlPlane:
  architecture: $ARCHITECTURE
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: 3
metadata:
  creationTimestamp: null
  name: $CLUSTER_NAME
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: $AWS_REGION
publish: External
pullSecret: '$(cat ~/pull-secret.txt)'
sshKey: |
  $(cat ~/.ssh/id_rsa.pub)
" > $OCP_CREATE_DIR/install-config.yaml && echo "created install-config.yaml" || return 1
    
    $OPENSHIFT_INSTALL create manifests --dir $OCP_CREATE_DIR || return 1
    # Use the custom release image
    OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$OCP_FUNCTIONS_RELEASE_IMAGE \
    $OPENSHIFT_INSTALL create cluster --dir $OCP_CREATE_DIR \
        --log-level=info || $OPENSHIFT_INSTALL gather bootstrap --dir $OCP_CREATE_DIR || return 1
}

znap function create-ocp-aws-arm64() {
    # ARM64 wrapper function
    create-ocp-aws "$1" "arm64"
}

znap function create-ocp-aws-amd64() {
    # AMD64 wrapper function
    create-ocp-aws "$1" "amd64"
}
