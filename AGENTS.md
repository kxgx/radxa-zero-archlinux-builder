# AGENTS.md — Radxa Zero Arch Linux Image Builder

Guidance for agents (and humans) changing this repository without breaking the
bootable image or regressing driver/firmware support.

**Repo purpose:** build a bootable **Arch Linux ARM** SD image for the
[Radxa Zero](https://wiki.radxa.com/Zero) (Amlogic S905Y2 / G12A) with a
**vanilla mainline kernel**, official Radxa-signed bootloader, and a
single-file (`BOOT/config.txt`) headless first-boot config.

**Baseline (as of v0.1.9 / `main`):** kernel version **resolved from
kernel.org at build time** (`KERNEL_CHANNEL=latest` = newest mainline, incl.
`-rc`; `stable` = newest stable point release — no pinned version in the repo),
Armbian `linux-meson64-edge.config`, DTB `meson-g12a-radxa-zero.dtb`, official
Radxa Debian `b23` bootloader.

---

## 1. Hard red lines (do not break)

| ID | Rule | Why |
|----|------|-----|
| **R1** | Do **not** change bootloader extraction/write (`inspect-official.sh`, `repack.sh` BL2+FIP `dd` + verify). | S905Y2 BootROM only accepts a **Radxa-signed BL2 head @ sector 0 + FIP @ sector 1**. Wrong layout = unbootable (v0.1.4 CI incident). |
| **R2** | Do **not** change partition offsets or `extlinux.conf` `fdt`/`append` lines unless the task is exactly that. | Working on the device now. |
| **R3** | Do **not** merge or copy large chunks from `wip-fixes`. | That branch is mid-bisect of a ~2s boot failure and renames stages. |
| **R4** | Do **not** hardcode kernel versions (in `build.sh` or the CI matrix). The version is resolved from `https://www.kernel.org/releases.json`: `KERNEL_CHANNEL=latest` (mainline, incl. `-rc`) or `stable`. `KERNEL_VERSION=<ver>` is an explicit pin for reproducible/bisect builds only. Do not change the Armbian config URL without an explicit task. | The image must follow mainline as it advances; pinned versions go stale (v0.1.9 still built 7.2.9 / 7.3-rc6 while 7.3 / 7.2.12 were current). |
| **R5** | Device tree: **append-only**. Never delete/rewrite existing nodes. | Precedent: `scripts/debug/led-boot-status.sh`. A bad DTS drop kills GPU/UART/mmc. |
| **R6** | Do not remove `set -euo pipefail` to “make it pass”. Use `if` / explicit `\|\| true`. | The pipeline relies on `set -e` to catch errors. |
| **R7** | Do not make mainline U-Boot the default bootloader. | BootROM rejects it; `repack.sh` hard-fails without official BL. |
| **R8** | Firmware must be **sha256-verified**. Never install a same-named blob from a different crystal/board. | RPi 37.4 MHz `.hcd` ≠ AP6212 26 MHz `.hcd`. |
| **R9** | Do **not** treat armbian `brcm/BCM43430A1.hcd` as a real firmware blob. | It is a **~24-byte dedup pointer**, not the firmware. |
| **R10** | `scripts/build/build.sh` firmware edits must stay inside the **`### 5. Firmware extras`** block (ends before `### 6.`). | Below that is U-Boot/FIP — covered by R1. |
| **R11** | Keep `serial-getty@ttyGS0` enabled in `scripts/usb/usb-gadget-composite.sh`. | The ACM function alone gives the PC a **COM port with no login prompt** (v0.1.8 and earlier shipped that way). |

---

## 2. Architecture (what runs where)

```
build-all.sh
  ├─ scripts/build/inspect-official.sh   # official Radxa bootloader only
  ├─ scripts/build/build.sh              # kernel(version from kernel.org) + rootfs + FIRMWARE + U-Boot/FIP
  ├─ scripts/config/rootfs-setup.sh      # pacman packages, keyring, users, net
  ├─ scripts/config/firstboot-config.sh  # config.txt → wifi/ssh/user/hostname
  ├─ scripts/config/wifi-firmware-fix.sh # WiFi nvram names
  ├─ scripts/usb/usb-gadget-composite.sh # NCM + ACM gadget + serial-getty@ttyGS0
  ├─ scripts/debug/led-boot-status.sh    # DTS append gpio-leds + make dtbs
  ├─ scripts/build/initramfs.sh
  └─ scripts/build/repack.sh             # AUTHORITATIVE SD image assembly
```

- Image assembly is **only** in `repack.sh`. `build.sh` must not write an image.
- Kernel config is **fetched** (Armbian `linux-meson64-edge.config`), not vendored.
- Firmware comes from sparse `armbian/firmware` + selected downloads; rootfs is
  generic Arch Linux ARM **without** `linux-firmware*` packages.
- DTB is built from mainline DTS, then **optional append patches**, then
  copied to BOOT by `repack.sh`.
- Kernel arguments live in `extlinux/extlinux.conf`. `BOOT/config.txt` is only
  the first-boot settings file consumed by `boot-config-apply.service`.
- `usb-serial.sh` / `usb-console-fix.sh` are legacy single-function variants;
  the build calls `usb-gadget-composite.sh` only.

---

## 3. Driver / firmware status (verified)

### Works out of the image (kernel side)
WiFi `brcmfmac` (BCM43430), GPU `panfrost` (Mali-G31), HDMI `meson-drm` +
audio, `meson-vdec` staging, SD `meson-gx-mmc`, USB gadget `dwc2` + host xHCI,
USB serial console (ACM `ttyGS0` login prompt) + NCM DHCP network, thermal,
watchdog, RTC, PWM, GPIO, SARADC, RNG, eFuse, CEC.

### Known gaps (build-level)

All items below are fixed in v0.1.8 except the USB serial one, fixed in v0.1.9.

| Gap | Root cause | Fix location |
|-----|------------|--------------|
| **BT `BCM43430A1.hcd` missing** | `build.sh` gated on `official-root.img` which **nothing ever creates**; fallback wrote wrong name `BCM43438A1.hcd` | `build.sh` §5 + delete alias block in `wifi-firmware-fix.sh` |
| **WiFi 43430/43455 blobs not copied** | Only 43456 is copied; `wifi-firmware-fix.sh` assumes nvram already in rootfs | `build.sh` §5 copy list |
| **meson VPU decode firmware** | `ls` check only; sparse-checkout is `brcm` only | `build.sh` §5 + `sparse-checkout set brcm meson` |
| **User not in device groups** | `useradd -G wheel` only; rename path never adds groups | `firstboot-config.sh` |
| **No bluez/mesa** | Not in pacman list | `rootfs-setup.sh` best-effort list |
| **USB serial: no login prompt** | `usb-gadget-composite.sh` creates the ACM tty but never enabled `serial-getty@ttyGS0` | `usb-gadget-composite.sh` (fixed in v0.1.9) |

### Non-gaps (do not “fix”)
- `panfrost: no regulator (mali)` — board has no dedicated GPU rail; GPU still works.
- MDIO deferred probe — no onboard Ethernet.
- `ttyS0`–`ttyS7` — 8250 placeholders, not real UARTs.
- No hardware video **encode** on mainline.

---

## 4. Bluetooth firmware — single source of truth

Kernel `btbcm` request order for this board:

```
brcm/BCM43430A1.radxa,zero.hcd
brcm/BCM43430A1.hcd          ← install THIS name
brcm/BCM.radxa,zero.hcd
brcm/BCM.hcd
```

| Field | Value |
|-------|-------|
| **URL** | `https://raw.githubusercontent.com/radxa/firmware/master/ap6212/bcm43438a1.hcd` |
| **sha256** | `d396912aa4efa7e0ea93dc6b63b1088619b59676ab53404d14fe79f5c71a5da0` |
| **size** | `33376` |
| **Identity in blob** | `BCM43438A1 26MHz AP6212A1_CL1 BT4.0 OTP-BD-0034` |
| **Install path** | `usr/lib/firmware/brcm/BCM43430A1.hcd` |

**Forbidden substitutes:**
- RPi 3 blobs (37.4 MHz), e.g. sha256 `591b2279…` / `c096ad4a…`
- armbian `brcm/BCM43430A1.hcd` — **pointer**, not a blob (R9)
- armbian `brcm/bcm43438-sdio.hcd` — different variant (`BCM4343A0`)
- Any file named `BCM43438A1.hcd` — **the kernel never requests this name**

**License:** proprietary Broadcom. Prefer also shipping `BCM-LEGAL.txt`
(RPi-Distro `bluez-firmware`). Mainline `linux-firmware` will never include this.

---

## 5. Allowed edit map (driver completion work)

Change **only** these when implementing the driver/firmware checklist:

| File | Allowed window | Must do | Must not |
|------|----------------|---------|----------|
| `scripts/build/build.sh` | `### 5. Firmware extras` block only | BT hcd + sha256; WiFi 43430/43455/43456 real blobs (skip &lt;100B pointers); `meson/vdec` copy; end-of-section assert | Touch kernel ver/config URL/FIP; edit outside §5 |
| `scripts/config/wifi-firmware-fix.sh` | nvram fallback `cp` guards; the BT block | Guard `cp` with source-exists (V9: `set -e` aborts); keep BT install in `build.sh` §5 | Re-add a BT alias block with a wrong name; break `radxa,zero` nvram fallback |
| `scripts/config/firstboot-config.sh` | user create/rename block only | Add groups on **both** `useradd` **and** rename `usermod -aG` paths | Touch password/wpa/ssh/hostname |
| `scripts/config/rootfs-setup.sh` | pacman best-effort list only | Append `bluez bluez-utils mesa` keeping `\|\| true` | Extend the hardcoded wpa/sudo ladder |
| `scripts/usb/usb-gadget-composite.sh` | serial-getty enable only | Keep `serial-getty@ttyGS0` enabled (R11) | Remove/rename the getty; break the NCM DHCP config |

**Do not touch:** `inspect-official.sh`, `repack.sh`, `initramfs.sh`,
`led-boot-status.sh`, `build-all.sh`, `Dockerfile`.

### Device groups to grant
`wheel,video,render,uucp,input,netdev`
(`netdev` already exists via `rootfs-setup.sh`; add the user to it.)

---

## 6. Implementation order (do not skip)

1. `build.sh` §5 only → `bash -n scripts/build/build.sh`
2. `wifi-firmware-fix.sh` → `bash -n`
3. `git diff` review: no bootloader/FIP/overshoot
4. `firstboot-config.sh` (both group paths) → `bash -n`
5. `rootfs-setup.sh` package list → `bash -n`
6. One commit per file (or per logical item), message cites item IDs
7. Docker build if available; at minimum syntax + logic review

---

## 7. Verification checklist (run after changes)

- [ ] `bash -n` on every edited script (CI runs it on all `git ls-files '*.sh'`)
- [ ] Kernel: no pinned version in `build.sh` / CI matrix; `build.sh` logs the
      kernel.org channel + resolved version
- [ ] `git diff` touches only the allowed files
- [ ] BT: `BCM43430A1.hcd` present in rootfs + sha256 matches the table above
- [ ] No `BCM43438A1.hcd` written anywhere
- [ ] WiFi: generic + board nvram for 43430/43455/43456 present
- [ ] `firmware-repo` sparse includes `meson` if vdec firmware is copied
- [ ] `wifi-firmware-fix` cannot abort on a clean tree (source-guarded `cp`)
- [ ] New user groups present on the **rename** path as well as `useradd`
- [ ] `repack.sh` / bootloader bytes untouched
- [ ] USB: `serial-getty@ttyGS0.service` enabled by `usb-gadget-composite.sh`
- [ ] CI `checks` job covers **all** tracked `*.sh`, not just the root ones
- [ ] Build log has no `WARN: bcm43438a1.hcd not found` / missing vdec

---

## 8. Useful commands

```bash
# Local syntax check on every tracked shell script (same as CI)
while IFS= read -r f; do bash -n "$f" || echo "FAIL: $f"; done < <(git ls-files '*.sh')

# ShellCheck at error level (CI severity)
while IFS= read -r f; do shellcheck --severity=error "$f"; done < <(git ls-files '*.sh')

# Full image build (kernel version resolved from kernel.org: latest mainline)
docker build -t rz-builder .
docker run --rm -v rz-build:/work -v "$PWD":/host:ro rz-builder bash /host/build-all.sh

# Same, but follow the stable channel / pin a version for bisecting
docker run --rm -e KERNEL_CHANNEL=stable -v rz-build:/work -v "$PWD":/host:ro rz-builder bash /host/build-all.sh
docker run --rm -e KERNEL_VERSION=7.3 -v rz-build:/work -v "$PWD":/host:ro rz-builder bash /host/build-all.sh

# What build.sh will resolve right now
wget -qO- https://www.kernel.org/releases.json | python3 -c 'import json,sys; [print(r["moniker"], r["version"], r["source"]) for r in json.load(sys.stdin)["releases"] if r["moniker"] in ("mainline", "stable")]'

# Verify BT firmware after extract
sha256sum rootfs/usr/lib/firmware/brcm/BCM43430A1.hcd
# expect: d396912aa4efa7e0ea93dc6b63b1088619b59676ab53404d14fe79f5c71a5da0

# Verify the USB serial getty installs into the rootfs
ls rootfs/etc/systemd/system/multi-user.target.wants/ | grep serial-getty
# expect: serial-getty@ttyGS0.service
```

---

## 9. Gotchas

1. **`[ -f x ] || cp src dst` under `set -e` still aborts if `cp` fails.** Use an `if`.
2. **armbian/firmware board files are often 22-byte pointers.** Always
   `stat -c%s` and skip tiny files (already done for 43456).
3. **`useradd` is not the only user path.** First boot usually **renames** the
   shipped `alarm` uid-1000 user.
4. **Never “fix” BT by copying any `.hcd` that merely has BCM4343x in the name.**
   Crystal frequency matters; use the hash table.
5. **`official-root.img` does not exist.** Do not build features on it unless
   you also add a step that actually creates it (not recommended — prefer
   `radxa/firmware` download).
6. **A gadget COM port is not a console.** `acm.usb0` only creates
   `/dev/ttyGS0`; a login prompt needs `serial-getty@ttyGS0` enabled (R11).
   Verify it in the built rootfs before releasing — the v0.1.8 image shipped
   without it and looked like a "dead" serial console.
7. **kernel.org `releases.json` is the source of truth for the kernel version.**
   It also lists `longterm` and `linux-next`; only `mainline` / `stable` are
   used. The per-release `source` URL is authoritative (it already contains
   `v<major>.x/testing/` for `-rc` kernels) — do not hand-build paths, and do
   not re-pin a version in CI to “make the build stable”.

---

## 10. Related docs (local research)

If present next to a working tree:
- `docs/CHECKLIST.md` — full verified change list (v2)
- `docs/FILES.md` — short file-only change table

Keep AGENTS.md in sync when red lines or firmware hashes change.
