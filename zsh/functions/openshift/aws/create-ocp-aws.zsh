create-ocp-aws() {
    # Core implementation for AWS OpenShift cluster creation
    # Parameters:
    #   $1 - Command/option (help, gather, delete, no-delete, --force-new)
    #   $2 - Architecture (arm64 or amd64)
    
    # Unset SSH_AUTH_SOCK on Darwin systems to avoid SSH errors
    if [[ "$(uname)" == "Darwin" ]]; then
        unset SSH_AUTH_SOCK
    fi

    # Detect host architecture for cross-arch support
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

    # Determine if we need multi-arch support
    local USE_MULTI_ARCH="false"
    if [[ "$HOST_ARCH" != "$ARCHITECTURE" ]]; then
        echo "INFO: Cross-architecture deployment detected (host: $HOST_ARCH, target: $ARCHITECTURE)"
        echo "INFO: Will use multi-arch release image to support $ARCHITECTURE clusters"
        USE_MULTI_ARCH="true"
    fi

    # Check if help is requested (before expensive get-openshift-install)
    if [[ $1 == "help" ]]; then
        echo "Usage: create-ocp-aws-$ARCH_SUFFIX [OPTION] [FLAGS]"
        echo "Create an OpenShift cluster on AWS using $ARCHITECTURE architecture"
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
        echo "              1.18.0 (matches OADP's virt e2e default, KubeVirt v1.8.4)."
        echo "  --nightly[=X.Y]"
        echo "              Use the raw per-minor-version OCP nightly release stream"
        echo "              (X.Y.0-0.nightly) instead of dev-preview/stable/--ec. Prompts for"
        echo "              the minor version if not given. Matches how OADP's virt e2e CI"
        echo "              provisions its cluster -- pair with --community-hco for a directly"
        echo "              comparable repro."
        echo ""
        echo "Examples:"
        echo "  create-ocp-aws-$ARCH_SUFFIX --force-new --ec"
        echo "  create-ocp-aws-$ARCH_SUFFIX no-delete --ec"
        echo "  create-ocp-aws-$ARCH_SUFFIX --ec --kvm"
        echo "  create-ocp-aws-$ARCH_SUFFIX --ec --kvm-all-workers --install-cnv"
        echo ""
        echo "Prerequisites:"
        echo "  - AWS_REGION environment variable (defaults to us-east-1 if not set)"
        echo "  - AWS_BASEDOMAIN environment variable (defaults to mg.dog8code.com if not set)"
        echo "  - AWS credentials must be configured"
        echo "  - SSH key must be added to the agent (ssh-add ~/.ssh/id_rsa)"
        echo "  - Pull secret must exist at ~/pull-secret.txt"
        echo "  - OCP_WORKER_INSTANCE_TYPE: optional override for the default (non-metal) worker"
        echo "    pool's instance size (e.g. m5.2xlarge/m6a.2xlarge for CPU/memory-heavy day-2"
        echo "    workloads like Ceph/rook-ceph). Mutually exclusive with --kvm-all-workers."
        echo "  - OCP_CONTROLPLANE_INSTANCE_TYPE: optional override for control-plane instance size."
        echo ""
        echo "KVM/metal notes:"
        echo "  - Bare-metal instances only expose /dev/kvm on '.metal' EC2 types -- non-metal"
        echo "    instances (even nested-virt-capable ones on some clouds) do NOT expose it on AWS."
        echo "  - TODO: AWS announced (Feb 2026) nested-virt support for non-metal C8i/M8i/R8i"
        echo "    families; re-check whether /dev/kvm eventually works without .metal types --"
        echo "    RH's OpenShift Virtualization AWS docs still only list metal types as of now."
        echo "  - Default metal type: m6g.metal (arm64) / m5.metal (amd64). Override with"
        echo "    OCP_KVM_INSTANCE_TYPE. Default zone: \${AWS_REGION}b. Override with OCP_KVM_ZONE"
        echo "    (metal capacity varies by AZ -- retry with a different zone on InsufficientInstanceCapacity)."
        echo "    OCP_KVM_ZONE is ignored by --kvm-all-workers (there's no single AZ to target when"
        echo "    every worker is metal)."
        echo "  - This adds ~1 extra large/expensive node -- delete-ocp-aws tears it down with the"
        echo "    rest of the cluster; do not leave it running longer than needed."
        echo "  - --kvm-all-workers automatically backgrounds a health watcher for the duration of"
        echo "    cluster creation that detects EC2 System Status Check failures ('impaired') on"
        echo "    .metal workers and deletes the affected Machine so its MachineSet reprovisions a"
        echo "    replacement -- no separate flag needed. This is real, seen-live AWS hardware"
        echo "    flakiness that nothing in openshift-install/CAPI/MachineHealthCheck otherwise"
        echo "    detects on its own (see create-ocp SKILL.md's EC2 .metal troubleshooting section)."
        echo ""
        echo "CNV/virt notes:"
        echo "  - --install-cnv installs the kubevirt-hyperconverged operator via OLM and waits"
        echo "    up to 15m for its CSV to reach Succeeded, then creates a HyperConverged CR."
        echo "  - --community-hco installs from a custom CatalogSource (quay.io/kubevirt/"
        echo "    hyperconverged-cluster-index:TAG) into the kubevirt-hyperconverged namespace"
        echo "    instead. Use this to reproduce OADP's virt e2e CI setup, which falls back to"
        echo "    Community HCO because productized CNV has no catalog build yet for an"
        echo "    unreleased nightly OCP payload -- see --nightly."
        echo "  - RECOMMENDED: prefer amd64 (\`create-ocp-aws-amd64\`) over arm64 for --community-hco."
        echo "    Community HCO's ssp-operator component has NO arm64 image at all (only"
        echo "    linux/amd64 + linux/s390x, confirmed via 'oc image info' manifest list), so"
        echo "    Community HCO is fully blocked on arm64 clusters regardless of KubeVirt version"
        echo "    or index tag."
        echo "  - RECOMMENDED: prefer --kvm-all-workers over --kvm/--kvm-spot when combined with"
        echo "    --community-hco (or any workload you plan to run VMs in without a dedicated"
        echo "    node). With --kvm/--kvm-spot, the dedicated=kubevirt:NoSchedule taint must be"
        echo "    tolerated in THREE separate places to actually run a VM there -- the"
        echo "    HyperConverged CR (handled automatically below), the VM's own template"
        echo "    (spec.template.spec.tolerations, for virt-launcher, NOT automated), and"
        echo "    potentially other datamover/helper pods with no toleration field exposed at"
        echo "    all. --kvm-all-workers avoids this entirely since no node is tainted."
        echo "  - If --kvm/--kvm-spot also ran and its metal node came up, the HyperConverged CR"
        echo "    gets a nodePlacement toleration for that node's dedicated=kubevirt:NoSchedule"
        echo "    taint (no nodeSelector, so KubeVirt components can use the node without forcing"
        echo "    all VM workloads onto it)."
        echo "  - With --kvm-all-workers or used alone, the HyperConverged CR has no nodePlacement"
        echo "    override -- there's no dedicated/tainted node to tolerate."
        echo "  - Best-effort: cluster creation has already succeeded by this point, so a failure"
        echo "    or timeout installing CNV is a warning, not a hard failure of this function."
        echo ""
        echo "Directory:"
        echo "  Installation files will be created in: $OCP_MANIFESTS_DIR/$TODAY-aws-$ARCH_SUFFIX"
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

    # Note: We skip architecture validation of the installer's default release image
    # because we always override it with OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE.
    # The installer binary can be any architecture (arm64/amd64) as long as it runs on the host.
    # The cluster node architecture is determined by the release image we select later.
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
    local CLUSTER_BASE_NAME="tkaovila-$TODAY-$ARCH_SUFFIX"
    local OCP_CREATE_DIR_BASE="$OCP_MANIFESTS_DIR/$TODAY-aws-$ARCH_SUFFIX"
    
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
            # Safety guard (added 2026-08-31 after a real incident: a second
            # same-day invocation destroyed a different, still-live cluster
            # that happened to land on this same directory). Even though
            # generate-unique-cluster-name should already have suffixed away
            # from a live cluster above, never destroy one -- fail loudly
            # instead of guessing.
            if is-cluster-live "$OCP_CREATE_DIR"; then
                echo "ERROR: $OCP_CREATE_DIR is a LIVE, reachable cluster (API server responded). Refusing to destroy it automatically." >&2
                echo "If this directory really should be replaced, verify the cluster is actually meant to be torn down first." >&2
                return 1
            fi
            # Archive configs/logs before destroy -- this is the ONLY copy of a
            # failed attempt's install-config/logs once we rm the dir below.
            # See archive-logs.sh: never deletes anything itself, only copies
            # to ~/OCP/manifests/.logs/ (kept >=30 days, see prune function).
            bash ~/.claude/skills/create-ocp/scripts/archive-logs.sh "$OCP_CREATE_DIR" 2>/dev/null || true
            $OPENSHIFT_INSTALL destroy cluster --dir $OCP_CREATE_DIR || echo "no existing cluster"
            $OPENSHIFT_INSTALL destroy bootstrap --dir $OCP_CREATE_DIR || echo "no existing bootstrap"
            ((rm -r $OCP_CREATE_DIR && echo "removed existing create dir") || (true && echo "no existing install dir")) || return 1
        else
            echo "Directory $OCP_CREATE_DIR does not exist, nothing to delete"
        fi
    fi
    
    # if param is delete then stop here
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

    # Set environment variables based on flags
    if [[ "$force_new" == "true" ]]; then
        export FORCE_NEW_CLUSTER="true"
    fi
    
    if [[ "$auto_ec" == "true" ]]; then
        export AUTO_SELECT_EC="true"
    fi
    
    # Check for existing clusters before proceeding
    check-for-existing-clusters "aws" "$ARCH_SUFFIX" || return 1
    
    # Unset the force flag after use
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

    # Determine which architecture to use for release image
    local RELEASE_ARCH="$ARCHITECTURE"
    if [[ "$USE_MULTI_ARCH" == "true" ]]; then
        RELEASE_ARCH="multi"
        echo "INFO: Using multi-arch release image to support cross-architecture deployment"
    fi

    local RELEASE_IMAGE=$(get-release-image "$stream" "$RELEASE_ARCH")
    [[ -z "$RELEASE_IMAGE" ]] && return 1

    # Use the appropriate release image
    if [[ "$USE_MULTI_ARCH" == "true" ]]; then
        echo "INFO: Using multi-arch release image: $RELEASE_IMAGE"
    else
        echo "INFO: Using architecture-specific release image for $ARCHITECTURE: $RELEASE_IMAGE"
    fi
    # Export the release image override
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$RELEASE_IMAGE
    echo "INFO: Exported OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$RELEASE_IMAGE"

    # Preflight-check that this build's images actually have a published
    # signature before committing to a ~45min bootstrap that will otherwise
    # hang forever on a missing one. See enforce-release-signature-check()
    # in common-functions.zsh for the full story; no-op for stream != dev-preview.
    enforce-release-signature-check "$RELEASE_IMAGE" "$stream" "$verify_all_signatures" "$allow_unsigned" || return 1

    # Raw nightlies aren't signed the way quay.io/openshift-release-dev/ocp-release
    # (and the ocp-v*-art-dev component images referenced by it) are for GA/production
    # use. Since 4.21, standalone clusters ship an 'openshift' ClusterImagePolicy that
    # requires Sigstore signatures on exactly those image scopes -- Red Hat's own
    # internal nightly CI sets OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY=true
    # to bypass this for nightly testing, since it isn't testing signed content.
    # Without it, crio's policy.json enforcement can block pulls for core payload
    # images (etcd, kube-apiserver, etc.) during bootstrap -- this reproduced as a
    # permanently-failed kubelet.service ("crio.service not found") and a CVO payload
    # apply stuck at ~84-85% across 5 separate nightly attempts (4.22/4.23/5.0) before
    # this override was added. See OCPBUGS-104571.
    if [[ "$stream" == "nightly" ]]; then
        export OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY=true
        echo "INFO: Nightly stream detected -- exported OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY=true to bypass Sigstore signature enforcement"
    fi

    # get-openshift-install() (called before RELEASE_IMAGE was known) only
    # picks from the latest cached EC/stable binaries -- if OCP_RELEASE_VERSION
    # or --nightly pins something else (e.g. a new major version's EC, or a
    # raw nightly), that binary can silently mismatch the release image by a
    # wide margin. Installer/Terraform asset logic is version-specific, so a
    # mismatch risks failing deep into provisioning rather than up front.
    # Always re-resolve the exact matching binary now that RELEASE_IMAGE is
    # known; fall back to the original binary (with a warning) only if
    # extraction itself fails, so a transient registry/oc issue doesn't hard
    # block the common case where the cached binary was already correct.
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

    mkdir -p $OCP_CREATE_DIR || return 1

    # Note: install-config's compute[].name only accepts "worker" or "edge" --
    # you cannot add an arbitrary custom-named compute pool (e.g. "worker-kvm")
    # at install time. So --kvm/--kvm-spot are handled post-install below by
    # cloning a real worker MachineSet with a bare-metal instance type via the
    # Machine API, once the cluster (and its kubeconfig) exists. --kvm-all-workers
    # is the exception: compute[].platform.aws.type IS settable at install time,
    # so it sets the whole worker pool to a metal type directly here, matching
    # Red Hat's documented install-time method for OpenShift Virtualization.
    local compute_platform_yaml="  platform: {}"
    if [[ "$kvm_all_workers" == "true" ]]; then
        local metal_instance_type=$(resolve-kvm-instance-type "$ARCHITECTURE")
        preflight-check-instance-type-capacity "$metal_instance_type" "$AWS_REGION" || return 1
        echo "INFO: --kvm-all-workers requested: all compute nodes will be $metal_instance_type"
        compute_platform_yaml="  platform:
    aws:
      type: $metal_instance_type"
    elif [[ -n "$OCP_WORKER_INSTANCE_TYPE" ]]; then
        # OCP_WORKER_INSTANCE_TYPE: optional override for the default (non-metal)
        # worker pool's instance size, e.g. when a workload needs more vCPU/memory
        # than the installer's own AWS default (m6i.xlarge). Sibling to
        # OCP_CONTROLPLANE_INSTANCE_TYPE below, just for compute instead of
        # controlPlane. Mutually exclusive with --kvm-all-workers (checked above).
        echo "INFO: OCP_WORKER_INSTANCE_TYPE set: worker nodes will be $OCP_WORKER_INSTANCE_TYPE"
        compute_platform_yaml="  platform:
    aws:
      type: $OCP_WORKER_INSTANCE_TYPE"
    fi
    # OCP_CONTROLPLANE_INSTANCE_TYPE: optional override for control-plane (master)
    # instance size, e.g. when the default (installer's own AWS default, m6i.xlarge
    # on amd64) is under-resourced for a given payload/bootstrap and masters need
    # more headroom. Unset by default -- "platform: {}" lets the installer pick.
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
publish: External"
        add-credentials-to-install-config
    } > $OCP_CREATE_DIR/install-config.yaml || return 1
    # openshift-install consumes (deletes) install-config.yaml as soon as it
    # renders manifests -- preserve a copy now, before that happens, so
    # archive-logs.sh has something to grab even on a failure that occurs
    # after manifest generation. See create-ocp SKILL.md's retention-policy
    # section.
    cp $OCP_CREATE_DIR/install-config.yaml $OCP_CREATE_DIR/install-config.yaml.orig

    echo "created install-config.yaml"

    $OPENSHIFT_INSTALL create manifests --dir $OCP_CREATE_DIR || return 1

    # Background: proactively watch for and remediate impaired .metal workers
    # for the ENTIRE duration of `create cluster` -- see
    # start-aws-metal-health-watcher()'s doc comment for why this is
    # necessary (no part of the OpenShift/CAPI stack polls AWS's own System
    # Status Check API on its own). Only relevant when --kvm-all-workers put
    # metal instances in the pool from day 1; the day-2 --kvm/--kvm-spot path
    # already has its own narrower wait-and-check loop in add-kvm-machineset.
    local metal_watcher_pid=""
    if [[ "$kvm_all_workers" == "true" ]]; then
        start-aws-metal-health-watcher "$OCP_CREATE_DIR" "$AWS_REGION" &
        metal_watcher_pid=$!
    fi

    # Create the cluster with error handling
    if ! $OPENSHIFT_INSTALL create cluster --dir $OCP_CREATE_DIR --log-level=info; then
        [[ -n "$metal_watcher_pid" ]] && kill "$metal_watcher_pid" 2>/dev/null && wait "$metal_watcher_pid" 2>/dev/null
        cleanup-on-failure "$OCP_CREATE_DIR" "$CLUSTER_NAME" "aws"
        unset OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY AUTO_SELECT_EC PROCEED_WITH_EXISTING_CLUSTERS OCP_NIGHTLY_MINOR
        return 1
    fi
    [[ -n "$metal_watcher_pid" ]] && kill "$metal_watcher_pid" 2>/dev/null && wait "$metal_watcher_pid" 2>/dev/null

    # Post-install: add a bare-metal worker MachineSet for /dev/kvm, if requested.
    # Best-effort -- the cluster itself already succeeded above, so a failure
    # or timeout here is a warning, not a hard failure of this function.
    local kvm_dedicated_node=false
    if [[ "$add_kvm_pool" == "true" ]]; then
        local kvm_instance_type=$(resolve-kvm-instance-type "$ARCHITECTURE")
        local kvm_zone="${OCP_KVM_ZONE:-${AWS_REGION}b}"
        if preflight-check-instance-type-capacity "$kvm_instance_type" "$AWS_REGION" && KUBECONFIG="$OCP_CREATE_DIR/auth/kubeconfig" add-kvm-machineset "$kvm_zone" "$kvm_instance_type" "$kvm_spot"; then
            kvm_dedicated_node=true
        fi
    fi

    # Post-install: install OpenShift Virtualization (CNV/KubeVirt), if requested.
    # Best-effort, same rationale as above.
    if [[ "$install_cnv" == "true" ]]; then
        local cnv_community_tag=""
        [[ "$community_hco" == "true" ]] && cnv_community_tag="$community_hco_tag"
        KUBECONFIG="$OCP_CREATE_DIR/auth/kubeconfig" install-cnv-operator "$kvm_dedicated_node" "$cnv_community_tag"
    fi

    # Cleanup
    unset OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY AUTO_SELECT_EC PROCEED_WITH_EXISTING_CLUSTERS OCP_NIGHTLY_MINOR
}

