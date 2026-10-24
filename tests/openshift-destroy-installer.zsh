#!/bin/zsh
# Offline contracts for delete-ocp-{aws,gcp-wif,azure-sts} installer
# resolution + "keep the dir when destroy fails". Fake openshift-install
# binaries on a temp PATH; temp manifests dir; no cloud calls.
emulate -LR zsh
umask 077
local repo="${0:A:h:h}" tmp
tmp=$(mktemp -d "${TMPDIR:-/tmp}/openshift-destroy-installer-tests.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/m"
path=("$tmp/bin" /usr/bin /bin)
export OCP_MANIFESTS_DIR="$tmp/m" CALLS="$tmp/calls"
unset OPENSHIFT_INSTALL

local pass=0 fail=0
eq() { if [[ "$2" == "$3" ]]; then (( ++pass )); print "  ok   $1"; else (( ++fail )); print "  FAIL $1: got [$2] want [$3]"; fi }

# fake <version> [exit]: records "<name> <args>" and exits <exit> for destroy cluster
fake() {
    print -r -- "#!/bin/sh
[ \"\$1\" = version ] && exit 0
echo \"\${0##*/} \$*\" >> \"$CALLS\"
[ \"\$2\" = cluster ] && exit ${2:-0}
exit 0" > "$tmp/bin/openshift-install-$1"
    chmod +x "$tmp/bin/openshift-install-$1"
}
# mkcluster <dir> <log line 1> [metadata]
mkcluster() {
    rm -rf "$tmp/m/$1"; mkdir -p "$tmp/m/$1"
    [[ -n "$2" ]] && print -r -- "$2" > "$tmp/m/$1/.openshift_install.log"
    [[ "$3" != nometa ]] && print '{"infraID":"x"}' > "$tmp/m/$1/metadata.json"
    : > "$CALLS"
}
reset_bins() { rm -f "$tmp/bin"/openshift-install-*(N); }
get-ocp-latest-ec-version() { print 4.23.0-ec.1 }
ccoctl() { return 0 }

source "$repo/zsh/functions/openshift/util/destroy-installer.zsh"
source "$repo/zsh/functions/openshift/aws/delete-ocp-aws.zsh"
source "$repo/zsh/functions/openshift/gcp/delete-ocp-gcp-wif.zsh"
source "$repo/zsh/functions/openshift/azure/delete-ocp-azure-sts.zsh"
V422='time="2026-10-23T12:41:16-04:00" level=debug msg="OpenShift Installer 4.22.19"'

print "== aws: 2026-10-23 incident (no Running: line, exact binary on PATH)"
reset_bins; fake 4.22.19; fake 4.22.0-ec.5; mkcluster 261023-aws-amd64 "$V422"
delete-ocp-aws tkaovila-261023-amd64 amd64 >/dev/null 2>&1; eq "returns 0" $? 0
eq "used exact 4.22.19" "$(head -1 $CALLS)" "openshift-install-4.22.19 destroy cluster --dir $tmp/m/261023-aws-amd64"
eq "dir removed" "$([[ -d $tmp/m/261023-aws-amd64 ]] && print kept || print gone)" gone

print "== aws: exact missing -> newest same-minor >= ver, never older/other minor"
reset_bins; fake 4.22.0-ec.5; fake 4.22.20; fake 4.22.25; fake 4.23.0-ec.1; mkcluster 261023-aws-amd64 "$V422"
out=$(delete-ocp-aws tkaovila-261023-amd64 amd64 2>&1); eq "returns 0" $? 0
eq "used 4.22.25" "${$(head -1 $CALLS)%% *}" "openshift-install-4.22.25"
eq "warned" "$([[ $out == *'not found; destroying with same-minor'* ]] && print y)" y

print "== aws: only older/other-minor binaries -> refuse, keep dir, marker"
reset_bins; fake 4.22.0-ec.5; fake 4.23.0-ec.1; mkcluster 261023-aws-amd64 "$V422"
out=$(delete-ocp-aws tkaovila-261023-amd64 amd64 2>&1); eq "returns 1" $? 1
eq "marker in output" "$([[ $out == *DESTROY_INSTALLER_MISSING* ]] && print y)" y
eq "no destroy ran" "$(wc -l < $CALLS | tr -d ' ')" 0
eq "dir kept" "$([[ -f $tmp/m/261023-aws-amd64/metadata.json ]] && print kept)" kept

print "== aws: OPENSHIFT_INSTALL override wins (manual fix path)"
mkcluster 261023-aws-amd64 "$V422"
OPENSHIFT_INSTALL="$tmp/bin/openshift-install-4.22.0-ec.5" delete-ocp-aws tkaovila-261023-amd64 amd64 >/dev/null 2>&1; eq "returns 0" $? 0
eq "used override" "${$(head -1 $CALLS)%% *}" "openshift-install-4.22.0-ec.5"

print "== aws: Running: line still preferred"
reset_bins; fake 4.22.19; fake 5.0.0-0.nightly-x
mkcluster 261023-aws-amd64 "level=debug msg=\"Running: $tmp/bin/openshift-install-5.0.0-0.nightly-x create cluster\""$'\n'"$V422"
delete-ocp-aws tkaovila-261023-amd64 amd64 >/dev/null 2>&1; eq "returns 0" $? 0
eq "used Running: path" "${$(head -1 $CALLS)%% *}" "openshift-install-5.0.0-0.nightly-x"

print "== aws: destroy cluster fails -> keep dir, return 1"
reset_bins; fake 4.22.19 1; mkcluster 261023-aws-amd64 "$V422"
delete-ocp-aws tkaovila-261023-amd64 amd64 >/dev/null 2>&1; eq "returns 1" $? 1
eq "dir kept" "$([[ -f $tmp/m/261023-aws-amd64/metadata.json ]] && print kept)" kept

print "== aws: no metadata.json (early failure) -> no binary needed, dir removed"
reset_bins; mkcluster 261023-aws-amd64 "" nometa
delete-ocp-aws tkaovila-261023-amd64 amd64 >/dev/null 2>&1; eq "returns 0" $? 0
eq "dir removed" "$([[ -d $tmp/m/261023-aws-amd64 ]] && print kept || print gone)" gone

print "== aws: no version in log + guessed EC missing -> refuse (unchanged)"
reset_bins; mkcluster 261023-aws-amd64 ""
delete-ocp-aws tkaovila-261023-amd64 amd64 >/dev/null 2>&1; eq "returns 1" $? 1
eq "dir kept" "$([[ -d $tmp/m/261023-aws-amd64 ]] && print kept)" kept

print "== gcp/azure: missing binary / failed destroy keep the dir (used to be swallowed + rm)"
reset_bins; mkcluster 261023-gcp-wif "$V422"
delete-ocp-gcp-wif tkaovila-261023-wif >/dev/null 2>&1; eq "gcp returns 1" $? 1
eq "gcp dir kept" "$([[ -f $tmp/m/261023-gcp-wif/metadata.json ]] && print kept)" kept
fake 4.22.19; mkcluster 261023-gcp-wif "$V422"
delete-ocp-gcp-wif tkaovila-261023-wif >/dev/null 2>&1; eq "gcp exact -> 0" $? 0
eq "gcp used 4.22.19" "${$(head -1 $CALLS)%% *}" "openshift-install-4.22.19"
reset_bins; fake 4.22.19 1; mkcluster 261023-azure-sts "$V422"
delete-ocp-azure-sts tkaovila-261023-sts >/dev/null 2>&1; eq "azure destroy fail -> 1" $? 1
eq "azure dir kept" "$([[ -f $tmp/m/261023-azure-sts/metadata.json ]] && print kept)" kept

print; print "passed=$pass failed=$fail"; (( fail == 0 ))
