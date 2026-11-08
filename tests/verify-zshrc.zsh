#!/usr/bin/env zsh
# CI: prove .zshrc works end to end on this OS.
#
#  1. Sources .zshrc in an interactive shell under a throwaway HOME (repo
#     symlinked in as ~/git/dotfiles, ~/.zshrc symlinked, like a real machine)
#     and fails on any startup error (command not found, parse error, ...).
#  2. Fires every registered lazy loader, then checks that every function
#     defined anywhere in the repo's zsh files resolves via `whence`
#     (as a function or alias) — i.e. nothing is broken or unreachable.
#
# Usage: tests/verify-zshrc.zsh [repo-root]   (default: parent of tests/)
# Safe to run anywhere: real $HOME is never touched.

set -eu
set -o pipefail

REPO_ROOT=${1:-$(cd -- "${${(%):-%x}:A:h}/.." && pwd)}
[[ -f "$REPO_ROOT/.zshrc" ]] || { print -u2 "no .zshrc under $REPO_ROOT"; exit 2 }

TESTHOME=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-zsh-ci.XXXXXX")
trap 'rm -rf -- "$TESTHOME"' EXIT
mkdir -p -- "$TESTHOME/git"
ln -s -- "$REPO_ROOT" "$TESTHOME/git/dotfiles"
ln -s -- "$TESTHOME/git/dotfiles/.zshrc" "$TESTHOME/.zshrc"

# --- 1. interactive source must be error-free --------------------------------
print '==> sourcing .zshrc in an interactive shell (throwaway HOME)'
startup_log="$TESTHOME/startup.log"
set +e
HOME="$TESTHOME" zsh -i -c 'exit 0' >"$startup_log" 2>&1
rc=$?
set -e
if (( rc != 0 )); then
  print -u2 "zsh -i exited $rc"
  cat -v "$startup_log"
  exit 1
fi
# ANSI-colored prompt output is expected; scan for real zsh error signatures.
if grep -aEi 'command not found|parse error|bad pattern|no such file or directory|permission denied|not a valid|unmatched|failed to source|file not found' "$startup_log"; then
  print -u2 '^ startup errors found (full log above)'
  exit 1
fi
print '    .zshrc sourced cleanly'

# --- 2. every repo-defined function must resolve ------------------------------
# Files only sourced on macOS (the macos.zsh chain) are skipped on Linux.
# zsh/aliases/claude-copilot.zsh is not sourced by anything (superseded by
# zsh/functions/claude/providers/copilot.zsh) — excluded until wired up or removed.
darwin_only=(
  zsh/macos.zsh
  zsh/macos-notvscode.zsh
  zsh/functions/randomize-mac.zsh
  zsh/functions/aa-inflight-wifi.zsh
)
never_sourced=(zsh/aliases/claude-copilot.zsh)
[[ $(uname) == Darwin ]] && darwin_only=()

files=("$REPO_ROOT/.zshrc")
for f in $REPO_ROOT/zsh/**/*.zsh(N); do
  rel=${f#"$REPO_ROOT"/}
  # membership via padded substring match — ${...(M)...:#pat} is unreliable
  # inside double quotes, and ${#arr[(Ie)x]} is 1 even on no match
  [[ " ${(j: :)darwin_only} " == *" $rel "* ]] && continue
  [[ " ${(j: :)never_sourced} " == *" $rel "* ]] && continue
  files+=("$f")
done

# Extract function names: `name() {` or `function name {` at column 0 only —
# indented definitions are helpers nested inside other functions (defined
# only when the outer function runs) and stay covered by the zsh -n syntax
# check in CI instead. Heredoc bodies (cloud-init scripts, generated
# completion files) are skipped so their contents aren't mistaken for zsh.
expected=(${(f)"$(awk '
  BEGIN { hd = "" }
  hd != "" { if ($0 ~ "^[[:space:]]*" hd "[[:space:]]*$") hd = ""; next }
  {
    if (match($0, /<<-?[[:space:]]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?/)) {
      t = substr($0, RSTART, RLENGTH); sub(/^<<-?/, "", t)
      gsub(/^[[:space:]]+/, "", t)
      gsub(/^['"'"'"]/, "", t); gsub(/['"'"'"]$/, "", t); hd = t
    }
    print
  }' "${files[@]}" \
  | grep -E '^(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_.-]*\(\)[[:space:]]*\{' \
  | grep -v '^#' \
  | sed -E 's/^(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_.-]*)\(\).*/\2/' \
  | sort -u)"})
print "==> checking ${#expected} unique function definitions from ${#files} files"

expected_file="$TESTHOME/expected-functions.txt"
print -r -- ${(F)expected} >"$expected_file"

set +e
HOME="$TESTHOME" EXPECTED_FUNCTIONS="$expected_file" STDERR_CAPTURE="$TESTHOME/stderr2.log" \
  zsh -i -c 'source ~/git/dotfiles/tests/verify-zshrc-inner.zsh' \
  >"$TESTHOME/check.log" 2>&1
rc=$?
set -e
cat "$TESTHOME/check.log"
cat "$TESTHOME/stderr2.log" 2>/dev/null || true
# Gate on the check shell's stderr (reopened after pure's zpty fd-2 relay):
# errors from the lazy-loader sources and synchronous re-sources land here.
if grep -aEi 'command not found|parse error|bad pattern|no such file or directory|permission denied|not a valid|unmatched|failed to source|file not found' "$TESTHOME/stderr2.log" 2>/dev/null; then
  print -u2 '^ errors while loading function files (see above)'
  exit 1
fi
(( rc == 0 )) || exit $rc
print '==> OK: .zshrc sources cleanly and all functions resolve'
