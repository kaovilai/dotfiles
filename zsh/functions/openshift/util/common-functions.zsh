# Common utility functions for OpenShift cluster creation
#
# This file contains shared utility functions used across all OpenShift cluster
# creation scripts (AWS, Azure, GCP, ROSA).
#
# Functions provided:
#   - prompt-release-stream: Interactive release stream selection (dev-preview/stable)
#   - get-release-image: Get release image URL for specific stream and architecture
#   - validate-env-vars: Validate required environment variables are set
#   - get-openshift-install: Find or install openshift-install binary
#   - handle-registry-login: Login to container registries (podman)
#   - update-pull-secret-with-podman: Update pull-secret.txt with registry credentials
#   - create-install-config-header: Generate standard install-config.yaml header
#   - add-credentials-to-install-config: Add pull secret and SSH key to install-config
#   - generate-unique-cluster-name: Generate unique cluster name to avoid conflicts
#   - cleanup-on-failure: Clean up resources when cluster creation fails

# Function to prompt for release version selection
# Usage: stream=$(prompt-release-stream)
# Description: Shows all available OCP versions in fzf for selection.
#   Sets OCP_RELEASE_VERSION with the selected version.
# Returns: "dev-preview" or "stable" to stdout (for backward compat)
prompt-release-stream() {
    # Step 1: Discover available ranges dynamically from release controller
    local ranges
    ranges=$(curl -sm 10 \
        'https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestreams/accepted' \
        2>/dev/null \
    | jq -r 'keys[] | select(test("^[0-9]+\\.[0-9]"))' \
    | grep -oE '^[0-9]+\.[0-9]+' | sort -Vru)

    if [[ -z "$ranges" ]]; then
        echo "WARN: Could not fetch version ranges, falling back to latest" >&2
        unset OCP_RELEASE_VERSION
        echo "dev-preview"
        return 0
    fi

    # Step 2: Pick major.minor range (instant, no extra fetch)
    local chosen_range
    if command -v fzf >/dev/null 2>&1; then
        chosen_range=$(echo "$ranges" | fzf --height 30% --reverse \
            --header "Select version range" \
            --prompt "Range> ")
    else
        echo "Available ranges:" >&2
        echo "$ranges" | cat -n >&2
        echo -n "Enter range (e.g. 4.17): " >&2
        read -r chosen_range </dev/tty
    fi

    if [[ -z "$chosen_range" ]]; then
        echo "No range selected, using latest dev-preview" >&2
        unset OCP_RELEASE_VERSION
        echo "dev-preview"
        return 0
    fi

    # Step 3: Fetch versions for chosen range only (single API call)
    echo "Fetching ${chosen_range}.x versions..." >&2
    local versions
    versions=$(curl -sm 15 \
        "https://quay.io/api/v1/repository/openshift-release-dev/ocp-release/tag/?limit=100&onlyActiveTags=true&filter_tag_name=like:${chosen_range}.%-x86_64" \
        2>/dev/null \
    | jq -r '
        [.tags[].name
        | select(test("-multi") | not)
        | rtrimstr("-x86_64")]
        | unique | sort_by(split(".-") | map(tonumber? // 99)) | reverse
        | .[] as $v
        | if ($v | test("ec\\.|rc\\.")) then "[dev-preview] \($v)"
          else "[stable-\($v | split(".")[0:2] | join("."))] \($v)"
          end
    ' 2>/dev/null)

    if [[ -z "$versions" ]]; then
        echo "WARN: No versions found for ${chosen_range}, falling back to latest" >&2
        unset OCP_RELEASE_VERSION
        echo "dev-preview"
        return 0
    fi

    # Step 4: Pick specific version
    local selected
    if command -v fzf >/dev/null 2>&1; then
        selected=$(echo "$versions" | fzf --height 40% --reverse \
            --header "Select ${chosen_range}.x version" \
            --prompt "Version> ")
    else
        echo "" >&2
        echo "$versions" | cat -n >&2
        echo -n "Enter line number or version: " >&2
        read -r selected </dev/tty
        if [[ "$selected" =~ ^[0-9]+$ ]]; then
            selected=$(echo "$versions" | sed -n "${selected}p")
        fi
    fi

    if [[ -z "$selected" ]]; then
        echo "No version selected, using latest dev-preview" >&2
        unset OCP_RELEASE_VERSION
        echo "dev-preview"
        return 0
    fi

    local version; version=$(echo "$selected" | awk '{print $2}')
    local stream_tag; stream_tag=$(echo "$selected" | awk '{print $1}' | tr -d '[]')

    echo "INFO: Selected version $version ($stream_tag)" >&2

    if [[ "$stream_tag" == "dev-preview" ]]; then
        echo "dev-preview $version"
    else
        echo "stable $version"
    fi
}

# Function to get release image based on stream and architecture
# Usage: image=$(get-release-image "stable" "amd64")
#        image=$(get-release-image "dev-preview" "arm64")
#        image=$(get-release-image "stable" "multi")
# Description: Gets the appropriate release image URL for the given stream and architecture
# Parameters:
#   $1 - stream: "stable" or "dev-preview"
#   $2 - architecture: "amd64", "arm64", or "multi" (multi-arch)
# Returns: Release image URL to stdout, exits with 1 on error
get-release-image() {
    local stream=$1
    local architecture=$2

    # If a specific version was selected, construct pullSpec directly
    if [[ -n "$OCP_RELEASE_VERSION" ]]; then
        local quay_arch
        case "$architecture" in
            "amd64"|"x86_64") quay_arch="x86_64" ;;
            "arm64"|"aarch64") quay_arch="aarch64" ;;
            "multi") quay_arch="multi" ;;
            *)
                echo "ERROR: Unknown architecture: $architecture" >&2
                return 1
                ;;
        esac
        echo "quay.io/openshift-release-dev/ocp-release:${OCP_RELEASE_VERSION}-${quay_arch}"
        return 0
    fi

    if [[ "$stream" == "stable" ]]; then
        case "$architecture" in
            "amd64"|"x86_64")
                get-ocp-release-image-stable-amd64
                ;;
            "arm64"|"aarch64")
                get-ocp-release-image-stable-arm64
                ;;
            "multi")
                get-ocp-release-image-stable-multi
                ;;
            *)
                echo "ERROR: Unknown architecture: $architecture" >&2
                return 1
                ;;
        esac
    else
        case "$architecture" in
            "amd64"|"x86_64")
                get-ocp-release-image-amd64
                ;;
            "arm64"|"aarch64")
                get-ocp-release-image-arm64
                ;;
            "multi")
                get-ocp-release-image-multi
                ;;
            *)
                echo "ERROR: Unknown architecture: $architecture" >&2
                return 1
                ;;
        esac
    fi
}

