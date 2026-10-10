#!/bin/bash
# The Radxa Zero ships with 3 WiFi modules (AP6212/BCM43438, AP6256/BCM43456,
# AW-CM256SM/BCM43455). brcmfmac loads brcmfmac<chip>-sdio.<machine>.txt first,
# then falls back to the generic brcmfmac<chip>-sdio.txt. 43430/43455 only have
# board-specific nvram, so add the generic fallback so WiFi works on any module.
set -euo pipefail
exec > >(tee -a /work/wifi-firmware-fix.log) 2>&1
echo "=== wifi-firmware-fix $(date -u) ==="
FW=/work/rootfs/usr/lib/firmware/brcm

[ -f "$FW/brcmfmac43430-sdio.txt" ] || cp "$FW/brcmfmac43430-sdio.AP6212.txt" "$FW/brcmfmac43430-sdio.txt"
[ -f "$FW/brcmfmac43455-sdio.txt" ] || cp "$FW/brcmfmac43455-sdio.AW-CM256SM.txt" "$FW/brcmfmac43455-sdio.txt"
# 43456 generic .txt already present (added earlier)

# also provide the board-specific name brcmfmac tries first
for c in 43430 43455 43456; do
  if [ -f "$FW/brcmfmac${c}-sdio.txt" ]; then
    cp -n "$FW/brcmfmac${c}-sdio.txt" "$FW/brcmfmac${c}-sdio.radxa,zero.txt" 2>/dev/null || true
  fi
done

# BT firmware for AP6212 (BCM43438) if the .hcd is available in linux-firmware
if [ ! -f "$FW/BCM43438A1.hcd" ] && [ -f "$FW/bcm43438-sdio.hcd" ]; then
  cp "$FW/bcm43438-sdio.hcd" "$FW/BCM43438A1.hcd" 2>/dev/null || true
fi

echo "--- WiFi nvram (generic .txt present for each variant):"
ls "$FW" | grep -E "sdio\.txt|radxa,zero" || true
echo "=== wifi-firmware-fix done ==="
