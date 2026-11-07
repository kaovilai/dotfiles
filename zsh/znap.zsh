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

# Tame zsh-autocomplete: require 2+ chars before suggesting from history
# (zstyle is global state; safe to set before the deferred source below.)
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
  # probe both casings: upstream dir is `Functions/`, some installs `functions/`;
  # lowercase-only path silently no-ops on case-sensitive Linux FS
  # (no `local` inside the loop body -- that SIGBUSes zsh 5.9 at function exit)
  local -a kbs=(
    $HOME/.zsh-snap/marlonrichert/zsh-autocomplete/Functions/Init/.autocomplete__key-bindings
    $HOME/.zsh-snap/marlonrichert/zsh-autocomplete/functions/Init/.autocomplete__key-bindings
  )
  local -P kb c tmp
  for kb in $kbs; do
    [[ -f $kb ]] || continue
    c=$(<$kb)
    [[ $c == *'$terminfo[kcbt]'* ]] || continue  # already patched / layout changed
    c=${c//'$terminfo[kcbt]'/'${terminfo[kcbt]-}'}
    c=${c//'$terminfo[kpp]'/'${terminfo[kpp]-}'}
    c=${c//'$terminfo[knp]'/'${terminfo[knp]-}'}
    # Write via temp + rename so a concurrently starting shell can never read
    # a half-truncated file.
    tmp=$kb.tmp.$$
    print -r -- $c > $tmp && command mv -f $tmp $kb
    # znap serves a compiled .zwc cache if present; drop it so the patched
    # source is recompiled on next source.
    command rm -f $kb.zwc
  done
}

# -- Deferred plugins (turbo-style) --
# zsh-syntax-highlighting and zsh-autocomplete are the heaviest startup cost
# after the prompt itself (zprof: ~40% of startup), and neither is needed
# until the first keystroke. Load them once zle goes idle after the first
# prompt renders: register a `zle -F` handler on a pipe, then have a
# background writer make it readable. zle services -F fds only while idle at
# the prompt, so the first prompt appears before any of this runs.
_zsh_deferred_plugins() {
  zle -F $_ZSH_DEFER_FD 2>/dev/null   # unregister the fd
  exec {_ZSH_DEFER_FD}>&-             # close the pipe
  znap source zsh-users/zsh-syntax-highlighting
  znap source marlonrichert/zsh-autocomplete
  # zsh-autocomplete rebinds ^R to its own async completion-menu toggle instead
  # of real incremental search, and that async path can silently fail to produce
  # matches. Restore native reverse-i-search so Ctrl+R reliably works.
  bindkey '^R' .history-incremental-search-backward
}
if [[ -o interactive ]]; then
  # /dev/null is permanently readable (EOF counts), so zle fires the handler
  # the first time it goes idle — right after the first prompt draws. No fork
  # needed (a process-substitution pipe works too but costs a fork, which
  # measurably slows first-prompt on this setup).
  exec {_ZSH_DEFER_FD}< /dev/null
  zle -F $_ZSH_DEFER_FD _zsh_deferred_plugins
else
  # No zle (non-interactive source of .zshrc): load inline, keep old behavior.
  znap source zsh-users/zsh-syntax-highlighting
  znap source marlonrichert/zsh-autocomplete
  bindkey '^R' .history-incremental-search-backward
fi

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

