#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  fetch-ws-1063-events.sh [--app-id APP_ID] [--version VERSION] [--hash SHA256] [--limit N] [--compact] [--raw] [--no-tui]

Examples:
  fetch-ws-1063-events.sh --app-id com.btcontract.wallet --version 2.5.8
  fetch-ws-1063-events.sh --app-id com.btcontract.wallet --limit 200
  fetch-ws-1063-events.sh --app-id com.btcontract.wallet --version 2.5.8 --compact
  fetch-ws-1063-events.sh

What it does:
  - Fetches Nostr kind 1063 asset-registration events
  - Filters for WalletScrutiny-related events
  - Prints the uploader pubkey, event id, timestamps, app id, version, hashes, and content
  - If --app-id is omitted, uses all appIds from WalletScrutiny Android's generated supported-wallet list
  - In an interactive terminal, opens a TUI by default unless --compact, --raw, or --no-tui is used
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

app_id=""
version=""
hash=""
limit="100"
compact="0"
raw="0"
no_tui="0"
sort_mode="newest"
search_app_id=""
default_wallets_file="/home/dannybuntu/work/walletscrutinyandroid/app/src/main/java/com/walletscrutiny/app/WalletsHelper.kt"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp_dir="$(mktemp -d)"
events_file="${tmp_dir}/events.jsonl"
sorted_file="${tmp_dir}/events.sorted.jsonl"
view_file="${tmp_dir}/events.view.jsonl"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id)
      app_id="${2:-}"
      shift 2
      ;;
    --version)
      version="${2:-}"
      shift 2
      ;;
    --hash)
      hash="${2:-}"
      shift 2
      ;;
    --limit)
      limit="${2:-}"
      shift 2
      ;;
    --compact)
      compact="1"
      shift
      ;;
    --raw)
      raw="1"
      shift
      ;;
    --no-tui)
      no_tui="1"
      shift
      ;;
    --wallets-file)
      default_wallets_file="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd nak
require_cmd jq
require_cmd rg

relays=(
  "wss://relay.nostr.band"
  "wss://relay.primal.net"
  "wss://relay.damus.io"
  "wss://nostr.mom"
)

use_tui="0"
if [[ "$compact" == "0" && "$raw" == "0" && "$no_tui" == "0" && -t 0 && -t 1 ]] && command -v whiptail >/dev/null 2>&1; then
  use_tui="1"
fi

load_default_app_ids() {
  local resolved_wallets_file="$default_wallets_file"

  if [[ ! -f "$resolved_wallets_file" ]]; then
    local fallback_wallets_file="${script_dir}/../../walletscrutinyandroid/app/src/main/java/com/walletscrutiny/app/WalletsHelper.kt"
    if [[ -f "$fallback_wallets_file" ]]; then
      resolved_wallets_file="$fallback_wallets_file"
    fi
  fi

  if [[ ! -f "$resolved_wallets_file" ]]; then
    echo "Error: default wallets file not found: $default_wallets_file" >&2
    exit 1
  fi

  mapfile -t default_app_ids < <(
    rg '^[[:space:]]*Wallet\("' "$resolved_wallets_file" \
      | sed -E 's/^[[:space:]]*Wallet\("([^"]+)".*/\1/' \
      | sort -u
  )

  if [[ "${#default_app_ids[@]}" -eq 0 ]]; then
    echo "Error: no appIds found in $resolved_wallets_file" >&2
    exit 1
  fi
}

get_app_ids() {
  if [[ -n "$app_id" ]]; then
    printf '%s\n' "$app_id"
  else
    load_default_app_ids
    printf '%s\n' "${default_app_ids[@]}"
  fi
}

