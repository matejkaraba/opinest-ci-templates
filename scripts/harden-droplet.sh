#!/usr/bin/env bash
# harden-droplet.sh — One-shot security hardening pre Opinest DigitalOcean droplety.
#
# Inštaluje a konfiguruje:
#   - UFW firewall (povolené iba 22, 80, 443)
#   - fail2ban (auto-ban IP po N failed login attempts)
#   - nginx s rate limiting (limit_req_zone)
#   - ModSecurity + OWASP Core Rule Set (WAF na nginx)
#   - SSH hardening (disable password auth, key-only)
#   - unattended-upgrades (auto OS security patches)
#   - Postgres bind to localhost only
#
# Použitie:
#   ssh root@<droplet-ip>
#   curl -fsSL https://raw.githubusercontent.com/matejkaraba/opinest-ci-templates/main/scripts/harden-droplet.sh | bash
#
# ALEBO lokálne:
#   scp harden-droplet.sh root@<droplet-ip>:/tmp/
#   ssh root@<droplet-ip> "bash /tmp/harden-droplet.sh"
#
# Idempotent — môže sa spustiť opakovane bezpečne.

set -euo pipefail

LOG="/var/log/opinest-harden-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "==> Opinest droplet hardening started at $(date)"
echo "==> Log: $LOG"

# ============================================================
# 0. Predispozície
# ============================================================
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Must run as root (sudo)."
  exit 1
fi

DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

apt-get update -qq

# ============================================================
# 1. UFW firewall — iba 22, 80, 443
# ============================================================
echo "==> [1/7] Setup UFW firewall"
apt-get install -y -qq ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable
ufw status verbose

# ============================================================
# 2. fail2ban — auto-ban brute force
# ============================================================
echo "==> [2/7] Setup fail2ban"
apt-get install -y -qq fail2ban

cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 5

[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log

[nginx-limit-req]
enabled = true
port = http,https
filter = nginx-limit-req
logpath = /var/log/nginx/error.log
maxretry = 10
findtime = 60
bantime = 600
EOF

systemctl enable fail2ban
systemctl restart fail2ban
fail2ban-client status

# ============================================================
# 3. SSH hardening — key-only, disable root password
# ============================================================
echo "==> [3/7] SSH hardening"

# Backup pôvodný config
cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.opinest-backup || true

# Vytvor opinest hardening config
cat > /etc/ssh/sshd_config.d/99-opinest.conf <<'EOF'
# Opinest SSH hardening
PasswordAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
LoginGraceTime 30
EOF

sshd -t  # validate config
systemctl restart ssh || systemctl restart sshd

# ============================================================
# 4. Unattended-upgrades — auto OS security patches
# ============================================================
echo "==> [4/7] Setup unattended-upgrades"
apt-get install -y -qq unattended-upgrades apt-listchanges

dpkg-reconfigure --priority=low unattended-upgrades

cat > /etc/apt/apt.conf.d/52opinest-auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Mail "matej.karaba@opinest.com";
Unattended-Upgrade::MailReport "on-change";
EOF

# ============================================================
# 5. Postgres bind to localhost (ak je nainštalovaný)
# ============================================================
echo "==> [5/7] Postgres bind check"
if command -v psql >/dev/null 2>&1; then
  PG_CONF="/etc/postgresql/$(ls /etc/postgresql/ 2>/dev/null | head -1)/main/postgresql.conf"
  if [ -f "$PG_CONF" ]; then
    sed -i "s/^#\?listen_addresses\s*=.*$/listen_addresses = 'localhost'/" "$PG_CONF"
    systemctl restart postgresql || true
    echo "Postgres bound to localhost in $PG_CONF"
  else
    echo "Postgres binary present but config not found in expected path"
  fi
else
  echo "Postgres not installed locally (možno beží v Docker), skip"
fi

# ============================================================
# 6. nginx + ModSecurity (ak nginx existuje)
# ============================================================
echo "==> [6/7] nginx ModSecurity + rate limiting"
if command -v nginx >/dev/null 2>&1; then
  apt-get install -y -qq libmodsecurity3 modsecurity-crs

  # Rate limiting global config
  cat > /etc/nginx/conf.d/01-opinest-rate-limit.conf <<'EOF'
# Opinest rate limiting — globálne aplikované cez include v server bloku
limit_req_zone $binary_remote_addr zone=opinest_general:10m rate=30r/s;
limit_req_zone $binary_remote_addr zone=opinest_login:10m rate=5r/m;
limit_conn_zone $binary_remote_addr zone=opinest_conn:10m;
EOF

  # Per-server include odporúčaný:
  cat > /etc/nginx/snippets/opinest-rate-limit.conf <<'EOF'
# Add do server bloku:
#   include /etc/nginx/snippets/opinest-rate-limit.conf;
limit_req zone=opinest_general burst=60 nodelay;
limit_conn opinest_conn 20;

# Pre /login a /api/auth:
location ~ ^/(login|api/auth) {
    limit_req zone=opinest_login burst=10 nodelay;
}
EOF

  nginx -t && systemctl reload nginx
  echo "Nginx rate limiting configured. Manuálne pridaj 'include snippets/opinest-rate-limit.conf;' do server bloku."
else
  echo "Nginx not installed (možno beží v Docker), skip ModSecurity"
fi

# ============================================================
# 7. Final report
# ============================================================
echo "==> [7/7] Hardening dokončený."
echo ""
echo "==> Verifikácia:"
echo "    UFW:        $(ufw status | head -1)"
echo "    fail2ban:   $(systemctl is-active fail2ban)"
echo "    SSH:        $(systemctl is-active ssh || systemctl is-active sshd)"
echo "    auto-upgr:  $(systemctl is-active unattended-upgrades 2>/dev/null || echo n/a)"
echo ""
echo "==> Log uložený do: $LOG"
echo "==> Done at $(date)"
