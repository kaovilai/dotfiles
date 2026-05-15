# Lazy-loading wrapper for S3/MinIO functions
# Avoids loading ~1700 lines of S3 code unless actually needed

typeset -g S3_FUNCTIONS_LOADED=0

_lazy_load_s3() {
    if [[ $S3_FUNCTIONS_LOADED -eq 0 ]]; then
        # Sourcing redefines all real functions by the same names, replacing these
        # wrappers via ZSH dynamic dispatch — no recursion on success.
        source ~/git/dotfiles/zsh/functions/s3/load.zsh && S3_FUNCTIONS_LOADED=1
    fi
}

# Lightweight aliases are always available
alias mc-config='mc config host add'
alias mc-ls='mc ls'
alias mc-cp='mc cp'
alias mc-rb='mc rb'
alias mc-mb='mc mb'

# Create lazy-loading wrappers for all public S3 functions
for func in \
    check-minio-docker-status \
    configure-minio-cluster-access \
    create-minio-aws \
    create-minio-config-dir \
    create-velero-dpa-for-minio \
    delete-minio-aws \
    download-minio-certificate \
    ensure-default-bucket \
    generate-self-signed-cert \
    get-minio-connection-info \
    list-minio-deployments \
    load-minio-config \
    remove-certificate-from-system \
    remove-minio-config \
    save-minio-config \
    test-minio-connection \
    trust-certificate-in-system; do
    eval "${func}() { _lazy_load_s3; ${func} \"\$@\"; }"
done
