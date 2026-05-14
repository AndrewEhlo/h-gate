# Host hardening for h-gate

Steps to harden a fresh Ubuntu 24.04 VPS before (or alongside) deploying the h-gate stack. Cuts off the largest exposures — root over SSH, password auth, port 22 brute force — and applies persistent fail2ban + sysctl defenses.

Nothing here is specific to h-gate; it's standard Linux host hardening. Listed separately from `README.md` because it's a one-time setup, not operational.

## Variables

Fill in your own values once at the top of the shell session; every command below uses these.

```bash
ADMIN_USER=...    # non-root admin name. Avoid 'admin', 'ubuntu', 'root'.
SSH_PORT=...      # high TCP port, not 22. Reduces log noise; not real protection.
PUBKEY=...        # contents of your workstation's .pub file, single line
```

## Cutover principle

Every revocable change is gated by a verified-working alternative before the previous access path is removed. Keep **two** independent SSH sessions open during the cutover — the original `root@22` plus a new `$ADMIN_USER@$SSH_PORT` — as a recovery belt. Don't skip a verification step to save a round trip; a locked-out VPS costs more than a paste.

## 1. Create the admin user with SSH key

```bash
sudo adduser --disabled-password --gecos "" "$ADMIN_USER"
sudo passwd "$ADMIN_USER"     # for sudo only; SSH stays key-only
sudo usermod -aG sudo "$ADMIN_USER"

sudo install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
echo "$PUBKEY" | sudo tee "/home/$ADMIN_USER/.ssh/authorized_keys" >/dev/null
sudo chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh/authorized_keys"
sudo chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"

sudo -u "$ADMIN_USER" -- sudo -k -v && echo "sudo OK"
```

## 2. Firewall — open new SSH port before sshd binds it

If ufw isn't already set up:

```bash
sudo apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp                # keep current SSH alive
sudo ufw allow 443/tcp               # xray
# Add wg-easy / awg when deployed:
# sudo ufw allow 51820/udp           # wg-easy
# sudo ufw allow 51821/tcp           # wg-easy web UI
# sudo ufw allow 51822/udp           # awg
sudo ufw --force enable
```

Then add the new SSH port:

```bash
sudo ufw allow "$SSH_PORT/tcp" comment 'ssh (new port)'
sudo ufw status numbered
```

Note: Docker publishes container ports via its own iptables chains, which bypass ufw. The 443/51820/51821/51822 rules above are for visibility/audit, not enforcement — Docker will accept those ports either way once the containers run.

## 3. Make sshd listen on 22 AND the new port

**Critical gotcha.** Ubuntu 24.04 uses socket-activated sshd. The `Port` directive in `/etc/ssh/sshd_config` (and its drop-in directory) is **ignored** — the listening port is owned by `ssh.socket`. Editing `sshd_config` for the port silently does nothing.

Additional gotcha: the vendor `ssh.socket` unit sets `BindIPv6Only=ipv6-only`, so a bare `ListenStream=<port>` creates a v6-only socket that rejects IPv4 connections with `Connection refused`. Both v4 and v6 must be listed explicitly.

```bash
sudo mkdir -p /etc/systemd/system/ssh.socket.d
sudo tee /etc/systemd/system/ssh.socket.d/override.conf >/dev/null <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:22
ListenStream=[::]:22
ListenStream=0.0.0.0:$SSH_PORT
ListenStream=[::]:$SSH_PORT
EOF

sudo systemctl daemon-reload
sudo systemctl restart ssh.socket
sudo systemctl restart ssh.service

sudo ss -tlnp | grep -E ":22 |:$SSH_PORT "
```

Expect four LISTEN lines (v4 + v6 for each port).

## 4. Verify new-port login BEFORE locking anything down

From your workstation in a **fresh terminal**:

```
ssh -p $SSH_PORT -i <path-to-private-key> $ADMIN_USER@<vps>
```

Once in:

```bash
whoami
sudo -v          # enter password
```

Keep this session and the original root session both open through step 6.

## 5. Harden sshd auth policy

```bash
sudo tee /etc/ssh/sshd_config.d/20-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no

X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no

MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

sudo sshd -t && echo "sshd config OK"
sudo systemctl restart ssh.service
```

**Gotcha: dual sshd.** If `ssh.service` was started directly at any point earlier (e.g. via `systemctl reload ssh` on a non-running service), both it and `ssh.socket` may be active simultaneously, with the long-lived daemon serving requests from its **pre-hardening cached config**. `sshd -T` reads from disk and reports the new values, but live connections honour the old ones. Symptoms: password root login still succeeds while `sshd -T` says `permitrootlogin no`. Always restart `ssh.service` after editing drop-ins, and check `ps -ef | grep '[s]shd: /usr/sbin/sshd'` shows exactly one fresh listener.

**Gotcha: `50-cloud-init.conf`.** Cloud-init drops `/etc/ssh/sshd_config.d/50-cloud-init.conf` containing `PasswordAuthentication yes`. The `20-` prefix on our drop-in makes it win (sshd uses first-match within the lex-sorted include set). Do not rename our drop-in to a number ≥ 50.

### Verify from workstation (each in a fresh terminal)

