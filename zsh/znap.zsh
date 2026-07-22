# Configure znap caching
zstyle ':znap:*' repos-dir ~/.zsh-snap
# Extend cache TTL to reduce network requests and speed up shell startup
zstyle ':znap:*:*' ttl 604800  # Cache for 7 days (in seconds)

# Optimization: Znap automatically handles compinit and comp dumps out of the box.
# Manually calling compinit degrades shell startup performance due to redundant execution.

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
# Tame zsh-autocomplete: require 2+ chars before suggesting from history
zstyle ':autocomplete:*' min-input 2
znap source marlonrichert/zsh-autocomplete

