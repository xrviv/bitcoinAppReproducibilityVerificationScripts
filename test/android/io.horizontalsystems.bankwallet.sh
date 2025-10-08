#!/bin/bash

# Unstoppable Wallet Build Script v0.45.0
# Containerized reproducible build script for Unstoppable Wallet (io.horizontalsystems.bankwallet)
# This script is designed to work with test.sh for automated APK verification

# Script version follows format: vX.Y.Z where X.Y matches app version, Z is script revision
SCRIPT_VERSION="v0.45.0"

usage() {
  echo 'NAME
       io.horizontalsystems.bankwallet.sh - Build Unstoppable Wallet from source

SYNOPSIS
       Source this script from test.sh (not meant to be run standalone)

DESCRIPTION
       This script builds Unstoppable Wallet using a containerized environment
       to ensure reproducible builds. It is called by test.sh which handles
       repository cloning, APK comparison, and verification.

       The script defines:
         - repo: Git repository URL
         - tag: Git tag/version to build (set from $versionName by test.sh)
         - test(): Function that performs the containerized build
         - builtApk: Path to the generated APK

ENVIRONMENT
       Requires podman and 12GB RAM for build container.

SEE ALSO
       test.sh - Main testing framework that sources this script'
}

# Handle -h flag if script is run directly (though it should be sourced by test.sh)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ "$1" == "-h" ]]; then
  usage
  exit 0
fi

# Required by test.sh
repo="https://github.com/horizontalsystems/unstoppable-wallet-android.git"
tag=$versionName

# Test function called by test.sh
test() {
  # Get the directory where this script is located
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Cleanup any existing container
  podman rm -f unstoppable-container 2>/dev/null || true

  # Copy Dockerfile and build
  cp "$SCRIPT_DIR/io.horizontalsystems.bankwallet.dockerfile" . && \
  podman build -t unstoppable-build -f io.horizontalsystems.bankwallet.dockerfile . && \
  podman run -it \
    --volume $PWD:/mnt \
    --workdir /mnt \
    --memory=12g \
    --name unstoppable-container \
    unstoppable-build \
    bash -x -c './gradlew clean && ./gradlew :app:assembleBaseRelease --no-daemon --max-workers=2 --info'

  # Cleanup container
  podman rm -f unstoppable-container 2>/dev/null || true
}

# Path to the built APK (relative to $workDir/app)
builtApk="app/build/outputs/apk/base/release/app-base-release.apk"
