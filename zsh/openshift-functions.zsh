# set kubectl edit to use vscode
export EDITOR="code -w"
alias kubectl=oc
alias oc-login-crc='export KUBECONFIG=~/.crc/machines/crc/kubeconfig'
alias oc-registry-login='oc registry login'
alias oc-registry-route='oc get route -n openshift-image-registry default-route -o jsonpath={.spec.host}'
alias crc-kubeadminpass='cat ~/.crc/machines/crc/kubeadmin-password'
alias ocwebconsole='edge $(oc whoami --show-console)'
alias rosa-create-cluster='rosa create cluster --cluster-name tkaovila-sts --sts --create-admin-user --region us-east-1 --replicas 2 --machine-cidr 10.0.0.0/16 --service-cidr 172.30.0.0/16 --pod-cidr 10.128.0.0/14 --host-prefix 23 --disable-workload-monitoring && rosa create operator-roles --cluster tkaovila-sts && rosa create oidc-provider --cluster tkaovila-sts'
znap function patchCSVreplicas(){
    if [ -z "$1" ]; then
        echo "No CSV name supplied"
        return 1
    fi
    if [ -z "$2" ]; then
        echo "No replicas supplied"
        return 1
    fi
    oc patch csv $1 --type='json' -p '[
  {
    "op": "replace",
    "path": "/spec/install/spec/deployments/0/spec/replicas",
    "value": '$2'
  }
]
'
}

alias oc-run='oc run --rm -it --image'
znap function agdKubeAdminPassword(){
 if [$1 = ""]; then 
  echo "No GUID supplied"
  return 1
 else
  echo "parsing guid $1"
  cat "~/.agnosticd/$1/ocp4-cluster_$1_kubeadmin-password"
 fi
}

znap function getOCrouterCA(){
    echo "Getting Ingress Router CA for server"
    oc whoami --show-server
    oc get secret router-ca -n openshift-ingress-operator -ojsonpath="{.data['tls\.crt']}" | base64 --decode > router-ca.crt
}

znap function rmRouterCA(){
    echo "Removing Ingress Router CA"
    rm router-ca.crt
}

znap function trustOCRouterCAFromFileInCurrentDir(){
    if uname -s | grep -q Darwin; then
        echo "Mac OS detected, trusting oc router ca"
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain router-ca.crt
    else
        echo "Linux detected, trusting oc router ca"
        sudo add-trusted-cert -d -r trustRoot -k /etc/ssl/certs/ca-certificates.crt router-ca.crt
    fi
}

znap function trustOCRouterCA(){
    getOCrouterCA
    trustOCRouterCAFromFileInCurrentDir
    rmRouterCA
}

znap function getAPICA(){
    echo "Getting API CA for server"
    oc whoami --show-server
    # oc get secret router-certs-default -n openshift-ingress -ojsonpath="{.data['tls\.crt']}" | base64 --decode > api-ca.crt
    oc get secret kube-apiserver-to-kubelet-signer -n openshift-kube-apiserver-operator -ojsonpath="{.data['tls\.crt']}" | base64 --decode > api-ca.crt
}

znap function rmAPICA(){
    echo "Removing API CA"
    rm api-ca.crt
}

znap function trustAPICAFromFileInCurrentDir(){
    if uname -s | grep -q Darwin; then
        echo "Mac OS detected"
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain api-ca.crt
    else
        echo "Linux detected"
        sudo add-trusted-cert -d -r trustRoot -k /etc/ssl/certs/ca-certificates.crt api-ca.crt
    fi
}

znap function trustAPICA(){
    getAPICA
    trustAPICAFromFileInCurrentDir
    rmAPICA
}

