# Define release payload for OpenShift installations
export OCP_FUNCTIONS_RELEASE_IMAGE=registry.ci.openshift.org/origin/release:4.19

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
        echo "openshift-functions.zsh: Unknown OS"
    fi
fi

# For filtering out unwanted versions
export OPENSHIFT_REJECT_VERSIONS_EXPRESSION="nightly|rc|fc|ci|ec"
