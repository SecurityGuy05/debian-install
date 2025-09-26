#!/usr/bin/env bash
set -u pipefail

# Ensure we’re in the *installed* system context (late_command uses in-target).
export DEBIAN_FRONTEND=noninteractive

echo ">>> Updating /etc/apt/sources.list"

# Clear existing sources.list and replace with yours
cat >/etc/apt/sources.list <<'EOF'
# Main repository
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian trixie main contrib non-free non-free-firmware

# Security updates
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF


# Safety: refresh apt and ensure expected pkgs are present
apt-get update -y
apt-get install -y systemd sysvinit-utils nano curl wget ca-certificates ufw systemd-zram-generator unattended-upgrades


# --- UFW baseline ---
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
# Outbound HTTPS & SNMP
ufw allow out 443/tcp
ufw allow out 161/udp
ufw --force enable

# --- ZRAM swap (no disk swap to spare the eMMC) ---
install -d -m 0755 /etc/systemd
install -d -m 0755 /etc/systemd/zram-generator.conf.d || true
cat >/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-fraction = 0.5
max-zram-size = 1024
swap-priority = 100
EOF

systemctl daemon-reload
# service is a device; use swapon for reliability after boot then verify now:
if [ -e /dev/zram0 ]; then
  true
else
  # Let systemd create it on next boot; fine.
  :
fi

# --- Mild swappiness ---
echo 'vm.swappiness=20' >/etc/sysctl.d/99-swappiness.conf
sysctl --system || true

# --- Journal size caps ---
install -d -m 0755 /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/size.conf <<'EOF'
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
EOF
systemctl restart systemd-journald || true

# --- Unattended upgrades ---
apt-get install -y unattended-upgrades
dpkg-reconfigure --priority=low unattended-upgrades

# --- Tailscale (optional unattended join via AUTH KEY) ---
# If you have an auth key, export it before install or bake it here (least safe).
# Example: TS_AUTHKEY="tskey-abc..." tailscale up --authkey=${TS_AUTHKEY} --ssh
curl -fsSL https://tailscale.com/install.sh | sh
if [ -n "${TS_AUTHKEY:-}" ]; then
  # You can also pin to an ACL tag: --advertise-tags=tag:wyse
  tailscale up --authkey="${TS_AUTHKEY}" --ssh || true
else
  # No key? Bring the service up; you can auth later with 'tailscale up'
  systemctl enable --now tailscaled
fi

# --- Remove CD-ROM APT source just in case ---
sed -i '/cdrom:/d' /etc/apt/sources.list || true

# --- Blacklist USB mass storage (prevents auto-mount/driver load) ---
echo "blacklist usb_storage" >/etc/modprobe.d/blacklist-usb-storage.conf
update-initramfs -u

# Ready.
echo "Postinstall complete." > /root/POSTINSTALL_DONE
