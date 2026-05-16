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

Generate the Reality private key and a short ID:

```bash
docker run --rm teddysun/xray xray x25519     # outputs PrivateKey + Password
openssl rand -hex 8                           # short ID
```

Fill these into `.env` along with the impersonation target SNI (must support TLS 1.3 + X25519 — `mail.kz`, `www.microsoft.com`, `www.cloudflare.com` are battle-tested):

```
XRAY_REALITY_PRIVATE_KEY=<PrivateKey line from xray x25519>
XRAY_SNI=mail.kz
XRAY_SHORT_ID=<output of openssl rand>
```

Then generate `xray/config.json` from `.env`:

```bash
bash scripts/xray-sync-config.sh
```

The script copies `xray/config.example.json` and applies the values from `.env`, leaving `clients[]` empty. Run it again any time you rotate the Reality key, change the SNI, or change the short ID — existing clients are preserved across runs. Pass `--restart` to also reload the xray container.

The matching public key (the one clients need as `pbk`) is **not** stored separately — `scripts/xray-add-user.sh` derives it on demand via `xray x25519 -i` when it builds each client's URL.

### 3. Set up AmneziaWG

Build the AWG image (compiles `amneziawg-go` + `amneziawg-tools` from source):

```bash
docker compose build awg
```

Generate the server keypair:

```bash
docker run --rm --entrypoint sh h-gate-awg:latest -c 'awg genkey | tee /dev/stderr | awg pubkey'
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

## Managing clients

### wg-easy (WireGuard)

Use the web UI. **New Client** → name it → download `.conf` or scan QR. Routing is governed by `WG_ALLOWED_IPS` in `.env`. Delete from the UI when you're done with a client. There is no script for wg-easy — the web UI is the source of truth.

### XRAY (VLESS + Reality)

```bash
bash scripts/xray-add-user.sh    <client-name>     # add
bash scripts/xray-list-users.sh                    # list
bash scripts/xray-remove-user.sh <client-name>     # remove
```

**Add** generates a fresh UUID, appends a client entry to `xray/config.json`, restarts the xray container, derives the Reality public key on the fly from the private key, and writes the resulting `vless://...` URL to `xray/urls/<client-name>.txt` (mode 600). The URL is also printed to stdout — copy into the client app, or render an in-terminal QR:

```bash
qrencode -t ansiutf8 < xray/urls/<client-name>.txt
```

**List** prints a table of all configured clients (`NAME`, `UUID`, `URL FILE`) by reading `xray/config.json`. XRAY doesn't expose per-client live state unless its `statsService` is enabled, so there's no traffic counter here.

**Remove** deletes the matching client entry (by `email` field) from `xray/config.json`, deletes the URL file, and restarts the xray container. Refuses with an error if the name isn't found.

Client apps:

| OS      | App                             |
|---|---|
| Android | v2rayNG (Play Store / F-Droid)  |
| Windows | v2rayN or Nekoray               |
| Linux   | Nekoray (GUI) or `xray` CLI     |

### AmneziaWG

```bash
bash scripts/awg-add-user.sh    <client-name>     # add
bash scripts/awg-list-users.sh                    # list (with live state)
bash scripts/awg-remove-user.sh <client-name>     # remove
```

**Add** generates a fresh keypair via the running `awg` container, picks the next free `10.9.0.X` address (scanning existing `[Peer] AllowedIPs`), appends a new `[Peer]` block, restarts the container, and emits a single-line `vpn://...` URL. Also written to `awg-data/urls/<client-name>.txt` (mode 600). `Jc`/`Jmin`/`Jmax`/`S1`-`S4`/`H1`-`H4` are read from the server config and embedded in the URL — server and client always agree.

**List** shows each peer with its `NAME`, `IP`, last 10 characters of the `PUBKEY`, `HANDSHAKE` age, and cumulative `RX / TX`. State comes from `awg show awg0 dump` inside the container, joined against names in `awg-data/awg0.conf`. Peers without a `# <name>` comment line (e.g. manually added) appear as `(unnamed)`.

**Remove** deletes the matching `[Peer]` block (and its leading `# <name>` comment line) from `awg-data/awg0.conf`, deletes the URL file, and restarts the container. Refuses with an error if the named peer isn't found. Peers without a `# <name>` comment must be edited out by hand.

Client app (all platforms): **AmneziaVPN** — paste the `vpn://` URL into "Add server" → "Paste from clipboard", or scan a QR:

```bash
qrencode -t ansiutf8 < awg-data/urls/<client-name>.txt
```

