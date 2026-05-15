#!/usr/bin/env bash
# Add a new AmneziaWG client and print an importable vpn:// URL.
#
# Usage:  scripts/awg-add-user.sh <client-name>
#
# Generates a fresh keypair via the running awg container, picks the next
# free 10.9.0.X address, appends a [Peer] block to awg-data/awg0.conf,
# restarts the awg container, and prints a single-line vpn:// URL for
# the AmneziaVPN client to import.
#
# Run with sudo: the script needs to read awg-data/awg0.conf (mode 600)
# and talk to the docker daemon.

set -euo pipefail

usage() {
    cat <<EOF >&2
Usage: $0 <client-name>

<client-name>   identifier for this client. Used as the JSON description
                inside the vpn:// payload. Must match [A-Za-z0-9._-]+.

Reads from .env:
  WG_HOST                     host clients connect to
  AWG_PORT                    UDP port (default 51822 if unset, falls back
                              to awg-data/awg0.conf's ListenPort)

Reads from awg-data/awg0.conf:
  [Interface] PrivateKey      used to derive the server's public key
  [Interface] obfuscation     Jc/Jmin/Jmax/S1/S2/H1..H4 copied verbatim
                              into the client config (must match server)
  [Peer] AllowedIPs lines     scanned to pick the next free 10.9.0.X

Prints the vpn:// URL on stdout. Other output goes to stderr so the URL
can be redirected cleanly:  scripts/awg-add-user.sh alice > alice.url
EOF
    exit 1
}

[ $# -eq 1 ] && [ -n "${1:-}" ] || usage
NAME="$1"

if ! [[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "error: client name must match [A-Za-z0-9._-]+" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_CONF="$REPO_ROOT/awg-data/awg0.conf"
ENV_FILE="$REPO_ROOT/.env"

command -v docker  >/dev/null || { echo "error: docker not installed" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not installed" >&2; exit 1; }
[ -f "$SERVER_CONF" ] || { echo "error: $SERVER_CONF missing" >&2; exit 1; }
[ -f "$ENV_FILE"    ] || { echo "error: $ENV_FILE missing" >&2; exit 1; }

# .env values without sourcing the file.
env_get() {
    grep -E "^${1}=" "$ENV_FILE" | head -1 | cut -d= -f2- \
        | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}
WG_HOST="$(env_get WG_HOST)"
AWG_PORT="$(env_get AWG_PORT)"
[ -n "$WG_HOST" ] || { echo "error: WG_HOST missing in .env" >&2; exit 1; }

# Single key=value pair from the [Interface] block (stop at first [Peer]).
# Values here are single tokens — numbers or base64 — so $3 is enough.
iface_get() {
    awk -v key="$1" '
        /^\[Peer\]/ { exit }
        $1 == key && $2 == "=" { print $3; exit }
    ' "$SERVER_CONF"
}

PRIV="$(iface_get PrivateKey)"
[ -n "$PRIV" ] || { echo "error: PrivateKey missing in $SERVER_CONF [Interface]" >&2; exit 1; }

JC="$(iface_get Jc)"
JMIN="$(iface_get Jmin)"
JMAX="$(iface_get Jmax)"
S1="$(iface_get S1)";  S1="${S1:-0}"
S2="$(iface_get S2)";  S2="${S2:-0}"
H1="$(iface_get H1)"
H2="$(iface_get H2)"
H3="$(iface_get H3)"
H4="$(iface_get H4)"
LISTEN_PORT="$(iface_get ListenPort)"
LISTEN_PORT="${LISTEN_PORT:-${AWG_PORT:-51822}}"

missing=()
for v in JC JMIN JMAX H1 H2 H3 H4; do
    eval "val=\${$v}"
    [ -n "$val" ] || missing+=("$v")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: missing in $SERVER_CONF [Interface]: ${missing[*]}" >&2
    exit 1
fi

# Derive server's public key from its private key.
SERVER_PUB="$(printf '%s' "$PRIV" | docker exec -i awg awg pubkey | tr -d '[:space:]')"
[ -n "$SERVER_PUB" ] || { echo "error: failed to derive server PublicKey (is the awg container running?)" >&2; exit 1; }

# Scan existing AllowedIPs for 10.9.0.X/32 entries, pick next free.
# 10.9.0.1 is the server.
declare -A used=([1]=1)
while IFS= read -r line; do
    IFS=',' read -ra parts <<<"${line#*=}"
    for part in "${parts[@]}"; do
        part="${part// /}"
        if [[ "$part" =~ ^10\.9\.0\.([0-9]+)/32$ ]]; then
            used[${BASH_REMATCH[1]}]=1
        fi
    done
done < <(grep -E '^[[:space:]]*AllowedIPs[[:space:]]*=' "$SERVER_CONF")

NEXT_OCTET=""
for i in $(seq 2 254); do
    if [ -z "${used[$i]:-}" ]; then
        NEXT_OCTET="$i"
        break
    fi
done
[ -n "$NEXT_OCTET" ] || { echo "error: no free IP in 10.9.0.0/24" >&2; exit 1; }
NEXT_IP="10.9.0.$NEXT_OCTET"

# Generate the client keypair via the awg container so binary versions match.
CLIENT_PRIV="$(docker exec awg awg genkey | tr -d '[:space:]')"
CLIENT_PUB="$(printf '%s' "$CLIENT_PRIV" | docker exec -i awg awg pubkey | tr -d '[:space:]')"
[ -n "$CLIENT_PRIV" ] && [ -n "$CLIENT_PUB" ] \
    || { echo "error: failed to generate client keypair" >&2; exit 1; }

# Append [Peer] block to server config and reload AWG.
{
    printf '\n# %s\n' "$NAME"
    printf '[Peer]\n'
    printf 'PublicKey = %s\n' "$CLIENT_PUB"
    printf 'AllowedIPs = %s/32\n' "$NEXT_IP"
} >> "$SERVER_CONF"

( cd "$REPO_ROOT" && docker compose restart awg ) >&2

# Build the standard WireGuard .conf body. This is what AmneziaVPN nests
# inside the vpn:// payload as "last_config" — it's also what you'd paste
# directly if the URL format ever stops working.
CONF_TEXT="$(cat <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = $NEXT_IP/32
DNS = 1.1.1.1

Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $WG_HOST:$LISTEN_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
)"

# Encode as a vpn:// URL: JSON payload → qCompress (Qt-style: 4-byte BE
# uncompressed length + zlib stream) → base64url. AmneziaVPN's schema for
# AWG isn't publicly specced — obfuscation params are lifted out of the
# .conf and set as explicit fields on the awg object so the app classifies
# the container as proper AmneziaWG (not "AmneziaWG Legacy" = vanilla WG).
URL="$(printf '%s' "$CONF_TEXT" | python3 - "$NAME" "$WG_HOST" "$LISTEN_PORT" <<'PY_EOF'
import sys, json, zlib, base64, struct, re

name, host, port = sys.argv[1:4]
conf = sys.stdin.read()

def grab(key):
    m = re.search(rf'^{key}\s*=\s*(\S+)', conf, re.MULTILINE)
    return m.group(1) if m else None

awg = {
    "last_config":           conf,
    "transport_proto":       "udp",
    "port":                  str(port),
    "isObfuscationEnabled":  True,
}
for k in ("Jc", "Jmin", "Jmax", "S1", "S2", "H1", "H2", "H3", "H4"):
    v = grab(k)
    if v is not None:
        awg[k] = v

payload = {
    "description":      name,
    "hostName":         host,
    "dns1":             "1.1.1.1",
    "dns2":             "1.0.0.1",
    "defaultContainer": "amnezia-awg",
    "containers": [{
        "container":   "amnezia-awg",
        # Inner key matches the container name. Using "awg" here caused
        # AmneziaVPN to import as "AmneziaWG Legacy" (no obfuscation).
        "amnezia-awg": awg,
    }],
}

data        = json.dumps(payload, separators=(',', ':')).encode('utf-8')
qcompressed = struct.pack('>I', len(data)) + zlib.compress(data, 9)
encoded     = base64.urlsafe_b64encode(qcompressed).decode('ascii')

print(f"vpn://{encoded}")
PY_EOF
)"

# Persist the URL so it can be re-fetched later without regenerating. One
# file per client; mode 600 since the URL embeds the client's PrivateKey
# inside the encoded payload. awg-data/ is already gitignored.
URL_DIR="$REPO_ROOT/awg-data/urls"
URL_FILE="$URL_DIR/$NAME.txt"
install -d -m 700 "$URL_DIR"
( umask 077 && printf '%s\n' "$URL" > "$URL_FILE" )

echo
echo "added AWG client '$NAME'"
echo "  IP:      $NEXT_IP/32"
echo "  pubkey:  $CLIENT_PUB"
echo "  url:     $URL_FILE"
echo
echo "vpn URL (paste into AmneziaVPN):"
echo "$URL"
