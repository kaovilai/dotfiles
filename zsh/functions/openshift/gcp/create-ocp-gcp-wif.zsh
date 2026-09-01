# create a cluster with gcp workload identity using CCO manual mode
# pre-req: ssh-add ~/.ssh/id_rsa
# Background helper: works around two GCP-specific bugs that otherwise eat
# most of the 45min bootstrap window when diagnosed interactively (confirmed
# live 2026-08-22, see create-ocp/SKILL.md "Apply bootstrap ILB workaround"):
#
# 1. installer#10590: GCP CAPI puts bootstrap in the same LB instance group
#    as master-0, so the internal LB pins worker ignition traffic to
#    bootstrap (which refuses it) -> worker ignition hangs forever. Fix:
#    remove bootstrap from that instance group. CAPI's own reconciler
#    periodically re-adds it, so this must be polled/re-applied, not one-shot.
# 2. Removing bootstrap from the LB group short-circuits openshift-install's
#    own graceful bootstrap-teardown, which normally creates a
#    kube-system/bootstrap ConfigMap (data: status=complete) as part of its
#    bootstrap-complete handoff. Without it, openshift-apiserver-operator's
#    precondition check hangs forever on APIServicesAvailable:PreconditionNotReady
#    even though the apiserver Deployment itself is healthy. Fix: apply that
#    ConfigMap directly once the API is reachable. See okd-project/okd#2036.
#
# Caller must background THIS FUNCTION CALL ITSELF (`start-gcp-bootstrap-bugfix-helper ... &`,
# then `local pid=$!`) and kill that PID once `openshift-install create
# cluster` returns. Do NOT wrap the call in `$(...)` -- capturing a command
# substitution around a call that backgrounds work internally corrupts the
# calling shell's own stdout/stderr redirection in zsh (confirmed live
# 2026-08-23: openshift-install's own progress logging, which goes to
# stderr, silently vanished into a zsh-internal temp file instead of the
# intended log for the rest of the script once this function had been
# invoked via `$(...)`). This function intentionally does NOT background
# anything internally, for the same reason -- one clean top-level background
# job, nothing nested.
#
# Usage: start-gcp-bootstrap-bugfix-helper <ocp-create-dir> <gcp-project-id> <gcp-region>
start-gcp-bootstrap-bugfix-helper() {
    local create_dir=$1
    local project_id=$2
    local region=$3

    # Resolve infra ID once metadata.json shows up (written early in
    # `create cluster`, well before the bootstrap instance exists).
    local infra_id=""
    for i in $(seq 1 60); do
        sleep 10
        if [[ -f "$create_dir/metadata.json" ]]; then
            infra_id=$(jq -r '.infraID // empty' "$create_dir/metadata.json" 2>/dev/null)
            [[ -n "$infra_id" ]] && break
        fi
    done
    if [[ -z "$infra_id" ]]; then
        echo "WARNING: gcp-bugfix-helper: could not determine infra ID within 10min, giving up"
        return 0
    fi
    echo "INFO: gcp-bugfix-helper: infra ID = $infra_id, watching for known GCP CAPI bugs"

    local zones=($(gcloud compute zones list --filter="region:(${region})" --project="$project_id" --format='value(name)' 2>/dev/null))
    [[ ${#zones[@]} -eq 0 ]] && zones=(${region}-a ${region}-b ${region}-c ${region}-d)

    # Single loop, both fixes interleaved -- see comment above for why this
    # isn't split into a nested background sub-job.
    #
    # BUG FIXED 2026-08-24 (was live-broken across at least 2 real attempts,
    # both of which silently got zero benefit from this function): the
    # bootstrap-instance-gone check below must NOT break on the very first
    # iteration just because the instance isn't found yet -- metadata.json
    # (used to resolve infra_id above) is written well before CAPI actually
    # provisions the bootstrap compute instance, so "not found" on an early
    # iteration means "hasn't been created yet", not "already torn down
    # normally". The old code treated both cases the same and broke
    # immediately, before ever removing bootstrap from the LB group or
    # applying the configmap even once. Track whether we've ever actually
    # seen the instance exist; only treat "not found" as "done, torn down
    # normally" after that.
    local configmap_applied=false
    local seen_bootstrap=false
    for i in $(seq 1 40); do
        sleep 45

        if [[ "$configmap_applied" == "false" && -f "$create_dir/auth/kubeconfig" ]] && \
           KUBECONFIG="$create_dir/auth/kubeconfig" oc get ns kube-system &>/dev/null; then
            if ! KUBECONFIG="$create_dir/auth/kubeconfig" oc get configmap bootstrap -n kube-system &>/dev/null; then
                cat <<EOF | KUBECONFIG="$create_dir/auth/kubeconfig" oc apply -f - &>/dev/null
kind: ConfigMap
apiVersion: v1
metadata:
  name: bootstrap
  namespace: kube-system
data:
  status: complete
EOF
                echo "INFO: gcp-bugfix-helper: applied kube-system/bootstrap configmap (works around installer bootstrap-teardown being skipped)"
            fi
            configmap_applied=true
        fi

        if gcloud compute instances list --project="$project_id" --filter="name=${infra_id}-bootstrap" --format='value(name)' 2>/dev/null | grep -q .; then
            seen_bootstrap=true
        elif [[ "$seen_bootstrap" == "true" ]]; then
            echo "INFO: gcp-bugfix-helper: bootstrap instance torn down normally, stopping ILB-removal loop"
            break
        else
            # Not created yet -- keep waiting, don't mistake this for "gone".
            continue
        fi

        for zone in "${zones[@]}"; do
            local present
            present=$(gcloud compute instance-groups unmanaged list-instances "${infra_id}-master-${zone}" --zone="${zone}" --project="$project_id" --format='value(instance)' 2>/dev/null | grep "${infra_id}-bootstrap")
            if [[ -n "$present" ]]; then
                gcloud compute instance-groups unmanaged remove-instances "${infra_id}-master-${zone}" \
                    --zone="${zone}" --instances="${infra_id}-bootstrap" --project="$project_id" --quiet 2>/dev/null \
                    && echo "INFO: gcp-bugfix-helper: removed bootstrap from ${infra_id}-master-${zone} LB instance group (CAPI may re-add -- will keep checking)"
            fi
        done
    done
    echo "INFO: gcp-bugfix-helper: done watching"
}

create-ocp-gcp-wif(){
    # Unset SSH_AUTH_SOCK on Darwin systems to avoid SSH errors
    if [[ "$(uname)" == "Darwin" ]]; then
        unset SSH_AUTH_SOCK
    fi

    # Check if help is requested (before expensive get-openshift-install)
    if [[ $1 == "help" ]]; then
        echo "Usage: create-ocp-gcp-wif [OPTION]"
        echo "Create an OpenShift cluster on GCP with Workload Identity Federation"
        echo ""
        echo "Options:"
        echo "  help        Display this help message"
        echo "  gather      Gather bootstrap logs from the installation directory"
        echo "  delete      Just delete the cluster without recreating it"
        echo "  no-delete   Skip deletion of existing cluster before creation"
        echo "  --force-new Force creation alongside existing clusters (skip prompt)"
        echo "  --ec        Automatically select Early Candidate release stream"
        echo "  --verify-all-signatures"
        echo "              With --ec, check every image in the release payload for a"
        echo "              published signature instead of just rhel-coreos (slower, ~10-20s)"
        echo "  --allow-unsigned"
        echo "              With --ec, if the signature preflight check finds a missing"
        echo "              signature, auto-disable ClusterImagePolicy enforcement (same as"
        echo "              --nightly) and continue instead of prompting/aborting"
        echo "  --nightly[=X.Y]"
        echo "              Use the raw per-minor-version OCP nightly release stream"
        echo "              (X.Y.0-0.nightly) instead of dev-preview/stable/--ec. Prompts for"
        echo "              the minor version if not given."
        echo "  --install-cnv"
        echo "              Install OpenShift Virtualization (CNV/KubeVirt operator + a minimal"
        echo "              HyperConverged CR). Can be combined with --kvm or used alone."
        echo "  --community-hco[=TAG]"
        echo "              Install Community HCO (quay.io/kubevirt/hyperconverged-cluster-index)"
        echo "              instead of productized CNV. Implies --install-cnv. TAG defaults to"
        echo "              1.18.0. Use this when --nightly is also set."
        echo "  --kvm       EXPERIMENTAL/best-effort: add a day-2 tainted worker MachineSet on a"
        echo "              GCP boot image derived with the enable-vmx license, exposing /dev/kvm"
        echo "              for nested virtualization. Default machine type n2-standard-4,"
        echo "              override with OCP_GCP_NESTED_VIRT_MACHINE_TYPE. No prior confirmed"
        echo "              working repro of this path -- unlike AWS/Azure's KVM support."
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
        echo ""
        echo "Note:"
        echo "  When creating clusters alongside existing ones (option 3), a unique"
        echo "  name will be generated by adding a suffix (e.g., -1, -2) to avoid conflicts"
        echo "  The --force-new flag automatically selects option 3 when existing clusters are found"
        echo "  The --ec flag automatically selects the Early Candidate release stream"
        return 0
    fi

    # Get openshift-install binary for creation
    local OPENSHIFT_INSTALL=$(get-openshift-install)
    [[ -z "$OPENSHIFT_INSTALL" ]] && return 1
    $OPENSHIFT_INSTALL version
    # TODO: remove OPENSHIFT_INSTALL_DESTROY override when openshift/installer#10586 merges
    # Patched binary fixes GCP destroy dependency ordering but lacks embedded CoreOS data for create
    local OPENSHIFT_INSTALL_DESTROY=$OPENSHIFT_INSTALL
    if [[ -f /tmp/openshift-install-gcp-fix ]]; then
        OPENSHIFT_INSTALL_DESTROY=/tmp/openshift-install-gcp-fix
        echo "INFO: Using patched openshift-install for destroy operations (GCP destroy fix)"
    fi

    # Verify ccoctl is available (needed for GCP WIF credential management)
    if ! command -v ccoctl &>/dev/null; then
        echo "ERROR: ccoctl not found in PATH"
        echo "Install options:"
        echo "  - From source: install-ccoctl"
        echo "  - From release: curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/ccoctl-linux.tar.gz | tar xzf - -C /usr/local/bin ccoctl"
        return 1
    fi

    # openshift-install create install-config --dir $OCP_MANIFESTS_DIR/$TODAY-gcp-wif --log-level debug
    # https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html-single/installing_on_gcp/index#cco-ccoctl-configuring_installing-gcp-customizations
    # prompt and remove if exists already so user can interrupt if uninstall is needed.
    
    # Safety check - ensure TODAY is not empty
    if [[ -z "$TODAY" ]]; then
        echo "WARNING: TODAY variable is empty, using current date"
        TODAY=$(date +%y%m%d)
    fi
    
    # Set initial cluster name and directory
    local CLUSTER_BASE_NAME="tkaovila-$TODAY-wif"
    local OCP_CREATE_DIR_BASE="$OCP_MANIFESTS_DIR/$TODAY-gcp-wif"
    
    # Generate unique cluster name if needed
    local unique_result=$(generate-unique-cluster-name "$CLUSTER_BASE_NAME" "$OCP_CREATE_DIR_BASE")
    [[ -z "$unique_result" ]] && return 1
    local CLUSTER_NAME=$(echo "$unique_result" | grep "cluster_name:" | cut -d: -f2)
    local OCP_CREATE_DIR=$(echo "$unique_result" | grep "cluster_dir:" | cut -d: -f2)
    # WIF pool/provider name persisted per-attempt-dir. GCP fully-deletes pools
    # only ~30 days after soft-delete; reusing the same name across retries
    # (old bug: this was just $CLUSTER_NAME, deterministic per-day) meant every
    # retry undeleted+redeleted the SAME pool, and after several cycles GCP's
    # eventual consistency broke: worker VMs got invalid_target errors trying
    # to exchange tokens against the pool, so no workers ever joined. Fix: give
    # every real create attempt a fresh random-suffixed name (see below, right
    # before ccoctl gcp create-all); this marker records it so the *next*
    # invocation's pre-create cleanup (right below) deletes the right pool
    # instead of guessing $CLUSTER_NAME.
    local WIF_NAME_MARKER="$OCP_MANIFESTS_DIR/.gcp-wif-name-$(basename $OCP_CREATE_DIR)"
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
        local metadata_backup="$OCP_MANIFESTS_DIR/.metadata-backup-$(basename $OCP_CREATE_DIR).json"
        # Resolve which WIF pool name to tear down: prefer the marker left by
        # the attempt that actually created it, fall back to $CLUSTER_NAME for
        # pre-existing dirs from before this fix.
        local delete_wif_name="$CLUSTER_NAME"
        [[ -f "$WIF_NAME_MARKER" ]] && delete_wif_name=$(cat "$WIF_NAME_MARKER")
        if [[ -d "$OCP_CREATE_DIR" ]]; then
            # Safety guard (added 2026-08-31 after a real incident on AWS: a
            # second same-day invocation destroyed a different, still-live
            # cluster that happened to land on this same directory). Never
            # destroy a live cluster -- fail loudly instead of guessing.
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
            $OPENSHIFT_INSTALL_DESTROY destroy cluster --dir $OCP_CREATE_DIR || echo "no existing cluster"
            $OPENSHIFT_INSTALL_DESTROY destroy bootstrap --dir $OCP_CREATE_DIR || echo "no existing bootstrap"
            (ccoctl gcp delete \
            --name $delete_wif_name \
            --project $GCP_PROJECT_ID \
            --credentials-requests-dir $OCP_CREATE_DIR/credentials-requests && echo "cleaned up ccoctl gcp resources") || true
            ((rm -r $OCP_CREATE_DIR && echo "removed existing create dir") || (true && echo "no existing install dir")) || return 1
            rm -f "$metadata_backup" "$WIF_NAME_MARKER" 2>/dev/null
        elif [[ -f "$metadata_backup" ]]; then
            # Restore metadata.json from backup to run destroy on orphaned resources
            echo "INFO: Restoring metadata.json from backup for destroy..."
            mkdir -p "$OCP_CREATE_DIR"
            cp "$metadata_backup" "$OCP_CREATE_DIR/metadata.json"
            $OPENSHIFT_INSTALL_DESTROY destroy cluster --dir $OCP_CREATE_DIR || echo "no existing cluster"
            rm -rf "$OCP_CREATE_DIR" "$metadata_backup" "$WIF_NAME_MARKER"
        else
            echo "Directory $OCP_CREATE_DIR does not exist, nothing to delete"
        fi
        # Fallback: clean up orphaned GCP compute resources by name pattern
        # Handles cases where openshift-install destroy failed (missing metadata.json)
        # or left resources due to dependency ordering issues
        cleanup-orphaned-gcp-resources "$CLUSTER_NAME" "$GCP_PROJECT_ID"
    fi
    # if param is delete then stop here
    if [[ $1 == "delete" ]]; then
        return 0
    fi
    
    # Validate required GCP environment variables
    validate-env-vars "gcp" \
        GCP_PROJECT_ID \
        GCP_REGION \
        GCP_BASEDOMAIN || return 1

    preflight-check-gcp-permissions

    # Parse command line flags
    local force_new=false
    local auto_ec=false
    local verify_all_signatures=false
    local allow_unsigned=false
    local use_nightly=false
    local nightly_minor=""
    local install_cnv=false
    local community_hco=false
    local community_hco_tag="1.18.0"
    local add_kvm_pool=false

    local no_cleanup=false

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
            --no-cleanup)
                no_cleanup=true
                ;;
            --nightly)
                use_nightly=true
                ;;
            --nightly=*)
                use_nightly=true
                nightly_minor="${arg#--nightly=}"
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
            --kvm)
                add_kvm_pool=true
                ;;
        esac
    done
    
    # Set environment variables based on flags
    if [[ "$force_new" == "true" ]]; then
        export FORCE_NEW_CLUSTER="true"
    fi
    
    if [[ "$auto_ec" == "true" ]]; then
        export AUTO_SELECT_EC="true"
    fi
    
    # Check for existing clusters before proceeding
    check-for-existing-clusters "gcp" || return 1
    
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
    local RELEASE_IMAGE=$(get-release-image "$stream" "multi")
    [[ -z "$RELEASE_IMAGE" ]] && return 1

    # Preflight-check that this build's images actually have a published
    # signature before committing to a ~45min bootstrap that will otherwise
    # hang forever on a missing one. See enforce-release-signature-check()
    # in common-functions.zsh for the full story; no-op for stream != dev-preview.
    enforce-release-signature-check "$RELEASE_IMAGE" "$stream" "$verify_all_signatures" "$allow_unsigned" || return 1

    # Raw nightlies aren't signed the way production release images are (see
    # the identical block/comment in create-ocp-aws.zsh, OCPBUGS-104571) --
    # bypass Sigstore ClusterImagePolicy enforcement for nightly streams.
    if [[ "$stream" == "nightly" ]]; then
        export OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY=true
        echo "INFO: Nightly stream detected -- exported OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY=true to bypass Sigstore signature enforcement"
    fi

    echo "INFO: Using release image: $RELEASE_IMAGE"
    # RELEASE_IMAGE=$($OPENSHIFT_INSTALL version | awk '/release image/ {print $3}')
    # make sure logged into registry since cco steps requires it.
    local BASE_RELEASE_IMAGE_REGISTRY=$(echo $RELEASE_IMAGE | awk -F/ '{print $1}')

    # Handle registry login and pull secret update
    handle-registry-login "$BASE_RELEASE_IMAGE_REGISTRY"
    update-pull-secret-with-podman "$BASE_RELEASE_IMAGE_REGISTRY"
    mkdir -p $OCP_CREATE_DIR || return 1
    
    {
        create-install-config-header
        echo "baseDomain: $GCP_BASEDOMAIN
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
credentialsMode: Manual # needed for WIF"
        add-credentials-to-install-config
    } > $OCP_CREATE_DIR/install-config.yaml || return 1
    # openshift-install consumes (deletes) install-config.yaml as soon as it
    # renders manifests -- preserve a copy now, before that happens, so
    # archive-logs.sh has something to grab even on a failure that occurs
    # after manifest generation. See create-ocp SKILL.md's retention-policy
    # section.
    cp $OCP_CREATE_DIR/install-config.yaml $OCP_CREATE_DIR/install-config.yaml.orig

    echo "created install-config.yaml"

    echo "INFO: Using release image for GCP: $RELEASE_IMAGE"

    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$RELEASE_IMAGE
    echo "INFO: Exported OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$RELEASE_IMAGE"

    # Give this attempt a genuinely unique WIF pool/provider name instead of
    # reusing $CLUSTER_NAME (see WIF_NAME_MARKER comment above for why: a
    # fully-deleted-then-recreated pool needs a new name to reliably avoid
    # GCP's eventual-consistency 409s / invalid_target auth failures --
    # undelete-and-reuse on the same name is exactly what broke). Persist it
    # so a later cleanup pass (this function's own pre-create block above, on
    # the next invocation) knows what to tear down.
    local WIF_NAME="${CLUSTER_NAME}-w$((RANDOM % 9000 + 1000))"
    echo "INFO: Using unique workload-identity pool name $WIF_NAME (avoids GCP pool-reuse/eventual-consistency bug)"
    echo "$WIF_NAME" > "$WIF_NAME_MARKER"

    # Legacy safety net: in the unlikely event $WIF_NAME collides with a pool
    # left over from a much older run (should never happen -- random suffix --
    # but cheap to guard), undelete+drain it the same way the old
    # $CLUSTER_NAME-based logic did, rather than failing into a 409.
    if gcloud iam workload-identity-pools describe "$WIF_NAME" \
        --location=global --project="$GCP_PROJECT_ID" &>/dev/null; then
        echo "INFO: Found existing workload identity pool $WIF_NAME, cleaning provider..."
        # Undelete pool if it's in soft-deleted state (no-op if already active)
        gcloud iam workload-identity-pools undelete "$WIF_NAME" \
            --location=global --project="$GCP_PROJECT_ID" --quiet 2>/dev/null || true
        # Wait for provider to become ACTIVE (pool undelete restores providers async)
        echo "INFO: Waiting for provider to be restored by pool undelete..."
        local wait_retries=12
        while (( wait_retries-- > 0 )); do
            local provider_state=$(gcloud iam workload-identity-pools providers describe "$WIF_NAME" \
                --workload-identity-pool="$WIF_NAME" \
                --location=global --project="$GCP_PROJECT_ID" \
                --format='value(state)' 2>/dev/null)
            if [[ "$provider_state" == "ACTIVE" ]]; then
                echo "INFO: Provider is ACTIVE, deleting..."
                break
            elif [[ -z "$provider_state" ]]; then
                echo "INFO: No provider found, clean state"
                break
            fi
            echo -n "."
            sleep 5
        done
        # Now delete the ACTIVE provider so ccoctl creates fresh with new OIDC keys
        if [[ "$provider_state" == "ACTIVE" ]]; then
            gcloud iam workload-identity-pools providers delete "$WIF_NAME" \
                --workload-identity-pool="$WIF_NAME" \
                --location=global --project="$GCP_PROJECT_ID" --quiet 2>/dev/null || true
            echo "INFO: Waiting for provider deletion to propagate..."
            local purge_retries=24
            while (( purge_retries-- > 0 )); do
                provider_state=$(gcloud iam workload-identity-pools providers describe "$WIF_NAME" \
                    --workload-identity-pool="$WIF_NAME" \
                    --location=global --project="$GCP_PROJECT_ID" \
                    --format='value(state)' 2>/dev/null)
                if [[ -z "$provider_state" || "$provider_state" == "DELETED" ]]; then
                    echo "INFO: Provider deleted, pool ready for ccoctl"
                    break
                fi
                echo -n "."
                sleep 5
            done
            # Keep this inside the branch that declares purge_retries: on the
            # clean path the variable is undefined and (( undefined <= 0 )) is
            # true, which produced a bogus warning.
            if (( purge_retries <= 0 )); then
                echo ""
                echo "WARNING: Provider still exists after timeout, ccoctl may hit 409 errors"
            fi
        fi
    fi

    # Use version-matched oc for credential extraction. Requires oc 4.22+
    # containing openshift/oc#2222 -- older oc mis-filters --included against
    # install-config's capabilities, incorrectly including the
    # openshift-cluster-api-gcp CredentialsRequest, which deadlocks bootkube
    # forever trying to create capg-manager-bootstrap-credentials in a
    # namespace that doesn't exist yet (OCPBUGS-77845, resolved upstream --
    # see create-ocp SKILL.md's GCP-WIF troubleshooting section). Fail loudly
    # here rather than silently proceeding with too-old an oc and deadlocking
    # 45 minutes later with a confusing symptom.
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
      --cloud=gcp \
      --included=true \
      --install-config=$OCP_CREATE_DIR/install-config.yaml \
      --registry-config ~/pull-secret.txt \
      --to=$OCP_CREATE_DIR/credentials-requests || return 1
    ccoctl gcp create-all \
      --name $WIF_NAME \
      --project $GCP_PROJECT_ID \
      --region $GCP_REGION \
      --output-dir $OCP_CREATE_DIR \
      --credentials-requests-dir $OCP_CREATE_DIR/credentials-requests || return 1
    $OPENSHIFT_INSTALL create manifests --dir $OCP_CREATE_DIR || return 1
    cp $OCP_CREATE_DIR/credentials-requests/* $OCP_CREATE_DIR/manifests/ || return 1 # copy cred requests to manifests dir, ccoctl delete will delete cred requests in separate dir
    
    # Create the cluster with error handling. A background helper runs for
    # the duration of this call to proactively work around the two known GCP
    # CAPI bugs (ILB-pinning + the bootstrap-configmap side effect of fixing
    # it) documented in start-gcp-bootstrap-bugfix-helper()'s comment above --
    # doing this unconditionally, before either bug can eat bootstrap-timeout
    # budget via interactive diagnosis, is the whole point.
    start-gcp-bootstrap-bugfix-helper "$OCP_CREATE_DIR" "$GCP_PROJECT_ID" "$GCP_REGION" &
    local bugfix_helper_pid=$!
    local create_cluster_status=0
    $OPENSHIFT_INSTALL create cluster --dir $OCP_CREATE_DIR --log-level=info || create_cluster_status=1
    kill "$bugfix_helper_pid" 2>/dev/null
    wait "$bugfix_helper_pid" 2>/dev/null
    if [[ "$create_cluster_status" != "0" ]]; then
        if [[ "$no_cleanup" == "true" ]]; then
            echo "WARNING: Cluster creation failed but --no-cleanup set, skipping destroy"
            echo "  Cluster dir: $OCP_CREATE_DIR"
            echo "  KUBECONFIG: $OCP_CREATE_DIR/auth/kubeconfig"
            echo "  Apply ILB fix: bash ~/.claude/skills/create-ocp-gcp-wif/scripts/fix-bootstrap-ilb.sh $GCP_PROJECT_ID $GCP_REGION"
        else
            cleanup-on-failure "$OCP_CREATE_DIR" "$CLUSTER_NAME" "gcp"
        fi
        unset OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE AUTO_SELECT_EC PROCEED_WITH_EXISTING_CLUSTERS
        return 1
    fi
    
    echo "workload-identity-pool: $WIF_NAME"
    echo "workload-identity-provider: $WIF_NAME"

    # Post-install: add a nested-virtualization-capable worker MachineSet for
    # /dev/kvm, if requested. EXPERIMENTAL/best-effort -- unlike AWS's --kvm
    # (bare-metal instance types) or Azure's --kvm-all-workers (VM families
    # that expose nested virt with zero extra config), GCP requires deriving
    # a custom boot image carrying the enable-vmx license first. This has no
    # prior confirmed-working repro in this codebase yet -- see
    # add-gcp-nested-virt-machineset()'s doc comment. The cluster itself
    # already succeeded above, so a failure/timeout here is a warning, not a
    # hard failure of this function.
    local kvm_dedicated_node=false
    if [[ "$add_kvm_pool" == "true" ]]; then
        if KUBECONFIG="$OCP_CREATE_DIR/auth/kubeconfig" add-gcp-nested-virt-machineset "$GCP_PROJECT_ID" "$CLUSTER_NAME"; then
            kvm_dedicated_node=true
        fi
    fi

    # Post-install: install OpenShift Virtualization (CNV/KubeVirt), if requested.
    # install-cnv-operator is defined in aws/create-ocp-aws.zsh but is cloud-agnostic
    # (only needs KUBECONFIG + a taint-tolerate bool + optional community tag) --
    # reused as-is here since load.zsh sources that file first. Best-effort, same
    # rationale as above.
    if [[ "$install_cnv" == "true" ]]; then
        local cnv_community_tag=""
        [[ "$community_hco" == "true" ]] && cnv_community_tag="$community_hco_tag"
        KUBECONFIG="$OCP_CREATE_DIR/auth/kubeconfig" install-cnv-operator "$kvm_dedicated_node" "$cnv_community_tag"
    fi

    # Update or remind about secrets.zsh
    echo ""
    echo "Would you like to automatically update ~/secrets.zsh with the WIF values? (y/n)"
    read -r update_secrets
    
    if [[ "$update_secrets" == "y" ]]; then
        # Check if secrets.zsh exists
        if [[ -f ~/secrets.zsh ]]; then
            # Create backup
            cp ~/secrets.zsh ~/secrets.zsh.bak.$(date +%Y%m%d_%H%M%S)
            
            # Check if GCP_POOL_ID and GCP_PROVIDER_ID already exist
            if grep -q "^export GCP_POOL_ID=" ~/secrets.zsh && grep -q "^export GCP_PROVIDER_ID=" ~/secrets.zsh; then
                # Update existing values
                sed -i.tmp "s/^export GCP_POOL_ID=.*/export GCP_POOL_ID='$WIF_NAME'/" ~/secrets.zsh
                sed -i.tmp "s/^export GCP_PROVIDER_ID=.*/export GCP_PROVIDER_ID='$WIF_NAME'/" ~/secrets.zsh
                rm -f ~/secrets.zsh.tmp
                echo "Updated existing GCP_POOL_ID and GCP_PROVIDER_ID in ~/secrets.zsh"
            else
                # Append new values
                echo "" >> ~/secrets.zsh
                echo "#For WIF work on cluster $WIF_NAME" >> ~/secrets.zsh
                echo "export GCP_POOL_ID='$WIF_NAME'" >> ~/secrets.zsh
                echo "export GCP_PROVIDER_ID='$WIF_NAME'" >> ~/secrets.zsh
                echo "Added GCP_POOL_ID and GCP_PROVIDER_ID to ~/secrets.zsh"
            fi
            
            echo "Backup created at: ~/secrets.zsh.bak.$(date +%Y%m%d_%H%M%S)"
            echo ""
            echo "To apply the changes, run: source ~/secrets.zsh"
        else
            echo "ERROR: ~/secrets.zsh not found. Creating it with the WIF values..."
            echo "#For WIF work on cluster $WIF_NAME" > ~/secrets.zsh
            echo "export GCP_POOL_ID='$WIF_NAME'" >> ~/secrets.zsh
            echo "export GCP_PROVIDER_ID='$WIF_NAME'" >> ~/secrets.zsh
            echo "Created ~/secrets.zsh with WIF values"
        fi
    else
        echo "Manual update required. Add the following to ~/secrets.zsh:"
        echo "  export GCP_POOL_ID='$WIF_NAME'"
        echo "  export GCP_PROVIDER_ID='$WIF_NAME'"
    fi
    
    # Cleanup
    unset OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE AUTO_SELECT_EC PROCEED_WITH_EXISTING_CLUSTERS
}

