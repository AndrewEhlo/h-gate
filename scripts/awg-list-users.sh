#!/usr/bin/env bash
# List AmneziaWG clients with their live state.
#
# Usage:  scripts/awg-list-users.sh
#
# Joins two sources:
#   awg-data/awg0.conf       — names and AllowedIPs of peers we registered
#   docker exec awg awg show — live handshake + transfer counters
#
# Peers added manually (without a "# <name>" comment line) appear as
# "(unnamed)" so they're still visible.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_CONF="$REPO_ROOT/awg-data/awg0.conf"

command -v docker >/dev/null || { echo "error: docker not installed" >&2; exit 1; }
[ -f "$SERVER_CONF" ] || { echo "error: $SERVER_CONF missing" >&2; exit 1; }

# Build pubkey -> name and pubkey -> IP maps from awg0.conf.
# awg-data/awg0.conf may be mode 600; sudo handles that.
declare -A NAME_BY_KEY IP_BY_KEY
while IFS=$'\t' read -r name pub ip; do
    [ -n "$pub" ] || continue
    NAME_BY_KEY[$pub]="${name:-(unnamed)}"
    IP_BY_KEY[$pub]="$ip"
done < <(awk '
    /^# /                              { name = substr($0, 3); next }
    /^\[Peer\]/                        { pub = ""; ip = ""; next }
    /^PublicKey[[:space:]]*=/          { pub = $3; next }
    /^AllowedIPs[[:space:]]*=/ {
        ip = $3; sub(/\/32.*$/, "", ip); sub(/,.*$/, "", ip)
        if (pub != "") {
            printf "%s\t%s\t%s\n", name, pub, ip
            name = ""
        }
    }
' "$SERVER_CONF")

# Live state from `awg show awg0 dump`. Format is one TSV line per peer:
#   <pubkey> <psk> <endpoint> <allowed-ips> <last-handshake> <rx-bytes> <tx-bytes> <keepalive>
# The first line is the interface itself; skip it.
human_bytes() {
    awk -v b="$1" 'BEGIN {
        if (b < 1024)      printf "%d B",   b
        else if (b < 1048576)  printf "%.1f KiB", b/1024
        else if (b < 1073741824) printf "%.1f MiB", b/1048576
        else printf "%.2f GiB", b/1073741824
    }'
}
human_age() {
    local ts="$1"
    if [ "$ts" = "0" ]; then echo "never"; return; fi
    local now diff
    now=$(date +%s)
    diff=$(( now - ts ))
    if   [ "$diff" -lt 60 ];     then echo "${diff}s ago"
    elif [ "$diff" -lt 3600 ];   then echo "$(( diff / 60 ))m ago"
    elif [ "$diff" -lt 86400 ];  then echo "$(( diff / 3600 ))h ago"
    else                              echo "$(( diff / 86400 ))d ago"
    fi
}

# Header.
printf '%-20s  %-12s  %-14s  %-12s  %s\n' \
    "NAME" "IP" "PUBKEY (last)" "HANDSHAKE" "RX / TX"

# Body. Tail -n +2 skips the interface line.
docker exec awg awg show awg0 dump 2>/dev/null | tail -n +2 | \
while IFS=$'\t' read -r pub _psk _endpoint _allowed handshake rx tx _ka; do
    [ -n "$pub" ] || continue
    name="${NAME_BY_KEY[$pub]:-(unnamed)}"
    ip="${IP_BY_KEY[$pub]:-?}"
    key_tail="…${pub: -10}"
    printf '%-20s  %-12s  %-14s  %-12s  %s / %s\n' \
        "$name" "$ip" "$key_tail" \
        "$(human_age "$handshake")" \
        "$(human_bytes "$rx")" "$(human_bytes "$tx")"
done
