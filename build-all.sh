#!/bin/bash
# Radxa Zero — Arch Linux image: full build orchestrator (entry point).
#
# Runs every stage in dependency order and writes a bootable SD image to /work.
# The build runs inside the rz-builder Docker container with /work as the build
# volume and this repository mounted read-only at /host.
#
# Usage:
#   docker build -t rz-builder .
#   docker run --rm -v rz-build:/work -v "$PWD":/host:ro rz-builder bash /host/build-all.sh
#
# NOTE: some of the stage scripts below were developed iteratively and their
# responsibilities overlap slightly (e.g. wifi-setup.sh vs port-pi.sh both set up
# the Raspberry Pi boot-partition mechanism).  Running them in this order produces
# the working image; later stages overwrite earlier ones where they overlap.
set -euo pipefail

cd /work

echo "=== [1/7] Official Radxa bootloader (BootROM-compatible) ==="
bash /host/inspect-official.sh

echo "=== [2/7] Base build: kernel + Arch rootfs + firmware + U-Boot/FIP ==="
bash /host/build.sh

echo "=== [3/7] Packages + Raspberry Pi-style boot-partition config ==="
bash /host/wifi-setup.sh

echo "=== [4/7] Pi scripts/units: wpa_copy, sshswitch, userconf ==="
bash /host/port-pi.sh

echo "=== [5/7] WiFi firmware for all three WiFi module variants ==="
bash /host/wifi-firmware-fix.sh

echo "=== [6/7] USB gadget: NCM network + ACM serial console ==="
bash /host/usb-gadget-composite.sh

echo "=== [7/7] Boot-status LED + initramfs + assemble SD image ==="
bash /host/led-boot-status.sh
bash /host/initramfs.sh
bash /host/repack.sh

echo "=== build-all done: image in /work/radxa-zero-archlinux-*.img.xz ==="
