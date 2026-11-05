#!/usr/bin/env bash
# Bootstrap a fresh Ubuntu 22.04/24.04 server for the homelab stack.
#
# Runs automatically via cloud-init when the server is created with Terraform.
# On any other VPS (Hetzner, DigitalOcean, ...) run it manually as root:
#   DEPLOY_USER=deploy SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." bash bootstrap.sh
#
# The script is idempotent: running it again is safe.
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
STACK_DIR="${STACK_DIR:-/opt/homelab}"
SWAP_SIZE="${SWAP_SIZE:-2G}"

log() { echo "[bootstrap] $(date -u +%FT%TZ) $*"; }

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# --- Packages -----------------------------------------------------------------
log "Installing base packages"
apt-get update -y
apt-get install -y \
  ca-certificates curl gnupg git rsync jq \
  ufw fail2ban python3-systemd unattended-upgrades apache2-utils

# --- Docker Engine (official repository, not the outdated Ubuntu package) ------
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker Engine"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck source=/dev/null
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

log "Configuring Docker daemon (log rotation, live-restore)"
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
systemctl enable docker
systemctl restart docker

# --- Deploy user ----------------------------------------------------------------
log "Creating deploy user '${DEPLOY_USER}'"
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DEPLOY_USER"
fi
usermod -aG docker,sudo "$DEPLOY_USER"
# NOTE: membership in the docker group is already root-equivalent, so
# passwordless sudo adds no extra risk here. In production, split the CI user
# (docker only) and the human admin user (sudo).
echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${DEPLOY_USER}"
chmod 440 "/etc/sudoers.d/90-${DEPLOY_USER}"

USER_HOME="/home/${DEPLOY_USER}"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "${USER_HOME}/.ssh"
AUTH_KEYS="${USER_HOME}/.ssh/authorized_keys"
if [[ -n "$SSH_PUBLIC_KEY" ]]; then
  grep -qxF "$SSH_PUBLIC_KEY" "$AUTH_KEYS" 2>/dev/null || echo "$SSH_PUBLIC_KEY" >> "$AUTH_KEYS"
elif [[ ! -s "$AUTH_KEYS" ]]; then
  # On AWS, root's authorized_keys contains a forced "login as ubuntu" command,
  # so prefer the default cloud user's keys.
  for src in /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys; do
    if [[ -s "$src" ]]; then
      cp "$src" "$AUTH_KEYS"
      break
    fi
  done
fi
if [[ -f "$AUTH_KEYS" ]]; then
  chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH_KEYS"
  chmod 600 "$AUTH_KEYS"
fi

install -d -m 755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$STACK_DIR" "${STACK_DIR}/scripts"

# --- SSH hardening ----------------------------------------------------------------
log "Hardening SSH"
{
  echo "PasswordAuthentication no"
  echo "KbdInteractiveAuthentication no"
  echo "X11Forwarding no"
  echo "MaxAuthTries 3"
  # Only lock out root once we know the deploy user can log in.
  if [[ -s "$AUTH_KEYS" ]]; then
    echo "PermitRootLogin no"
  fi
} > /etc/ssh/sshd_config.d/99-hardening.conf
if sshd -t; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
else
  log "sshd config test failed, removing hardening file"
  rm -f /etc/ssh/sshd_config.d/99-hardening.conf
fi

# --- Firewall ---------------------------------------------------------------------
# WARNING: ports published by Docker (-p / "ports:") bypass UFW, because Docker
# inserts its own iptables rules. That's why only 80, 443 and 51820/udp are
# published in docker-compose.yml, and the cloud security group is the outer wall.
log "Configuring UFW"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 51820/udp
ufw --force enable

# --- fail2ban -------------------------------------------------------------------
log "Configuring fail2ban"
cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
systemctl enable fail2ban
systemctl restart fail2ban

# --- Automatic security updates --------------------------------------------------
log "Enabling unattended security upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# --- Swap (small instances run out of RAM otherwise) ------------------------------
if ! swapon --show | grep -q '/swapfile'; then
  log "Creating ${SWAP_SIZE} swap file"
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
echo 'vm.swappiness=10' > /etc/sysctl.d/99-homelab.conf
sysctl --system >/dev/null

log "Done. Log in with: ssh ${DEPLOY_USER}@<server-ip>"
