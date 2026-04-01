# Description: General-purpose small utilities

code-git() {
    code ~/git/$1
}

# # Non Essentials -- for vscode
if [[ "$TERM_PROGRAM" != "vscode" ]]; then
    # view current prs in dirs matched by find . -type d -maxdepth 1 -name "<$1>"
    # view-pr-dirs "velero*"
    function view-pr-dirs() {
        find . -type d -maxdepth 1 -name "$1" -exec sh -c "cd {} && pwd && gh pr view --web" \;
    }
fi

# Update local .zshrc from the dotfiles repository
update-zshrc-from-dotfiles() {
    if [ ! -d "$HOME/git/dotfiles" ]; then
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
    read "reply?Apply these changes? [y/N] "
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        cp "$HOME/git/dotfiles/.zshrc" "$HOME/.zshrc"
        echo "Updated. Reload your shell or run 'source ~/.zshrc' to apply changes."
    else
        echo "Aborted."
    fi
}
