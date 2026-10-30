# Fetch WalletScrutiny Kind 1063 Events

This helper note shows how to fetch Nostr asset-registration events (`kind 1063`) that are related to WalletScrutiny and print the uploader public key.

This is useful when you want to answer:

- who uploaded this APK?
- was it uploaded by WalletScrutiny Android?
- what Nostr pubkey signed the asset registration event?

## What This Filters

The commands below fetch `kind 1063` events and then filter for WalletScrutiny-related asset registrations using these checks:

- tag `client=WalletScrutiny.com`
- or `content` containing `WalletScrutiny Android`

That covers the Android app upload path and the normal WalletScrutiny client tag.

## Requirements

- `nak`
- `jq`

## Relay Set Used

These relays are used because they are already common in WalletScrutiny-related code:

- `wss://relay.nostr.band`
- `wss://relay.primal.net`
- `wss://relay.damus.io`
- `wss://nostr.mom`

## Bash Script

A script version now exists here:

- `/home/dannybuntu/work/scripts/nostr/fetch-ws-1063-events.sh`

## Helper Function

# Comment: run this in any shell
# Comment: multi-line command

```bash
fetch_ws_1063_events() {
  local app_id="$1"
  local version="${2:-}"
  local limit="${3:-200}"

  if [ -z "$app_id" ]; then
    echo "Usage: fetch_ws_1063_events <app_id> [version] [limit]" >&2
    return 1
  fi

  nak req \
    -k 1063 \
    -t "i=${app_id}" \
    ${version:+-t "version=${version}"} \
    -l "$limit" \
    wss://relay.nostr.band \
    wss://relay.primal.net \
    wss://relay.damus.io \
    wss://nostr.mom \
  | jq -r '
      select(
        any(.tags[]?; .[0] == "client" and .[1] == "WalletScrutiny.com")
        or (.content | tostring | test("WalletScrutiny Android"))
      )
      | {
          created_at,
          seen_utc: (.created_at | strftime("%Y-%m-%d %H:%M:%S UTC")),
          pubkey,
          id,
          appId: ([.tags[]? | select(.[0] == "i") | .[1]][0]),
          version: ([.tags[]? | select(.[0] == "version") | .[1]][0]),
          client: ([.tags[]? | select(.[0] == "client") | .[1]][0]),
          hashes: ([.tags[]? | select(.[0] == "x") | .[1]] | unique),
          content
        }
    '
}
```

## Example: Simple Bitcoin Wallet

# Comment: run this in any shell
# Comment: one line command

```bash
fetch_ws_1063_events com.btcontract.wallet 2.5.8
```

## Example Output Shape

```json
{
  "created_at": 1768491240,
  "seen_utc": "2026-01-15 14:34:00 UTC",
  "pubkey": "abcdef0123456789...",
  "id": "1234abcd...",
  "appId": "com.btcontract.wallet",
  "version": "2.5.8",
  "client": "WalletScrutiny.com",
  "hashes": [
    "f2faf0b12..."
  ],
  "content": "SBW: Simple Bitcoin Wallet v2.5.8 APK (uploaded by WalletScrutiny Android)"
}
```

## Notes

- The `pubkey` field is the uploader trace you are looking for.
- The event `id` can be used to cross-reference the raw Nostr event later.
- The `hashes` array comes from the `x` tags on the asset-registration event.
- If nothing is returned, try increasing the limit.

## Broader Query

If you want all WalletScrutiny-related `kind 1063` events for an app regardless of version:

# Comment: run this in any shell
# Comment: one line command

```bash
fetch_ws_1063_events com.btcontract.wallet
```

## Hash-Specific Query

If you already know the APK hash and want to narrow further:

# Comment: run this in any shell
# Comment: multi-line command

```bash
nak req \
  -k 1063 \
  -t "i=com.btcontract.wallet" \
  -t "x=f2faf0b12..." \
  -l 100 \
  wss://relay.nostr.band \
  wss://relay.primal.net \
  wss://relay.damus.io \
  wss://nostr.mom \
| jq -r '
    select(
      any(.tags[]?; .[0] == "client" and .[1] == "WalletScrutiny.com")
      or (.content | tostring | test("WalletScrutiny Android"))
    )
    | { created_at, pubkey, id, content }
  '
```
