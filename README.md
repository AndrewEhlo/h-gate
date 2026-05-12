# Multi-Protocol VPN Server

A self-hosted VPN stack running three independent services on one host. Each is selected by the client app — they don't share clients, state, or routing.

| Service     | Protocol                | Use it when…                                                  |
|---|---|---|
| **wg-easy** | Vanilla WireGuard       | The network is open and you want the simplest, fastest tunnel. |
| **XRAY**    | VLESS + Reality (TCP 443) | UDP is blocked or DPI fingerprints WireGuard; traffic looks like HTTPS to `mail.kz`. |
| **AmneziaWG** | Obfuscated WireGuard | Vanilla WG handshake is DPI-blocked; uses junk-packet obfuscation. |

wg-easy provides a web UI for client management. XRAY and AmneziaWG are configured by editing files on disk.

## Prerequisites

- Docker and Docker Compose installed on the host
- A server with a public IP address (or LAN IP for local testing)
- Ports open in the firewall:

| Port  | Protocol | Service     | Audience                |
|---|---|---|---|
| 51820 | UDP      | wg-easy WG  | Public                  |
| 51821 | TCP      | wg-easy UI  | Trusted IPs only / SSH tunnel |
| 443   | TCP      | XRAY        | Public                  |
| 51822 | UDP      | AmneziaWG   | Public                  |

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

# Backup (private keys + client lists)
tar czf vpn-backup-$(date +%F).tar.gz wg-data/ awg-data/ xray/config.json .env
```

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
