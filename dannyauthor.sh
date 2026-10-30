#!/bin/bash

# dannyauthor.sh v0.3.0
#
# Purpose
# -------
# Count WalletScrutiny markdown pages whose front matter lists Danny as author.
# This was created to estimate Danny Garcia's authored/reviewed WalletScrutiny
# app pages before later repository cleanups changed the count.
#
# Why the checkout date matters
# -----------------------------
# WalletScrutiny changed over time. In older snapshots, mobile app pages lived in
# _android/ and _iphone/. In newer snapshots, those collections were unified into
# _mobile/. Later cleanups also removed app pages and/or removed author metadata.
# Because of that, this script can produce drastically different totals depending
# on which WalletScrutiny commit you run it against.
#
# Reference snapshot used for the historical report:
#   walletScrutinyCom commit: d6a8e37a19f83ddcc5da56ca84ed834e24b4c976
#   commit date: 2026-01-06T09:52:33+08:00
#   subject: new app/splitRewards
#
# How to run
# ----------
# 1. Use an existing WalletScrutiny checkout, or create a historical worktree:
#      git -C ~/work/walletScrutinyCom worktree add --detach /tmp/ws-jan2026 d6a8e37a19f83ddcc5da56ca84ed834e24b4c976
# 2. Run this script with the WalletScrutiny repo path:
#      ~/work/scripts/dannyauthor.sh /tmp/ws-jan2026
# 3. Optional: save the full report, including non-Danny-author files:
#      ~/work/scripts/dannyauthor.sh /tmp/ws-jan2026 > ~/work/ws-notes/stats/danny-authored-walletscrutiny-pages-jan-2026.txt
#
# Match rule
# ----------
# Counts a file as Danny-authored when any line exactly matches either:
#   author: danny
#   - danny
# with leading/trailing whitespace allowed.

set -euo pipefail

SCRIPT_VERSION="v0.3.0"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [WALLET_SCRUTINY_REPO]

Counts WalletScrutiny markdown files where Danny is listed as author.
If WALLET_SCRUTINY_REPO is omitted, defaults to:
  $HOME/work/walletScrutinyCom

Important: totals depend on the checked-out WalletScrutiny commit.
For the January 2026 historical count, run against commit:
  d6a8e37a19f83ddcc5da56ca84ed834e24b4c976
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

WS_ROOT="${1:-$HOME/work/walletScrutinyCom}"
AUTHOR_PATTERN='^[[:space:]]*(author:[[:space:]]*danny|-[[:space:]]*danny)[[:space:]]*$'

if [ ! -d "$WS_ROOT" ]; then
    echo "Error: WalletScrutiny directory not found: $WS_ROOT"
    exit 1
fi

repo_commit="unknown"
repo_commit_date="unknown"
repo_commit_subject="unknown"
if git -C "$WS_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repo_commit=$(git -C "$WS_ROOT" rev-parse HEAD)
    repo_commit_date=$(git -C "$WS_ROOT" show -s --date=iso-strict --format=%cd HEAD)
    repo_commit_subject=$(git -C "$WS_ROOT" show -s --format=%s HEAD)
fi

COLLECTIONS=()
if [ -d "$WS_ROOT/_mobile" ]; then
    COLLECTIONS+=("_mobile")
else
    COLLECTIONS+=("_android" "_iphone")
fi
COLLECTIONS+=("_bearer" "_others" "_hardware" "_desktop")

printf 'Danny-authored WalletScrutiny pages\n'
printf 'Script: %s\n' "$SCRIPT_PATH"
printf 'Script version: %s\n' "$SCRIPT_VERSION"
printf 'Repo: %s\n' "$WS_ROOT"
printf 'Repo commit: %s\n' "$repo_commit"
printf 'Repo commit date: %s\n' "$repo_commit_date"
printf 'Repo commit subject: %s\n\n' "$repo_commit_subject"
printf '%-12s %10s %10s %10s\n' "Collection" "Authored" "Total" "Instances"
printf '%-12s %10s %10s %10s\n' "----------" "--------" "-----" "---------"

total_files=0
total_collection_files=0
total_instances=0
non_author_files=$(mktemp)
trap 'rm -f "$non_author_files"' EXIT

for collection in "${COLLECTIONS[@]}"; do
    dir="$WS_ROOT/$collection"

    if [ ! -d "$dir" ]; then
        printf '%-12s %10s %10s %10s\n' "$collection" "missing" "missing" "missing"
        continue
    fi

    file_count=0
    collection_file_count=0
    instance_count=0

    while IFS= read -r -d '' file; do
        collection_file_count=$((collection_file_count + 1))
        matches=$(grep -E -c "$AUTHOR_PATTERN" "$file" || true)

        if [ "$matches" -gt 0 ]; then
            file_count=$((file_count + 1))
            instance_count=$((instance_count + matches))
        else
            printf '%s\n' "${file#$WS_ROOT/}" >> "$non_author_files"
        fi
    done < <(find "$dir" -maxdepth 1 -type f -name '*.md' -print0)

    total_files=$((total_files + file_count))
    total_collection_files=$((total_collection_files + collection_file_count))
    total_instances=$((total_instances + instance_count))

    printf '%-12s %10d %10d %10d\n' "$collection" "$file_count" "$collection_file_count" "$instance_count"
done

printf '%-12s %10s %10s %10s\n' "----------" "--------" "-----" "---------"
printf '%-12s %10d %10d %10d\n' "TOTAL" "$total_files" "$total_collection_files" "$total_instances"
printf '\nDanny-authored pages: %d of %d total markdown files\n' "$total_files" "$total_collection_files"

printf '\nFiles where Danny is not listed as author:\n'
if [ -s "$non_author_files" ]; then
    sort "$non_author_files"
else
    printf 'None\n'
fi
