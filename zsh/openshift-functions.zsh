alias kubectl=oc
function agdKubeAdminPassword(){
 if [$1 = ""]; then 
  echo "No GUID supplied"
  return 1
 else
  echo "parsing guid $1"
  cat "~/.agnosticd/$1/ocp4-cluster_$1_kubeadmin-password"
 fi
}

function getOCrouterCA(){
    echo "Getting Ingress Router CA for server"
    oc whoami --show-server
    oc get secret router-ca -n openshift-ingress-operator -ojsonpath="{.data['tls\.crt']}" | base64 --decode > router-ca.crt
}

function rmRouterCA(){
    echo "Removing Ingress Router CA"
    rm router-ca.crt
}

function trustOCRouterCAFromFileInCurrentDir(){
    if uname -s | grep -q Darwin; then
        echo "Mac OS detected"
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain router-ca.crt
    else
        echo "Linux detected"
        sudo add-trusted-cert -d -r trustRoot -k /etc/ssl/certs/ca-certificates.crt router-ca.crt
    fi
}

function trustOCRouterCA(){
    getOCrouterCA
    trustOCRouterCAFromFileInCurrentDir
    rmRouterCA
}

function getAPICA(){
    echo "Getting API CA for server"
    oc whoami --show-server
    # oc get secret router-certs-default -n openshift-ingress -ojsonpath="{.data['tls\.crt']}" | base64 --decode > api-ca.crt
    oc get secret kube-apiserver-to-kubelet-signer -n openshift-kube-apiserver-operator -ojsonpath="{.data['tls\.crt']}" | base64 --decode > api-ca.crt
}

function rmAPICA(){
    echo "Removing API CA"
    rm api-ca.crt
}

function trustAPICAFromFileInCurrentDir(){
    if uname -s | grep -q Darwin; then
        echo "Mac OS detected"
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain api-ca.crt
    else
        echo "Linux detected"
        sudo add-trusted-cert -d -r trustRoot -k /etc/ssl/certs/ca-certificates.crt api-ca.crt
    fi
}

function trustAPICA(){
    getAPICA
    trustAPICAFromFileInCurrentDir
    rmAPICA
}
