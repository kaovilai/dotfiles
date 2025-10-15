# OpenShift Certificate Authority (CA) Management Functions
#
# Functions for extracting and trusting OpenShift cluster CA certificates
#
# Functions provided:
#   - getOCrouterCA: Extract router CA certificate
#   - rmRouterCA: Remove router-ca.crt file
#   - trustOCRouterCAFromFileInCurrentDir: Trust router CA from current directory
#   - trustOCRouterCA: Extract, trust, and cleanup router CA (all-in-one)
#   - getAPICA: Extract API server CA certificate
#   - rmAPICA: Remove api-ca.crt file
#   - trustAPICAFromFileInCurrentDir: Trust API CA from current directory
#   - trustAPICA: Extract, trust, and cleanup API CA (all-in-one)

# Extract router CA certificate from OpenShift cluster
# Usage: getOCrouterCA
# Description: Extracts the Ingress Router CA certificate and saves to router-ca.crt
#              Useful for trusting self-signed certificates from OpenShift routes
# Prerequisites:
#   - Must be logged into an OpenShift cluster (oc login)
# Output: Creates router-ca.crt in current directory
# Example:
#   getOCrouterCA
#   # Use with: curl --cacert router-ca.crt https://my-route.apps.cluster.com
znap function getOCrouterCA(){
    echo "Getting Ingress Router CA for server"
    oc whoami --show-server
    oc get secret router-ca -n openshift-ingress-operator -ojsonpath="{.data['tls\.crt']}" | base64 --decode > router-ca.crt
}

# Remove router CA certificate file
# Usage: rmRouterCA
# Description: Deletes router-ca.crt from current directory
znap function rmRouterCA(){
    echo "Removing Ingress Router CA"
    rm router-ca.crt
}

# Trust router CA certificate from current directory
# Usage: trustOCRouterCAFromFileInCurrentDir
# Description: Adds router-ca.crt to system trust store (macOS or Linux)
#              Requires sudo privileges
# Prerequisites:
#   - router-ca.crt must exist in current directory
# Example:
#   getOCrouterCA
#   trustOCRouterCAFromFileInCurrentDir
znap function trustOCRouterCAFromFileInCurrentDir(){
    if uname -s | grep -q Darwin; then
        echo "Mac OS detected, trusting oc router ca"
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain router-ca.crt
    else
        echo "Linux detected, trusting oc router ca"
        sudo add-trusted-cert -d -r trustRoot -k /etc/ssl/certs/ca-certificates.crt router-ca.crt
    fi
}

# Extract, trust, and cleanup router CA (all-in-one)
# Usage: trustOCRouterCA
# Description: Convenience function that extracts router CA, adds to system trust,
#              and removes the temporary file
# Prerequisites:
#   - Must be logged into an OpenShift cluster
#   - Requires sudo privileges
# Example:
#   trustOCRouterCA
znap function trustOCRouterCA(){
    getOCrouterCA
    trustOCRouterCAFromFileInCurrentDir
    rmRouterCA
}

znap function getAPICA(){
    echo "Getting API CA for server"
    oc whoami --show-server
    # oc get secret router-certs-default -n openshift-ingress -ojsonpath="{.data['tls\.crt']}" | base64 --decode > api-ca.crt
    oc get secret kube-apiserver-to-kubelet-signer -n openshift-kube-apiserver-operator -ojsonpath="{.data['tls\.crt']}" | base64 --decode > api-ca.crt
}

znap function rmAPICA(){
    echo "Removing API CA"
    rm api-ca.crt
}

znap function trustAPICAFromFileInCurrentDir(){
    if uname -s | grep -q Darwin; then
        echo "Mac OS detected"
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain api-ca.crt
    else
        echo "Linux detected"
        sudo add-trusted-cert -d -r trustRoot -k /etc/ssl/certs/ca-certificates.crt api-ca.crt
    fi
}

znap function trustAPICA(){
    getAPICA
    trustAPICAFromFileInCurrentDir
    rmAPICA
}