# Background watcher: proactively detect and remediate EC2 .metal workers
# that fail AWS's own System Status Check ("impaired"/"reachability: failed")
# during a --kvm-all-workers install. Meant to be backgrounded for the
# duration of `openshift-install create cluster` and killed right after,
# same pattern as start-gcp-bootstrap-bugfix-helper.
#
# WHY THIS EXISTS (confirmed live 2026-08-31/09-01, AWS): nothing in the
# OpenShift/CAPI stack polls AWS's System Status Check API. CAPI's machine
# controller only watches EC2 instance STATE (pending/running/terminated)
# via DescribeInstances, never DescribeInstanceStatus's separate
# SystemStatus/InstanceStatus health fields -- so a physically-broken host
# can sit "running" from CAPI's point of view forever. MachineHealthCheck
# (the CRD actually designed for auto-remediating bad machines) triggers off
# "no Node / Node NotReady for N minutes" -- but an impaired .metal instance
# often never gets far enough to register a Node at all during initial
# bootstrap, so there's nothing for MachineHealthCheck to watch yet, and
# (also) MachineHealthCheck resources aren't created for worker MachineSets
# by default anyway. Net effect: this class of failure never self-heals
# without an explicit `oc delete machine` (which lets the owning MachineSet
# reprovision a replacement, usually on different underlying hardware).
# Manually diagnosing+applying this fix cost real 40min timeout windows
# across repeated attempts (both us-east-1 and us-west-2) before this
# watcher existed -- catching it within the first minute or two, instead of
# only when a human happens to check, is the entire point.
#
# Usage: start-aws-metal-health-watcher <install-dir> <aws-region> &
#        local pid=$!
#        ...
#        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
start-aws-metal-health-watcher() {
    # Explicitly silence xtrace/verbose regardless of the caller's shell
    # state -- confirmed live 2026-09-01: this function's own code already
    # only prints on an actual problem (impaired instance found), but the
    # backgrounding shell's own xtrace setting (inherited from wherever it
    # was enabled upstream, e.g. a sourced dotfile) was leaking a raw
    # `impaired_ids='...'` trace line into the log on every single 60s tick,
    # healthy or not -- pure noise for a background watcher meant to be
    # silent until there's something to report.
    unsetopt xtrace verbose 2>/dev/null

    local install_dir=$1
    local region=$2
    local kubeconfig="$install_dir/auth/kubeconfig"

    # Wait for kubeconfig to exist (written mid-bootstrap, well before this
    # matters -- metal workers aren't even requested until install-config is
    # rendered, which is after this function is already backgrounded).
    local waited=0
    while [[ ! -f "$kubeconfig" ]]; do
        sleep 10
        (( waited += 10 ))
        if (( waited >= 1800 )); then
            echo "WARNING: metal-health-watcher: no kubeconfig after 30min, giving up" >&2
            return 0
        fi
    done

    local infra_id=""
    while [[ -z "$infra_id" ]]; do
        infra_id=$(jq -r '.infraID // empty' "$install_dir/metadata.json" 2>/dev/null)
        [[ -n "$infra_id" ]] && break
        sleep 5
    done
    echo "INFO: metal-health-watcher: watching for impaired .metal instances on cluster $infra_id in $region" >&2

    while true; do
        sleep 60

        local impaired_ids
        impaired_ids=$(aws ec2 describe-instance-status --region "$region" \
            --filters "Name=system-status.status,Values=impaired" \
                      "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" \
            --query 'InstanceStatuses[].InstanceId' --output text 2>/dev/null)
        [[ -z "$impaired_ids" ]] && continue

        for instance_id in ${(z)impaired_ids}; do
            local machine_name
            machine_name=$(KUBECONFIG="$kubeconfig" oc get machines -n openshift-machine-api --request-timeout=10s \
                -o jsonpath="{range .items[?(@.spec.providerID==\"aws:///*/${instance_id}\")]}{.metadata.name}{end}" 2>/dev/null)
            # jsonpath doesn't support wildcards mid-string reliably across all oc
            # versions -- fall back to a jq-based match on the full list if the
            # jsonpath query above came up empty.
            if [[ -z "$machine_name" ]]; then
                machine_name=$(KUBECONFIG="$kubeconfig" oc get machines -n openshift-machine-api --request-timeout=10s -o json 2>/dev/null \
                    | jq -r --arg id "$instance_id" '.items[] | select(.spec.providerID // "" | endswith($id)) | .metadata.name')
            fi
            [[ -z "$machine_name" ]] && continue

            local phase
            phase=$(KUBECONFIG="$kubeconfig" oc get machine "$machine_name" -n openshift-machine-api --request-timeout=10s -o jsonpath='{.status.phase}' 2>/dev/null)
            if [[ "$phase" == "Deleting" ]]; then
                continue
            fi

            echo "WARNING: metal-health-watcher: instance $instance_id (machine $machine_name) failed System Status Check, deleting so its MachineSet reprovisions a replacement" >&2
            KUBECONFIG="$kubeconfig" oc delete machine "$machine_name" -n openshift-machine-api --request-timeout=15s 2>&1 | sed 's/^/INFO: metal-health-watcher: /' >&2
        done
    done
}

