znap function crc-start-version(){
    # check X.Y.Z version is specified
    if [ -z "$1" ]; then
        echo "No version supplied, try 2.43.0 or check https://github.com/crc-org/crc/releases"
        return 1
    fi
    # check version is semver
    if ! [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Version $1 is not semver"
        return 1
    fi
    # if running
    if [[ $(crc status --output json | jq --raw-output .openshiftStatus) = "Running" ]]; then
    # exit if version matching already
        if [[ $(crc version --output json 2> /dev/null | jq --raw-output .version) =  $1 ]]; then
            echo already requested version and running
            return 0
        fi
    fi
    # if not stopped
    if ! [[ $(crc status --output json | jq --raw-output .openshiftStatus) = "Stopped" ]]; then
        echo stopping and cleanup.
        crc stop; crc delete -f; crc cleanup;
    fi
    # install/upgrade if version mismatched
    if ! [[ $(crc version --output json 2> /dev/null | jq --raw-output .version) =  $1 ]]; then
        (cat ~/Downloads/$1-crc.pkg >/dev/null || curl https://developers.redhat.com/content-gateway/file/pub/openshift-v4/clients/crc/$1/crc-macos-installer.pkg -L -o ~/Downloads/$1-crc.pkg) && sudo installer -pkg ~/Downloads/$1-crc.pkg -target LocalSystem
    fi
    crc version && crc setup && crc start --log-level debug && crc status --log-level debug
}

alias oc-login-crc='export KUBECONFIG=~/.crc/machines/crc/kubeconfig'
alias crc-kubeadminpass='cat ~/.crc/machines/crc/kubeadmin-password'
