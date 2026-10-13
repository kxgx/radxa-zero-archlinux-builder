#!/bin/bash
# Repack the Radxa Zero image from cached /work state (adds /wifi.conf to FAT BOOT)
set -euo pipefail
exec > >(tee -a /work/repack.log) 2>&1
echo "=== repack $(date -u) ==="
cd /work

KREL=$(make -s -C linux-src kernelrelease)
ROOTUUID=$(grep -oE 'UUID=[0-9a-f-]+' rootfs/etc/fstab | head -1 | cut -d= -f2)
echo "KREL=$KREL ROOTUUID=$ROOTUUID"

rm -rf bootfs; mkdir -p bootfs/extlinux
cp linux-src/arch/arm64/boot/Image bootfs/Image
cp linux-src/arch/arm64/boot/dts/amlogic/meson-g12a-radxa-zero.dtb bootfs/
[ -f /work/initramfs.cpio.gz ] && cp /work/initramfs.cpio.gz bootfs/initramfs.cpio.gz
cat > bootfs/extlinux/extlinux.conf <<EOF
default l0
prompt 0
timeout 10

label l0
	linux /Image
	fdt /meson-g12a-radxa-zero.dtb
	initrd /initramfs.cpio.gz
	append root=UUID=$ROOTUUID rootwait rw panic=5 earlycon consoleblank=0 console=tty0 console=ttyAML0,115200n8 coherent_pool=2M irqchip.gicv3_pseudo_nmi=0 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1
EOF
cat > bootfs/config.txt <<'EOF'
# Radxa Zero 统一启动配置 config.txt（用 boot-config 工具填写，或手动编辑）
# 一行一个 key=value，# 开头为注释。首启应用后本文件会被删除。
# 建议用 boot-config 工具：它会把密码哈希/派生（不存明文）。

hostname=radxa-zero
timezone=Asia/Shanghai
ssh=1

# WiFi：wifi_psk 填 PBKDF2 派生的 64 位 hex（工具生成），或先填明文口令
#wifi_ssid=你的WiFi名称
#wifi_country=CN
#wifi_psk=你的WiFi口令或派生hex

# 用户：password_hash 填 openssl passwd -6 的哈希（工具生成），不要存明文密码
#username=xg
#password_hash=$6$...
EOF

rm -f boot.img root.img final.img
mkfs.vfat -F 32 -n BOOT -C boot.img 524288
mmd -i boot.img ::/extlinux
mcopy -i boot.img bootfs/Image ::/Image
mcopy -i boot.img bootfs/meson-g12a-radxa-zero.dtb ::/
[ -f bootfs/initramfs.cpio.gz ] && mcopy -i boot.img bootfs/initramfs.cpio.gz ::/initramfs.cpio.gz
mcopy -i boot.img bootfs/extlinux/extlinux.conf ::/extlinux/extlinux.conf
mcopy -i boot.img bootfs/config.txt ::/config.txt

ROOTUSED=$(du -sm rootfs | cut -f1)
ROOTSIZE=$(( (ROOTUSED + ROOTUSED/3 + 300) / 256 * 256 + 256 ))
echo "rootfs used=${ROOTUSED}MB -> root ${ROOTSIZE}MB"
mkfs.ext4 -q -U "$ROOTUUID" -L ARCHROOT -d rootfs -m 1 root.img "${ROOTSIZE}M"

BOOT_START=32768
BOOT_SIZE=1048576
ROOT_START=$((BOOT_START + BOOT_SIZE))
ROOT_SECTORS=$((ROOTSIZE * 2048))
TOTAL_SECTORS=$((ROOT_START + ROOT_SECTORS))
truncate -s $((TOTAL_SECTORS * 512)) final.img

printf 'label: dos\nstart=%d, size=%d, type=c, bootable\nstart=%d, type=83\n' \
  "$BOOT_START" "$BOOT_SIZE" "$ROOT_START" | sfdisk --no-reread --no-tell-kernel final.img

