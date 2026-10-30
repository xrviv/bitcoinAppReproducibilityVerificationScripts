#!/bin/bash

# Script to find Android wallets tagged as fewusers
# Looks for files with "meta: fewusers" in the front matter
# Results are sorted by number of users in descending order

ANDROID_DIR=~/work/walletScrutinyCom/_mobile

# Check if the directory exists
if [ ! -d "$ANDROID_DIR" ]; then
    echo "Error: Directory $ANDROID_DIR not found!"
    exit 1
fi

echo "Finding Android wallets tagged as fewusers..."
echo ""
echo "fewusers sorted in descending order:"
echo ""

# Create a temporary file to store results
temp_file=$(mktemp)

# Loop through all md files in the _android directory
for file in "$ANDROID_DIR"/*.md; do
    # Get just the filename without the path
    filename=$(basename "$file")

    # Check if the file contains "meta: fewusers" AND "verdict: wip"
    if grep -q "meta: fewusers" "$file" && grep -q "verdict: wip" "$file"; then
        # Extract the users value from front matter
        users=$(grep -m 1 "users:" "$file" | sed 's/users: //' | tr -d "[:space:]")

        # If users value is not found, set it to 0
        if [ -z "$users" ]; then
            users=0
        fi

        # Store filename and users count in the temp file
        echo "$users:$filename" >> "$temp_file"
    fi
done

# Sort the results by users count in descending order and format the output
sort -t: -k1,1 -nr "$temp_file" | while IFS=: read -r users filename; do
    echo "$filename - users: $users"
done

# Count the total number of matching files
count=$(wc -l < "$temp_file")

# Remove the temporary file
rm "$temp_file"

echo ""
echo "Total number of fewusers: $count"
