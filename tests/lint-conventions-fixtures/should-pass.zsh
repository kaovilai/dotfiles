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
echo "braced" && "${oc_bin}" adm release extract --command=openshift-install img
# quoted text mentioning the command is not a command position
echo 'Example: (oc adm release extract --command=oc img)'
# ...not even when a real command is chained after the quoted text
print -r -- 'Example: (oc adm release extract --command=oc img)' && true
# a quoted span starting with a variable is still just an argument
echo "$label (oc adm release extract --command=oc img)"
