# Lazy-loading wrapper for OpenShift functions
# This avoids loading all OpenShift code unless actually needed

# Track if we've loaded the functions
typeset -g OPENSHIFT_FUNCTIONS_LOADED=0

# Create placeholder functions that will load the real ones on first use
_lazy_load_openshift() {
    if [[ $OPENSHIFT_FUNCTIONS_LOADED -eq 0 ]]; then
        source ~/git/dotfiles/zsh/functions/openshift/load.zsh
        OPENSHIFT_FUNCTIONS_LOADED=1
    fi
}

# Create lazy-loading wrappers for common OpenShift functions
for func in create-ocp-aws delete-ocp-aws use-ocp-aws \
            create-ocp-azure-sts delete-ocp-azure-sts use-ocp-azure-sts \
            create-ocp-gcp-wif delete-ocp-gcp-wif use-ocp-gcp-wif \
            check-existing-clusters install-cluster list-and-use; do
    eval "${func}() { _lazy_load_openshift; ${func} \"\$@\"; }"
done

# Always set aliases as they're lightweight
alias kubectl=oc
alias oc-registry-login='oc registry login'
alias oc-registry-route='oc get route -n openshift-image-registry default-route -o jsonpath={.spec.host}'
alias ocwebconsole='edge $(oc whoami --show-console)'
alias oc-run='oc run --rm -it --image'