znap function installClusterOpenshiftInstall(){
    [ $(command -v openshift-install-official) ] || [ $(command -v openshift-install) ] || {
        echo "openshift-install-official or openshift-install not found"
        return 1
    }

    [ $(command -v openshift-install-official) ] && OC_INSTALLER=openshift-install-official || OC_INSTALLER=openshift-install
    echo "Using $OC_INSTALLER"
    [ -f ~/install-config.yaml ] || {
        echo "install-config.yaml not found in home dir"
        echo "Please create one using the ${RED}openshift-install create install-config${NC} command"
        return 1
    }
    [ $(command -v yq) ] || {
        echo "yq not found"
        echo "Please install yq"
        return 1
    }
    # current date/time ie. apr7-1158
    # update metadata.name to tkaovila-$DATE
    DATE=$(date +%b%d-%H%M)
    # lowercase the date
    DATE=$(echo $DATE | tr '[:upper:]' '[:lower:]')
    mkdir -p ~/clusters/$DATE && \
    echo "Installing into dir ~/clusters/$DATE" && \
    cp ~/install-config.yaml ~/clusters/$DATE/ && \
    yq -i ".metadata.name=\"tkaovila-$DATE\"" ~/clusters/$DATE/install-config.yaml && \
    $OC_INSTALLER version && \
    $OC_INSTALLER create cluster --dir ~/clusters/$DATE
}

# cp KUBECONFIG to ~/.kube/config
znap function copyKUBECONFIG() {
    [ -f $KUBECONFIG ] || {
        echo "KUBECONFIG not set"
        return 1
    }
    [ -f $KUBECONFIG ] && {
        echo "KUBECONFIG set to $KUBECONFIG"
        echo "Copying to ~/.kube/config"
        cp $KUBECONFIG ~/.kube/config
    }
}

znap function watchAllPodLogsInNamespace(){
    if [ -z "$1" ]; then
        echo "No namespace supplied"
        return 1
    fi
    oc get pods -n $1 -o name | xargs -n 1 -P 100 oc logs -f -n $1
}

znap function watchAllPodErrorsInNamespace(){
    if [ -z "$1" ]; then
        echo "No namespace supplied"
        return 1
    fi
    # get all pod logs in namespace, grep for error, and prefix with pod name
    oc get pods -n $1 -o name | xargs -n 1 -P 100 -I {} sh -c "oc logs -n $1 -f {} | grep --line-buffered error | sed \"s#^#{}: #\""
}

