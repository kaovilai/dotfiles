# Description: General-purpose small utilities

# Poll a URL until it responds successfully, then notify via macOS say/sound.
# Usage: wait-for-url <url> [interval_seconds] [label]
# Examples:
#   wait-for-url https://quay.io/health
#   wait-for-url https://quay.io/api/v1/repository/ 30 "Quay.io"
#   wait-for-url https://api.example.com/status 60 "My API"
wait-for-url() {
    local url=$1
    local interval=${2:-30}
    local label=${3:-$url}

    if [[ -z "$url" ]]; then
        echo "Usage: wait-for-url <url> [interval_seconds] [label]" >&2
        return 1
    fi
    if ! command -v curl &>/dev/null; then
        echo "❌ curl not found. Install it with: brew install curl" >&2
        return 1
    fi

    echo "Polling $label every ${interval}s until it responds..."
    echo "URL: $url"
    echo "Press Ctrl-C to stop."

    local attempt=0
    while true; do
        ((attempt++))
        local http_code
        http_code=$(curl -sm 10 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)

        if [[ "$http_code" =~ ^[23] ]]; then
            echo ""
            echo "$(date '+%H:%M:%S') - $label is UP (HTTP $http_code)"
            if [[ "$OSTYPE" == darwin* ]]; then
                say "${label} is back up" &
                afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &
                local escaped_label="${label//\"/\\\"}"
                osascript -e "display notification \"${escaped_label} is back up (HTTP $http_code)\" with title \"Service Recovered\" sound name \"Glass\"" 2>/dev/null
            fi
            return 0
        fi

        printf "\r\033[K$(date '+%H:%M:%S') - attempt %d: HTTP %s - still down" "$attempt" "${http_code:-timeout}"
        sleep "$interval"
    done
}

code-git() {
    if [[ -z "$1" ]]; then
        echo "Usage: code-git <repo-name>" >&2
        return 1
    fi
    if ! command -v code &>/dev/null; then
        echo "❌ code not found. Install VS Code and run: Shell Command: Install 'code' command in PATH" >&2
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
            echo "❌ gh not found. Install it with: brew install gh" >&2
            return 1
        fi
        if [[ -z "$1" ]]; then
            echo "Usage: view-pr-dirs <pattern>" >&2
            echo "Example: view-pr-dirs \"velero*\"" >&2
            return 1
        fi
        if [[ -z "$(find . -type d -maxdepth 1 -name "$1" -print -quit)" ]]; then
            echo "❌ No directories found matching pattern: $1" >&2
            return 1
        fi
        find . -type d -maxdepth 1 -name "$1" -exec sh -c 'cd "$1" || { echo "Failed to cd into $1" >&2; exit 1; }; pwd && gh pr view --web' _ {} \;
    }
    alias view-pr-dirs='noglob view-pr-dirs'
fi

# Update local .zshrc from the dotfiles repository
update-zshrc-from-dotfiles() {
    if [[ ! -d "$HOME/git/dotfiles" ]]; then
        echo "Error: Dotfiles repository not found at $HOME/git/dotfiles" >&2
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
    local _diff_color=()
    diff --color /dev/null /dev/null &>/dev/null && _diff_color=(--color)
    diff "${_diff_color[@]}" "$HOME/.zshrc" "$HOME/git/dotfiles/.zshrc" && {
        echo "No changes to apply."
        return 0
    }
    echo
    local reply
    read -r "reply?Apply these changes? [y/N] "
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        cp "$HOME/git/dotfiles/.zshrc" "$HOME/.zshrc" || { echo "Error: Failed to copy .zshrc" >&2; return 1; }
        echo "Updated. Reload your shell or run 'source ~/.zshrc' to apply changes."
    else
        echo "Aborted."
    fi
}
