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

**Repo gotcha:** Fedora's onboarding flow (`fedora-third-party` / "install
NVIDIA driver" GUI prompt) enables a *scoped* repo,
`rpmfusion-nonfree-nvidia-driver`, which only carries the mainline driver —
not the legacy `580xx`/`470xx` branches. `dnf search`/`dnf install
akmod-nvidia-580xx` will fail with "No match for argument" until the full
`rpmfusion-free`/`rpmfusion-nonfree` repos are also enabled (the script does
this first).

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

## Windows Hello equivalent (Howdy) — DO NOT run linux-enable-ir-emitter on this camera

**⚠️ This camera was permanently damaged by `linux-enable-ir-emitter configure` on 2026-09-01. Do not run it again on this or any Sunplus-chip HP TrueVision RGB-IR camera without reading the incident below.**

The IR camera is `Suyin Corp. HP TrueVision FHD RGB-IR`, but it only exposes
**one** capture-capable node: `/dev/video0` (`Video Capture`). `/dev/video1`
is `Metadata Capture` only — no frames, don't point anything at it (`ffplay
/dev/video1` fails with "Inappropriate ioctl for device", which is expected).
`v4l2-ctl -d /dev/video0 --list-formats-ext` only lists `MJPG`/`YUYV` (both
RGB) — there's no separate IR pixel format either. IR mode on this sensor is
toggled via a vendor UVC extension-unit control.

`principis/howdy`'s COPR RPM depends on `python3dist(dlib)`, which isn't
packaged for Fedora 44 yet → `dnf install` fails with a conflicting-request
error. Workaround: build `dlib`/`face_recognition` via `pip` and force-install
the howdy RPM with `rpm -i --nodeps`, bypassing just that one broken
dependency check. Source: https://github.com/Boltgolt/howdy/issues/1135.

Script: [`scripts/spectre-x360/setup-howdy.sh`](../scripts/spectre-x360/setup-howdy.sh)
still installs howdy itself fine (that part is safe and unrelated to the
camera incident below) — **skip the `linux-enable-ir-emitter` step entirely**
until upstream has a real fix. The remaining manual steps it prints (PAM,
SELinux) are also still accurate for whenever the camera situation is
resolved:
- Add `auth sufficient pam_howdy.so` to `/etc/pam.d/gdm-password`, `sudo`,
  `polkit-1` (this machine runs GNOME/GDM, not KDE — different guides online
  reference `plasmalogin` instead).
- Load an SELinux policy module granting GDM's `xdm_t` context access to the
  camera device node (`v4l_device_t`), otherwise face auth at the login
  screen fails even though `sudo howdy test` works from a normal session.

These last steps are deliberately **not** scripted — a bad PAM edit can lock
you out of login/sudo, so do them one at a time with a root shell open in
another terminal.

### Incident: camera bricked by `linux-enable-ir-emitter configure` (2026-09-01)

**Timeline:**
1. `ffplay /dev/video0` worked normally (real RGB picture) beforehand.
2. Ran `sudo linux-enable-ir-emitter -d /dev/video0 configure`. It hung;
   turned out two copies were running concurrently in different terminals,
   contending for the device. Killed both.
3. From then on, the camera was broken — permanently, surviving a full
   reboot and a `systemctl suspend`/resume cycle.

**Symptoms:**
- `lsusb`/`/sys/class/video4linux/video0/name` show the camera identifying
  as generic `SPCA2085 PC Camera` (`1bcf:0b09`, manufacturer `SunplusIT Inc`)
  instead of `HP TrueVision FHD RGB-IR` (`064e:3401`).
- `sudo lsusb -v -d 1bcf:0b09` (full, non-privilege-limited descriptor dump)
  shows a structurally different, much more primitive device: exactly one
  format (`160x120 YUY2`) instead of `MJPG`/`YUYV` up to `1920x1080`, and a
  **Bulk** transfer endpoint instead of the Isochronous endpoint real UVC
  video cameras use. `Warning: Descriptor too short` on the Processing Unit
  descriptor persists even under full root access (not a permission
  artifact).
- `v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=1` times out with no
  frames ever delivered — even when explicitly set to the device's own
  claimed native format (`160x120 YUY2`). The IR LED does light up when the
  device is opened and turn off on close (so basic USB control-plane
  communication works), but zero video data is ever produced.
- No kernel errors logged anywhere during any of this — it fails silently,
  not loudly.

**What was ruled out:**
- Not a stale process/lock: confirmed nothing had `/dev/video0` open via
  `fuser`/`lsof`/`ps`.
- Not a USB-core state issue: full reboot re-enumerated the device fresh,
  identity and behavior unchanged.
- Not a suspend-recoverable hang: `systemctl suspend` + resume (which fixed
  an analogous hang for another user, see below) did not help here.
- Not a runtime mode toggle: `MSloan14/hp-rgbir-ir-mode` — a project that
  reverse-engineered this exact camera family's safe RGB/IR toggle (Extension
  Unit 3, selector 2, GUID `96274e36-eca7-49d5-995c-13cf882759cc`) — can't
  even find that control anymore (`ERROR: cannot read the camera control:
  [Errno 2] No such file or directory`). Our current (broken) descriptor
  table only has Unit 2 (Processing) and Unit 4 (Extension, different GUID
  `63610682-5070-49ab-b8cc-b3855e8d221d`) — the entire custom Unit 3 control
  block HP's firmware exposed is structurally gone, not just switched to a
  different value.
- No BIOS/WMI privacy shutter exists on this model to rule in/out
  (`hp-wmi` sysfs has no camera-related attribute).

**Root cause (best understanding):** `linux-enable-ir-emitter configure`
brute-force-probes UVC Extension Unit control selectors looking for one that
turns on the IR emitter, including (per its own upstream source and the
`hp-rgbir-ir-mode` author's independent findings) selectors used for the
Sunplus SPCA20xx ISP's flash **erase/write/finish** sequence on Unit 4
(historically documented around selectors 9/10/12 on this chip family, though
our saved `/etc/linux-enable-ir-emitter/*.ini` only recorded `idle`/reverted
status for everything it tried — it does not appear to have *recorded* a
successful destructive write, but the resulting device state matches one
exactly). The `MSloan14/hp-rgbir-ir-mode` README documents the identical
failure mode independently: "*Writing Extension Unit 4 selector 16 with a
value of 2 HARD-HUNG this camera's firmware... It took a suspend-to-RAM
(deep/S3) to power-cycle the sensor*" on the *same* camera family. A GitHub
issue on `linux-enable-ir-emitter` (EmixamPP/linux-enable-ir-emitter#102)
describes an **identical** symptom on different hardware: same fallback
identity (`1bcf:0b09`), same single-resolution/no-frames behavior, after the
same `configure` command — unresolved, multiple full shutdowns did not fix
it either. A separate case on a ThinkPad (different OEM/chip pairing,
`04f2:b614` → `1bcf:0b13`) documented the underlying firmware boot sector
being erased by an interrupted `configure` run, with recovery requiring a
byte-for-byte SPI flash dump from a working **donor** unit of the identical
model — read-only tooling for that exists (`dump-b614-readonly.py`, gist by
Shlok-Bhakta) but only for that specific Chicony/Lenovo chip variant, and
even that has no write/reflash counterpart yet (deliberately: "no flash
write").

**Recovery attempted and exhausted:**
1. Full reboot — no change.
2. `systemctl suspend` + resume — no change (despite fixing an analogous
   Unit-4 hang for the `hp-rgbir-ir-mode` author on the same chip family).
3. The one documented-safe control write (`ir-mode --set rgb --apply`,
   targeting Unit 3/selector 2) — the control no longer exists on the device
   to write to.
4. SPI flash reflash — no public dump exists for the `064e:3401` HP variant
   specifically, no write-capable tool exists for *any* variant of this chip
   yet, and we have no donor unit of this exact model to source a dump from
   even if one did.

**Conclusion:** this is very likely permanent firmware damage requiring
either HP service/warranty (camera module replacement) or a Sunplus/HP
vendor recovery tool that doesn't currently exist for Linux. Do not attempt
`linux-enable-ir-emitter configure` (or any Unit-4 extension-unit probing)
on this camera again — if a fix ever ships upstream, it will need to come
from someone with a genuine SPI reflash path for the `064e:3401` firmware,
not from re-running the same brute-force probe.



## Battery gauge cuts off at 17%

The battery gauge is miscalibrated: recalibration cycles (running down to the
sudden power-off) don't fix it, and the hardware cuts power at a reported
**17%**, so the usable range is 17-100%. `cycle_count` is always 0 and
`charge_full == charge_full_design`, so the firmware reports static values.

Software can't re-map the gauge, but UPower can shut down cleanly before the
cutoff. [`scripts/spectre-x360/setup-battery-thresholds.sh`](../scripts/spectre-x360/setup-battery-thresholds.sh)
installs a drop-in (`90-spectre-x360-battery.conf`) that warns at 30%, goes
critical at 25% and powers off at 21%. `CriticalPowerAction=Auto` falls back to
power-off because hibernate is unavailable (no disk swap, no `resume=`).

Limit: UPower can't act while suspended, so a long suspend can still drain to
the cutoff with no warning. Fixing that needs hibernate (disk swap of at least
RAM size plus `resume=`/`resume_offset=`) and `suspend-then-hibernate`.

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
