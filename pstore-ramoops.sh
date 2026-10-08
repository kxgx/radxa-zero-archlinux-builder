#!/bin/bash
# Add pstore/ramoops so the kernel panic log survives a reset (no serial console).
# The kernel panics ~2s in; with ramoops the oops/console log is saved to reserved
# RAM and can be read after reboot from /sys/fs/pstore/.
set -euo pipefail
exec > >(tee -a /work/pstore-ramoops.log) 2>&1
echo "=== pstore-ramoops $(date -u) ==="
R=/work/rootfs

cd /work/linux-src
DTS=arch/arm64/boot/dts/amlogic/meson-g12a-radxa-zero.dts
if ! grep -q 'ramoops' "$DTS"; then
  cat >> "$DTS" <<'EOF'

/ {
	reserved-memory {
		/* 1 MiB for ramoops (kernel panic log survives reset) */
		ramoops@7300000 {
			compatible = "ramoops";
			reg = <0x0 0x07300000 0x0 0x100000>;
			record-size = <0x40000>;
			console-size = <0x40000>;
			pmsg-size = <0x20000>;
		};
	};
};
EOF
fi
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- dtbs
echo "dtb rebuilt (ramoops reserved)"

# load the ramoops driver at boot (CONFIG_PSTORE_RAM=m)
mkdir -p "$R/etc/modules-load.d"
echo ramoops > "$R/etc/modules-load.d/pstore.conf"

# copy the panic log to the FAT BOOT partition so it can be read from Windows
cat > "$R/usr/local/bin/pstore-copy" <<'EOF'
#!/bin/sh
# After a panic+reboot, copy /sys/fs/pstore/* to the FAT BOOT partition (panic.log)
# so the log can be read by popping the SD card into a PC (no serial needed).
if [ -d /sys/fs/pstore ] && [ -n "$(ls -A /sys/fs/pstore 2>/dev/null)" ]; then
  mkdir -p /run/pstore-copy
  mount -o rw /dev/disk/by-label/BOOT /run/pstore-copy 2>/dev/null || exit 0
  { echo "=== pstore $(date -u) ==="; cat /sys/fs/pstore/*; } > /run/pstore-copy/panic.log 2>/dev/null
  sync
  umount /run/pstore-copy 2>/dev/null
fi
exit 0
EOF
chmod +x "$R/usr/local/bin/pstore-copy"

cat > "$R/etc/systemd/system/pstore-copy.service" <<'EOF'
[Unit]
Description=Copy kernel panic log to FAT BOOT partition
After=systemd-udevd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/pstore-copy

[Install]
WantedBy=multi-user.target
EOF
mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/pstore-copy.service "$R/etc/systemd/system/multi-user.target.wants/pstore-copy.service"

echo "--- ramoops node:"; grep -A9 'ramoops' "$DTS" | head -11
echo "=== pstore-ramoops done ==="
