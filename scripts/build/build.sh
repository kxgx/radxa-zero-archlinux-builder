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

### 1. Kernel source (KERNEL_VERSION: 7.2.9 stable or 7.3-rc6) ###############
KVER="${KERNEL_VERSION:-7.3-rc6}"
echo "=== [1/8] Download kernel $KVER ==="
# re-download if the cached tree is a different version (e.g. stable vs latest)
if [ ! -d linux-src ] || [ "$(cat linux-src/.kver 2>/dev/null)" != "$KVER" ]; then
  rm -rf linux-src linux-*.tar.*
  mkdir -p linux-src
  # stable releases live in v7.x/, release candidates in v7.x/testing/.
  # Download to a fixed temp name (avoids wget .1 suffixes and glob ambiguity).
  ( wget -q -O /work/linux-kernel.tar "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${KVER}.tar.xz" \
    || wget -q -O /work/linux-kernel.tar "https://cdn.kernel.org/pub/linux/kernel/v7.x/testing/linux-${KVER}.tar.xz" \
    || wget -q -O /work/linux-kernel.tar "https://git.kernel.org/torvalds/t/linux-${KVER}.tar.gz" ) || { echo "FATAL: kernel $KVER download failed"; exit 1; }
  tar xf /work/linux-kernel.tar -C linux-src --strip-components=1
  rm -f /work/linux-kernel.tar
  echo "$KVER" > linux-src/.kver
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
# NOTE: the SD image is assembled by scripts/build/repack.sh (the authoritative
# assembly with the official bootloader).  build.sh only prepares the kernel,
# rootfs, and U-Boot/FIP -- it must NOT write a second image here (that produced
# the duplicate 'radxa-zero-archlinux-linux-*.img' next to repack.sh's output).
echo "=== [8/8] Image assembly (handled by repack.sh) ==="

### Ship #####################################################################
# NOTE: the image + build info are written by scripts/build/repack.sh.  build.sh
# ends after preparing the kernel/rootfs/U-Boot; it no longer writes an image, so
# there is nothing to ship here.
echo "=== build.sh done (image handled by repack.sh) ==="
