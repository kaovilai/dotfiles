#!/bin/zsh
# Offline tests for the lid-closed laptop checks in verify-t3-headless
# (_t3_headless_laptop_checks). busctl, systemctl, lsblk, nmcli and gsettings
# are stub functions answering from STUB_* variables; files live in a temp dir.
emulate -LR zsh
setopt err_exit pipe_fail
local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
source "$repo/zsh/functions/migrate-laptop.zsh"

fail() { print -ru2 -- "FAIL: $*"; exit 1; }
export T3_GDM_DCONF_DIR="$tmp/gdm.d" T3_CRYPTTAB="$tmp/crypttab"
mkdir -p "$T3_GDM_DCONF_DIR"

busctl() { print -r -- "s \"$STUB_LID\""; }
systemctl() {
    case "$*" in
        "is-enabled suspend.target") print -r -- "$STUB_SUSPEND" ;;
        "is-enabled sshd") print -r -- "$STUB_SSHD" ;;
    esac
}
lsblk() { print -r -- disk; print -r -- part; [[ -n "$STUB_CRYPT" ]] && print -r -- crypt; return 0; }
nmcli() {
    case "$*" in
        *--active*) print -r -- "Home:802-11-wireless"; print -r -- "Wired:802-3-ethernet" ;;
        *connection.permissions*) print -r -- "$STUB_PERMS" ;;
        *psk-flags*) print -r -- "$STUB_FLAGS" ;;
    esac
}
gsettings() { print -r -- "$STUB_USER_SLEEP"; }
# $+commands decides whether nmcli/gsettings checks run; point them at stubs
commands[nmcli]=/stub/nmcli commands[gsettings]=/stub/gsettings

local out

# Fresh Fedora Workstation: everything suspends, LUKS without TPM, per-user Wi-Fi
STUB_LID=suspend STUB_SUSPEND=static STUB_SSHD=disabled STUB_CRYPT=1 \
    STUB_PERMS="user:tiger:" STUB_FLAGS=1 STUB_USER_SLEEP="'suspend'"
: > "$T3_CRYPTTAB"
# stdin held open with nothing to read: no check may wait on it (an empty
# gdm.d once ran grep with no file arguments, which then read stdin)
mkfifo "$tmp/stdin"
exec 3<>"$tmp/stdin"
_t3_headless_laptop_checks <&3 >"$tmp/out" 2>&1 &
local pid=$! i
for i in {1..30}; do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
if kill -0 $pid 2>/dev/null; then kill $pid; fail "a check read stdin"; fi
if wait $pid; then fail "defaults passed: $(<"$tmp/out")"; fi
exec 3<&-
out=$(<"$tmp/out")
[[ "$out" == *"Closing the lid on AC power suspends (logind HandleLidSwitchExternalPower=suspend)"* ]] || fail "lid not reported: $out"
[[ "$out" == *"Login screen suspends after idle"* ]] || fail "greeter suspend not reported: $out"
[[ "$out" == *"Your GNOME session suspends"* ]] || fail "session suspend not reported: $out"
[[ "$out" == *"Encrypted disk without TPM2 unlock"* ]] || fail "LUKS not reported: $out"
[[ "$out" == *"Wi-Fi 'Home' connects only after login"* ]] || fail "per-user Wi-Fi not reported: $out"
[[ "$out" != *Wired* ]] || fail "wired connection checked as Wi-Fi: $out"
[[ "$out" == *"sshd not enabled"* ]] || fail "sshd not reported: $out"

# Configured as the docs say
STUB_LID=ignore STUB_SSHD=enabled STUB_PERMS="" STUB_FLAGS=0 STUB_USER_SLEEP="'nothing'"
print -r -- "[org/gnome/settings-daemon/plugins/power]"$'\n'"sleep-inactive-ac-type='nothing'" > "$T3_GDM_DCONF_DIR/95-t3-no-suspend"
print -r -- "luks-1234 UUID=abcd none tpm2-device=auto,discard" > "$T3_CRYPTTAB"
out=$(_t3_headless_laptop_checks 2>&1) || fail "configured laptop failed: $out"
[[ "$out" != *"⚠"* && "$out" != *"✗"* ]] || fail "configured laptop still warned: $out"
[[ "$out" == *"Wi-Fi 'Home' connects at boot"* ]] || fail "system Wi-Fi not confirmed: $out"

# Masked sleep targets stand in for the greeter and session settings
rm "$T3_GDM_DCONF_DIR/95-t3-no-suspend"
STUB_SUSPEND=masked STUB_USER_SLEEP="'suspend'"
out=$(_t3_headless_laptop_checks 2>&1) || fail "masked suspend failed: $out"
[[ "$out" == *"Suspend is masked"* && "$out" != *"GNOME session"* ]] || fail "masked suspend not accepted: $out"

print -r -- "ok t3-headless-laptop"
