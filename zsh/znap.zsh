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

# -- Essential prompt initialization (foreground) --
# Prompt setup - keep in foreground as it's visually important
znap prompt sindresorhus/pure

# -- Essential plugins (foreground) --
# Syntax highlighting is loaded in foreground for immediate feedback
znap source zsh-users/zsh-syntax-highlighting
znap source marlonrichert/zsh-autocomplete

# -- Non-essential plugins (background) --
{
} &!


# -- Asynchronous evaluations --
# Start background initializations
{
  # Shell integrations and environment setup
  [[ -n "$ITERM_PROFILE" ]] && znap eval iterm2 'curl -fsSL https://iterm2.com/shell_integration/zsh'

  # Node version manager (if installed)
  [[ -s "$HOME/.nvm/nvm.sh" ]] && znap eval nvm-init "$HOME/.nvm/nvm.sh"

  # Python virtual environment managers
  command -v pyenv >/dev/null && znap eval pyenv-init 'pyenv init -'
  command -v pipenv >/dev/null && znap eval pipenv-shell 'pipenv --completion'
} &!
