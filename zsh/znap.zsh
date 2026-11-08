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
# Hosts missing the local terminal's terminfo entry (e.g. TERM=xterm-ghostty over
# ssh to a machine without ghostty's terminfo) leave $terminfo empty and READ-ONLY
# (not fixable in-shell: zsh/terminfo caches the entry from the shell's startup
# TERM, even across module unload/reload). zsh-autocomplete then reads
# $terminfo[kcbt] unguarded, which errors under nounset:
# ".autocomplete__key-bindings:39: terminfo[kcbt]: parameter not set".
# Patch the plugin's unguarded terminfo reads with ${...-} defaults, idempotently
# (re-applies after `znap pull` overwrites the file). Real fix for the missing
# entry itself is on the remote host:
#   infocmp -x xterm-ghostty | ssh <host> -- tic -x -
() {
  # plugin dir is `Functions/` upstream; lowercase `functions/` only resolves on
  # case-insensitive macOS FS, so Linux hosts silently skipped the patch
  # probe both casings: upstream dir is `Functions/`, some installs `functions/`;
  # lowercase-only path silently no-ops on case-sensitive Linux FS
  # (no `local` inside the loop body -- that SIGBUSes zsh 5.9 at function exit)
  local -a kbs=(
    $HOME/.zsh-snap/marlonrichert/zsh-autocomplete/Functions/Init/.autocomplete__key-bindings
    $HOME/.zsh-snap/marlonrichert/zsh-autocomplete/functions/Init/.autocomplete__key-bindings
  )
  local -P kb=""
  local -P f
  for f in $kbs; do
    [[ -f $f ]] && kb=$f && break
  done
  [[ -n $kb ]] || return
  local -P c=$(<$kb)
  [[ $c == *'$terminfo[kcbt]'* ]] || return  # already patched / layout changed
  c=${c//'$terminfo[kcbt]'/'${terminfo[kcbt]-}'}
  c=${c//'$terminfo[kpp]'/'${terminfo[kpp]-}'}
  c=${c//'$terminfo[knp]'/'${terminfo[knp]-}'}
  print -r -- $c > $kb
}
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

