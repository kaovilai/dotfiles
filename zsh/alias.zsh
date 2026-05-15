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

# Linux dev environments (lazy-loaded — ~756 lines only parsed when first used)
typeset -g LINUX_DEV_LOADED=0
_lazy_load_linux_dev() {
    if [[ $LINUX_DEV_LOADED -eq 0 ]]; then
        # Sourcing redefines functions by the same names, replacing these wrappers
        # via ZSH dynamic dispatch — no recursion on success.
        source ~/git/dotfiles/zsh/functions/linux-dev.zsh && LINUX_DEV_LOADED=1
    fi
}
for func in podman-linux az-linux gcp-linux; do
    eval "${func}() { _lazy_load_linux_dev; ${func} \"\$@\"; }"
done

# Migration utilities (lazy-loaded — ~634 lines only parsed when first used)
typeset -g MIGRATE_LAPTOP_LOADED=0
_lazy_load_migrate() {
    if [[ $MIGRATE_LAPTOP_LOADED -eq 0 ]]; then
        # Sourcing redefines functions by the same names, replacing these wrappers
        # via ZSH dynamic dispatch — no recursion on success.
        source ~/git/dotfiles/zsh/functions/migrate-laptop.zsh && MIGRATE_LAPTOP_LOADED=1
    fi
}
for func in \
    migrate-to-new-laptop \
    export-wifi-credentials \
    import-wifi-credentials \
    list-wifi-networks \
    verify-migration \
    backup-before-migration \
    update-brewfile \
    brewfile-cleanup; do
    eval "${func}() { _lazy_load_migrate; ${func} \"\$@\"; }"
done
