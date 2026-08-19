# Configure znap caching
zstyle ':znap:*' repos-dir ~/.zsh-snap
# Extend cache TTL to reduce network requests and speed up shell startup
zstyle ':znap:*:*' ttl 604800  # Cache for 7 days (in seconds)

# Optimization: Znap handles compinit automatically and efficiently out of the box,
# regenerating the comp dump file as needed, so manual invocation is redundant
# and negatively impacts shell startup performance.

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

# -- Daily auto-update of all znap plugins --
# znap does NOT auto-update; `znap pull` is manual. Run it at most once per 24h,
# in the background, so plugin repos (pure, syntax-highlighting, etc.) stay fresh
# without slowing shell startup. Guarded by a timestamp file's mtime.
() {
  setopt local_options extended_glob
  local _stamp=~/.zsh-snap/.last-pull
  # Run when stamp is missing OR older than 24h (mh+24 = modified 24+ hours ago).
  local -a _stale=($_stamp(#qN.mh+24))
  if [[ ! -f $_stamp ]] || (( ${#_stale} > 0 )); then
    ( znap pull &> ~/.zsh-snap/.last-pull.log ) &!
    print -n > $_stamp   # touch stamp now so concurrent shells don't also pull
  fi
}

