#!/bin/bash
# cleanUpServer.sh - Remote server cleanup script for WalletScrutiny
# Checks disk space and cleans up if < 60GB available on /dev/vda1

set -e

# Color constants
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Remote server connection (using existing alias)
REMOTE_SERVER="danny@backend.walletscrutiny.com"

echo "Connecting to remote server: $REMOTE_SERVER"

# Check available disk space and cleanup if needed
ssh -t "$REMOTE_SERVER" '
set -e

# Colors for remote output
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
NC="\033[0m"

echo "Checking disk space on /dev/vda1..."

# Get available space in GB
AVAIL_SPACE_KB=$(df /dev/vda1 | awk "NR==2 {print \$4}")
AVAIL_SPACE_GB=$((AVAIL_SPACE_KB / 1024 / 1024))

echo "Available space: ${AVAIL_SPACE_GB}GB"

if [ "$AVAIL_SPACE_GB" -lt 60 ]; then
    echo "Available space (${AVAIL_SPACE_GB}GB) is less than 60GB. Starting cleanup..."
    
    # Cleanup specified directories with single sudo command
    cd /tmp
    echo "Removing:"
    
    directories_to_remove="blixt-test* com.kraken.superwallet electrum_build extract_base* flash-mobile-build* fromBuild* fromPlay* jade* keystone3-firmware* shapeshift-build* test_* tmp* yarn* muun* electrum* bithd* onekey*"
    
    # First show what will be deleted
    for pattern in $directories_to_remove; do
        matches=$(ls -d $pattern 2>/dev/null || true)
        if [ -n "$matches" ]; then
            echo "$matches" | while read -r match; do
                echo "- $(basename "$match")"
            done
        fi
    done
    
    echo ""
    echo "Executing cleanup with sudo (password required once)..."
    
    # Single sudo command to delete all patterns
    sudo bash -c "
        cd /tmp
        for pattern in $directories_to_remove; do
            if ls -d \$pattern >/dev/null 2>&1; then
                echo \"Deleting: \$pattern\"
                rm -rf \$pattern 2>/dev/null || echo \"Failed: \$pattern\"
            fi
        done
        echo \"Cleanup completed.\"
    "
    
    # Docker cleanup
    echo "Cleaning up Docker containers and images..."
    docker container prune -f 2>/dev/null || true
    docker image prune -a -f 2>/dev/null || true
    docker system prune -a -f 2>/dev/null || true
    
    # Podman cleanup
    echo "Cleaning up Podman containers and images..."
    podman container prune -f 2>/dev/null || true
    podman image prune -a -f 2>/dev/null || true
    podman system prune -a -f --volumes 2>/dev/null || true

    # Clean up Podman/Buildah overlay storage with permission issues
    echo "Cleaning up container overlay storage (requires sudo)..."
    sudo podman system reset -f 2>/dev/null || true

    # Cache directory cleanup
    echo "Cleaning up cache directories..."

    # Clean yarn cache
    if [ -d ~/.yarn ]; then
        echo "- Clearing yarn cache (~/.yarn)"
        rm -rf ~/.yarn 2>/dev/null || true
    fi

    # Clean general cache
    if [ -d ~/.cache ]; then
        echo "- Clearing general cache (~/.cache)"
        rm -rf ~/.cache/* 2>/dev/null || true
    fi

    # Clean Kotlin/Native cache
    if [ -d ~/.konan ]; then
        echo "- Clearing Kotlin/Native cache (~/.konan)"
        rm -rf ~/.konan 2>/dev/null || true
    fi

    # Clean gradle cache
    if [ -d ~/.gradle-home ]; then
        echo "- Clearing Gradle home cache (~/.gradle-home)"
        rm -rf ~/.gradle-home 2>/dev/null || true
    fi

    # Clean Android SDK cache (build-cache only, preserve SDK)
    if [ -d ~/.android/build-cache ]; then
        echo "- Clearing Android build cache (~/.android/build-cache)"
        rm -rf ~/.android/build-cache 2>/dev/null || true
    fi

    # Clean Docker cache that might remain in ~/.docker
    if [ -d ~/.docker ]; then
        echo "- Clearing Docker config cache (~/.docker)"
        rm -rf ~/.docker/buildx ~/.docker/scan 2>/dev/null || true
    fi

    echo "Cleanup completed."
else
    echo "Sufficient disk space available (${AVAIL_SPACE_GB}GB >= 60GB). No cleanup needed."
fi

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}     DISK USAGE ANALYSIS${NC}"
echo -e "${CYAN}========================================${NC}"

echo -e "\n${CYAN}Top 5 largest subdirectories in /tmp:${NC}"
du -sh /tmp/*/ 2>/dev/null | sort -hr | head -5 | while read size dir; do
    echo "  $size  $dir"
done

echo -e "\n${CYAN}Top 5 largest subdirectories in /home:${NC}"
du -sh /home/*/ 2>/dev/null | sort -hr | head -5 | while read size dir; do
    echo "  $size  $dir"  
done

echo -e "\n${CYAN}Top 5 largest subdirectories in /var/shared/apk:${NC}"
du -sh /var/shared/apk/*/ 2>/dev/null | sort -hr | head -5 | while read size dir; do
    echo "  $size  $dir"
done

echo -e "\n${YELLOW}Top 10 largest subdirectories in /home/danny:${NC}"
du -sh /home/danny/*/ 2>/dev/null | sort -hr | head -10 | while read size dir; do
    echo "  $size  $dir"
done

echo -e "\n${YELLOW}Contents of ~/.local directory:${NC}"
du -sh /home/danny/.local/*/ 2>/dev/null | sort -hr | head -10 | while read size dir; do
    echo "  $size  $dir"
done

echo -e "\n${YELLOW}Container storage overlay layers:${NC}"
if [ -d /home/danny/.local/share/containers/storage/overlay ]; then
    overlay_count=$(find /home/danny/.local/share/containers/storage/overlay -maxdepth 1 -type d 2>/dev/null | wc -l)
    overlay_size=$(du -sh /home/danny/.local/share/containers/storage/overlay 2>/dev/null | cut -f1)
    echo "  Overlay layers count: $overlay_count"
    echo "  Overlay total size: $overlay_size"
else
    echo "  No overlay storage found"
fi

echo -e "\n${CYAN}Current disk usage:${NC}"
df -h /dev/vda1
'

echo "Server cleanup and analysis completed."
