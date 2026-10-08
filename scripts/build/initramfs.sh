#!/bin/bash
# Build the initramfs for the Radxa Zero Arch image.  It runs as PID 1 before the
# real root and:
#   - copies any ramoops panic log from the previous boot to the BOOT partition
#   - finds the root by its ARCHROOT label (no hardcoded /dev/mmcblk*) and
#     switch_root's into it
# The kernel config (ramoops/pstore) is handled by scripts/build/build.sh; this
# script only assembles the initramfs cpio (no kernel rebuild).
set -euo pipefail
exec > >(tee -a /work/initramfs.log) 2>&1
echo "=== initramfs $(date -u) ==="
cd /work
command -v cpio >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq cpio; }

# --- static ARM64 busybox (prebuilt; cross-compiling busybox is fiddly) ---
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
for a in sh mount umount blkid cp mkdir sync echo switch_root reboot ls cat; do
  ln -sf busybox "$IR"/bin/$a
done

cat > "$IR"/init <<'INIT'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
BOOTDEV=$(blkid -L BOOT 2>/dev/null)
ROOTDEV=$(blkid -L ARCHROOT 2>/dev/null)
# copy any ramoops panic log from the previous boot to the BOOT partition (rw)
mkdir -p /mnt
if [ -n "$BOOTDEV" ] && mount -o rw "$BOOTDEV" /mnt 2>/dev/null; then
  mkdir -p /mnt/pstore
  for f in /sys/fs/pstore/*; do [ -e "$f" ] && cp "$f" /mnt/pstore/ 2>/dev/null; done
  echo "initramfs-ran" > /mnt/initramfs-marker.txt 2>/dev/null
  sync
  umount /mnt 2>/dev/null
fi
# boot the real root (found by label, no hardcoded device paths)
mkdir -p /newroot
if [ -n "$ROOTDEV" ] && mount "$ROOTDEV" /newroot 2>/dev/null; then
  exec switch_root /newroot /sbin/init
fi
echo "initramfs: cannot mount root (ARCHROOT label not found)" > /dev/kmsg 2>/dev/null
reboot
INIT
chmod +x "$IR"/init

( cd "$IR" && find . | cpio -o -H newc | gzip > /work/initramfs.cpio.gz )
ls -la /work/initramfs.cpio.gz
echo "=== initramfs done ==="
