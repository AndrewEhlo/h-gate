#!/usr/bin/env bash
# List XRAY VLESS+Reality clients.
#
# Usage:  scripts/xray-list-users.sh
#
# Reads xray/config.json and prints a table of name (email) + UUID + whether
# a saved vless URL exists in xray/urls/. XRAY doesn't expose per-client
# connection state without enabling its stats service, so we only show
# what's in the config; live traffic data isn't available here.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$REPO_ROOT/xray/config.json"
URLS_DIR="$REPO_ROOT/xray/urls"

command -v jq >/dev/null || { echo "error: jq not installed (apt-get install jq)" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "error: $CONFIG missing" >&2; exit 1; }

count=$(jq '.inbounds[0].settings.clients | length' "$CONFIG")
if [ "$count" -eq 0 ]; then
    echo "no clients configured in $CONFIG"
    exit 0
fi

printf '%-20s  %-40s  %s\n' "NAME" "UUID" "URL FILE"

jq -r '.inbounds[0].settings.clients[] | [(.email // "(unnamed)"), .id] | @tsv' "$CONFIG" | \
while IFS=$'\t' read -r name uuid; do
    url_path="$URLS_DIR/$name.txt"
    if [ -f "$url_path" ]; then
        marker="$url_path"
    else
        marker="(missing)"
    fi
    printf '%-20s  %-40s  %s\n' "$name" "$uuid" "$marker"
done
