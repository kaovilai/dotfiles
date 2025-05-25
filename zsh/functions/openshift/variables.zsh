# Function to get the latest AMD64 release image from OpenShift CI API
get_latest_amd64_release_image() {
    local pullSpec=$(curl -s https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-dev-preview/latest | jq -r '.pullSpec' 2>/dev/null)
    if [ -z "$pullSpec" ]; then
        echo "ERROR: Failed to fetch latest AMD64 release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Function to get the latest ARM64 release image from OpenShift CI API
get_latest_arm64_release_image() {
    local pullSpec=$(curl -s https://arm64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-dev-preview-arm64/latest | jq -r '.pullSpec' 2>/dev/null)
    if [ -z "$pullSpec" ]; then
        echo "ERROR: Failed to fetch latest ARM64 release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Get the latest EC version from AMD64 release for compatibility
get_latest_ec_version() {
    local version=$(curl -s https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-dev-preview/latest | jq -r '.name' 2>/dev/null)
    if [ -z "$version" ]; then
        echo "ERROR: Failed to fetch latest EC version from OpenShift CI API" >&2
        return 1
    else
        echo "$version"
    fi
}

# Function to get the latest multi-arch release image from OpenShift CI API
get_latest_multi_release_image() {
    local pullSpec=$(curl -s https://multi.ocp.releases.ci.openshift.org/api/v1/releasestream/4-dev-preview-multi/latest | jq -r '.pullSpec' 2>/dev/null)
    if [ -z "$pullSpec" ]; then
        echo "ERROR: Failed to fetch latest multi-arch release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Get the latest EC version dynamically
export OCP_LATEST_EC_VERSION=$(get_latest_ec_version)

# Define release payload for OpenShift installations
# Using architecture-specific images from the API
# For AMD64 architecture
export OCP_FUNCTIONS_RELEASE_IMAGE_AMD64=$(get_latest_amd64_release_image)
# For ARM64 architecture
export OCP_FUNCTIONS_RELEASE_IMAGE_ARM64=$(get_latest_arm64_release_image)
# For multi-arch
export OCP_FUNCTIONS_RELEASE_IMAGE_MULTI=$(get_latest_multi_release_image)

# 4-stable release stream functions
# Function to get the latest stable AMD64 release image from OpenShift CI API
get_latest_stable_amd64_release_image() {
    local pullSpec=$(curl -s https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable/latest | jq -r '.pullSpec' 2>/dev/null)
    if [ -z "$pullSpec" ]; then
        echo "ERROR: Failed to fetch latest stable AMD64 release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Function to get the latest stable ARM64 release image from OpenShift CI API
get_latest_stable_arm64_release_image() {
    local pullSpec=$(curl -s https://arm64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable-arm64/latest | jq -r '.pullSpec' 2>/dev/null)
    if [ -z "$pullSpec" ]; then
        echo "ERROR: Failed to fetch latest stable ARM64 release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Function to get the latest stable multi-arch release image from OpenShift CI API
get_latest_stable_multi_release_image() {
    local pullSpec=$(curl -s https://multi.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable-multi/latest | jq -r '.pullSpec' 2>/dev/null)
    if [ -z "$pullSpec" ]; then
        echo "ERROR: Failed to fetch latest stable multi-arch release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Get the latest stable version from AMD64 release
get_latest_stable_version() {
    local version=$(curl -s https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable/latest | jq -r '.name' 2>/dev/null)
    if [ -z "$version" ]; then
        echo "ERROR: Failed to fetch latest stable version from OpenShift CI API" >&2
        return 1
    else
        echo "$version"
    fi
}

# Get the latest stable version dynamically
export OCP_LATEST_STABLE_VERSION=$(get_latest_stable_version)

# Define stable release payload for OpenShift installations
# Using architecture-specific images from the API
# For AMD64 architecture
export OCP_FUNCTIONS_RELEASE_IMAGE_STABLE_AMD64=$(get_latest_stable_amd64_release_image)
# For ARM64 architecture
export OCP_FUNCTIONS_RELEASE_IMAGE_STABLE_ARM64=$(get_latest_stable_arm64_release_image)
# For multi-arch
export OCP_FUNCTIONS_RELEASE_IMAGE_STABLE_MULTI=$(get_latest_stable_multi_release_image)


# Directory containing the manifests for many clusters
export OCP_MANIFESTS_DIR=~/OCP/manifests

# Current date in YYYYMMDD format
export TODAY=$(date +%Y%m%d)

# Set client OS and architecture (used for downloading clients)
if [ -n "$(command -v sw_vers)" ]; then
    export ocpclientos='mac'
    export ocpclientarch=$(arch)
else
    if [ -n $(command -v lsb_release) ]; then
        export ocpclientos='linux'
        export ocpclientarch=$(dpkg --print-architecture)
    else
        echo "zsh/functions/openshift/variables.zsh: Unknown OS"
    fi
fi

# For filtering out unwanted versions
export OPENSHIFT_REJECT_VERSIONS_EXPRESSION="nightly|rc|fc|ci|ec"
