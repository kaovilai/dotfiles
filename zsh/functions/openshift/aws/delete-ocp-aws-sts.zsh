delete-ocp-aws-sts() {
    # Core implementation for AWS STS OpenShift cluster deletion
    # Parameters:
    #   $1 - Cluster name or help
    #   $2 - Architecture suffix (arm64 or amd64)

    if [[ "$(uname)" == "Darwin" ]]; then
        unset SSH_AUTH_SOCK
    fi

    local EC_VERSION; EC_VERSION=$(get-ocp-latest-ec-version)
    local OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-openshift-install-${EC_VERSION}}
    local ARCH_SUFFIX=$2

    if [[ $1 == "help" ]]; then
        echo "Usage: delete-ocp-aws-sts [CLUSTER_NAME]"
        echo "       delete-ocp-aws-sts-arm64 [CLUSTER_NAME]"
        echo "       delete-ocp-aws-sts-amd64 [CLUSTER_NAME]"
        echo "Delete an OpenShift cluster on AWS that was created with STS (ccoctl)"
        echo ""
        echo "Options:"
        echo "  help          Display this help message"
        echo "  CLUSTER_NAME  Optional: Specify a custom cluster name (default: auto-detected)"
        echo ""
        echo "This function:"
        echo "  - Auto-detects architecture from existing cluster directories"
        echo "  - Destroys the cluster using openshift-install"
        echo "  - Deletes the AWS STS resources using ccoctl aws delete"
        echo "  - Removes the installation directory"
        return 0
    fi

    if [[ -z "$TODAY" ]]; then
        echo "WARNING: TODAY variable is empty, using current date"
        TODAY=$(date +%y%m%d)
    fi

    if [[ -z "$ARCH_SUFFIX" && -n $1 && $1 =~ ^tkaovila-([0-9]{6,8})-sts-(arm64|amd64)(-[0-9]+)?$ ]]; then
        ARCH_SUFFIX=${match[2]}
    fi
    if [[ -z "$ARCH_SUFFIX" ]]; then
        echo "Auto-detecting AWS STS cluster architecture..."
        local found_clusters=()
        local found_archs=()

        if [[ -d "$OCP_MANIFESTS_DIR" ]]; then
            for dir in "$OCP_MANIFESTS_DIR"/$TODAY-aws-sts-*(/N); do
                local dir_basename="${dir:t}"
                if [[ $dir_basename =~ ^[0-9]{6,8}-aws-sts-(arm64|amd64)(-[0-9]+)?$ ]]; then
                    local arch=${match[1]}
                    found_clusters+=("$dir_basename")
                    found_archs+=("$arch")
                fi
            done
        fi

        if [[ ${#found_clusters[@]} -eq 0 ]]; then
            echo "ERROR: No AWS STS clusters found for today ($TODAY)"
            echo ""
            echo "Usage:"
            echo "  delete-ocp-aws-sts-arm64    - Delete ARM64 STS cluster"
            echo "  delete-ocp-aws-sts-amd64    - Delete AMD64 STS cluster"
            echo ""
            echo "Or specify a directory:"
            echo "  delete-ocp-aws-sts-dir /path/to/cluster/directory"
            return 1
        elif [[ ${#found_clusters[@]} -eq 1 ]]; then
            ARCH_SUFFIX="${found_archs[1]}"
            echo "Found cluster: ${found_clusters[1]} (${ARCH_SUFFIX})"
        else
            echo "Found multiple AWS STS clusters for today:"
            local selection_list=""
            for i in {1..${#found_clusters[@]}}; do
                selection_list+="$i. ${found_clusters[$i]} (${found_archs[$i]})"$'\n'
            done
            selection_list=${selection_list%$'\n'}

            local selected
            if command -v fzf >/dev/null 2>&1; then
                selected=$(echo "$selection_list" | fzf --height 40% --reverse --header "Select a cluster to delete")
            else
                echo "$selection_list"
                echo ""
                read "choice?Enter choice (1-${#found_clusters[@]}): "
                if [[ ! $choice =~ ^[0-9]+$ || $choice -lt 1 || $choice -gt ${#found_clusters[@]} ]]; then
                    echo "ERROR: Invalid selection"
                    return 1
                fi
                selected="$choice."
            fi

            if [[ -z "$selected" ]]; then
                return 0
            fi

            local choice; choice=$(echo "$selected" | awk -F'.' '{print $1}')
            ARCH_SUFFIX="${found_archs[$choice]}"
            echo "Selected: ${found_clusters[$choice]} (${ARCH_SUFFIX})"
        fi
        echo ""
    fi

    OCP_CREATE_DIR=$OCP_MANIFESTS_DIR/$TODAY-aws-sts-$ARCH_SUFFIX
    CLUSTER_NAME=tkaovila-$TODAY-sts-$ARCH_SUFFIX

    if [[ -n $1 ]]; then
        CLUSTER_NAME=$1
        if [[ $1 =~ ^tkaovila-([0-9]{6,8})-sts-(arm64|amd64)(-[0-9]+)?$ ]]; then
            if [[ -n "$ARCH_SUFFIX" && "$ARCH_SUFFIX" != "${match[2]}" ]]; then
                echo "WARNING: cluster name '$1' encodes arch ${match[2]}, but ${ARCH_SUFFIX} was requested -- using ${match[2]}"
                ARCH_SUFFIX=${match[2]}
            fi
            OCP_CREATE_DIR=$OCP_MANIFESTS_DIR/${match[1]}-aws-sts-${match[2]}${match[3]}
        elif [[ $1 != "cleanup-legacy" ]]; then
            echo "ERROR: cluster name '$1' does not match tkaovila-<date>-sts-<arch>[-N]" >&2
            echo "       Use delete-ocp-aws-sts-dir for an explicit directory." >&2
            return 1
        fi
    fi

    echo "Destroying AWS STS cluster in directory: $OCP_CREATE_DIR"
    $OPENSHIFT_INSTALL destroy cluster --dir $OCP_CREATE_DIR || echo "no existing cluster"
    echo "Destroying AWS STS bootstrap in directory: $OCP_CREATE_DIR"
    $OPENSHIFT_INSTALL destroy bootstrap --dir $OCP_CREATE_DIR || echo "no existing bootstrap"
    (ccoctl aws delete \
    --name $CLUSTER_NAME \
    --region ${AWS_REGION:-us-east-1} \
    --credentials-requests-dir $OCP_CREATE_DIR/credentials-requests && echo "cleaned up ccoctl aws resources") || true
    ((rm -r $OCP_CREATE_DIR && echo "removed existing create dir") || (true && echo "no existing install dir")) || return 1
}

function delete-ocp-aws-sts-arm64() {
    delete-ocp-aws-sts "$1" "arm64"
}

function delete-ocp-aws-sts-amd64() {
    delete-ocp-aws-sts "$1" "amd64"
}

delete-ocp-aws-sts-dir() {
    # Delete AWS STS OpenShift cluster based on a directory name
    # Parameters:
    #   $1 - Directory name (e.g., ~/OCP/manifests/20250410-aws-sts-arm64)

    if [[ $1 == "help" ]]; then
        echo "Usage: delete-ocp-aws-sts-dir DIRECTORY_PATH"
        echo "Delete an OpenShift cluster on AWS (STS) based on the directory name"
        echo ""
        echo "Parameters:"
        echo "  DIRECTORY_PATH  Path to the cluster directory (e.g., ~/OCP/manifests/20250410-aws-sts-arm64)"
        return 0
    fi

    if [ ! -d "$1" ]; then
        echo "ERROR: Directory $1 does not exist"
        return 1
    fi

    local dir_basename="${1:t}"
    echo "DEBUG: Processing directory basename: $dir_basename"

    if [[ $dir_basename =~ ^([0-9]{6,8})-aws-sts-(arm64|amd64)(-[0-9]+)?$ ]]; then
        local extracted_date=${match[1]}
        local extracted_arch=${match[2]}
        local extracted_suffix=${match[3]}

        echo "Extracted date: $extracted_date, architecture: $extracted_arch, suffix: ${extracted_suffix:-none}"

        local original_today=$TODAY
        TODAY=$extracted_date

        local cluster_name="tkaovila-$extracted_date-sts-$extracted_arch$extracted_suffix"
        echo "Using cluster name: $cluster_name"

        if [[ "$extracted_arch" == "arm64" ]]; then
            delete-ocp-aws-sts-arm64 "$cluster_name"
        else
            delete-ocp-aws-sts-amd64 "$cluster_name"
        fi

        TODAY=$original_today
    else
        echo "ERROR: Directory name format not recognized: $dir_basename"
        echo "Expected format: YYMMDD-aws-sts-ARCH (e.g., 260428-aws-sts-arm64)"
        return 1
    fi
}
