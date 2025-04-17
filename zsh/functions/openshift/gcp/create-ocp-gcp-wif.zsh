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
    
    # Check for existing clusters before proceeding
    check-for-existing-clusters "gcp" || return 1
    
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
