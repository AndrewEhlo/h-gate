#!/usr/bin/env bash
# Add a new VLESS+Reality client to xray/config.json, restart xray, and print
# the vless:// URL for the client.
#
# Usage:  scripts/xray-add-user.sh <client-name>
#
# Reads connection params (port, SNI, short ID, private key) from
# xray/config.json itself so the script can't drift from what the server
# actually accepts. The Reality public key is derived on the fly from the
# private key via 'xray x25519 -i'. Only WG_HOST comes from .env.

set -euo pipefail

usage() {
    cat <<EOF >&2
Usage: $0 <client-name>

<client-name>   used as the JSON 'email' field (uniqueness + xray stats)
                and as the #fragment in the vless:// URL.
                Must match [A-Za-z0-9._-]+.

Reads from .env:
  WG_HOST                     host clients connect to

Reads from xray/config.json:
  inbounds[0].port
  inbounds[0].streamSettings.realitySettings.serverNames[0]
  inbounds[0].streamSettings.realitySettings.shortIds[0]
  inbounds[0].streamSettings.realitySettings.privateKey
    (the matching public key is derived via 'xray x25519 -i')

Generates a UUID, appends a client to .inbounds[0].settings.clients,
runs 'docker compose restart xray', and prints the vless:// URL on stdout.
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
CONFIG="$REPO_ROOT/xray/config.json"
ENV_FILE="$REPO_ROOT/.env"

command -v jq     >/dev/null || { echo "error: jq not installed (apt-get install jq)" >&2; exit 1; }
command -v docker >/dev/null || { echo "error: docker not installed" >&2; exit 1; }
[ -f "$CONFIG"   ] || { echo "error: $CONFIG missing — run scripts/xray-sync-config.sh first" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "error: $ENV_FILE missing" >&2; exit 1; }

# Pull values from .env without sourcing it (sourcing would execute any shell
# code that ended up there). Strips matching surrounding quotes.
env_get() {
    grep -E "^${1}=" "$ENV_FILE" | head -1 | cut -d= -f2- \
        | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}
WG_HOST="$(env_get WG_HOST)"
[ -n "$WG_HOST" ] || { echo "error: WG_HOST missing in .env" >&2; exit 1; }

PORT="$(jq -r     '.inbounds[0].port                                  // empty' "$CONFIG")"
SNI="$(jq -r      '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$CONFIG")"
SHORT_ID="$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]    // empty' "$CONFIG")"
PRIV="$(jq -r     '.inbounds[0].streamSettings.realitySettings.privateKey     // empty' "$CONFIG")"

missing=()
[ -n "$PORT"     ] || missing+=("inbounds[0].port")
[ -n "$SNI"      ] || missing+=("realitySettings.serverNames[0]")
[ -n "$SHORT_ID" ] || missing+=("realitySettings.shortIds[0]")
[ -n "$PRIV"     ] || missing+=("realitySettings.privateKey")
if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: missing in $CONFIG: ${missing[*]}" >&2
    echo "       run scripts/xray-sync-config.sh to populate from .env" >&2
    exit 1
fi

# Derive the Reality public key from the private key. xray x25519 -i prints
# both lines; recent xray-core labels the public key "Password" (because it's
# the 'pbk' parameter clients use), older versions label it "Public key".
# Match either form.
PBK="$(docker run --rm teddysun/xray xray x25519 -i "$PRIV" 2>/dev/null \
       | grep -iE '^(Public[[:space:]]*key|Password)[[:space:]]*:' \
       | head -1 \
       | sed -E 's/^[^:]+:[[:space:]]*//' \
       | tr -d '[:space:]')"
[ -n "$PBK" ] || { echo "error: failed to derive Reality public key from privateKey via 'xray x25519 -i'" >&2; exit 1; }

# Refuse if the name is already used.
if jq -e --arg n "$NAME" '.inbounds[0].settings.clients[]? | select(.email == $n)' "$CONFIG" >/dev/null 2>&1; then
    echo "error: client '$NAME' already exists in $CONFIG" >&2
    exit 1
fi

UUID="$(docker run --rm teddysun/xray xray uuid | tr -d '[:space:]')"
[ -n "$UUID" ] || { echo "error: UUID generation failed" >&2; exit 1; }

# Atomic edit via a temp file in the same directory (same FS = atomic mv).
TMP="$(mktemp "${CONFIG}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
jq --arg id "$UUID" --arg email "$NAME" \
   '.inbounds[0].settings.clients += [{"id": $id, "flow": "xtls-rprx-vision", "email": $email}]' \
   "$CONFIG" > "$TMP"
mv "$TMP" "$CONFIG"

# Reload xray to pick up the new client. Compose project context is the repo root.
( cd "$REPO_ROOT" && docker compose restart xray )

URL="$(printf 'vless://%s@%s:%s?security=reality&encryption=none&pbk=%s&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=%s&sid=%s#%s' \
    "$UUID" "$WG_HOST" "$PORT" "$PBK" "$SNI" "$SHORT_ID" "$NAME")"

# Persist the URL so it can be re-fetched later without regenerating. One file
# per client; mode 600 since the URL embeds the UUID. The xray/urls/ directory
# is gitignored.
URL_DIR="$REPO_ROOT/xray/urls"
URL_FILE="$URL_DIR/$NAME.txt"
install -d -m 700 "$URL_DIR"
( umask 077 && printf '%s\n' "$URL" > "$URL_FILE" )

echo
echo "added client '$NAME'"
echo "  UUID:    $UUID"
echo "  config:  $CONFIG"
echo "  url:     $URL_FILE"
echo
echo "vless URL (paste into v2rayNG / v2rayN / Nekoray):"
echo "$URL"
