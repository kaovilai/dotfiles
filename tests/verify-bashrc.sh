#!/usr/bin/env bash
# shellcheck disable=SC2016  # $-style vars in single quotes are intentional:
# they must expand inside the child bash -i, not in this script
# CI: prove .bashrc and .bash_profile work on this OS.
#
# Sources them under a throwaway HOME (repo symlinked in as ~/git/dotfiles,
# like a real machine) and verifies the interactive shell comes up with the
# configured shopt options, aliases and history settings.
#
# Usage: tests/verify-bashrc.sh [repo-root]   (default: parent of tests/)
# Safe to run anywhere: real $HOME is never touched.

set -euo pipefail

REPO_ROOT=${1:-$(cd -- "$(dirname -- "$0")/.." && pwd)}
[[ -f "$REPO_ROOT/.bashrc" ]] || { echo "no .bashrc under $REPO_ROOT" >&2; exit 2; }

TESTHOME=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-bash-ci.XXXXXX")
trap 'rm -rf -- "$TESTHOME"' EXIT
mkdir -p -- "$TESTHOME/git"
ln -s -- "$REPO_ROOT" "$TESTHOME/git/dotfiles"
ln -s -- "$TESTHOME/git/dotfiles/.bashrc" "$TESTHOME/.bashrc"
ln -s -- "$TESTHOME/git/dotfiles/.bash_profile" "$TESTHOME/.bash_profile"

# bash -i without a tty prints job-control warnings on stderr; anything else
# is a real problem — fail on it. Prints the captured stderr when the command
# itself fails, so the actual error isn't swallowed by set -e.
check() {
  if ! HOME="$TESTHOME" "$@" 2>"$TESTHOME/stderr.log"; then
    echo "FAILED: $*" >&2
    cat "$TESTHOME/stderr.log" >&2
    return 1
  fi
}
noise_ok() {
  local unexpected
  unexpected=$(grep -avE '^bash: (cannot set terminal process group|no job control in this shell)' "$TESTHOME/stderr.log") || true
  if [[ -n "$unexpected" ]]; then
    echo "unexpected stderr from bash:" >&2
    printf '%s\n' "$unexpected" >&2
    return 1
  fi
}

echo '==> interactive bash sources .bashrc (aliases, shopt, history)'
# set -e inside the child: without it only the LAST line's status is the
# exit code, so earlier failures would be masked
check bash -i -c '
  set -e
  shopt -q histappend
  shopt -q checkwinsize
  # globstar is bash 4+ only (macOS ships bash 3.2)
  if ((BASH_VERSINFO[0] >= 4)); then shopt -q globstar; fi
  [[ $HISTSIZE == 1000 && $HISTFILESIZE == 2000 && $HISTCONTROL == ignoreboth ]]
  alias ls >/dev/null
  alias ll >/dev/null
  alias la >/dev/null
  alias z >/dev/null
  alias grep >/dev/null
'
noise_ok

echo '==> login bash sources .bash_profile -> .bashrc chain'
check bash -l -i -c 'alias ll >/dev/null && [[ $PAGER == less ]]'
noise_ok

echo '==> OK: .bashrc and .bash_profile work'
