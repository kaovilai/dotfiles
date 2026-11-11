#!/bin/zsh
# completion-pins.zsh - pinned remote completion downloads (supply-chain hardening)
#
# Remote completion files (_docker, _podman, _claude, ...) are zsh shell code
# autoloaded from FPATH. They are therefore fetched at a PINNED COMMIT and
# sha256-verified before install — never from a mutable branch head. When the
# upstream branch moves past the pin, shell startup prints a one-line notice
# (rate-limited to once per CACHE_TTL_COMPLETION per pin). Review the diff and
# bump interactively with `bump-completion-pins [name...]`, then commit the
# updated pin lines in this file.

# Pin entry fields: <name> <repo> <branch> <path-in-repo> <pinned-commit-sha> <sha256-of-file>
typeset -ga _COMPLETION_PINS
_COMPLETION_PINS=(
  "docker docker/docker-ce master components/cli/contrib/completion/zsh/_docker 44a430f4c43e61c95d4e9e9fd6a0573fa113a119 967e185b2d32900077854699b3e19bcf21187d7a100b21f2f17aaa749d6bd498"
  "podman containers/podman main completions/zsh/_podman fc1d4e5f913cbb464ef90ca161d0c7fb07d3e3b8 bb0df2fe593484e2827387774e0da2521b3fd3b509481694f99a65dc46e44a1a"
  "claude wbingli/zsh-claudecode-completion main _claude f26686ff7aa55966f906f6b04b4376a6bd90466a 9354cd7a920da0ccc847814e3f3a4d6436157d4d3ee33774ca413e4d222f1681"
)

# Echo the pin entry line for <name>; return 1 if unknown.
_completion-pin-entry() {
  local entry
  for entry in "${_COMPLETION_PINS[@]}"; do
    if [[ "${entry%% *}" == "$1" ]]; then
      print -r -- "$entry"
      return 0
    fi
  done
  return 1
}

# <file> -> stdout sha256 (empty on failure)
_completion-pin-sha256() {
  ( command shasum -a 256 < "$1" 2>/dev/null || command sha256sum < "$1" 2>/dev/null ) | command awk '{print $1; exit}'
}

# Download completion <name> at its pinned commit, verify sha256, install into
# cache dir + FPATH. Keeps any existing cached copy on failure. Network errors
# are silent (cache stays); sha256 mismatch is loud (possible tamper/force-push).
_completion-pin-install() {
  local name="$1" entry
  entry=$(_completion-pin-entry "$name") || return 1
  local -a f=(${=entry})  # name repo branch path sha sum
  local cache_file="$ZSH_COMPLETION_CACHE_DIR/_${name}"
  local t
  t=$(mktemp "${cache_file}.XXXXXX") || return 1
  if ! command curl -fsLm 20 "https://raw.githubusercontent.com/${f[2]}/${f[5]}/${f[4]}" > "$t" 2>/dev/null || [[ ! -s "$t" ]]; then
    command rm -f "$t" 2>/dev/null
    return 1
  fi
  if [[ $(_completion-pin-sha256 "$t") != "${f[6]}" ]]; then
    command rm -f "$t" 2>/dev/null
    print -u2 -- "completion-pins: ${name}: sha256 mismatch, expected ${f[6]} — not installed, keeping existing cache"
    return 1
  fi
  command mv "$t" "$cache_file" && command cp "$cache_file" "$HOME/.zsh/completions/_${name}"
}

# Print a bump notice when upstream branch head != pin. Rate-limited by state
# file, one check per name per CACHE_TTL_COMPLETION. ~1 HTTP call when due.
_completion-pin-check() {
  local name="$1" entry
  entry=$(_completion-pin-entry "$name") || return 0
  local -a f=(${=entry})
  local state="$ZSH_COMPLETION_CACHE_DIR/.pincheck-${name}"
  completion_cache_expired "$state" || return 0
  command touch "$state"
  local head
  head=$(command curl -fsSLm 10 "https://api.github.com/repos/${f[2]}/commits/${f[3]}" 2>/dev/null | command grep -m1 '"sha"' | command awk -F'"' '{print $4}')
  [[ -n "$head" ]] || return 0
  if [[ "$head" != "${f[5]}" ]]; then
    print -u2 -- "completion-pins: ${name} (${f[2]} ${f[3]}) upstream moved: pinned ${f[5]:0:7}, upstream ${head:0:7}. Run 'bump-completion-pins ${name}' to review and update."
  fi
}