# Function to validate environment variables
# Usage: validate-env-vars "aws" AWS_REGION AWS_PROFILE
#        validate-env-vars "azure" AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID
# Description: Validates that all required environment variables are set
# Parameters:
#   $1 - provider: Cloud provider name (for error messages only)
#   $@ - variable names to validate
# Returns: 0 if all variables are set, 1 if any are missing
# Example:
#   validate-env-vars "azure" AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID || return 1
validate-env-vars() {
    local provider=$1
    shift
    local required_vars=("$@")
    
    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${(P)var}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "ERROR: The following required environment variables are not set:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        echo ""
        echo "Please set these variables before running this function."
        return 1
    fi
    
    return 0
}

# Internal helper to download openshift-install binary
_download-openshift-install() {
    local version=$1
    local arch=$2

    echo "Installing openshift-install ${version} for $arch architecture..." >&2

    local os=""
    case "$(uname -s)" in
        "Darwin") os="mac" ;;
        "Linux") os="linux" ;;
        *)
            echo "ERROR: Unsupported OS: $(uname -s)" >&2
            return 1
            ;;
    esac

    local url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp-dev-preview/${version}/openshift-install-${os}-${arch}.tar.gz"
    local temp_dir; temp_dir=$(mktemp -d)

    echo "Downloading from: $url" >&2
    if curl -sL "$url" -o "${temp_dir}/openshift-install.tar.gz"; then
        tar -xzf "${temp_dir}/openshift-install.tar.gz" -C "${temp_dir}"
        if sudo mv "${temp_dir}/openshift-install" "/usr/local/bin/openshift-install-${version}"; then
            sudo chmod +x "/usr/local/bin/openshift-install-${version}"
            echo "Successfully installed openshift-install-${version}" >&2
            rm -rf "${temp_dir}"
            echo "openshift-install-${version}"
            return 0
        else
            echo "ERROR: Failed to install openshift-install to /usr/local/bin" >&2
            rm -rf "${temp_dir}"
            return 1
        fi
    else
        echo "ERROR: Failed to download openshift-install" >&2
        rm -rf "${temp_dir}"
        return 1
    fi
}

