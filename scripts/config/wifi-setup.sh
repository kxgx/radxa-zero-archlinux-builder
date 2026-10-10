#!/bin/bash
# Radxa Zero image: full Raspberry-Pi-style boot-partition configuration mechanism
# FAT BOOT partition files (Windows-editable):
#   wpa_supplicant.conf  -> WiFi (copied to /etc/wpa_supplicant/, consumed)
#   ssh / ssh.txt        -> enable sshd (consumed)
#   userconf.txt         -> "user:password-or-hash" create/update user (consumed)
set -euo pipefail
exec > >(tee -a /work/wifi-setup.log) 2>&1
echo "=== pi-mechanism-setup $(date -u) ==="

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

# Base tools + a fresh keyring (C3/C4).  Best-effort: these improve usability but
# a missing package must not abort the build.
pacman -r /work/rootfs --config /work/pacman-offline.conf --noconfirm -Sy \
  archlinuxarm-keyring wireless-regdb inetutils less wget openbsd-netcat rsync \
  cronie git python parted wpa_supplicant sudo 2>/dev/null || true

# Initialize the pacman keyring (C4 root cause: the image never ran pacman-key
# --init, so nothing could be installed).  Best-effort (chroot has no RNG).
chroot /work/rootfs pacman-key --init 2>/dev/null || true
chroot /work/rootfs pacman-key --populate archlinuxarm 2>/dev/null || true

# Ladder: normal install -> db-only + extract -> plain extract
if ! pacman -r /work/rootfs --config /work/pacman-offline.conf --noconfirm -Sy wpa_supplicant sudo; then
  echo "WARN: normal install failed, trying db-only + manual extract"
  pacman -r /work/rootfs --config /work/pacman-offline.conf --noconfirm -Sy --dbonly wpa_supplicant sudo || true
fi
for bin in wpa_supplicant sudo; do
  if [ ! -x "/work/rootfs/usr/bin/$bin" ]; then
    echo "WARN: extracting $bin package manually"
    PKG=$(ls /work/rootfs/var/cache/pacman/pkg/${bin}-*.pkg.tar.xz 2>/dev/null | head -1)
    if [ -z "$PKG" ]; then
      PKG=/tmp/${bin}.pkg.tar.xz
      wget -q -O "$PKG" "http://mirror.archlinuxarm.org/aarch64/extra/${bin}-2.11-2-aarch64.pkg.tar.xz" \
        || wget -q -O "$PKG" "http://mirror.archlinuxarm.org/aarch64/core/${bin}-2.11-2-aarch64.pkg.tar.xz" \
        || wget -q -O "$PKG" "http://mirror.archlinuxarm.org/aarch64/extra/${bin}-2.11-1-aarch64.pkg.tar.xz" \
        || wget -q -O "$PKG" "http://mirror.archlinuxarm.org/aarch64/core/${bin}-2.11-1-aarch64.pkg.tar.xz"
    fi
    tar -xJf "$PKG" -C /work/rootfs
  fi
done
ls -la /work/rootfs/usr/bin/wpa_supplicant /work/rootfs/usr/bin/sudo

# NOTE: the Raspberry Pi-style boot configurator (userconf/ssh/wpa from the BOOT
# partition) is installed by scripts/config/port-pi.sh (the real Pi code).  It is
# NOT duplicated here.

cat > /work/rootfs/etc/systemd/network/25-wireless.network <<'EOF'
[Match]
Name=wlan*

[Network]
DHCP=yes
EOF

# netdev group (Pi-style confs use GROUP=netdev).  Add to BOTH /etc/group and
# /etc/gshadow so grpck stays clean (a group in group but not gshadow makes
# shadow.service/grpck fail on every boot).
grep -q '^netdev:' /work/rootfs/etc/group || echo 'netdev:x:976:' >> /work/rootfs/etc/group
grep -q '^netdev:' /work/rootfs/etc/gshadow || echo 'netdev:!::' >> /work/rootfs/etc/gshadow
# wheel sudoers (userconf-created users get sudo)
mkdir -p /work/rootfs/etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /work/rootfs/etc/sudoers.d/10-wheel
chmod 440 /work/rootfs/etc/sudoers.d/10-wheel

# --- first-boot root partition + filesystem expand (D1) ---------------------
# The image root partition is small (~4G); expand it to fill the SD card on the
# first boot.  parted -s is non-interactive (plain parted asked "Partition is
# being used. Are you sure?" and the old service exited 1).
cat > /work/rootfs/usr/local/bin/expand-rootfs <<'EOF'
#!/bin/sh
set -e
ROOTDEV=$(findmnt -n -o SOURCE /)
DISK=$(lsblk -no PKNAME "$ROOTDEV")
PARTNUM=$(cat "/sys/class/block/$(basename "$ROOTDEV")/partition")
parted -s "/dev/$DISK" resizepart "$PARTNUM" 100%
resize2fs "$ROOTDEV"
touch /var/lib/expand-rootfs-done
EOF
chmod +x /work/rootfs/usr/local/bin/expand-rootfs

cat > /work/rootfs/etc/systemd/system/expand-rootfs.service <<'EOF'
[Unit]
Description=Expand root filesystem to fill the SD card (first boot)
DefaultDependencies=no
After=systemd-fsck-root.service
Before=systemd-remount-fs.service
ConditionPathExists=!/var/lib/expand-rootfs-done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/expand-rootfs
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /work/rootfs/etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/expand-rootfs.service /work/rootfs/etc/systemd/system/multi-user.target.wants/expand-rootfs.service

# sshd OFF by default (Pi semantics: drop an empty `ssh` file on BOOT to enable)
rm -f /work/rootfs/etc/systemd/system/multi-user.target.wants/sshd.service

# drop package cache to keep image slim
rm -f /work/rootfs/var/cache/pacman/pkg/* 2>/dev/null || true

echo "=== pi-mechanism-setup done ==="