# Startup entry: serve cached copy, reinstall when missing/tampered, refresh +
# staleness-check when TTL expired. <name> [ttl_seconds]
_completion-pin-ensure() {
  local name="$1" ttl="${2:-$CACHE_TTL_COMPLETION}" entry
  entry=$(_completion-pin-entry "$name") || return 0
  local -a f=(${=entry})
  local cache_file="$ZSH_COMPLETION_CACHE_DIR/_${name}"
  if [[ -f "$cache_file" && $(_completion-pin-sha256 "$cache_file") == "${f[6]}" ]]; then
    command cp "$cache_file" "$HOME/.zsh/completions/_${name}" &!
    completion_cache_expired "$cache_file" "$ttl" || return 0
  fi
  # Missing or sha-mismatched cache (old unpinned content, tampering): reinstall from pin.
  _completion-pin-install "$name" &!
  _completion-pin-check "$name"
}

# Interactively review upstream changes and bump pins you approve.
# Usage: bump-completion-pins [name ...]   (no args = all pins)
bump-completion-pins() {
  local name entry pins_file="$HOME/git/dotfiles/zsh/completion-pins.zsh"
  [[ -f "$pins_file" ]] || { print -u2 -- "completion-pins: pin file not found: $pins_file"; return 1 }
  local -a names=("$@")
  (( ${#names} )) || names=("${_COMPLETION_PINS[@]%% *}")
  for name in "${names[@]}"; do
    entry=$(_completion-pin-entry "$name") || { print -u2 -- "completion-pins: unknown pin: ${name}"; continue }
    local -a f=(${=entry})  # name repo branch path sha sum
    local head
    head=$(command curl -fsSLm 10 "https://api.github.com/repos/${f[2]}/commits/${f[3]}" 2>/dev/null | command grep -m1 '"sha"' | command awk -F'"' '{print $4}')
    if [[ -z "$head" ]]; then
      print -u2 -- "${name}: could not fetch upstream head of ${f[2]} ${f[3]}"
      continue
    fi
    if [[ "$head" == "${f[5]}" ]]; then
      print -- "${name}: up to date (${f[5]:0:7})"
      continue
    fi
    local t new_sum
    t=$(mktemp) || continue
    if ! command curl -fsLm 20 "https://raw.githubusercontent.com/${f[2]}/${head}/${f[4]}" > "$t" 2>/dev/null || [[ ! -s "$t" ]]; then
      print -u2 -- "${name}: download at upstream ${head:0:7} failed"
      command rm -f "$t"
      continue
    fi
    new_sum=$(_completion-pin-sha256 "$t")
    print -- "${name}: ${f[2]} ${f[3]} ${f[5]:0:7} -> ${head:0:7}"
    print -- "  old sha256 ${f[6]}"
    print -- "  new sha256 ${new_sum}"
    local old_file="$ZSH_COMPLETION_CACHE_DIR/_${name}"
    if [[ -f "$old_file" ]] && command -v git >/dev/null 2>&1; then
      command git diff --no-index --stat "$old_file" "$t" 2>/dev/null | command tail -1
      print -- "  full diff: git diff --no-index '$old_file' '$t'"
    fi
    local reply
    if ! read -q "reply?Bump ${name} pin to ${head:0:7}? [y/N] "; then
      print
      command rm -f "$t"
      print -- "${name}: skipped"
      continue
    fi
    print
    local new_entry="${name} ${f[2]} ${f[3]} ${f[4]} ${head} ${new_sum}"
    local pins_content
    pins_content=$(<"$pins_file")
    pins_content=${pins_content//\"$entry\"/\"$new_entry\"}
    if [[ "$pins_content" == *"$new_entry"* ]]; then
      print -r -- "$pins_content" > "$pins_file"
      command mv "$t" "$ZSH_COMPLETION_CACHE_DIR/_${name}" && command cp "$ZSH_COMPLETION_CACHE_DIR/_${name}" "$HOME/.zsh/completions/_${name}"
      print -- "${name}: pin bumped to ${head:0:7} and installed. Commit ~/git/dotfiles to persist."
    else
      command rm -f "$t"
      print -u2 -- "${name}: failed to rewrite pin line in $pins_file — update it manually"
    fi
  done
}
bump_completion_pins() { bump-completion-pins "$@"; }