# Add a nested-virtualization-capable worker MachineSet to an existing GCP
# cluster so /dev/kvm is exposed for OpenShift Virtualization/KubeVirt VMs.
#
# EXPERIMENTAL / best-effort: unlike AWS (.metal instance types, zero extra
# config) or Azure (Dv3/Dsv3/Ev3/Esv3+ VM families expose nested virt
# natively), GCP nested virtualization requires a boot image that carries the
# "enable-vmx" license -- OpenShift's own installer-generated RHCOS image
# doesn't have it, and GCP's install-config compute[].platform.gcp stanza has
# no per-pool custom-image override the way AWS's `type:` field works for
# instance size. So this has to run as a day-2 step: derive a licensed image
# from the existing worker's boot image, then clone the worker MachineSet
# (same jq clone-and-mutate pattern as AWS's add-kvm-machineset in
# aws/create-ocp-aws.zsh) onto that image with a nested-virt-capable machine
# type. This has NO prior confirmed-working repro in this codebase (unlike
# AWS's --kvm, which cites a live-tested history) -- treat any failure here
# as informative, not diagnostic of a real problem elsewhere.
#
# Usage: KUBECONFIG=/path/to/kubeconfig add-gcp-nested-virt-machineset <gcp-project-id> <cluster-name>
add-gcp-nested-virt-machineset() {
    local project_id=$1
    local cluster_name=$2

    if [[ -z "$project_id" || -z "$cluster_name" ]]; then
        echo "Usage: add-gcp-nested-virt-machineset <gcp-project-id> <cluster-name>" >&2
        return 1
    fi

    echo "INFO: --kvm requested: deriving a nested-virt-capable (enable-vmx) worker image (EXPERIMENTAL, best-effort)"

    local infra_id
    infra_id=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null)
    if [[ -z "$infra_id" ]]; then
        echo "WARN: --kvm: could not determine infrastructureName, skipping nested-virt MachineSet" >&2
        return 1
    fi

    local base_ms
    base_ms=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$base_ms" ]]; then
        echo "WARN: --kvm: no worker MachineSet found, skipping nested-virt MachineSet" >&2
        return 1
    fi

    local source_image
    source_image=$(oc get machineset "$base_ms" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.disks[0].image}' 2>/dev/null)
    if [[ -z "$source_image" ]]; then
        echo "WARN: --kvm: could not read boot image from MachineSet $base_ms, skipping" >&2
        return 1
    fi

    local licensed_image_name="${cluster_name}-nested-virt"
    echo "INFO: --kvm: creating licensed image $licensed_image_name from $source_image..."
    if ! gcloud compute images create "$licensed_image_name" \
        --source-image="$source_image" \
        --licenses="https://www.googleapis.com/compute/v1/projects/vm-options/global/licenses/enable-vmx" \
        --project="$project_id" --quiet; then
        echo "WARN: --kvm: failed to create licensed image, skipping nested-virt MachineSet" >&2
        return 1
    fi

    local new_ms="${infra_id}-worker-nested-virt"
    local machine_type="${OCP_GCP_NESTED_VIRT_MACHINE_TYPE:-n2-standard-4}"
    local image_selflink="projects/${project_id}/global/images/${licensed_image_name}"

    local jq_filter='
        del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .metadata.selfLink) |
        del(.status) |
        .metadata.name = $name |
        .spec.replicas = 1 |
        .spec.selector.matchLabels["machine.openshift.io/cluster-api-machineset"] = $name |
        .spec.template.metadata.labels["machine.openshift.io/cluster-api-machineset"] = $name |
        .spec.template.spec.providerSpec.value.machineType = $mtype |
        .spec.template.spec.providerSpec.value.disks[0].image = $image |
        .spec.template.spec.taints = [{"key": "dedicated", "value": "kubevirt", "effect": "NoSchedule"}] |
        .spec.template.spec.metadata.labels["dedicated"] = "kubevirt" |
        .spec.template.spec.metadata.labels["node-role.kubernetes.io/kvm"] = ""
    '
    if ! oc get machineset "$base_ms" -n openshift-machine-api -o json \
        | jq --arg name "$new_ms" --arg mtype "$machine_type" --arg image "$image_selflink" "$jq_filter" \
        | oc apply -f - ; then
        echo "WARN: --kvm: failed to create nested-virt MachineSet $new_ms" >&2
        return 1
    fi

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
                    echo "INFO: --kvm: nested-virt machine is Running and node $node_name is tainted"
                    return 0
                fi
            fi
        fi
        sleep 15
        (( elapsed += 15 ))
    done

    echo "WARN: --kvm: nested-virt machine did not reach Running+tainted within 15m (phase=${phase:-unknown})." >&2
    echo "      Check: oc get machine -n openshift-machine-api -l machine.openshift.io/cluster-api-machineset=${new_ms}" >&2
    return 1
}

