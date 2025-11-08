# Common utility functions for OpenShift cluster creation
#
# This file contains shared utility functions used across all OpenShift cluster
# creation scripts (AWS, Azure, GCP, ROSA).
#
# Functions provided:
#   - prompt_release_stream: Interactive release stream selection (dev-preview/stable)
#   - get_release_image: Get release image URL for specific stream and architecture
#   - validate_env_vars: Validate required environment variables are set
#   - get_openshift_install: Find or install openshift-install binary
#   - handle_registry_login: Login to container registries (podman)
#   - update_pull_secret_with_podman: Update pull-secret.txt with registry credentials
#   - create_install_config_header: Generate standard install-config.yaml header
#   - add_credentials_to_install_config: Add pull secret and SSH key to install-config
#   - generate_unique_cluster_name: Generate unique cluster name to avoid conflicts
#   - cleanup_on_failure: Clean up resources when cluster creation fails

# Function to prompt for release stream selection
# Usage: stream=$(prompt_release_stream)
# Description: Interactively prompts user to select between dev-preview (EC) or stable release
# Returns: "dev-preview" or "stable" to stdout
prompt_release_stream() {
    echo "" >&2
    echo "Select OpenShift release stream:" >&2
    echo "1) 4-dev-preview (Early Candidate) - Version: $(get_ocp_latest_ec_version)" >&2
    echo "2) 4-stable (Release Candidate)   - Version: $(get_ocp_latest_stable_version)" >&2
    echo "" >&2
    echo -n "Enter your choice (1 or 2): " >&2
    read stream_choice
    
    if [[ "$stream_choice" == "2" ]]; then
        echo "INFO: Using 4-stable release stream (version: $(get_ocp_latest_stable_version))" >&2
        echo "stable"
    else
        echo "INFO: Using 4-dev-preview release stream (version: $(get_ocp_latest_ec_version))" >&2
        echo "dev-preview"
    fi
}

# Function to get release image based on stream and architecture
# Usage: image=$(get_release_image "stable" "amd64")
#        image=$(get_release_image "dev-preview" "arm64")
#        image=$(get_release_image "stable" "multi")
# Description: Gets the appropriate release image URL for the given stream and architecture
# Parameters:
#   $1 - stream: "stable" or "dev-preview"
#   $2 - architecture: "amd64", "arm64", or "multi" (multi-arch)
# Returns: Release image URL to stdout, exits with 1 on error
get_release_image() {
    local stream=$1
    local architecture=$2
    
    if [[ "$stream" == "stable" ]]; then
        case "$architecture" in
            "amd64"|"x86_64")
                get_ocp_functions_release_image_stable_amd64
                ;;
            "arm64"|"aarch64")
                get_ocp_functions_release_image_stable_arm64
                ;;
            "multi")
                get_ocp_functions_release_image_stable_multi
                ;;
            *)
                echo "ERROR: Unknown architecture: $architecture" >&2
                return 1
                ;;
        esac
    else
        case "$architecture" in
            "amd64"|"x86_64")
                get_ocp_functions_release_image_amd64
                ;;
            "arm64"|"aarch64")
                get_ocp_functions_release_image_arm64
                ;;
            "multi")
                get_ocp_functions_release_image_multi
                ;;
            *)
                echo "ERROR: Unknown architecture: $architecture" >&2
                return 1
                ;;
        esac
    fi
}

