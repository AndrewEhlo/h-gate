#!/usr/bin/env bash
# Remove an XRAY VLESS+Reality client.
#
# Usage:  scripts/xray-remove-user.sh <client-name>
#
# Deletes the matching entry from xray/config.json's
# .inbounds[0].settings.clients[] (by 'email' field), drops
# xray/urls/<client-name>.txt, and restarts the xray container.

set -euo pipefail

usage() {
    cat <<EOF >&2
Usage: $0 <client-name>

<client-name>   the name passed to xray-add-user.sh when the client was
                created (stored as the JSON 'email' field).
                Must match [A-Za-z0-9._-]+.
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
URL_FILE="$REPO_ROOT/xray/urls/$NAME.txt"

command -v jq     >/dev/null || { echo "error: jq not installed (apt-get install jq)" >&2; exit 1; }
command -v docker >/dev/null || { echo "error: docker not installed" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "error: $CONFIG missing" >&2; exit 1; }

# Refuse if the client isn't there.
if ! jq -e --arg n "$NAME" '.inbounds[0].settings.clients[]? | select(.email == $n)' "$CONFIG" >/dev/null 2>&1; then
    echo "error: client '$NAME' not found in $CONFIG" >&2
    exit 1
fi

# Capture the UUID for the summary, before deletion.
UUID="$(jq -r --arg n "$NAME" '.inbounds[0].settings.clients[] | select(.email == $n) | .id' "$CONFIG" | head -1)"

# Atomic edit: build to a temp file in the same directory, then mv.
TMP="$(mktemp "${CONFIG}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
jq --arg n "$NAME" \
   '.inbounds[0].settings.clients |= map(select(.email != $n))' \
   "$CONFIG" > "$TMP"

chmod --reference="$CONFIG" "$TMP"
chown --reference="$CONFIG" "$TMP" 2>/dev/null || true
mv "$TMP" "$CONFIG"

rm -f "$URL_FILE"

# Reload xray so the client's UUID stops being accepted.
( cd "$REPO_ROOT" && docker compose restart xray )

echo
echo "removed XRAY client '$NAME'"
echo "  UUID was: $UUID"
echo "  url file: $URL_FILE (removed if existed)"
