#!/usr/bin/env zsh
# lint-conventions-selftest.zsh — prove every rule in lint-conventions.zsh
# actually fires, using the committed fixtures. They live under
# tests/lint-conventions-fixtures/ which the main lint run excludes, so this
# selftest is the only place they are scanned.
# Exits nonzero if the lint does not flag every expected violation the exact
# expected number of times, or flags the clean fixture.

set -uo pipefail

here="${0:A:h}"
bad_fixture="$here/lint-conventions-fixtures/should-fail.zsh"
good_fixture="$here/lint-conventions-fixtures/should-pass.zsh"

# message-substring : expected occurrence count
expected=(
  "function 'foo_bar' uses underscore:1"
  "function 'bad_brace' uses underscore:1"
  "function 'bad_parens' uses underscore:1"
  "alias 'my_bad' uses underscore:1"
  'is bash — use $match:1'
  'znap name() {...}:1'
  "bare 'oc adm release extract':5"
  "runs through '\$OC_BIN':1"
  "runs through '\"\$OC_BIN':1"
  "runs through '\${OC_BIN}':1"
  "runs through '\$REASSIGN':1"
)

output=$(zsh "$here/lint-conventions.zsh" "$bad_fixture" 2>&1)
rc=$?

if [[ $rc -eq 0 ]]; then
  print -u2 "❌ selftest: lint exited 0 on the bad fixture — rules are not firing"
  exit 1
fi

failed=0
for e in $expected; do
  msg="${e%:*}"
  want="${e##*:}"
  got=$(print -r -- "$output" | grep -cF "$msg")
  if [[ "$got" != "$want" ]]; then
    print -u2 "❌ selftest: expected $want occurrence(s) of '$msg', got $got"
    (( failed++ )) || true
  fi
done

# and the clean fixture must pass
if ! zsh "$here/lint-conventions.zsh" "$good_fixture" &>/dev/null; then
  print -u2 "❌ selftest: lint flagged the clean fixture — false positive"
  exit 1
fi

if (( failed > 0 )); then
  print -u2 "$output"
  exit 1
fi
print "✅ lint-conventions-selftest: all rules fire, clean file passes"
