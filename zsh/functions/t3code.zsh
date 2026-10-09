# T3 Code: build desktop app from local checkout and install it to /Applications

# Rebuild the arm64 DMG from the local t3code checkout and replace the installed app.
# Usage: install-t3code-from-source [--pull] [--no-install]
#   --pull        git pull --ff-only before building
#   --no-install  build the DMG only
install-t3code-from-source() {
    local repo="${T3CODE_REPO:-$HOME/git/t3code}"
    local pull=0 install=1 arg
    for arg in "$@"; do
        case $arg in
            --pull) pull=1 ;;
            --no-install) install=0 ;;
            *) echo "Unknown option: $arg" >&2; return 1 ;;
        esac
    done

    [[ -d $repo/.git ]] || { echo "❌ t3code checkout not found at $repo (set T3CODE_REPO)" >&2; return 1; }

    # rustup is keg-only under Homebrew; the desktop build needs cargo
    path=(/opt/homebrew/opt/rustup/bin $HOME/.cargo/bin $path)
    command -v cargo &>/dev/null || { echo "❌ cargo not found. brew install rustup && rustup default stable" >&2; return 1; }
    rustup target add aarch64-apple-darwin || return 1

    (
        set -e
        cd "$repo"
        (( pull )) && git pull --ff-only
        pnpm install --frozen-lockfile
        pnpm run dist:desktop:dmg:arm64
    ) || { echo "❌ t3code build failed" >&2; return 1; }

    local dmg
    dmg=$(ls -t "$repo"/release/*-arm64.dmg(N) 2>/dev/null | head -1)
    [[ -n $dmg ]] || { echo "❌ no DMG found in $repo/release" >&2; return 1; }
    echo "✅ Built $dmg"
    (( install )) || return 0

    local mnt
    mnt=$(mktemp -d /tmp/t3code-dmg.XXXXXX)
    hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null || return 1
    local app=("$mnt"/*.app(N))
    if [[ -z $app ]]; then
        echo "❌ no .app in DMG" >&2
        hdiutil detach "$mnt" >/dev/null; return 1
    fi
    local name="${app[1]:t}"

    # Quit running instance, then replace
    osascript -e "tell application \"${name%.app}\" to quit" &>/dev/null
    sleep 2
    rm -rf "/Applications/$name"
    ditto "${app[1]}" "/Applications/$name" && xattr -cr "/Applications/$name"
    local rc=$?
    hdiutil detach "$mnt" >/dev/null; rmdir "$mnt" 2>/dev/null
    (( rc == 0 )) && echo "✅ Installed /Applications/$name" || echo "❌ install failed" >&2
    return $rc
}
