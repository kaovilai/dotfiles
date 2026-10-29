# Configure znap caching. znap aborts ("Could not find repos dir") when the
# dir is missing, which is every first shell on a new machine.
[[ -d ~/.zsh-snap ]] || mkdir -p ~/.zsh-snap
zstyle ':znap:*' repos-dir ~/.zsh-snap
# Extend cache TTL to reduce network requests and speed up shell startup
zstyle ':znap:*:*' ttl 604800  # Cache for 7 days (in seconds)

# Do NOT call compinit here: zsh-autocomplete runs it itself (its README says to
# remove all compinit calls). An early compinit runs before the plugin prepends
# its Completions dir to fpath, so the dump lacks its `#autoload` helpers; the
# plugin then sees _comp_setup + a readable dump, skips its own compinit, and
# completion widgets (e.g. Up-arrow history) fail with
# "command not found: _autocomplete__history_lines".

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

# zsh-autocomplete rebinds ^R to its own async completion-menu toggle instead of
# real incremental search, and that async path can silently fail to produce
# matches. Restore native reverse-i-search so Ctrl+R reliably works.
bindkey '^R' .history-incremental-search-backward

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

