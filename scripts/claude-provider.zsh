#!/bin/zsh -f
# Symlink as claude-t3-{copilot,vertex,openai,enmass}. Never load .zshrc.
emulate -L zsh
unsetopt xtrace verbose
typeset root="${0:A:h:h}" backend="${0:t}"
backend="${backend#claude-t3-}"
if [[ "$backend" == claude-provider.zsh ]]; then
    backend="${1-}"
    (( $# )) && shift
fi
case "$backend" in
    copilot|vertex|openai|enmass) ;;
    *) print -ru2 -- 'Usage: claude-provider.zsh <copilot|vertex|openai|enmass> [Claude arguments | --prepare]'; exit 2 ;;
esac
typeset native="${CLAUDE_PROVIDER_NATIVE_BINARY:-$HOME/.local/bin/claude}"
[[ -x "$native" && "${native:A}" != "${0:A}" ]] || {
    print -ru2 -- 'claude-provider: native Claude executable is missing or points at the bridge.'
    exit 1
}
# T3's four-second version check must not source credentials or start services.
if (( $# == 1 )) && [[ "$1" == --version || "$1" == --help || "$1" == -h ]]; then
    exec "$native" "$@"
fi
typeset -U path
path=(/opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.bun/bin" $path)
exec python3 "$root/scripts/claude-provider.py" "$backend" "$native" "$@"
