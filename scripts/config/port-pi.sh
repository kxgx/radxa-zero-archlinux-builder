#!/bin/bash
# Port the REAL Raspberry Pi OS boot-partition configuration mechanism into the Arch rootfs.
# Sources (verbatim logic, minimal Arch adaptation):
#   - raspberrypi-sys-mods: get_fw_loc, sshswitch, regenerate_ssh_host_keys
#   - userconf-pi: userconf, userconf-service
# Plus the classic Pi headless-WiFi mechanism (wpa_supplicant.conf on the boot partition).
set -euo pipefail
exec > >(tee -a /work/port-pi.log) 2>&1
echo "=== port-pi-mechanism $(date -u) ==="

R=/work/rootfs
mkdir -p "$R/usr/lib/raspberrypi-sys-mods" "$R/usr/lib/userconf-pi" \
         "$R/usr/lib/systemd/system" "$R/etc/systemd/system/multi-user.target.wants" \
         "$R/boot/firmware" "$R/etc/wpa_supplicant" "$R/etc/sudoers.d"

### 1. get_fw_loc (from raspberrypi-sys-mods; adapted: no dpkg on Arch) ###
cat > "$R/usr/lib/raspberrypi-sys-mods/get_fw_loc" <<'EOF'
#!/bin/sh
# Adapted from raspberrypi-sys-mods get_fw_loc (original uses dpkg for arch check)
if [ -r /etc/default/raspberrypi-sys-mods ]; then
  . /etc/default/raspberrypi-sys-mods
fi
if [ -z "$FWLOC" ]; then
  for FWLOC in /boot/firmware /boot NOT_FOUND; do
    if ( findmnt --fstab "$FWLOC" || findmnt "$FWLOC" ) > /dev/null; then
      break
    fi
  done
fi
echo "$FWLOC"
if [ "$FWLOC" = "NOT_FOUND" ]; then
  exit 1
fi
exit 0
EOF
chmod +x "$R/usr/lib/raspberrypi-sys-mods/get_fw_loc"

### 2. sshswitch (from raspberrypi-sys-mods; adapted ssh -> sshd) ###
cat > "$R/usr/lib/raspberrypi-sys-mods/sshswitch" <<'EOF'
#!/bin/sh
# Adapted from raspberrypi-sys-mods sshswitch (service name ssh -> sshd on Arch)
set -e
if ! FWLOC=$(/usr/lib/raspberrypi-sys-mods/get_fw_loc); then
  echo "Could not determine firmware partition" >&2
  exit 1
fi
FOUND=0
for file in "$FWLOC/ssh" "$FWLOC/ssh.txt"; do
  [ -e "$file" ] || continue
  FOUND=1
  rm -f "$file"
done
if [ "$FOUND" = "1" ]; then
  systemctl enable --now --no-block sshd
fi
exit 0
EOF
chmod +x "$R/usr/lib/raspberrypi-sys-mods/sshswitch"

### 3. regenerate_ssh_host_keys (from raspberrypi-sys-mods; run once) ###
cat > "$R/usr/lib/raspberrypi-sys-mods/regenerate_ssh_host_keys" <<'EOF'
#!/bin/sh
# Adapted from raspberrypi-sys-mods regenerate_ssh_host_keys (only if missing)
set -e
if ! ls /etc/ssh/ssh_host_*_key > /dev/null 2>&1; then
  ssh-keygen -A
fi
exit 0
EOF
chmod +x "$R/usr/lib/raspberrypi-sys-mods/regenerate_ssh_host_keys"

### 4. userconf (from userconf-pi; minus raspi-config desktop bits) ###
cat > "$R/usr/lib/userconf-pi/userconf" <<'EOF'
#!/bin/sh
# Adapted from userconf-pi userconf
rename_user () {
    usermod -l "$NEWNAME" "$FIRSTUSER"
    usermod -m -d "/home/$NEWNAME" "$NEWNAME"
    groupmod -n "$NEWNAME" "$FIRSTGROUP"
    for file in /etc/subuid /etc/subgid; do
        [ -f "$file" ] && sed -i "s/^$FIRSTUSER:/$NEWNAME:/" "$file"
    done
    if [ -f /etc/sudoers.d/010_pi-nopasswd ]; then
        sed -i "s/^$FIRSTUSER /$NEWNAME /" /etc/sudoers.d/010_pi-nopasswd
    fi
}
if [ $# -eq 3 ]; then
    FIRSTUSER="$1"
    FIRSTGROUP="$1"
    shift
else
    FIRSTUSER="$(getent passwd 1000 | cut -d: -f1)"
    FIRSTGROUP="$(getent group 1000 | cut -d: -f1)"
fi
NEWNAME=$1
NEWPASS=$2
if [ "$FIRSTUSER" != "$NEWNAME" ]; then
    rename_user
fi
usermod -s /bin/bash "$NEWNAME"
if [ -n "$NEWPASS" ]; then
    case "$NEWPASS" in
      \$*) echo "$NEWNAME:$NEWPASS" | chpasswd -e ;;
      *)   echo "$NEWNAME:$NEWPASS" | chpasswd ;;
    esac
