# Load all S3-compatible storage functions
# This file is sourced by .zshrc

# Load common MinIO functions
[[ -f ~/git/dotfiles/zsh/functions/s3/s3-minio-common.zsh ]] || { print -P "%F{red}[s3] Missing: s3-minio-common.zsh%f" >&2; return 1; }
source ~/git/dotfiles/zsh/functions/s3/s3-minio-common.zsh || { print -P "%F{red}[s3] Failed to source: s3-minio-common.zsh%f" >&2; return 1; }

# Load provider-specific functions
[[ -f ~/git/dotfiles/zsh/functions/s3/s3-minio-aws.zsh ]] || { print -P "%F{red}[s3] Missing: s3-minio-aws.zsh%f" >&2; return 1; }
source ~/git/dotfiles/zsh/functions/s3/s3-minio-aws.zsh || { print -P "%F{red}[s3] Failed to source: s3-minio-aws.zsh%f" >&2; return 1; }

# Set common aliases for MinIO client
alias mc-config='mc config host add'
alias mc-ls='mc ls'
alias mc-cp='mc cp'
alias mc-rb='mc rb'
alias mc-mb='mc mb'