# Function to create Velero identity for current GCP OpenShift cluster
# run this after creation above is successful to get vars for velero install for oadp with `make deploy-olm-stsflow-gcp`
create-velero-identity-for-gcp-cluster() {
    # Get cluster API URL
    local API_URL=$(oc whoami --show-server)
    
    # Extract cluster name from API URL
    # Format: https://api.cluster-name.basedomain:6443
    local CLUSTER_NAME=$(echo "$API_URL" | sed 's|https://api\.||' | sed 's|\..*||')
    
    if [[ -z "$CLUSTER_NAME" ]]; then
        echo "ERROR: Could not determine cluster name from API URL: $API_URL"
        return 1
    fi
    
    echo "Creating Velero service account for cluster: $CLUSTER_NAME"
    
    # Check if GCP_PROJECT_ID is set
    if [[ -z "$GCP_PROJECT_ID" ]]; then
        echo "ERROR: GCP_PROJECT_ID environment variable is not set"
        return 1
    fi
    
    local SERVICE_ACCOUNT_NAME="velero-${CLUSTER_NAME}"
    local SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
    
    echo "Using project: $GCP_PROJECT_ID"
    
    # Check if service account already exists
    if gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project="$GCP_PROJECT_ID" &>/dev/null; then
        echo "Service account $SERVICE_ACCOUNT_EMAIL already exists"
    else
        echo "Creating service account..."
        gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
            --display-name="Velero service account for $CLUSTER_NAME" \
            --project="$GCP_PROJECT_ID"
        
        # Wait for service account to propagate
        echo "Waiting for service account to propagate..."
        sleep 10
    fi
    
    # Check and assign roles if not already assigned
    echo "Checking role assignments for service account..."
    
    # Define required roles
    local REQUIRED_ROLES=(
        "roles/compute.storageAdmin"
        "roles/storage.admin"
        "roles/compute.admin"
    )
    
    for role in "${REQUIRED_ROLES[@]}"; do
        # Check if role is already assigned
        if gcloud projects get-iam-policy "$GCP_PROJECT_ID" \
            --flatten="bindings[].members" \
            --filter="bindings.role:$role AND bindings.members:serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
            --format="value(bindings.members)" | grep -q "$SERVICE_ACCOUNT_EMAIL"; then
            echo "Role $role already assigned"
        else
            echo "Assigning role $role..."
            gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
                --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
                --role="$role" \
                --condition=None
        fi
    done
    
    # Get OIDC issuer URL from the cluster
    echo "Getting cluster OIDC issuer URL..."
    local SERVICE_ACCOUNT_ISSUER=$(oc get authentication.config.openshift.io cluster -o json | jq -r .spec.serviceAccountIssuer)
    
    if [[ -z "$SERVICE_ACCOUNT_ISSUER" || "$SERVICE_ACCOUNT_ISSUER" == "null" ]]; then
        echo "ERROR: Could not get OIDC issuer URL from cluster"
        return 1
    fi
    
    # Extract issuer URL without protocol
    local ISSUER_HOST=$(echo "$SERVICE_ACCOUNT_ISSUER" | sed 's|https://||')
    
    # Get or use existing workload identity pool and provider
    local POOL_ID="${GCP_POOL_ID:-${CLUSTER_NAME}}"
    local PROVIDER_ID="${GCP_PROVIDER_ID:-${CLUSTER_NAME}}"
    
    echo "Using workload identity pool: $POOL_ID"
    echo "Using workload identity provider: $PROVIDER_ID"
    
    # Get project number for workload identity binding
    local GCP_PROJECT_NUM=$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(projectNumber)")
    
    # Check if workload identity pool exists
    if ! gcloud iam workload-identity-pools describe "$POOL_ID" \
        --location="global" \
        --project="$GCP_PROJECT_ID" &>/dev/null; then
        echo "WARNING: Workload identity pool '$POOL_ID' not found in project '$GCP_PROJECT_ID'"
        echo "This is expected if the cluster was not created with workload identity federation"
        echo "Skipping workload identity binding..."
    else
        # Add policy binding for workload identity
        echo "Adding workload identity user binding..."
        gcloud iam service-accounts add-iam-policy-binding "$SERVICE_ACCOUNT_EMAIL" \
            --project="$GCP_PROJECT_ID" \
            --role="roles/iam.workloadIdentityUser" \
            --member="principalSet://iam.googleapis.com/projects/${GCP_PROJECT_NUM}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.namespace_name/openshift-adp#velero"
        
        # Also add binding for the specific subject format
        gcloud iam service-accounts add-iam-policy-binding "$SERVICE_ACCOUNT_EMAIL" \
            --project="$GCP_PROJECT_ID" \
            --role="roles/iam.workloadIdentityUser" \
            --member="principal://iam.googleapis.com/projects/${GCP_PROJECT_NUM}/locations/global/workloadIdentityPools/${POOL_ID}/subject/system:serviceaccount:openshift-adp:velero" \
            2>/dev/null || true
        
        # Add binding for OADP controller manager using principalSet format
        echo "Adding workload identity user binding for OADP controller manager..."
        gcloud iam service-accounts add-iam-policy-binding "$SERVICE_ACCOUNT_EMAIL" \
            --project="$GCP_PROJECT_ID" \
            --role="roles/iam.workloadIdentityUser" \
            --member="principalSet://iam.googleapis.com/projects/${GCP_PROJECT_NUM}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.namespace_name/openshift-adp#openshift-adp-controller-manager"
        
        # Also add binding for the specific subject format for controller manager
        gcloud iam service-accounts add-iam-policy-binding "$SERVICE_ACCOUNT_EMAIL" \
            --project="$GCP_PROJECT_ID" \
            --role="roles/iam.workloadIdentityUser" \
            --member="principal://iam.googleapis.com/projects/${GCP_PROJECT_NUM}/locations/global/workloadIdentityPools/${POOL_ID}/subject/system:serviceaccount:openshift-adp:openshift-adp-controller-manager" \
            2>/dev/null || true
    fi
    
    echo ""
    echo "Velero identity setup complete!"
    echo ""
    echo "Identity Configuration Summary:"
    echo "  Service Account Name: $SERVICE_ACCOUNT_NAME"
    echo "  Service Account Email: $SERVICE_ACCOUNT_EMAIL"
    echo "  Project ID: $GCP_PROJECT_ID"
    echo "  Project Number: $GCP_PROJECT_NUM"
    echo "  Workload Identity Pool: $POOL_ID"
    echo "  Workload Identity Provider: $PROVIDER_ID"
    echo ""
    echo "Service account has been configured with:"
    echo "  ✓ Compute Storage Admin role (for disk snapshots)"
    echo "  ✓ Storage Admin role (for object storage)"
    echo "  ✓ Compute Admin role (for VM operations)"
    if gcloud iam workload-identity-pools describe "$POOL_ID" \
        --location="global" \
        --project="$GCP_PROJECT_ID" &>/dev/null; then
        echo "  ✓ Workload Identity User binding for Velero"
    else
        echo "  ⚠️  Workload Identity binding skipped (pool not found)"
    fi
    
    echo ""
    echo "Export these variables for the OADP Makefile:"
    echo "export GCP_PROJECT_ID=$GCP_PROJECT_ID"
    echo "export GCP_PROJECT_NUM=$GCP_PROJECT_NUM"
    echo "export GCP_POOL_ID=$POOL_ID"
    echo "export GCP_PROVIDER_ID=$PROVIDER_ID"
    echo "export GCP_SA_EMAIL=$SERVICE_ACCOUNT_EMAIL"
    echo "export GCP_SERVICE_ACCOUNT_EMAIL=$SERVICE_ACCOUNT_EMAIL"
    
    # Export all required variables
    export GCP_PROJECT_NUM=$GCP_PROJECT_NUM
    export GCP_POOL_ID=$POOL_ID
    export GCP_PROVIDER_ID=$PROVIDER_ID
    export GCP_SA_EMAIL=$SERVICE_ACCOUNT_EMAIL
    export GCP_SERVICE_ACCOUNT_EMAIL=$SERVICE_ACCOUNT_EMAIL
    
    echo ""
    echo "Or run the OADP deployment directly with:"
    echo "make deploy-olm-stsflow-gcp GCP_PROJECT_ID=$GCP_PROJECT_ID GCP_PROJECT_NUM=$GCP_PROJECT_NUM GCP_POOL_ID=$POOL_ID GCP_PROVIDER_ID=$PROVIDER_ID GCP_SA_EMAIL=$SERVICE_ACCOUNT_EMAIL"
}

