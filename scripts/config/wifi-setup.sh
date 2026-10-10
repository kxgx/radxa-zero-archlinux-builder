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

# --- Pi-style boot-time configurator ---
cat > /work/rootfs/usr/local/bin/pi-bootcfg.sh <<'EOF'
#!/bin/bash
set -u
CONF=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
BOOTDEV=""
for dev in /dev/mmcblk0p1 /dev/mmcblk1p1; do
  if [ -e "$dev" ] && blkid -o value -s LABEL "$dev" 2>/dev/null | grep -q '^BOOT$'; then BOOTDEV=$dev; break; fi
done

# resume wifi from a previously consumed config
if [ -f "$CONF" ]; then
  systemctl restart wpa_supplicant@wlan0.service 2>/dev/null || true
fi

[ -n "$BOOTDEV" ] || exit 0
mkdir -p /run/pi-bootcfg
mount -o rw "$BOOTDEV" /run/pi-bootcfg 2>/dev/null || exit 0

# 1) userconf.txt -> create/update user ("user:password-or-crypted-hash")
if [ -s /run/pi-bootcfg/userconf.txt ]; then
  LINE=$(sed '1s/^\xEF\xBB\xBF//' /run/pi-bootcfg/userconf.txt | grep -v '^#' | head -1)
  U=${LINE%%:*}; P=${LINE#*:}
  if [ -n "$U" ] && [ -n "$P" ] && [ "$U" != "$LINE" ]; then
    if ! id -u "$U" >/dev/null 2>&1; then
      useradd -m -G wheel -s /bin/bash "$U" 2>/dev/null || true
    fi
    if id -u "$U" >/dev/null 2>&1; then
      echo "$U:$P" | chpasswd -e 2>/dev/null || echo "$U:$P" | chpasswd
    fi
  fi
  rm -f /run/pi-bootcfg/userconf.txt
fi

# 2) ssh / ssh.txt -> enable sshd
if [ -f /run/pi-bootcfg/ssh ] || [ -f /run/pi-bootcfg/ssh.txt ]; then
  systemctl enable --now sshd.service 2>/dev/null || true
  rm -f /run/pi-bootcfg/ssh /run/pi-bootcfg/ssh.txt
fi

# 3) wpa_supplicant.conf -> WiFi (copy verbatim, strip BOM, consume)
if [ -s /run/pi-bootcfg/wpa_supplicant.conf ] \
   && grep -qE '^[[:space:]]*ssid[[:space:]]*=' /run/pi-bootcfg/wpa_supplicant.conf; then
  umask 077
  cp /run/pi-bootcfg/wpa_supplicant.conf "$CONF"
  sed -i '1s/^\xEF\xBB\xBF//' "$CONF"
  chmod 600 "$CONF"
  rm -f /run/pi-bootcfg/wpa_supplicant.conf
  systemctl restart wpa_supplicant@wlan0.service 2>/dev/null || true
fi

umount /run/pi-bootcfg
exit 0
EOF
chmod +x /work/rootfs/usr/local/bin/pi-bootcfg.sh

cat > /work/rootfs/etc/systemd/system/pi-bootcfg.service <<'EOF'
[Unit]
Description=Pi-style boot configuration from BOOT partition
After=systemd-udevd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/pi-bootcfg.sh

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /work/rootfs/etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/pi-bootcfg.service /work/rootfs/etc/systemd/system/multi-user.target.wants/pi-bootcfg.service

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
