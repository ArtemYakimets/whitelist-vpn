#!/usr/bin/env bash
set -euo pipefail

# Deploy Grey VPN (GreyVPN) on ForeignVM
# Standalone script — equivalent of marzban_grey Ansible role
# Usage: bash deploy_grey.sh [--ssh-pubkey "ssh-ed25519 AAAA..."]

GREY_XRAY_PORT=2053
GREY_MARZBAN_PORT=8001
GREY_DASHBOARD_PATH="/panel/"
XRAY_FALLBACK_PORT=8443
MINIO_CONSOLE_PORT=9001
DOMAIN=$(cat /etc/xray/domain 2>/dev/null || hostname -f)

SSH_PUBKEY=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --ssh-pubkey) SSH_PUBKEY="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- Pre-flight checks ---
log "Checking prerequisites..."
command -v docker >/dev/null || { echo "ERROR: docker not found"; exit 1; }
command -v xray >/dev/null 2>&1 || [[ -f /usr/local/bin/xray ]] || { echo "ERROR: xray not found"; exit 1; }
[[ -f /etc/xray/reality_private_key ]] || { echo "ERROR: Reality keys not found in /etc/xray/"; exit 1; }

log "Domain: $DOMAIN"

# --- SSH key setup ---
if [[ -n "$SSH_PUBKEY" ]]; then
  log "Adding SSH public key to authorized_keys..."
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  touch ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
  if ! grep -qF "$SSH_PUBKEY" ~/.ssh/authorized_keys 2>/dev/null; then
    echo "$SSH_PUBKEY" >> ~/.ssh/authorized_keys
    log "SSH key added"
  else
    log "SSH key already present"
  fi
fi

# --- Store domain for future reference ---
echo "$DOMAIN" > /etc/xray/domain

# --- Read existing Reality keys ---
PRIVATE_KEY=$(cat /etc/xray/reality_private_key)
PUBLIC_KEY=$(cat /etc/xray/reality_public_key)
SHORT_ID=$(cat /etc/xray/short_id)
log "Reality keys loaded (public: ${PUBLIC_KEY:0:12}...)"

# --- Create directories ---
log "Creating directories..."
mkdir -p /opt/marzban-grey /var/lib/marzban-grey /var/log/xray

# --- Generate admin password ---
if [[ ! -f /var/lib/marzban-grey/.admin_password ]]; then
  ADMIN_PASS=$(openssl rand -base64 24)
  echo -n "$ADMIN_PASS" > /var/lib/marzban-grey/.admin_password
  chmod 600 /var/lib/marzban-grey/.admin_password
  log "Admin password generated"
else
  ADMIN_PASS=$(cat /var/lib/marzban-grey/.admin_password)
  log "Admin password already exists"
fi

# --- Xray config (VLESS Reality XHTTP) ---
log "Writing Xray config..."
cat > /var/lib/marzban-grey/xray_config.json << XRAYEOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access-grey.log",
    "error": "/var/log/xray/error-grey.log"
  },
  "inbounds": [
    {
      "tag": "VLESS_REALITY_XHTTP",
      "listen": "0.0.0.0",
      "port": ${GREY_XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "/",
          "mode": "auto"
        },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "127.0.0.1:${XRAY_FALLBACK_PORT}",
          "xver": 0,
          "serverNames": [
            "${DOMAIN}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "outboundTag": "BLOCK", "ip": ["geoip:private"] }
    ]
  }
}
XRAYEOF

# --- Docker Compose ---
log "Writing docker-compose..."
cat > /opt/marzban-grey/docker-compose.yml << 'DCEOF'
services:
  marzban-grey:
    image: gozargah/marzban:latest
    container_name: marzban-grey
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - /var/lib/marzban-grey:/var/lib/marzban
      - /usr/local/bin/xray:/usr/local/bin/xray:ro
      - /usr/local/share/xray:/usr/local/share/xray:ro
      - /var/log/xray:/var/log/xray
DCEOF

# --- Environment file ---
log "Writing .env..."
cat > /opt/marzban-grey/.env << ENVEOF
SUDO_USERNAME=admin
SUDO_PASSWORD=${ADMIN_PASS}
UVICORN_HOST=127.0.0.1
UVICORN_PORT=${GREY_MARZBAN_PORT}
DASHBOARD_PATH=${GREY_DASHBOARD_PATH}
XRAY_JSON=/var/lib/marzban/xray_config.json
XRAY_EXECUTABLE_PATH=/usr/local/bin/xray
XRAY_ASSETS_PATH=/usr/local/share/xray
ENVEOF
chmod 600 /opt/marzban-grey/.env

# --- UFW ---
log "Opening UFW port ${GREY_XRAY_PORT}..."
ufw allow "${GREY_XRAY_PORT}/tcp" >/dev/null 2>&1 || true

