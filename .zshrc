# expected content of ~/.zshrc
# ```
# source ~/git/dotfiles/.zshrc
# ```
# -- Essential initialization section (happens in foreground) --
source ~/git/dotfiles/zsh/znap.zsh
[[ -f ~/git/dotfiles/zsh/znap.zsh ]] || sh -c "mkdir -p ~/git && git clone --depth 1 -- \
    git@github.com:kaovilai/dotfiles.git ~/git/dotfiles"
# Don't put secrets here, put them in ~/secrets.zsh
# edit ~/.zshrc first then run copy-to-dotfiles-from-zshrc to copy to dotfiles
[[ -f ~/secrets.zsh ]] && source ~/secrets.zsh
export HISTSIZE=100000 # number of commands stored in history
export HISTFILESIZE=200000 # bytes in history file
source ~/git/dotfiles/zsh/colors.zsh

# Essential exports and aliases for immediate shell usage
alias edit-dotfiles='code ~/git/dotfiles/'
source ~/git/dotfiles/zsh/alias.zsh
# gpg tty
export GPG_TTY=$(tty)
# Export essential environment variables
export CONTAINER_ENGINE=docker
export BUILDX_ENABLED=true
export BUILDX_PUSH=true
export GCR_IMAGE_TAGS=""
export BUILDX_PLATFORMS=linux/amd64,linux/arm64

# Load OS-specific essentials
[[ "$(uname -s)" = "Darwin" ]] && source ~/git/dotfiles/zsh/macos.zsh

# Essential znap functions
znap function update-zshrc-from-dotfiles() {
  git -C ~/git/dotfiles pull > /dev/null && \
  cp ~/git/dotfiles/.zshrc ~/.zshrc
}
znap function copy-to-dotfiles-from-zshrc() {
  cp ~/.zshrc ~/git/dotfiles/.zshrc && \
  git -C ~/git/dotfiles diff
  echo
  echo "${RED}push-dotfiles-from-zshrc${NC} to push dotfiles"
}
znap function push-dotfiles-from-zshrc() {
  git -C ~/git/dotfiles add .zshrc && \
  git -C ~/git/dotfiles commit -m "Update .zshrc" && \
  git -C ~/git/dotfiles push
}

# Essential utilities (needed for basic shell functionality)
source ~/git/dotfiles/zsh/paths.zsh
source ~/git/dotfiles/zsh/command-cache.zsh
source ~/git/dotfiles/zsh/cached-commands.zsh

# -- Non-essential initialization (happens in background) --
{
  # Load extended utilities in background
  source ~/git/dotfiles/zsh/util.zsh
  source ~/git/dotfiles/zsh/go.zsh
  source ~/git/dotfiles/zsh/openshift-functions.zsh
  source ~/git/dotfiles/zsh/aws.zsh
  source ~/git/dotfiles/zsh/podman.zsh
  
  # Load completions system (already has internal background processes)
  source ~/git/dotfiles/zsh/completions.zsh
  
  # Load GitHub Copilot aliases
  eval "$(gh copilot alias -- zsh)"
  
  # # Git status check in background
  # if [[ "$TERM_PROGRAM" != "vscode" ]]; then
  #   if git -C ~/git/dotfiles status --porcelain | grep -q "M"; then
  #     echo "dotfiles repo has uncommitted changes, run ${RED}edit-dotfiles${NC} to review"
  #   fi
  # fi
} &!
# # bun completions
# [ -s "/Users/tiger/.bun/_bun" ] && source "/Users/tiger/.bun/_bun"


# # bun
# export BUN_INSTALL="$HOME/.bun"
# export PATH="$BUN_INSTALL/bin:$PATH"

# export PATH="$HOME/.local/bin:$PATH"

# [ -f "/Users/tiger/.ghcup/env" ] && . "/Users/tiger/.ghcup/env" # ghcup-env
