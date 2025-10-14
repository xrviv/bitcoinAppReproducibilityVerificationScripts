#!/bin/bash
# verify_bitcoinknots.sh v1.1.0 - Bitcoin Knots standalone reproducible build verification
# Integrates wsTestDesktop.sh functionality for standalone operation

# Check if we are already in a recording session
if [ -z "$__ASC_REC" ]; then
  # This is the parent script. It decides whether to record.
  
  # Pre-parse arguments to check for recording conditions
  if [ $# -ge 2 ]; then
    version="$1"
    target="$2"
    
    # Conditions met, start the recording process.
    echo "Extracting app metadata for directory structure..."
    
    # Create WS reports directory structure
    platform="desktop"
    app="bitcoinknots"
    logs_dir="$HOME/work/0-reports/$platform/$app/$version/logs"
    mkdir -p "$logs_dir"
    echo "Created logs directory: $logs_dir"
    
    current_date=$(date +%F)
    current_time=$(date +%H%M)
    initial_cast_filename="$logs_dir/${current_date}.${current_time}-${app}_v${version}_${target}.cast"
    
    # Build the command to be recorded
    command_to_run="bash '$0'"
    for arg in "$@"; do
      command_to_run+=$(printf " %q" "$arg")
    done

    echo "Starting asciinema recording. Initial file: $initial_cast_filename"
    
    # Set flags for the child process and run recording
    export __ASC_REC=true
    asciinema rec "$initial_cast_filename" --command="$command_to_run"

    # --- Recording has finished, parent script resumes ---
    
    # Determine final filename
    final_base_filename="${current_date}.${current_time}-${app}_v${version}_${target}"
    final_cast_filename="$logs_dir/${final_base_filename}.cast"
    final_log_filename="$logs_dir/${final_base_filename}.log"

    # Rename the initial cast file to its final name
    mv "$initial_cast_filename" "$final_cast_filename"

    # Generate the human-readable log file from the cast
    asciinema cat "$final_cast_filename" > "$final_log_filename"

    echo -e "\n\033[1mRecording complete. Artifacts saved:\033[0m"
    echo -e "  - Replayable Cast: \033[1;32m$final_cast_filename\033[0m"
    echo -e "  - Plain Text Log:  \033[1;32m$final_log_filename\033[0m"
    
    exit 0 # End of parent script
  fi
  # If conditions are not met, the script continues execution normally without recording.
fi

# Color constants
CYAN='\033[1;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Global variables
APP_NAME="bitcoinknots"
REPO_URL="https://github.com/bitcoinknots/bitcoin.git"
BUILD_START_TIME=""
BUILD_END_TIME=""
OFFICIAL_HASH=""
BUILT_HASH=""
GPG_VALID=""
VERDICT=""

# Setup directory structure - CORRECTED to use /tmp/
setup_directories() {
    local version="$1"
    local target="$2"
    
    local workdir="/tmp/testdesktop_bitcoinknots_v$version"
    local logsdir="$HOME/work/0-reports/desktop/$APP_NAME/$version/logs"
    
    echo "Setting up directory structure..." >&2
    mkdir -p "$workdir"/{official,source,build}
    mkdir -p "$logsdir"
    
    echo -e "${GREEN}✅ Created directories:${NC}" >&2
    echo "  - Work: $workdir" >&2
    echo "  - Logs: $logsdir" >&2
    
    # Return ONLY workdir to stdout
    echo "$workdir"
}

# Log session information
log_session() {
    local version="$1"
    local target="$2"
    local workdir="$3"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${CYAN}📝 Session: $APP_NAME v$version ($target) - $timestamp${NC}"
    echo -e "${CYAN}📁 Working Directory: $workdir${NC}"
}

# Help function
show_help() {
    echo "Bitcoin Knots Standalone Reproducible Build Verification v1.1.0"
    echo ""
    echo "Usage:"
    echo "  $0 <version> <target>"
    echo "  $0 --help"
    echo ""
    echo "Available targets:"
    echo "  x86_64-linux-gnu     # Linux 64-bit (tar.gz) - Recommended"
    echo "  riscv64-linux-gnu    # Linux RISC-V 64-bit (tar.gz)"
    echo "  win64                # Windows 64-bit (zip)"  
    echo "  x86_64-apple-darwin  # macOS Intel (tar.gz)"
    echo "  arm64-apple-darwin   # macOS Apple Silicon (tar.gz)"
    echo ""
    echo "Examples:"
    echo "  $0 29.1.knots20250903 x86_64-linux-gnu"
    echo "  $0 29.1.knots20250903 riscv64-linux-gnu"
    echo "  $0 29.1.knots20250903 win64"
    echo ""
    echo "Features:"
    echo "  - Standalone operation (no external dependencies)"
    echo "  - Automatic asciinema recording"
    echo "  - WalletScrutiny.com directory structure"
    echo "  - Native Guix build (no Docker containers)"
    echo "  - GPG signature verification"
    echo "  - Comprehensive logging and reporting"
}

# Map target to official filename
get_filename() {
    local version="$1"
    local target="$2"
    
    case "$target" in
        x86_64-linux-gnu)
            echo "bitcoin-${version}-x86_64-linux-gnu.tar.gz"
            ;;
        riscv64-linux-gnu)
            echo "bitcoin-${version}-riscv64-linux-gnu.tar.gz"
            ;;
        win64)
            echo "bitcoin-${version}-win64-unsigned.zip"
            ;;
        x86_64-apple-darwin)
            echo "bitcoin-${version}-x86_64-apple-darwin.tar.gz"
            ;;
        arm64-apple-darwin)
            echo "bitcoin-${version}-arm64-apple-darwin.tar.gz"
            ;;
        *)
            echo "ERROR: Unknown target '$target'" >&2
            return 1
            ;;
    esac
}