# Function to create GCS bucket for Velero backups
create-velero-bucket-for-gcp-cluster() {
    # Get cluster API URL
    local API_URL=$(oc whoami --show-server)
    
    # Extract cluster name from API URL
    local CLUSTER_NAME=$(echo "$API_URL" | sed 's|https://api\.||' | sed 's|\..*||')
    
    if [[ -z "$CLUSTER_NAME" ]]; then
        echo "ERROR: Could not determine cluster name from API URL: $API_URL"
        return 1
    fi
    
    echo "Creating Velero storage bucket for cluster: $CLUSTER_NAME"
    
    # Check if GCP_PROJECT_ID is set
    if [[ -z "$GCP_PROJECT_ID" ]]; then
        echo "ERROR: GCP_PROJECT_ID environment variable is not set"
        return 1
    fi
    
    echo "Using project: $GCP_PROJECT_ID"
    
    # Bucket name must be globally unique and follow GCS naming rules
    local BUCKET_NAME="velero-${GCP_PROJECT_ID}-${CLUSTER_NAME}"
    # Ensure bucket name is valid (lowercase, no underscores, max 63 chars)
    BUCKET_NAME=$(echo "$BUCKET_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | cut -c1-63)
    
    # Get region from environment or use default
    local REGION="${GCP_REGION:-us-central1}"
    
    # Check if bucket exists
    if gsutil ls -b "gs://${BUCKET_NAME}" &>/dev/null; then
        echo "Bucket gs://${BUCKET_NAME} already exists"
    else
        echo "Creating bucket: gs://${BUCKET_NAME} in region ${REGION}"
        gsutil mb -p "$GCP_PROJECT_ID" -c STANDARD -l "$REGION" "gs://${BUCKET_NAME}"
        
        # Enable versioning for better backup integrity
        echo "Enabling versioning on bucket..."
        gsutil versioning set on "gs://${BUCKET_NAME}"
        
        # Set lifecycle policy to delete old backups after 30 days (optional)
        echo "Setting lifecycle policy..."
        cat > /tmp/lifecycle.json << EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "Delete"},
        "condition": {
          "age": 30,
          "matchesPrefix": ["backups/"]
        }
      }
    ]
  }
}
EOF
        gsutil lifecycle set /tmp/lifecycle.json "gs://${BUCKET_NAME}"
        rm -f /tmp/lifecycle.json
    fi
    
    # Grant access to the service account
    local SERVICE_ACCOUNT_NAME="velero-${CLUSTER_NAME}"
    local SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
    
    # Check if service account exists
    if gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project="$GCP_PROJECT_ID" &>/dev/null; then
        echo "Granting bucket access to service account: $SERVICE_ACCOUNT_EMAIL"
        
        # Grant objectAdmin role on the bucket
        gsutil iam ch "serviceAccount:${SERVICE_ACCOUNT_EMAIL}:objectAdmin" "gs://${BUCKET_NAME}"
        
        # Grant legacy bucket writer role
        gsutil iam ch "serviceAccount:${SERVICE_ACCOUNT_EMAIL}:legacyBucketWriter" "gs://${BUCKET_NAME}"
    else
        echo "Service account not found. Run 'create-velero-identity-for-gcp-cluster' to create it."
    fi
    
    echo ""
    echo "Velero storage bucket setup complete!"
    echo ""
    echo "Storage configuration:"
    echo "  Bucket: gs://${BUCKET_NAME}"
    echo "  Region: ${REGION}"
    echo "  Project: ${GCP_PROJECT_ID}"
    echo ""
    if gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project="$GCP_PROJECT_ID" &>/dev/null; then
        echo "Access granted to:"
        echo "  ✓ Service Account: $SERVICE_ACCOUNT_EMAIL"
        echo "  ✓ Object Admin role on bucket"
        echo "  ✓ Legacy Bucket Writer role"
    fi
    echo ""
    echo "To configure Velero with this storage:"
    echo "1. Ensure you have run 'create-velero-identity-for-gcp-cluster' first"
    echo "2. Use the following in your BackupStorageLocation:"
    echo "   bucket: ${BUCKET_NAME}"
    echo "   prefix: velero"
    
    # Export for later use
    export VELERO_BUCKET_NAME="${BUCKET_NAME}"
}

