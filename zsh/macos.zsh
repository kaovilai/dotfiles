# Essential macOS aliases and lightweight operations
# These are always available, including in VS Code

alias ghd='open -a GitHub\ Desktop'
alias finder='open -R'
alias idlesleeppreventers='pmset -g assertions'
alias comet='open -a Comet'
alias edgedev='open -a Microsoft\ Edge\ Dev'
alias edge='open -a Microsoft\ Edge'
alias docker-desktop='open -a /Applications/Docker.app/Contents/MacOS/Docker\ Desktop.app'
alias dockerd='open -a /Applications/Docker.app'
alias dequarantine='xattr -d com.apple.quarantine'
alias dequarantine-dir='xattr -dr com.apple.quarantine'
alias dsstoredelete='find . -name .DS_Store -delete'
alias terminal='open -a Terminal .'

alias install-pkg='sudo installer -target LocalSystem -pkg'

install-pkg-from-url(){
    if [[ -z "$1" ]]; then
        echo "Usage: install-pkg-from-url <https://...pkg>" >&2
        return 1
    fi
    if [[ ! "$1" =~ ^https:// ]]; then
        echo "Error: Only HTTPS URLs are supported" >&2
        return 1
    fi
    echo "Warning: Installing unverified package from URL. No checksum verification."
    local pkg_file=~/Downloads/"${${1:t}%%\?*}"
    curl -Lm 60 -o "$pkg_file" "$1" && install-pkg "$pkg_file"
}

PATH=$PATH:/Library/Frameworks/Python.framework/Versions/Current/bin

# Source heavy operations only when not in VS Code
if [[ "$TERM_PROGRAM" != "vscode" ]]; then
    source ~/git/dotfiles/zsh/macos-notvscode.zsh
fi
