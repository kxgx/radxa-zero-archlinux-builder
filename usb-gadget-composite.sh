#!/bin/bash
# USB gadget composite: NCM (network) + ACM (serial) on the USB-C OTG port.
# This is the official Radxa approach (rsetup -> Hardware -> USB OTG services:
# radxa-ncm@*.* recommended).  Plug into a PC -> USB NIC (SSH) + COM port.
set -euo pipefail
exec > >(tee -a /work/usb-gadget-composite.log) 2>&1
echo "=== usb-gadget-composite $(date -u) ==="
R=/work/rootfs

# --- gadget setup script (configfs composite: NCM + ACM) ---
cat > "$R/usr/local/bin/usb-gadget-setup" <<'EOF'
#!/bin/sh
# Set up a USB gadget composite (NCM network + ACM serial) via configfs.
# First FORCE the USB role to DEVICE: the meson-g12a glue auto-detects the OTG ID
# pin (USB_R5 ID_DIG) and can stick in HOST mode on the Radxa Zero, so the gadget
# never sees the PC.  The driver registers a usb-role-switch with
# allow_userspace_control=true, so we can override it from userspace.
modprobe libcomposite 2>/dev/null

# wait for the usb-role-switch, then force device mode (retry)
i=0
while [ $i -lt 40 ]; do
  found=0
  for r in /sys/class/usb_role/*/role; do
    if [ -w "$r" ]; then echo device > "$r" 2>/dev/null; found=1; fi
  done
  [ "$found" = "1" ] && break
  i=$((i+1))
  sleep 0.5
done

mount -t configfs none /sys/kernel/config 2>/dev/null
CFG=/sys/kernel/config/usb_gadget/g1
mkdir -p "$CFG"
cd "$CFG"
echo 0x1d6b > idVendor
echo 0x0104 > idProduct
mkdir -p strings/0x409
echo "radxa-zero" > strings/0x409/serialnumber
echo "Radxa" > strings/0x409/manufacturer
echo "Radxa Zero" > strings/0x409/product
mkdir -p functions/ncm.usb0
mkdir -p functions/acm.usb0
mkdir -p configs/c.1/strings/0x409
echo "NCM+ACM" > configs/c.1/strings/0x409/configuration
ln -sf functions/ncm.usb0 configs/c.1/
ln -sf functions/acm.usb0 configs/c.1/
# re-force device mode, then bind to the first UDC (dwc2 peripheral)
for r in /sys/class/usb_role/*/role; do [ -w "$r" ] && echo device > "$r" 2>/dev/null; done
UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
[ -n "$UDC" ] && echo "$UDC" > UDC

# watchdog: the glue IRQ auto-switches the role back to HOST from the OTG ID pin;
# keep forcing DEVICE for the first 2 min so the gadget stays enumerated on the PC.
( i=0; while [ $i -lt 60 ]; do
    for r in /sys/class/usb_role/*/role; do [ -w "$r" ] && echo device > "$r" 2>/dev/null; done
    i=$((i+1)); sleep 2
  done ) &
exit 0
EOF
chmod +x "$R/usr/local/bin/usb-gadget-setup"

# --- systemd service ---
cat > "$R/etc/systemd/system/usb-gadget.service" <<'EOF'
[Unit]
Description=USB gadget composite (NCM network + ACM serial)
After=systemd-udevd.service
Before=serial-getty@ttyGS0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/usb-gadget-setup

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/usb-gadget.service "$R/etc/systemd/system/multi-user.target.wants/usb-gadget.service"

# drop the old g_serial loader (replaced by the configfs composite)
rm -f "$R/etc/modules-load.d/gadget-serial.conf" \
      "$R/etc/systemd/system/multi-user.target.wants/usb-gadget-console.service" \
      "$R/etc/systemd/system/usb-gadget-console.service"

# --- network: usb0 static IP so the PC can SSH over USB ---
cat > "$R/etc/systemd/network/20-usb-gadget.network" <<'EOF'
[Match]
Name=usb*

[Network]
Address=192.168.100.1/24
EOF

echo "--- enabled:"; ls "$R/etc/systemd/system/multi-user.target.wants/" | grep -E "usb-gadget|ttyGS0" || true
echo "=== usb-gadget-composite done ==="
