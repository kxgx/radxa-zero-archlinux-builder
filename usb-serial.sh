#!/bin/bash
# Enable a USB serial console (CDC ACM gadget) on the Radxa Zero USB-C OTG port.
# The device tree already sets dwc2 (usb@ff400000) to dr_mode="peripheral";
# g_serial binds to it and the board enumerates as /dev/ttyACM0 on the PC.
set -euo pipefail
exec > >(tee -a /work/usb-serial.log) 2>&1
echo "=== usb-serial $(date -u) ==="
R=/work/rootfs
mkdir -p "$R/etc/modules-load.d" "$R/etc/systemd/system/multi-user.target.wants"

# 1. load g_serial at boot -> creates /dev/ttyGS0 on the board, CDC ACM on the PC
echo g_serial > "$R/etc/modules-load.d/gadget-serial.conf"

# 2. login prompt on the USB serial port (like a Pi Zero g_serial console)
ln -sf /usr/lib/systemd/system/serial-getty@.service \
       "$R/etc/systemd/system/multi-user.target.wants/serial-getty@ttyGS0.service"

# 3. make sure getty doesn't fight the dedicated UART console (ttyAML0 stays default)
echo "--- enabled serial getty:"
ls -la "$R/etc/systemd/system/multi-user.target.wants/" | grep -E "ttyGS0|getty" || true
echo "=== usb-serial done ==="
