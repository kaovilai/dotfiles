alias kubectl=oc
alias oc-login-crc='export KUBECONFIG=~/.crc/machines/crc/kubeconfig'
alias oc-registry-login='oc registry login'
alias oc-registry-route='oc get route -n openshift-image-registry default-route -o jsonpath={.spec.host}'
alias crc-kubeadminpass='cat ~/.crc/machines/crc/kubeadmin-password'
alias ocwebconsole='edge $(oc whoami --show-console)'
alias rosa-create-cluster='rosa create cluster --cluster-name tkaovila-sts --sts --create-admin-user --region us-east-1 --replicas 2 --machine-cidr 10.0.0.0/16 --service-cidr 172.30.0.0/16 --pod-cidr 10.128.0.0/14 --host-prefix 23 --disable-workload-monitoring && rosa create operator-roles --cluster tkaovila-sts && rosa create oidc-provider --cluster tkaovila-sts'
function patchCSVreplicas(){
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

function trustOCRouterCAFromFileInCurrentDir(){
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

function trustAPICAFromFileInCurrentDir(){
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
function openshift-patch-versions-arm64(){
    curl --silent https://openshift-release-artifacts-arm64.apps.ci.l2s4.p1.openshiftapps.com/ | grep -vE $OPENSHIFT_REJECT_VERSIONS_EXPRESSION | cut -d '"' -f 2 | sed "s/\///g" | grep -vE "<|>|en|utf|^$" | grep -ve "\.\." | sort -V | awk -F. '{if(!a[$1"."$2]++)print $1"."$2"."$NF}'
}
function openshift-patch-versions-amd64(){
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

function install-oc(){
    curl --silent https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-$ocpclientos-$ocpclientarch.tar.gz -o ~/Downloads/openshift-client-$ocpclientos-$ocpclientarch.tar.gz && \
    tar -xvf ~/Downloads/openshift-client-$ocpclientos-$ocpclientarch.tar.gz -C ~/Downloads && \
    sudo mv ~/Downloads/oc /usr/local/bin && \
    sudo mv ~/Downloads/kubectl /usr/local/bin && \
    rm ~/Downloads/openshift-client-$ocpclientos-$ocpclientarch.tar.gz
    rm ~/Downloads/README.md
}

function install-ocp-installer(){
    curl --silent https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-install-$ocpclientos-$ocpclientarch.tar.gz -o ~/Downloads/openshift-install-$ocpclientos-$ocpclientarch.tar.gz && \
    tar -xvf ~/Downloads/openshift-install-$ocpclientos-$ocpclientarch.tar.gz -C ~/Downloads && \
    sudo mv ~/Downloads/openshift-install /usr/local/bin
    rm ~/Downloads/openshift-install-$ocpclientos-$ocpclientarch.tar.gz
    rm ~/Downloads/README.md
}

function install-ccoctl(){
    go install github.com/openshift/cloud-credential-operator/cmd/ccoctl@release-$(latest-openshift-minor-version-arm64)
}

function install-opm(){
    go install github.com/operator-framework/operator-registry/cmd/opm@latest
}
# directory containing the manifests for many clusters
OCP_MANIFESTS_DIR=~/OCP/manifests
TODAY=$(date +%Y%m%d)
# create a cluster with gcp workload identity using CCO manual mode
# pre-req: ssh-add ~/.ssh/id_rsa
function create-ocp-gcp-wif(){
    # openshift-install create install-config --dir $OCP_MANIFESTS_DIR/$TODAY-gcp-wif --log-level debug
    # https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html-single/installing_on_gcp/index#cco-ccoctl-configuring_installing-gcp-customizations
    # prompt and remove if exists already so user can interrupt if uninstall is needed.
    OCP_CREATE_DIR=$OCP_MANIFESTS_DIR/$TODAY-gcp-wif
    CLUSTER_NAME=tkaovila-$TODAY-wif #max 21 char allowed
    if [[ $1 == "gather" ]]; then
        openshift-install gather bootstrap --dir $OCP_CREATE_DIR || return 1
        return 0
    fi
    if [[ $1 != "no-delete" ]]; then
        openshift-install destroy cluster --dir $OCP_CREATE_DIR || echo "no existing cluster"
        openshift-install destroy bootstrap --dir $OCP_CREATE_DIR || echo "no existing bootstrap"
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
RELEASE_IMAGE=$(openshift-install version | awk '/release image/ {print $3}')
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
openshift-install create manifests --dir $OCP_CREATE_DIR || return 1
cp $OCP_CREATE_DIR/credentials-requests/* $OCP_CREATE_DIR/manifests/ || return 1 # copy cred requests to manifests dir, ccoctl delete will delete cred requests in separate dir
openshift-install create cluster --dir $OCP_CREATE_DIR \
    --log-level=info || openshift-install gather bootstrap --dir $OCP_CREATE_DIR || return 1
}

function delete-ocp-gcp-wif(){
    OCP_CREATE_DIR=$OCP_MANIFESTS_DIR/$TODAY-gcp-wif
    CLUSTER_NAME=tkaovila-$TODAY-wif
    if [[ -n $1 ]]; then
        CLUSTER_NAME=$1
    fi
    openshift-install destroy cluster --dir $OCP_CREATE_DIR || echo "no existing cluster"
    openshift-install destroy bootstrap --dir $OCP_CREATE_DIR || echo "no existing bootstrap"
    (ccoctl gcp delete \
    --name $CLUSTER_NAME \
    --project $GCP_PROJECT_ID \
    --credentials-requests-dir $OCP_CREATE_DIR/credentials-requests && echo "cleaned up ccoctl gcp resources") || true
    ((rm -r $OCP_CREATE_DIR && echo "removed existing create dir") || (true && echo "no existing install dir")) || return 1
}
