#!/bin/bash

# dannyauthor-monthly.sh v0.2.0
#
# Purpose
# -------
# Run dannyauthor.sh once per month at a representative WalletScrutiny commit,
# then preserve the monthly totals in Markdown, TSV, and raw per-month reports.
#
# The sampled commits are deterministic, not freshly random on every run. For
# each month, this script hashes a fixed seed with the month and uses that value
# to select one commit from the month's first-parent master history. That keeps
# the sample auditable and repeatable.
#
# January 2026 is intentionally pinned to the previously reviewed snapshot:
#   d6a8e37a19f83ddcc5da56ca84ed834e24b4c976
#
# How to run
# ----------
# Current year-to-date default:
#   ~/work/scripts/dannyauthor-monthly.sh
#
# Specific range:
#   START_MONTH=2025-01 END_MONTH=2025-12 ~/work/scripts/dannyauthor-monthly.sh
#
# Optional environment variables:
#   WS_ROOT=/path/to/walletScrutinyCom
#   STATS_DIR=/path/to/output/stats
#   WORKTREE_DIR=/tmp/ws-author-monthly
#   START_MONTH=2026-01
#   END_MONTH=2026-07

set -euo pipefail

SCRIPT_VERSION="v0.2.0"
SEED="dannyauthor-monthly-v1"
AUTHOR_SCRIPT="${AUTHOR_SCRIPT:-$HOME/work/scripts/dannyauthor.sh}"
WS_ROOT="${WS_ROOT:-$HOME/work/walletScrutinyCom}"
STATS_DIR="${STATS_DIR:-$HOME/work/ws-notes/stats}"
WORKTREE_DIR="${WORKTREE_DIR:-/tmp/ws-author-monthly}"
START_MONTH="${START_MONTH:-2026-01}"
END_MONTH="${END_MONTH:-$(date +%Y-%m)}"
MASTER_REF="${MASTER_REF:-master}"
JAN_2026_COMMIT="d6a8e37a19f83ddcc5da56ca84ed834e24b4c976"

start_year="${START_MONTH%%-*}"
end_year="${END_MONTH%%-*}"
if [ "$start_year" = "$end_year" ]; then
    REPORT_ID="$start_year"
    REPORT_LABEL="$start_year"
else
    REPORT_ID="$START_MONTH-to-$END_MONTH"
    REPORT_LABEL="$START_MONTH to $END_MONTH"
fi

MAIN_REPORT="$STATS_DIR/$REPORT_ID-monthly-danny-authored-walletscrutiny-pages.md"
TSV_REPORT="$STATS_DIR/$REPORT_ID-monthly-danny-authored-walletscrutiny-pages.tsv"
RAW_DIR="$STATS_DIR/monthly-raw"

usage() {
    cat <<USAGE
Usage: $(basename "$0")

Generates monthly Danny-authored WalletScrutiny page counts.

Defaults:
  WalletScrutiny repo: $WS_ROOT
  Per-snapshot script: $AUTHOR_SCRIPT
  Output directory:    $STATS_DIR
  Reused worktree:     $WORKTREE_DIR
  Month range:         $START_MONTH through $END_MONTH
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ ! -x "$AUTHOR_SCRIPT" ]; then
    echo "Error: author counter is not executable: $AUTHOR_SCRIPT" >&2
    exit 1
fi

if ! git -C "$WS_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: WalletScrutiny repo not found: $WS_ROOT" >&2
    exit 1
fi

if ! git -C "$WS_ROOT" rev-parse --verify "$MASTER_REF" >/dev/null 2>&1; then
    echo "Error: master ref not found in WalletScrutiny repo: $MASTER_REF" >&2
    exit 1
fi

mkdir -p "$RAW_DIR"

if git -C "$WORKTREE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    :
else
    if [ -e "$WORKTREE_DIR" ]; then
        echo "Error: worktree path exists but is not a git worktree: $WORKTREE_DIR" >&2
        exit 1
    fi
    git -C "$WS_ROOT" worktree add --detach "$WORKTREE_DIR" "$MASTER_REF" >/dev/null
fi

month_to_epoch() {
    date -d "$1-01" +%s
}

next_month() {
    date -d "$1-01 +1 month" +%Y-%m
}

month_start_iso() {
    printf '%s-01 00:00:00\n' "$1"
}

month_end_iso() {
    date -d "$1-01 +1 month" +'%Y-%m-%d 00:00:00'
}

month_label() {
    date -d "$1-01" +%b-%Y
}

