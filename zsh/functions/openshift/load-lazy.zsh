# Lazy-loading wrapper for OpenShift functions
# This avoids loading all OpenShift code unless actually needed

# Track if we've loaded the functions
typeset -g OPENSHIFT_FUNCTIONS_LOADED=0

# Load real implementations on first use
_lazy_load_openshift() {
    if [[ $OPENSHIFT_FUNCTIONS_LOADED -eq 0 ]]; then
        source ~/git/dotfiles/zsh/functions/openshift/load.zsh
        OPENSHIFT_FUNCTIONS_LOADED=1
    fi
}

# Create lazy-loading wrappers for all OpenShift functions
for func in \
    add-credentials-to-install-config \
    agd-kubeadmin-password \
    check-for-existing-clusters \
    cleanup-on-failure \
    cleanup-velero-rosa-resources \
    copy-kubeconfig \
    crc-start-version \
    create-install-config-header \
    create-ocp-aws \
    create-ocp-azure-sts \
    create-ocp-gcp-wif \
    create-rosa-sts \
    create-velero-bsl-for-azure-cluster \
    create-velero-bsl-for-gcp-cluster \
    create-velero-bsl-for-rosa-cluster \
    create-velero-bucket-for-gcp-cluster \
    create-velero-container-for-azure-cluster \
    create-velero-container-for-rosa-cluster \
    create-velero-dpa-for-azure-cluster \
    create-velero-dpa-for-gcp-cluster \
    create-velero-dpa-for-rosa-cluster \
    create-velero-identity-for-azure-cluster \
    create-velero-identity-for-gcp-cluster \
    create-velero-identity-for-rosa-cluster \
    delete-ocp-aws \
    delete-ocp-aws-dir \
    delete-ocp-azure-sts \
    delete-ocp-azure-sts-dir \
    delete-ocp-gcp-wif \
    delete-ocp-gcp-wif-dir \
    delete-rosa-sts \
    generate-unique-cluster-name \
    get-api-ca \
    get-oc-router-ca \
    get-ocp-latest-ec-version \
    get-ocp-latest-stable-version \
    get-ocp-release-image-multi \
    get-ocp-release-image-stable-multi \
    get-openshift-install \
    get-release-image \
    handle-registry-login \
    install-ccoctl \
    install-cluster-openshift-install \
    install-oc \
    install-ocp-installer \
    install-opm \
    list-ocp-clusters \
    patch-csv-replicas \
    prompt-release-stream \
    retry-ccoctl-azure \
    rm-api-ca \
    rm-router-ca \
    save-cluster-login \
    select-rosa-cluster \
    setup-velero-oadp-for-azure-cluster \
    setup-velero-oadp-for-gcp-cluster \
    setup-velero-oadp-for-rosa-cluster \
    trust-api-ca \
    trust-api-ca-from-file \
    trust-oc-router-ca \
    trust-oc-router-ca-from-file \
    update-pull-secret-with-podman \
    use-ocp-aws \
    use-ocp-aws-dir \
    use-ocp-azure-sts \
    use-ocp-azure-sts-dir \
    use-ocp-cluster \
    use-ocp-gcp-wif \
    use-ocp-gcp-wif-dir \
    use-rosa-sts \
    validate-env-vars \
    validate-velero-role-assignments-for-azure-cluster \
    validate-velero-role-assignments-for-rosa-cluster \
    watch-all-pod-errors-in-namespace \
    watch-all-pod-logs-in-namespace; do
    eval "${func}() { _lazy_load_openshift; ${func} \"\$@\"; }"
done

# Backwards compatibility aliases for renamed camelCase/snake_case functions
alias copyKUBECONFIG='copy-kubeconfig'
alias installClusterOpenshiftInstall='install-cluster-openshift-install'

# Always set aliases as they're lightweight
alias kubectl=oc
alias oc-registry-login='oc registry login'
alias oc-registry-route='oc get route -n openshift-image-registry default-route -o jsonpath={.spec.host}'
alias ocwebconsole='comet $(oc whoami --show-console)'
alias oc-run='oc run --rm -it --image'

# Export variables (in case they were not exported in the variables file)
export EDITOR="code -w"
