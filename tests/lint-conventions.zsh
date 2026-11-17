#!/usr/bin/env zsh
# lint-conventions.zsh — enforce the repo conventions that CLAUDE.md/AGENTS.md
# only state as prose, so an AI (or human) can't ship against them:
#   1. ZSH, not Bash: no $BASH_REMATCH (use $match)
#   2. kebab-case public function/alias names; only _underscore_prefix is private
#   3. never `znap name() { ... }` definitions (silently redefine znap itself)
#   4. `oc adm release extract` must run via a version-matched oc (get-release-oc),
#      not the system `oc` (OCPBUGS-77845)
# Exits nonzero on any violation. Offline, no deps beyond zsh + grep.

set -euo pipefail

repo_root="${0:A:h:h}"
failures=0

# Names that predate the kebab-case rule (renaming them is separate,
# backwards-compat-breaking work). DO NOT add new names here — new public
# functions/aliases must be kebab-case; only _underscore_prefix stays private.
GRANDFATHERED=(
  # functions
  run_suite stop_proxy head_of up_head ensure_go stop_go fp_with status_json
  status_sync_agree chk_stale chk_fresh dump_of reset_bins gcu_nb cached_exec
  command_cache_status command_cache_clear has_command cache_file_expired
  command_cache_expired completion_cache_expired bump_completion_pins
  zsh_completion_cache_status zsh_completion_cache_clear check_internet
  reconnect_wifi go_impl command_exists install_packages_manually
  get_latest_stable_multi_release_image get_latest_stable_version
  get_latest_arm64_release_image get_latest_nightly_release_image
  get_latest_ec_version get_latest_amd64_release_image
  get_latest_multi_release_image get_latest_stable_amd64_release_image
  get_latest_stable_arm64_release_image
  # aliases
  single_arch db_single db_multi db_multit db_multir db_multip ghcr_tag
  ghcr_notag ghcr_tag-web dbubi_multi dbubi_multip pbubi_manifest db_amd64
  db_amd64t db_amd64r db_amd64rp gcu_master gcu_master_nb gcu_main gcu_main_nb
  gcu_oadp gcu_oadp_nb ocregistry_tag ocregistry_notag
)
grandfathered() {
  local n
  for n in $GRANDFATHERED; do
    [[ "$n" == "$1" ]] && return 0
  done
  return 1
}

fail() {
  print -r -- "❌ $1"
  (( failures++ )) || true
}

