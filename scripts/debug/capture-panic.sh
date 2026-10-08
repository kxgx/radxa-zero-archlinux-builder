#!/bin/bash
# Capture the ~2s kernel panic log with NO serial console.
# Root cause of "没有log": CONFIG_PSTORE_RAM=m (module) is not loaded at panic
# time (~2s, before systemd), so the panic was never recorded.  Fix:
#   1) CONFIG_PSTORE_RAM=y (built-in)  -> any panic is written to reserved RAM
#   2) CONFIG_PSTORE_CONSOLE=y         -> capture console too
#   3) an initramfs that runs BEFORE the panic point and copies /sys/fs/pstore
#      to the FAT BOOT partition (panic.log), so it can be read from a PC.
set -euo pipefail
exec > >(tee -a /work/capture-panic.log) 2>&1
echo "=== capture-panic $(date -u) ==="
R=/work/rootfs

# --- 1. get a static ARM64 busybox (prebuilt, for the initramfs /init) ---
if [ ! -x /work/busybox-static ]; then
  cd /work
  wget -q http://deb.debian.org/debian/pool/main/b/busybox/busybox-static_1.35.0-4+deb12u1+b1_arm64.deb -O busybox.deb
  rm -rf busybox-extract
  dpkg-deb -x busybox.deb busybox-extract
  cp busybox-extract/bin/busybox /work/busybox-static
  chmod +x /work/busybox-static
  cd /work
fi
file /work/busybox-static

# --- 2. build the initramfs ---
command -v cpio >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq cpio; }
IR=/work/initramfs-root
rm -rf "$IR"
mkdir -p "$IR"/bin "$IR"/proc "$IR"/sys "$IR"/dev "$IR"/mnt "$IR"/newroot
cp /work/busybox-static "$IR"/bin/busybox
chmod +x "$IR"/bin/busybox
for a in sh mount umount blkid cp mkdir sync echo switch_root reboot ls cat kmsg; do
  ln -sf busybox "$IR"/bin/$a
done
cat > "$IR"/init <<'INIT'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
# dump any pstore (ramoops) left by the PREVIOUS boot's panic to the FAT BOOT part
BOOTDEV=$(blkid -L BOOT 2>/dev/null)
ROOTDEV=$(blkid -L ARCHROOT 2>/dev/null)
mkdir -p /mnt
if [ -n "$BOOTDEV" ] && mount -o rw "$BOOTDEV" /mnt 2>/dev/null; then
  mkdir -p /mnt/pstore
  for f in /sys/fs/pstore/*; do [ -e "$f" ] && cp "$f" /mnt/pstore/ 2>/dev/null; done
  echo "initramfs-ran" > /mnt/initramfs-marker.txt 2>/dev/null
  sync
  umount /mnt 2>/dev/null
fi
# boot the real root
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

# --- 3. kernel: make ramoops built-in so early panics are captured ---
cd /work/linux-src
scripts/config --enable PSTORE --enable PSTORE_RAM --enable PSTORE_CONSOLE --enable PSTORE_PMSG
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
echo "--- pstore config now:"
grep -E "CONFIG_PSTORE" .config | grep -v "^#"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image modules dtbs
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules_install INSTALL_MOD_PATH="$R" INSTALL_MOD_STRIP=1
depmod -b "$R" 7.3.0-rc6

echo "=== capture-panic done ==="
