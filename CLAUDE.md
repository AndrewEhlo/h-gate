# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Docker Compose stack running three independent VPN/proxy services on one host. There is no application source code — the deliverables are `docker-compose.yml`, the per-service config files, and `.env`. Services do not share clients, state, or routing; each is selected by the client app.

| Service   | Image                          | Port       | Purpose                          | State dir          |
|---|---|---|---|---|
| `wg-easy` | `ghcr.io/wg-easy/wg-easy`      | UDP 51820 / TCP 51821 | Vanilla WireGuard + web UI | `wg-data/`         |
| `xray`    | `teddysun/xray`                | TCP 443    | VLESS + Reality (port-share TLS) | `xray/config.json` |
| `awg`     | built from `awg/Dockerfile`    | UDP 51822  | AmneziaWG userspace daemon       | `awg-data/`        |

The XRAY Reality impersonation target is `mail.kz`. The AWG container builds `amneziawg-go` + `amneziawg-tools` from source (no canonical published image exists).

## Common commands

```bash
sudo docker compose up -d --build               # start everything (build awg image on first run)
sudo docker compose down                        # stop everything
sudo docker compose up -d --build awg           # rebuild only awg after Dockerfile changes
sudo docker compose logs -f <service>           # tail one service
sudo docker compose config                      # validate .env interpolation, esp. PASSWORD_HASH escaping
sudo docker exec wg-easy wg show                # WG peer state + handshakes
sudo docker exec awg awg show                   # AWG peer state + handshakes
sudo docker exec xray xray version              # XRAY sanity check
```

### Key generation (one-time, per deployment)

```bash
# wg-easy admin password hash → PASSWORD_HASH in .env (remember to double $ → $$)
sudo docker run -it ghcr.io/wg-easy/wg-easy wgpw 'YOUR_PASSWORD'

# XRAY: UUID, Reality keypair, short ID
sudo docker run --rm teddysun/xray xray uuid
sudo docker run --rm teddysun/xray xray x25519
openssl rand -hex 8

# AWG server keypair (after the awg image is built)
sudo docker run --rm --entrypoint sh awg-awg -c 'awg genkey | tee /dev/stderr | awg pubkey'
```

Drop the values into `xray/config.json` (copy from `xray/config.example.json`) and `awg-data/awg0.conf` (copy from `awg/awg0.example.conf`).

## Non-obvious gotchas

### Cross-cutting

- **`$` must be doubled to `$$` in `.env`.** Compose interpolates `.env`, so a bcrypt hash like `$2a$12$...` must be written `$$2a$$12$$...`. Verify with `sudo docker compose config | grep PASSWORD_HASH` — the printed value must show single `$`. Most common cause of broken wg-easy login.
- **Env changes require recreate, not restart.** `down && up -d` — env is baked at container creation.
- **`.env` is gitignored; so are `wg-data/`, `awg-data/`, and `xray/config.json`.** Real keys never leave the host. The `.example` files are safe templates and are committed.
- **Required host kernel:** UDP forwarding (`net.ipv4.ip_forward=1`) is set per-container via sysctls. wg-easy needs the host's WireGuard kernel module; AWG uses userspace so it only needs `/dev/net/tun` (already wired up in `docker-compose.yml`).

### wg-easy

- **`WG_ALLOWED_IPS` changes affect new clients only.** Existing clients keep their downloaded `.conf`; re-issue if they need new routing.

### XRAY (VLESS + Reality)

- **`config.json` does not support env-var interpolation.** All secrets (UUID, private key, short ID) are written directly into the JSON. That's why the real file is gitignored and `config.example.json` is the template.
- **`dest` and `serverNames` must match what real clients send as SNI.** Both are set to `mail.kz`. If you change the impersonation target, change both fields together.
- **Verify the impersonation target supports TLS 1.3 + X25519** before trusting it. Quick test:
  ```bash
  openssl s_client -connect mail.kz:443 -tls1_3 -groups X25519 -servername mail.kz </dev/null 2>&1 | grep -E 'Protocol|Cipher'
  ```
  Must show `Protocol: TLSv1.3`. If not, pick another target (`www.microsoft.com`, `www.cloudflare.com`, `dl.google.com` are battle-tested).
- **Each client needs its own UUID.** Add one `{ "id": "...", "flow": "xtls-rprx-vision" }` entry per client under `inbounds[0].settings.clients`, then `sudo docker compose restart xray`.
- **Client connection string (paste into v2rayNG / v2rayN / Nekoray):**
  ```
  vless://<UUID>@<WG_HOST>:443?security=reality&encryption=none&pbk=<REALITY_PUBLIC_KEY>&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=mail.kz&sid=<SHORT_ID>#name
  ```
  `pbk` is the public key from `xray x25519` (NOT the private one in `config.json`).

### AmneziaWG

- **There is no admin UI.** Clients are added by hand-editing `awg-data/awg0.conf` (a `[Peer]` block per device) and writing the matching client `.conf` with the same junk/header params.
- **`Jc`, `Jmin`, `Jmax`, `S1`, `S2`, `H1`-`H4` MUST be identical** on server and every client. Mismatch = silent handshake failure. The example values in `awg/awg0.example.conf` are sane defaults; if you regenerate `H1`-`H4`, propagate to every client config.
- **Userspace daemon.** Driven by `WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go` in `awg/entrypoint.sh`. If `awg-quick up` fails with "Unable to access interface: Protocol not supported," it means the env var isn't being honored — check it's exported before `awg-quick` runs.
- **Reload after editing `awg0.conf`:** `sudo docker compose restart awg`. The container ignores config changes otherwise.
- **AWG image is built locally** (`sudo docker compose build awg` or `up --build`). After bumping `amneziawg-go`/`amneziawg-tools` upstream, rebuild with `--no-cache`.

## Scope

Operational config only. If a change can't be expressed as edits to `docker-compose.yml`, the three config templates, `awg/Dockerfile`/`entrypoint.sh`, or `.env.example`/`README.md`/`CLAUDE.md`, question whether it belongs here. Don't introduce build tooling, test frameworks, linters, or CI scaffolding — there is nothing to build, test, or lint in the application sense.
