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
    add_credentials_to_install_config \
    agdKubeAdminPassword \
    check-for-existing-clusters \
    cleanup-velero-rosa-resources \
    copyKUBECONFIG \
    crc-start-version \
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
    create_install_config_header \
    delete-ocp-aws \
    delete-ocp-aws-dir \
    delete-ocp-azure-sts \
    delete-ocp-azure-sts-dir \
    delete-ocp-gcp-wif \
    delete-ocp-gcp-wif-dir \
    delete-rosa-sts \
    generate_unique_cluster_name \
    getAPICA \
    getOCrouterCA \
    get_ocp_functions_release_image_multi \
    get_ocp_functions_release_image_stable_multi \
    get_ocp_latest_ec_version \
    get_ocp_latest_stable_version \
    get_openshift_install \
    get_release_image \
    handle_registry_login \
    install-ccoctl \
    install-oc \
    install-ocp-installer \
    install-opm \
    installClusterOpenshiftInstall \
    list-ocp-clusters \
    patchCSVreplicas \
    prompt_release_stream \
    retry_ccoctl_azure \
    rmAPICA \
    rmRouterCA \
    save-cluster-login \
    select-rosa-cluster \
    setup-velero-oadp-for-azure-cluster \
    setup-velero-oadp-for-gcp-cluster \
    setup-velero-oadp-for-rosa-cluster \
    trustAPICA \
    trustAPICAFromFileInCurrentDir \
    trustOCRouterCA \
    trustOCRouterCAFromFileInCurrentDir \
    update_pull_secret_with_podman \
    use-ocp-aws \
    use-ocp-aws-dir \
    use-ocp-azure-sts \
    use-ocp-azure-sts-dir \
    use-ocp-cluster \
    use-ocp-gcp-wif \
    use-ocp-gcp-wif-dir \
    use-rosa-sts \
    validate-velero-role-assignments-for-azure-cluster \
    validate-velero-role-assignments-for-rosa-cluster \
    watchAllPodErrorsInNamespace \
    watchAllPodLogsInNamespace; do
    eval "${func}() { _lazy_load_openshift; ${func} \"\$@\"; }"
done

# Always set aliases as they're lightweight
alias kubectl=oc
alias oc-registry-login='oc registry login'
alias oc-registry-route='oc get route -n openshift-image-registry default-route -o jsonpath={.spec.host}'
alias ocwebconsole='comet $(oc whoami --show-console)'
alias oc-run='oc run --rm -it --image'

# Export variables (in case they were not exported in the variables file)
export EDITOR="code -w"