# --- Update Nginx config ---
log "Updating Nginx config..."
NGINX_CONF="/etc/nginx/sites-available/main"
if [[ -f "$NGINX_CONF" ]]; then
  # Check if grey panel locations already exist
  if ! grep -q "marzban-grey" "$NGINX_CONF"; then
    # Insert Grey Marzban locations before the Minio catch-all location /
    sed -i "/# Minio Console/i\\
    # Grey Marzban panel (marzban-grey)\\
    location ${GREY_DASHBOARD_PATH} {\\
        proxy_pass http://127.0.0.1:${GREY_MARZBAN_PORT}${GREY_DASHBOARD_PATH};\\
        proxy_set_header Host \\\$host;\\
        proxy_set_header X-Real-IP \\\$remote_addr;\\
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;\\
        proxy_set_header X-Forwarded-Proto \\\$scheme;\\
        proxy_http_version 1.1;\\
        proxy_set_header Upgrade \\\$http_upgrade;\\
        proxy_set_header Connection \"upgrade\";\\
    }\\
\\
    # Grey Marzban static assets (marzban-grey)\\
    location /statics/ {\\
        proxy_pass http://127.0.0.1:${GREY_MARZBAN_PORT}/statics/;\\
        proxy_set_header Host \\\$host;\\
        proxy_set_header X-Real-IP \\\$remote_addr;\\
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;\\
        proxy_set_header X-Forwarded-Proto \\\$scheme;\\
    }\\
\\
    # Grey Marzban API (marzban-grey)\\
    location /api/ {\\
        proxy_pass http://127.0.0.1:${GREY_MARZBAN_PORT}/api/;\\
        proxy_set_header Host \\\$host;\\
        proxy_set_header X-Real-IP \\\$remote_addr;\\
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;\\
        proxy_set_header X-Forwarded-Proto \\\$scheme;\\
    }\\
\\
    # Grey Marzban subscription (marzban-grey)\\
    location /sub/ {\\
        proxy_pass http://127.0.0.1:${GREY_MARZBAN_PORT}/sub/;\\
        proxy_set_header Host \\\$host;\\
        proxy_set_header X-Real-IP \\\$remote_addr;\\
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;\\
        proxy_set_header X-Forwarded-Proto \\\$scheme;\\
    }\\
" "$NGINX_CONF"
    log "Nginx config updated with Grey panel locations"
  else
    log "Nginx config already has Grey panel locations"
  fi

  nginx -t 2>&1 && systemctl reload nginx && log "Nginx reloaded OK" || log "ERROR: Nginx config test failed!"
else
  log "WARNING: Nginx config not found at $NGINX_CONF"
fi

# --- Verify existing Xray chain (port 443) still works ---
log "Checking chain Xray on port 443..."
if systemctl is-active --quiet xray; then
  log "Chain Xray (port 443) is running - OK"
else
  log "WARNING: Chain Xray is not running! Checking..."
  /usr/local/bin/xray -test -config /usr/local/etc/xray/config.json 2>&1 && \
    systemctl start xray && log "Chain Xray started" || \
    log "ERROR: Chain Xray config invalid"
fi

# --- Start Marzban Grey ---
log "Pulling Marzban image..."
docker pull gozargah/marzban:latest 2>&1 | tail -1

log "Starting Marzban Grey..."
cd /opt/marzban-grey
docker compose up -d 2>&1

# --- Wait for Marzban to be ready ---
log "Waiting for Marzban Grey to be ready..."
for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:${GREY_MARZBAN_PORT}/api/" >/dev/null 2>&1; then
    log "Marzban Grey is UP"
    break
  fi
  sleep 5
done

# --- Configure Marzban hosts for direct access ---
log "Configuring Marzban hosts..."
TOKEN_RESP=$(curl -sf -X POST "http://127.0.0.1:${GREY_MARZBAN_PORT}/api/admin/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&username=admin&password=${ADMIN_PASS}" 2>/dev/null) || true

if [[ -n "$TOKEN_RESP" ]]; then
  TOKEN=$(echo "$TOKEN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true
  if [[ -n "$TOKEN" ]]; then
    curl -sf -X PUT "http://127.0.0.1:${GREY_MARZBAN_PORT}/api/hosts" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"VLESS_REALITY_XHTTP\": [{\"remark\": \"GreyVPN\", \"address\": \"${DOMAIN}\", \"port\": ${GREY_XRAY_PORT}, \"sni\": \"${DOMAIN}\", \"fingerprint\": \"chrome\", \"is_disabled\": false}]}" >/dev/null 2>&1 && \
      log "Marzban hosts configured (GreyVPN → ${DOMAIN}:${GREY_XRAY_PORT})" || \
      log "WARNING: Failed to configure hosts (configure manually in panel)"
  else
    log "WARNING: Could not parse token (configure hosts manually in panel)"
  fi
else
  log "WARNING: Marzban API not ready yet (configure hosts manually after startup)"
fi

# --- Final status ---
echo ""
echo "============================================"
echo "  Grey VPN (GreyVPN) Deployment Complete"
echo "============================================"
echo ""
echo "  Panel:    https://${DOMAIN}${GREY_DASHBOARD_PATH}"
echo "  Username: admin"
echo "  Password: ${ADMIN_PASS}"
echo "  VPN Port: ${GREY_XRAY_PORT}"
echo ""
echo "  Chain Xray (WhiteVPN):  $(systemctl is-active xray) on :443"
echo "  Marzban Grey container: $(docker ps --filter name=marzban-grey --format '{{.Status}}' 2>/dev/null || echo 'unknown')"
echo "  Nginx:                  $(systemctl is-active nginx)"
echo ""
echo "  Public Key: ${PUBLIC_KEY}"
echo "  Short ID:   ${SHORT_ID}"
echo ""
echo "============================================"
