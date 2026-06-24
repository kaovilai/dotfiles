# Configure znap caching
zstyle ':znap:*' repos-dir ~/.zsh-snap
# Extend cache TTL to reduce network requests and speed up shell startup
zstyle ':znap:*:*' ttl 604800  # Cache for 7 days (in seconds)

autoload -Uz compinit
# Run full compinit when:
#   - the dump doesn't exist yet (first run), OR
#   - the dump is older than 24h (mh+24 = modified more than 24h ago)
# Otherwise use -C to skip the fpath security scan for faster startup.
() {
  setopt local_options extended_glob
  local _zcompdump="${ZDOTDIR:-$HOME}/.zcompdump"
  local -a dump_check
  dump_check=( ${_zcompdump}(#qN.mh+24) )
  if [[ ! -f $_zcompdump || ${#dump_check} -gt 0 ]]; then
    compinit          # no dump or stale: rebuild and re-check fpath security
  else
    compinit -C       # dump is fresh: skip security scan for faster startup
  fi
}

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