# Function to validate environment variables
# Usage: validate_env_vars "aws" AWS_REGION AWS_PROFILE
#        validate_env_vars "azure" AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID
# Description: Validates that all required environment variables are set
# Parameters:
#   $1 - provider: Cloud provider name (for error messages only)
#   $@ - variable names to validate
# Returns: 0 if all variables are set, 1 if any are missing
# Example:
#   validate_env_vars "azure" AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID || return 1
validate_env_vars() {
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

# Function to get openshift-install binary
# Usage: OPENSHIFT_INSTALL=$(get_openshift_install)
# Description: Finds an appropriate openshift-install binary or offers to install one
#              Checks for versioned binaries (e.g., openshift-install-4.17.0) first,
#              then falls back to generic 'openshift-install' command.
#              If not found, offers to download and install the latest EC version.
# Returns: Path to openshift-install binary to stdout
# Environment:
#   OPENSHIFT_INSTALL - If set, uses this path instead of searching
# Example:
#   local installer=$(get_openshift_install)
#   [[ -z "$installer" ]] && return 1
#   $installer version
get_openshift_install() {
    local ec_version=$(get_ocp_latest_ec_version)
    local stable_version=$(get_ocp_latest_stable_version)

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

    # Function to check if binary is executable and get its architecture
    local check_binary_arch() {
        local binary=$1
        # First check if the binary is executable
        if ! $binary version &>/dev/null; then
            return 2  # Binary not executable
        fi

        local version_output=$($binary version 2>/dev/null | grep "release architecture")
        local binary_arch=$(echo "$version_output" | awk '{print $3}')

        if [[ "$binary_arch" == "$host_arch" ]]; then
            return 0  # Correct architecture
        else
            # Check if it's macOS where Rosetta can run amd64 on arm64
            if [[ "$(uname)" == "Darwin" ]] && [[ "$host_arch" == "arm64" ]] && [[ "$binary_arch" == "amd64" ]]; then
                # Binary is amd64 on arm64 macOS - Rosetta can handle this
                # Return special code to indicate it works but is cross-arch
                return 3
            fi
            return 1  # Wrong architecture and won't work
        fi
    }

    # Try EC version first
    if command -v "openshift-install-${ec_version}" &> /dev/null; then
        local binary="openshift-install-${ec_version}"
        check_binary_arch "$binary"
        local arch_status=$?

        if [[ $arch_status -eq 0 ]]; then
            # Correct architecture
            echo "$binary"
            return 0
        elif [[ $arch_status -eq 3 ]]; then
            # Cross-architecture but works via Rosetta on macOS
            # Use it without prompting - it works fine
            echo "$binary"
            return 0
        elif [[ $arch_status -eq 1 ]]; then
            # Wrong architecture and won't work
            echo "WARN: Found $binary but it's not built for $host_arch architecture" >&2
            echo "WARN: Would you like to re-download the correct $host_arch version? (y/n)" >&2
            read -r redownload_choice
            if [[ "$redownload_choice" == "y" || "$redownload_choice" == "Y" ]]; then
                # Remove the incorrect binary
                local binary_path=$(command -v "$binary")
                echo "Removing incorrect binary: $binary_path" >&2
                sudo rm "$binary_path"
                # Fall through to installation below
            else
                echo "$binary"
                return 0
            fi
        fi
        # If arch_status -eq 2 (not executable), fall through to try other binaries
    fi

    # Try stable version
    if command -v "openshift-install-${stable_version}" &> /dev/null; then
        local binary="openshift-install-${stable_version}"
        check_binary_arch "$binary"
        local arch_status=$?
        if [[ $arch_status -eq 0 ]] || [[ $arch_status -eq 3 ]]; then
            echo "$binary"
            return 0
        fi
    fi

    # Try generic openshift-install
    if command -v "openshift-install" &> /dev/null; then
        local binary="openshift-install"
        check_binary_arch "$binary"
        local arch_status=$?
        if [[ $arch_status -eq 0 ]] || [[ $arch_status -eq 3 ]]; then
            echo "$binary"
            return 0
        fi
    fi

    # No suitable binary found, offer to install
    if true; then
        echo "ERROR: No openshift-install binary found" >&2
        echo "" >&2
        echo "Would you like to install openshift-install version ${ec_version}? (y/n)" >&2
        read -r install_choice
        
        if [[ "$install_choice" == "y" || "$install_choice" == "Y" ]]; then
            echo "Installing openshift-install ${ec_version} for $host_arch architecture..." >&2

            # Detect OS
            local os=""
            case "$(uname -s)" in
                "Darwin")
                    os="mac"
                    ;;
                "Linux")
                    os="linux"
                    ;;
                *)
                    echo "ERROR: Unsupported OS: $(uname -s)" >&2
                    return 1
                    ;;
            esac
            
            # Download URL
            local url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp-dev-preview/${ec_version}/openshift-install-${os}-${host_arch}.tar.gz"
            
            # Create temporary directory
            local temp_dir=$(mktemp -d)
            
            # Download and extract
            echo "Downloading from: $url" >&2
            if curl -sL "$url" -o "${temp_dir}/openshift-install.tar.gz"; then
                tar -xzf "${temp_dir}/openshift-install.tar.gz" -C "${temp_dir}"
                
                # Install to /usr/local/bin with version suffix
                if sudo mv "${temp_dir}/openshift-install" "/usr/local/bin/openshift-install-${ec_version}"; then
                    sudo chmod +x "/usr/local/bin/openshift-install-${ec_version}"
                    echo "Successfully installed openshift-install-${ec_version}" >&2
                    
                    # Clean up
                    rm -rf "${temp_dir}"
                    
                    # Return the installed binary
                    echo "openshift-install-${ec_version}"
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
        else
            echo "Please install openshift-install or set OPENSHIFT_INSTALL variable" >&2
            return 1
        fi
    fi
}

