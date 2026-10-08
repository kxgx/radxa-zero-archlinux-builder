#!/bin/bash
# Make the USB gadget serial console work (the user's ONLY console channel).
# Force USB device mode so g_serial enumerates as a CDC ACM device on the PC.
set -euo pipefail
exec > >(tee -a /work/usb-console-fix.log) 2>&1
echo "=== usb-console-fix $(date -u) ==="
R=/work/rootfs

# --- 1. Revert the risky DT change (dr_mode=peripheral broke boot) ---
cd /work/linux-src
DTS=arch/arm64/boot/dts/amlogic/meson-g12a-radxa-zero.dts
sed -i '/dr_mode = "peripheral";/d' "$DTS"
echo "--- &usb node now:"; grep -A3 '^&usb {' "$DTS"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- dtbs
echo "dtb rebuilt"

# --- 2. rootfs: sysfs role-force (backup) + g_serial + getty ---
mkdir -p "$R/usr/local/bin" "$R/etc/systemd/system/multi-user.target.wants" "$R/etc/modules-load.d"

cat > "$R/usr/local/bin/usb-force-device" <<'EOF'
#!/bin/sh
# Backup: force USB role to device via sysfs so the gadget enumerates.
for r in /sys/class/usb_role/*/role /sys/class/typec/port*/data_role; do
  [ -w "$r" ] && echo device > "$r" 2>/dev/null
done
modprobe g_serial 2>/dev/null
exit 0
EOF
chmod +x "$R/usr/local/bin/usb-force-device"

cat > "$R/etc/systemd/system/usb-gadget-console.service" <<'EOF'
[Unit]
Description=Force USB device mode + g_serial (gadget serial console)
After=systemd-udevd.service
Before=serial-getty@ttyGS0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/usb-force-device

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/usb-gadget-console.service \
       "$R/etc/systemd/system/multi-user.target.wants/usb-gadget-console.service"

# g_serial loads at boot
echo g_serial > "$R/etc/modules-load.d/gadget-serial.conf"

# getty on USB serial (ttyGS0) + UART (ttyAML0)
ln -sf /usr/lib/systemd/system/serial-getty@.service \
       "$R/etc/systemd/system/multi-user.target.wants/serial-getty@ttyGS0.service"
ln -sf /usr/lib/systemd/system/serial-getty@.service \
       "$R/etc/systemd/system/multi-user.target.wants/serial-getty@ttyAML0.service"

echo "--- enabled:"; ls "$R/etc/systemd/system/multi-user.target.wants/" | grep -E "ttyGS0|ttyAML0|usb-gadget" || true
echo "=== usb-console-fix done ==="