# Repo zsh sources. Excluded: vendored completions (zsh/completions/, *.txt),
# docs/.claude (prose), .git, this test's own fixtures (exercised by
# tests/lint-conventions-selftest.zsh instead).
# Enumeration failure must FAIL the lint, not silently scan nothing.
# Optional args: explicit file list to scan (used by the selftest) instead of
# enumerating the repo.
_zsh_files() {
  if (( $# > 0 )); then
    local f
    for f in "$@"; do print -r -- "$f"; done
    return 0
  fi
  local out
  if ! out=$(git -C "$repo_root" ls-files '*.zsh' '*.zshrc'); then
    print -u2 "❌ git ls-files failed — cannot enumerate zsh files to lint"
    return 1
  fi
  print -r -- "$out" \
    | { grep -v '^zsh/completions/' || true; } \
    | { grep -v '^tests/lint-conventions-fixtures/' || true; } \
    | while IFS= read -r f; do print -r -- "$repo_root/$f"; done
}

lint_files=$(_zsh_files "$@") || { print -u2 "❌ file enumeration failed — aborting"; exit 1 }
typeset -A var_extract_files
typeset -A has_get_release_oc
while IFS= read -r file; do
  [[ -f "$file" ]] || continue
  lineno=0
  prev_line=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$(( lineno + 1 ))
    # skip full-line comments
    [[ "$line" =~ '^[[:space:]]*#' ]] && { prev_line="$line"; continue }

    # 1. bash-isms — flag $BASH_REMATCH / ${BASH_REMATCH usage (the convention);
    #    a bare mention (like this lint's own message text) is not a violation
    if [[ "$line" == *"\$BASH"_REMATCH* || "$line" == *'${BASH'"_REMATCH"* ]]; then
      fail "$file:$lineno: \$BASH"_REMATCH" is bash — use \$match (ZSH regex captures)"
    fi

    # 2. kebab-case for public definitions and aliases.
    #    name() { ... } and function name { ... } — underscore in a non-_prefixed name is private-by-mistake
    if [[ "$line" =~ '^[[:space:]]*(function[[:space:]]+)?([A-Za-z][A-Za-z0-9_-]*)[[:space:]]*\(\)' ]]; then
      local name="${match[2]}"
      if [[ "$name" == *_* && "$name" != _* ]] && ! grandfathered "$name"; then
        fail "$file:$lineno: function '$name' uses underscore in a public name — use kebab-case (rename to '${name//_/-}', keep a back-compat alias; _prefix only for private helpers)"
      fi
    fi
    if [[ "$line" =~ '^[[:space:]]*function[[:space:]]+([A-Za-z][A-Za-z0-9_-]*)[[:space:]]*\{' ]]; then
      local fname="${match[1]}"
      if [[ "$fname" == *_* && "$fname" != _* ]] && ! grandfathered "$fname"; then
        fail "$file:$lineno: function '$fname' uses underscore in a public name — use kebab-case (rename to '${fname//_/-}', keep a back-compat alias; _prefix only for private helpers)"
      fi
    fi
    # alias name=...
    if [[ "$line" =~ '^[[:space:]]*alias[[:space:]]+([A-Za-z0-9_-]+)=' ]]; then
      local aname="${match[1]}"
      if [[ "$aname" == *_* ]] && ! grandfathered "$aname"; then
        fail "$file:$lineno: alias '$aname' uses underscore — use kebab-case (rename to '${aname//_/-}', keep a back-compat alias)"
      fi
    fi

    # 3. znap-prefixed function definitions
    if [[ "$line" =~ '^[[:space:]]*znap([[:space:]]+function)?[[:space:]]+[A-Za-z0-9_-]+[[:space:]]*\(\)' ]]; then
      fail "$file:$lineno: 'znap name() {...}' redefines znap itself — define functions plainly: name() { ... }"
    fi

    # 4. system-oc release extraction. Match `oc adm release` only at a command
    #    boundary (line start, after ; & | ! ( ) — so chained `... && oc adm ...`
    #    is caught), not mid-string text like `extract: oc adm release extract`
    #    inside an echo message. Leading condition keywords (if/while/elif/then)
    #    and negations are stripped before the boundary match so `if oc adm ...`
    #    is caught too.
    if [[ "$line" == *'adm release extract'* ]]; then
      local cmd="$line"
      cmd="${cmd#"${cmd%%[![:space:]]*}"}"
      while [[ "$cmd" =~ '^(if|while|elif|then|!|command|sudo|env)[[:space:]]+' ]]; do
        cmd="${cmd#"$MATCH"}"
      done
      # variable-mediated extract ($OC_BIN / "$oc_bin" adm release extract, at a command
      # boundary incl. mid-line after &&): allowed only with a lint-allow marker, or when
      # the file derives the variable from get-release-oc somewhere (checked after the loop)
      if [[ "$cmd" =~ '(^|[;&|!()])[[:space:]]*"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?[[:space:]]+adm[[:space:]]+release' ]]; then
        if [[ "$line" != *'lint-allow: release-extract-bootstrap'* && "$prev_line" != *'lint-allow: release-extract-bootstrap'* ]]; then
          var_extract_files[$file]=$lineno
        fi
      fi
      if [[ "$cmd" =~ '(^|[;&|!()])[[:space:]]*oc[[:space:]]+adm[[:space:]]+release' ]]; then
        # allowed: bootstrap extraction marked with lint-allow on this or the previous line
        if [[ "$line" != *'lint-allow: release-extract-bootstrap'* && "$prev_line" != *'lint-allow: release-extract-bootstrap'* ]]; then
          fail "$file:$lineno: bare 'oc adm release extract' — use a version-matched oc from get-release-oc (OCPBUGS-77845). Bootstrap-only use: add a '# lint-allow: release-extract-bootstrap' comment on the line above"
        fi
      fi
    fi

    # only a real derivation counts — '$(get-release-oc ...)' command substitution,
    # not the helper's name appearing in echo/message text
    if [[ "$line" == *'$(get-release-oc '* || "$line" == *'$(get-release-oc)'* ]]; then
      has_get_release_oc[$file]=1
    fi

    prev_line="$line"
  done < "$file"
done < <(print -r -- "$lint_files")

# variable-mediated extracts must be derived from get-release-oc somewhere in the file
for f in "${(@k)var_extract_files}"; do
  if [[ -z "${has_get_release_oc[$f]:-}" ]]; then
    fail "$f:${var_extract_files[$f]}: 'adm release extract' runs through a variable that this file never derives from get-release-oc — a future edit swapping the variable to the system oc would stay green (OCPBUGS-77845). Derive it via get-release-oc (or add a '# lint-allow: release-extract-bootstrap' marker)"
  fi
done

if (( failures > 0 )); then
  print -u2 -- "\n$failures convention violation(s). See CLAUDE.md/AGENTS.md 'Conventions'."
  exit 1
fi
print "✅ lint-conventions: no convention violations"
