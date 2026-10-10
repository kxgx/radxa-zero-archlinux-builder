#!/bin/bash
# Build the initramfs for the Radxa Zero Arch image.  It runs as PID 1 before the
# real root and:
#   - copies any ramoops panic log from the previous boot to the BOOT partition
#   - finds the root from the kernel cmdline (root=UUID=... / root=/dev/...) and
#     switch_root's into it -- the same way the official Radxa initrd does it
# The kernel config is handled by build.sh; this script only assembles the cpio.
set -euo pipefail
exec > >(tee -a /work/initramfs.log) 2>&1
echo "=== initramfs $(date -u) ==="
cd /work
command -v cpio >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq cpio; }

# --- static ARM64 busybox (prebuilt) ---
if [ ! -x /work/busybox-static ]; then
  wget -q http://deb.debian.org/debian/pool/main/b/busybox/busybox-static_1.35.0-4+deb12u1+b1_arm64.deb -O busybox.deb
  rm -rf busybox-extract
  dpkg-deb -x busybox.deb busybox-extract
  cp busybox-extract/bin/busybox /work/busybox-static
  chmod +x /work/busybox-static
fi
file /work/busybox-static

# --- assemble the initramfs ---
IR=/work/initramfs-root
rm -rf "$IR"
mkdir -p "$IR"/bin "$IR"/proc "$IR"/sys "$IR"/dev "$IR"/mnt "$IR"/newroot
cp /work/busybox-static "$IR"/bin/busybox
chmod +x "$IR"/bin/busybox
for a in sh mount umount blkid cp mkdir sync echo switch_root reboot ls cat sed head; do
  ln -sf busybox "$IR"/bin/$a
done

cat > "$IR"/init <<'INIT'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

# copy any ramoops panic log from the previous boot to the BOOT partition (best-effort)
BOOTDEV=$(blkid -L BOOT 2>/dev/null)
mkdir -p /mnt
if [ -n "$BOOTDEV" ] && mount -o rw "$BOOTDEV" /mnt 2>/dev/null; then
  mkdir -p /mnt/pstore
  for f in /sys/fs/pstore/*; do [ -e "$f" ] && cp "$f" /mnt/pstore/ 2>/dev/null; done
  echo "initramfs-ran" > /mnt/initramfs-marker.txt 2>/dev/null
  sync
  umount /mnt 2>/dev/null
fi

# find + mount the root: ARCHROOT label, root=UUID from cmdline, then the common
# mmcblk paths (busybox blkid -L/-U may be unavailable -- these hardcoded
# fallbacks are what made the previous working image boot).
DEV=$(blkid -L ARCHROOT 2>/dev/null)
if [ -z "$DEV" ]; then
  ROOT=$(sed -n 's/.*root=\([^ 	]*\).*/\1/p' /proc/cmdline | head -1)
  case "$ROOT" in
    UUID=*)  DEV=$(blkid -U "${ROOT#UUID=}" 2>/dev/null) ;;
    LABEL=*) DEV=$(blkid -L "${ROOT#LABEL=}" 2>/dev/null) ;;
    /dev/*) DEV="$ROOT" ;;
  esac
fi
mkdir -p /newroot
if [ -n "$DEV" ] && mount "$DEV" /newroot 2>/dev/null; then
  exec switch_root /newroot /sbin/init
fi
for d in /dev/mmcblk0p2 /dev/mmcblk1p2; do
  [ -b "$d" ] || continue
  mount "$d" /newroot 2>/dev/null && exec switch_root /newroot /sbin/init
done
echo "initramfs: cannot mount root (dev=$DEV)" > /dev/kmsg 2>/dev/null
reboot
INIT
chmod +x "$IR"/init

( cd "$IR" && find . | cpio -o -H newc | gzip > /work/initramfs.cpio.gz )
ls -la /work/initramfs.cpio.gz
echo "=== initramfs done ==="
