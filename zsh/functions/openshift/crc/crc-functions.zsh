crc-start-version(){
    if ! command -v crc &>/dev/null; then
        echo "❌ crc not found. Install it from: https://github.com/crc-org/crc/releases" >&2
        return 1
    fi
    if ! command -v jq &>/dev/null; then
        echo "❌ jq not found. Install it with: brew install jq" >&2
        return 1
    fi
    # check X.Y.Z version is specified
    if [[ -z "$1" ]]; then
        echo "No version supplied, try 2.43.0 or check https://github.com/crc-org/crc/releases" >&2
        return 1
    fi
    # check version is semver
    if ! [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Version $1 is not semver" >&2
        return 1
    fi
    local version="$1"
    local crc_status_json crc_openshift_status crc_installed_version
    crc_status_json=$(crc status --output json)
    crc_openshift_status=$(jq --raw-output .openshiftStatus <<< "$crc_status_json")
    crc_installed_version=$(crc version --output json 2>/dev/null | jq --raw-output .version)
    # if running
    if [[ "$crc_openshift_status" = "Running" ]]; then
    # exit if version matching already
        if [[ "$crc_installed_version" = "$version" ]]; then
            echo "Already at requested version and running"
            return 0
        fi
    fi
    # if not stopped
    if ! [[ "$crc_openshift_status" = "Stopped" ]]; then
        echo "Stopping and cleaning up..."
        crc stop; crc delete -f; crc cleanup;
    fi
    # install/upgrade if version mismatched
    if ! [[ "$crc_installed_version" = "$version" ]]; then
        (cat ~/Downloads/"$version"-crc.pkg >/dev/null || curl https://developers.redhat.com/content-gateway/file/pub/openshift-v4/clients/crc/"$version"/crc-macos-installer.pkg -L -o ~/Downloads/"$version"-crc.pkg) && sudo installer -pkg ~/Downloads/"$version"-crc.pkg -target LocalSystem
    fi
    crc version && crc setup && crc start --log-level debug && crc status --log-level debug
}

alias oc-login-crc='export KUBECONFIG=~/.crc/machines/crc/kubeconfig'
alias crc-kubeadminpass='cat ~/.crc/machines/crc/kubeadmin-password'
