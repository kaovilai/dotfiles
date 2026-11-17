#!/usr/bin/env zsh
# lint-conventions-selftest.zsh — prove every rule in lint-conventions.zsh
# actually fires, using the committed fixture. The fixture lives under
# tests/lint-conventions-fixtures/ which the main lint run excludes, so this
# selftest is the only place it is scanned.
# Exits nonzero if the lint does not flag every expected violation.

set -uo pipefail

here="${0:A:h}"
fixture="$here/lint-conventions-fixtures/should-fail.zsh"

expected=(
  'function '\''foo_bar'\'' uses underscore'
  'function '\''bad_brace'\'' uses underscore'
  'function '\''bad_parens'\'' uses underscore'
  'alias '\''my_bad'\'' uses underscore'
  'is bash — use $match'
  'znap name() {...}'
  'bare '\''oc adm release extract'\'''
  "runs through '\$OC_BIN'"
  "runs through '\$REASSIGN'"
)

output=$(zsh "$here/lint-conventions.zsh" "$fixture" 2>&1)
rc=$?

if [[ $rc -eq 0 ]]; then
  print -u2 "❌ selftest: lint exited 0 on the bad fixture — rules are not firing"
  exit 1
fi

failed=0
for e in $expected; do
  if ! print -r -- "$output" | grep -qF "$e"; then
    print -u2 "❌ selftest: expected a violation matching '$e' — not reported"
    (( failed++ )) || true
  fi
done

# and a clean file must pass
if ! zsh "$here/lint-conventions.zsh" "$here/lint-conventions-fixtures/should-pass.zsh" &>/dev/null; then
  print -u2 "❌ selftest: lint flagged the clean fixture — false positive"
  exit 1
fi

if (( failed > 0 )); then
  print -u2 "$output"
  exit 1
fi
print "✅ lint-conventions-selftest: all rules fire, clean file passes"
