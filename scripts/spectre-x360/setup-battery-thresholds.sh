#!/bin/bash
# The battery gauge is miscalibrated and the hardware cuts power abruptly at a
# reported 17%. This installs a UPower drop-in that warns at 30%, goes critical
# at 25% and shuts down cleanly at 21%, before the sudden cutoff. It cannot act
# while the machine is suspended; see ../../docs/fedora44-spectre-x360-setup.md.
set -e

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/90-spectre-x360-battery.conf"
DEST=/etc/UPower/UPower.conf.d/90-spectre-x360-battery.conf

sudo install -m 0644 "$SRC" "$DEST"
sudo systemctl restart upower

echo "Installed $DEST"
upower -i "$(upower -e | grep -i BAT)" | grep -E 'state|percentage|warning-level'
