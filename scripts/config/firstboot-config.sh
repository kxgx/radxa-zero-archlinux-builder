#!/bin/bash
# Radxa Zero image: unified first-boot configuration from BOOT/config.txt.
#
# This REPLACES the Raspberry Pi scattered-file mechanism (wpa_supplicant.conf /
# userconf.txt / ssh) with a single config.txt that holds every setting.  The
# boot-config tool writes it; a first-boot hook applies it.  Secrets are hashed
# so no plaintext password is ever written to the FAT card.
#
# config.txt format (key=value, one per line, '#' comments):
#   hostname=radxa-zero
#   timezone=Asia/Shanghai
#   ssh=1
#   wifi_ssid=MyNetwork
#   wifi_country=CN
#   wifi_psk=<64-hex derived PSK>      # PBKDF2(passphrase, ssid); NOT plaintext
#   username=xg
#   password_hash=$6$<salt>$<hash>     # SHA-512 crypt; NOT plaintext
#
# The hook consumes (deletes) config.txt after applying so secrets don't linger.
set -euo pipefail
exec > >(tee -a /work/firstboot-config.log) 2>&1
echo "=== firstboot-config $(date -u) ==="

R=/work/rootfs

# ---- the first-boot applier ---------------------------------------------
cat > "$R/usr/local/bin/boot-config-apply" <<'HOOK'
#!/bin/sh
# Apply the unified boot configuration (config.txt) from the BOOT partition.
set -u
log() { echo "boot-config: $*"; }

BOOT=""
for d in /dev/mmcblk0p1 /dev/mmcblk1p1; do
  [ -b "$d" ] || continue
  [ "$(blkid -o value -s LABEL "$d" 2>/dev/null)" = "BOOT" ] && { BOOT="$d"; break; }
done
MNT=/run/boot-config
mkdir -p "$MNT"
[ -n "$BOOT" ] && mount -o rw "$BOOT" "$MNT" 2>/dev/null

CONF="$MNT/config.txt"
if [ ! -f "$CONF" ]; then
  log "no config.txt on BOOT; nothing to apply"
  umount "$MNT" 2>/dev/null
  exit 0
fi

# parse key=value safely (no shell eval)
CFG_HOST=""; CFG_TZ=""; CFG_SSH=""; CFG_SSID=""; CFG_PSK=""; CFG_CC=""; CFG_USER=""; CFG_PASSHASH=""
while IFS= read -r line; do
  case "$line" in \#*|"") continue;; esac
  key="${line%%=*}"; val="${line#*=}"
  case "$key" in
    hostname)      CFG_HOST="$val";;
    timezone)      CFG_TZ="$val";;
    ssh)           CFG_SSH="$val";;
    wifi_ssid)     CFG_SSID="$val";;
    wifi_psk)      CFG_PSK="$val";;
    wifi_country)  CFG_CC="$val";;
    username)      CFG_USER="$val";;
    password_hash) CFG_PASSHASH="$val";;
  esac
done < "$CONF"

# timezone
if [ -n "$CFG_TZ" ] && [ -e "/usr/share/zoneinfo/$CFG_TZ" ]; then
  ln -sf "/usr/share/zoneinfo/$CFG_TZ" /etc/localtime
  log "timezone -> $CFG_TZ"
fi

# hostname
if [ -n "$CFG_HOST" ]; then
  echo "$CFG_HOST" > /etc/hostname
  hostname "$CFG_HOST" 2>/dev/null || true
  log "hostname -> $CFG_HOST"
fi

# ssh (fresh host keys, then enable)
if [ "$CFG_SSH" = "1" ] || [ "$CFG_SSH" = "yes" ]; then
  rm -f /etc/ssh/ssh_host_* 2>/dev/null
  ssh-keygen -A >/dev/null 2>&1 || true
  systemctl enable --now --no-block sshd.service 2>/dev/null || true
  log "ssh enabled"
fi

# wifi -> wpa_supplicant (psk is the derived hex, or a passphrase)
if [ -n "$CFG_SSID" ]; then
  CC="${CFG_CC:-CN}"
  mkdir -p /etc/wpa_supplicant
  # A 64-hex PSK must be UNQUOTED (psk=<hex>, a raw key); a passphrase is quoted.
  if [ "${#CFG_PSK}" = "64" ]; then
    PSKLINE="    psk=$CFG_PSK"
  else
    PSKLINE="    psk=\"$CFG_PSK\""
  fi
  cat > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=$CC
network={
    ssid="$CFG_SSID"
$PSKLINE
}
EOF
  chmod 600 /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
  systemctl enable --now --no-block wpa_supplicant@wlan0.service 2>/dev/null || true
  log "wifi -> $CFG_SSID"
fi

# user (rename the default uid-1000 user if present, else create; set hash)
if [ -n "$CFG_USER" ]; then
  SHELL_BIN=/bin/bash
  command -v zsh >/dev/null 2>&1 && SHELL_BIN=/bin/zsh
  DEFAULT_USER="$(getent passwd 1000 | cut -d: -f1)"
  if [ -n "$DEFAULT_USER" ] && [ "$DEFAULT_USER" != "$CFG_USER" ]; then
    usermod -l "$CFG_USER" "$DEFAULT_USER" 2>/dev/null || true
    usermod -d "/home/$CFG_USER" -m "$CFG_USER" 2>/dev/null || true
  fi
  id -u "$CFG_USER" >/dev/null 2>&1 || useradd -m -G wheel -s "$SHELL_BIN" "$CFG_USER" 2>/dev/null || true
  usermod -s "$SHELL_BIN" "$CFG_USER" 2>/dev/null || true
  if [ -n "$CFG_PASSHASH" ]; then
    echo "$CFG_USER:$CFG_PASSHASH" | chpasswd -e 2>/dev/null || true
  fi
  log "user -> $CFG_USER"
fi

# consume config.txt so secrets don't linger on the card
rm -f "$CONF" 2>/dev/null
sync
umount "$MNT" 2>/dev/null || true
log "done"
HOOK
chmod +x "$R/usr/local/bin/boot-config-apply"

# ---- first-boot systemd unit --------------------------------------------
cat > "$R/etc/systemd/system/boot-config-apply.service" <<'UNIT'
[Unit]
Description=Apply unified boot configuration (config.txt)
After=systemd-udevd.service
Before=sshd.service wpa_supplicant@wlan0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/boot-config-apply

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/boot-config-apply.service \
  "$R/etc/systemd/system/multi-user.target.wants/boot-config-apply.service"

# mount the FAT BOOT partition at /boot/firmware (so config files are accessible)
mkdir -p "$R/boot/firmware"
grep -q '/boot/firmware' "$R/etc/fstab" 2>/dev/null || \
  echo '/dev/disk/by-label/BOOT  /boot/firmware  vfat  defaults,umask=0022  0  0' >> "$R/etc/fstab"

echo "--- installed ---"
ls -la "$R/usr/local/bin/boot-config-apply" "$R/etc/systemd/system/boot-config-apply.service"
echo "=== firstboot-config done ==="
