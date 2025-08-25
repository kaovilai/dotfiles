# Load all S3-compatible storage functions
# This file is sourced by .zshrc

# Load common MinIO functions
source ~/git/dotfiles/zsh/functions/s3/s3-minio-common.zsh

# Load provider-specific functions
source ~/git/dotfiles/zsh/functions/s3/s3-minio-aws.zsh

# Set common aliases for MinIO client
alias mc-config='mc config host add'
alias mc-ls='mc ls'
alias mc-cp='mc cp'
alias mc-rb='mc rb'
alias mc-mb='mc mb'