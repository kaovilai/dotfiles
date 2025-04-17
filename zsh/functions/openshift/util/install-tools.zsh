znap function install-oc(){
    curl --silent https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-$ocpclientos-$ocpclientarch.tar.gz -o ~/Downloads/openshift-client-$ocpclientos-$ocpclientarch.tar.gz && \
    tar -xvf ~/Downloads/openshift-client-$ocpclientos-$ocpclientarch.tar.gz -C ~/Downloads && \
    sudo mv ~/Downloads/oc /usr/local/bin && \
    sudo mv ~/Downloads/kubectl /usr/local/bin && \
    rm ~/Downloads/openshift-client-$ocpclientos-$ocpclientarch.tar.gz
    rm ~/Downloads/README.md
}

znap function install-ocp-installer(){
    curl --silent https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-install-$ocpclientos-$ocpclientarch.tar.gz -o ~/Downloads/openshift-install-$ocpclientos-$ocpclientarch.tar.gz && \
    tar -xvf ~/Downloads/openshift-install-$ocpclientos-$ocpclientarch.tar.gz -C ~/Downloads && \
    sudo mv ~/Downloads/openshift-install /usr/local/bin
    rm ~/Downloads/openshift-install-$ocpclientos-$ocpclientarch.tar.gz
    rm ~/Downloads/README.md
}

znap function install-ccoctl(){
    go install github.com/openshift/cloud-credential-operator/cmd/ccoctl@release-$(latest-openshift-minor-version-arm64)
}

znap function install-opm(){
    go install github.com/operator-framework/operator-registry/cmd/opm@latest
}

znap function openshift-patch-versions-arm64(){
    curl --silent https://openshift-release-artifacts-arm64.apps.ci.l2s4.p1.openshiftapps.com/ | grep -vE $OPENSHIFT_REJECT_VERSIONS_EXPRESSION | cut -d '"' -f 2 | sed "s/\///g" | grep -vE "<|>|en|utf|^$" | grep -ve "\.\." | sort -V | awk -F. '{if(!a[$1"."$2]++)print $1"."$2"."$NF}'
}

znap function openshift-patch-versions-amd64(){
    curl --silent https://openshift-release-artifacts.apps.ci.l2s4.p1.openshiftapps.com/ | grep -vE $OPENSHIFT_REJECT_VERSIONS_EXPRESSION | cut -d '"' -f 2 | sed "s/\///g" | grep -vE "<|>|en|utf|^$" | grep -ve "\.\." | sort -V | awk -F. '{if(!a[$1"."$2]++)print $1"."$2"."$NF}'
}

alias latest-openshift-patch-version-arm64="openshift-patch-versions-arm64 | tail -n 1"
alias latest-openshift-patch-version-amd64="openshift-patch-versions-amd64 | tail -n 1"
alias latest-openshift-minor-version-arm64="openshift-patch-versions-arm64 | tail -n 1 | cut -d '.' -f 1,2"