# Preflight-check an EC2 instance type/region combo before committing to a
# 40min+ cluster-create attempt (or a 15min day-2 machineset wait) that could
# otherwise fail deep in provisioning. Two checks, two different severities:
#
# 1. HARD (fails the caller): is $instance_type offered in $region AT ALL?
#    This is a real, deterministic AWS fact (some instance types/families are
#    entirely absent from certain regions) -- catching it here takes seconds
#    instead of discovering it after a wasted install attempt.
# 2. SOFT (warns only, never fails the caller): a Spot placement score for
#    $instance_type in $region, as an ADVISORY capacity-pressure signal. This
#    is NOT a reliable predictor of on-demand launch success or of System
#    Status Check health after launch -- confirmed live 2026-08-31, where
#    m5.metal workers in us-east-1 launched fine (capacity existed) but then
#    repeatedly failed EC2 System Status Checks (a hardware-fault class of
#    problem, unrelated to capacity availability) across 4 separate attempts.
#    AWS has no public API that reports real-time on-demand launch success
#    odds or hardware-health odds -- this score is the closest available
#    signal and is deliberately non-blocking because of that limitation.
#
# Usage: preflight-check-instance-type-capacity <instance-type> <region>
preflight-check-instance-type-capacity() {
    local instance_type=$1
    local region=$2

    if [[ -z "$instance_type" || -z "$region" ]]; then
        echo "Usage: preflight-check-instance-type-capacity <instance-type> <region>" >&2
        return 1
    fi

    local offered
    offered=$(aws ec2 describe-instance-type-offerings --region "$region" \
        --filters "Name=instance-type,Values=$instance_type" \
        --query 'InstanceTypeOfferings[0].InstanceType' --output text 2>/dev/null)
    if [[ -z "$offered" || "$offered" == "None" ]]; then
        echo "ERROR: preflight: $instance_type is not offered anywhere in $region -- pick a different region or override the instance type (OCP_KVM_INSTANCE_TYPE)." >&2
        return 1
    fi
    echo "INFO: preflight: $instance_type is offered in $region" >&2

    local score
    score=$(aws ec2 get-spot-placement-scores --instance-types "$instance_type" \
        --target-capacity 1 --region-names "$region" \
        --query 'SpotPlacementScores[0].Score' --output text 2>/dev/null)
    if [[ -n "$score" && "$score" != "None" ]]; then
        echo "INFO: preflight: capacity-pressure hint (Spot placement score, advisory only, NOT a guarantee for on-demand or a predictor of hardware health) for $instance_type in $region: ${score}/10" >&2
        if (( score <= 3 )); then
            echo "WARNING: preflight: low placement score (${score}/10) suggests $region may be capacity-constrained for $instance_type right now. This does not block the attempt -- if launches keep failing (InsufficientInstanceCapacity, or repeated System Status Check failures across fresh replacement instances), try a different AWS_REGION next time (see create-ocp SKILL.md's EC2 .metal troubleshooting section)." >&2
        fi
    fi
    return 0
}

