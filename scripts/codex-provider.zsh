#!/bin/zsh -f
# Symlink as codex-t3-enmass or codex-t3-glm-hybrid. Never load .zshrc.
#
# Executable launcher for apps (e.g. T3 Code) that need a binary path instead
# of an interactive shell function. Fixed backend per symlink, independent of
# claude-mode. Sources the credential file (CLAUDE_PROVIDER_CREDENTIALS_FILE,
# default ~/secrets.zsh, output suppressed) for ENMAAS_API_KEY, then the
# native Codex CLI (CODEX_PROVIDER_NATIVE_BINARY, default ~/.local/bin/codex)
# starts with its arguments unchanged. Provider, model, and reasoning wiring
# travels in T3's per-instance launchArgs as `-c` config overrides, the same
# mechanism T3's own managed Codex runtime uses.
#
# enmass: adds nothing but credentials. Codex talks to the gateway directly
# (Responses API); no local proxy.
#
# glm-hybrid: GLM on EnMaaS as the main model, an OpenAI model (default
# gpt-6-luna) as the auto-review model. Codex sends the auto-review request
# to the same model_provider as the main model, so both go through the local
# "codex" GLM hybrid LiteLLM proxy (scripts/glm-hybrid-proxy.zsh, port 4147),
# which routes by model id. Codex gets only the local proxy token as
# GLM_HYBRID_PROXY_TOKEN, never the upstream keys. Session exit leaves the
# proxy running; a changed config or key refuses to start until stopped:
#
#   codex-provider.zsh glm-hybrid --stop-proxy
#   codex-t3-enmass --version   bypasses credentials entirely
emulate -L zsh
unsetopt xtrace verbose
typeset backend="${0:t}"
backend="${backend#codex-t3-}"
if [[ "$backend" == codex-provider.zsh ]]; then
    backend="${1-}"
    (( $# )) && shift
fi
case "$backend" in
    enmass|glm-hybrid) ;;
    *) print -ru2 -- 'Usage: codex-provider.zsh <enmass|glm-hybrid> [Codex arguments]'; exit 2 ;;
esac
typeset native="${CODEX_PROVIDER_NATIVE_BINARY:-$HOME/.local/bin/codex}"
[[ -x "$native" && "${native:A}" != "${0:A}" ]] || {
    print -ru2 -- 'codex-provider: native Codex executable is missing or points at the bridge.'
    exit 1
}
# T3's four-second version check must not source credentials or start services.
if (( $# == 1 )) && [[ "$1" == --version || "$1" == --help || "$1" == -h ]]; then
    exec "$native" "$@"
fi
typeset -U path
path=(/opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.bun/bin" $path)

source "${0:A:h}/glm-hybrid-proxy.zsh" || exit 1

if [[ "$backend" == glm-hybrid && "${1-}" == --stop-proxy ]]; then
    _glm_hybrid_proxy_stop codex
    exit $?
fi

[[ -n "${ENMAAS_API_KEY-}" ]] || {
    typeset credentials="${CLAUDE_PROVIDER_CREDENTIALS_FILE:-$HOME/secrets.zsh}"
    [[ -r "$credentials" ]] && source "$credentials" >/dev/null
}
[[ -n "${ENMAAS_API_KEY-}" ]] || {
    print -ru2 -- 'codex-provider: ENMAAS_API_KEY is not set and no credential file provided it.'
    exit 1
}

if [[ "$backend" == enmass ]]; then
    export ENMAAS_API_KEY
    exec "$native" "$@"
fi

# glm-hybrid
_glm_hybrid_proxy_ensure codex || {
    [[ -f "$_ghp_runtime/fingerprint" ]] || exit 1
    print -ru2 -- 'codex-provider: to restart it: codex-provider.zsh glm-hybrid --stop-proxy'
    exit 1
}
unset ENMAAS_API_KEY OPENAI_API_KEY
export GLM_HYBRID_PROXY_TOKEN="$_ghp_token"
exec "$native" "$@"
