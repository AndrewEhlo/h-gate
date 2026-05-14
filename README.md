# Multi-Protocol VPN Server

A self-hosted VPN stack running three independent services on one host. Each is selected by the client app — they don't share clients, state, or routing.

| Service     | Protocol                | Use it when…                                                  |
|---|---|---|
| **wg-easy** | Vanilla WireGuard       | The network is open and you want the simplest, fastest tunnel. |
| **XRAY**    | VLESS + Reality (TCP 443) | UDP is blocked or DPI fingerprints WireGuard; traffic looks like HTTPS to `mail.kz`. |
| **AmneziaWG** | Obfuscated WireGuard | Vanilla WG handshake is DPI-blocked; uses junk-packet obfuscation. |

wg-easy provides a web UI for client management. XRAY and AmneziaWG are configured by editing files on disk.

## Prerequisites

- A server with a public IP address (or LAN IP for local testing)
- Root or `sudo` access
- A KVM-based VPS (OpenVZ/LXC containers won't work — they lack `/dev/net/tun` and the kernel WireGuard module)
- Ports open in the firewall:

| Port  | Protocol | Service     | Audience                |
|---|---|---|---|
| 51820 | UDP      | wg-easy WG  | Public                  |
| 51821 | TCP      | wg-easy UI  | Trusted IPs only / SSH tunnel |
| 443   | TCP      | XRAY        | Public                  |
| 51822 | UDP      | AmneziaWG   | Public                  |

### Install required software on the VPS

The host needs Docker Engine, the Compose v2 plugin, the WireGuard kernel module (for wg-easy), and IPv4 forwarding enabled. Steps below assume **Ubuntu 22.04 / 24.04 or Debian 12** — the most common VPS images.

**1. Update the system and install base tools:**

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y ca-certificates curl gnupg git openssl
```

**2. Install Docker Engine + Compose plugin** (from Docker's official repo — distro packages are usually too old):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

For Debian, replace `ubuntu` with `debian` in both URLs above.

Verify:

```bash
docker --version
docker compose version
```

**3. Run Docker without `sudo`** (optional but recommended):

```bash
sudo usermod -aG docker $USER
newgrp docker     # or log out and back in
```

**4. Install the WireGuard kernel module** (needed by wg-easy; AmneziaWG runs in userspace and does not require it):

```bash
sudo apt install -y wireguard-tools
sudo modprobe wireguard
lsmod | grep wireguard     # should print a line
```

**5. Enable IPv4 forwarding persistently:**

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-vpn-forward.conf
sudo sysctl --system
```

**6. Verify the kernel exposes `/dev/net/tun`** (required by AmneziaWG):

```bash
ls -l /dev/net/tun
# crw-rw-rw- 1 root root 10, 200 ...
```

If it's missing, your VPS provider is using OpenVZ/LXC and this stack will not work — pick a KVM plan.

**7. Sanity-check CPU features** (AES-NI dramatically speeds up VPN crypto):

```bash
grep -E -o 'aes|avx' /proc/cpuinfo | sort -u
```

**8. Clone the repo:**

```bash
git clone <this-repo-url> h-gate
cd h-gate
```

You're ready for the Quick Start below.

## Quick Start

### 1. Configure `.env`

```bash
cp .env.example .env
```

Set `WG_HOST` to your public IP or domain (or LAN IP for local testing):

```
WG_HOST=203.0.113.10
```

Generate a bcrypt hash for the wg-easy web UI and put it in `.env` as `PASSWORD_HASH`. **Every `$` must be doubled to `$$`** — otherwise Compose interpolates the hash and login breaks.

```bash
docker run -it ghcr.io/wg-easy/wg-easy wgpw 'YOUR_PASSWORD'
# Output: $2a$12$abc...xyz
# In .env:  PASSWORD_HASH=$$2a$$12$$abc...xyz
```

### 2. Set up XRAY

Generate the three required values:

```bash
docker run --rm teddysun/xray xray uuid             # one UUID per client
docker run --rm teddysun/xray xray x25519           # Reality keypair (keep both)
openssl rand -hex 8                                  # short ID
```

```bash
cp xray/config.example.json xray/config.json
```

Edit `xray/config.json` and replace the three `REPLACE_WITH_*` placeholders. Save the Reality **public** key — clients need it.

### 3. Set up AmneziaWG

Build the AWG image (compiles `amneziawg-go` + `amneziawg-tools` from source):

```bash
docker compose build awg
```

Generate the server keypair:

```bash
docker run --rm --entrypoint sh awg-awg -c 'awg genkey | tee /dev/stderr | awg pubkey'
# First line  = server private key
# Second line = server public key (clients need this)
```

```bash
mkdir -p awg-data
cp awg/awg0.example.conf awg-data/awg0.conf
```

Edit `awg-data/awg0.conf` and paste the **private** key into `PrivateKey =`. The `H1`-`H4` and `Jc`/`Jmin`/`Jmax`/`S1`/`S2` values can stay as-is, but every client must use identical values.

### 4. Start the stack

```bash
docker compose up -d
docker compose ps     # all three containers should be "running"
```

Open the wg-easy UI at `http://<WG_HOST>:51821` and log in.

## Adding clients

### wg-easy (WireGuard)

Use the web UI. **New Client** → name it → download `.conf` or scan QR. Routing is governed by `WG_ALLOWED_IPS` in `.env`.

### XRAY (VLESS + Reality)

1. Generate a UUID per device: `docker run --rm teddysun/xray xray uuid`
2. Add an entry to `xray/config.json` under `inbounds[0].settings.clients`:
   ```json
   { "id": "<NEW_UUID>", "flow": "xtls-rprx-vision" }
   ```
3. Restart: `docker compose restart xray`
4. Give the client this URI (one per device, or QR-encode it):
   ```
   vless://<UUID>@<WG_HOST>:443?security=reality&encryption=none&pbk=<REALITY_PUBLIC_KEY>&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=mail.kz&sid=<SHORT_ID>#<name>
   ```

Client apps:

| OS      | App                             |
|---|---|
| Android | v2rayNG (Play Store / F-Droid)  |
| Windows | v2rayN or Nekoray               |
| Linux   | Nekoray (GUI) or `xray` CLI     |

### AmneziaWG

1. Generate a client keypair on the *client device* (or with `docker run --rm --entrypoint sh awg-awg -c 'awg genkey | tee /dev/stderr | awg pubkey'`).
2. Append a `[Peer]` block to `awg-data/awg0.conf`:
   ```ini
   [Peer]
   PublicKey = <CLIENT_PUBLIC_KEY>
   AllowedIPs = 10.9.0.2/32
   ```
   Increment the IP for each new client (`10.9.0.2`, `10.9.0.3`, …).
3. Restart: `docker compose restart awg`
4. Build the client `.conf` (paste into AmneziaVPN app). **`Jc`/`Jmin`/`Jmax`/`S1`/`S2`/`H1`-`H4` must match the server exactly.**
   ```ini
   [Interface]
   PrivateKey = <CLIENT_PRIVATE_KEY>
   Address = 10.9.0.2/32
   DNS = 1.1.1.1
   Jc = 4
   Jmin = 40
   Jmax = 70
   S1 = 0
   S2 = 0
   H1 = 982742843
   H2 = 1325344849
   H3 = 1456789012
   H4 = 1567890123

   [Peer]
   PublicKey = <SERVER_PUBLIC_KEY>
   Endpoint = <WG_HOST>:51822
   AllowedIPs = 0.0.0.0/0, ::/0
   PersistentKeepalive = 25
   ```

Client app (all platforms): **AmneziaVPN** — supports importing the `.conf` directly.

## Full Tunnel vs Split Tunnel (wg-easy)

Edit `WG_ALLOWED_IPS` in `.env`:

| Mode         | Value                              | Effect                                      |
|--------------|------------------------------------|----------------------------------------------|
| Full tunnel  | `0.0.0.0/0, ::/0`                 | All client traffic routes through the VPN    |
| Split tunnel | `10.0.0.0/8, 192.168.0.0/16`      | Only specified subnets route through the VPN |

After changing, recreate the container:

```bash
docker compose down && docker compose up -d
```

This sets the default for *new* clients. Existing clients keep their downloaded config. For XRAY and AmneziaWG, `AllowedIPs` is set in the client config and changed there directly.

## Management

```bash
# View logs (all services or one)
docker compose logs -f
docker compose logs -f xray

# Live peer state
docker exec wg-easy wg show
docker exec awg awg show

# Stop everything
docker compose down

# Update images (wg-easy, xray)
docker compose pull && docker compose up -d

# Rebuild AWG after upstream changes
docker compose build --no-cache awg && docker compose up -d awg
```

See **Backup & Restore** below for snapshot and recovery.

## Backup & Restore

Everything in the repo can be regenerated from its templates except the per-deployment state below. These are the paths that matter:

| Path | Contains |
|---|---|
| `.env` | host, wg-easy password hash, XRAY Reality params |
| `wg-data/` | wg-easy server keys + all client configs |
| `awg-data/` | AmneziaWG server keypair + peer list |
| `xray/config.json` | XRAY runtime config — Reality private key + all client UUIDs |
| `xray/urls/` | per-client vless:// URLs (optional; regenerable from `xray/config.json`) |

All five are listed in `.gitignore`, so they live only on the host.

### Backup

```bash
# Snapshot to a tarball, preserving mode bits (private keys stay 0600).
tar czf vpn-backup-$(date +%F).tar.gz \
    .env wg-data/ awg-data/ xray/config.json xray/urls/

# Move it off the host. Don't store it on the same machine you're backing up.
scp vpn-backup-*.tar.gz user@elsewhere:~/backups/
```

If the backup will sit anywhere other than offline media (object storage, shared file server, second VPS), encrypt it first. Lowest-dependency option:

```bash
gpg --symmetric --cipher-algo AES256 vpn-backup-$(date +%F).tar.gz
# Produces .tar.gz.gpg. Verify it decrypts, then delete the plaintext.
gpg --decrypt vpn-backup-$(date +%F).tar.gz.gpg | tar tz | head
rm vpn-backup-$(date +%F).tar.gz
```

### Restore (fresh VPS)

1. Run the **Prerequisites** install steps at the top of this README — Docker, Compose, `wireguard-tools`, sysctl forwarding, `/dev/net/tun` check.
2. Clone the repo:
   ```bash
   git clone <this-repo-url> h-gate
   cd h-gate
   ```
3. Build the AWG image (the backup carries state, not images):
   ```bash
   docker compose build awg
   ```
4. Extract the backup over the repo root:
   ```bash
   tar xzf ~/vpn-backup-2026-05-14.tar.gz
   # or, if encrypted:
   # gpg --decrypt ~/vpn-backup-2026-05-14.tar.gz.gpg | tar xz
   ```
   `tar` restores ownership and `0600` on private keys. Verify a sample:
   ```bash
   ls -l wg-data/wg0.json xray/config.json
   ```
5. If the host's public IP or domain changed, update `WG_HOST` in `.env`. Existing distributed client configs have the old endpoint baked in — see below.
6. Bring the stack up:
   ```bash
   docker compose up -d
   docker compose ps
   ```

### Restoring to a new IP / hostname

The server state survives; the **client-side configs** you previously handed out do not, because they each contain the old endpoint:

- **wg-easy** clients have `Endpoint = <old-ip>:51820` in their `.conf`. Either re-issue from the wg-easy UI, or have each client edit the line locally.
- **AmneziaWG** clients have `Endpoint = <old-ip>:51822` in their `.conf`. Same fix.
- **XRAY** clients have the host in the vless:// URL (`@<host>:443`). Re-issue URLs:
  ```bash
  # Regenerate one URL file for an existing user by deleting the line
  # in xray/config.json's clients[] and running xray-add-user.sh again
  # — UUIDs are reusable but adding the same name twice is refused.
  ```
  The cleanest workaround: keep `WG_HOST` set to a domain (not a literal IP) that you can repoint via DNS. Then a host move requires only a DNS change; no client config touches.

### What is NOT in the backup, by design

- **Reality public key.** Not stored — derived on demand from `realitySettings.privateKey` in `xray/config.json` by `scripts/xray-add-user.sh` via `xray x25519 -i`. As long as `xray/config.json` is in the backup, the public key is recoverable.
- **Docker images.** Re-pulled / re-built from the repo. The AWG image must be `docker compose build awg`'d on the new host (no published image exists).
- **Host hardening state.** See `HARDENING.md` — it's the same checklist for every fresh host, run once.

## Firewall Rules

```bash
# ufw
sudo ufw allow 51820/udp
sudo ufw allow 443/tcp
sudo ufw allow 51822/udp
sudo ufw allow from <TRUSTED_CIDR> to any port 51821 proto tcp

# firewalld
sudo firewall-cmd --add-port=51820/udp --permanent
sudo firewall-cmd --add-port=443/tcp   --permanent
sudo firewall-cmd --add-port=51822/udp --permanent
sudo firewall-cmd --reload
```

The wg-easy UI port (51821) should be restricted to trusted source IPs or accessed only via SSH tunnel in production.