# Resolve the default bare-metal EC2 instance type for /dev/kvm exposure,
# honoring the OCP_KVM_INSTANCE_TYPE override. Shared by the install-time
# (--kvm-all-workers) and day-2 (--kvm/--kvm-spot) metal-node paths.
resolve-kvm-instance-type() {
    local architecture=$1
    local instance_type="${OCP_KVM_INSTANCE_TYPE:-}"
    if [[ -z "$instance_type" ]]; then
        if [[ "$architecture" == "arm64" ]]; then
            instance_type="m6g.metal"
        else
            instance_type="m5.metal"
        fi
    fi
    echo "$instance_type"
}

# Add a bare-metal worker MachineSet to an existing cluster so /dev/kvm is
# exposed for OpenShift Virtualization/KubeVirt VMs. AWS only exposes /dev/kvm
# on '.metal' instance types -- regular (non-metal) instances never expose it,
# on any architecture, no matter how nested-virt-capable the hypervisor is.
# TODO: AWS announced (Feb 2026) nested-virt support for non-metal C8i/M8i/R8i
# families; re-check whether /dev/kvm eventually works without .metal types --
# RH's OpenShift Virtualization AWS docs still only list metal types as of now.
#
# Usage: KUBECONFIG=/path/to/kubeconfig add-kvm-machineset <zone> <instance-type> [spot]
#
# Clones the existing worker MachineSet in the given zone (so subnet/AMI/IAM/
# security-group config is already correct) rather than hand-building one --
# only the instance type, spot market option, and identity fields change.
# The cloned MachineSet's nodes are also tainted/labeled (dedicated=kubevirt)
# so they're isolated from general workloads; pair with --install-cnv to wire
# a matching toleration into the HyperConverged CR.
add-kvm-machineset() {
    local zone=$1
    local instance_type=$2
    local spot=${3:-false}

    if [[ -z "$zone" || -z "$instance_type" ]]; then
        echo "Usage: add-kvm-machineset <zone> <instance-type> [spot]" >&2
        return 1
    fi

    echo "INFO: --kvm requested: cloning worker MachineSet in $zone as $instance_type (spot=$spot)"

    local infra_id
    infra_id=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null)
    if [[ -z "$infra_id" ]]; then
        echo "WARN: --kvm: could not determine infrastructureName, skipping metal MachineSet" >&2
        return 1
    fi

    local base_ms="${infra_id}-worker-${zone}"
    local new_ms="${infra_id}-worker-metal-${zone}"

    if ! oc get machineset "$base_ms" -n openshift-machine-api &>/dev/null; then
        echo "WARN: --kvm: base MachineSet $base_ms not found (no worker in zone $zone?), skipping" >&2
        return 1
    fi

    local jq_filter='
        del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .metadata.selfLink) |
        del(.status) |
        .metadata.name = $name |
        .spec.replicas = 1 |
        .spec.selector.matchLabels["machine.openshift.io/cluster-api-machineset"] = $name |
        .spec.template.metadata.labels["machine.openshift.io/cluster-api-machineset"] = $name |
        .spec.template.spec.providerSpec.value.instanceType = $itype |
        .spec.template.spec.taints = [{"key": "dedicated", "value": "kubevirt", "effect": "NoSchedule"}] |
        .spec.template.spec.metadata.labels["dedicated"] = "kubevirt" |
        .spec.template.spec.metadata.labels["node-role.kubernetes.io/kvm"] = ""
    '
    if [[ "$spot" == "true" ]]; then
        jq_filter="${jq_filter} | .spec.template.spec.providerSpec.value.spotMarketOptions = {}"
    fi

    if ! oc get machineset "$base_ms" -n openshift-machine-api -o json \
        | jq --arg name "$new_ms" --arg itype "$instance_type" "$jq_filter" \
        | oc apply -f - ; then
        echo "WARN: --kvm: failed to create metal MachineSet $new_ms" >&2
        return 1
    fi

    # Wait for both Running phase AND the taint landing on the Node -- the
    # Machine controller copies spec.template.spec.taints onto the Node
    # asynchronously, so Running alone doesn't guarantee the taint is applied
    # yet. Callers (e.g. install-cnv-operator's toleration wiring) rely on
    # this return code to mean "the taint is actually present on the node".
    echo "INFO: --kvm: waiting up to 15m for $new_ms's machine to become Running and tainted (best-effort)..."
    local elapsed=0
    while (( elapsed < 900 )); do
        local phase node_name taint_value
        phase=$(oc get machine -n openshift-machine-api -l "machine.openshift.io/cluster-api-machineset=${new_ms}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        if [[ "$phase" == "Running" ]]; then
            node_name=$(oc get machine -n openshift-machine-api -l "machine.openshift.io/cluster-api-machineset=${new_ms}" -o jsonpath='{.items[0].status.nodeRef.name}' 2>/dev/null)
            if [[ -n "$node_name" ]]; then
                taint_value=$(oc get node "$node_name" -o jsonpath='{.spec.taints[?(@.key=="dedicated")].value}' 2>/dev/null)
                if [[ "$taint_value" == "kubevirt" ]]; then
                    echo "INFO: --kvm: metal machine is Running and node $node_name is tainted"
                    return 0
                fi
            fi
        fi
        sleep 15
        (( elapsed += 15 ))
    done

    echo "WARN: --kvm: metal machine did not reach Running+tainted within 15m (phase=${phase:-unknown})." >&2
    echo "      Check: oc get machine -n openshift-machine-api -l machine.openshift.io/cluster-api-machineset=${new_ms}" >&2
    return 1
}

