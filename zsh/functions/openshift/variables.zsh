# Function to get the latest AMD64 release image from OpenShift CI API
znap get_latest_amd64_release_image() {
    local pullSpec
    pullSpec=$(curl -sm 10 https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-dev-preview/latest | jq -r '.pullSpec' 2>/dev/null)
    if [[ -z "$pullSpec" ]]; then
        echo "ERROR: Failed to fetch latest AMD64 release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Function to get the latest ARM64 release image from OpenShift CI API
znap get_latest_arm64_release_image() {
    local pullSpec
    pullSpec=$(curl -sm 10 https://arm64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-dev-preview-arm64/latest | jq -r '.pullSpec' 2>/dev/null)
    if [[ -z "$pullSpec" ]]; then
        echo "ERROR: Failed to fetch latest ARM64 release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Get the latest EC version from AMD64 release for compatibility
znap get_latest_ec_version() {
    local version
    version=$(curl -sm 10 https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-dev-preview/latest | jq -r '.name' 2>/dev/null)
    if [[ -z "$version" ]]; then
        echo "ERROR: Failed to fetch latest EC version from OpenShift CI API" >&2
        return 1
    else
        echo "$version"
    fi
}

# Function to get the latest multi-arch release image from OpenShift CI API
znap get_latest_multi_release_image() {
    local pullSpec
    pullSpec=$(curl -sm 10 https://multi.ocp.releases.ci.openshift.org/api/v1/releasestream/4-dev-preview-multi/latest | jq -r '.pullSpec' 2>/dev/null)
    if [[ -z "$pullSpec" ]]; then
        echo "ERROR: Failed to fetch latest multi-arch release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Functions to get latest EC version and release images dynamically at runtime
get-ocp-latest-ec-version() {
    get_latest_ec_version
}

function get-ocp-release-image-amd64() {
    get_latest_amd64_release_image
}

function get-ocp-release-image-arm64() {
    get_latest_arm64_release_image
}

get-ocp-release-image-multi() {
    get_latest_multi_release_image
}

# 4-stable release stream functions
# Function to get the latest stable AMD64 release image from OpenShift CI API
znap get_latest_stable_amd64_release_image() {
    local pullSpec
    pullSpec=$(curl -sm 10 https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable/latest | jq -r '.pullSpec' 2>/dev/null)
    if [[ -z "$pullSpec" ]]; then
        echo "ERROR: Failed to fetch latest stable AMD64 release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Function to get the latest stable ARM64 release image from OpenShift CI API
znap get_latest_stable_arm64_release_image() {
    local pullSpec
    pullSpec=$(curl -sm 10 https://arm64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable-arm64/latest | jq -r '.pullSpec' 2>/dev/null)
    if [[ -z "$pullSpec" ]]; then
        echo "ERROR: Failed to fetch latest stable ARM64 release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Function to get the latest stable multi-arch release image from OpenShift CI API
znap get_latest_stable_multi_release_image() {
    local pullSpec
    pullSpec=$(curl -sm 10 https://multi.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable-multi/latest | jq -r '.pullSpec' 2>/dev/null)
    if [[ -z "$pullSpec" ]]; then
        echo "ERROR: Failed to fetch latest stable multi-arch release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

# Get the latest stable version from AMD64 release
znap get_latest_stable_version() {
    local version
    version=$(curl -sm 10 https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable/latest | jq -r '.name' 2>/dev/null)
    if [[ -z "$version" ]]; then
        echo "ERROR: Failed to fetch latest stable version from OpenShift CI API" >&2
        return 1
    else
        echo "$version"
    fi
}

# Functions to get latest stable version and release images dynamically at runtime
get-ocp-latest-stable-version() {
    get_latest_stable_version
}

function get-ocp-release-image-stable-amd64() {
    get_latest_stable_amd64_release_image
}

function get-ocp-release-image-stable-arm64() {
    get_latest_stable_arm64_release_image
}

get-ocp-release-image-stable-multi() {
    get_latest_stable_multi_release_image
}

# Nightly release stream functions -- raw per-minor-version CI payloads
# (e.g. 4.22.0-0.nightly), NOT the "4-dev-preview" meta-stream of promoted
# EC/RC builds used above. This matches what CI systems mean by
# "stream: nightly" (e.g. OADP's virt e2e Prow job, which forces Community
# HCO because productized CNV has no catalog build yet for an unreleased
# nightly OCP payload -- see kubevirt-datamover-controller project memory
# "oadp-virt-e2e-nightlies"). Unsigned and can be broken; use for reproducing
# CI-specific behavior, not for anything you need to stay up.
znap get_latest_nightly_release_image() {
    local minor=$1
    local stream_suffix=$2   # "" for amd64, "-arm64" for arm64, "-multi" for multi
    local arch_subdomain=$3
    if [[ -z "$minor" ]]; then
        echo "ERROR: get_latest_nightly_release_image requires a minor version (e.g. 4.22)" >&2
        return 1
    fi
    local pullSpec
    pullSpec=$(curl -sm 10 "https://${arch_subdomain}.ocp.releases.ci.openshift.org/api/v1/releasestream/${minor}.0-0.nightly${stream_suffix}/latest" | jq -r '.pullSpec' 2>/dev/null)
    if [[ -z "$pullSpec" || "$pullSpec" == "null" ]]; then
        echo "ERROR: Failed to fetch latest ${minor}.0-0.nightly${stream_suffix} release image from OpenShift CI API" >&2
        return 1
    else
        echo "$pullSpec"
    fi
}

function get-ocp-release-image-nightly-amd64() {
    get_latest_nightly_release_image "$1" "" "amd64"
}

function get-ocp-release-image-nightly-arm64() {
    get_latest_nightly_release_image "$1" "-arm64" "arm64"
}

get-ocp-release-image-nightly-multi() {
    get_latest_nightly_release_image "$1" "-multi" "multi"
}

# Directory containing the manifests for many clusters
export OCP_MANIFESTS_DIR=~/OCP/manifests

# Current date in YYMMDD format (6 digits to keep cluster names under 21 chars)
export TODAY=${TODAY:-$(date +%y%m%d)}

# Set client OS and architecture (used for downloading clients)
if command -v sw_vers &>/dev/null; then
    export ocpclientos='mac'
    export ocpclientarch=$(arch)
else
    if command -v lsb_release &>/dev/null; then
        export ocpclientos='linux'
        if command -v dpkg &>/dev/null; then
            export ocpclientarch=$(dpkg --print-architecture)
        else
            _ocp_uname_m=$(uname -m)
            case "$_ocp_uname_m" in
                x86_64)         export ocpclientarch='amd64' ;;
                aarch64|arm64)  export ocpclientarch='arm64' ;;
                *)              export ocpclientarch="$_ocp_uname_m" ;;
            esac
            unset _ocp_uname_m
        fi
    else
        echo "zsh/functions/openshift/variables.zsh: Unknown OS"
    fi
fi

# For filtering out unwanted versions
export OPENSHIFT_REJECT_VERSIONS_EXPRESSION="nightly|rc|fc|ci|ec"
