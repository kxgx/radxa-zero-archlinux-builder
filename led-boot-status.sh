#!/bin/bash
# Boot-status LED for the Radxa Zero (no-peripheral debugging).
# The power LED is a GPIO LED (Radxa HW docs): GPIOAO_8 on v1.4 boards,
# GPIOAO_10 on v1.51 boards.  The mainline DT has no leds node, so add one for
# both pins (whichever matches the board lights up).
#   blink (heartbeat) = kernel running   |   solid (default-on) = system ready
set -euo pipefail
exec > >(tee -a /work/led-boot-status.log) 2>&1
echo "=== led-boot-status $(date -u) ==="
R=/work/rootfs

cd /work/linux-src
DTS=arch/arm64/boot/dts/amlogic/meson-g12a-radxa-zero.dts
if ! grep -q 'gpio-leds' "$DTS"; then
  cat >> "$DTS" <<'EOF'

/* Radxa Zero power LED is GPIO-driven (see Radxa HW docs):
 * v1.4 -> GPIOAO_8, v1.51 -> GPIOAO_10.  Add both; the one matching the board
 * lights up.  heartbeat = kernel alive (switched to default-on when ready). */
/ {
	leds {
		compatible = "gpio-leds";

		power-ao8 {
			gpios = <&gpio_ao GPIOAO_8 GPIO_ACTIVE_HIGH>;
			linux,default-trigger = "heartbeat";
		};

		power-ao10 {
			gpios = <&gpio_ao GPIOAO_10 GPIO_ACTIVE_HIGH>;
			linux,default-trigger = "heartbeat";
		};
	};
};
EOF
fi
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- dtbs
echo "dtb rebuilt (leds added, heartbeat = kernel alive)"

# NOTE: no "ready" service - the LED stays in heartbeat (blink) as long as the
# kernel runs.  Blink = kernel alive, dark = kernel died/crashed.  This makes the
# LED an unambiguous liveness indicator (polarity-independent).
rm -f "$R/usr/local/bin/led-ready" \
      "$R/etc/systemd/system/led-ready.service" \
      "$R/etc/systemd/system/multi-user.target.wants/led-ready.service"

echo "--- dtb leds:"; grep -A20 'gpio-leds' "$DTS" | head -22
echo "=== led-boot-status done ==="
