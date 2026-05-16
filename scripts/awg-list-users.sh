#!/usr/bin/env bash
# List AmneziaWG clients with their live state.
#
# Usage:  scripts/awg-list-users.sh
#
# Joins two sources:
#   awg-data/awg0.conf       — names and AllowedIPs of peers we registered
#   docker exec awg awg show — live handshake + transfer counters
#
# Peers added without a "# <name>" comment line appear as "(unnamed)".

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_CONF="$REPO_ROOT/awg-data/awg0.conf"

command -v docker >/dev/null || { echo "error: docker not installed" >&2; exit 1; }
[ -f "$SERVER_CONF" ] || { echo "error: $SERVER_CONF missing" >&2; exit 1; }

# Build pubkey -> {name, ip} maps from awg0.conf.
#
# A "# <name>" comment only counts as a peer name when:
#   - it matches /^# <single-token>$/ where <single-token> = [A-Za-z0-9._-]+
#   - and nothing other than blank lines / further-replacing "# name" lines
#     appears between it and the [Peer] header.
#
# PublicKey / AllowedIPs values are parsed whitespace-agnostically so the
# script tolerates "Key = Value", "Key=Value", "Key =Value", and friends.
declare -A NAME_BY_KEY IP_BY_KEY
while IFS=$'\t' read -r name pub ip; do
    [ -n "$pub" ] || continue
    [ -n "$ip"  ] || continue
    NAME_BY_KEY[$pub]="${name:-(unnamed)}"
    IP_BY_KEY[$pub]="$ip"
done < <(awk '
    /^# [A-Za-z0-9._-]+[[:space:]]*$/ {
        name = $2
        sub(/[[:space:]]+$/, "", name)
        next
    }
    /^#/ { name = ""; next }              # any other comment: clear pending name
    /^[[:space:]]*$/ { next }             # blank line: keep state
    /^\[Peer\]/ {                          # start of a peer block
        pub = ""
        next
    }
    /^\[/ {                                # any other section header
        name = ""; pub = ""
        next
    }
    /^PublicKey/ {
        line = $0
        sub(/^PublicKey[[:space:]]*=[[:space:]]*/, "", line)
        sub(/[[:space:]]+$/, "", line)
        pub = line
        next
    }
    /^AllowedIPs/ {
        line = $0
        sub(/^AllowedIPs[[:space:]]*=[[:space:]]*/, "", line)
        sub(/,.*$/, "", line)               # take first CIDR if comma-list
        sub(/\/[0-9]+.*$/, "", line)        # strip the /NN prefix
        sub(/[[:space:]]+$/, "", line)
        if (pub != "" && line != "") {
            # Emit a literal "(unnamed)" placeholder when no name was captured.
            # If we wrote an empty first field here, `read -r ... ` would strip
            # the leading TAB (it's whitespace under POSIX rules) and shift
            # the values left, losing the IP.
            printf "%s\t%s\t%s\n", (name == "" ? "(unnamed)" : name), pub, line
        }
        name = ""; pub = ""
        next
    }
    # Any other directive (PrivateKey, Address, ListenPort, Jc, ...) outside
    # an active peer block resets any pending name.
    /^[A-Za-z]/ {
        if (pub == "") name = ""
    }
' "$SERVER_CONF")

human_bytes() {
    awk -v b="$1" 'BEGIN {
        if (b < 1024)            printf "%d B",   b
        else if (b < 1048576)    printf "%.1f KiB", b/1024
        else if (b < 1073741824) printf "%.1f MiB", b/1048576
        else                     printf "%.2f GiB", b/1073741824
    }'
}

human_age() {
    local ts="$1"
    if [ "$ts" = "0" ] || [ -z "$ts" ]; then echo "never"; return; fi
    local now diff
    now=$(date +%s)
    diff=$(( now - ts ))
    if   [ "$diff" -lt 60 ];     then echo "${diff}s ago"
    elif [ "$diff" -lt 3600 ];   then echo "$(( diff / 60 ))m ago"
    elif [ "$diff" -lt 86400 ];  then echo "$(( diff / 3600 ))h ago"
    else                              echo "$(( diff / 86400 ))d ago"
    fi
}

# WireGuard has no explicit "connected" state. We infer one from the last
# handshake age. Threshold = 180s (REJECT_AFTER_TIME) — the protocol's own
# cutoff for considering a session dead. With PersistentKeepalive = 25,
# a live peer renews every ~25s, so anything beyond 3 min is reliably gone.
peer_status() {
    local ts="$1"
    if [ "$ts" = "0" ] || [ -z "$ts" ]; then echo "—"; return; fi
    local now diff
    now=$(date +%s)
    diff=$(( now - ts ))
    if [ "$diff" -le 180 ]; then echo "online"; else echo "offline"; fi
}

printf '%-20s  %-8s  %-12s  %-14s  %-12s  %s\n' \
    "NAME" "STATUS" "IP" "PUBKEY (last)" "HANDSHAKE" "RX / TX"

# Live state from `awg show awg0 dump`. Format per peer (one line, TSV):
#   <pubkey>  <psk>  <endpoint>  <allowed-ips>  <latest-handshake>  <rx>  <tx>  <keepalive>
# Line 1 is the interface itself (different shape); skip it.
#
# Process-substitution feed so the loop runs in the parent shell and can
# read NAME_BY_KEY / IP_BY_KEY directly.
while IFS=$'\t' read -r pub _psk _endpoint _allowed handshake rx tx _ka; do
    [ -n "$pub" ] || continue
    name="${NAME_BY_KEY[$pub]:-(unnamed)}"
    ip="${IP_BY_KEY[$pub]:-?}"
    key_tail="…${pub: -10}"
    printf '%-20s  %-8s  %-12s  %-14s  %-12s  %s / %s\n' \
        "$name" \
        "$(peer_status "$handshake")" \
        "$ip" "$key_tail" \
        "$(human_age "$handshake")" \
        "$(human_bytes "$rx")" "$(human_bytes "$tx")"
done < <(docker exec awg awg show awg0 dump 2>/dev/null | tail -n +2)
