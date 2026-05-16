#!/usr/bin/env bash
# Remove an AmneziaWG client.
#
# Usage:  scripts/awg-remove-user.sh <client-name>
#
# Deletes the matching [Peer] block from awg-data/awg0.conf, drops the
# corresponding awg-data/urls/<name>.txt, and restarts the awg container.
#
# Only removes peers that this script set added (i.e. ones written with a
# leading "# <name>" comment line). Manually-added peers without that
# comment won't be matched — edit awg-data/awg0.conf by hand for those.

set -euo pipefail

usage() {
    cat <<EOF >&2
Usage: $0 <client-name>

<client-name>   the name passed to awg-add-user.sh when the peer was created.
                Must match [A-Za-z0-9._-]+.

The script removes:
  - the leading "# <client-name>" comment line in awg-data/awg0.conf
  - the [Peer] / PublicKey / AllowedIPs lines that follow it
  - awg-data/urls/<client-name>.txt
Then restarts the awg container so the change takes effect.
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
URL_FILE="$REPO_ROOT/awg-data/urls/$NAME.txt"

command -v docker >/dev/null || { echo "error: docker not installed" >&2; exit 1; }
[ -f "$SERVER_CONF" ] || { echo "error: $SERVER_CONF missing" >&2; exit 1; }

# Refuse if the named peer isn't present — sed would happily delete the
# wrong range if its start pattern doesn't match.
if ! grep -qE "^# ${NAME}\$" "$SERVER_CONF"; then
    echo "error: no peer marker '# $NAME' in $SERVER_CONF" >&2
    echo "       (manually-added peers without a leading comment must be edited by hand)" >&2
    exit 1
fi

# Capture the peer's IP for the summary, before deletion.
PEER_IP="$(awk -v name="$NAME" '
    $0 == "# " name { found = 1; next }
    found && /^AllowedIPs[[:space:]]*=/ { print $3; exit }
' "$SERVER_CONF")"

# Atomic edit: build to a temp file, then mv.
TMP="$(mktemp "${SERVER_CONF}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
# Delete the inclusive range:  "# name" ... first following "AllowedIPs = ..."
# That covers our 4-line block ("# name", "[Peer]", "PublicKey", "AllowedIPs").
sed "/^# ${NAME}\$/,/^AllowedIPs[[:space:]]*=/d" "$SERVER_CONF" > "$TMP"

# Preserve mode + ownership of the original file.
chmod --reference="$SERVER_CONF" "$TMP"
chown --reference="$SERVER_CONF" "$TMP" 2>/dev/null || true
mv "$TMP" "$SERVER_CONF"

# Drop the URL file too (no error if absent).
rm -f "$URL_FILE"

# Reload AWG so the peer is forgotten.
( cd "$REPO_ROOT" && docker compose restart awg )

echo
echo "removed AWG client '$NAME'"
[ -n "$PEER_IP" ] && echo "  IP was:  $PEER_IP"
echo "  url file: $URL_FILE (removed if existed)"
