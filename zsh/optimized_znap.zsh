#!/usr/bin/env zsh
# optimized_znap.zsh - Optimized version of znap.zsh for faster startup

# Configure znap repos directory
zstyle ':znap:*' repos-dir ~/.zsh-snap

# Skip compinit as it's already done in optimized_completions.zsh
# autoload -Uz compinit
# compinit

# Download Znap, if it's not there yet.
if [[ ! -f ~/git/zsh-snap/znap.zsh ]]; then
  echo "Installing znap..."
  git clone --depth 1 -- \
    https://github.com/marlonrichert/zsh-snap.git ~/git/zsh-snap
fi

# Start Znap
source ~/git/zsh-snap/znap.zsh

# Configure prompt immediately since it affects the prompt display
znap prompt sindresorhus/pure

# Load essential plugins in the background to speed up startup
{
  # Use znap eval to cache plugin output when possible
  znap source zsh-users/zsh-syntax-highlighting
  
  # zsh-autocomplete is loaded last as it's the heaviest plugin
  znap source marlonrichert/zsh-autocomplete
} &!

# Define znap function wrappers in the main shell
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
