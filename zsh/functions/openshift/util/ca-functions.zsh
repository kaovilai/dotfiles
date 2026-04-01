# OpenShift Certificate Authority (CA) Management Functions
#
# Functions for extracting and trusting OpenShift cluster CA certificates
#
# Functions provided:
#   - get-oc-router-ca: Extract router CA certificate
#   - rm-router-ca: Remove router-ca.crt file
#   - trust-oc-router-ca-from-file: Trust router CA from current directory
#   - trust-oc-router-ca: Extract, trust, and cleanup router CA (all-in-one)
#   - get-api-ca: Extract API server CA certificate
#   - rm-api-ca: Remove api-ca.crt file
#   - trust-api-ca-from-file: Trust API CA from current directory
#   - trust-api-ca: Extract, trust, and cleanup API CA (all-in-one)

# Extract router CA certificate from OpenShift cluster
# Usage: get-oc-router-ca
# Description: Extracts the Ingress Router CA certificate and saves to router-ca.crt
#              Useful for trusting self-signed certificates from OpenShift routes
# Prerequisites:
#   - Must be logged into an OpenShift cluster (oc login)
# Output: Creates router-ca.crt in current directory
# Example:
#   get-oc-router-ca
#   # Use with: curl --cacert router-ca.crt https://my-route.apps.cluster.com
get-oc-router-ca(){
    echo "Getting Ingress Router CA for server"
    oc whoami --show-server
    oc get secret router-ca -n openshift-ingress-operator -ojsonpath="{.data['tls\.crt']}" | base64 --decode > router-ca.crt
}

# Remove router CA certificate file
# Usage: rm-router-ca
# Description: Deletes router-ca.crt from current directory
rm-router-ca(){
    echo "Removing Ingress Router CA"
    rm router-ca.crt
}

# Trust router CA certificate from current directory
# Usage: trust-oc-router-ca-from-file
# Description: Adds router-ca.crt to system trust store (macOS or Linux)
#              Requires sudo privileges
# Prerequisites:
#   - router-ca.crt must exist in current directory
# Example:
#   get-oc-router-ca
#   trust-oc-router-ca-from-file
trust-oc-router-ca-from-file(){
    if uname -s | grep -q Darwin; then
        echo "Mac OS detected, trusting oc router ca"
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain router-ca.crt
    else
        echo "Linux detected, trusting oc router ca"
        sudo add-trusted-cert -d -r trustRoot -k /etc/ssl/certs/ca-certificates.crt router-ca.crt
    fi
}

# Extract, trust, and cleanup router CA (all-in-one)
# Usage: trust-oc-router-ca
# Description: Convenience function that extracts router CA, adds to system trust,
#              and removes the temporary file
# Prerequisites:
#   - Must be logged into an OpenShift cluster
#   - Requires sudo privileges
# Example:
#   trust-oc-router-ca
trust-oc-router-ca(){
    get-oc-router-ca
    trust-oc-router-ca-from-file
    rm-router-ca
}

get-api-ca(){
    echo "Getting API CA for server"
    oc whoami --show-server
    # oc get secret router-certs-default -n openshift-ingress -ojsonpath="{.data['tls\.crt']}" | base64 --decode > api-ca.crt
    oc get secret kube-apiserver-to-kubelet-signer -n openshift-kube-apiserver-operator -ojsonpath="{.data['tls\.crt']}" | base64 --decode > api-ca.crt
}

rm-api-ca(){
    echo "Removing API CA"
    rm api-ca.crt
}

trust-api-ca-from-file(){
    if uname -s | grep -q Darwin; then
        echo "Mac OS detected"
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain api-ca.crt
    else
        echo "Linux detected"
        sudo add-trusted-cert -d -r trustRoot -k /etc/ssl/certs/ca-certificates.crt api-ca.crt
    fi
}

trust-api-ca(){
    get-api-ca
    trust-api-ca-from-file
    rm-api-ca
}

# Backwards compatibility aliases for renamed functions
alias getOCrouterCA='get-oc-router-ca'
alias rmRouterCA='rm-router-ca'
alias trustOCRouterCAFromFileInCurrentDir='trust-oc-router-ca-from-file'
alias trustOCRouterCA='trust-oc-router-ca'
alias getAPICA='get-api-ca'
alias rmAPICA='rm-api-ca'
alias trustAPICAFromFileInCurrentDir='trust-api-ca-from-file'
alias trustAPICA='trust-api-ca'
