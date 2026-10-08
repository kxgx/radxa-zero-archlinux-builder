#!/bin/bash
# Rootfs base configuration for the Radxa Zero Arch Linux image:
#   - install packages (base tools, keyring, WiFi, sudo)
#   - users/groups (netdev), sudoers, network, first-boot root partition expand
#
# The Raspberry Pi-style headless config (userconf / ssh / wpa from the BOOT
# partition) is NOT here -- that lives in scripts/config/port-pi.sh (real Pi code).
set -euo pipefail
exec > >(tee -a /work/rootfs-config.log) 2>&1
echo "=== rootfs-config $(date -u) ==="

DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pacman-package-manager

cat > /work/pacman-offline.conf <<'EOF'
[options]
Architecture = aarch64
SigLevel = Never
CheckSpace

[core]
Server = http://mirror.archlinuxarm.org/aarch64/core

[extra]
Server = http://mirror.archlinuxarm.org/aarch64/extra

[alarm]
Server = http://mirror.archlinuxarm.org/aarch64/alarm
EOF

# Base tools + a fresh keyring + WiFi/sudo.  Best-effort for the optional tools:
# they improve usability but a missing package must not abort the build.
pacman -r /work/rootfs --config /work/pacman-offline.conf --noconfirm -Sy \
  archlinuxarm-keyring wireless-regdb inetutils less wget openbsd-netcat rsync \
  cronie git python parted wpa_supplicant sudo 2>/dev/null || true

# Guarantee wpa_supplicant + sudo are present (the ladder: install -> extract).
for bin in wpa_supplicant sudo; do
  if [ ! -x "/work/rootfs/usr/bin/$bin" ]; then
    echo "WARN: $bin missing, trying a direct package extract"
    PKG=$(ls /work/rootfs/var/cache/pacman/pkg/${bin}-*.pkg.tar.* 2>/dev/null | head -1)
    [ -n "$PKG" ] && tar -xf "$PKG" -C /work/rootfs 2>/dev/null || true
  fi
done
ls -la /work/rootfs/usr/bin/wpa_supplicant /work/rootfs/usr/bin/sudo

# 25-wireless.network: DHCP on wlan* (systemd-networkd).
cat > /work/rootfs/etc/systemd/network/25-wireless.network <<'EOF'
[Match]
Name=wlan*

[Network]
DHCP=yes
EOF

# netdev group (Pi-style confs use GROUP=netdev).  Add to BOTH /etc/group and
# /etc/gshadow so grpck stays clean -- a group in /etc/group but not /etc/gshadow
# makes shadow.service/grpck fail (build-issues-report.md C1).
grep -q '^netdev:' /work/rootfs/etc/group || echo 'netdev:x:976:' >> /work/rootfs/etc/group
grep -q '^netdev:' /work/rootfs/etc/gshadow || echo 'netdev:!::' >> /work/rootfs/etc/gshadow

# wheel sudoers (userconf-created users get sudo).
mkdir -p /work/rootfs/etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /work/rootfs/etc/sudoers.d/10-wheel
chmod 440 /work/rootfs/etc/sudoers.d/10-wheel

# Auto-expand the root partition on first boot (D1): the image rootfs is sized
# small, so grow partition 2 to fill the SD card and resize ext4.  One-shot.
mkdir -p /work/rootfs/usr/local/bin
cat > /work/rootfs/usr/local/bin/expand-rootfs <<'EXPAND'
#!/bin/bash
# Grow root partition 2 to fill the disk, then resize ext4 (online).  One-shot.
set -e
DEV=/dev/mmcblk0
PART=2
if [ -b "$DEV" ] && command -v parted >/dev/null && command -v resize2fs >/dev/null; then
  END=$(parted -s "$DEV" unit s print 2>/dev/null | awk -v p=" $PART " '$0 ~ "^ *"p {print $3}' | tr -d 's')
  DISK=$(parted -s "$DEV" unit s print 2>/dev/null | awk '/Disk .*:/{print $3}' | tr -d 's')
  if [ -n "$END" ] && [ -n "$DISK" ] && [ "$END" -lt "$((DISK-34))" ]; then
    parted -s "$DEV" resizepart "$PART" 100%
    e2fsck -fy "${DEV}p${PART}" || true
    resize2fs "${DEV}p${PART}"
  fi
fi
EXPAND
chmod +x /work/rootfs/usr/local/bin/expand-rootfs

cat > /work/rootfs/etc/systemd/system/expand-rootfs.service <<'EXPANDSVC'
[Unit]
Description=Expand root filesystem to fill the SD card (first boot)
After=local-fs.target
ConditionPathExists=!/var/lib/expand-rootfs-done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/expand-rootfs
ExecStartPost=/bin/touch /var/lib/expand-rootfs-done
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EXPANDSVC
mkdir -p /work/rootfs/etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/expand-rootfs.service /work/rootfs/etc/systemd/system/multi-user.target.wants/expand-rootfs.service

# sshd OFF by default (Pi semantics: drop an empty `ssh` file on BOOT to enable).
rm -f /work/rootfs/etc/systemd/system/multi-user.target.wants/sshd.service

# drop package cache to keep the image slim.
rm -f /work/rootfs/var/cache/pacman/pkg/* 2>/dev/null || true

echo "=== rootfs-config done ==="