# Function to handle registry login
# Usage: handle_registry_login "registry.ci.openshift.org"
#        handle_registry_login "quay.io"
# Description: Ensures user is logged into the specified container registry using podman
#              For registry.ci.openshift.org, opens browser for OAuth login
# Parameters:
#   $1 - registry: Registry hostname to login to
# Example:
#   handle_registry_login "registry.ci.openshift.org"
handle_registry_login() {
    local registry=$1
    
    echo "INFO: Checking if podman is logged into $registry"
    if ! podman login --get-login "$registry" &>/dev/null; then
        if [[ "$registry" == "registry.ci.openshift.org" ]]; then
            echo "Opening browser for registry.ci.openshift.org login..."
            open "https://oauth-openshift.apps.ci.l2s4.p1.openshiftapps.com/oauth/authorize?client_id=openshift-browser-client&redirect_uri=https%3A%2F%2Foauth-openshift.apps.ci.l2s4.p1.openshiftapps.com%2Foauth%2Ftoken%2Fdisplay&response_type=code"
            echo "Login URL opened in browser. Please copy the login command from the browser and paste it below:"
            read login_command
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
# Usage: update_pull_secret_with_podman "registry.ci.openshift.org"
# Description: Updates ~/pull-secret.txt with credentials from podman auth file
#              for the specified registry. Skips quay.io as it's already included.
# Parameters:
#   $1 - registry: Registry hostname to add credentials for
# Prerequisites:
#   - Must be logged into the registry via podman
#   - ~/pull-secret.txt must exist
# Example:
#   handle_registry_login "$registry"
#   update_pull_secret_with_podman "$registry"
update_pull_secret_with_podman() {
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
    local registry_auth=$(jq -r --arg reg "$registry" '.auths[$reg] // empty' "$podman_auth_file")
    
    if [[ -z "$registry_auth" ]]; then
        echo "WARN: No auth found for $registry in podman auth file"
        return 1
    fi
    
    # Read current pull secret
    local pull_secret=$(cat ~/pull-secret.txt)
    
    # Update pull secret with the registry auth
    local updated_pull_secret=$(echo "$pull_secret" | jq --arg reg "$registry" --argjson auth "$registry_auth" '.auths[$reg] = $auth')
    
    # Write back to pull-secret.txt
    echo "$updated_pull_secret" > ~/pull-secret.txt
    echo "INFO: Updated ~/pull-secret.txt with credentials for $registry"
    
    return 0
}

# Function to create standard install-config.yaml header
# Usage: create_install_config_header > install-config.yaml
# Description: Outputs the standard OpenShift install-config.yaml header
# Returns: YAML header to stdout
create_install_config_header() {
    echo "additionalTrustBundlePolicy: Proxyonly
apiVersion: v1"
}

# Function to add pull secret and SSH key to install-config
# Usage: add_credentials_to_install_config >> install-config.yaml
# Description: Outputs pull secret and SSH key sections for install-config.yaml
# Prerequisites:
#   - ~/pull-secret.txt must exist
#   - ~/.ssh/id_rsa.pub must exist
# Returns: YAML credentials section to stdout
add_credentials_to_install_config() {
    echo "pullSecret: '$(cat ~/pull-secret.txt)'
sshKey: |
  $(cat ~/.ssh/id_rsa.pub)"
}

# Function to generate unique cluster name and directory
# Usage: result=$(generate_unique_cluster_name "tkaovila-20250114-sts" "/path/to/dir")
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
#   local unique=$(generate_unique_cluster_name "$CLUSTER_NAME" "$OCP_CREATE_DIR")
#   [[ -z "$unique" ]] && return 1
generate_unique_cluster_name() {
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
# Usage: cleanup_on_failure "$OCP_CREATE_DIR" "$CLUSTER_NAME" "azure"
# Description: Attempts to gather bootstrap logs and provides cleanup guidance
#              when cluster creation fails
# Parameters:
#   $1 - cluster_dir: Path to cluster installation directory
#   $2 - cluster_name: Name of the cluster
#   $3 - provider: Cloud provider ("aws", "gcp", "azure")
# Returns: Always returns 1 (failure status)
# Example:
#   if ! $OPENSHIFT_INSTALL create cluster --dir $dir; then
#       cleanup_on_failure "$dir" "$name" "aws"
#       return 1
#   fi
cleanup_on_failure() {
    local cluster_dir=$1
    local cluster_name=$2
    local provider=$3
    
    echo "ERROR: Cluster creation failed, cleaning up resources..."
    
    # Try to gather bootstrap logs first
    if [[ -d "$cluster_dir" ]]; then
        local openshift_install=$(get_openshift_install)
        if [[ -n "$openshift_install" ]]; then
            echo "Attempting to gather bootstrap logs..."
            $openshift_install gather bootstrap --dir "$cluster_dir" || true
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