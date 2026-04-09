# White VPN Infrastructure

Ansible-managed double-hop VPN with Xray VLESS Reality protocol and full traffic obfuscation.

## Architecture

```
Client
  │
  ▼  VLESS Reality (SNI: <S3VM_DOMAIN>)
WhiteVM (<WHITEVM_IP>:443)          ← HAProxy routes by SNI
  │
  ▼  VLESS Reality chain
S3VM (<S3VM_IP>:443)                ← Xray Reality + Marzban (user management)
  │
  ▼  VLESS Reality chain → exit
ForeignVM (<FOREIGNVM_IP>:443)      ← Xray Reality (service user), exit to internet
  │
  ▼
Internet
```

| Host | Role |
|------|------|
| WhiteVM | HAProxy SNI router (whitelisted IP, e.g. Yandex Cloud) |
| S3VM | Xray Reality + Marzban panel + Minio cover |
| ForeignVM | Xray Reality exit node + Minio cover + (optional) Grey VPN |

## Camouflage Strategy

- **Xray Reality "Steal Oneself"** — Xray on port 443 falls back to a local Nginx + Minio, making traffic indistinguishable from a legitimate S3 storage service
- **Double Reality hop** — both S3VM and ForeignVM use VLESS Reality with "steal oneself", DPI sees only normal TLS traffic
- **HAProxy SNI routing** — WhiteVM appears as a normal web server while transparently routing VPN traffic
- **Minio cover** — both VPN nodes serve a real Minio S3 console as the cover website

## Grey VPN — Direct Access (Optional)

In addition to the double-hop WhiteVPN, you can optionally deploy **GreyVPN** — a direct VPN on ForeignVM that bypasses the chain and connects clients straight to the exit server.

```
Client
  │
  ▼  VLESS Reality XHTTP (<FOREIGNVM_DOMAIN>:2053)
ForeignVM ← Marzban (user management) + Xray Reality XHTTP
  │
  ▼
Internet
```

**Key points:**

- Runs alongside the existing chain VPN without conflicts (separate Xray process on port 2053)
- Uses VLESS Reality XHTTP transport for maximum stealth
- "Steal oneself" camouflage — Reality falls back to the same Nginx/Minio cover site
- Marzban panel at `https://<FOREIGNVM_DOMAIN>/panel/`
- Enabled by setting `grey_vpn_enabled: true` in `group_vars/all.yml`

**When to use:**

| VPN | Route | Use case |
|-----|-------|----------|
| WhiteVPN | Client → WhiteVM → S3VM → ForeignVM → Internet | Bypass IP whitelists (Russian services) |
| GreyVPN | Client → ForeignVM → Internet | Direct access, lower latency |

---

## Deployment

### Prerequisites

1. **3 servers** with public IPs:
   - **WhiteVM** — server with a whitelisted/clean IP (e.g. Yandex Cloud)
   - **S3VM** — intermediate server (e.g. Timeweb, any VPS)
   - **ForeignVM** — exit server in a foreign country

2. **DNS A records** for each server pointing to its IP

3. **SSH access** to all hosts (key-based or password)

4. **Ansible** 2.12+ with `community.general` collection:

```bash
pip install ansible
ansible-galaxy collection install community.general
```

5. **sshpass** (if using password-based SSH):

```bash
# Ubuntu/Debian
apt install sshpass
# macOS
brew install hudochenkov/sshpass/sshpass
```

6. **Ports 80 and 443** open in cloud security groups / firewalls for all hosts (+ port **2053** on ForeignVM if Grey VPN is enabled)

### Configuration

1. Copy example config files:

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
cp group_vars/all.yml.example group_vars/all.yml
```

2. Edit `inventory/hosts.yml` — fill in your server IPs, SSH credentials, and domains

3. Edit `group_vars/all.yml` — fill in IPs, domains, email, and Yandex Cloud IDs

4. (Optional) Set `grey_vpn_enabled: true` in `group_vars/all.yml` to enable Grey VPN on ForeignVM

5. (Optional) Place your Yandex Cloud service account key in `secrets/yc-sa-key.json`

### Deploy

```bash
# Full deployment
ansible-playbook site.yml

# Deploy specific host
ansible-playbook site.yml --limit s3

