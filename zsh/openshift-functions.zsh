alias kubectl=oc
znap function agdKubeAdminPassword(){
 if [$1 = ""]; then 
  echo "No GUID supplied"
  return 1
 else
  echo "parsing guid $1"
  cat "~/.agnosticd/$1/ocp4-cluster_$1_kubeadmin-password"
 fi
}

znap function getOCrouterCA(){
    echo "Getting Ingress Router CA for server"
    oc whoami --show-server
    oc get secret router-ca -n openshift-ingress-operator -ojsonpath="{.data['tls\.crt']}" | base64 --decode > router-ca.crt
}

znap function rmRouterCA(){
    echo "Removing Ingress Router CA"
    rm router-ca.crt
}

znap function trustOCRouterCAFromFileInCurrentDir(){
    if uname -s | grep -q Darwin; then
        echo "Mac OS detected"
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain router-ca.crt
    else
        echo "Linux detected"
        sudo add-trusted-cert -d -r trustRoot -k /etc/ssl/certs/ca-certificates.crt router-ca.crt
    fi
}

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

znap function installClusterOpenshiftInstall(){
    [ $(command -v openshift-install-official) ] || [ $(command -v openshift-install) ] || {
        echo "openshift-install-official or openshift-install not found"
        return 1
    }

    [ $(command -v openshift-install-official) ] && OC_INSTALLER=openshift-install-official || OC_INSTALLER=openshift-install
    echo "Using $OC_INSTALLER"
    [ -f ~/install-config.yaml ] || {
        echo "install-config.yaml not found in home dir"
        echo "Please create one using the ${RED}openshift-install create install-config${NC} command"
        return 1
    }
    [ $(command -v yq) ] || {
        echo "yq not found"
        echo "Please install yq"
        return 1
    }
    # current date/time ie. apr7-1158
    # update metadata.name to tkaovila-$DATE
    DATE=$(date +%b%d-%H%M)
    # lowercase the date
    DATE=$(echo $DATE | tr '[:upper:]' '[:lower:]')
    mkdir -p ~/clusters/$DATE && \
    echo "Installing into dir ~/clusters/$DATE" && \
    cp ~/install-config.yaml ~/clusters/$DATE/ && \
    yq -i ".metadata.name=\"tkaovila-$DATE\"" ~/clusters/$DATE/install-config.yaml && \
    $OC_INSTALLER version && \
    $OC_INSTALLER create cluster --dir ~/clusters/$DATE
}