# OpenShift and related tools installation functions
#
# Functions provided:
#   - install-oc: Download and install OpenShift CLI (oc and kubectl)
#   - install-ocp-installer: Download and install openshift-install
#   - install-ccoctl: Install Cloud Credential Operator CLI from source
#   - install-opm: Install Operator Package Manager from source
#   - openshift-patch-versions-arm64: List available ARM64 patch versions
#   - openshift-patch-versions-amd64: List available AMD64 patch versions
#
# Aliases:
#   - latest-openshift-patch-version-arm64: Get latest ARM64 patch version
#   - latest-openshift-patch-version-amd64: Get latest AMD64 patch version
#   - latest-openshift-minor-version-arm64: Get latest ARM64 minor version

# Download and install OpenShift CLI (oc and kubectl)
# Usage: install-oc
# Description: Downloads latest oc and kubectl binaries and installs to /usr/local/bin
#              Requires sudo for installation
# Prerequisites:
#   - $ocpclientos must be set (e.g., "mac", "linux")
#   - $ocpclientarch must be set (e.g., "amd64", "arm64")
# Example:
#   export ocpclientos="mac"
#   export ocpclientarch="arm64"
#   install-oc
znap function install-oc(){
    curl --silent https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-$ocpclientos-$ocpclientarch.tar.gz -o ~/Downloads/openshift-client-$ocpclientos-$ocpclientarch.tar.gz && \
    tar -xvf ~/Downloads/openshift-client-$ocpclientos-$ocpclientarch.tar.gz -C ~/Downloads && \
    sudo mv ~/Downloads/oc /usr/local/bin && \
    sudo mv ~/Downloads/kubectl /usr/local/bin && \
    rm ~/Downloads/openshift-client-$ocpclientos-$ocpclientarch.tar.gz
    rm ~/Downloads/README.md
}

# Download and install openshift-install binary
# Usage: install-ocp-installer
# Description: Downloads latest openshift-install binary and installs to /usr/local/bin
#              Requires sudo for installation
# Prerequisites:
#   - $ocpclientos must be set (e.g., "mac", "linux")
#   - $ocpclientarch must be set (e.g., "amd64", "arm64")
# Example:
#   export ocpclientos="linux"
#   export ocpclientarch="amd64"
#   install-ocp-installer
znap function install-ocp-installer(){
    curl --silent https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-install-$ocpclientos-$ocpclientarch.tar.gz -o ~/Downloads/openshift-install-$ocpclientos-$ocpclientarch.tar.gz && \
    tar -xvf ~/Downloads/openshift-install-$ocpclientos-$ocpclientarch.tar.gz -C ~/Downloads && \
    sudo mv ~/Downloads/openshift-install /usr/local/bin
    rm ~/Downloads/openshift-install-$ocpclientos-$ocpclientarch.tar.gz
    rm ~/Downloads/README.md
}

# Install Cloud Credential Operator CLI from source
# Usage: install-ccoctl
# Description: Compiles and installs ccoctl from GitHub source for latest OpenShift version
#              Used for creating cloud credentials in manual mode (AWS, Azure, GCP)
# Prerequisites:
#   - Go must be installed
#   - latest-openshift-minor-version-arm64 function must be available
# Example:
#   install-ccoctl
znap function install-ccoctl(){
    go install github.com/openshift/cloud-credential-operator/cmd/ccoctl@release-$(latest-openshift-minor-version-arm64)
}

# Install Operator Package Manager from source
# Usage: install-opm
# Description: Compiles and installs latest opm from GitHub source
#              Used for building and managing operator catalogs
# Prerequisites:
#   - Go must be installed
# Example:
#   install-opm
znap function install-opm(){
    go install github.com/operator-framework/operator-registry/cmd/opm@latest
}

# List available ARM64 OpenShift patch versions
# Usage: openshift-patch-versions-arm64
# Description: Queries CI artifacts to list all available ARM64 OpenShift versions
#              Filters out rejected versions and shows only latest patch for each minor version
# Returns: List of versions (e.g., 4.16.3, 4.17.0) to stdout
# Environment:
#   OPENSHIFT_REJECT_VERSIONS_EXPRESSION - Regex to filter out unwanted versions
# Example:
#   openshift-patch-versions-arm64
#   latest=$(openshift-patch-versions-arm64 | tail -n 1)
znap function openshift-patch-versions-arm64(){
    curl --silent https://openshift-release-artifacts-arm64.apps.ci.l2s4.p1.openshiftapps.com/ | grep -vE $OPENSHIFT_REJECT_VERSIONS_EXPRESSION | cut -d '"' -f 2 | sed "s/\///g" | grep -vE "<|>|en|utf|^$" | grep -ve "\.\." | sort -V | awk -F. '{if(!a[$1"."$2]++)print $1"."$2"."$NF}'
}

# List available AMD64 OpenShift patch versions
# Usage: openshift-patch-versions-amd64
# Description: Queries CI artifacts to list all available AMD64 OpenShift versions
#              Filters out rejected versions and shows only latest patch for each minor version
# Returns: List of versions (e.g., 4.16.3, 4.17.0) to stdout
# Environment:
#   OPENSHIFT_REJECT_VERSIONS_EXPRESSION - Regex to filter out unwanted versions
# Example:
#   openshift-patch-versions-amd64
#   latest=$(openshift-patch-versions-amd64 | tail -n 1)
znap function openshift-patch-versions-amd64(){
    curl --silent https://openshift-release-artifacts.apps.ci.l2s4.p1.openshiftapps.com/ | grep -vE $OPENSHIFT_REJECT_VERSIONS_EXPRESSION | cut -d '"' -f 2 | sed "s/\///g" | grep -vE "<|>|en|utf|^$" | grep -ve "\.\." | sort -V | awk -F. '{if(!a[$1"."$2]++)print $1"."$2"."$NF}'
}

alias latest-openshift-patch-version-arm64="openshift-patch-versions-arm64 | tail -n 1"
alias latest-openshift-patch-version-amd64="openshift-patch-versions-amd64 | tail -n 1"
alias latest-openshift-minor-version-arm64="openshift-patch-versions-arm64 | tail -n 1 | cut -d '.' -f 1,2"
