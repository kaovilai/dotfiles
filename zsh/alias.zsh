# Safe source: reports errors without killing the shell
_safe_source() {
  source "$1" 2>&1 || print -P "%F{red}[dotfiles] Failed to source: $1%f" >&2
}

# Load all alias categories
_safe_source ~/git/dotfiles/zsh/aliases/docker.zsh
_safe_source ~/git/dotfiles/zsh/aliases/go.zsh
_safe_source ~/git/dotfiles/zsh/aliases/git.zsh
_safe_source ~/git/dotfiles/zsh/aliases/github.zsh
_safe_source ~/git/dotfiles/zsh/aliases/code.zsh
_safe_source ~/git/dotfiles/zsh/aliases/ibmcloud.zsh
_safe_source ~/git/dotfiles/zsh/aliases/velero.zsh
_safe_source ~/git/dotfiles/zsh/aliases/misc.zsh

# Linux dev environments
_safe_source ~/git/dotfiles/zsh/functions/linux-dev.zsh

# Migration utilities
_safe_source ~/git/dotfiles/zsh/functions/migrate-laptop.zsh
