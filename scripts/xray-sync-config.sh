#!/usr/bin/env bash
# Apply structural Reality params from .env to xray/config.json.
#
# Use this on fresh installs (no config.json yet) and any time you rotate the
# Reality private key, change the impersonation target (SNI), or change the
# short ID. Idempotent — clients[] array is preserved across runs.
#
# Usage:  scripts/xray-sync-config.sh [--restart]
#
# Reads from .env:
#   XRAY_PORT, XRAY_REALITY_PRIVATE_KEY, XRAY_SNI, XRAY_SHORT_ID
#
# Writes to xray/config.json:
#   inbounds[0].port
#   inbounds[0].streamSettings.realitySettings.privateKey
#   inbounds[0].streamSettings.realitySettings.serverNames = [XRAY_SNI]
#   inbounds[0].streamSettings.realitySettings.dest        = "XRAY_SNI:443"
#   inbounds[0].streamSettings.realitySettings.shortIds    = [XRAY_SHORT_ID]
#
# Pass --restart to also run 'docker compose restart xray' at the end.

set -euo pipefail

usage() {
    cat <<EOF >&2
Usage: $0 [--restart]

Reads XRAY_PORT, XRAY_REALITY_PRIVATE_KEY, XRAY_SNI, XRAY_SHORT_ID from .env
and writes them into xray/config.json (creating it from xray/config.example.json
if absent). Preserves the existing clients[] array.

  --restart   run 'docker compose restart xray' after writing config.json
EOF
    exit 1
}

RESTART=0
for arg in "$@"; do
    case "$arg" in
        --restart) RESTART=1 ;;
        -h|--help) usage ;;
        *) echo "error: unknown argument '$arg'" >&2; usage ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$REPO_ROOT/xray/config.json"
TEMPLATE="$REPO_ROOT/xray/config.example.json"
ENV_FILE="$REPO_ROOT/.env"

command -v jq >/dev/null || { echo "error: jq not installed (apt-get install jq)" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "error: $TEMPLATE missing" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "error: $ENV_FILE missing" >&2; exit 1; }

env_get() {
    grep -E "^${1}=" "$ENV_FILE" | head -1 | cut -d= -f2- \
        | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}
XRAY_PORT="$(env_get XRAY_PORT)"
PRIV="$(env_get XRAY_REALITY_PRIVATE_KEY)"
SNI="$(env_get XRAY_SNI)"
SHORT_ID="$(env_get XRAY_SHORT_ID)"

missing=()
[ -n "$XRAY_PORT" ] || missing+=("XRAY_PORT")
[ -n "$PRIV"      ] || missing+=("XRAY_REALITY_PRIVATE_KEY")
[ -n "$SNI"       ] || missing+=("XRAY_SNI")
[ -n "$SHORT_ID"  ] || missing+=("XRAY_SHORT_ID")
if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: missing in .env: ${missing[*]}" >&2
    exit 1
fi

# Source = existing config.json if present (preserves clients), else the template.
if [ -f "$CONFIG" ]; then
    SRC="$CONFIG"
    CREATED=0
else
    SRC="$TEMPLATE"
    CREATED=1
fi

# Atomic write: build into a temp file in the same directory and mv.
TMP="$(mktemp "${CONFIG}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# Cast port to a JSON number (jq's --arg always passes strings).
jq --argjson port "$XRAY_PORT" \
   --arg priv "$PRIV" \
   --arg sni "$SNI" \
   --arg sid "$SHORT_ID" \
   '.inbounds[0].port = $port
    | .inbounds[0].streamSettings.realitySettings.privateKey  = $priv
    | .inbounds[0].streamSettings.realitySettings.serverNames = [$sni]
    | .inbounds[0].streamSettings.realitySettings.dest        = ($sni + ":443")
    | .inbounds[0].streamSettings.realitySettings.shortIds    = [$sid]
   ' "$SRC" > "$TMP"

# When created from the template, the placeholder client is meaningless — drop it.
# It carries the literal string "REPLACE_WITH_UUID" which xray would refuse.
if [ "$CREATED" -eq 1 ]; then
    jq '.inbounds[0].settings.clients = []' "$TMP" > "$TMP.2" && mv "$TMP.2" "$TMP"
fi

mv "$TMP" "$CONFIG"

if [ "$CREATED" -eq 1 ]; then
    echo "created $CONFIG from template; clients[] is empty"
    echo "next: scripts/xray-add-user.sh <name>   to add the first client"
else
    echo "updated $CONFIG in place; clients[] preserved"
fi

if [ "$RESTART" -eq 1 ]; then
    ( cd "$REPO_ROOT" && docker compose restart xray )
else
    echo "run 'docker compose restart xray' (or pass --restart) to apply"
fi
