#!/bin/bash

# Script to find wip wallets that are active
# Looks for a platform block with "meta: ok" and "verdict: wip" in the front matter
# Results are sorted by number of users in descending order
#
# Last modified by: Danny Garcia
# Last modified on: 2026-07-21

MOBILE_DIR=~/work/walletScrutinyCom/_mobile

# Check if the directory exists
if [ ! -d "$MOBILE_DIR" ]; then
    echo "Error: Directory $MOBILE_DIR not found!"
    exit 1
fi

echo "Finding active wip wallets..."
echo ""
echo "WIP sorted in descending order:"
echo ""

# Create a temporary file to store results
temp_file=$(mktemp)

# Each _mobile file carries an android: and an iphone: block, so meta/verdict/users
# are read per block rather than per file
awk '
function flush(   p, u) {
    if (fname == "") return
    for (p in verdict) {
        if (verdict[p] == "wip" && meta[p] == "ok") {
            u = (p in users) ? users[p] : 0
            printf "%s\t%s\t%s\n", u, fname, p
        }
    }
}
FNR == 1 {
    flush()
    delete verdict; delete meta; delete users
    fname = FILENAME
    sub(/.*\//, "", fname)
    plat = ""; infm = 1; dashes = 0
}
infm == 0 { next }
/^---[[:space:]]*$/ { if (++dashes >= 2) infm = 0; next }
/^(android|iphone):[[:space:]]*$/ { plat = $1; sub(/:.*/, "", plat); next }
/^[^[:space:]]/ { plat = ""; next }
plat != "" && $1 == "verdict:" { verdict[plat] = $2; next }
plat != "" && $1 == "meta:"    { meta[plat] = $2; next }
plat != "" && $1 == "users:"   { users[plat] = $2; next }
END { flush() }
' "$MOBILE_DIR"/*.md > "$temp_file"

# Sort the results by users count in descending order and format the output
sort -t$'\t' -k1,1nr "$temp_file" | while IFS=$'\t' read -r users filename platform; do
    echo "$filename [$platform] - users: $users"
done

# Count the total number of wip entries
count=$(wc -l < "$temp_file")

# Remove the temporary file
rm "$temp_file"

echo ""
echo "Total number of active wip: $count"
