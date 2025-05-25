# Common utility functions for OpenShift cluster creation

# Function to prompt for release stream selection
prompt_release_stream() {
    echo ""
    echo "Select OpenShift release stream:"
    echo "1) 4-dev-preview (Early Candidate) - Version: $OCP_LATEST_EC_VERSION"
    echo "2) 4-stable (Release Candidate)   - Version: $OCP_LATEST_STABLE_VERSION"
    echo ""
    echo -n "Enter your choice (1 or 2): "
    read stream_choice
    
    if [[ "$stream_choice" == "2" ]]; then
        echo "INFO: Using 4-stable release stream (version: $OCP_LATEST_STABLE_VERSION)"
        echo "stable"
    else
        echo "INFO: Using 4-dev-preview release stream (version: $OCP_LATEST_EC_VERSION)"
        echo "dev-preview"
    fi
}

# Function to get release image based on stream and architecture
get_release_image() {
    local stream=$1
    local architecture=$2
    
    if [[ "$stream" == "stable" ]]; then
        case "$architecture" in
            "amd64"|"x86_64")
                echo "$OCP_FUNCTIONS_RELEASE_IMAGE_STABLE_AMD64"
                ;;
            "arm64"|"aarch64")
                echo "$OCP_FUNCTIONS_RELEASE_IMAGE_STABLE_ARM64"
                ;;
            "multi")
                echo "$OCP_FUNCTIONS_RELEASE_IMAGE_STABLE_MULTI"
                ;;
            *)
                echo "ERROR: Unknown architecture: $architecture" >&2
                return 1
                ;;
        esac
    else
        case "$architecture" in
            "amd64"|"x86_64")
                echo "$OCP_FUNCTIONS_RELEASE_IMAGE_AMD64"
                ;;
            "arm64"|"aarch64")
                echo "$OCP_FUNCTIONS_RELEASE_IMAGE_ARM64"
                ;;
            "multi")
                echo "$OCP_FUNCTIONS_RELEASE_IMAGE_MULTI"
                ;;
            *)
                echo "ERROR: Unknown architecture: $architecture" >&2
                return 1
                ;;
        esac
    fi
}

# Function to validate environment variables
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
get_openshift_install() {
    local ec_version=${OCP_LATEST_EC_VERSION:-$(get_latest_ec_version)}
    local stable_version=${OCP_LATEST_STABLE_VERSION:-$(get_latest_stable_version)}
    
    # Check if user has set a specific version
    if [[ -n "$OPENSHIFT_INSTALL" ]]; then
        echo "$OPENSHIFT_INSTALL"
        return
    fi
    
    # Try EC version first
    if command -v "openshift-install-${ec_version}" &> /dev/null; then
        echo "openshift-install-${ec_version}"
    # Try stable version
    elif command -v "openshift-install-${stable_version}" &> /dev/null; then
        echo "openshift-install-${stable_version}"
    # Try generic openshift-install
    elif command -v "openshift-install" &> /dev/null; then
        echo "openshift-install"
    else
        echo "ERROR: No openshift-install binary found" >&2
        echo "Please install openshift-install or set OPENSHIFT_INSTALL variable" >&2
        return 1
    fi
}

# Function to handle registry login
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
create_install_config_header() {
    echo "additionalTrustBundlePolicy: Proxyonly
apiVersion: v1"
}

# Function to add pull secret and SSH key to install-config
add_credentials_to_install_config() {
    echo "pullSecret: '$(cat ~/pull-secret.txt)'
sshKey: |
  $(cat ~/.ssh/id_rsa.pub)"
}

# Function to generate unique cluster name and directory
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