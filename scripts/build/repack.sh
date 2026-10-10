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
cat > bootfs/wpa_supplicant.conf <<'EOF'
# 树莓派风格 WiFi 配置：取消注释并填写后保存，开机自动连接（SSH 默认已开启）
country=CN
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
#network={
#    ssid="你的WiFi名称"
#    psk="你的WiFi密码"
#}
# 多个网络可写多个 network={...} 块；隐藏网络在块内加 scan_ssid=1
EOF

cat > bootfs/userconf.txt <<'EOF'
#username:password
#↑ 把第 1 行改成  用户名:密码  （明文，或 openssl passwd -6 生成的 SHA-512 哈希）
# 开机会把默认用户 alarm 重命名为你指定的用户名并设置密码，自动加入 wheel 组可 sudo
# 只有第 1 行会被读取（树莓派 userconf.txt 标准格式）；其余是说明，不会被处理
EOF

rm -f boot.img root.img final.img
mkfs.vfat -F 32 -n BOOT -C boot.img 524288
mmd -i boot.img ::/extlinux
mcopy -i boot.img bootfs/Image ::/Image
mcopy -i boot.img bootfs/meson-g12a-radxa-zero.dtb ::/
[ -f bootfs/initramfs.cpio.gz ] && mcopy -i boot.img bootfs/initramfs.cpio.gz ::/initramfs.cpio.gz
mcopy -i boot.img bootfs/extlinux/extlinux.conf ::/extlinux/extlinux.conf
mcopy -i boot.img bootfs/wpa_supplicant.conf ::/wpa_supplicant.conf
mcopy -i boot.img bootfs/userconf.txt ::/userconf.txt

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

# Bootloader: OFFICIAL Radxa bootloader (Radxa-signed, BootROM accepts it).
# Written with the Amlogic convention (BL2 head @0 + FIP @512), preserving our MBR.
BL=/work/official-bootloader.img
[ -f "$BL" ] || BL=uboot/u-boot.bin.sd.bin
dd if="$BL" of=final.img bs=1 count=442 conv=notrunc status=none
dd if="$BL" of=final.img bs=512 skip=1 seek=1 conv=notrunc status=none
dd if=boot.img of=final.img bs=512 seek=$BOOT_START conv=notrunc status=none
dd if=root.img of=final.img bs=512 seek=$ROOT_START conv=notrunc status=none
sync

fdisk -l final.img || true
IMGFILE=radxa-zero-archlinux-linux-${KREL}-pi.img
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
  echo "bootcfg: REAL Raspberry Pi OS scripts ported (minimal Arch adaptation)"
  echo "  BOOT/wpa_supplicant.conf -> wifi via raspberrypi-net-mods wpa_copy (Bullseye 1.3.4)"
  echo "  BOOT/ssh | ssh.txt       -> enable sshd via raspberrypi-sys-mods sshswitch"
  echo "  BOOT/userconf.txt        -> rename default user via userconf-pi userconf"
  echo "  BOOT partition mounted at /boot/firmware (Bookworm-style)"
  echo "sshd: DISABLED by default (Pi semantics: drop empty ssh file on BOOT to enable)"
  echo "rootfs uuid: $ROOTUUID"
  echo "root partition: ${ROOTSIZE}MB, boot: 512MB (offset 16MiB)"
  echo "image size: $(du -sm "$IMGFILE" | cut -f1)MB, xz: $(du -sm "$IMGFILE.xz" | cut -f1)MB"
  echo "built: $(date -u)"
} | tee /out/BUILD-INFO.txt

cp /work/repack.log /out/repack.log
echo "=== repack done: /out/$IMGFILE.xz ==="
