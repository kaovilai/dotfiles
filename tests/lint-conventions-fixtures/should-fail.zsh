# Fixture: every rule must flag something in this file. Only scanned by
# tests/lint-conventions-selftest.zsh — excluded from the main lint run.
foo_bar() { echo hi; }
function bad_brace { echo hi; }
function bad_parens() { echo hi; }
alias my_bad='echo hi'
if [[ $x =~ re ]]; then y=$BASH_REMATCH; fi
znap baz() { echo hi; }
oc adm release extract --command=oc img
oc adm  release extract --command=oc img
oc adm release  extract --command=oc img
true && sudo oc adm release extract --command=oc img
echo "extracting" && $OC_BIN adm release extract --command=oc img
echo "quoted var" && "$OC_BIN" adm release extract --command=oc img
echo "braced" && ${OC_BIN} adm release extract --command=oc img
REASSIGN=$(get-release-oc "$img")
REASSIGN=oc
$REASSIGN adm release extract --command=oc img
function ok-name() { echo hi; }
function ok-brace { echo hi; }
ok-name() { echo hi; }
_private_helper() { echo hi; }
alias fine-alias='echo hi'