# Function to get openshift-install binary
# Usage: OPENSHIFT_INSTALL=$(get-openshift-install)
# Description: Finds an appropriate openshift-install binary or offers to install one
#              Checks for versioned binaries (e.g., openshift-install-4.17.0) first,
#              then falls back to generic 'openshift-install' command.
#              If not found, offers to download and install the latest EC version.
# Returns: Path to openshift-install binary to stdout
# Environment:
#   OPENSHIFT_INSTALL - If set, uses this path instead of searching
# Example:
#   local installer=$(get-openshift-install)
#   [[ -z "$installer" ]] && return 1
#   $installer version
get-openshift-install() {
    local ec_version; ec_version=$(get-ocp-latest-ec-version)
    local stable_version; stable_version=$(get-ocp-latest-stable-version)

    # Detect host architecture
    local host_arch=""
    case "$(uname -m)" in
        "x86_64"|"amd64")
            host_arch="amd64"
            ;;
        "arm64"|"aarch64")
            host_arch="arm64"
            ;;
        *)
            echo "ERROR: Unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac

    # Check if user has set a specific version
    if [[ -n "$OPENSHIFT_INSTALL" ]]; then
        echo "$OPENSHIFT_INSTALL"
        return
    fi

    # Check if binary is executable on this host
    # Note: "release architecture" in openshift-install version output is the
    # TARGET cluster architecture, not the binary's CPU architecture.
    local check_binary_arch() {
        local binary=$1
        if $binary version &>/dev/null; then
            return 0  # Binary runs successfully
        fi
        return 2  # Binary not executable (wrong CPU arch, missing deps, etc.)
    }

    # Try EC version first, then stable, then generic
    for binary in "openshift-install-${ec_version}" "openshift-install-${stable_version}" "openshift-install"; do
        if command -v "$binary" &> /dev/null && check_binary_arch "$binary"; then
            echo "$binary"
            return 0
        fi
    done

    # No suitable binary found, offer to install
    if true; then
        echo "ERROR: No openshift-install binary found" >&2
        echo "" >&2
        echo "Would you like to install openshift-install version ${ec_version}? (y/n)" >&2
        local install_choice
        read -r install_choice
        
        if [[ "$install_choice" == "y" || "$install_choice" == "Y" ]]; then
            _download-openshift-install "$ec_version" "$host_arch"
            return $?
        else
            echo "Please install openshift-install or set OPENSHIFT_INSTALL variable" >&2
            return 1
        fi
    fi
}

