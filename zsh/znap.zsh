# Configure znap caching
zstyle ':znap:*' repos-dir ~/.zsh-snap
# Extend cache TTL to reduce network requests and speed up shell startup
zstyle ':znap:*:*' ttl 604800  # Cache for 7 days (in seconds)

autoload -Uz compinit
compinit

# Download Znap, if it's not there yet.
[[ -f ~/git/zsh-snap/znap.zsh ]] ||
    git clone --depth 1 -- \
        https://github.com/marlonrichert/zsh-snap.git ~/git/zsh-snap

source ~/git/zsh-snap/znap.zsh  # Start Znap

# `znap prompt` reduces your shell's startup time to just 15-40 ms!
znap prompt sindresorhus/pure

# `znap source` automatically downloads and installs your plugins.
znap source marlonrichert/zsh-autocomplete
# conflicts I think with autocomplete
# znap source zsh-users/zsh-autosuggestions
znap source zsh-users/zsh-syntax-highlighting

# `znap eval` caches any kind of command output for you.
# znap eval iterm2 'curl -fsSL https://iterm2.com/shell_integration/zsh'

# This section configures eval caching for frequently used commands
# These are commands that:
# 1. Generate shell code that needs to be evaluated
# 2. Take time to execute but change infrequently
# 3. Are part of your common development workflow

# Shell integrations and environment setup
[[ -n "$ITERM_PROFILE" ]] && znap eval iterm2 'curl -fsSL https://iterm2.com/shell_integration/zsh'

# Node version manager (if installed)
[[ -s "$HOME/.nvm/nvm.sh" ]] && znap eval nvm-init "$HOME/.nvm/nvm.sh"

# Python virtual environment managers
command -v pyenv >/dev/null && znap eval pyenv-init 'pyenv init -'
command -v pipenv >/dev/null && znap eval pipenv-shell 'pipenv --completion'
