#!/bin/bash
set -e

CONF=/etc/amnezia/amneziawg/awg0.conf
if [ ! -f "$CONF" ]; then
  echo "ERROR: $CONF not found." >&2
  echo "Copy awg/awg0.example.conf to awg-data/awg0.conf, fill in keys, restart." >&2
  exit 1
fi

# awg-quick uses this to spawn the userspace daemon instead of the kernel module.
export WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
export LOG_LEVEL=info

# awg-quick reads /etc/amneziawg/<name>.conf, so symlink our mounted dir there.
mkdir -p /etc/amneziawg
ln -sf /etc/amnezia/amneziawg/awg0.conf /etc/amneziawg/awg0.conf

shutdown() {
  awg-quick down awg0 || true
  exit 0
}
trap shutdown SIGTERM SIGINT

awg-quick up awg0
awg show

# Block forever; signals trigger shutdown trap.
sleep infinity &
wait $!
