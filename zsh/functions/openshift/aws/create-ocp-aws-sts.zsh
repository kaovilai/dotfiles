# Create an AWS OpenShift cluster with STS (CCO manual mode via ccoctl aws),
# mirroring create-ocp-azure-sts/create-ocp-gcp-wif's ccoctl pattern but
# keeping create-ocp-aws.zsh's arch/--kvm/--install-cnv feature parity.
# pre-req: ssh-add ~/.ssh/id_rsa, ccoctl in PATH
create-ocp-aws-sts() {
    # Unset SSH_AUTH_SOCK on Darwin systems to avoid SSH errors
    if [[ "$(uname)" == "Darwin" ]]; then
        unset SSH_AUTH_SOCK
    fi

    # Detect host architecture for cross-arch support (same as create-ocp-aws)
    local HOST_ARCH=""
    case "$(uname -m)" in
        "x86_64"|"amd64")
            HOST_ARCH="amd64"
            ;;
        "arm64"|"aarch64")
            HOST_ARCH="arm64"
            ;;
        *)
            echo "ERROR: Unsupported host architecture: $(uname -m)"
            return 1
            ;;
    esac

    local ARCHITECTURE=${2:-$HOST_ARCH}
    local ARCH_SUFFIX=$ARCHITECTURE

    local USE_MULTI_ARCH="false"
    if [[ "$HOST_ARCH" != "$ARCHITECTURE" ]]; then
        echo "INFO: Cross-architecture deployment detected (host: $HOST_ARCH, target: $ARCHITECTURE)"
        echo "INFO: Will use multi-arch release image to support $ARCHITECTURE clusters"
        USE_MULTI_ARCH="true"
    fi

    # Check if help is requested (before expensive get-openshift-install)
    if [[ $1 == "help" ]]; then
        echo "Usage: create-ocp-aws-sts-$ARCH_SUFFIX [OPTION] [FLAGS]"
        echo "Create an OpenShift cluster on AWS with STS (CCO manual mode via ccoctl)"
        echo ""
        echo "Options:"
        echo "  help        Display this help message"
        echo "  gather      Gather bootstrap logs from the installation directory"
        echo "  delete      Just delete the cluster without recreating it"
        echo "  no-delete   Skip deletion of existing cluster before creation"
        echo ""
        echo "Flags (can be combined):"
        echo "  --force-new Force creation alongside existing clusters (skip prompt)"
        echo "  --ec        Automatically select Early Candidate release stream"
        echo "  --verify-all-signatures"
        echo "              With --ec, check every image in the release payload for a"
        echo "              published signature instead of just rhel-coreos (slower, ~10-20s)"
        echo "  --allow-unsigned"
        echo "              With --ec, if the signature preflight check finds a missing"
        echo "              signature, auto-disable ClusterImagePolicy enforcement (same as"
        echo "              --nightly) and continue instead of prompting/aborting"
        echo "  --kvm       Add a second compute pool with a bare-metal instance type (day-2)"
        echo "              (exposes /dev/kvm for OpenShift Virtualization/KubeVirt VMs)"
        echo "  --kvm-spot  Same as --kvm, but request the metal node as a spot instance"
        echo "  --kvm-all-workers"
        echo "              Set the whole worker pool to a bare-metal instance type at install"
        echo "              time (matches Red Hat's documented method). Mutually exclusive with"
        echo "              --kvm/--kvm-spot."
        echo "  --install-cnv"
        echo "              Install OpenShift Virtualization (CNV/KubeVirt operator + a minimal"
        echo "              HyperConverged CR). Can be combined with --kvm/--kvm-spot or"
        echo "              --kvm-all-workers, or used alone."
        echo "  --community-hco[=TAG]"
        echo "              Install Community HCO (quay.io/kubevirt/hyperconverged-cluster-index)"
        echo "              instead of productized CNV. Implies --install-cnv. TAG defaults to"
        echo "              1.18.0."
        echo "  --nightly[=X.Y]"
        echo "              Use the raw per-minor-version OCP nightly release stream"
        echo "              (X.Y.0-0.nightly) instead of dev-preview/stable/--ec. Prompts for"
        echo "              the minor version if not given."
        echo ""
        echo "Examples:"
        echo "  create-ocp-aws-sts-$ARCH_SUFFIX --force-new --ec"
        echo "  create-ocp-aws-sts-$ARCH_SUFFIX no-delete --ec"
        echo "  create-ocp-aws-sts-$ARCH_SUFFIX --ec --kvm"
        echo ""
        echo "Prerequisites:"
        echo "  - AWS_REGION environment variable (defaults to us-east-1 if not set)"
        echo "  - AWS_BASEDOMAIN environment variable (defaults to mg.dog8code.com if not set)"
        echo "  - AWS credentials must be configured, with permissions to create/delete IAM"
        echo "    roles/OIDC providers and S3 buckets (ccoctl aws create-all/delete)"
        echo "  - ccoctl must be installed (install-ccoctl)"
        echo "  - SSH key must be added to the agent (ssh-add ~/.ssh/id_rsa)"
        echo "  - Pull secret must exist at ~/pull-secret.txt"
        echo "  - OCP_WORKER_INSTANCE_TYPE / OCP_CONTROLPLANE_INSTANCE_TYPE: same overrides as"
        echo "    create-ocp-aws (see 'create-ocp-aws help')"
        echo ""
        echo "Directory:"
        echo "  Installation files will be created in: $OCP_MANIFESTS_DIR/$TODAY-aws-sts-$ARCH_SUFFIX"
        echo ""
        echo "Note:"
        echo "  When creating clusters alongside existing ones (option 3), a unique"
        echo "  name will be generated by adding a suffix (e.g., -1, -2) to avoid conflicts"
        echo "  The --force-new flag automatically selects option 3 when existing clusters are found"
        echo "  The --ec flag automatically selects the Early Candidate release stream"
        return 0
    fi

    # Get openshift-install binary
    local OPENSHIFT_INSTALL=$(get-openshift-install)
    [[ -z "$OPENSHIFT_INSTALL" ]] && return 1
    $OPENSHIFT_INSTALL version

    # Verify ccoctl is available (needed for AWS STS credential management)
    if ! command -v ccoctl &>/dev/null; then
        echo "ERROR: ccoctl not found in PATH"
        echo "Install options:"
        echo "  - From source: install-ccoctl"
        echo "  - From release: curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/ccoctl-linux.tar.gz | tar xzf - -C /usr/local/bin ccoctl"
        return 1
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

    # Validate AWS credentials are configured
    if ! aws sts get-caller-identity &>/dev/null; then
        echo "ERROR: AWS credentials not configured. Please run 'aws configure' or set AWS credentials"
        return 1
    fi

    preflight-check-aws-permissions

    if [[ "$USE_MULTI_ARCH" == "true" ]]; then
        echo "INFO: Cross-architecture deployment - will use multi-arch release image"
    else
        echo "INFO: Native architecture deployment - will use $ARCHITECTURE-specific release image"
    fi

    # Safety check - ensure TODAY is not empty
    if [[ -z "$TODAY" ]]; then
        echo "WARNING: TODAY variable is empty, using current date"
        TODAY=$(date +%y%m%d)
    fi

    # Set initial cluster name and directory
    local CLUSTER_BASE_NAME="tkaovila-$TODAY-sts-$ARCH_SUFFIX"
    local OCP_CREATE_DIR_BASE="$OCP_MANIFESTS_DIR/$TODAY-aws-sts-$ARCH_SUFFIX"

    # Generate unique cluster name if needed
    local unique_result=$(generate-unique-cluster-name "$CLUSTER_BASE_NAME" "$OCP_CREATE_DIR_BASE")
    [[ -z "$unique_result" ]] && return 1
    local CLUSTER_NAME=$(echo "$unique_result" | grep "cluster_name:" | cut -d: -f2)
    local OCP_CREATE_DIR=$(echo "$unique_result" | grep "cluster_dir:" | cut -d: -f2)

    if [[ $1 == "gather" ]]; then
        if [[ -d "$OCP_CREATE_DIR" ]]; then
            $OPENSHIFT_INSTALL gather bootstrap --dir $OCP_CREATE_DIR || return 1
        else
            echo "Directory $OCP_CREATE_DIR does not exist, cannot gather bootstrap logs"
            return 1
        fi
        return 0
    fi

    if [[ $1 != "no-delete" ]]; then
        if [[ -d "$OCP_CREATE_DIR" ]]; then
            bash ~/.claude/skills/create-ocp/scripts/archive-logs.sh "$OCP_CREATE_DIR" 2>/dev/null || true
            $OPENSHIFT_INSTALL destroy cluster --dir $OCP_CREATE_DIR || echo "no existing cluster"
            $OPENSHIFT_INSTALL destroy bootstrap --dir $OCP_CREATE_DIR || echo "no existing bootstrap"
            (ccoctl aws delete \
            --name $CLUSTER_NAME \
            --region $AWS_REGION \
            --credentials-requests-dir $OCP_CREATE_DIR/credentials-requests && echo "cleaned up ccoctl aws resources") || true
            ((rm -r $OCP_CREATE_DIR && echo "removed existing create dir") || (true && echo "no existing install dir")) || return 1
        else
            echo "Directory $OCP_CREATE_DIR does not exist, nothing to delete"
        fi
    fi

    if [[ $1 == "delete" ]]; then
        return 0
    fi

    # Parse command line flags
    local force_new=false
    local auto_ec=false
    local add_kvm_pool=false
    local kvm_spot=false
    local kvm_all_workers=false
    local install_cnv=false
    local community_hco=false
    local community_hco_tag="1.18.0"
    local use_nightly=false
    local nightly_minor=""
    local verify_all_signatures=false
    local allow_unsigned=false

    for arg in "$@"; do
        case "$arg" in
            --force-new)
                force_new=true
                ;;
            --ec)
                auto_ec=true
                ;;
            --verify-all-signatures)
                verify_all_signatures=true
                ;;
            --allow-unsigned)
                allow_unsigned=true
                ;;
            --kvm)
                add_kvm_pool=true
                ;;
            --kvm-spot)
                add_kvm_pool=true
                kvm_spot=true
                ;;
            --kvm-all-workers)
                kvm_all_workers=true
                ;;
            --install-cnv)
                install_cnv=true
                ;;
            --community-hco)
                community_hco=true
                install_cnv=true
                ;;
            --community-hco=*)
                community_hco=true
                install_cnv=true
                community_hco_tag="${arg#--community-hco=}"
                ;;
            --nightly)
                use_nightly=true
                ;;
            --nightly=*)
                use_nightly=true
                nightly_minor="${arg#--nightly=}"
                ;;
        esac
    done

    if [[ "$kvm_all_workers" == "true" && "$add_kvm_pool" == "true" ]]; then
        echo "ERROR: --kvm-all-workers cannot be combined with --kvm or --kvm-spot (pick one metal strategy)" >&2
        return 1
    fi

    if [[ "$force_new" == "true" ]]; then
        export FORCE_NEW_CLUSTER="true"
    fi

    if [[ "$auto_ec" == "true" ]]; then
        export AUTO_SELECT_EC="true"
    fi

    # Check for existing clusters before proceeding
    check-for-existing-clusters "aws" "sts-$ARCH_SUFFIX" || return 1

    [[ -n "$FORCE_NEW_CLUSTER" ]] && unset FORCE_NEW_CLUSTER

    # Prompt for release stream selection and get release image
    local stream
    if [[ "$use_nightly" == "true" ]]; then
        if [[ -z "$nightly_minor" ]]; then
            nightly_minor=$(prompt-nightly-minor-version) || return 1
        fi
        export OCP_NIGHTLY_MINOR="$nightly_minor"
        stream="nightly"
        echo "INFO: --nightly requested: using raw ${nightly_minor}.0-0.nightly release stream"
        unset AUTO_SELECT_EC
    elif [[ -n "$OCP_RELEASE_VERSION" ]]; then
        if [[ "$OCP_RELEASE_VERSION" =~ (ec|rc)\. ]]; then
            stream="dev-preview"
        else
            stream="stable"
        fi
        echo "INFO: Using pre-set OCP_RELEASE_VERSION=$OCP_RELEASE_VERSION (stream=$stream)"
        unset AUTO_SELECT_EC
    elif [[ -n "$AUTO_SELECT_EC" ]]; then
        stream="4-dev-preview"
        echo "Automatically selecting Early Candidate release stream"
        unset AUTO_SELECT_EC
    else
        local stream_output=$(prompt-release-stream)
        stream=${stream_output%% *}
        local selected_version=${stream_output#* }
        if [[ "$selected_version" != "$stream" ]]; then
            export OCP_RELEASE_VERSION="$selected_version"
        fi
    fi

    local RELEASE_ARCH="$ARCHITECTURE"
    if [[ "$USE_MULTI_ARCH" == "true" ]]; then
        RELEASE_ARCH="multi"
        echo "INFO: Using multi-arch release image to support cross-architecture deployment"
    fi

    local RELEASE_IMAGE=$(get-release-image "$stream" "$RELEASE_ARCH")
    [[ -z "$RELEASE_IMAGE" ]] && return 1

    if [[ "$USE_MULTI_ARCH" == "true" ]]; then
        echo "INFO: Using multi-arch release image: $RELEASE_IMAGE"
    else
        echo "INFO: Using architecture-specific release image for $ARCHITECTURE: $RELEASE_IMAGE"
    fi
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$RELEASE_IMAGE
    echo "INFO: Exported OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$RELEASE_IMAGE"

    # Preflight-check that this build's images actually have a published
    # signature before committing to a ~45min bootstrap. See
    # enforce-release-signature-check() in common-functions.zsh.
    enforce-release-signature-check "$RELEASE_IMAGE" "$stream" "$verify_all_signatures" "$allow_unsigned" || return 1

    # Raw nightlies aren't signed the way production release images are (see
    # the identical block/comment in create-ocp-aws.zsh, OCPBUGS-104571).
    if [[ "$stream" == "nightly" ]]; then
        export OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY=true
        echo "INFO: Nightly stream detected -- exported OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY=true to bypass Sigstore signature enforcement"
    fi

    # Re-resolve openshift-install to match RELEASE_IMAGE exactly (see the
    # identical block/comment in create-ocp-aws.zsh for why).
    local exact_install_binary
    exact_install_binary=$(get-openshift-install-for-release-image "$RELEASE_IMAGE")
    if [[ -n "$exact_install_binary" ]]; then
        OPENSHIFT_INSTALL="$exact_install_binary"
        echo "INFO: Using exact-matching openshift-install binary: $OPENSHIFT_INSTALL"
        $OPENSHIFT_INSTALL version
    else
        echo "WARN: Could not resolve an exact-matching openshift-install binary for $RELEASE_IMAGE" >&2
        echo "      Falling back to $OPENSHIFT_INSTALL (may not match the release image version)." >&2
    fi

    local BASE_RELEASE_IMAGE_REGISTRY=$(echo $RELEASE_IMAGE | awk -F/ '{print $1}')
    handle-registry-login "$BASE_RELEASE_IMAGE_REGISTRY"
    update-pull-secret-with-podman "$BASE_RELEASE_IMAGE_REGISTRY"

    mkdir -p $OCP_CREATE_DIR || return 1

    # Same compute/controlPlane platform overrides as create-ocp-aws (KVM
    # metal pool, worker/control-plane instance type overrides).
    local compute_platform_yaml="  platform: {}"
    if [[ "$kvm_all_workers" == "true" ]]; then
        local metal_instance_type=$(resolve-kvm-instance-type "$ARCHITECTURE")
        echo "INFO: --kvm-all-workers requested: all compute nodes will be $metal_instance_type"
        compute_platform_yaml="  platform:
    aws:
      type: $metal_instance_type"
    elif [[ -n "$OCP_WORKER_INSTANCE_TYPE" ]]; then
        echo "INFO: OCP_WORKER_INSTANCE_TYPE set: worker nodes will be $OCP_WORKER_INSTANCE_TYPE"
        compute_platform_yaml="  platform:
    aws:
      type: $OCP_WORKER_INSTANCE_TYPE"
    fi
    local controlplane_platform_yaml="  platform: {}"
    if [[ -n "$OCP_CONTROLPLANE_INSTANCE_TYPE" ]]; then
        echo "INFO: OCP_CONTROLPLANE_INSTANCE_TYPE set: control-plane nodes will be $OCP_CONTROLPLANE_INSTANCE_TYPE"
        controlplane_platform_yaml="  platform:
    aws:
      type: $OCP_CONTROLPLANE_INSTANCE_TYPE"
    fi

    {
        create-install-config-header
        echo "baseDomain: $AWS_BASEDOMAIN
compute:
- architecture: $ARCHITECTURE
  hyperthreading: Enabled
  name: worker
$compute_platform_yaml
  replicas: 3
controlPlane:
  architecture: $ARCHITECTURE
  hyperthreading: Enabled
  name: master
$controlplane_platform_yaml
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
credentialsMode: Manual # needed for STS"
        add-credentials-to-install-config
    } > $OCP_CREATE_DIR/install-config.yaml || return 1
    # openshift-install consumes (deletes) install-config.yaml as soon as it
    # renders manifests -- preserve a copy now, before that happens, so
    # archive-logs.sh has something to grab even on a failure that occurs
    # after manifest generation. See create-ocp SKILL.md's retention-policy
    # section.
    cp $OCP_CREATE_DIR/install-config.yaml $OCP_CREATE_DIR/install-config.yaml.orig

    echo "created install-config.yaml"

    # Use version-matched oc for credential extraction. Requires oc 4.22+
    # for correct --included filtering (OCPBUGS-77845) -- see the identical
    # block/comment in create-ocp-azure-sts.zsh/create-ocp-gcp-wif.zsh.
    local OC_BIN=$(get-release-oc "$RELEASE_IMAGE")
    local oc_ver; oc_ver=$($OC_BIN version --client 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$oc_ver" ]]; then
        autoload -U is-at-least
        if ! is-at-least 4.22 "$oc_ver"; then
            echo "ERROR: resolved oc ($OC_BIN) is version $oc_ver, need >=4.22 for correct --included filtering (OCPBUGS-77845)."
            echo "  This usually means get-release-oc fell back to system oc -- check its output above for a WARNING line."
            return 1
        fi
    else
        echo "WARNING: could not determine $OC_BIN version, proceeding anyway"
    fi
    echo "extracting credential-requests" && $OC_BIN adm release extract \
      --from=$RELEASE_IMAGE \
      --credentials-requests \
      --cloud=aws \
      --included=true \
      --install-config=$OCP_CREATE_DIR/install-config.yaml \
      --registry-config ~/pull-secret.txt \
      --to=$OCP_CREATE_DIR/credentials-requests || return 1

    echo "INFO: Running ccoctl aws create-all..."
    ccoctl aws create-all \
      --name $CLUSTER_NAME \
      --region $AWS_REGION \
      --output-dir $OCP_CREATE_DIR \
      --credentials-requests-dir $OCP_CREATE_DIR/credentials-requests || return 1

    $OPENSHIFT_INSTALL create manifests --dir $OCP_CREATE_DIR || return 1
    cp $OCP_CREATE_DIR/credentials-requests/* $OCP_CREATE_DIR/manifests/ || return 1 # copy cred requests to manifests dir, ccoctl delete will delete cred requests in separate dir

    # Create the cluster with error handling
    if ! $OPENSHIFT_INSTALL create cluster --dir $OCP_CREATE_DIR --log-level=info; then
        cleanup-on-failure "$OCP_CREATE_DIR" "$CLUSTER_NAME" "aws"
        unset OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY AUTO_SELECT_EC PROCEED_WITH_EXISTING_CLUSTERS OCP_NIGHTLY_MINOR
        return 1
    fi

    # Post-install: add a bare-metal worker MachineSet for /dev/kvm, if requested.
    # add-kvm-machineset/resolve-kvm-instance-type are defined in
    # create-ocp-aws.zsh (cloud-specific to AWS, reused as-is here since
    # load.zsh sources that file first). Best-effort.
    local kvm_dedicated_node=false
    if [[ "$add_kvm_pool" == "true" ]]; then
        local kvm_instance_type=$(resolve-kvm-instance-type "$ARCHITECTURE")
        local kvm_zone="${OCP_KVM_ZONE:-${AWS_REGION}b}"
        if KUBECONFIG="$OCP_CREATE_DIR/auth/kubeconfig" add-kvm-machineset "$kvm_zone" "$kvm_instance_type" "$kvm_spot"; then
            kvm_dedicated_node=true
        fi
    fi

    # Post-install: install OpenShift Virtualization (CNV/KubeVirt), if requested.
    if [[ "$install_cnv" == "true" ]]; then
        local cnv_community_tag=""
        [[ "$community_hco" == "true" ]] && cnv_community_tag="$community_hco_tag"
        KUBECONFIG="$OCP_CREATE_DIR/auth/kubeconfig" install-cnv-operator "$kvm_dedicated_node" "$cnv_community_tag"
    fi

    # Cleanup
    unset OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY AUTO_SELECT_EC PROCEED_WITH_EXISTING_CLUSTERS OCP_NIGHTLY_MINOR
}

function create-ocp-aws-sts-arm64() {
    # ARM64 wrapper function
    create-ocp-aws-sts "$1" "arm64" "${@:2}"
}

function create-ocp-aws-sts-amd64() {
    # AMD64 wrapper function
    create-ocp-aws-sts "$1" "amd64" "${@:2}"
}
