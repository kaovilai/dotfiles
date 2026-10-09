#!/bin/zsh -f
# Symlink as claude-t3-{copilot,vertex,openai,enmass}. Never load .zshrc.
#
# Executable launcher for apps (e.g. T3 Code) that need a binary path instead
# of the interactive claude-<backend> shell functions. Fixed backend per
# symlink, independent of claude-mode. Flow: claude-provider.py sources the
# credential file (CLAUDE_PROVIDER_CREDENTIALS_FILE, default ~/secrets.zsh,
# output suppressed), then claude-provider-prepare.zsh runs the existing
# wrapper from zsh/functions/claude/ with its final `claude` call captured,
# then the native CLI (CLAUDE_PROVIDER_NATIVE_BINARY, default
# ~/.local/bin/claude) starts with the merged settings and pinned transport.
#
#   claude-t3-<backend> --prepare   prewarm proxy + catalogs, no prompt sent
#   claude-t3-<backend> --version   bypasses credentials/proxies entirely
#
# Shares the wrappers' local proxies. Unlike the interactive wrappers, a
# changed config fingerprint is refused with a restart instruction rather
# than restarting a proxy other sessions use. Preparation is serialized per
# backend under ${XDG_STATE_HOME:-~/.local/state}/claude-provider/; catalog
# data (no credentials) is cached under ${XDG_CACHE_HOME:-~/.cache}/claude-provider/.
# Upstream keys stay with their proxies; Claude only gets local tokens.
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
