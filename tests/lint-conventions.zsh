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

# Underscore definitions that predate the kebab-case rule, keyed as
# '<repo-relative-file>:<name>' so the exemption is tied to the file that
# originally carried it. A NEW underscore definition fails even when it
# reuses one of these names, and moving/renaming a file drops its exemption.
# DO NOT add entries — new public functions/aliases must be kebab-case; only
# _underscore_prefix stays private.
GRANDFATHERED=(
  tests/claude-enmaas-proxy.zsh:run_suite
  tests/codex-enmaas.zsh:stop_proxy
  tests/fleet-sync.zsh:head_of
  tests/fleet-sync.zsh:up_head
  tests/hosted-only-go-proxy.zsh:ensure_go
  tests/hosted-only-go-proxy.zsh:fp_with
  tests/hosted-only-go-proxy.zsh:stop_go
  tests/llm-proxy-sync.zsh:chk_fresh
  tests/llm-proxy-sync.zsh:chk_stale
  tests/llm-proxy-sync.zsh:status_json
  tests/llm-proxy-sync.zsh:status_sync_agree
  tests/llm-usage.zsh:dump_of
  tests/openshift-destroy-installer.zsh:reset_bins
  zsh/aliases/docker.zsh:db_amd64
  zsh/aliases/docker.zsh:db_amd64r
  zsh/aliases/docker.zsh:db_amd64rp
  zsh/aliases/docker.zsh:db_amd64t
  zsh/aliases/docker.zsh:db_multi
  zsh/aliases/docker.zsh:db_multip
  zsh/aliases/docker.zsh:db_multir
  zsh/aliases/docker.zsh:db_multit
  zsh/aliases/docker.zsh:db_single
  zsh/aliases/docker.zsh:dbubi_multi
  zsh/aliases/docker.zsh:dbubi_multip
  zsh/aliases/docker.zsh:ghcr_notag
  zsh/aliases/docker.zsh:ghcr_tag
  zsh/aliases/docker.zsh:ghcr_tag-web
  zsh/aliases/docker.zsh:pbubi_manifest
  zsh/aliases/docker.zsh:single_arch
  zsh/aliases/git.zsh:gcu_main
  zsh/aliases/git.zsh:gcu_main_nb
  zsh/aliases/git.zsh:gcu_master
  zsh/aliases/git.zsh:gcu_master_nb
  zsh/aliases/git.zsh:gcu_nb
  zsh/aliases/git.zsh:gcu_oadp
  zsh/aliases/git.zsh:gcu_oadp_nb
  zsh/aliases/velero.zsh:ocregistry_notag
  zsh/aliases/velero.zsh:ocregistry_tag
  zsh/command-cache.zsh:cached_exec
  zsh/command-cache.zsh:cache_file_expired
  zsh/command-cache.zsh:command_cache_clear
  zsh/command-cache.zsh:command_cache_expired
  zsh/command-cache.zsh:command_cache_status
  zsh/command-cache.zsh:completion_cache_expired
  zsh/command-cache.zsh:has_command
  zsh/completion-pins.zsh:bump_completion_pins
  zsh/completions.zsh:zsh_completion_cache_clear
  zsh/completions.zsh:zsh_completion_cache_status
  zsh/functions/aa-inflight-wifi.zsh:check_internet
  zsh/functions/aa-inflight-wifi.zsh:reconnect_wifi
  zsh/functions/claude/providers/enmaas-proxy.zsh:go_impl
  zsh/functions/migrate-laptop.zsh:command_exists
  zsh/functions/migrate-laptop.zsh:install_packages_manually
  zsh/functions/openshift/variables.zsh:get_latest_amd64_release_image
  zsh/functions/openshift/variables.zsh:get_latest_arm64_release_image
  zsh/functions/openshift/variables.zsh:get_latest_ec_version
  zsh/functions/openshift/variables.zsh:get_latest_multi_release_image
  zsh/functions/openshift/variables.zsh:get_latest_nightly_release_image
  zsh/functions/openshift/variables.zsh:get_latest_stable_amd64_release_image
  zsh/functions/openshift/variables.zsh:get_latest_stable_arm64_release_image
  zsh/functions/openshift/variables.zsh:get_latest_stable_multi_release_image
  zsh/functions/openshift/variables.zsh:get_latest_stable_version
)
grandfathered() {
  # $1 = repo-relative file path, $2 = name
  local e="${1}:${2}"
  local n
  for n in $GRANDFATHERED; do
    [[ "$n" == "$e" ]] && return 0
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
typeset -A var_derived
while IFS= read -r file; do
  [[ -f "$file" ]] || continue
  var_derived=()
  prev_line=""
  # backslash continuations are JOINED before matching, so a wrap between
  # 'adm' and 'release'/'extract' cannot evade rule 4 (lineno = first line)
  local -a file_lines
  file_lines=("${(f)$(<"$file")}")
  local li=0
  while (( li < ${#file_lines} )); do
    li=$(( li + 1 ))
    lineno=$li
    local line="${file_lines[li]}"
    while [[ "$line" =~ '\\$' ]] && (( li < ${#file_lines} )); do
      li=$(( li + 1 ))
      line="${line%\\}${file_lines[li]}"
    done
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
      if [[ "$name" == *_* && "$name" != _* ]] && ! grandfathered "${file#$repo_root/}" "$name"; then
        fail "$file:$lineno: function '$name' uses underscore in a public name — use kebab-case (rename to '${name//_/-}', keep a back-compat alias; _prefix only for private helpers)"
      fi
    fi
    if [[ "$line" =~ '^[[:space:]]*function[[:space:]]+([A-Za-z][A-Za-z0-9_-]*)[[:space:]]*\{' ]]; then
      local fname="${match[1]}"
      if [[ "$fname" == *_* && "$fname" != _* ]] && ! grandfathered "${file#$repo_root/}" "$fname"; then
        fail "$file:$lineno: function '$fname' uses underscore in a public name — use kebab-case (rename to '${fname//_/-}', keep a back-compat alias; _prefix only for private helpers)"
      fi
    fi
    # alias name=...
    if [[ "$line" =~ '^[[:space:]]*alias[[:space:]]+([A-Za-z0-9_-]+)=' ]]; then
      local aname="${match[1]}"
      if [[ "$aname" == *_* ]] && ! grandfathered "${file#$repo_root/}" "$aname"; then
        fail "$file:$lineno: alias '$aname' uses underscore — use kebab-case (rename to '${aname//_/-}', keep a back-compat alias)"
      fi
    fi

    # 3. znap-prefixed function definitions
    if [[ "$line" =~ '^[[:space:]]*znap([[:space:]]+function)?[[:space:]]+[A-Za-z0-9_-]+[[:space:]]*\(\)' ]]; then
      fail "$file:$lineno: 'znap name() {...}' redefines znap itself — define functions plainly: name() { ... }"
    fi

    # 4. system-oc release extraction. `oc adm release` is matched only at a
    #    command boundary (line start, after ; & | ! ( ), incl. after
    #    command/sudo/env wrappers and leading if/while/elif/then/! keywords),
    #    so chained `... && sudo oc adm ...` is caught while quoted text like
    #    'Example: (oc adm release extract ...)' inside an echo message is not
    #    (quoted spans are stripped before matching). Variable-mediated
    #    extracts are approved only while THAT variable's latest assignment
    #    derives it from get-release-oc — a later reassignment to the system
    #    oc invalidates the approval.
    #
    # track variable assignments first: latest assignment wins. Assignments are
    # matched anywhere in the line (e.g. 'local oc_bin; oc_bin=$(...)'), and a
    # var derived via get-release-oc is approved only until reassigned.
    local arest="$line" am=""
    while [[ "$arest" =~ '(^|[[:space:];&])(local[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=[^=[:space:]]' ]]; do
      am="$MATCH"
      local av="${match[3]}"
      if [[ "$line" =~ "${av}=\\\$\(get-release-oc" ]]; then
        var_derived[$av]=1
      else
        var_derived[$av]=0
      fi
      arest="${arest#*"$am"}"
    done

    if [[ "$line" == *'release'* ]]; then
      local cmd="$line"
      cmd="${cmd#"${cmd%%[![:space:]]*}"}"
      # strip quoted spans — text inside quotes is not a command position —
      # but KEEP quoted variable references ("$OC_BIN" / "${OC_BIN}"), which
      # are real command positions
      local qout="" qrest="$cmd" qm=""
      while [[ "$qrest" =~ \'[^\']*\' ]]; do
        qm="$MATCH"
        qout+="${qrest%%"$qm"*}"
        qrest="${qrest#*"$qm"}"
      done
      qout+="$qrest"
      qrest="$qout"
      qout=""
      while [[ "$qrest" =~ \"[^\"]*\" ]]; do
        qm="$MATCH"
        qout+="${qrest%%"$qm"*}"
        # keep only a LEADING variable reference inside the quotes — the rest of
        # the span is still a quoted argument, not a command position
        # ('"$label (oc adm release extract ...)"' keeps '"$label"' only)
        if [[ "$qm" =~ '^"(\$[A-Za-z_][A-Za-z0-9_]*|\$\{[A-Za-z_][A-Za-z0-9_]*\})' ]]; then
          qout+="$MATCH"
        fi
        qrest="${qrest#*"$qm"}"
      done
      qout+="$qrest"
      cmd="$qout"
      while [[ "$cmd" =~ '^(if|while|elif|then|!|command|sudo|env)[[:space:]]+' ]]; do
        cmd="${cmd#"$MATCH"}"
      done
      local marked=0
      [[ "$line" == *'lint-allow: release-extract-bootstrap'* || "$prev_line" == *'lint-allow: release-extract-bootstrap'* ]] && marked=1
      # bare system oc, at any command boundary, incl. after wrappers
      if [[ "$cmd" =~ '(^|[;&|!()])[[:space:]]*((command|sudo|env|then|else|do)[[:space:]]+)*oc[[:space:]]+adm[[:space:]]+release[[:space:]]+extract' ]]; then
        if (( ! marked )); then
          fail "$file:$lineno: bare 'oc adm release extract' — use a version-matched oc from get-release-oc (OCPBUGS-77845). Bootstrap-only use: add a '# lint-allow: release-extract-bootstrap' comment on the line above"
        fi
      fi
      # variable-mediated: group 5 is the variable name
      if [[ "$cmd" =~ '(^|[;&|!()])[[:space:]]*((command|sudo|env|then|else|do)[[:space:]]+)*("?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?)[[:space:]]+adm[[:space:]]+release[[:space:]]+extract' ]]; then
        local vname="${match[5]}" vspell="${match[4]}"
        if (( ! marked )) && [[ "${var_derived[$vname]:-0}" != 1 ]]; then
          fail "$file:$lineno: 'adm release extract' runs through '$vspell', which is not currently derived from get-release-oc — a later reassignment to the system oc would stay green (OCPBUGS-77845). Derive it via get-release-oc (or add a '# lint-allow: release-extract-bootstrap' marker)"
        fi
      fi
    fi

    prev_line="$line"
  done
done < <(print -r -- "$lint_files")

if (( failures > 0 )); then
  print -u2 -- "\n$failures convention violation(s). See CLAUDE.md/AGENTS.md 'Conventions'."
  exit 1
fi
print "✅ lint-conventions: no convention violations"
