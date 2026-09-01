#!/bin/bash
# Post-reboot verification for fix-nvidia-driver.sh. See
# ../../docs/fedora44-spectre-x360-setup.md for expected output.

echo "=== NVIDIA ==="
nvidia-smi
lsmod | grep nvidia

echo
echo "=== Power profiles (via tuned-ppd) ==="
systemctl is-active tuned
tuned-adm active

echo
echo "=== Sleep mode ==="
cat /sys/power/mem_sleep
