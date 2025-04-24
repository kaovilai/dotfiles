# Define release payload for OpenShift installations
# Using architecture-specific images
# export OCP_FUNCTIONS_RELEASE_IMAGE=quay.io/openshift-release-dev/ocp-release:4.19.0-ec.4-multi
# For AMD64 architecture
export OCP_FUNCTIONS_RELEASE_IMAGE_AMD64=quay.io/openshift-release-dev/ocp-release:4.19.0-ec.5-x86_64
# For ARM64 architecture
export OCP_FUNCTIONS_RELEASE_IMAGE_ARM64=quay.io/openshift-release-dev/ocp-release:4.19.0-ec.5-aarch64
# multi
export OCP_FUNCTIONS_RELEASE_IMAGE_MULTI=quay.io/openshift-release-dev/ocp-release:4.19.0-ec.5-multi


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