fi
EOF
chmod +x "$R/usr/lib/userconf-pi/userconf"

### 5. userconf-service (from userconf-pi; non-interactive path only) ###
cat > "$R/usr/lib/userconf-pi/userconf-service" <<'EOF'
#!/bin/sh -e
# Adapted from userconf-pi userconf-service (non-interactive path; Pi adds a
# whiptail/raspi-config TTY wizard we drop for headless Arch)
if ! FWLOC=$(/usr/lib/raspberrypi-sys-mods/get_fw_loc 2> /dev/null); then
    FWLOC=/boot/firmware
fi
validate_user() {
    RET=0
    MSG="Entered username is invalid:"
    if [ -z "$NEW_USER" ] || [ ${#NEW_USER} -gt 32 ]; then
        MSG="$MSG\nLength must be between 1 and 32 characters."
        RET=1
    fi
    if ! echo "$NEW_USER" | grep -q '^[a-z][a-z0-9\-]*$'; then
        MSG="$MSG\nMust only contain lower-case letters, digits and hyphens, and start with a letter."
        RET=1
    fi
    if [ "$NEW_USER" = "root" ]; then
        MSG="$MSG\nCannot be root."
        RET=1
    fi
    if [ "$RET" -ne 0 ]; then
        echo "$MSG"
    fi
    return "$RET"
}
validate_password() {
    if [ -z "$NEW_PASS" ]; then
        echo "Password cannot be empty."
        return 1
    fi
}
for BOOT_CONF_FILE in "$FWLOC/userconf" "$FWLOC/userconf.txt"; do
    if [ ! -f "$BOOT_CONF_FILE" ]; then
        continue
    fi
    LINE="$(head -n1 "$BOOT_CONF_FILE" | tr -d '\r')"
    case "$LINE" in
        ''|'#'*) break ;;   # blank/comment line-1: leave the template for the user
    esac
    NEW_USER="$(echo "$LINE" | cut -f1 -d:)"
    NEW_PASS="$(echo "$LINE" | cut -f2 -d:)"
    if MSG=$(validate_user && validate_password); then
        /usr/lib/userconf-pi/userconf "$NEW_USER" "$NEW_PASS"
        rm -f "$BOOT_CONF_FILE"
    else
        echo "$MSG" >> "$BOOT_CONF_FILE" >&2
        mv "$BOOT_CONF_FILE" "$FWLOC/failed_$(basename "$BOOT_CONF_FILE")"
        sync
    fi
    break
done
rm -f "$FWLOC/failed_userconf" "$FWLOC/failed_userconf.txt"
exit 0
EOF
chmod +x "$R/usr/lib/userconf-pi/userconf-service"

### 6. wpa_copy (REAL code from raspberrypi-net-mods 1.3.4; minimal Arch adapt) ###
mkdir -p "$R/usr/lib/raspberrypi-net-mods"
cat > "$R/usr/lib/raspberrypi-net-mods/wpa_copy" <<'EOF'
#!/bin/sh
# REAL raspberrypi-net-mods wpa_copy (Bullseye 1.3.4). Minimal Arch adaptation:
#   /boot -> /boot/firmware (our FAT mount point)
#   raspi-config nonint do_wifi_country -> iw reg set
#   raspi-config nonint do_netconf 1    -> restart wpa_supplicant (systemd-networkd handles the rest)
set -e
mv /boot/firmware/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
chmod 600 /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
REGDOMAIN=$(sed -n 's/^\s*country=\(..\)$/\1/p' /etc/wpa_supplicant/wpa_supplicant-wlan0.conf)
[ -n "$REGDOMAIN" ] && iw reg set "$REGDOMAIN" 2>/dev/null || true
systemctl enable --now --no-block wpa_supplicant@wlan0.service 2>/dev/null || true
EOF
chmod +x "$R/usr/lib/raspberrypi-net-mods/wpa_copy"

### 7. systemd units (mirroring Pi's service layout) ###
cat > "$R/usr/lib/systemd/system/raspberrypi-sys-mods-regenerate_ssh_host_keys.service" <<'EOF'
[Unit]
Description=Regenerate SSH host keys if missing (Raspberry Pi mechanism)
After=boot-firmware.mount
Requires=boot-firmware.mount
Before=sshd.service sshswitch.service
ConditionPathExists=!/etc/ssh/ssh_host_rsa_key

[Service]
Type=oneshot
ExecStart=/usr/lib/raspberrypi-sys-mods/regenerate_ssh_host_keys

[Install]
WantedBy=multi-user.target
EOF

cat > "$R/usr/lib/systemd/system/raspberrypi-sys-mods-sshswitch.service" <<'EOF'
[Unit]
Description=Turn on SSH if /boot/firmware/ssh or /boot/ssh is present (Raspberry Pi mechanism)
After=regenerate_ssh_host_keys.service boot-firmware.mount
Requires=boot-firmware.mount

[Service]
Type=oneshot
ExecStart=/usr/lib/raspberrypi-sys-mods/sshswitch

[Install]
WantedBy=multi-user.target
EOF

cat > "$R/usr/lib/systemd/system/userconf-pi-userconfig.service" <<'EOF'
[Unit]
Description=User configuration from userconf.txt (Raspberry Pi mechanism)
After=boot-firmware.mount
Requires=boot-firmware.mount

[Service]
Type=oneshot
ExecStart=/usr/lib/userconf-pi/userconf-service

[Install]
WantedBy=multi-user.target
EOF

cat > "$R/usr/lib/systemd/system/raspberrypi-net-mods.service" <<'EOF'
[Unit]
Description=Copy user wpa_supplicant.conf (raspberrypi-net-mods)
ConditionPathExists=/boot/firmware/wpa_supplicant.conf
Before=wpa_supplicant@wlan0.service
After=systemd-rfkill.service boot-firmware.mount
Requires=boot-firmware.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/raspberrypi-net-mods/wpa_copy

[Install]
WantedBy=multi-user.target
EOF

# enable the four services
for s in raspberrypi-sys-mods-regenerate_ssh_host_keys \
         raspberrypi-sys-mods-sshswitch \
         userconf-pi-userconfig \
         raspberrypi-net-mods; do
  ln -sf "/usr/lib/systemd/system/$s.service" "$R/etc/systemd/system/multi-user.target.wants/$s.service"
done

### 8. mount the FAT BOOT partition at /boot/firmware (Bookworm-style) ###
grep -q '/boot/firmware' "$R/etc/fstab" 2>/dev/null || \
  echo '/dev/disk/by-label/BOOT  /boot/firmware  vfat  defaults,umask=0022  0  0' >> "$R/etc/fstab"

# wifi: DHCP on wlan*, sudo for wheel (kept from earlier build)
[ -f "$R/etc/systemd/network/25-wireless.network" ] || cat > "$R/etc/systemd/network/25-wireless.network" <<'EOF'
[Match]
Name=wlan*

[Network]
DHCP=yes
EOF
grep -q '^netdev:' "$R/etc/group" || echo 'netdev:x:976:' >> "$R/etc/group"
echo '%wheel ALL=(ALL:ALL) ALL' > "$R/etc/sudoers.d/10-wheel"
chmod 440 "$R/etc/sudoers.d/10-wheel"

### 9. retire my earlier hand-rolled services (superseded by the real Pi scripts) ###
rm -f "$R/etc/systemd/system/multi-user.target.wants/pi-bootcfg.service" \
      "$R/etc/systemd/system/pi-bootcfg.service" \
      "$R/usr/local/bin/pi-bootcfg.sh" \
      "$R/usr/lib/raspberrypi-sys-mods/wifi-config" \
      "$R/usr/lib/systemd/system/raspberrypi-sys-mods-wifi-config.service" \
      "$R/etc/systemd/system/multi-user.target.wants/raspberrypi-sys-mods-wifi-config.service"

# sshd OFF by default (Pi semantics)
rm -f "$R/etc/systemd/system/multi-user.target.wants/sshd.service"

echo "--- installed files ---"
ls -la "$R/usr/lib/raspberrypi-sys-mods" "$R/usr/lib/userconf-pi"
echo "=== port-pi-mechanism done ==="
