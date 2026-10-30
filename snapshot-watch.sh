#!/bin/bash
#
# snapshot-watch.sh - check snapshot.ubuntu.com every 5 minutes and show the status history.
# Probes the Nunchuk 2.9.1 pinned snapshot (dists/noble/Release). Read-only; downloads nothing.
#
# Usage: snapshot-watch.sh [SNAPSHOT]   (default 20261008T000000Z; Ctrl-C to stop)
#

SNAPSHOT="${1:-20261008T000000Z}"
URL="https://snapshot.ubuntu.com/ubuntu/${SNAPSHOT}/dists/noble/Release"
INTERVAL=300
history=()

while true; do
    code="$(curl -s -o /dev/null -m 20 -w '%{http_code}' "$URL")"
    history+=("${code} as of $(TZ=Asia/Manila date +%H:%M:%S)")
    [[ "$code" == "200" ]] && state="UP" || state="DOWN"

    clear
    echo "Snapshot.ubuntu.com is ${state}"
    echo ""
    printf '%s\n' "${history[@]}"

    sleep "$INTERVAL"
done