# Function to create BackupStorageLocation YAML for Velero with GCP Workload Identity
create-velero-bsl-for-gcp-cluster() {
    # Get cluster API URL
    local API_URL=$(oc whoami --show-server)
    
    # Extract cluster name from API URL
    local CLUSTER_NAME=$(echo "$API_URL" | sed 's|https://api\.||' | sed 's|\..*||')
    
    if [[ -z "$CLUSTER_NAME" ]]; then
        echo "ERROR: Could not determine cluster name from API URL: $API_URL"
        return 1
    fi
    
    echo "Creating Velero BackupStorageLocation for cluster: $CLUSTER_NAME"
    
    # Check if GCP_PROJECT_ID is set
    if [[ -z "$GCP_PROJECT_ID" ]]; then
        echo "ERROR: GCP_PROJECT_ID environment variable is not set"
        return 1
    fi
    
    # Bucket name
    local BUCKET_NAME="velero-${GCP_PROJECT_ID}-${CLUSTER_NAME}"
    BUCKET_NAME=$(echo "$BUCKET_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | cut -c1-63)
    
    # Check if bucket exists
    if ! gsutil ls -b "gs://${BUCKET_NAME}" &>/dev/null; then
        echo "ERROR: Bucket gs://${BUCKET_NAME} not found"
        echo "Please run 'create-velero-bucket-for-gcp-cluster' first"
        return 1
    fi
    
    # Check if velero service account exists
    local SERVICE_ACCOUNT_NAME="velero-${CLUSTER_NAME}"
    local SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
    
    if ! gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project="$GCP_PROJECT_ID" &>/dev/null; then
        echo "ERROR: Velero service account not found"
        echo "Please run 'create-velero-identity-for-gcp-cluster' first"
        return 1
    fi
    
    # Create BSL YAML file
    local BSL_FILE="velero-bsl-${CLUSTER_NAME}.yaml"
    
    echo "Creating BackupStorageLocation YAML: $BSL_FILE"
    
    cat > "$BSL_FILE" << EOF
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: default
  namespace: openshift-adp
spec:
  # Name of the object store plugin to use to connect to this location.
  provider: velero.io/gcp
  
  objectStorage:
    # The bucket in which to store backups.
    bucket: ${BUCKET_NAME}
    
    # The prefix within the bucket under which to store backups.
    prefix: velero
EOF

    echo ""
    echo "BackupStorageLocation YAML created: $BSL_FILE"
    echo ""
    echo "Prerequisites checklist:"
    echo "✓ Storage bucket: gs://${BUCKET_NAME}"
    echo "✓ Velero service account: $SERVICE_ACCOUNT_EMAIL"
    echo "✓ Project ID: $GCP_PROJECT_ID"
    echo ""
    echo "To apply this BackupStorageLocation:"
    echo "  kubectl apply -f $BSL_FILE"
    echo ""
    echo "Make sure you have:"
    echo "1. OADP (OpenShift API for Data Protection) installed"
    echo "2. Service account 'velero' in 'openshift-adp' namespace with workload identity annotation"
    echo "3. Workload identity binding configured for 'system:serviceaccount:openshift-adp:velero'"
    echo ""
    echo "Note: This BSL is configured for the 'openshift-adp' namespace used by OADP"
}

# Function to create DataProtectionApplication YAML for OADP with GCP Workload Identity
create-velero-dpa-for-gcp-cluster() {
    # Get cluster API URL
    local API_URL=$(oc whoami --show-server)
    
    # Extract cluster name from API URL
    local CLUSTER_NAME=$(echo "$API_URL" | sed 's|https://api\.||' | sed 's|\..*||')
    
    if [[ -z "$CLUSTER_NAME" ]]; then
        echo "ERROR: Could not determine cluster name from API URL: $API_URL"
        return 1
    fi
    
    echo "Creating DataProtectionApplication for cluster: $CLUSTER_NAME"
    
    # Check if GCP_PROJECT_ID is set
    if [[ -z "$GCP_PROJECT_ID" ]]; then
        echo "ERROR: GCP_PROJECT_ID environment variable is not set"
        return 1
    fi
    
    # Bucket name
    local BUCKET_NAME="velero-${GCP_PROJECT_ID}-${CLUSTER_NAME}"
    BUCKET_NAME=$(echo "$BUCKET_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | cut -c1-63)
    
    # Check if bucket exists
    if ! gsutil ls -b "gs://${BUCKET_NAME}" &>/dev/null; then
        echo "ERROR: Bucket gs://${BUCKET_NAME} not found"
        echo "Please run 'create-velero-bucket-for-gcp-cluster' first"
        return 1
    fi
    
    # Check if velero service account exists
    local SERVICE_ACCOUNT_NAME="velero-${CLUSTER_NAME}"
    local SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
    
    if ! gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project="$GCP_PROJECT_ID" &>/dev/null; then
        echo "ERROR: Velero service account not found"
        echo "Please run 'create-velero-identity-for-gcp-cluster' first"
        return 1
    fi
    
    # Create DPA YAML file
    local DPA_FILE="velero-dpa-${CLUSTER_NAME}.yaml"
    
    echo "Creating DataProtectionApplication YAML: $DPA_FILE"
    
    cat > "$DPA_FILE" << EOF
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa
  namespace: openshift-adp
spec:
  configuration:
    velero:
      # Use OpenShift plugin for OpenShift-specific features
      defaultPlugins:
        - openshift
        - gcp
        - csi
      # Resource requests/limits for Velero pod
      resourceAllocations:
        limits:
          cpu: 1000m
          memory: 512Mi
        requests:
          cpu: 500m
          memory: 256Mi
    # Node agent configuration (formerly Restic)
    nodeAgent:
      enable: true
      uploaderType: kopia
      # Configure the DaemonSet node selector
      nodeSelector:
        node-role.kubernetes.io/worker: ""
  # TODO: fix - backupImages should be enabled once image backup is properly configured
  backupImages: false
  backupLocations:
    - name: default
      velero:
        # GCP provider configuration
        provider: velero.io/gcp
        default: true
        # Credential secret reference
        credential:
          name: cloud-credentials-gcp
          key: service_account.json
        # Storage configuration
        objectStorage:
          bucket: ${BUCKET_NAME}
          prefix: velero
  # Volume snapshot locations for GCP snapshots
  snapshotLocations:
    - name: default
      velero:
        provider: gcp
        # Credential secret reference
        credential:
          name: cloud-credentials-gcp
          key: service_account.json
        config:
          snapshotLocation: ${GCP_REGION:-us-central1}
EOF

    echo ""
    echo "DataProtectionApplication YAML created: $DPA_FILE"
    echo ""
    echo "Prerequisites checklist:"
    echo "✓ Storage bucket: gs://${BUCKET_NAME}"
    echo "✓ Velero service account: $SERVICE_ACCOUNT_EMAIL"
    echo "✓ Project ID: $GCP_PROJECT_ID"
    echo ""
    echo "IMPORTANT: Before applying the DPA, ensure the Velero service account is properly annotated:"
    echo "  kubectl annotate serviceaccount velero -n openshift-adp iam.gke.io/gcp-service-account=$SERVICE_ACCOUNT_EMAIL --overwrite"
    echo ""
    echo "To apply this DataProtectionApplication:"
    echo "  kubectl apply -f $DPA_FILE"
    echo ""
    echo "Make sure you have:"
    echo "1. OADP operator installed in 'openshift-adp' namespace"
    echo "2. Completed the STS configuration flow (the operator will create the cloud-credentials-gcp secret)"
    echo "3. The velero service account annotated with workload identity"
    echo ""
    echo "After applying the DPA, check the status with:"
    echo "  kubectl get dpa dpa -n openshift-adp -o yaml"
    echo ""
    echo "Verify the deployment:"
    echo "  kubectl get secret cloud-credentials-gcp -n openshift-adp"
    echo "  kubectl get pods -n openshift-adp"
    echo "  velero version"
}

# Function to setup complete Velero/OADP for current GCP OpenShift cluster
setup-velero-oadp-for-gcp-cluster() {
    echo "Starting complete Velero/OADP setup for GCP OpenShift cluster..."
    echo "================================================================"
    
    # Get cluster API URL
    local API_URL=$(oc whoami --show-server 2>/dev/null)
    
    if [[ -z "$API_URL" ]]; then
        echo "ERROR: Not connected to an OpenShift cluster. Please login first."
        return 1
    fi
    
    # Extract cluster name from API URL
    local CLUSTER_NAME=$(echo "$API_URL" | sed 's|https://api\.||' | sed 's|\..*||')
    
    if [[ -z "$CLUSTER_NAME" ]]; then
        echo "ERROR: Could not determine cluster name from API URL: $API_URL"
        return 1
    fi
    
    echo "Cluster: $CLUSTER_NAME"
    echo ""
    
    # Step 1: Create Velero identity
    echo "Step 1: Creating Velero service account..."
    echo "-----------------------------------"
    if ! create-velero-identity-for-gcp-cluster; then
        echo "ERROR: Failed to create Velero service account"
        return 1
    fi
    echo ""
    
    # Step 2: Create storage bucket
    echo "Step 2: Creating Velero storage bucket..."
    echo "-------------------------------------------"
    if ! create-velero-bucket-for-gcp-cluster; then
        echo "ERROR: Failed to create Velero storage bucket"
        return 1
    fi
    echo ""
    
    # Step 3: Deploy OADP operator with STS flow
    echo "Step 3: Deploying OADP operator with STS flow..."
    echo "------------------------------------------------"
    
    # Check if we're in an OADP repo directory
    if [[ -f "Makefile" ]] && grep -q "deploy-olm-stsflow-gcp" Makefile 2>/dev/null; then
        echo "Found OADP Makefile in current directory"
    else
        echo "WARNING: Not in OADP operator directory. Please ensure you're in the correct directory."
        echo "You can clone it with: git clone https://github.com/openshift/oadp-operator.git"
        echo ""
        echo "Would you like to continue anyway? (y/N)"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "Aborting setup"
            return 1
        fi
    fi
    
    # The required variables should already be exported by create-velero-identity-for-gcp-cluster
    if [[ -z "$GCP_PROJECT_ID" ]] || [[ -z "$GCP_PROJECT_NUM" ]] || [[ -z "$GCP_POOL_ID" ]] || [[ -z "$GCP_PROVIDER_ID" ]] || [[ -z "$GCP_SA_EMAIL" ]]; then
        echo "ERROR: Required GCP environment variables not set. This should have been done by create-velero-identity-for-gcp-cluster"
        echo "Missing one or more of: GCP_PROJECT_ID, GCP_PROJECT_NUM, GCP_POOL_ID, GCP_PROVIDER_ID, GCP_SA_EMAIL"
        return 1
    fi
    
    echo "Running: make deploy-olm-stsflow-gcp"
    if ! make deploy-olm-stsflow-gcp; then
        echo "ERROR: Failed to deploy OADP operator"
        echo "Please check the output above for errors"
        return 1
    fi
    echo ""
    
    # Wait for operator to be ready
    echo "Waiting for OADP operator to be ready..."
    local retries=30
    while [[ $retries -gt 0 ]]; do
        if oc get pods -n openshift-adp 2>/dev/null | grep -q "oadp-operator.*Running"; then
            echo "OADP operator is running"
            break
        fi
        echo -n "."
        sleep 5
        ((retries--))
    done
    
    if [[ $retries -eq 0 ]]; then
        echo ""
        echo "WARNING: OADP operator may not be fully ready yet"
    fi
    echo ""
    
    # Step 4: Create and apply DataProtectionApplication
    echo "Step 4: Creating and applying DataProtectionApplication..."
    echo "---------------------------------------------------------"
    if ! create-velero-dpa-for-gcp-cluster; then
        echo "ERROR: Failed to create DataProtectionApplication YAML"
        return 1
    fi
    
    # Get the DPA file name
    local DPA_FILE="velero-dpa-${CLUSTER_NAME}.yaml"
    
    if [[ ! -f "$DPA_FILE" ]]; then
        echo "ERROR: DataProtectionApplication file not found: $DPA_FILE"
        return 1
    fi
    
    echo "Applying DataProtectionApplication..."
    if ! oc apply -f "$DPA_FILE"; then
        echo "ERROR: Failed to apply DataProtectionApplication"
        return 1
    fi
    echo ""
    
    # Step 5: Wait for Velero to be ready
    echo "Step 5: Waiting for Velero deployment to be ready..."
    echo "---------------------------------------------------"
    local velero_ready=false
    retries=60  # 5 minutes timeout
    
    while [[ $retries -gt 0 ]]; do
        if oc get pods -n openshift-adp -l app.kubernetes.io/name=velero 2>/dev/null | grep -q "velero.*Running"; then
            velero_ready=true
            break
        fi
        echo -n "."
        sleep 5
        ((retries--))
    done
    
    echo ""
    
    if [[ "$velero_ready" == "true" ]]; then
        echo "✓ Velero is running"
    else
        echo "⚠️  Velero may not be fully ready yet"
    fi
    
    # Step 6: Validate setup
    echo ""
    echo "Step 6: Validating Velero setup..."
    echo "----------------------------------"
    
    # Check Velero version
    if command -v velero &>/dev/null; then
        echo "Velero CLI version:"
        velero version --client-only
    else
        echo "Velero CLI not found. Install it from: https://velero.io/docs/main/basic-install/#install-the-cli"
    fi
    
    # Check DPA status
    echo ""
    echo "DataProtectionApplication status:"
    oc get dpa dpa -n openshift-adp -o jsonpath='{.status.conditions[?(@.type=="Reconciled")]}' | jq '.' 2>/dev/null || echo "Status not yet available"
    
    # Check pods
    echo ""
    echo "OADP/Velero pods:"
    oc get pods -n openshift-adp
    
    # Final summary
    echo ""
    echo "================================================================"
    echo "Velero/OADP Setup Complete!"
    echo "================================================================"
    echo ""
    echo "Next steps:"
    echo "1. Verify the setup with: oc get all -n openshift-adp"
    echo "2. Check backup storage location: oc get backupstoragelocation -n openshift-adp"
    echo "3. Create your first backup: velero backup create test-backup --include-namespaces=<namespace>"
    echo ""
    echo "DataProtectionApplication file saved as: $DPA_FILE"
    echo ""
    echo "To troubleshoot issues:"
    echo "- Check DPA status: oc describe dpa dpa -n openshift-adp"
    echo "- Check Velero logs: oc logs -n openshift-adp -l app.kubernetes.io/name=velero"
}

# Alias for convenience
alias setup-velero-gcp='setup-velero-oadp-for-gcp-cluster'
alias setup-cluster-with-oadp-gcp='create-ocp-gcp-wif && oc login -u kubeadmin -p $(cat $OCP_CREATE_DIR/auth/kubeadmin-password) $(oc whoami --show-server) && create-velero-identity-for-gcp-cluster && create-velero-bucket-for-gcp-cluster && make deploy-olm-stsflow-gcp && create-velero-dpa-for-gcp-cluster && oc apply -f velero-dpa-*.yaml'

trigger-create-ocp-gcp-wif() {
    local stream=${1:-dev-preview}
    local action=${2:-create}
    local repo="kaovilai/dotfiles"

    gh workflow run create-ocp-gcp-wif.yml \
        -f stream="$stream" \
        -f action="$action" \
        --repo "$repo"

    echo "Triggered create-ocp-gcp-wif (stream=$stream, action=$action)"
    echo "Watch:  gh run watch --repo $repo"
    echo "Fetch:  download-ocp-gcp-wif-auth <RUN_ID>"
}

download-ocp-gcp-wif-auth() {
    local run_id=$1
    local repo="kaovilai/dotfiles"

    if [[ -z "$run_id" ]]; then
        echo "Usage: download-ocp-gcp-wif-auth <RUN_ID>"
        echo "Find run ID: gh run list --workflow create-ocp-gcp-wif.yml --repo $repo"
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

trigger-destroy-ocp-gcp-wif() {
    local metadata_path=$1
    local repo="kaovilai/dotfiles"
    local today=${TODAY:-$(date +%y%m%d)}

    if [[ -z "$metadata_path" ]]; then
        local live_dir="$OCP_MANIFESTS_DIR/$today-gcp-wif"
        local backup_path="$OCP_MANIFESTS_DIR/.metadata-backup-$today-gcp-wif.json"
        if [[ -f "$live_dir/metadata.json" ]]; then
            metadata_path="$live_dir/metadata.json"
        elif [[ -f "$backup_path" ]]; then
            metadata_path="$backup_path"
        else
            echo "ERROR: no metadata.json found for $today-gcp-wif (checked $live_dir/metadata.json and $backup_path)"
            echo "Usage: trigger-destroy-ocp-gcp-wif [path/to/metadata.json]"
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

    echo "About to trigger REMOTE destroy of cluster '$cluster_name' via GitHub Actions."
    echo "This deletes real GCP infrastructure and cannot be undone."
    local confirm
    read "confirm?Type the cluster name to confirm ($cluster_name): "
    if [[ "$confirm" != "$cluster_name" ]]; then
        echo "Confirmation did not match, aborting. Nothing was triggered."
        return 1
    fi

    local encoded; encoded=$(base64 < "$metadata_path" | tr -d '\n')

    gh workflow run create-ocp-gcp-wif.yml \
        -f action="delete" \
        -f metadata_json="$encoded" \
        --repo "$repo"

    echo "Triggered remote destroy for $cluster_name"
    echo "Watch:  gh run watch --repo $repo"
    echo "Safe to close the laptop now -- the runner finishes independently."
}