# Download and verify official release
download_official() {
    local version="$1"
    local target="$2"
    local workdir="$3"
    
    local filename=$(get_filename "$version" "$target")
    local base_url="https://github.com/bitcoinknots/bitcoin/releases/download/v${version}/"
    
    echo "Downloading official Bitcoin Knots $version..."
    cd "$workdir/official"
    
    # Download main file
    echo "Downloading $filename..."
    if ! wget "$base_url$filename"; then
        echo "❌ Failed to download $filename"
        return 1
    fi
    
    # Download checksums and signature
    echo "Downloading SHA256SUMS..."
    if ! wget "${base_url}SHA256SUMS"; then
        echo "❌ Failed to download SHA256SUMS"
        return 1
    fi
    
    echo "Downloading SHA256SUMS.asc..."
    if ! wget "${base_url}SHA256SUMS.asc"; then
        echo "❌ Failed to download SHA256SUMS.asc"
        return 1
    fi
    
    echo "✅ Downloaded official files"
    return 0
}

# Verify GPG signatures
verify_signatures() {
    local version="$1"
    local target="$2"
    local workdir="$3"
    
    local filename=$(get_filename "$version" "$target")
    cd "$workdir/official"
    
    echo "Verifying official file hash..."
    
    # Verify the file exists in SHA256SUMS
    if ! grep -q "$filename" SHA256SUMS; then
        echo "❌ File $filename not found in SHA256SUMS"
        return 1
    fi
    
    # Extract hash for our specific file
    OFFICIAL_HASH=$(grep "$filename" SHA256SUMS | awk '{print $1}')
    
    # Verify file hash matches
    local computed_hash=$(sha256sum "$filename" | awk '{print $1}')
    if [ "$OFFICIAL_HASH" != "$computed_hash" ]; then
        echo "❌ Hash mismatch for downloaded file"
        echo "Expected: $OFFICIAL_HASH"
        echo "Got: $computed_hash"
        return 1
    fi
    
    echo "✅ File hash verified: $OFFICIAL_HASH"
    
    # Import Bitcoin Knots signing keys
    echo "Importing Bitcoin Knots signing keys..."
    
    # Luke Dashjr's key (Bitcoin Knots maintainer)
    gpg --keyserver keyserver.ubuntu.com --recv-keys 0x36EEE1C8E73A2AE1 || \
    gpg --keyserver keys.openpgp.org --recv-keys 0x36EEE1C8E73A2AE1 || \
    gpg --keyserver pgp.mit.edu --recv-keys 0x36EEE1C8E73A2AE1 || \
    echo "⚠️  Could not import signing keys"
    
    # Verify signature
    echo "Verifying GPG signature..."
    if gpg --verify SHA256SUMS.asc SHA256SUMS 2>/dev/null; then
        GPG_VALID="✅ VALID"
        echo "✅ GPG signature verified"
    else
        GPG_VALID="⚠️  Could not verify"
        echo "⚠️  Could not verify GPG signature (keys may not be available)"
    fi
    
    return 0
}

