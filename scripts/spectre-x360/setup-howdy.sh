#!/bin/bash
# Windows Hello-style face unlock via the built-in RGB-IR camera.
# principis/howdy's RPM dependency on python3-dlib is broken for f44 (not
# packaged yet), so build dlib via pip and force-install the RPM with
# --nodeps instead. See ../../docs/fedora44-spectre-x360-setup.md.
set -e

sudo dnf copr enable -y principis/howdy
# NOT ffmpeg (full build) here — it conflicts with Fedora's default
# ffmpeg-free once the full rpmfusion-free repo is enabled, and neither
# howdy nor ffmpeg-python need the CLI binary, just the pip bindings.
sudo dnf install -y cmake gcc-c++ python3-devel python3-pip python3-opencv v4l-utils
sudo pip install dlib face_recognition ffmpeg-python

cd /tmp
sudo dnf download howdy
sudo rpm -i --nodeps howdy-*.x86_64.rpm

# IR emitter helper, in case the IR LED doesn't turn on by default
sudo dnf copr enable -y ikunji/linux-enable-ir-emitter
sudo dnf --refresh install -y linux-enable-ir-emitter

echo
echo "=== Installed. Manual steps remain (do these yourself, one at a time) ==="
echo
echo "This camera (HP TrueVision FHD RGB-IR) only exposes ONE capture-capable node:"
echo "/dev/video0 (Video Capture, formats MJPG/YUYV only — no separate IR format)."
echo "/dev/video1 is Metadata Capture only, not usable for frames — ignore it."
echo "IR mode is toggled via a vendor UVC extension-unit control, not a separate"
echo "device or pixel format, hence step 2 below is REQUIRED, not just a fallback."
echo
echo "1. Point howdy at the (only) capture device:"
echo "     sudo sed -i 's|device_path = none|device_path = /dev/video0|' /usr/lib64/security/howdy/config.ini"
echo "     sudo sed -i 's/frame_width = -1/frame_width = 640/' /usr/lib64/security/howdy/config.ini"
echo "     sudo sed -i 's/frame_height = -1/frame_height = 360/' /usr/lib64/security/howdy/config.ini"
echo
echo "2. Configure the IR emitter (required for this hardware). It auto-picks the"
echo "   wrong node (/dev/video1, metadata-only) by default — pass -d explicitly:"
echo "     sudo linux-enable-ir-emitter -d /dev/video0 configure"
echo "     sudo systemctl enable --now linux-enable-ir-emitter"
echo
echo "3. Add your face and test recognition BEFORE touching PAM:"
echo "     sudo howdy add"
echo "     sudo howdy test"
echo
echo "4. Only after step 3 succeeds, enable it in PAM. Keep a root shell open in another"
echo "   terminal while you edit these, in case of a mistake. Add this line ABOVE the"
echo "   first 'auth' line in each file (GNOME/GDM, not KDE):"
echo "     auth sufficient pam_howdy.so"
echo "     sudo nano /etc/pam.d/gdm-password"
echo "     sudo nano /etc/pam.d/sudo"
echo "     sudo nano /etc/pam.d/polkit-1"
echo
echo "5. GDM runs confined under SELinux (xdm_t) and needs explicit camera access:"
echo "     cat > /tmp/howdy_xdm.te << 'EOF'"
echo "     module howdy_xdm 1.0;"
echo "     require {"
echo "         type xdm_t;"
echo "         type v4l_device_t;"
echo "         class chr_file { read write open ioctl map getattr };"
echo "     }"
echo "     allow xdm_t v4l_device_t:chr_file { read write open ioctl map getattr };"
echo "     EOF"
echo "     checkmodule -M -m -o /tmp/howdy_xdm.mod /tmp/howdy_xdm.te"
echo "     semodule_package -o /tmp/howdy_xdm.pp -m /tmp/howdy_xdm.mod"
echo "     sudo semodule -i /tmp/howdy_xdm.pp"
