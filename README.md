# Radxa Zero — Arch Linux Image Builder

Build a bootable **Arch Linux ARM** image for the [Radxa Zero](https://wiki.radxa.com/Zero) single-board computer (Amlogic S905Y2) with a **vanilla mainline Linux kernel** and **headless, Raspberry Pi–style first boot**.

Configure WiFi, SSH, the default user, hostname and timezone by dropping one plain-text **`config.txt`** onto the boot partition from Windows — **no monitor, keyboard, or serial adapter required**.

## Highlights

- **Vanilla mainline kernel** (Armbian `linux-meson64-edge` config) — the version is resolved from kernel.org at build time, so the image tracks mainline automatically; no vendor BSP blobs
- **Official Radxa bootloader** (BootROM-compatible, signed)
- **Arch Linux ARM** rootfs (AArch64, `pacman` ready)
- **Headless first-boot config** — one `config.txt` on the BOOT partition (WiFi / SSH / user with hashed password / hostname / timezone), applied on first boot and then deleted
- **USB gadget console** — the USB-C OTG port enumerates as a USB NIC (NCM, `192.168.100.1`, built-in DHCP server) **and** as a serial console (ACM, `ttyGS0`, with login prompt)
- **WiFi + Bluetooth** firmware for the onboard AP6212 (BCM43430) module
- **Panfrost GPU**, HDMI + audio, HW video decode (H.264/HEVC/VP9)

## What's in the image

| Component | Details |
|---|---|
| Bootloader | Official Radxa bootloader + `extlinux` (distro boot) |
| Kernel | Vanilla mainline Linux — version auto-resolved from kernel.org (`latest` / `stable`) |
| Device tree | `amlogic/meson-g12a-radxa-zero.dtb` |
| Rootfs | Arch Linux ARM (AArch64) + `wpa_supplicant` + `sudo` |
| Boot config | `BOOT/config.txt` — unified first-boot settings, applied then deleted |
| USB | NCM network + ACM serial composite gadget |
| WiFi / BT | AP6212 module (BCM43430 WiFi / BCM43438A1 Bluetooth) |

## Headless configuration

After flashing, open the **BOOT** partition (FAT32, editable in Notepad) and edit `config.txt`: one `key=value` per line, `#` starts a comment.

| Key | Effect |
|---|---|
| `hostname=radxa-zero` | System hostname |
| `timezone=Asia/Shanghai` | `/etc/localtime` |
| `ssh=1` | Generate SSH host keys and enable `sshd` (the shipped template sets `ssh=1`; use `ssh=0` to keep it off) |
| `wifi_ssid=MyNetwork` | WiFi SSID |
| `wifi_country=CN` | WiFi regulatory country |
| `wifi_psk=...` | WiFi passphrase, or the raw 64-hex PSK (64-hex is written unquoted) |
| `username=xg` | Rename the shipped `alarm` (uid 1000) user — or create that user if absent |
| `password_hash=$6$...` | SHA-512 crypt hash for that user (`openssl passwd -6`); never plaintext |

Example `config.txt`:
```ini
hostname=radxa-zero
timezone=Asia/Shanghai
ssh=1
wifi_ssid=your-wifi-ssid
wifi_country=CN
wifi_psk=your-wifi-password
username=xg
password_hash=$6$...
```

Generate the password hash on any Linux/macOS machine or in Git Bash:
```bash
openssl passwd -6 'your-password'
```

Notes:
- `config.txt` is **consumed and deleted on first boot** so credentials don't linger on the FAT partition. Drop a new `config.txt` on BOOT and reboot to apply it again.
- Set `password_hash` whenever you set `username`: without it the renamed user keeps the base image's default password (and a newly created account has no usable password).
- The configured user is added to `wheel,video,render,uucp,input,netdev`; sudo works through the `wheel` sudoers entry.
- BOOT is also mounted at `/boot/firmware` at runtime.
- `config.txt` here is the image's first-boot settings file (applied by `boot-config-apply.service`), **not** the Raspberry Pi firmware boot config — kernel arguments live in `extlinux/extlinux.conf`.

### First-boot improvements (automatic)

- **Applies `config.txt`** — timezone, hostname, SSH (fresh host keys), WiFi, user/password hash — then deletes the file.
- **Partition auto-expand** — the root partition + filesystem grow to fill the whole SD card on first boot (`expand-rootfs.service`, non-interactive `sfdisk` + `partx` + `resize2fs`; always succeeds silently so the system never enters `degraded`).
- **Pacman keyring self-heal** — `pacman-key --init && pacman-key --populate archlinuxarm` runs at build time where possible; the first-boot hook repeats it offline-safe so `pacman -Syu` never fails with "unknown trust".

## Getting started

### 1. Flash
```bash
xz -dc radxa-zero-archlinux-*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
```
Or use [balenaEtcher](https://etcher.balena.io) on Windows/macOS.

### 2. Configure
Pop the SD card back into your PC, edit `BOOT/config.txt` (WiFi / SSH / user), then eject.

### 3. Connect (any of these)
- **USB serial** — plug the USB-C **OTG** port into your PC; a COM port appears (115200 8N1). Log in as `root` / `root`.
- **USB network SSH** — the same cable also shows a USB NIC with a built-in DHCP server: the PC gets `192.168.100.x` automatically, then `ssh xg@192.168.100.1` (use the user you configured — password SSH for `root` is disabled by default). Zero-config fallback (no DHCP, no admin rights needed): `ssh xg@169.254.31.200` (APIPA link-local). Or set your PC statically to `192.168.100.2/24`.
- **WiFi SSH** — find `radxa-zero` in your router's DHCP list, then `ssh xg@<ip>`.

> **Note:** v0.1.8 and earlier releases do not enable the USB serial login prompt (the gadget itself works). v0.1.9 and later enable `serial-getty@ttyGS0`; on older images use the USB NIC + SSH.

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

The finished image is written to `/work/radxa-zero-archlinux-*.img.xz` (mounted from `rz-build`); the filename carries the detected kernel release.

**Kernel version is not pinned.** `build.sh` reads [`https://www.kernel.org/releases.json`](https://www.kernel.org/releases.json) at build time:

- `KERNEL_CHANNEL=latest` (default) — newest **mainline** release, including `-rc` kernels
- `KERNEL_CHANNEL=stable` — newest **stable** point release

```bash
# follow the stable channel instead of mainline
docker run --rm -e KERNEL_CHANNEL=stable \
  -v rz-build:/work -v "$PWD":/host:ro \
  rz-builder bash /host/build-all.sh
```

For a reproducible/pinned build only, set `-e KERNEL_VERSION=7.3` (or any version). The CI build matrix runs both channels automatically on every release tag.

## Project layout

The stage scripts are grouped by function under `scripts/`:

| Path | Purpose |
|---|---|
| `build-all.sh` | **Entry point** — runs every stage in dependency order |
| `scripts/build/` | Image pipeline — `build.sh` (kernel + rootfs + firmware + U-Boot/FIP), `inspect-official.sh` (extracts the official Radxa bootloader → `official-bootloader.img`, **required: only the Radxa-signed BL2+FIP layout boots**), `initramfs.sh`, `repack.sh` (assemble the SD image, verify BL2/FIP placement) |
| `scripts/config/` | Rootfs config — `rootfs-setup.sh` (base system: packages / keyring / zsh shell / network / sudoers / partition expand), `firstboot-config.sh` (installs the `BOOT/config.txt` first-boot hook), `wifi-firmware-fix.sh` |
| `scripts/usb/` | USB gadget — `usb-gadget-composite.sh` (NCM + ACM composite, used by the build; `usb-serial.sh` / `usb-console-fix.sh` are older single-function variants) |
| `scripts/debug/` | Diagnostics — `led-boot-status.sh`, `capture-panic.sh`, `pstore-ramoops.sh` |
| `Dockerfile` | Cross-toolchain build container |
| `AGENTS.md` | Hard constraints for agents/humans changing the repository |

## Hardware support (mainline)

- **GPU** — Panfrost (Mali G31, OpenGL/ES)
- **Display** — DRM meson + HDMI (with audio)
- **WiFi** — `brcmfmac` (BCM43430 firmware included)
- **Bluetooth** — `hci_uart_bcm` (BCM43438A1 firmware included)
- **Video decode** — H.264 / HEVC / VP9 (V4L2 stateless, `meson-vdec`)
- **USB** — DWC2 (gadget) + DWC3 (host); SD / eMMC; UART / I2C / SPI / PWM / ADC; Amlogic crypto engine

> Mainline has **no hardware video encoding**. Kernel arguments live in `extlinux/extlinux.conf`; there is no Raspberry Pi firmware stage. (`BOOT/config.txt` is only the first-boot settings file described above.)

## WiFi module variants

The Radxa Zero ships with one of three WiFi modules. All are supported (firmware + nvram included):

| Module | WiFi chip | Bluetooth chip |
|---|---|---|
| AP6212 | BCM43430 | BCM43438A1 |
| AP6256 | BCM43456 | BCM4345C0 |
| AW-CM256SM | BCM43455 | BCM4345C0 |

## Notes

- Only the **USB-C OTG** port provides the gadget (serial + network); the other USB-C is host-only. Use a **data** cable.
- SSH is enabled by the shipped `config.txt` template (`ssh=1`); set `ssh=0` or remove the key to keep it disabled. SSH host keys are regenerated on first boot.
- Default credentials: `root` / `root` on the local and USB serial console. Over SSH, log in as the user you configured — `root` password login is disabled by default (root key login works once you install a key).