select_commit_for_month() {
    local month="$1"
    local start
    local end
    local selected_index
    local hash_input
    local hash_prefix
    local count
    local commits=()

    if [ "$month" = "2026-01" ]; then
        printf '%s\n' "$JAN_2026_COMMIT"
        return
    fi

    start=$(month_start_iso "$month")
    end=$(month_end_iso "$month")
    mapfile -t commits < <(git -C "$WS_ROOT" log "$MASTER_REF" --first-parent --since="$start" --until="$end" --format='%H' --reverse)
    count=${#commits[@]}
    if [ "$count" -eq 0 ]; then
        printf 'none\n'
        return
    fi

    hash_input="$SEED:$month:$count"
    hash_prefix=$(printf '%s' "$hash_input" | sha256sum | cut -c1-12)
    selected_index=$((16#$hash_prefix % count))
    printf '%s\n' "${commits[$selected_index]}"
}

parse_total_row() {
    awk '$1 == "TOTAL" { print $2 "\t" $3 "\t" $4 }' "$1"
}

percentage() {
    local authored="$1"
    local total="$2"
    awk -v a="$authored" -v t="$total" 'BEGIN { if (t == 0) print "0.00"; else printf "%.2f", (a / t) * 100 }'
}

printf 'Month\tCommit\tCommit Date\tCommit Subject\tAuthored\tTotal\tPercent\tInstances\tRaw Report\n' > "$TSV_REPORT"

{
    printf '# Monthly Danny-Authored WalletScrutiny Pages in %s\n\n' "$REPORT_LABEL"
    printf 'This report runs `%s` once per month against a representative WalletScrutiny commit.\n\n' "$AUTHOR_SCRIPT"
    printf 'Sampling is deterministic: each month uses one pseudo-random first-parent `%s` commit selected with seed `%s`.\n' "$MASTER_REF" "$SEED"
    printf 'January 2026 is pinned to the previously reviewed snapshot `%s` when included in the range.\n\n' "$JAN_2026_COMMIT"
    printf 'Generated by `%s` version `%s` for `%s` through `%s`.\n\n' "$0" "$SCRIPT_VERSION" "$START_MONTH" "$END_MONTH"
    printf '| Month | Commit | Commit Date | Authored | Total | Percent | Instances | Raw Report |\n'
    printf '|---|---|---:|---:|---:|---:|---:|---|\n'
} > "$MAIN_REPORT"

current="$START_MONTH"
while [ "$(month_to_epoch "$current")" -le "$(month_to_epoch "$END_MONTH")" ]; do
    commit=$(select_commit_for_month "$current")
    label=$(month_label "$current")

    if [ "$commit" = "none" ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "none" "" "No first-parent commits" "" "" "" "" "" >> "$TSV_REPORT"
        printf '| %s | none |  |  |  |  |  |  |\n' "$label" >> "$MAIN_REPORT"
        current=$(next_month "$current")
        continue
    fi

    git -C "$WORKTREE_DIR" checkout --detach "$commit" >/dev/null 2>&1

    raw_file="$RAW_DIR/$current-dannyauthor.txt"
    "$AUTHOR_SCRIPT" "$WORKTREE_DIR" > "$raw_file"

    total_values=$(parse_total_row "$raw_file")
    authored=$(printf '%s\n' "$total_values" | cut -f1)
    total=$(printf '%s\n' "$total_values" | cut -f2)
    instances=$(printf '%s\n' "$total_values" | cut -f3)
    percent=$(percentage "$authored" "$total")
    commit_date=$(git -C "$WORKTREE_DIR" show -s --date=iso-strict --format=%cd HEAD)
    commit_subject=$(git -C "$WORKTREE_DIR" show -s --format=%s HEAD)
    short_commit=$(printf '%s' "$commit" | cut -c1-10)
    raw_rel="monthly-raw/$current-dannyauthor.txt"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s%%\t%s\t%s\n' "$label" "$commit" "$commit_date" "$commit_subject" "$authored" "$total" "$percent" "$instances" "$raw_rel" >> "$TSV_REPORT"
    printf '| %s | `%s` | %s | %s | %s | %s%% | %s | [%s](%s) |\n' "$label" "$short_commit" "$commit_date" "$authored" "$total" "$percent" "$instances" "$raw_rel" "$raw_rel" >> "$MAIN_REPORT"

    current=$(next_month "$current")
done

printf 'Wrote %s\n' "$MAIN_REPORT"
printf 'Wrote %s\n' "$TSV_REPORT"
printf 'Wrote raw reports to %s\n' "$RAW_DIR"
