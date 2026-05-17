# Description: General-purpose small utilities

code-git() {
    if [[ -z "$1" ]]; then
        echo "Usage: code-git <repo-name>"
        return 1
    fi
    if ! command -v code &>/dev/null; then
        echo "❌ code not found. Install VS Code and run: Shell Command: Install 'code' command in PATH"
        return 1
    fi
    code ~/git/"$1"
}

# # Non Essentials -- for vscode
if [[ "$TERM_PROGRAM" != "vscode" ]]; then
    # view current prs in dirs matched by find . -type d -maxdepth 1 -name "<$1>"
    # view-pr-dirs "velero*"
    function view-pr-dirs() {
        if ! command -v gh &>/dev/null; then
            echo "❌ gh not found. Install it with: brew install gh"
            return 1
        fi
        if [[ -z "$1" ]]; then
            echo "Usage: view-pr-dirs <pattern>"
            echo "Example: view-pr-dirs \"velero*\""
            return 1
        fi
        find . -type d -maxdepth 1 -name "$1" -exec sh -c 'cd "$1" && pwd && gh pr view --web' _ {} \;
    }
fi

# Update local .zshrc from the dotfiles repository
update-zshrc-from-dotfiles() {
    if [[ ! -d "$HOME/git/dotfiles" ]]; then
        echo "Error: Dotfiles repository not found at $HOME/git/dotfiles"
        return 1
    fi

    # If already symlinked, no copying needed
    if [[ -L "$HOME/.zshrc" && "$(readlink "$HOME/.zshrc")" == *"git/dotfiles/.zshrc" ]]; then
        echo "~/.zshrc is already symlinked to the dotfiles repo. Changes are live automatically."
        return 0
    fi

    # Recommend symlink instead of copying
    echo "Tip: Symlink instead of copying so changes are always live:"
    echo "  ln -sf ~/git/dotfiles/.zshrc ~/.zshrc"
    echo ""

    echo "Updating .zshrc from dotfiles repository..."
    diff --color "$HOME/.zshrc" "$HOME/git/dotfiles/.zshrc" && {
        echo "No changes to apply."
        return 0
    }
    echo
    local reply
    read "reply?Apply these changes? [y/N] "
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        cp "$HOME/git/dotfiles/.zshrc" "$HOME/.zshrc"
        echo "Updated. Reload your shell or run 'source ~/.zshrc' to apply changes."
    else
        echo "Aborted."
    fi
}
