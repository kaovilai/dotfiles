znap function installClusterOpenshiftInstall(){
    # Unset SSH_AUTH_SOCK on Darwin systems to avoid SSH errors
    if [[ "$(uname)" == "Darwin" ]]; then
        unset SSH_AUTH_SOCK
    fi
    
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
    
    # Check for existing clusters before proceeding
    check-for-existing-clusters "all" "$DATE" || return 1
    
    mkdir -p ~/clusters/$DATE && \
    echo "Installing into dir ~/clusters/$DATE" && \
    cp ~/install-config.yaml ~/clusters/$DATE/ && \
    yq -i ".metadata.name=\"tkaovila-$DATE\"" ~/clusters/$DATE/install-config.yaml && \
    $OC_INSTALLER version && \
    $OC_INSTALLER create cluster --dir ~/clusters/$DATE
}