# Clone and build Bitcoin Knots
build_bitcoin_knots() {
    local version="$1"
    local target="$2"
    local workdir="$3"
    
    echo "Building Bitcoin Knots $version for $target..."
    BUILD_START_TIME=$(date +%s)
    
    # Clone repository if not already present
    if [ ! -d "$workdir/source/bitcoin" ]; then
        echo "Cloning Bitcoin Knots repository..."
        mkdir -p "$workdir/source"
        cd "$workdir/source"
        
        if ! git clone "$REPO_URL" bitcoin; then
            echo "❌ Failed to clone repository"
            return 1
        fi
    fi
    
    cd "$workdir/source/bitcoin"
    
    # Checkout the specific tag
    echo "Checking out tag v$version..."
    if ! git checkout "v$version"; then
        echo "❌ Failed to checkout tag v$version"
        return 1
    fi
    
    # Set Guix build parameters based on target
    local hosts=""
    case "$target" in
        x86_64-linux-gnu)
            hosts="x86_64-linux-gnu"
            ;;
        riscv64-linux-gnu)
            hosts="riscv64-linux-gnu"
            ;;
        win64)
            hosts="x86_64-w64-mingw32"
            ;;
        x86_64-apple-darwin)
            hosts="x86_64-apple-darwin"
            ;;
        arm64-apple-darwin)
            hosts="arm64-apple-darwin"
            ;;
    esac
    
    # Clean any previous builds
    echo "Cleaning previous build artifacts..."
    ./contrib/guix/guix-clean || true
    
    # Run Guix build with fallback strategy
    echo "Starting Guix build for $hosts..."
    echo "Build command: env ADDITIONAL_GUIX_COMMON_FLAGS='--fallback --max-jobs=2' HOSTS=\"$hosts\" ./contrib/guix/guix-build"
    echo "Using substitutes with fallback to source building - this may take 30-90 minutes..."
    
    if env ADDITIONAL_GUIX_COMMON_FLAGS='--fallback --max-jobs=2' HOSTS="$hosts" ./contrib/guix/guix-build; then
        BUILD_END_TIME=$(date +%s)
        echo ""
        echo "✅ Build completed successfully"
        
        # Show build output directory structure
        echo "Build output structure:"
        find "guix-build-$version/output/$hosts/" -type f -name "*.tar.gz" -o -name "*.zip" 2>/dev/null | head -10
        
        # Copy output to build directory
        mkdir -p "$workdir/build/output"
        cp -r "guix-build-$version/output/$hosts/"* "$workdir/build/output/"
        echo "✅ Build artifacts copied to: $workdir/build/output/"
        
        return 0
    else
        BUILD_END_TIME=$(date +%s)
        echo "❌ Build failed"
        echo "Check the output above for error details"
        return 1
    fi
}

# Compare built binary with official
compare_binaries() {
    local version="$1"
    local target="$2"
    local workdir="$3"
    
    local official_filename=$(get_filename "$version" "$target")
    local built_filename=$(get_filename "$version" "$target")  # Same filename for both
    local official_file="$workdir/official/$official_filename"
    local built_file="$workdir/build/output/$built_filename"
    
    echo "Comparing built binary with official..."
    
    if [ ! -f "$built_file" ]; then
        echo "❌ Built file not found: $built_file"
        VERDICT="❌ NOT REPRODUCIBLE"
        return 1
    fi
    
    BUILT_HASH=$(sha256sum "$built_file" | awk '{print $1}')
    
    if [ "$OFFICIAL_HASH" = "$BUILT_HASH" ]; then
        echo "✅ Binary hashes match - REPRODUCIBLE!"
        VERDICT="✅ REPRODUCIBLE"
        return 0
    else
        echo "❌ Binary hashes do not match"
        echo "Official: $OFFICIAL_HASH"
        echo "Built:    $BUILT_HASH"
        VERDICT="❌ NOT REPRODUCIBLE"
        return 1
    fi
}

# Generate summary
generate_summary() {
    local version="$1"
    local target="$2"
    local workdir="$3"
    
    local official_filename=$(get_filename "$version" "$target")
    local build_duration=""
    
    if [ -n "$BUILD_START_TIME" ] && [ -n "$BUILD_END_TIME" ]; then
        local duration=$((BUILD_END_TIME - BUILD_START_TIME))
        build_duration="${duration}s"
    else
        build_duration="Unknown"
    fi
    
    # Get file sizes
    local official_size="Unknown"
    local built_size="Unknown"
    
    if [ -f "$workdir/official/$official_filename" ]; then
        official_size=$(stat -c%s "$workdir/official/$official_filename")
    fi
    
    if [ -f "$workdir/build/output/$official_filename" ]; then
        built_size=$(stat -c%s "$workdir/build/output/$official_filename")
    fi
    
    echo -e "\n${CYAN}=========================================="
    echo -e "           VERIFICATION SUMMARY"
    echo -e "==========================================${NC}"
    echo -e "${CYAN}App ID:${NC}          $APP_NAME"
    echo -e "${CYAN}Version:${NC}         $version"
    echo -e "${CYAN}Target:${NC}          $target"
    echo -e "${CYAN}Official File:${NC}   $official_filename"
    echo -e "${CYAN}Built File:${NC}      $official_filename"
    echo -e "${CYAN}Official SHA256:${NC}  $OFFICIAL_HASH"
    echo -e "${CYAN}Built SHA256:${NC}     $BUILT_HASH"
    echo -e "${CYAN}Hashes Match:${NC}     $([ "$OFFICIAL_HASH" = "$BUILT_HASH" ] && echo "✅ YES" || echo "❌ NO")"
    echo -e "${CYAN}GPG Signature:${NC}   $GPG_VALID"
    echo -e "${CYAN}Official Size:${NC}    $official_size bytes"
    echo -e "${CYAN}Built Size:${NC}       $built_size bytes"
    echo -e "${CYAN}Build Time:${NC}       $build_duration"
    echo -e "${CYAN}Verdict:${NC}         $VERDICT"
    echo -e "${CYAN}==========================================${NC}"
}

