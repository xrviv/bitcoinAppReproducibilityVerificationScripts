#!/bin/bash
# Check if GitHub Personal Access Token has been set
#
# updateVerifications.sh v0.0.1
# An internal script by
# Author: Daniel Andrei "Dannybuntu" R. Garcia
# ============================================
# Checks out to ws, updates ws, backs up verifications, then checks what needs to be verified.
# Outputs file to home

set -e # exit immediately if a command fails

if [ -z "${GAP}" ]; then
  echo "GAP is not set. Please export it first, eg:"
  echo 'export GAP="your_github_personal_access_token"'
  exit 1
fi

cd ~/work/walletScrutinyCom || exit
git checkout master
git fetch origin master
git pull
git checkout includeNostrBackuptoSearchVerifications
node scripts/nostr/backupNostrVerificationEvents.mjs -d 365
./refresh.sh -g "$GAP"
node scripts/nostr/wsVerify.mjs --needs-verification | tee ~/needs-verification-$(date +%Y-%m-%d).txt
git restore .
git clean -f
git checkout master
git reset --hard HEAD