znap function crc-start-version(){
    # check X.Y.Z version is specified
    if [ -z "$1" ]; then
        echo "No version supplied, try 2.43.0 or check https://github.com/crc-org/crc/releases"
        return 1
    fi
    # check version is semver
    if ! [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Version $1 is not semver"
        return 1
    fi
    # if running
    if [[ $(crc status --output json | jq --raw-output .openshiftStatus) = "Running" ]]; then
    # exit if version matching already
        if [[ $(crc version --output json 2> /dev/null | jq --raw-output .version) =  $1 ]]; then
            echo already requested version and running
            return 0
        fi
    fi
    # if not stopped
    if ! [[ $(crc status --output json | jq --raw-output .openshiftStatus) = "Stopped" ]]; then
        echo stopping and cleanup.
        crc stop; crc delete -f; crc cleanup;
    fi
    # install/upgrade if version mismatched
    if ! [[ $(crc version --output json 2> /dev/null | jq --raw-output .version) =  $1 ]]; then
        (cat ~/Downloads/$1-crc.pkg >/dev/null || curl https://developers.redhat.com/content-gateway/file/pub/openshift-v4/clients/crc/$1/crc-macos-installer.pkg -L -o ~/Downloads/$1-crc.pkg) && sudo installer -pkg ~/Downloads/$1-crc.pkg -target LocalSystem
    fi
    crc version && crc setup && crc start --log-level debug && crc status --log-level debug
}

export OPENSHIFT_REJECT_VERSIONS_EXPRESSION="nightly|rc|fc|ci|ec"
znap function openshift-patch-versions-arm64(){
    curl --silent https://openshift-release-artifacts-arm64.apps.ci.l2s4.p1.openshiftapps.com/ | grep -vE $OPENSHIFT_REJECT_VERSIONS_EXPRESSION | cut -d '"' -f 2 | sed "s/\///g" | grep -vE "<|>|en|utf|^$" | grep -ve "\.\." | sort -V | awk -F. '{if(!a[$1"."$2]++)print $1"."$2"."$NF}'
}
znap function openshift-patch-versions-amd64(){
    curl --silent https://openshift-release-artifacts.apps.ci.l2s4.p1.openshiftapps.com/ | grep -vE $OPENSHIFT_REJECT_VERSIONS_EXPRESSION | cut -d '"' -f 2 | sed "s/\///g" | grep -vE "<|>|en|utf|^$" | grep -ve "\.\." | sort -V | awk -F. '{if(!a[$1"."$2]++)print $1"."$2"."$NF}'
}
alias latest-openshift-patch-version-arm64="openshift-patch-versions-arm64 | tail -n 1"
alias latest-openshift-patch-version-amd64="openshift-patch-versions-amd64 | tail -n 1"
alias latest-openshift-minor-version-arm64="openshift-patch-versions-arm64 | tail -n 1 | cut -d '.' -f 1,2"

if [ -n "$(command -v sw_vers)" ]; then
    ocpclientos='mac'
    ocpclientarch=$(arch)
else
    if [ -n $(command -v lsb_release) ]; then
        ocpclientos='linux'
        ocpclientarch=$(dpkg --print-architecture)
    else
        echo "openshift-functions.zsh: Unknown OS"
    fi
fi

znap function install-oc(){
    curl --silent https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-$ocpclientos-$ocpclientarch.tar.gz -o ~/Downloads/openshift-client-$ocpclientos-$ocpclientarch.tar.gz && \
    tar -xvf ~/Downloads/openshift-client-$ocpclientos-$ocpclientarch.tar.gz -C ~/Downloads && \
    sudo mv ~/Downloads/oc /usr/local/bin && \
    sudo mv ~/Downloads/kubectl /usr/local/bin && \
    rm ~/Downloads/openshift-client-$ocpclientos-$ocpclientarch.tar.gz
    rm ~/Downloads/README.md
}

znap function install-ocp-installer(){
    curl --silent https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-install-$ocpclientos-$ocpclientarch.tar.gz -o ~/Downloads/openshift-install-$ocpclientos-$ocpclientarch.tar.gz && \
    tar -xvf ~/Downloads/openshift-install-$ocpclientos-$ocpclientarch.tar.gz -C ~/Downloads && \
    sudo mv ~/Downloads/openshift-install /usr/local/bin
    rm ~/Downloads/openshift-install-$ocpclientos-$ocpclientarch.tar.gz
    rm ~/Downloads/README.md
}

znap function install-ccoctl(){
    go install github.com/openshift/cloud-credential-operator/cmd/ccoctl@release-$(latest-openshift-minor-version-arm64)
}

znap function install-opm(){
    go install github.com/operator-framework/operator-registry/cmd/opm@latest
}
# Define release payload for OpenShift installations
OCP_FUNCTIONS_RELEASE_IMAGE=registry.ci.openshift.org/origin/release:4.19
# directory containing the manifests for many clusters
OCP_MANIFESTS_DIR=~/OCP/manifests
TODAY=$(date +%Y%m%d)
# create a cluster with gcp workload identity using CCO manual mode
# pre-req: ssh-add ~/.ssh/id_rsa
znap function create-ocp-gcp-wif(){
    # Use specified openshift-install or default to 4.19.0-ec.4
    local OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-openshift-install-4.19.0-ec.4}

    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: create-ocp-gcp-wif [OPTION]"
        echo "Create an OpenShift cluster on GCP with Workload Identity Federation"
        echo ""
        echo "Options:"
        echo "  help      Display this help message"
        echo "  gather    Gather bootstrap logs from the installation directory"
        echo "  delete    Just delete the cluster without recreating it"
        echo "  no-delete Skip deletion of existing cluster before creation"
        echo ""
        echo "Prerequisites:"
        echo "  - GCP_PROJECT_ID environment variable must be set"
        echo "  - GCP_REGION environment variable must be set"
        echo "  - GCP_BASEDOMAIN environment variable must be set"
        echo "  - SSH key must be added to the agent (ssh-add ~/.ssh/id_rsa)"
        echo "  - Pull secret must exist at ~/pull-secret.txt"
        echo ""
        echo "Directory:"
        echo "  Installation files will be created in: $OCP_MANIFESTS_DIR/$TODAY-gcp-wif"
        return 0
    fi
    
    # openshift-install create install-config --dir $OCP_MANIFESTS_DIR/$TODAY-gcp-wif --log-level debug
    # https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html-single/installing_on_gcp/index#cco-ccoctl-configuring_installing-gcp-customizations
    # prompt and remove if exists already so user can interrupt if uninstall is needed.
    OCP_CREATE_DIR=$OCP_MANIFESTS_DIR/$TODAY-gcp-wif
    CLUSTER_NAME=tkaovila-$TODAY-wif #max 21 char allowed
    if [[ $1 == "gather" ]]; then
        $OPENSHIFT_INSTALL gather bootstrap --dir $OCP_CREATE_DIR || return 1
        return 0
    fi
    if [[ $1 != "no-delete" ]]; then
        $OPENSHIFT_INSTALL destroy cluster --dir $OCP_CREATE_DIR || echo "no existing cluster"
        $OPENSHIFT_INSTALL destroy bootstrap --dir $OCP_CREATE_DIR || echo "no existing bootstrap"
        (ccoctl gcp delete \
        --name $CLUSTER_NAME \
        --project $GCP_PROJECT_ID \
        --credentials-requests-dir $OCP_CREATE_DIR/credentials-requests && echo "cleaned up ccoctl gcp resources") || true
        ((rm -r $OCP_CREATE_DIR && echo "removed existing create dir") || (true && echo "no existing install dir")) || return 1
    fi
    # if param is delete then stop here
    if [[ $1 == "delete" ]]; then
        return 0
    fi
    mkdir -p $OCP_CREATE_DIR && \
    echo "additionalTrustBundlePolicy: Proxyonly
apiVersion: v1
baseDomain: $GCP_BASEDOMAIN
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 3
controlPlane:
  architecture: amd64
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
  gcp:
    projectID: $GCP_PROJECT_ID
    region: $GCP_REGION
publish: External
credentialsMode: Manual # needed for WIF at the time of prior writing at https://github.com/openshift/oadp-operator/wiki/GCP-WIF-Authentication-on-OpenShift
pullSecret: '$(cat ~/pull-secret.txt)'
sshKey: |
  $(cat ~/.ssh/id_rsa.pub)
" > $OCP_CREATE_DIR/install-config.yaml && echo "created install-config.yaml" || return 1
# Set a $RELEASE_IMAGE variable with the release image from your installation file by running the following command:
RELEASE_IMAGE=$($OPENSHIFT_INSTALL version | awk '/release image/ {print $3}')
# Extract the list of CredentialsRequest custom resources (CRs) from the OpenShift Container Platform release image by running the following command:
echo "extracting credential-requests" && oc adm release extract \
  --from=$RELEASE_IMAGE \
  --credentials-requests \
  --included \
  --install-config=$OCP_CREATE_DIR/install-config.yaml \
  --to=$OCP_CREATE_DIR/credentials-requests || return 1 #credential requests are stored in credentials-requests dir
ccoctl gcp create-all \
--name $CLUSTER_NAME \
--project $GCP_PROJECT_ID \
--region $GCP_REGION \
--output-dir $OCP_CREATE_DIR \
--credentials-requests-dir $OCP_CREATE_DIR/credentials-requests || return 1
    $OPENSHIFT_INSTALL create manifests --dir $OCP_CREATE_DIR || return 1
    cp $OCP_CREATE_DIR/credentials-requests/* $OCP_CREATE_DIR/manifests/ || return 1 # copy cred requests to manifests dir, ccoctl delete will delete cred requests in separate dir
    # Use the custom release image
    OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$OCP_FUNCTIONS_RELEASE_IMAGE \
    $OPENSHIFT_INSTALL create cluster --dir $OCP_CREATE_DIR \
        --log-level=info || $OPENSHIFT_INSTALL gather bootstrap --dir $OCP_CREATE_DIR || return 1
}

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

# List all installed OpenShift clusters
znap function list-ocp-clusters() {
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: list-ocp-clusters [OPTIONS]"
        echo "List all installed OpenShift clusters"
        echo ""
        echo "Options:"
        echo "  help     Display this help message"
        echo "  --full   Show full path to auth directory and kubeconfig"
        echo ""
        echo "This function searches for OpenShift clusters in the following locations:"
        echo "  - $OCP_MANIFESTS_DIR (AWS and GCP installations)"
        echo "  - ~/clusters (using installClusterOpenshiftInstall function)"
        echo "  - ~/.crc/machines/crc (CodeReady Containers)"
        echo ""
        return 0
    fi

    local show_full=false
    if [[ "$1" == "--full" ]]; then
        show_full=true
    fi
    
    echo "=== OpenShift Clusters ==="
    echo ""
    
    # Check AWS and GCP cluster directories
    if [ -d "$OCP_MANIFESTS_DIR" ]; then
        echo "AWS/GCP Clusters:"
        local count=0
        
        # Find all directories with auth/kubeconfig files
        for dir in $(find $OCP_MANIFESTS_DIR -type d -name "auth" 2>/dev/null | sort); do
            if [[ -f "$dir/kubeconfig" ]]; then
                local cluster_dir=$(dirname "$dir")
                local cluster_name=$(basename "$cluster_dir")
                count=$((count+1))
                
                if [ "$show_full" = true ]; then
                    echo "$count. $cluster_name: $dir/kubeconfig"
                else
                    echo "$count. $cluster_name"
                fi
            fi
        done
        
        if [ $count -eq 0 ]; then
            echo "   No AWS/GCP clusters found"
        fi
        echo ""
    fi
    
    # Check local clusters directory
    if [ -d "$HOME/clusters" ]; then
        echo "Local Clusters:"
        local count=0
        
        # Find all directories with auth/kubeconfig files
        for dir in $(find $HOME/clusters -type d -name "auth" 2>/dev/null | sort); do
            if [[ -f "$dir/kubeconfig" ]]; then
                local cluster_dir=$(dirname "$dir")
                local cluster_name=$(basename "$cluster_dir")
                count=$((count+1))
                
                if [ "$show_full" = true ]; then
                    echo "$count. $cluster_name: $dir/kubeconfig"
                else
                    echo "$count. $cluster_name"
                fi
            fi
        done
        
        if [ $count -eq 0 ]; then
            echo "   No local clusters found"
        fi
        echo ""
    fi
    
    # Check CRC
    if [ -f "$HOME/.crc/machines/crc/kubeconfig" ]; then
        echo "CodeReady Containers:"
        if [ "$show_full" = true ]; then
            echo "1. crc: $HOME/.crc/machines/crc/kubeconfig"
        else
            echo "1. crc"
        fi
        echo ""
    else
        echo "CodeReady Containers: Not installed"
        echo ""
    fi
}

# Set KUBECONFIG to a cluster
znap function use-ocp-cluster() {
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        echo "Usage: use-ocp-cluster [PATTERN]"
        echo "Set KUBECONFIG to a selected cluster"
        echo ""
        echo "Parameters:"
        echo "  PATTERN  Optional search pattern to filter clusters"
        echo "           If omitted, will show all available clusters"
        echo ""
        echo "This function searches for OpenShift clusters and prompts you to select one,"
        echo "then sets the KUBECONFIG environment variable to the selected cluster's kubeconfig."
        echo ""
        return 0
    fi

    local search_pattern=$1
    local kubeconfig_files=()
    local cluster_names=()
    
    # Find all AWS/GCP clusters
    if [ -d "$OCP_MANIFESTS_DIR" ]; then
        for dir in $(find $OCP_MANIFESTS_DIR -type d -name "auth" 2>/dev/null | sort); do
            if [[ -f "$dir/kubeconfig" ]]; then
                local cluster_dir=$(dirname "$dir")
                local cluster_name=$(basename "$cluster_dir")
                
                # Apply pattern filter if provided
                if [[ -z $search_pattern || $cluster_name == *$search_pattern* ]]; then
                    kubeconfig_files+=("$dir/kubeconfig")
                    cluster_names+=("$cluster_name (AWS/GCP)")
                fi
            fi
        done
    fi
    
    # Find all local clusters
    if [ -d "$HOME/clusters" ]; then
        for dir in $(find $HOME/clusters -type d -name "auth" 2>/dev/null | sort); do
            if [[ -f "$dir/kubeconfig" ]]; then
                local cluster_dir=$(dirname "$dir")
                local cluster_name=$(basename "$cluster_dir")
                
                # Apply pattern filter if provided
                if [[ -z $search_pattern || $cluster_name == *$search_pattern* ]]; then
                    kubeconfig_files+=("$dir/kubeconfig")
                    cluster_names+=("$cluster_name (Local)")
                fi
            fi
        done
    fi
    
    # Check CRC
    if [[ -f "$HOME/.crc/machines/crc/kubeconfig" ]]; then
        if [[ -z $search_pattern || "crc" == *$search_pattern* ]]; then
            kubeconfig_files+=("$HOME/.crc/machines/crc/kubeconfig")
            cluster_names+=("crc (CodeReady Containers)")
        fi
    fi
    
    # If no clusters found
    if [[ ${#kubeconfig_files[@]} -eq 0 ]]; then
        echo "No OpenShift clusters found"
        if [[ -n $search_pattern ]]; then
            echo "Try without a search pattern or check if your clusters exist"
        fi
        return 1
    fi
    
    # If only one cluster found, use it directly
    if [[ ${#kubeconfig_files[@]} -eq 1 ]]; then
        export KUBECONFIG="${kubeconfig_files[0]}"
        echo "Using cluster: ${cluster_names[0]}"
        echo "KUBECONFIG set to: $KUBECONFIG"
        return 0
    fi
    
    # Show selection menu
    echo "Available clusters:"
    for i in $(seq 1 ${#kubeconfig_files[@]}); do
        echo "$i. ${cluster_names[$i-1]}"
    done
    
    # Prompt for selection
    echo ""
    read "choice?Enter cluster number (1-${#kubeconfig_files[@]}): "
    
    # Validate choice
    if [[ ! $choice =~ ^[0-9]+$ || $choice -lt 1 || $choice -gt ${#kubeconfig_files[@]} ]]; then
        echo "Invalid selection"
        return 1
    fi
    
    # Set KUBECONFIG
    export KUBECONFIG="${kubeconfig_files[$choice-1]}"
    echo "Using cluster: ${cluster_names[$choice-1]}"
    echo "KUBECONFIG set to: $KUBECONFIG"
    
    # Offer to copy to ~/.kube/config as well
    echo ""
    read "copy?Copy to ~/.kube/config? (y/n): "
    if [[ $copy == "y" || $copy == "Y" ]]; then
        mkdir -p ~/.kube
        cp "$KUBECONFIG" ~/.kube/config
        echo "Copied to ~/.kube/config"
    fi
}
