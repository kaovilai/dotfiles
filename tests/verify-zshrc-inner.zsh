#!/usr/bin/env zsh
# Inner half of tests/verify-zshrc.zsh — NOT run directly.
# Sourced by an interactive zsh (so .zshrc has run) with:
#   EXPECTED_FUNCTIONS  file listing every repo-defined function name
#   STDERR_CAPTURE      file to reattach stderr to (see below)
# Prints missing names and exits 1, or reports success.

# No `set -u`: replicate a real user shell (no nounset) — several function
# files legitimately read possibly-unset vars like $TERM_PROGRAM.
# pure's async worker (started via zpty during prompt init) replaces fd 2 with
# a zsh temp file in tty-less interactive shells (zsh-async issue #35 variant),
# silently swallowing every later stderr message. Reopen stderr so failures
# from the lazy loaders below are actually visible.
[[ -n "${STDERR_CAPTURE:-}" ]] && exec 2>>"$STDERR_CAPTURE"

fail=0

# Fire every lazy loader the repo registered (.zshrc + alias.zsh + load-lazy
# files): git-utils, podman-utils, dns, symlink-sd, wifi, openshift, s3,
# linux-dev, migrate-laptop, ...
for loader in ${(k)functions[(I)_lazy_load*]}; do
  if ! $loader; then
    print "lazy loader FAILED: $loader"
    fail=1
  fi
done
(( fail )) && exit 1
print '    all lazy loaders fired'

# .zshrc sources command-cache.zsh (via completions.zsh) in a disowned
# background job — a race against this check. Source both synchronously;
# both are idempotent and side-effect-light (completion regen is guarded by
# has-command checks).
_safe_source ~/git/dotfiles/zsh/command-cache.zsh || { print 'command-cache.zsh failed to source'; exit 1 }
_safe_source ~/git/dotfiles/zsh/completions.zsh || { print 'completions.zsh failed to source'; exit 1 }
print '    command-cache + completions sourced'

# Canaries: prove .zshrc executed through to its final lines. Needed because
# pure's async worker relays fd 2 through a zpty temp file in tty-less
# interactive shells, so late startup errors don't reliably reach the
# captured stderr — side effects are checked directly instead.
canary_fail=0
canary() { # canary <description> <zsh condition, evaluated>
  if ! eval "$2"; then
    print "CANARY FAILED: $1"
    canary_fail=1
  fi
}
canary 'HISTSIZE from .zshrc exports'      '[[ $HISTSIZE == 100000 ]]'
canary 'HISTFILESIZE from .zshrc'          '[[ $HISTFILESIZE == 200000 ]]'
canary 'BUILDX_ENABLED from .zshrc'        '[[ $BUILDX_ENABLED == true ]]'
canary 'BUILDX_INSTANCE from .zshrc'       '[[ $BUILDX_INSTANCE == default ]]'
canary 'CLAUDE_CODE_ENABLE_TASKS'          '[[ $CLAUDE_CODE_ENABLE_TASKS == 1 ]]'
canary 'edit-dotfiles alias (early)'       '[[ -n $aliases[edit-dotfiles] ]]'
canary 'noglob alias (go-mod-upgrade-dirs)' \
  '[[ $aliases[go-mod-upgrade-dirs] == "noglob go-mod-upgrade-dirs" ]]'
canary 'lazy loader defined (_lazy_load_wifi)' '[[ -n $functions[_lazy_load_wifi] ]]'
canary 'FPATH has ~/.zsh/completions'      '[[ ":$FPATH:" == *":$HOME/.zsh/completions:"* ]]'
canary 'PATH has ~/.bun/bin (late .zshrc)' '[[ ":$PATH:" == *":$HOME/.bun/bin:"* ]]'
canary 'PATH has ~/.local/bin (late .zshrc)' \
  '[[ ":$PATH:" == *":$HOME/.local/bin:"* ]]'
if (( canary_fail )); then exit 1; fi
print '    .zshrc canaries all set (executed through to the end)'

missing=()
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  # whence -w prints "name: kind" (function/alias/builtin/command/none)
  kind=$(whence -w -- "$name" 2>/dev/null) || kind='none'
  if [[ "$kind" != *": function" && "$kind" != *": alias" ]]; then
    missing+=("$name")
  fi
done <"$EXPECTED_FUNCTIONS"

if (( ${#missing} )); then
  print -u2 "MISSING after full load (${#missing}):"
  print -u2 - "  $missing"
  exit 1
fi
print "    all functions resolve (checked $(wc -l <"$EXPECTED_FUNCTIONS" | tr -d ' ') names)"
exit 0
