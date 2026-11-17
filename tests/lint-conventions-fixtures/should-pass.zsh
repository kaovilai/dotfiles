# Fixture: clean under every rule. Only scanned by
# tests/lint-conventions-selftest.zsh — excluded from the main lint run.
ok-name() { echo hi; }
function ok-brace { echo hi; }
function ok-parens() { echo hi; }
alias fine-alias='echo hi'
_private_helper() { echo hi; }
if [[ $x =~ re ]]; then y=$match[1]; fi
# lint-allow: release-extract-bootstrap
oc adm release extract --command=oc img
local oc_bin; oc_bin=$(get-release-oc "$release_image")
"$oc_bin" adm release extract --command=openshift-install img