| Test | Expected |
|---|---|
| `ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@<vps>` | rejected |
| `ssh -i <key> root@<vps>` | rejected (no key on root) |
| `ssh -p $SSH_PORT -o PreferredAuthentications=password -o PubkeyAuthentication=no $ADMIN_USER@<vps>` | rejected |
| `ssh -p $SSH_PORT -i <key> $ADMIN_USER@<vps>` | succeeds |

Only proceed once the first three reliably fail.

## 6. Close port 22

From a session on the new port (not the root@22 session — that one's about to lose its listener):

```bash
sudo tee /etc/systemd/system/ssh.socket.d/override.conf >/dev/null <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:$SSH_PORT
ListenStream=[::]:$SSH_PORT
EOF

sudo systemctl daemon-reload
sudo systemctl restart ssh.socket
sudo systemctl restart ssh.service

sudo ufw delete allow 22/tcp
sudo ufw status
```

From workstation: `ssh root@<vps>` should now fail with `Connection refused`.

## 7. fail2ban

```bash
sudo apt-get install -y fail2ban

sudo tee /etc/fail2ban/jail.local >/dev/null <<EOF
[DEFAULT]
# Ubuntu 24.04 doesn't always have /var/log/auth.log; read from journal
backend  = systemd
bantime  = 1h
findtime = 10m
maxretry = 5
# Escalate bans geometrically for repeat offenders
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = $SSH_PORT
EOF

sudo fail2ban-client -t
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

Add static admin IPs to `ignoreip` if you have them. With key-only auth in place, the practical risk of self-banning is low, but a typo against `MaxAuthTries=3` plus an inherited Windows password prompt can still get you on the list.

## 8. Sysctl

```bash
sudo tee /etc/sysctl.d/99-hardening.conf >/dev/null <<'EOF'
# This host is not a router that should hint clients about better gateways.
net.ipv4.conf.all.send_redirects     = 0
net.ipv4.conf.default.send_redirects = 0

# Log packets with impossible source addresses. Cheap diagnostic for spoofing
# attempts and misconfigured peers; nothing logs under normal operation.
net.ipv4.conf.all.log_martians     = 1
net.ipv4.conf.default.log_martians = 1
EOF

sudo sysctl --system
```

**Do not** tighten `net.ipv4.conf.all.rp_filter` to strict (`1`) — it breaks asymmetric routing once WireGuard/AmneziaWG come up. Leave it at the Ubuntu default `2` (loose).

**Do not** touch `net.ipv4.ip_forward` — Docker sets it to `1` and the VPN services need it.

## 9. Verification

```bash
echo "=== sshd policy ==="
sudo sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|maxauthtries|x11forwarding|allowtcpforwarding|allowagentforwarding)\b' | sort

echo "=== listeners ==="
sudo ss -tulnp | grep -vE 'systemd-resolve|127\.0\.0\.5'

echo "=== ufw ==="
sudo ufw status verbose

echo "=== fail2ban ==="
sudo fail2ban-client status sshd

echo "=== sysctl ==="
sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter \
       net.ipv4.conf.all.send_redirects net.ipv4.conf.all.log_martians \
       net.ipv4.tcp_syncookies

echo "=== unattended-upgrades ==="
systemctl is-active unattended-upgrades apt-daily.timer apt-daily-upgrade.timer
```

Pass criteria:

- sshd: `permitrootlogin no`, `passwordauthentication no`, `kbdinteractiveauthentication no`
- listeners: sshd on `$SSH_PORT` only (no `:22`); docker-proxy on 443; nothing else exposed beyond `127.0.0.*`
- ufw: active, allows `$SSH_PORT/tcp` and `443/tcp` (and WG/AWG ports if deployed), no `22/tcp`
- fail2ban: sshd jail active, reading `_SYSTEMD_UNIT=sshd.service`
- sysctl: `ip_forward=1`, `rp_filter=2`, `send_redirects=0`, `log_martians=1`, `tcp_syncookies=1`
- unattended-upgrades: `active` along with both apt timers

## Operational notes

- **Do not add `$ADMIN_USER` to the `docker` group.** Membership is equivalent to passwordless root via `docker run --privileged -v /:/host`. Use `sudo docker ...` — sudo is the audit gate.
- **Workstation `~/.ssh/config`** — once verified, add a `Host` block so `ssh <alias>` works without flags:
  ```
  Host <alias>
      HostName <vps>
      User <admin>
      Port <ssh-port>
      IdentityFile <path-to-private-key>
      IdentitiesOnly yes
  ```
  `IdentitiesOnly yes` prevents the client from offering every key in `.ssh/`, which can trip `MaxAuthTries=3` on the server.
- **Adding more services** — when wg-easy / awg are deployed, add the matching `ufw allow` rules. Docker will accept the traffic regardless, but explicit rules keep `ufw status` accurate.

## Out of scope

Worth doing eventually, not covered here:

- Docker daemon log rotation (`/etc/docker/daemon.json` → `log-opts.max-size`, `max-file`)
- `Unattended-Upgrade::Automatic-Reboot "true"` with a maintenance window, once the host is production
- Second admin user and second SSH key to avoid single-key dependency
- Monitoring / alerting on fail2ban bans, sshd auth failures, journal log-martians entries
