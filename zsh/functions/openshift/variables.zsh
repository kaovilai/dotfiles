# Function to get the latest AMD64 release image from OpenShift CI API
znap get_latest_amd64_release_image() {
    local pullSpec=$(curl -s https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-dev-preview/latest | jq -r '.pullSpec' 2>/dev/null)
    if [ -z "$pullSpec" ]; then
        echo "ERROR: Failed to fetch latest AMD64 release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Function to get the latest ARM64 release image from OpenShift CI API
znap get_latest_arm64_release_image() {
    local pullSpec=$(curl -s https://arm64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-dev-preview-arm64/latest | jq -r '.pullSpec' 2>/dev/null)
    if [ -z "$pullSpec" ]; then
        echo "ERROR: Failed to fetch latest ARM64 release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Get the latest EC version from AMD64 release for compatibility
znap get_latest_ec_version() {
    local version=$(curl -s https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-dev-preview/latest | jq -r '.name' 2>/dev/null)
    if [ -z "$version" ]; then
        echo "ERROR: Failed to fetch latest EC version from OpenShift CI API" >&2
        return 1
    else
        echo "$version"
    fi
}

# Function to get the latest multi-arch release image from OpenShift CI API
znap get_latest_multi_release_image() {
    local pullSpec=$(curl -s https://multi.ocp.releases.ci.openshift.org/api/v1/releasestream/4-dev-preview-multi/latest | jq -r '.pullSpec' 2>/dev/null)
    if [ -z "$pullSpec" ]; then
        echo "ERROR: Failed to fetch latest multi-arch release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Functions to get latest EC version and release images dynamically at runtime
znap function get_ocp_latest_ec_version() {
    get_latest_ec_version
}

znap function get_ocp_functions_release_image_amd64() {
    get_latest_amd64_release_image
}

znap function get_ocp_functions_release_image_arm64() {
    get_latest_arm64_release_image
}

znap function get_ocp_functions_release_image_multi() {
    get_latest_multi_release_image
}

# 4-stable release stream functions
# Function to get the latest stable AMD64 release image from OpenShift CI API
znap get_latest_stable_amd64_release_image() {
    local pullSpec=$(curl -s https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable/latest | jq -r '.pullSpec' 2>/dev/null)
    if [ -z "$pullSpec" ]; then
        echo "ERROR: Failed to fetch latest stable AMD64 release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Function to get the latest stable ARM64 release image from OpenShift CI API
znap get_latest_stable_arm64_release_image() {
    local pullSpec=$(curl -s https://arm64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable-arm64/latest | jq -r '.pullSpec' 2>/dev/null)
    if [ -z "$pullSpec" ]; then
        echo "ERROR: Failed to fetch latest stable ARM64 release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Function to get the latest stable multi-arch release image from OpenShift CI API
znap get_latest_stable_multi_release_image() {
    local pullSpec=$(curl -s https://multi.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable-multi/latest | jq -r '.pullSpec' 2>/dev/null)
    if [ -z "$pullSpec" ]; then
        echo "ERROR: Failed to fetch latest stable multi-arch release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Get the latest stable version from AMD64 release
znap get_latest_stable_version() {
    local version=$(curl -s https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable/latest | jq -r '.name' 2>/dev/null)
    if [ -z "$version" ]; then
        echo "ERROR: Failed to fetch latest stable version from OpenShift CI API" >&2
        return 1
    else
        echo "$version"
    fi
}

# Functions to get latest stable version and release images dynamically at runtime
znap function get_ocp_latest_stable_version() {
    get_latest_stable_version
}

znap function get_ocp_functions_release_image_stable_amd64() {
    get_latest_stable_amd64_release_image
}

znap function get_ocp_functions_release_image_stable_arm64() {
    get_latest_stable_arm64_release_image
}

znap function get_ocp_functions_release_image_stable_multi() {
    get_latest_stable_multi_release_image
}


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
