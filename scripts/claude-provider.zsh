#!/bin/zsh -f
# Symlink as claude-t3-{copilot,vertex,openai,enmaas,hosted-only,mlx,vertex-native-adc,ollama}; claude-t3-glm-hybrid and
# claude-t3-glm-only are retired names for hosted-only. Never load .zshrc.
#
# Executable launcher for apps (e.g. T3 Code) that need a binary path instead
# of the interactive claude-<backend> shell functions. Fixed backend per
# symlink, independent of claude-mode. Flow: the bridge (Go by default, the
# Python file as fallback) sources the credential file
# (CLAUDE_PROVIDER_CREDENTIALS_FILE, default ~/secrets.zsh, output suppressed),
# then claude-provider-prepare.zsh runs the existing wrapper from
# zsh/functions/claude/ with its final `claude` call captured, then the native
# CLI (CLAUDE_PROVIDER_NATIVE_BINARY, default ~/.local/bin/claude) starts with
# the merged settings and pinned transport.
#
#   claude-t3-<backend> --prepare   prewarm proxy + catalogs, no prompt sent
#   claude-t3-<backend> --version   bypasses credentials/proxies entirely
#
# CLAUDE_PROVIDER_IMPL picks the bridge: auto (default; the Go build when its
# sources and a go toolchain exist), go or python. CLAUDE_PROVIDER_GO_BIN
# execs a prebuilt Go bridge directly. The Go bridge is what every T3 thread
# runs resident — a few MB instead of a Python interpreter (12–14 MB) per
# live thread; the Python file stays the portable fallback and the transient
# --background spawner for the LiteLLM proxy path.
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
[[ "$backend" == enmass ]] && backend=enmaas   # pre-rename launcher name
[[ "$backend" == glm-hybrid || "$backend" == glm-only || "$backend" == hybrid ]] && backend=hosted-only   # retired names
case "$backend" in
    copilot|vertex|openai|enmaas|hosted-only|mlx|vertex-native-adc|ollama) ;;
    *) print -ru2 -- 'Usage: claude-provider.zsh <copilot|vertex|openai|enmaas|hosted-only|mlx|vertex-native-adc|ollama> [Claude arguments | --prepare]'; exit 2 ;;
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

# _claude_provider_go_bin <root>: build (or reuse) the Go bridge in the state
# dir, rebuilt when a source changes — the same stamp pattern the Go proxy
# launcher uses.
_claude_provider_go_bin() {
    local src="$1/scripts/claude-provider-go" out bin stamp want
    [[ -d "$src" ]] || return 1
    command -v go >/dev/null || return 1
    out="${XDG_STATE_HOME:-$HOME/.local/state}/claude-provider-go"
    bin="$out/claude-provider" stamp="$out/source.sha"
    want=$( ( cd "$src" && cat go.mod *.go ) | shasum -a 256 | cut -d' ' -f1 ) || return 1
    if [[ ! -x "$bin" || "$(<"$stamp" 2>/dev/null)" != "$want" ]]; then
        mkdir -p "$out" || return 1
        # Build to a private name and rename into place: go build -o removes
        # and rewrites its target, so two fleet-synced launches rebuilding at
        # once could otherwise exec a half-written binary.
        local tmpbin="$bin.$$"
        ( cd "$src" && go build -trimpath -o "$tmpbin" . ) || {
            rm -f "$tmpbin"
            print -ru2 -- 'claude-provider: go build failed; falling back to the Python bridge.'
            return 1
        }
        mv -f "$tmpbin" "$bin" || return 1
        print -r -- "$want" >| "$stamp" || return 1
    fi
    print -r -- "$bin"
}

typeset impl="${CLAUDE_PROVIDER_IMPL:-auto}" gobin=
if [[ "$impl" == go || "$impl" == auto ]]; then
    if [[ -n "${CLAUDE_PROVIDER_GO_BIN-}" && -x "$CLAUDE_PROVIDER_GO_BIN" ]]; then
        gobin="$CLAUDE_PROVIDER_GO_BIN"
    else
        gobin=$(_claude_provider_go_bin "$root")
    fi
fi
if [[ -n "$gobin" ]]; then
    exec env CLAUDE_PROVIDER_ROOT="$root" "$gobin" "$backend" "$native" "$@"
elif [[ "$impl" == go ]]; then
    print -ru2 -- 'claude-provider: CLAUDE_PROVIDER_IMPL=go but the Go bridge is not buildable (no sources or no go).'
    exit 1
fi
exec python3 "$root/scripts/claude-provider.py" "$backend" "$native" "$@"
