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
# Stage scripts are grouped by function under scripts/:
#   scripts/build/   -- image build pipeline (kernel/rootfs/bootloader/assembly)
#   scripts/config/  -- system + Raspberry Pi-style headless config, WiFi
#   scripts/usb/     -- USB gadget (network + serial console)
#   scripts/debug/   -- diagnostics (LED, optional panic capture; not run here)
set -euo pipefail

cd /work

echo "=== [1/7] Official Radxa bootloader (BootROM-compatible) ==="
bash /host/scripts/build/inspect-official.sh

echo "=== [2/7] Base build: kernel + Arch rootfs + firmware + U-Boot/FIP ==="
bash /host/scripts/build/build.sh

echo "=== [3/7] Packages + Raspberry Pi-style boot-partition config ==="
bash /host/scripts/config/wifi-setup.sh

echo "=== [4/7] Pi scripts/units: wpa_copy, sshswitch, userconf ==="
bash /host/scripts/config/port-pi.sh

echo "=== [5/7] WiFi firmware for all three WiFi module variants ==="
bash /host/scripts/config/wifi-firmware-fix.sh

echo "=== [6/7] USB gadget: NCM network + ACM serial console ==="
bash /host/scripts/usb/usb-gadget-composite.sh

echo "=== [7/7] Boot-status LED + initramfs + assemble SD image ==="
bash /host/scripts/debug/led-boot-status.sh
bash /host/scripts/build/initramfs.sh
bash /host/scripts/build/repack.sh

echo "=== build-all done: image in /work/radxa-zero-archlinux-*.img.xz ==="
