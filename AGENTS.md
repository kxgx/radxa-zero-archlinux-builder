# AGENTS.md — Development Guide & Constraints

Rules and workflow for humans **and AI agents** working on this repository. Follow
them; they encode hard-won lessons (a wrong bootloader bricks the boot, a leaked
secret is public forever).

## What this project is

Builds a bootable **Arch Linux ARM** SD image for the **Radxa Zero** (Amlogic
S905Y2) with a **vanilla mainline kernel**, the **official Radxa bootloader**, and
**Raspberry Pi–style headless configuration** (WiFi/SSH/user via files on the boot
partition). It is built inside a Docker container and released (stable + latest
kernel variants) through GitHub Actions.

## Repository layout

```
build-all.sh                 # entry point — orchestrates every stage in order
Dockerfile                   # cross-toolchain build container
scripts/
  build/    # image pipeline: kernel+rootfs (build.sh), bootloader
            #   (inspect-official.sh), SD assembly (repack.sh)
  config/   # rootfs base config (wifi-setup.sh) + Pi headless mechanism
            #   (port-pi.sh) + WiFi firmware (wifi-firmware-fix.sh)
  usb/      # USB gadget: NCM network + ACM serial console
  debug/    # optional diagnostics (LED, panic capture) — not in the default build
```

**Keep script responsibilities separate.** `wifi-setup.sh` = rootfs base config
(packages, keyring, netdev, sudoers, network, root expand). `port-pi.sh` = the Pi
headless mechanism only (real `wpa_copy`/`sshswitch`/`userconf` + units). Never
let them grow into each other again.

## HARD RULES — never violate

1. **Bootloader must be the official Radxa blob.** The mainline U-Boot we build is
   **rejected by the S905Y2 BootROM** — the board drops into USB burn mode
   (GX-CHIP). `inspect-official.sh` extracts `official-bootloader.img` from the
   official Radxa image; `repack.sh` **fails hard** if it's missing. Never add a
   fallback to the mainline U-Boot.

2. **No secrets, ever.** No WiFi passwords/SSIDs, tokens, or personal paths in the
   repo **or git history**. History is public. Scan before pushing
   (`git grep -nE 'password|psk=|<ssid>'`); the CI `checks` job also scans.

3. **No initramfs.** The kernel mounts root directly by UUID (EXT4 + MMC are
   built-in). An initramfs with hardcoded `/dev/mmcblk*` paths caused
   "Can't lookup blockdev" on every boot. If you add one back, mount by UUID only.

4. **Kernel version is auto-detected.** Image names use `${KREL}` from
   `make kernelrelease`. Never hardcode a kernel version into a filename.

5. **`wpa_copy` must use `systemctl enable --now --no-block`.** A blocking
   `systemctl restart wpa_supplicant@wlan0` deadlocks against the unit's
   `Before=` ordering and hangs first boot.

6. **`netdev` group goes in BOTH `/etc/group` and `/etc/gshadow`.** A group in
   `group` but not `gshadow` makes `shadow.service`/`grpck` fail every boot.

7. **Landlock stays enabled** (`CONFIG_SECURITY_LANDLOCK=y` + in the `LSM` list) —
   pacman uses it to sandbox installs.

8. **Shell style:** `#!/bin/bash`, `set -euo pipefail`, **LF line endings**
   (`.gitattributes` enforces this), no hardcoded host paths (use `/work` and
   `/host` container paths). Every `.sh` must pass `bash -n` and
   `shellcheck --severity=error`.

## Build workflow

```bash
docker build -t rz-builder .
docker run --rm -v rz-build:/work -v "$PWD":/host:ro rz-builder bash /host/build-all.sh
```

- `/work` is the build volume (kernel source, rootfs, artifacts); `/host` is this
  repo mounted read-only. Stage scripts run **inside** the container.
- `build-all.sh` calls the stage scripts in dependency order. Keep that order:
  bootloader → base build → rootfs config → Pi mechanism → WiFi firmware → USB →
  LED → image assembly.

## Release workflow

Pushing a tag `vX.Y.Z` triggers GitHub Actions:

1. `checks` — lint/syntax/secret-scan/Docker (fast, every push/PR).
2. `build-image` — a **stable + latest matrix**, each building a full image in
   parallel. Kernel versions are set in the matrix (`KERNEL_VERSION`/`VARIANT`).
3. `release` — publishes both images; filenames carry the auto-detected kernel
   version (e.g. `radxa-zero-archlinux-stable-7.2.9.img.xz`).

To change kernels, edit the matrix in `.github/workflows/build.yml` (stable +
latest entries). Everything downstream renames itself automatically.

## Testing on hardware

The board has **no monitor/keyboard** — only a PC, a USB-C cable, and an SD
reader. Verify through:

- **USB serial** (COM port, 115200 8N1) — the console for logs/login.
- **USB network** (`192.168.100.1`) — SSH once `sshd` is on.
- **LED** — heartbeat = kernel alive; dark = stopped early.
- **SD BOOT partition** — drop `wpa_supplicant.conf`/`ssh`/`userconf.txt` for
  headless setup (consumed on first boot).

A released image must boot past the kernel (LED heartbeat + USB serial login). If
it enters **burn mode (GX-CHIP)**, the bootloader is wrong — see Hard Rule 1.

## Change discipline

- Prefer small, focused commits with a clear message.
- Any change to the boot path (bootloader, extlinux, kernel config) must be
  re-tested on hardware before release.
- Don't reintroduce a silent fallback that produces an unbootable image — fail
  loudly instead.