# Function to handle registry login
# Usage: handle-registry-login "registry.ci.openshift.org"
#        handle-registry-login "quay.io"
# Description: Ensures user is logged into the specified container registry using podman
#              For registry.ci.openshift.org, opens browser for OAuth login
# Parameters:
#   $1 - registry: Registry hostname to login to
# Example:
#   handle-registry-login "registry.ci.openshift.org"
handle-registry-login() {
    local registry=$1
    
    echo "INFO: Checking if podman is logged into $registry"
    if ! podman login --get-login "$registry" &>/dev/null; then
        if [[ "$registry" == "registry.ci.openshift.org" ]]; then
            echo "Opening browser for registry.ci.openshift.org login..."
            open "https://oauth-openshift.apps.ci.l2s4.p1.openshiftapps.com/oauth/authorize?client_id=openshift-browser-client&redirect_uri=https%3A%2F%2Foauth-openshift.apps.ci.l2s4.p1.openshiftapps.com%2Foauth%2Ftoken%2Fdisplay&response_type=code"
            echo "Login URL opened in browser. Please copy the login command from the browser and paste it below:"
            local login_command
            read -r login_command
            if [[ "$login_command" != podman\ login* && "$login_command" != oc\ login* && "$login_command" != docker\ login* ]]; then
                echo "ERROR: Only 'podman login', 'oc login', or 'docker login' commands are accepted"
                return 1
            fi
            echo "Executing login command..."
            eval "$login_command"
        else
            echo "Please login to $registry:"
            podman login "$registry"
        fi
    else
        echo "Already logged into $registry"
    fi
}

# Function to update pull secret with podman credentials
# Usage: update-pull-secret-with-podman "registry.ci.openshift.org"
# Description: Updates ~/pull-secret.txt with credentials from podman auth file
#              for the specified registry. Skips quay.io as it's already included.
# Parameters:
#   $1 - registry: Registry hostname to add credentials for
# Prerequisites:
#   - Must be logged into the registry via podman
#   - ~/pull-secret.txt must exist
# Example:
#   handle-registry-login "$registry"
#   update-pull-secret-with-podman "$registry"
update-pull-secret-with-podman() {
    local registry=$1
    
    if [[ "$registry" == "quay.io" ]]; then
        echo "INFO: Skipping pull secret update for quay.io (already included)"
        return 0
    fi
    
    if ! podman login --get-login "$registry" &>/dev/null; then
        echo "WARN: Not logged into $registry, skipping pull secret update"
        return 0
    fi
    
    echo "INFO: Updating pull-secret.txt with credentials for $registry"
    
    # Get podman auth file location
    local podman_auth_file="${XDG_RUNTIME_DIR}/containers/auth.json"
    if [[ ! -f "$podman_auth_file" ]]; then
        podman_auth_file="$HOME/.config/containers/auth.json"
    fi
    
    if [[ ! -f "$podman_auth_file" ]]; then
        echo "WARN: Podman auth file not found"
        return 1
    fi
    
    # Extract auth for the specific registry
    # Note: declare local first, then assign so jq's exit status is preserved.
    local registry_auth
    registry_auth=$(jq -r --arg reg "$registry" '.auths[$reg] // empty' "$podman_auth_file") || {
        echo "WARN: Failed to parse podman auth file for $registry" >&2
        return 1
    }
    
    if [[ -z "$registry_auth" ]]; then
        echo "WARN: No auth found for $registry in podman auth file"
        return 1
    fi
    
    # Read current pull secret
    local pull_secret
    pull_secret=$(cat ~/pull-secret.txt) || {
        echo "WARN: Failed to read ~/pull-secret.txt" >&2
        return 1
    }
    
    # Update pull secret with the registry auth
    local updated_pull_secret
    updated_pull_secret=$(echo "$pull_secret" | jq --arg reg "$registry" --argjson auth "$registry_auth" '.auths[$reg] = $auth') || {
        echo "WARN: Failed to update pull secret JSON for $registry" >&2
        return 1
    }
    
    # Write back to pull-secret.txt
    echo "$updated_pull_secret" > ~/pull-secret.txt
    echo "INFO: Updated ~/pull-secret.txt with credentials for $registry"
    
    return 0
}

# Function to create standard install-config.yaml header
# Usage: create-install-config-header > install-config.yaml
# Description: Outputs the standard OpenShift install-config.yaml header
# Returns: YAML header to stdout
create-install-config-header() {
    echo "additionalTrustBundlePolicy: Proxyonly
apiVersion: v1"
}

# Function to add pull secret and SSH key to install-config
# Usage: add-credentials-to-install-config >> install-config.yaml
# Description: Outputs pull secret and SSH key sections for install-config.yaml
# Prerequisites:
#   - ~/pull-secret.txt must exist
#   - ~/.ssh/id_rsa.pub must exist
# Returns: YAML credentials section to stdout
add-credentials-to-install-config() {
    echo "pullSecret: '$(cat ~/pull-secret.txt)'
sshKey: |
  $(cat ~/.ssh/id_rsa.pub)"
}

