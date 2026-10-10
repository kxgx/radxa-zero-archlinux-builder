#!/bin/bash
# Inspect the official Radxa Debian image: extract its bootloader + boot flow.
set -x
cd /work
echo "=== [1] download official Radxa Debian b23 ==="
wget -q https://github.com/radxa-build/radxa-zero/releases/download/b23/radxa-zero_debian_bullseye_kde_b23.img.xz -O official.img.xz
echo "=== [2] decompress ==="
xz -dc official.img.xz > official.img
ls -la official.img
echo "=== [3] partition table ==="
fdisk -l official.img
echo "=== [4] first 4MB (bootloader area) ==="
dd if=official.img of=official-bl.bin bs=1M count=4 status=none
ls -la official-bl.bin
echo "first 16 bytes:"; xxd official-bl.bin | head -2
echo "=== [5] inspect each partition (find boot FAT) ==="
for P in 1 2 3; do
  S=$(fdisk -l official.img 2>/dev/null | awk -v p="official.img$P " '$0 ~ p { if ($2 == "*") print $3; else print $2 }')
  [ -z "$S" ] && continue
  echo "--- partition $P start sector $S ---"
  mdir -i "official.img@@$((S*512))" ::/ 2>/dev/null | head -30 || echo "(not FAT)"
done
echo "=== [6] grab boot.scr / extlinux / boot.ini from FAT partitions ==="
for P in 1 2 3; do
  S=$(fdisk -l official.img 2>/dev/null | awk -v p="official.img$P " '$0 ~ p { if ($2 == "*") print $3; else print $2 }')
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