fetch_events_for_app_id() {
  local current_app_id="$1"
  local nak_args=(
    req
    -k 1063
    -t "i=${current_app_id}"
    -l "${limit}"
  )

  if [[ -n "$version" ]]; then
    nak_args+=(-t "version=${version}")
  fi

  if [[ -n "$hash" ]]; then
    nak_args+=(-t "x=${hash}")
  fi

  nak "${nak_args[@]}" "${relays[@]}" </dev/null | jq -c '
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

load_events() {
  : >"$events_file"

  if [[ "$use_tui" == "1" ]]; then
    whiptail --title "WalletScrutiny 1063 Browser" --infobox "Fetching Nostr kind 1063 events..." 8 60
  fi

  while IFS= read -r current_app_id; do
    fetch_events_for_app_id "$current_app_id" >>"$events_file" || true
  done < <(get_app_ids)

  if [[ ! -s "$events_file" ]]; then
    return 1
  fi

  sort_events "$sort_mode"
}

apply_current_filter() {
  if [[ -z "$search_app_id" ]]; then
    cp "$sorted_file" "$view_file"
    return 0
  fi

  jq -c --arg search_app_id "$search_app_id" '
    select(((.appId // "") | ascii_downcase) | contains($search_app_id | ascii_downcase))
  ' "$sorted_file" >"$view_file"
}

sort_events() {
  local mode="${1:-newest}"
  sort_mode="$mode"

  case "$mode" in
    newest)
      jq -s -c '
        sort_by(.id, .created_at)
        | group_by(.id)
        | map(last)
        | sort_by(.created_at, .id)
        | reverse
        | .[]
      ' "$events_file" >"$sorted_file"
      ;;
    oldest)
      jq -s -c '
        sort_by(.id, .created_at)
        | group_by(.id)
        | map(last)
        | sort_by(.created_at, .id)
        | .[]
      ' "$events_file" >"$sorted_file"
      ;;
    appid)
      jq -s -c '
        sort_by(.id, .created_at)
        | group_by(.id)
        | map(last)
        | sort_by(.appId // "", .version // "", -(.created_at // 0), .id)
        | .[]
      ' "$events_file" >"$sorted_file"
      ;;
    version)
      jq -s -c '
        sort_by(.id, .created_at)
        | group_by(.id)
        | map(last)
        | sort_by(.version // "", .appId // "", -(.created_at // 0), .id)
        | .[]
      ' "$events_file" >"$sorted_file"
      ;;
    *)
      echo "Error: unknown sort mode: $mode" >&2
      exit 1
      ;;
  esac

  apply_current_filter
}

print_compact() {
  jq -r '
    [
      .created_at,
      .seen_utc,
      .pubkey,
      .id,
      .appId,
      .version,
      (.hashes | join(",")),
      .content
    ] | @tsv
  ' "$view_file"
}

print_raw() {
  jq '.' "$view_file"
}

build_details_file() {
  local event_json="$1"
  local details_file="$2"

  jq -r '
    [
      "WalletScrutiny Kind 1063 Event",
      "",
      "Seen: " + (.seen_utc // ""),
      "Created At: " + ((.created_at // 0) | tostring),
      "App ID: " + (.appId // ""),
      "Version: " + (.version // ""),
      "Uploader Pubkey: " + (.pubkey // ""),
      "Event ID: " + (.id // ""),
      "Client: " + (.client // ""),
      "Hashes:",
      ((.hashes // []) | map("  - " + .) | join("\n")),
      "",
      "Content:",
      (.content // "")
    ] | join("\n")
  ' <<<"$event_json" >"$details_file"
}

show_event_details() {
  local event_json="$1"
  local details_file="${tmp_dir}/event-details.txt"
  build_details_file "$event_json" "$details_file"
  whiptail --title "Event Details" --textbox "$details_file" 24 100
}

event_menu() {
  local selected_id=""

  while true; do
    local menu_items=()
    local count=0

    while IFS= read -r event_json; do
      count=$((count + 1))
      local tag
      local desc
      tag="$(jq -r '.id' <<<"$event_json")"
      desc="$(jq -r '[.seen_utc, (.appId // "?"), (.version // "?"), ((.pubkey // "")[0:12] + "..."), ((.content // "") | gsub("[\r\n\t]"; " ") | .[0:40])] | join(" | ")' <<<"$event_json")"
      menu_items+=("$tag" "$desc")
    done <"$view_file"

    if [[ "$count" -eq 0 ]]; then
      whiptail --title "WalletScrutiny 1063 Browser" --msgbox "No matching events found." 8 50
      return 0
    fi

    if ! selected_id=$(
      whiptail \
        --title "WalletScrutiny 1063 Browser" \
        --menu "Sort: ${sort_mode} | Events: ${count}\nUse arrow keys, Enter for details, Cancel for main menu." \
        25 120 16 \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3
    ); then
      return 0
    fi

    local chosen_event
    chosen_event="$(jq -c --arg id "$selected_id" 'select(.id == $id)' "$view_file" | head -n 1)"
    if [[ -n "$chosen_event" ]]; then
      show_event_details "$chosen_event"
    fi
  done
}

sort_menu() {
  local choice=""
  choice=$(
    whiptail \
      --title "Sort Options" \
      --menu "Choose event ordering." \
      18 70 8 \
      "newest" "Newest first" \
      "oldest" "Oldest first" \
      "appid" "Group by app id" \
      "version" "Group by version" \
      3>&1 1>&2 2>&3
  ) || return 0

  sort_events "$choice"
}

search_menu() {
  local input=""

  input=$(
    whiptail \
      --title "Search By App ID" \
      --inputbox "Enter full or partial app ID.\nCurrent: ${search_app_id:-<none>}" \
      12 80 \
      "$search_app_id" \
      3>&1 1>&2 2>&3
  ) || return 0

  search_app_id="$input"
  apply_current_filter

  if [[ ! -s "$view_file" ]]; then
    whiptail --title "Search By App ID" --msgbox "No matching events found for: ${search_app_id}" 8 60
  fi
}

clear_search() {
  search_app_id=""
  apply_current_filter
}

main_menu() {
  while true; do
    local choice=""
    choice=$(
      whiptail \
        --title "WalletScrutiny 1063 Browser" \
        --menu "Choose an action.\nSearch: ${search_app_id:-<none>}" \
        20 80 10 \
        "browse" "Browse events" \
        "sort" "Change sorting (current: ${sort_mode})" \
        "search" "Search by app id" \
        "clear-search" "Clear app id search" \
        "reload" "Reload from relays" \
        "quit" "Exit" \
        3>&1 1>&2 2>&3
    ) || return 0

    case "$choice" in
      browse)
        event_menu
        ;;
      sort)
        sort_menu
        ;;
      search)
        search_menu
        ;;
      clear-search)
        clear_search
        ;;
      reload)
        if ! load_events; then
          whiptail --title "WalletScrutiny 1063 Browser" --msgbox "No matching events found." 8 50
        fi
        ;;
      quit)
        return 0
        ;;
    esac
  done
}

if ! load_events; then
  if [[ "$use_tui" == "1" ]]; then
    whiptail --title "WalletScrutiny 1063 Browser" --msgbox "No matching events found." 8 50
    exit 0
  fi
  exit 0
fi

if [[ "$compact" == "1" ]]; then
  print_compact
elif [[ "$raw" == "1" || "$use_tui" == "0" ]]; then
  print_raw
else
  main_menu
fi