# Function to generate unique cluster name and directory
# Usage: result=$(generate-unique-cluster-name "tkaovila-20250114-sts" "/path/to/dir")
#        cluster_name=$(echo "$result" | grep "cluster_name:" | cut -d: -f2)
#        cluster_dir=$(echo "$result" | grep "cluster_dir:" | cut -d: -f2)
# Description: Generates unique cluster name by appending suffix if conflicts exist
#              Only adds suffix when PROCEED_WITH_EXISTING_CLUSTERS=true
# Parameters:
#   $1 - base_name: Base cluster name
#   $2 - base_dir: Base directory path
# Returns: Two lines to stdout: "cluster_name:NAME" and "cluster_dir:DIR"
# Environment:
#   PROCEED_WITH_EXISTING_CLUSTERS - If "true", appends -1, -2, etc. to avoid conflicts
# Example:
#   local unique=$(generate-unique-cluster-name "$CLUSTER_NAME" "$OCP_CREATE_DIR")
#   [[ -z "$unique" ]] && return 1
generate-unique-cluster-name() {
    local base_name=$1
    local base_dir=$2
    local suffix=""
    local suffix_num=1
    
    # Check if PROCEED_WITH_EXISTING_CLUSTERS is set
    if [[ -n "$PROCEED_WITH_EXISTING_CLUSTERS" && "$PROCEED_WITH_EXISTING_CLUSTERS" == "true" ]]; then
        # Look for existing clusters with the same base name
        while find "$OCP_MANIFESTS_DIR" -type d -name "*${base_name}*" 2>/dev/null | grep -q .; do
            suffix="-${suffix_num}"
            local test_name="${base_name}${suffix}"
            echo "Found existing cluster with similar name, trying: $test_name"
            
            # Check if the new name exists
            if ! find "$OCP_MANIFESTS_DIR" -type d -name "*${test_name}*" 2>/dev/null | grep -q .; then
                # Found a unique name
                echo "cluster_name:${test_name}"
                echo "cluster_dir:${base_dir}${suffix}"
                return 0
            fi
            
            ((suffix_num++))
            # Safety check to avoid infinite loop
            if [[ $suffix_num -gt 10 ]]; then
                echo "ERROR: Cannot find a unique cluster name after 10 attempts" >&2
                return 1
            fi
        done
    fi
    
    # Return the base name if no conflicts or not proceeding with existing
    echo "cluster_name:${base_name}"
    echo "cluster_dir:${base_dir}"
    return 0
}

# Function to cleanup cluster resources on failure
# Usage: cleanup-on-failure "$OCP_CREATE_DIR" "$CLUSTER_NAME" "azure"
# Description: Attempts to gather bootstrap logs and provides cleanup guidance
#              when cluster creation fails
# Parameters:
#   $1 - cluster_dir: Path to cluster installation directory
#   $2 - cluster_name: Name of the cluster
#   $3 - provider: Cloud provider ("aws", "gcp", "azure")
# Returns: Always returns 1 (failure status)
# Example:
#   if ! $OPENSHIFT_INSTALL create cluster --dir $dir; then
#       cleanup-on-failure "$dir" "$name" "aws"
#       return 1
#   fi
cleanup-on-failure() {
    local cluster_dir=$1
    local cluster_name=$2
    local provider=$3

    echo "ERROR: Cluster creation failed, cleaning up resources..."

    # Archive logs before any cleanup destroys them
    bash ~/.claude/skills/create-ocp-gcp-wif/scripts/archive-logs.sh "$cluster_dir" 2>/dev/null || true

    # Try to gather bootstrap logs first
    if [[ -d "$cluster_dir" ]]; then
        local openshift_install; openshift_install=$(get-openshift-install)
        if [[ -n "$openshift_install" ]]; then
            echo "Attempting to gather bootstrap logs..."
            $openshift_install gather bootstrap --dir "$cluster_dir" || true

            # Run destroy if metadata.json exists (installer can identify resources)
            if [[ -f "$cluster_dir/metadata.json" ]]; then
                # Back up metadata.json so pre-create destroy works even if dir is removed
                local backup_path="${OCP_MANIFESTS_DIR}/.metadata-backup-$(basename "$cluster_dir").json"
                cp "$cluster_dir/metadata.json" "$backup_path" 2>/dev/null && \
                    echo "INFO: Backed up metadata.json to $backup_path"
                echo "Running openshift-install destroy cluster..."
                $openshift_install destroy cluster --dir "$cluster_dir" || \
                    echo "WARNING: destroy cluster failed, may need manual cleanup"
            fi
        fi
    fi

    # Provider-specific cleanup
    case "$provider" in
        "aws"|"gcp"|"azure")
            echo "Note: You may need to manually clean up cloud resources"
            echo "Check your $provider console for any orphaned resources"
            ;;
    esac

    return 1
}

