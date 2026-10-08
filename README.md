# Radxa Zero — Arch Linux Image Builder

Build a bootable **Arch Linux ARM** image for the [Radxa Zero](https://wiki.radxa.com/Zero) single-board computer (Amlogic S905Y2) with a **vanilla mainline Linux kernel** and **Raspberry Pi–style headless configuration**.

Configure WiFi, SSH, and the default user by dropping plain-text files onto the boot partition from Windows — **no monitor, keyboard, or serial adapter required**.

## Highlights

- **Vanilla mainline kernel** (Armbian `linux-meson64-edge` config) — no vendor BSP blobs
- **Official Radxa bootloader** (BootROM-compatible, signed)
- **Arch Linux ARM** rootfs (AArch64, `pacman` ready)
- **Raspberry Pi–style headless config** — `wpa_supplicant.conf` / `ssh` / `userconf.txt` on the boot partition (real `raspberrypi-net-mods` / `raspberrypi-sys-mods` / `userconf-pi` code, minimally ported)
- **USB gadget console** — the USB-C OTG port enumerates as a USB NIC (NCM, `192.168.100.1`) + a serial console (ACM)
- **WiFi + Bluetooth** firmware for the onboard AP6212 (BCM43430) module
- **Panfrost GPU**, HDMI + audio, HW video decode (H.264/HEVC/VP9)

## What's in the image

| Component | Details |
|---|---|
| Bootloader | Official Radxa bootloader + `extlinux` (distro boot) |
| Kernel | Vanilla mainline Linux (Armbian meson64-edge config) |
| Device tree | `amlogic/meson-g12a-radxa-zero.dtb` |
| Rootfs | Arch Linux ARM (AArch64) + `wpa_supplicant` + `sudo` |
| Boot config | Raspberry Pi–style files on the FAT `BOOT` partition |
| USB | NCM network + ACM serial composite gadget |
| WiFi / BT | AP6212 module (BCM43430 WiFi / BCM43438A1 Bluetooth) |

## Headless configuration

After flashing, open the **BOOT** partition (FAT32, editable in Notepad). Three files control first-boot setup:

| File | Effect | Source mechanism |
|---|---|---|
| `wpa_supplicant.conf` | Connect to WiFi on boot | `raspberrypi-net-mods` `wpa_copy` |
| `ssh` (or `ssh.txt`, empty) | Enable SSH (off by default) | `raspberrypi-sys-mods` `sshswitch` |
| `userconf.txt` | Line 1 = `username:password`, renames the default `alarm` user | `userconf-pi` `userconf` |

**WiFi example** (`wpa_supplicant.conf`):
```
country=CN
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
network={
    ssid="your-wifi-ssid"
    psk="your-wifi-password"
}
```

**User example** (`userconf.txt`, first line):
```
bob:my-password
```
(Plain text or a `openssl passwd -6` hash; the user is added to the `wheel` group for `sudo`.)

The files are consumed on first boot (deleted afterwards, same as a real Raspberry Pi) so credentials don't linger on the FAT partition.

## Getting started

### 1. Flash
```bash
xz -dc radxa-zero-archlinux-*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
```
Or use [balenaEtcher](https://etcher.balena.io) on Windows/macOS.

### 2. Configure
Pop the SD card back into your PC, edit the BOOT partition files (WiFi / `ssh` / `userconf.txt`), then eject.

### 3. Connect (any of these)
- **USB serial** — plug the USB-C **OTG** port into your PC; a COM port appears (115200 8N1). Log in as `root` / `root`.
- **USB network SSH** — the same cable also shows a USB NIC; set your PC to `192.168.100.2/24`, then `ssh root@192.168.100.1`.
- **WiFi SSH** — find `radxa-zero` in your router's DHCP list, then `ssh root@<ip>`.

## Building from source

The build runs inside a Docker container with an AArch64 cross-toolchain.

```bash
# 1. Build the toolchain container
docker build -t rz-builder .

# 2. Run the full image build
docker run --rm \
  -v rz-build:/work \
  -v "$PWD":/host:ro \
  rz-builder bash /host/build-all.sh
```

The finished image is written to `/work/radxa-zero-archlinux-<kernel-version>.img.xz` (mounted from `rz-build`). The kernel version in the filename is **auto-detected** from the build (`make kernelrelease`), e.g. `radxa-zero-archlinux-7.3.0-rc6.img.xz` — so when you bump the kernel version, the image name updates automatically and each build is easy to tell apart.

The GitHub Actions workflow also picks up the kernel version and uses it in the artifact and release names (e.g. *Radxa Zero Arch Linux (kernel 7.3.0-rc6)*).

## Project layout

| Script | Purpose |
|---|---|
| `build-all.sh` | **Entry point** — runs the full build in order |
| `build.sh` | Base build: kernel, Arch rootfs, firmware, U-Boot/FIP |
| `inspect-official.sh` | Extract the official Radxa bootloader (BootROM-compatible) |
| `wifi-setup.sh` | Install packages + Raspberry Pi–style boot-partition config |
| `port-pi.sh` | Port the real Pi `wpa_copy` / `sshswitch` / `userconf` scripts + units |
| `wifi-firmware-fix.sh` | WiFi firmware for the three possible WiFi modules |
| `usb-gadget-composite.sh` | USB NCM network + ACM serial composite gadget |
| `usb-console-fix.sh` / `usb-serial.sh` | USB serial console helpers |
| `led-boot-status.sh` | Boot-status LED (no-peripheral debugging) |
| `pstore-ramoops.sh` / `capture-panic.sh` | Optional: capture kernel panic logs without a console |
| `repack.sh` | Assemble the final SD card image |
| `Dockerfile` | Cross-toolchain build container |

## Hardware support (mainline)

- **GPU** — Panfrost (Mali G31, OpenGL/ES)
- **Display** — DRM meson + HDMI (with audio)
- **WiFi** — `brcmfmac` (BCM43430 firmware included)
- **Bluetooth** — `hci_uart_bcm` (BCM43438A1 firmware included)
- **Video decode** — H.264 / HEVC / VP9 (V4L2 stateless, `meson-vdec`)
- **USB** — DWC2 (gadget) + DWC3 (host); SD / eMMC; UART / I2C / SPI / PWM / ADC; Amlogic crypto engine

> Mainline has **no hardware video encoding**. `config.txt` / `cmdline.txt` are Raspberry Pi firmware conventions and don't apply here — kernel arguments live in `extlinux/extlinux.conf`.

## WiFi module variants

The Radxa Zero ships with one of three WiFi modules. All are supported (firmware + nvram included):

| Module | WiFi chip | Bluetooth chip |
|---|---|---|
| AP6212 | BCM43430 | BCM43438A1 |
| AP6256 | BCM43456 | BCM4345C0 |
| AW-CM256SM | BCM43455 | BCM4345C0 |

## Notes

- Only the **USB-C OTG** port provides the gadget (serial + network); the other USB-C is host-only. Use a **data** cable.
- SSH is disabled by default (Raspberry Pi semantics): drop an empty `ssh` file on BOOT to enable it.
- Default credentials: `root` / `root` (or the user you create via `userconf.txt`).
