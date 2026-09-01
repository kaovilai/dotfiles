#!/bin/bash
# GeForce 940MX is Maxwell (GM108M, PCI ID 10de:134d) — mainline NVIDIA driver
# branches (560+) dropped Maxwell support from their kernel modules. Installing
# the generic akmod-nvidia/xorg-x11-drv-nvidia* packages silently fails to
# probe the GPU and nvidia-fallback.service drops back to nouveau. Must use
# RPM Fusion's legacy 580xx branch instead (last branch supporting Maxwell).
# Last known-good on: Fedora 44, kernel 7.1.12-200.fc44.x86_64, driver 580.x.
# See ../../docs/fedora44-spectre-x360-setup.md for the diagnosis.
set -e

# Fedora's scoped third-party repo (rpmfusion-nonfree-nvidia-driver) only
# carries the mainline driver. The legacy 580xx/470xx branches (needed for
# Maxwell) live in the full rpmfusion-nonfree repo, which isn't enabled by
# that scoped setup — enable it explicitly.
sudo dnf install -y \
    "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

sudo dnf remove akmod-nvidia 'xorg-x11-drv-nvidia*' 'kmod-nvidia*' nvidia-settings nvidia-modprobe nvidia-gpu-firmware
sudo dnf install akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx
sudo akmods --force
sudo dracut -f --regenerate-all

read -p "Reboot now to load the new driver? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    sudo reboot
else
    echo "Skipping reboot. Run 'sudo reboot' manually when ready."
fi