# Clean up orphaned GCP compute resources by cluster name pattern
# Deletes in dependency order: forwarding rules → target proxies → backend services → instance groups
# Skips silently if no orphaned resources found
cleanup-orphaned-gcp-resources() {
    local cluster_name=$1
    local project=$2

    [[ -z "$cluster_name" || -z "$project" ]] && return 0

    local filter="name~${cluster_name}"
    local found=false

    # Check if any orphaned compute resources exist
    local backend_services=$(gcloud compute backend-services list --project="$project" \
        --filter="$filter" --format='value(name)' 2>/dev/null)
    local instance_groups=$(gcloud compute instance-groups list --project="$project" \
        --filter="$filter" --format='value(name,zone.basename())' 2>/dev/null)

    [[ -z "$backend_services" && -z "$instance_groups" ]] && return 0

    echo "INFO: Found orphaned GCP resources for $cluster_name, cleaning up..."

    # Delete in GCP dependency order
    # 1. Forwarding rules (reference target proxies)
    gcloud compute forwarding-rules list --project="$project" --filter="$filter" \
        --format='value(name,region.basename())' 2>/dev/null | while IFS=$'\t' read -r name region; do
        [[ -n "$name" ]] || continue
        echo "  Deleting forwarding rule: $name"
        if [[ -n "$region" ]]; then
            gcloud compute forwarding-rules delete "$name" --region="$region" --project="$project" --quiet 2>/dev/null || true
        else
            gcloud compute forwarding-rules delete "$name" --global --project="$project" --quiet 2>/dev/null || true
        fi
    done

    # 2. Target TCP proxies (reference backend services)
    gcloud compute target-tcp-proxies list --project="$project" --filter="$filter" \
        --format='value(name)' 2>/dev/null | while read -r name; do
        [[ -n "$name" ]] || continue
        echo "  Deleting target TCP proxy: $name"
        gcloud compute target-tcp-proxies delete "$name" --project="$project" --quiet 2>/dev/null || true
    done

    # 3. Backend services (reference instance groups)
    echo "$backend_services" | while read -r name; do
        [[ -n "$name" ]] || continue
        echo "  Deleting backend service: $name"
        gcloud compute backend-services delete "$name" --global --project="$project" --quiet 2>/dev/null || true
    done

    # 4. Instance groups (now unblocked)
    echo "$instance_groups" | while IFS=$'\t' read -r name zone; do
        [[ -n "$name" ]] || continue
        echo "  Deleting instance group: $name (zone: $zone)"
        gcloud compute instance-groups unmanaged delete "$name" --zone="$zone" --project="$project" --quiet 2>/dev/null || true
    done

    # 5. Health checks
    gcloud compute health-checks list --project="$project" --filter="$filter" \
        --format='value(name)' 2>/dev/null | while read -r name; do
        [[ -n "$name" ]] || continue
        echo "  Deleting health check: $name"
        gcloud compute health-checks delete "$name" --project="$project" --quiet 2>/dev/null || true
    done

    echo "INFO: Orphaned GCP resource cleanup complete"
}