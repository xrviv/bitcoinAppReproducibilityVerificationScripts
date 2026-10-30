#!/bin/bash

# dannycommits.sh v0.1.1
#
# Count Danny-authored commits in the WalletScrutiny repository history.
#
# Default scope is the official GitLab project remote:
#   refs/remotes/origin/*
#
# In this checkout, origin points to:
#   git@gitlab.com:walletscrutiny/walletScrutinyCom.git
#
# The count is over unique commits reachable from the chosen ref scope. It is an
# author count, not a committer count, so merge commits authored by other people
# do not count as Danny commits even if they merged Danny-authored work.
#
# How to run:
#   ~/work/scripts/dannycommits.sh
#
# Optional environment variables:
#   WS_ROOT=/path/to/walletScrutinyCom
#   REF_SCOPE=refs/remotes/origin
#   DANNY_AUTHOR_REGEX='custom extended grep regex'

set -euo pipefail

SCRIPT_VERSION="v0.1.1"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
WS_ROOT="${WS_ROOT:-$HOME/work/walletScrutinyCom}"
REF_SCOPE="${REF_SCOPE:-refs/remotes/origin}"
DANNY_AUTHOR_REGEX="${DANNY_AUTHOR_REGEX:-dannybuntu@proton\.me|dannyboygarcia@gmail\.com|44260360\+xrviv@users\.noreply\.github\.com|dannybuntu@Ubuntu22\.myguest\.virtualbox\.org|dannybuntu@Debian\.myguest\.virtualbox\.org}"

usage() {
    cat <<USAGE
Usage: $(basename "$0")

Counts Danny-authored unique commits in WalletScrutiny history.

Defaults:
  WalletScrutiny repo: $WS_ROOT
  Ref scope:           $REF_SCOPE

Examples:
  ~/work/scripts/dannycommits.sh
  REF_SCOPE=refs/remotes/danny ~/work/scripts/dannycommits.sh
  REF_SCOPE=--all ~/work/scripts/dannycommits.sh
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if ! git -C "$WS_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: WalletScrutiny repo not found: $WS_ROOT" >&2
    exit 1
fi

git_args=()
if [ "$REF_SCOPE" = "--all" ]; then
    git_args+=(--all)
else
    mapfile -t refs < <(git -C "$WS_ROOT" for-each-ref --format='%(refname)' "$REF_SCOPE")
    if [ "${#refs[@]}" -eq 0 ]; then
        echo "Error: no refs found for REF_SCOPE=$REF_SCOPE" >&2
        exit 1
    fi
    git_args+=("${refs[@]}")
fi

total_commits=$(git -C "$WS_ROOT" rev-list --count "${git_args[@]}")
danny_commits=$(git -C "$WS_ROOT" log "${git_args[@]}" --format='%H%x09%an <%ae>%x09%aI%x09%s' | grep -E "$DANNY_AUTHOR_REGEX" || true)
danny_count=$(printf '%s\n' "$danny_commits" | sed '/^$/d' | wc -l)
percent=$(awk -v d="$danny_count" -v t="$total_commits" 'BEGIN { if (t == 0) print "0.00"; else printf "%.2f", (d / t) * 100 }')

printf 'Danny-authored WalletScrutiny commits\n'
printf 'Script: %s\n' "$SCRIPT_PATH"
printf 'Script version: %s\n' "$SCRIPT_VERSION"
printf 'Repo: %s\n' "$WS_ROOT"
printf 'Ref scope: %s\n' "$REF_SCOPE"
printf 'Author regex: %s\n\n' "$DANNY_AUTHOR_REGEX"

printf 'Total unique commits in scope: %d\n' "$total_commits"
printf 'Danny-authored commits: %d\n' "$danny_count"
printf 'Danny-authored share: %s%%\n\n' "$percent"

printf 'Danny commits by author identity:\n'
if [ "$danny_count" -gt 0 ]; then
    printf '%s\n' "$danny_commits" | cut -f2 | sort | uniq -c | sort -nr
else
    printf 'None\n'
fi

printf '\nDanny commits by author year:\n'
if [ "$danny_count" -gt 0 ]; then
    printf '%s\n' "$danny_commits" | cut -f3 | cut -c1-4 | sort | uniq -c
else
    printf 'None\n'
fi

if [ "$danny_count" -gt 0 ]; then
    sorted_danny=$(printf '%s\n' "$danny_commits" | sort -t "$(printf '\t')" -k3,3)

    printf '\nEarliest Danny-authored commit in scope:\n'
    printf '%s\n' "$sorted_danny" | awk -F '\t' 'NR == 1 { printf "%s %s %s\n", $3, $1, $4 }'

    printf '\nLatest Danny-authored commit in scope:\n'
    printf '%s\n' "$sorted_danny" | awk -F '\t' 'END { printf "%s %s %s\n", $3, $1, $4 }'
else
    printf '\nEarliest Danny-authored commit in scope:\nNone\n'
    printf '\nLatest Danny-authored commit in scope:\nNone\n'
fi