# Bootloader: OFFICIAL Radxa bootloader (Radxa-signed -- the BootROM only
# accepts a vendor-signed BL2 head at sector 0, with the FIP at sector 1).
# inspect-official.sh extracts it as official-bootloader.img (and
# official-bl.bin). A bare aml_encrypt --bootmk output is a FIP-only blob
# and is NOT a drop-in replacement: written with this layout it puts the FIP
# at sector 0 and the image never boots (this is exactly what made the
# v0.1.4 CI release unbootable while local builds worked).
BL=/work/official-bootloader.img
[ -f "$BL" ] || BL=/work/official-bl.bin
if [ ! -f "$BL" ]; then
	echo "FATAL: official Radxa bootloader not found (tried official-bootloader.img, official-bl.bin)."
	echo "       Run scripts/build/inspect-official.sh first -- a locally signed"
	echo "       FIP without the Radxa BL2 head will NOT boot."
	exit 1
fi
echo "bootloader: $BL"
dd if="$BL" of=final.img bs=1 count=442 conv=notrunc status=none
dd if="$BL" of=final.img bs=512 skip=1 seek=1 conv=notrunc status=none
dd if=boot.img of=final.img bs=512 seek=$BOOT_START conv=notrunc status=none
dd if=root.img of=final.img bs=512 seek=$ROOT_START conv=notrunc status=none
sync

# Verify the bootloader landed intact: BL2 head at 0 + FIP (non-zero) at 512.
SRC_HEAD=$(dd if="$BL" bs=1 count=442 2>/dev/null | sha256sum | cut -d' ' -f1)
IMG_HEAD=$(dd if=final.img bs=1 count=442 2>/dev/null | sha256sum | cut -d' ' -f1)
[ "$SRC_HEAD" = "$IMG_HEAD" ] || { echo "FATAL: BL2 head mismatch in final.img"; exit 1; }
IMG_FIP=$(dd if=final.img bs=1 skip=512 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')
if [ -z "$IMG_FIP" ] || [ "$IMG_FIP" = "0000000000000000" ]; then
	echo "FATAL: no FIP at sector 1 of final.img (wrong bootloader layout)"
	exit 1
fi
echo "bootloader verified: BL2 head + FIP in place"

fdisk -l final.img || true
IMGFILE=radxa-zero-archlinux-linux-${KREL}.img
mv final.img "$IMGFILE"
echo "Compressing (xz -6)..."
xz -T0 -6 -kf "$IMGFILE"

mkdir -p /out
cp "$IMGFILE.xz" /out/
sha256sum /out/"$IMGFILE.xz" > /out/SHA256SUMS.txt
{
  echo "image: $IMGFILE.xz"
  echo "kernel: vanilla mainline $KREL"
  echo "kernel config: armbian/build linux-meson64-edge.config (7.3) + DEBUG_INFO off"
  echo "u-boot: OFFICIAL Radxa bootloader (Radxa-signed, from official Debian image) + extlinux"
  echo "rootfs: Arch Linux ARM generic AArch64 latest + wpa_supplicant + sudo"
  echo "bootcfg: unified BOOT/config.txt applied on first boot (boot-config-apply)"
  echo "  config.txt keys: hostname, timezone, ssh, wifi_ssid/wifi_psk/wifi_country,"
  echo "                   username, password_hash"
  echo "  secrets hashed (SHA-512 crypt user, derived hex WiFi PSK) -- no plaintext"
  echo "  BOOT partition mounted at /boot/firmware"
  echo "sshd: enabled per config.txt (ssh=1); host keys regenerated on first boot"
  echo "rootfs uuid: $ROOTUUID"
  echo "root partition: ${ROOTSIZE}MB, boot: 512MB (offset 16MiB)"
  echo "image size: $(du -sm "$IMGFILE" | cut -f1)MB, xz: $(du -sm "$IMGFILE.xz" | cut -f1)MB"
  echo "built: $(date -u)"
} | tee /out/BUILD-INFO.txt

cp /work/repack.log /out/repack.log
echo "=== repack done: /out/$IMGFILE.xz ==="