> **Schema caveat for the `vpn://` URL**: AmneziaVPN's share format isn't publicly specced. The script generates URLs in the v2 schema (`container: "amnezia-awg2"`, `protocol_version: "2"`, `last_config` as a JSON-stringified object containing `client_priv_key`, `clientId`, `mtu`, etc.). If a future AmneziaVPN release changes the schema and rejects the URL, fall back to manual peer registration: copy the `[Peer]` block from `awg-data/awg0.conf` plus the obfuscation params from `[Interface]` into a hand-written client `.conf`.
>
> **Server-side `I1-I5`**: the `amneziawg-tools` we build doesn't yet recognize the optional `I1-I5` spoof-packet keys; `awg setconf` errors with `Line unrecognized`. They're omitted from `awg-data/awg0.conf` and emitted as empty strings in the client URL. AmneziaVPN still classifies the import as full AmneziaWG v2.

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

## Monitoring & diagnostics

### Who's connected right now

**wg-easy (WireGuard)** — peer state with last-handshake and per-peer transfer:

```bash
docker exec wg-easy wg show
```

The web UI at `http://<WG_HOST>:51821` shows the same data graphically.

**AmneziaWG** — the list script joins names from `awg-data/awg0.conf` with live state from `awg show`:

```bash
bash scripts/awg-list-users.sh
docker exec awg awg show           # raw output, if you need it
```

A peer with `latest handshake: never` has been registered but hasn't dialed yet. Recent handshake + non-zero transfer = currently connected.

**XRAY** — configured clients (no per-client live counters without `statsService`):

```bash
bash scripts/xray-list-users.sh
```

For live connection events:

```bash
docker compose logs --tail=100 xray
```

XRAY logs an `accepted` line per established session. With `loglevel: "warning"` (our default), routine connect lines aren't emitted; bump to `info` in `xray/config.json` temporarily if you need them.

**SSH on the host**:

```bash
who                    # currently logged in
last -n 20             # recent login history
```

### Traffic volumes

Per-peer cumulative bytes are already in `wg show` / `awg show` output (`transfer: X received, Y sent`).

Aggregate per-container:

```bash
docker stats --no-stream
```

Host interface counters (cumulative since boot — useful for "how much have we shifted overall"):

```bash
ip -s link
```

### Failed connection attempts

**SSH brute force** — most active source IPs in the last hour:

```bash
sudo journalctl -u ssh.service --since "1 hour ago" \
    | grep -oE 'from [0-9.]+' | sort | uniq -c | sort -rn | head -10
```

What fail2ban has caught:

```bash
sudo fail2ban-client status sshd
```

Shows `Currently failed`, `Total failed`, `Currently banned`, plus the banned IP list. If `Currently banned` is non-zero, those IPs are firewalled off until the bantime expires.

**XRAY rejections** — clients with the wrong UUID, mis-typed SNI, etc.:

```bash
docker compose logs --tail=300 xray | grep -iE 'rejected|invalid|denied|fail'
```

**AmneziaWG handshake misses** — the server *silently* drops on obfuscation/key mismatch, so failures don't show in logs. Two ways to spot:

- `awg show` peer has `transfer: N received, 0 sent` (packets arriving, server can't decrypt)
- tcpdump shows inbound packets but no outbound responses from `:51822`:
  ```bash
  sudo tcpdump -i any -nn udp port 51822 -c 30
  ```

If the client keeps trying every ~5s with bursts of 5 packets (Jc=4 junks + 1 real handshake) but no response leaves the server, you've got a param mismatch.

### Security events

**ufw blocks** — packets dropped by an explicit deny rule (only present if `ufw logging` is on; we enabled it during hardening):

```bash
sudo journalctl -k --since "1 hour ago" | grep '\[UFW BLOCK\]'
```

**Log-martians** — packets with impossible source addresses (we enabled `net.ipv4.conf.all.log_martians=1`). Nothing in normal operation; entries here indicate spoofing or a misconfigured peer:

```bash
sudo dmesg --time-format=iso | grep -i martian | tail
```

**Recently banned IPs**:

```bash
sudo fail2ban-client banned
```

### Container & host health

```bash
docker compose ps                       # all three should say "Up"
docker compose logs --tail=30 <svc>     # recent log lines for one service
docker stats --no-stream                # CPU / mem / network per container
```

Host basics:

```bash
uptime                                  # load + uptime
free -h                                 # memory
df -h /                                 # root disk
sudo journalctl -p err --since "24 hours ago" | head -30   # recent errors
```

**Unattended-upgrades** sanity (set up in `HARDENING.md`):

```bash
systemctl is-active unattended-upgrades apt-daily.timer apt-daily-upgrade.timer
tail -20 /var/log/unattended-upgrades/unattended-upgrades.log
```

## Management

```bash
# Stop everything
docker compose down

# Update images (wg-easy, xray)
docker compose pull && docker compose up -d

# Rebuild AWG after upstream changes
docker compose build --no-cache awg && docker compose up -d awg
```

See **Backup & Restore** below for snapshot and recovery, and **Monitoring & diagnostics** above for day-to-day visibility.

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
