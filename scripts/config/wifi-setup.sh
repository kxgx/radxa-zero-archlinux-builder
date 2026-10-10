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

# netdev group (Pi-style confs use GROUP=netdev)
grep -q '^netdev:' /work/rootfs/etc/group || echo 'netdev:x:976:' >> /work/rootfs/etc/group
# wheel sudoers (userconf-created users get sudo)
mkdir -p /work/rootfs/etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /work/rootfs/etc/sudoers.d/10-wheel
chmod 440 /work/rootfs/etc/sudoers.d/10-wheel

# sshd OFF by default (Pi semantics: drop an empty `ssh` file on BOOT to enable)
rm -f /work/rootfs/etc/systemd/system/multi-user.target.wants/sshd.service

# drop package cache to keep image slim
rm -f /work/rootfs/var/cache/pacman/pkg/* 2>/dev/null || true

echo "=== pi-mechanism-setup done ==="