# Show cleanup options
show_cleanup_options() {
    local workdir="$1"
    
    echo -e "\n${GREEN}🧹 Cleanup Options:${NC}"
    echo -e "${GREEN}# Remove all build artifacts (keeps source):${NC}"
    echo -e "${GREEN}rm -rf \"$workdir/build\"${NC}"
    echo -e "${GREEN}# Remove downloaded files:${NC}"
    echo -e "${GREEN}rm -rf \"$workdir/official\"${NC}"
    echo -e "${GREEN}# Remove everything:${NC}"
    echo -e "${GREEN}rm -rf \"$workdir\"${NC}"
}

# Main function
main() {
    # Handle help requests
    if [ "$1" = "--help" ] || [ "$1" = "-h" ] || [ $# -eq 0 ]; then
        show_help
        exit 0
    fi
    
    # Validate arguments
    if [ $# -lt 2 ]; then
        echo -e "${RED}Error: Insufficient arguments${NC}" >&2
        echo -e "Usage: $0 <version> <target>" >&2
        echo -e "Try '$0 --help' for more information." >&2
        exit 1
    fi
    
    local version="$1"
    local target="$2"
    
    # Validate target
    if ! get_filename "$version" "$target" >/dev/null 2>&1; then
        echo -e "${RED}❌ Invalid target: $target${NC}"
        show_help
        exit 1
    fi
    
    echo -e "${CYAN}verify_bitcoinknots.sh v1.1.0 - Bitcoin Knots Verification${NC}"
    echo -e "${CYAN}================================================================${NC}"
    
    # Setup directory structure
    local workdir=$(setup_directories "$version" "$target")
    
    # Log session
    log_session "$version" "$target" "$workdir"
    
    echo -e "\n${CYAN}🚀 Starting Bitcoin Knots reproducible build verification...${NC}"
    echo -e "${CYAN}📋 App: $APP_NAME | Version: $version | Target: $target${NC}"
    
    # Execute build and verification steps
    if ! download_official "$version" "$target" "$workdir"; then
        echo -e "\n${RED}❌ FATAL: Download failed${NC}"
        echo -e "${YELLOW}Check network connection and release availability${NC}"
        exit 1
    fi
    
    if ! verify_signatures "$version" "$target" "$workdir"; then
        echo -e "\n${RED}❌ FATAL: Signature verification failed${NC}"
        echo -e "${YELLOW}Downloaded files may be corrupted or tampered with${NC}"
        exit 1
    fi
    
    if ! build_bitcoin_knots "$version" "$target" "$workdir"; then
        echo -e "\n${RED}❌ FATAL: Build failed${NC}"
        echo -e "${YELLOW}Check build logs above for detailed error information${NC}"
        exit 1
    fi
    
    if ! compare_binaries "$version" "$target" "$workdir"; then
        echo -e "\n${RED}❌ FATAL: Binary comparison failed${NC}"
        echo -e "${YELLOW}Build completed but binaries do not match - NOT REPRODUCIBLE${NC}"
    else
        echo -e "\n${GREEN}✅ All verification steps completed successfully${NC}"
        echo -e "${GREEN}✅ BUILD IS REPRODUCIBLE!${NC}"
    fi
    
    # Always show summary and cleanup options
    generate_summary "$version" "$target" "$workdir"
    show_cleanup_options "$workdir"
    
    echo -e "\n${GREEN}🎉 Bitcoin Knots verification completed!${NC}"
    echo -e "${CYAN}📊 Results and artifacts available in: $workdir${NC}"
}

# Execute main function with all arguments
main "$@"