# Fedora 44 on HP Spectre x360 (bl0XX / hostname `spectrex360`)

Hardware: HP Spectre x360 Convertible 15-bl0XX. Intel Kaby Lake-U (HD Graphics
620) + NVIDIA GeForce 940MX (Optimus), Realtek ALC295 audio, HP TrueVision FHD
RGB-IR camera, Realtek Sunrise Point-LP Integrated Sensor Hub.

## NVIDIA GPU — mainline driver dropped Maxwell support, falls back to nouveau

**Last known-good: Fedora 44, kernel `7.1.12-200.fc44.x86_64`, driver branch `580.x` (RPM Fusion `akmod-nvidia-580xx`).**

`/proc/cmdline` already had the right pieces (`nvidia-drm.modeset=1`,
`rd.driver.blacklist=nouveau,nova_core`, `modprobe.blacklist=nouveau,nova_core`),
and a `kmod-nvidia` package matching the exact running kernel was installed —
but `lspci -k` still showed `nouveau` as the driver in use and `nvidia-smi`
returned nothing.

First suspected an initramfs regen issue (blacklist directive not baked in),
so ran `akmods --force && dracut -f --regenerate-all`. That was necessary but
not sufficient — the real cause, found in `journalctl -b 0 -k`:

```
nvidia 0000:01:00.0: enabling device (0006 -> 0007)
NVRM: The NVIDIA GPU 0000:01:00.0 (PCI ID: 10de:134d)
NVRM: nvidia.ko because it does not include the required GPU
nvidia 0000:01:00.0: probe with driver nvidia failed with error -1
NVRM: The NVIDIA probe routine failed for 1 device(s).
```

followed by `nvidia-fallback.service` running `modprobe nouveau` and Plymouth
showing "NVIDIA kernel module missing. Falling back to nouveau."

The GeForce 940MX is Maxwell (GM108M, PCI ID `10de:134d`). Mainline NVIDIA
driver branches (560+, this system had pulled in `610.57.04`) dropped kernel
module support for Maxwell entirely — it's not an open-vs-closed-module
issue, the GPU just isn't supported by current mainline anymore. Cached akmod
build logs in `/var/cache/akmods/nvidia/` showed this machine had previously
built successfully against driver `580.105.08` (fc41 kernel) and `580.178.04`
(fc43 kernel) — the legacy branch that still supports Maxwell — before
something (likely a routine `dnf upgrade`) pulled in the generic mainline
`akmod-nvidia` package for the fc44 kernel instead.

Fix: [`scripts/spectre-x360/fix-nvidia-driver.sh`](../scripts/spectre-x360/fix-nvidia-driver.sh)
removes the mainline packages and swaps to RPM Fusion's `akmod-nvidia-580xx` /
`xorg-x11-drv-nvidia-580xx` (the last branch with Maxwell support), rebuilds,
regenerates the initramfs, and reboots. Verify after reboot with
[`scripts/spectre-x360/check-hardware-setup.sh`](../scripts/spectre-x360/check-hardware-setup.sh).

If a future `dnf upgrade` pulls the generic `akmod-nvidia`/`xorg-x11-drv-nvidia*`
packages back in (they can look like a newer version and win a plain
upgrade), this will regress — re-run the fix script.

## Power management — already correct, don't install power-profiles-daemon

Fedora 44 ships `tuned` + `tuned-ppd` (not `power-profiles-daemon`).
`tuned-ppd` provides the same `ppd-service` D-Bus interface GNOME's power
panel expects, by way of `tuned`. Installing `power-profiles-daemon` on top
conflicts with it (`ppd-service` provided by both). Confirmed already
enabled/active, running the `balanced-battery` profile — no action needed.
Check with `tuned-adm active`.

## Sleep

`/sys/power/mem_sleep` shows `s2idle [deep]` — deep (S3) sleep is selected,
which is the right call for this Kaby Lake-era hardware (s2idle is flaky on
it). Not yet exercised/tested this boot at time of writing.

## Windows Hello equivalent (Howdy) — needs a workaround for f44

The IR camera is real: `Suyin Corp. HP TrueVision FHD RGB-IR`, exposed as
both `/dev/video0` and `/dev/video1` (same sensor name on both — one is the
RGB stream, one is the IR stream; figure out which with `ffplay`).

`principis/howdy`'s COPR RPM depends on `python3dist(dlib)`, which isn't
packaged for Fedora 44 yet → `dnf install` fails with a conflicting-request
error. Workaround: build `dlib`/`face_recognition` via `pip` and force-install
the howdy RPM with `rpm -i --nodeps`, bypassing just that one broken
dependency check. Source: https://github.com/Boltgolt/howdy/issues/1135.

Script: [`scripts/spectre-x360/setup-howdy.sh`](../scripts/spectre-x360/setup-howdy.sh).
Automates the install; prints (but does not auto-run) the remaining manual
steps:
- Identify the IR `/dev/videoN` node.
- Point howdy's `config.ini` at it and set frame dimensions.
- Optionally `linux-enable-ir-emitter` if the IR LED doesn't light up.
- `howdy add` / `howdy test` before touching PAM.
- Add `auth sufficient pam_howdy.so` to `/etc/pam.d/gdm-password`, `sudo`,
  `polkit-1` (this machine runs GNOME/GDM, not KDE — different guides online
  reference `plasmalogin` instead).
- Load an SELinux policy module granting GDM's `xdm_t` context access to the
  camera device node (`v4l_device_t`), otherwise face auth at the login
  screen fails even though `sudo howdy test` works from a normal session.

These last steps are deliberately **not** scripted — a bad PAM edit can lock
you out of login/sudo, so do them one at a time with a root shell open in
another terminal.

## Audio (B&O speakers) — under investigation

Codec is Realtek ALC295 (`snd_hda_codec_alc269` driver). Boot log:

```
snd_hda_codec_alc269 hdaudioC0D0: ALC295: picked fixup  for PCI SSID 103c:0000
snd_hda_codec_alc269 hdaudioC0D0: autoconfig for ALC295: line_outs=1 (0x17/0x0/0x0/0x0/0x0) type:speaker
snd_hda_codec_alc269 hdaudioC0D0:    speaker_outs=0 (0x0/0x0/0x0/0x0/0x0)
```

The picked fixup name is blank and the PCI subsystem ID reads as `103c:0000`
instead of the real HP subsystem ID (`103c:82c1` per `lspci`) — the codec's
SSID isn't matching any entry in the kernel's ALC295 fixup table, so no
quad-speaker quirk gets applied and `speaker_outs=0`. This is the likely
cause of thin/missing-bass audio, since the B&O tuning on this model relies
on that fixup driving both tweeters and woofers. Not yet confirmed by
listening test, and no exact-match upstream fix found yet for ALC295
(closest reference: an ALC285 quad-speaker fix repo, not directly
applicable). Still being researched.