# Install Community HCO (quay.io/kubevirt/hyperconverged-cluster-index) from a
# custom CatalogSource, instead of productized CNV from the default
# redhat-operators catalog. This is the fallback path OADP's own virt e2e CI
# uses (EnsureCommunityHcoCatalog/GetVirtOperator in openshift/oadp-operator's
# tests/e2e/lib/virt_helpers.go) because productized CNV has no catalog build
# yet for an unreleased nightly OCP payload -- see --nightly and the
# kubevirt-datamover-controller project memory "oadp-virt-e2e-nightlies".
#
# Usage: KUBECONFIG=/path/to/kubeconfig _install-community-hco <index-tag> [tolerate-kvm-taint]
_install-community-hco() {
    local index_tag=$1
    local tolerate_kvm_taint=${2:-false}

    echo "INFO: --community-hco requested: installing Community HCO index tag $index_tag (best-effort)"

    if ! oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: kubevirt-community-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/kubevirt/hyperconverged-cluster-index:${index_tag}
  displayName: KubeVirt Community HCO
  publisher: KubeVirt
EOF
    then
        echo "WARN: --community-hco: failed to create CatalogSource" >&2
        return 1
    fi

    # channel is derived from the index tag, e.g. 1.18.0 -> stable-v1.18
    # (matches communityChannelFromTag in openshift/oadp-operator's virt_helpers.go)
    local -a tag_parts=(${(s:.:)index_tag})
    local channel="stable-v${tag_parts[1]}.${tag_parts[2]}"

    echo "INFO: --community-hco: waiting up to 5m for community-kubevirt-hyperconverged PackageManifest with channel $channel..."
    local elapsed=0 found=false
    while (( elapsed < 300 )); do
        if oc get packagemanifest community-kubevirt-hyperconverged -n default -o jsonpath='{.status.channels[*].name}' 2>/dev/null | grep -qw "$channel"; then
            found=true
            break
        fi
        sleep 5
        (( elapsed += 5 ))
    done
    if [[ "$found" != "true" ]]; then
        echo "WARN: --community-hco: PackageManifest channel $channel did not appear within 5m" >&2
        return 1
    fi

    if ! oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: kubevirt-hyperconverged
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: kubevirt-hyperconverged
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: community-kubevirt-hyperconverged
  namespace: kubevirt-hyperconverged
spec:
  source: kubevirt-community-catalog
  sourceNamespace: openshift-marketplace
  name: community-kubevirt-hyperconverged
  channel: ${channel}
EOF
    then
        echo "WARN: --community-hco: failed to apply namespace/OperatorGroup/Subscription" >&2
        return 1
    fi

    echo "INFO: --community-hco: waiting up to 15m for CSV to reach Succeeded (best-effort)..."
    elapsed=0
    local phase=""
    while (( elapsed < 900 )); do
        phase=$(oc get csv -n kubevirt-hyperconverged -l operators.coreos.com/community-kubevirt-hyperconverged.kubevirt-hyperconverged -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        [[ "$phase" == "Succeeded" ]] && break
        sleep 15
        (( elapsed += 15 ))
    done
    if [[ "$phase" != "Succeeded" ]]; then
        echo "WARN: --community-hco: CSV did not reach Succeeded within 15m (phase=${phase:-unknown})." >&2
        echo "      Check: oc get csv -n kubevirt-hyperconverged" >&2
        return 1
    fi
    echo "INFO: --community-hco: CSV reached Succeeded"

    echo "INFO: --community-hco: creating HyperConverged CR"
    local hco_manifest
    if [[ "$tolerate_kvm_taint" == "true" ]]; then
        hco_manifest='apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: kubevirt-hyperconverged
spec:
  workloads:
    nodePlacement:
      tolerations:
      - key: dedicated
        operator: Equal
        value: kubevirt
        effect: NoSchedule'
    else
        hco_manifest='apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: kubevirt-hyperconverged
spec: {}'
    fi

    if ! echo "$hco_manifest" | oc apply -f -; then
        echo "WARN: --community-hco: failed to create HyperConverged CR" >&2
        return 1
    fi

    echo "INFO: --community-hco: HyperConverged CR created"
    return 0
}

# Install OpenShift Virtualization (CNV/KubeVirt) via OLM and wait for the
# operator to reach Succeeded, then create a minimal HyperConverged CR.
# Best-effort -- the cluster itself already succeeded, so a failure or
# timeout here is a warning, not a hard failure of the caller.
#
# Usage: KUBECONFIG=/path/to/kubeconfig install-cnv-operator [tolerate-kvm-taint] [community-index-tag]
#
# When tolerate-kvm-taint is "true", the HyperConverged CR is created with a
# nodePlacement toleration for the dedicated=kubevirt:NoSchedule taint added
# by add-kvm-machineset (no nodeSelector, so KubeVirt components can use the
# node without forcing all VM workloads onto it).
#
# When community-index-tag is non-empty, installs Community HCO from that
# index tag instead of productized CNV (see _install-community-hco).
install-cnv-operator() {
    local tolerate_kvm_taint=${1:-false}
    local community_index_tag=${2:-}

    if [[ -n "$community_index_tag" ]]; then
        _install-community-hco "$community_index_tag" "$tolerate_kvm_taint"
        return $?
    fi

    echo "INFO: --install-cnv requested: installing OpenShift Virtualization (best-effort)"

    if ! oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
  - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  channel: stable
EOF
    then
        echo "WARN: --install-cnv: failed to apply namespace/OperatorGroup/Subscription" >&2
        return 1
    fi

    echo "INFO: --install-cnv: waiting up to 15m for CSV to reach Succeeded (best-effort)..."
    local elapsed=0 phase=""
    while (( elapsed < 900 )); do
        phase=$(oc get csv -n openshift-cnv -l operators.coreos.com/kubevirt-hyperconverged.openshift-cnv -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        [[ "$phase" == "Succeeded" ]] && break
        sleep 15
        (( elapsed += 15 ))
    done

    if [[ "$phase" != "Succeeded" ]]; then
        echo "WARN: --install-cnv: CSV did not reach Succeeded within 15m (phase=${phase:-unknown})." >&2
        echo "      Check: oc get csv -n openshift-cnv" >&2
        return 1
    fi
    echo "INFO: --install-cnv: CSV reached Succeeded"

    echo "INFO: --install-cnv: creating HyperConverged CR"
    local hco_manifest
    if [[ "$tolerate_kvm_taint" == "true" ]]; then
        hco_manifest='apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  workloads:
    nodePlacement:
      tolerations:
      - key: dedicated
        operator: Equal
        value: kubevirt
        effect: NoSchedule'
    else
        hco_manifest='apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec: {}'
    fi

    if ! echo "$hco_manifest" | oc apply -f -; then
        echo "WARN: --install-cnv: failed to create HyperConverged CR" >&2
        return 1
    fi

    echo "INFO: --install-cnv: HyperConverged CR created"
    return 0
}

function create-ocp-aws-arm64() {
    # ARM64 wrapper function
    # Note: $1 is the command/option (help, gather, delete, no-delete), $2 is
    # always the architecture -- any additional flags (--force-new, --ec,
    # --kvm, etc.) must come after, so we splice arm64 in ahead of them.
    create-ocp-aws "$1" "arm64" "${@:2}"
}

function create-ocp-aws-amd64() {
    # AMD64 wrapper function
    create-ocp-aws "$1" "amd64" "${@:2}"
}

trigger-create-ocp-aws() {
    local arch=${1:-amd64}
    local stream=${2:-dev-preview}
    local action=${3:-create}
    local repo="kaovilai/dotfiles"

    gh workflow run create-ocp-aws.yml \
        -f arch="$arch" \
        -f stream="$stream" \
        -f action="$action" \
        --repo "$repo"

    echo "Triggered create-ocp-aws (arch=$arch, stream=$stream, action=$action)"
    echo "Watch:  gh run watch --repo $repo"
    echo "Fetch:  download-ocp-aws-auth <RUN_ID>"
}

download-ocp-aws-auth() {
    local run_id=$1
    local repo="kaovilai/dotfiles"

    if [[ -z "$run_id" ]]; then
        echo "Usage: download-ocp-aws-auth <RUN_ID>"
        echo "Find run ID: gh run list --workflow create-ocp-aws.yml --repo $repo"
        return 1
    fi

    local tmpdir=$(mktemp -d)
    gh run download "$run_id" --repo "$repo" --dir "$tmpdir"

    local gpg_file=$(find "$tmpdir" -name '*.gpg' | head -1)
    if [[ -z "$gpg_file" ]]; then
        echo "No encrypted artifact found in run $run_id"
        rm -rf "$tmpdir"
        return 1
    fi

    gpg --decrypt "$gpg_file" | tar xzf -
    rm -rf "$tmpdir"

    echo "Extracted auth/ directory"
    echo "export KUBECONFIG=$(pwd)/auth/kubeconfig"
}

trigger-destroy-ocp-aws() {
    local arch=${1:-amd64}
    local metadata_path=$2
    local repo="kaovilai/dotfiles"
    local today=${TODAY:-$(date +%y%m%d)}

    if [[ -z "$metadata_path" ]]; then
        local live_dir="$OCP_MANIFESTS_DIR/$today-aws-$arch"
        local backup_path="$OCP_MANIFESTS_DIR/.metadata-backup-$today-aws-$arch.json"
        if [[ -f "$live_dir/metadata.json" ]]; then
            metadata_path="$live_dir/metadata.json"
        elif [[ -f "$backup_path" ]]; then
            metadata_path="$backup_path"
        else
            echo "ERROR: no metadata.json found for $today-aws-$arch (checked $live_dir/metadata.json and $backup_path)"
            echo "Usage: trigger-destroy-ocp-aws <arch> [path/to/metadata.json]"
            return 1
        fi
    fi

    if [[ ! -f "$metadata_path" ]]; then
        echo "ERROR: metadata.json not found at $metadata_path"
        return 1
    fi

    local cluster_name; cluster_name=$(jq -r '.clusterName' "$metadata_path" 2>/dev/null)
    if [[ -z "$cluster_name" || "$cluster_name" == "null" ]]; then
        echo "ERROR: could not read .clusterName from $metadata_path"
        return 1
    fi

    echo "About to trigger REMOTE destroy of cluster '$cluster_name' (arch=$arch) via GitHub Actions."
    echo "This deletes real AWS infrastructure and cannot be undone."
    local confirm
    read "confirm?Type the cluster name to confirm ($cluster_name): "
    if [[ "$confirm" != "$cluster_name" ]]; then
        echo "Confirmation did not match, aborting. Nothing was triggered."
        return 1
    fi

    local encoded; encoded=$(base64 < "$metadata_path" | tr -d '\n')

    gh workflow run create-ocp-aws.yml \
        -f arch="$arch" \
        -f action="delete" \
        -f metadata_json="$encoded" \
        --repo "$repo"

    echo "Triggered remote destroy for $cluster_name (arch=$arch)"
    echo "Watch:  gh run watch --repo $repo"
    echo "Safe to close the laptop now -- the runner finishes independently."
}
