#!/bin/bash
# Inspect the official Radxa Debian image: extract its bootloader + boot flow.
set -x
cd /work
# Cache: skip the ~2GB download + extraction when the bootloader is already
# extracted (rebuild speed).  Set FORCE_OFFICIAL_DL=1 to force a re-download.
if [ -f official-bootloader.img ] && [ "${FORCE_OFFICIAL_DL:-0}" != "1" ]; then
  echo "official-bootloader.img already present — skipping official image download."
  exit 0
fi
echo "=== [1] download official Radxa Debian b23 ==="
wget -q https://github.com/radxa-build/radxa-zero/releases/download/b23/radxa-zero_debian_bullseye_kde_b23.img.xz -O official.img.xz
echo "=== [2] decompress ==="
xz -dc official.img.xz > official.img
ls -la official.img
echo "=== [3] partition table ==="
fdisk -l official.img
echo "=== [4] first 4MB (bootloader area) ==="
# This is the official Radxa bootloader (BL2 head @0-441 + FIP @512+).  repack.sh
# writes it with the Amlogic convention (442 bytes @0 + rest @512) and expects the
# name official-bootloader.img.  The mainline U-Boot we build is REJECTED by the
# S905Y2 BootROM, so this official blob is what makes the image bootable.
dd if=official.img of=official-bootloader.img bs=1M count=4 status=none
cp official-bootloader.img official-bl.bin
ls -la official-bootloader.img official-bl.bin
echo "first 16 bytes (BL2 magic should be 60 5c 8e 39):"; xxd official-bootloader.img | head -2
echo "=== [5] inspect each partition (find boot FAT) ==="
for P in 1 2 3; do
  S=$(fdisk -l official.img 2>/dev/null | awk -v p="official.img$P " '$0 ~ p {print $2}')
  [ -z "$S" ] && continue
  echo "--- partition $P start sector $S ---"
  mdir -i "official.img@@$((S*512))" ::/ 2>/dev/null | head -30 || echo "(not FAT)"
done
echo "=== [6] grab boot.scr / extlinux / boot.ini from FAT partitions ==="
for P in 1 2 3; do
  S=$(fdisk -l official.img 2>/dev/null | awk -v p="official.img$P " '$0 ~ p {print $2}')
  [ -z "$S" ] && continue
  mcopy -o -i "official.img@@$((S*512))" ::/boot.scr /work/official-boot.scr 2>/dev/null && echo "got boot.scr from p$P"
  mcopy -o -i "official.img@@$((S*512))" ::/boot.ini /work/official-boot.ini 2>/dev/null && echo "got boot.ini from p$P"
  mcopy -o -i "official.img@@$((S*512))" ::/extlinux/extlinux.conf /work/official-extlinux.conf 2>/dev/null && echo "got extlinux.conf from p$P"
done
ls -la /work/official-boot.scr /work/official-boot.ini /work/official-extlinux.conf 2>/dev/null
echo "=== [7] decompile boot.scr if present ==="
if [ -f /work/official-boot.scr ]; then
  mkimage -l /work/official-boot.scr 2>/dev/null
  tail -c +65 /work/official-boot.scr | strings | head -40
fi
echo "=== [8] extlinux.conf if present ==="
cat /work/official-extlinux.conf 2>/dev/null
echo "=== inspect done ==="