# Verify only
ansible-playbook site.yml --start-at-task="Stage 12"
```

---

## VPN Connection Guide

### Step 1. Access the Marzban Panel

Marzban is the VPN user management panel running on S3VM. Open in your browser:

```
https://<S3VM_DOMAIN>/panel/
```

> This works via Reality fallback — regular HTTPS requests are forwarded by Xray to Nginx, which proxies Marzban.

Credentials are stored on the server at `/var/lib/marzban/.admin_password`. Default username: `admin`.

### Step 2. Create a User

1. Log in to the Marzban panel
2. Click **"Add User"**
3. Fill in:
   - **Username** — any name (e.g. `my-vpn`)
   - **Protocol** — select **VLESS**
   - **Inbound** — select **VLESS_REALITY**
   - **Flow** — `xtls-rprx-vision`
4. Click **Create**
5. Copy the generated **VLESS link** — it will already contain the correct server address and keys

### Step 3. Install a VPN Client

| Platform | Recommended Client |
|----------|-------------------|
| Windows | [Hiddify Next](https://github.com/hiddify/hiddify-app), [v2rayN](https://github.com/2dust/v2rayN) |
| macOS | [Hiddify Next](https://github.com/hiddify/hiddify-app), [V2Box](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) |
| Android | [Hiddify Next](https://github.com/hiddify/hiddify-app), [v2rayNG](https://github.com/2dust/v2rayNG) |
| iOS | [Hiddify Next](https://github.com/hiddify/hiddify-app), [Streisand](https://apps.apple.com/app/streisand/id6450534064) |
| Linux | [Hiddify Next](https://github.com/hiddify/hiddify-app), [Nekoray](https://github.com/MatsuriDayo/nekoray) |

### Step 4. Connect

1. Copy the VLESS link from Marzban
2. In your client, select **"Import from clipboard"**
3. Connect

### Step 5. Verify

After connecting:
1. Open [https://whatismyipaddress.com](https://whatismyipaddress.com) — the IP should show ForeignVM's country
2. Open [https://browserleaks.com/ip](https://browserleaks.com/ip) — verify there are no leaks

---

## Grey VPN Connection Guide (if enabled)

### Step 1. Access the Grey Marzban Panel

```
https://<FOREIGNVM_DOMAIN>/panel/
```

Credentials are stored on the server at `/var/lib/marzban-grey/.admin_password`. Default username: `admin`.

### Step 2. Create a User

1. Log in to the Grey Marzban panel
2. Click **"Add User"**
3. Fill in:
   - **Username** — any name (e.g. `my-grey-vpn`)
   - **Protocol** — select **VLESS**
   - **Inbound** — select **VLESS_REALITY_XHTTP**
   - **Flow** — leave **empty** (XHTTP does not use vision flow)
4. Click **Create**
5. Copy the generated **VLESS link**

### Step 3. Connect

1. Import the link into your VPN client (same clients as WhiteVPN)
2. Connect — traffic goes directly through ForeignVM without the chain

> **Note:** Both WhiteVPN and GreyVPN can be used simultaneously on different profiles in your VPN client.

---

## What Gets Deployed

### WhiteVM (HAProxy)
- UFW firewall (22, 80, 443)
- Fail2ban for SSH protection
- HAProxy: TCP-mode SNI-based routing on port 443
- Nginx: cover website on port 8443 (behind HAProxy)
- Let's Encrypt SSL certificate

### S3VM (Xray Reality + Marzban)
- UFW firewall (22, 80, 443)
- Fail2ban for SSH protection
- Docker + Docker Compose
- Xray: VLESS Reality inbound on 443, outbound chained to ForeignVM (managed by Marzban)
- Marzban: user management panel (Docker, host networking)
- Nginx: SSL reverse proxy on 8443 → Marzban panel + Minio (Reality fallback)
- Minio: bare S3 console (Docker, no persistence)
- WhiteVM monitoring script (auto-starts VM via Yandex Cloud CLI)
- Let's Encrypt SSL certificate

### ForeignVM (Xray Exit + optional Grey VPN)
- UFW firewall (22, 80, 443, +2053 if Grey VPN)
- Fail2ban for SSH protection
- Docker + Docker Compose
- Xray: standalone VLESS Reality inbound on 443, freedom outbound (exit node for chain)
- Nginx: SSL reverse proxy on 8443 → Minio + Grey Marzban panel (Reality fallback)
- Minio: bare S3 console (Docker, no persistence)
- (Optional) Marzban Grey: direct VPN panel (Docker, host networking, port 8001)
- (Optional) Xray Grey: VLESS Reality XHTTP on port 2053 (managed by Marzban Grey)
- Let's Encrypt SSL certificate

## Auto-Recovery

All services are configured to survive VM reboots:

| VM | Service | Auto-start method |
|----|---------|------------------|
| WhiteVM | HAProxy | systemd `enabled` |
| WhiteVM | Nginx | systemd `enabled` |
| S3VM | Docker + Marzban | systemd + `restart: always` |
| S3VM | Docker + Minio | systemd + `restart: unless-stopped` |
| S3VM | WhiteVM monitor | cron (every minute) |
| ForeignVM | Xray | systemd `enabled` |
| ForeignVM | Docker + Minio | systemd + `restart: unless-stopped` |
| ForeignVM | Docker + Marzban Grey | systemd + `restart: always` (if enabled) |
| ForeignVM | Nginx | systemd `enabled` |

S3VM runs a health check script every minute — if WhiteVM is unreachable, it automatically starts the Yandex Cloud instance via `yc` CLI.

## Security Notes

- All services (Minio, Marzban) are bound to `127.0.0.1` — not exposed directly
- Only ports 22, 80, 443 are open in UFW
- SSH hardened (no root password login, fail2ban)
- Reality keys are generated per-host and stored in `/etc/xray/`
- Marzban admin password is auto-generated and stored on the server
- **No sensitive data in git** — real configs (`hosts.yml`, `all.yml`) are gitignored; use `.example` files as templates

## File Structure

```
├── ansible.cfg                 # Ansible configuration
├── site.yml                    # Main playbook (14 stages)
├── inventory/
│   ├── hosts.yml.example       # Host inventory template (fill in your values)
│   └── hosts.yml               # (gitignored) Actual host inventory
├── group_vars/
│   ├── all.yml.example         # Shared variables template
│   └── all.yml                 # (gitignored) Actual variables
├── secrets/                    # (gitignored) Yandex Cloud keys, etc.
└── roles/
    ├── common/                 # System hardening, firewall
    ├── docker/                 # Docker installation
    ├── certbot/                # Nginx ACME + SSL certs
    ├── xray/                   # Xray install, keygen, config
    ├── nginx/                  # Reverse proxy configuration
    ├── minio/                  # Minio Docker deployment
    ├── haproxy/                # HAProxy SNI routing
    ├── marzban/                # Marzban panel deployment (S3VM, WhiteVPN)
    ├── marzban_grey/           # Grey VPN panel deployment (ForeignVM, optional)
    ├── monitoring/             # WhiteVM health check (S3VM)
    └── verify/                 # Deployment verification
```
