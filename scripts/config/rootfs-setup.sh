#!/bin/bash
# Radxa Zero image: rootfs base system configuration.
# Installs base packages + a fresh pacman keyring, sets up zsh + oh-my-zsh as the
# default shell, and configures the base system (wireless network, netdev group,
# sudoers, first-boot partition auto-expand).  The unified first-boot config
# (config.txt) is applied by scripts/config/firstboot-config.sh.
set -euo pipefail
exec > >(tee -a /work/rootfs-setup.log) 2>&1
echo "=== rootfs-setup $(date -u) ==="

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
  cronie git python parted zsh wpa_supplicant sudo 2>/dev/null || true

# Initialize the pacman keyring.  CRITICAL (not best-effort): without a
# trusted keyring every runtime `pacman -Syu` dies with "signature ... is
# unknown trust".  The chroot needs /dev/urandom for pacman-key --init to
# generate its master key, so bind-mount /dev first (this was the C4 root
# cause chain: init failed silently -> trust never established -> all
# upgrades broken).  Failures are now LOUD; firstboot also self-heals.
mkdir -p /work/rootfs/dev
mount --bind /dev /work/rootfs/dev 2>/dev/null || true
chroot /work/rootfs pacman-key --init || echo "WARN: pacman-key --init failed"
if ! chroot /work/rootfs pacman-key --populate archlinuxarm \
	&& ! chroot /work/rootfs pacman-key --populate archlinux; then
	echo "WARN: pacman-key --populate failed -- runtime upgrades will fail with unknown trust"
fi
umount /work/rootfs/dev 2>/dev/null || true

# --- zsh + oh-my-zsh as the default shell (rootfs base config) ---
# zsh becomes the login shell, so it MUST be present.  Install it robustly
# (retry) and verify before switching any shell -- a missing zsh would break
# login.  Only then set up oh-my-zsh and make zsh the default.
for _try in 1 2 3; do
  [ -x /work/rootfs/usr/bin/zsh ] && break
  pacman -r /work/rootfs --config /work/pacman-offline.conf --noconfirm -Sy zsh 2>/dev/null || true
done

if [ -x /work/rootfs/usr/bin/zsh ]; then
  ZSH_DIR=/work/rootfs/usr/share/oh-my-zsh
  rm -rf "$ZSH_DIR"
  git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$ZSH_DIR" 2>/dev/null \
    || echo "WARN: oh-my-zsh clone failed (no network at build?)"

  mkdir -p /work/rootfs/etc/zsh /work/rootfs/etc/skel /work/rootfs/etc/default
  cat > /work/rootfs/etc/zsh/zshrc <<'EOF'
# system-wide zshrc: enable oh-my-zsh for all users
export ZSH=/usr/share/oh-my-zsh
ZSH_THEME="robbyrussell"
plugins=(git)
[ -f "$ZSH/oh-my-zsh.sh" ] && source "$ZSH/oh-my-zsh.sh"
EOF
  cp /work/rootfs/etc/zsh/zshrc /work/rootfs/etc/skel/.zshrc
  # Also drop .zshrc into root's and every existing user's home (e.g. the default
  # "alarm" user, which first-boot renames).  Without ~/.zshrc zsh runs
  # zsh-newuser-install on every login.
  cp /work/rootfs/etc/zsh/zshrc /work/rootfs/root/.zshrc 2>/dev/null || true
  for h in /work/rootfs/home/*/; do
    [ -d "$h" ] && cp /work/rootfs/etc/zsh/zshrc "$h/.zshrc" 2>/dev/null || true
  done

  # default login shell = zsh (root now, useradd default for future users)
  sed -i 's#^\(root:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\).*#\1/bin/zsh#' /work/rootfs/etc/passwd
  grep -qx '/bin/zsh' /work/rootfs/etc/shells 2>/dev/null || echo '/bin/zsh' >> /work/rootfs/etc/shells
  sed -i 's#^SHELL=.*#SHELL=/bin/zsh#' /work/rootfs/etc/default/useradd 2>/dev/null \
    || echo 'SHELL=/bin/zsh' >> /work/rootfs/etc/default/useradd
else
  echo "WARN: zsh failed to install; NOT changing the default shell (would break login)"
fi

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

# NOTE: the unified first-boot config (config.txt: wifi/user/ssh/hostname/timezone)
# is applied by scripts/config/firstboot-config.sh.  It is NOT duplicated here.

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

# SSH: keep sessions alive (prevents idle / NAT timeouts from dropping the link)
mkdir -p /work/rootfs/etc/ssh/sshd_config.d
cat > /work/rootfs/etc/ssh/sshd_config.d/keepalive.conf <<'EOF'
ClientAliveInterval 30
ClientAliveCountMax 3
TCPKeepAlive yes
EOF

# --- first-boot root partition + filesystem expand (D1) ---------------------
# The image root partition is small (~4G); expand it to fill the SD card on the
# first boot.  parted -s is non-interactive (plain parted asked "Partition is
# being used. Are you sure?" and the old service exited 1).
cat > /work/rootfs/usr/local/bin/expand-rootfs <<'EOF'
#!/bin/sh
# Expand the root partition + filesystem to fill the SD card (D1).
# Runs once on first boot.  Uses sfdisk (non-interactive, can edit a mounted
# partition table) + resize2fs (online).  Always exits 0 so a failure cannot put
# the system into 'degraded' (parted prompted 'Partition is being used' and the
# old oneshot service failed -> degraded).
LOG=/var/log/expand-rootfs.log
{
  ROOTDEV=$(findmnt -n -o SOURCE /)
  DISK=$(lsblk -no PKNAME "$ROOTDEV")
  PARTNUM=$(cat "/sys/class/block/$(basename "$ROOTDEV")/partition" 2>/dev/null)
  echo "root=$ROOTDEV disk=$DISK part=$PARTNUM"
  echo ", +" | sfdisk --no-reread -N "$PARTNUM" "/dev/$DISK" && echo "partition table updated"
  partx --update --nr "$PARTNUM" "/dev/$DISK" 2>/dev/null && echo "kernel notified of new size"
  resize2fs "$ROOTDEV" && echo "filesystem grown"
  df -h /
} >> "$LOG" 2>&1
touch /var/lib/expand-rootfs-done 2>/dev/null
exit 0
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
