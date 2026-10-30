#!/usr/bin/env bash

# delete-bitcoinsafe-knots-bad-events.sh v0.1.0
#
# Publishes NIP-09 deletion requests for two WalletScrutiny Nostr events that
# were incorrectly tagged as bitcoin.safe even though they describe Bitcoin
# Knots v29.3.knots20260210.
#
# Context:
# - Event 92cf9f...2cef is kind 1063, an asset-registration event.
# - Event d68d6e...15c5 is kind 30301, a verification event.
# - Both were authored by Danny's Nostr pubkey:
#     1f9e547c2f31942623b8ad1d07713282e8640fd8cf474e9f79f18ace8af216ed
#   npub:
#     npub1r709glp0xx2zvgac45wswufjst5xgr7cear5a8me7x9vazhjzmksp2sf7d
# - NIP-09 deletion requests should be signed by the same key that authored the
#   target events.
#
# Safety:
# - Prompts for the private key with hidden input.
# - Does not echo or log the private key.
# - Uses NOSTR_SECRET_KEY only for the nak child processes, then unsets it.
#
# Requirements:
# - nak installed at /home/dannybuntu/go/bin/nak, or available in PATH.
#
# Usage:
#   ~/work/scripts/delete-bitcoinsafe-knots-bad-events.sh

set -euo pipefail

SCRIPT_VERSION="v0.1.0"
NAK="${NAK:-/home/dannybuntu/go/bin/nak}"

AUTHOR_PUBKEY="1f9e547c2f31942623b8ad1d07713282e8640fd8cf474e9f79f18ace8af216ed"
AUTHOR_NPUB="npub1r709glp0xx2zvgac45wswufjst5xgr7cear5a8me7x9vazhjzmksp2sf7d"

RELAYS=(
  "wss://relay.nostr.info/"
  "wss://nostr.mom/"
  "wss://relay.primal.net/"
  "wss://relay.damus.io/"
  "wss://nos.lol/"
)

TARGET_IDS=(
  "92cf9f7331e582fd50781187c1680320e7092de2bf3e905eb6d8835f70612cef"
  "d68d6e72d8174767d7227176d1e3ac0439c224c15db6d943615ef5646e9d15c5"
)

TARGET_KINDS=(
  "1063"
  "30301"
)

TARGET_REASONS=(
  "Delete mis-tagged Bitcoin Knots asset registration published under bitcoin.safe"
  "Delete mis-tagged Bitcoin Knots verification published under bitcoin.safe"
)

cleanup() {
  unset NOSTR_SECRET_KEY
}
trap cleanup EXIT

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '1,34p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ ! -x "$NAK" ]; then
  if command -v nak >/dev/null 2>&1; then
    NAK="$(command -v nak)"
  else
    echo "Error: nak not found. Expected: /home/dannybuntu/go/bin/nak"
    exit 1
  fi
fi

echo "WalletScrutiny bad Bitcoin Safe/Knots event deletion helper"
echo "Script version: $SCRIPT_VERSION"
echo "Signer must match:"
echo "  hex:  $AUTHOR_PUBKEY"
echo "  npub: $AUTHOR_NPUB"
echo
echo "Targets:"
for i in "${!TARGET_IDS[@]}"; do
  printf '  - kind %s  %s\n' "${TARGET_KINDS[$i]}" "${TARGET_IDS[$i]}"
done
echo

read -r -p "Continue and prompt for the matching private key? [y/N] " confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *)
    echo "Aborted."
    exit 0
    ;;
esac

printf 'Enter matching Nostr private key (nsec, ncryptsec, or hex): '
IFS= read -r -s NOSTR_SECRET_KEY
printf '\n'

if [ -z "$NOSTR_SECRET_KEY" ]; then
  echo "Error: empty private key."
  exit 1
fi

export NOSTR_SECRET_KEY

echo
echo "Publishing deletion requests..."
for i in "${!TARGET_IDS[@]}"; do
  target_id="${TARGET_IDS[$i]}"
  target_kind="${TARGET_KINDS[$i]}"
  reason="${TARGET_REASONS[$i]}"

  echo
  echo "Deleting kind $target_kind event:"
  echo "  $target_id"

  "$NAK" event \
    --confirm \
    -k 5 \
    -e "$target_id" \
    -t "k=$target_kind" \
    -c "$reason" \
    "${RELAYS[@]}"
done

echo
echo "Querying relays for deletion requests..."
for target_id in "${TARGET_IDS[@]}"; do
  echo
  echo "Deletion requests referencing:"
  echo "  $target_id"
  "$NAK" req \
    -k 5 \
    -e "$target_id" \
    "${RELAYS[@]}" || true
done

echo
echo "Done."
