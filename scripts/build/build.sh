#!/bin/bash
# Radxa Zero (S905Y2) mainline image builder
# Kernel 7.3-rc6 (vanilla mainline, Armbian meson64 edge config) + mainline U-Boot
# Rootfs: Arch Linux ARM generic AArch64
set -euo pipefail

exec > >(tee -a /work/build.log) 2>&1

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
NPROC=$(nproc)
echo "=== Build start: $(date -u) | jobs=$NPROC ==="

cd /work

### 1. Kernel source (7.3-rc6) ##############################################
echo "=== [1/8] Download kernel 7.3-rc6 ==="
if [ ! -d linux-src ]; then
  mkdir -p linux-src
  ( wget -q https://cdn.kernel.org/pub/linux/kernel/v7.x/testing/linux-7.3-rc6.tar.xz \
    || wget -q https://git.kernel.org/torvalds/t/linux-7.3-rc6.tar.gz ) || { echo "FATAL: kernel download failed"; exit 1; }
  tar xf linux-7.3-rc6.tar.* -C linux-src --strip-components=1
fi
cd linux-src

### 2. Kernel config ########################################################
echo "=== [2/8] Kernel config ==="
wget -q -O .config https://raw.githubusercontent.com/armbian/build/main/config/kernel/linux-meson64-edge.config
scripts/config --disable DEBUG_INFO --disable DEBUG_INFO_DWARF5 --disable DEBUG_INFO_BTF --enable DEBUG_INFO_NONE
scripts/config --set-str LOCALVERSION ""
scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
# Landlock (pacman sandbox), KASLR entropy, and ramoops/pstore (panic capture).
scripts/config --enable SECURITY_LANDLOCK
scripts/config --set-str LSM "capability,yama,apparmor,landlock"
scripts/config --enable RANDOM_TRUST_BOOTLOADER
scripts/config --enable RANDOM_TRUST_CPU
scripts/config --enable PSTORE --enable PSTORE_RAM --enable PSTORE_CONSOLE --enable PSTORE_PMSG
make olddefconfig

echo "--- key options ---"
grep -E '^CONFIG_(MMC_MESON_GX|EXT4_FS|DRM_MESON|DRM_PANFROST|BRCMFMAC|BT_HCIUART_BCM|VIDEO_MESON_VDEC|USB_DWC3|USB_DWC2|PWM_MESON|CRYPTO_DEV_AMLOGIC_GXL|MMC)=|CONFIG_LOCALVERSION|CONFIG_DEBUG_INFO_NONE' .config || true

### 3. Kernel build ##########################################################
echo "=== [3/8] Kernel build ==="
make -j"$NPROC" Image modules dtbs
KREL=$(make -s kernelrelease)
echo "Kernel release: $KREL"

### 4. Rootfs (Arch Linux ARM) ##############################################
echo "=== [4/8] Rootfs: Arch Linux ARM ==="
cd /work
mkdir -p rootfs
[ -f ArchLinuxARM-aarch64-latest.tar.gz ] || \
  wget -q https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz || \
  wget -q http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
bsdtar -xpf ArchLinuxARM-aarch64-latest.tar.gz -C rootfs
echo "Rootfs size: $(du -sm rootfs | cut -f1) MB"

cd linux-src
make modules_install INSTALL_MOD_PATH=/work/rootfs INSTALL_MOD_STRIP=1
depmod -b /work/rootfs "$KREL"
cd /work
echo "Rootfs with modules: $(du -sm rootfs | cut -f1) MB"

### 5. Firmware extras (Radxa Zero WiFi/BT) ##################################
echo "=== [5/8] Firmware ==="
[ -d firmware-repo/brcm ] || { rm -rf firmware-repo; git clone -q --depth 1 --filter=blob:none --sparse https://github.com/armbian/firmware firmware-repo; cd firmware-repo; git sparse-checkout set brcm; cd /work; }
FW=rootfs/usr/lib/firmware
mkdir -p "$FW/brcm"
# Radxa Zero WiFi = BCM43456. The .radxa,zero.* files in armbian/firmware are only
# 22-byte dedup pointers ("same as upstream generic"), so copy the REAL generic blobs.
for f in brcmfmac43456-sdio.bin brcmfmac43456-sdio.txt brcmfmac43456-sdio.clm_blob; do
  if [ -f "firmware-repo/brcm/$f" ] && [ "$(stat -c%s "firmware-repo/brcm/$f")" -gt 100 ]; then
    cp "firmware-repo/brcm/$f" "$FW/brcm/$f"; echo "fw: $f ($(stat -c%s "$FW/brcm/$f") B)"
  else
    echo "WARN: missing real blob $f"
  fi
done
# BT: BCM4345C0 UART hcd (generic) -> BCM4345C0.hcd
if [ -f firmware-repo/brcm/BCM4345C0_003.001.025.0162.0000_Generic_UART_37_4MHz_wlbga_ref_iLNA_iTR_eLG.hcd ]; then
  cp firmware-repo/brcm/BCM4345C0_003.001.025.0162.0000_Generic_UART_37_4MHz_wlbga_ref_iLNA_iTR_eLG.hcd "$FW/brcm/BCM4345C0.hcd"; echo "fw: BCM4345C0.hcd"
fi
# BT: AP6212 (BCM43430A1) — real hcd is only in the official Radxa image (bcm43438a1.hcd).
# Mainline hci_bcm requests it as BCM43430A1.hcd (same 4343x family), so extract + rename.
if [ -f official-root.img ]; then
  rm -f /work/bcm43438a1.hcd
  for src in /usr/lib/firmware/brcm/bcm43438a1.hcd /lib/firmware/brcm/bcm43438a1.hcd; do
    debugfs -R "dump $src /work/bcm43438a1.hcd" official-root.img 2>/dev/null && [ -s /work/bcm43438a1.hcd ] && break
  done
  if [ -s /work/bcm43438a1.hcd ]; then
    cp /work/bcm43438a1.hcd "$FW/brcm/BCM43430A1.hcd"
    cp /work/bcm43438a1.hcd "$FW/brcm/BCM.hcd"
    cp /work/bcm43438a1.hcd "$FW/brcm/bcm43438a1.hcd"
    echo "fw: BCM43430A1.hcd (BT AP6212, from official image $(stat -c%s "$FW/brcm/BCM43430A1.hcd") B)"
  else
    echo "WARN: bcm43438a1.hcd not found in official-root.img (BT for AP6212 will be missing)"
  fi
fi
# Meson vdec firmware check
ls "$FW/meson/vdec/" 2>/dev/null | head -5 || echo "WARN: no meson/vdec firmware in rootfs"

### 6. Rootfs configuration ##################################################
echo "=== [6/8] Rootfs configuration ==="
ROOTUUID=$(cat /proc/sys/kernel/random/uuid)
cat > rootfs/etc/fstab <<EOF
UUID=$ROOTUUID / ext4 defaults,noatime 0 1
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
EOF
echo radxa-zero > rootfs/etc/hostname
sed -i 's/^127\.0\.1\.1.*/127.0.1.1 radxa-zero/' rootfs/etc/hosts 2>/dev/null || echo '127.0.1.1 radxa-zero' >> rootfs/etc/hosts
mkdir -p rootfs/etc/modprobe.d
echo 'blacklist simpledrm' > rootfs/etc/modprobe.d/blacklist-radxa-zero.conf
echo "ROOTUUID=$ROOTUUID"

### 7. U-Boot + Amlogic FIP signing #########################################
echo "=== [7/8] U-Boot + FIP ==="
git clone -q --depth 1 https://github.com/LibreELEC/amlogic-boot-fip 2>/dev/null || true
[ -d amlogic-boot-fip ] || { echo "FATAL: amlogic-boot-fip missing"; exit 1; }
B=/work/amlogic-boot-fip/radxa-zero
chmod +x "$B/blx_fix.sh" "$B/aml_encrypt_g12a"
file "$B/aml_encrypt_g12a" | tee /work/encrypt-tool-file.txt
if file "$B/aml_encrypt_g12a" | grep -qi '32-bit'; then
  dpkg --add-architecture i386; apt-get update -qq; apt-get install -y -qq libc6:i386 libstdc++6:i386 || true
fi

UBOOT_TAG=""
for t in v2026.10 v2026.07 v2026.04 v2026.01 v2025.10 v2025.07 v2025.04 v2025.01 v2024.10 v2024.07 v2024.04 v2024.01 v2023.10 v2023.07; do
  rm -rf uboot
  git clone -q --depth 1 --branch "$t" https://github.com/u-boot/u-boot.git uboot 2>/dev/null || continue
  if git -C uboot ls-tree -r --name-only HEAD | grep -q 'configs/radxa-zero_defconfig'; then UBOOT_TAG="$t"; break; fi
done
if [ -z "$UBOOT_TAG" ]; then
  rm -rf uboot; UBOOT_TAG=v2023.07.02
  git clone -q --depth 1 --branch v2023.07.02 https://github.com/u-boot/u-boot.git uboot || { echo "FATAL: u-boot clone failed"; exit 1; }
fi
echo "U-Boot tag: $UBOOT_TAG"
cd uboot
make radxa-zero_defconfig
make -j"$NPROC"

# --- Amlogic G12A FIP signing (verbatim from Armbian meson64_common.inc) ---
mv -f u-boot.bin bl33.bin
"$B/blx_fix.sh" "$B/bl30.bin" zero_tmp bl30_zero.bin "$B/bl301.bin" bl301_zero.bin bl30_new.bin bl30
"$B/blx_fix.sh" "$B/bl2.bin"  zero_tmp bl2_zero.bin  "$B/acs.bin"   bl21_zero.bin   bl2_new.bin   bl2
"$B/aml_encrypt_g12a" --bl30sig --input bl30_new.bin --output bl30_new.bin.g12.enc --level v3
"$B/aml_encrypt_g12a" --bl3sig  --input bl30_new.bin.g12.enc --output bl30_new.bin.enc --level v3 --type bl30
"$B/aml_encrypt_g12a" --bl3sig  --input "$B/bl31.img" --output bl31.img.enc --level v3 --type bl31
"$B/aml_encrypt_g12a" --bl3sig  --input bl33.bin --compress lz4 --output bl33.bin.enc --level v3 --type bl33
"$B/aml_encrypt_g12a" --bl2sig  --input bl2_new.bin --output bl2.n.bin.sig
if [ -e "$B/lpddr3_1d.fw" ]; then
  "$B/aml_encrypt_g12a" --bootmk --output u-boot.bin \
    --bl2 bl2.n.bin.sig --bl30 bl30_new.bin.enc --bl31 bl31.img.enc --bl33 bl33.bin.enc \
    --ddrfw1 "$B/ddr4_1d.fw" --ddrfw2 "$B/ddr4_2d.fw" --ddrfw3 "$B/ddr3_1d.fw" \
    --ddrfw4 "$B/piei.fw" --ddrfw5 "$B/lpddr4_1d.fw" --ddrfw6 "$B/lpddr4_2d.fw" \
    --ddrfw7 "$B/diag_lpddr4.fw" --ddrfw8 "$B/aml_ddr.fw" --ddrfw9 "$B/lpddr3_1d.fw" --level v3
else
  "$B/aml_encrypt_g12a" --bootmk --output u-boot.bin \
    --bl2 bl2.n.bin.sig --bl30 bl30_new.bin.enc --bl31 bl31.img.enc --bl33 bl33.bin.enc \
    --ddrfw1 "$B/ddr4_1d.fw" --ddrfw2 "$B/ddr4_2d.fw" --ddrfw3 "$B/ddr3_1d.fw" \
    --ddrfw4 "$B/piei.fw" --ddrfw5 "$B/lpddr4_1d.fw" --ddrfw6 "$B/lpddr4_2d.fw" \
    --ddrfw7 "$B/diag_lpddr4.fw" --ddrfw8 "$B/aml_ddr.fw" --level v3
fi
mv -f u-boot.bin u-boot.bin.sd.bin
ls -la u-boot.bin.sd.bin
cd /work

### 8. Image assembly ########################################################
echo "=== [8/8] Image assembly ==="
mkdir -p bootfs/extlinux
cp linux-src/arch/arm64/boot/Image bootfs/Image
cp linux-src/arch/arm64/boot/dts/amlogic/meson-g12a-radxa-zero.dtb bootfs/
cat > bootfs/extlinux/extlinux.conf <<EOF
DEFAULT radxa-zero-arch
TIMEOUT 20

LABEL radxa-zero-arch
  KERNEL /Image
  FDT /meson-g12a-radxa-zero.dtb
  APPEND root=UUID=$ROOTUUID rootwait rw console=ttyAML0,115200 no_console_suspend
EOF

rm -f boot.img root.img final.img
mkfs.vfat -F 32 -n BOOT -C boot.img 524288
mmd -i boot.img ::/extlinux
mcopy -i boot.img bootfs/Image ::/Image
mcopy -i boot.img bootfs/meson-g12a-radxa-zero.dtb ::/
mcopy -i boot.img bootfs/extlinux/extlinux.conf ::/extlinux/extlinux.conf

ROOTUSED=$(du -sm rootfs | cut -f1)
ROOTSIZE=$(( (ROOTUSED + ROOTUSED/3 + 300) / 256 * 256 + 256 ))
echo "rootfs used=${ROOTUSED}MB -> root partition ${ROOTSIZE}MB"
mkfs.ext4 -q -U "$ROOTUUID" -L ARCHROOT -d rootfs -m 1 root.img "${ROOTSIZE}M"

BOOT_START=32768
BOOT_SIZE=1048576
ROOT_START=$((BOOT_START + BOOT_SIZE))
ROOT_SECTORS=$((ROOTSIZE * 2048))
TOTAL_SECTORS=$((ROOT_START + ROOT_SECTORS))
truncate -s $((TOTAL_SECTORS * 512)) final.img

printf 'label: dos\nstart=%d, size=%d, type=c, bootable\nstart=%d, type=83\n' \
  "$BOOT_START" "$BOOT_SIZE" "$ROOT_START" | sfdisk --no-reread --no-tell-kernel final.img

dd if=uboot/u-boot.bin.sd.bin of=final.img bs=1 count=442 conv=notrunc status=none
dd if=uboot/u-boot.bin.sd.bin of=final.img bs=512 skip=1 seek=1 conv=notrunc status=none
dd if=boot.img of=final.img bs=512 seek=$BOOT_START conv=notrunc status=none
dd if=root.img of=final.img bs=512 seek=$ROOT_START conv=notrunc status=none
sync

fdisk -l final.img || true

IMGFILE=radxa-zero-archlinux-linux-${KREL}.img
mv final.img "$IMGFILE"
echo "Compressing (xz -6)..."
xz -T0 -6 -kf "$IMGFILE"

### Ship #####################################################################
mkdir -p /out
cp "$IMGFILE.xz" /out/
sha256sum /out/"$IMGFILE.xz" > /out/SHA256SUMS.txt
{
  echo "image: $IMGFILE.xz"
  echo "kernel: vanilla mainline $KREL"
  echo "kernel config: armbian/build linux-meson64-edge.config (7.3) + DEBUG_INFO off"
  echo "u-boot: mainline $UBOOT_TAG (radxa-zero_defconfig) + LibreELEC amlogic-boot-fip g12a FIP"
  echo "rootfs: Arch Linux ARM generic AArch64 latest"
  echo "rootfs uuid: $ROOTUUID"
  echo "root partition: ${ROOTSIZE}MB, boot: 512MB (offset 16MiB)"
  echo "modules: $(ls rootfs/usr/lib/modules | tr '\n' ' ')"
  echo "image size: $(du -sm "$IMGFILE" | cut -f1)MB, xz: $(du -sm "$IMGFILE.xz" | cut -f1)MB"
  echo "built: $(date -u)"
} | tee /out/BUILD-INFO.txt

cp /work/build.log /out/build.log 2>/dev/null || true
echo "=== BUILD COMPLETE: /out/$IMGFILE.xz ==="
