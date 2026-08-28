#!/bin/bash
#
# sparrowdesktop_build.sh - Sparrow Desktop Reproducible Build Verifier
# Version: v0.19.1
#
# Linux (tarball/deb/rpm) builds run containerized via Docker/Podman;
# Windows (msi/zip) builds run via GitHub Actions.
#
# Organization: WalletScrutiny.com
# Repository: https://gitlab.com/walletscrutiny/walletScrutinyCom
#

set -euo pipefail

SCRIPT_VERSION="v0.19.1"

GH_REPO="xrviv/WalletScrutinyCom"
GH_WORKFLOW="sparrow-build.yml"
GH_WORKFLOW_REF="master"
GH_HELPER_IMAGE="sparrow-gh-helper"
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

DEFAULT_JDK_VERSION="25.0.2+10"
DEFAULT_BASE_IMAGE="ubuntu:22.04"
DOCKER_CMD="${DOCKER_CMD:-}"

APP_VERSION=""
APP_ARCH=""
APP_TYPE=""
WORK_DIR=""
CUSTOM_WORK_DIR=""
NO_CACHE=false
KEEP_CONTAINER=false
QUIET=false
BINARY_PATH=""

die() {
    echo "ERROR: $1" >&2
    exit "${2:-$EXIT_BUILD_FAILED}"
}

warn() {
    echo "WARN: $1" >&2
}

detect_container_cmd() {
    if [[ -n "$DOCKER_CMD" ]]; then
        return
    fi
    if command -v podman >/dev/null 2>&1; then
        DOCKER_CMD="podman"
    elif command -v docker >/dev/null 2>&1; then
        DOCKER_CMD="docker"
    else
        die "Neither podman nor docker was found in PATH" $EXIT_INVALID_PARAMS
    fi
}

require_value() {
    local flag="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        die "Missing value for parameter: $flag" $EXIT_INVALID_PARAMS
    fi
}

sanitize_component() {
    local input="$1"
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    input=$(echo "$input" | sed -E 's/[^a-z0-9]+/-/g')
    input="${input#-}"
    input="${input%-}"
    if [[ -z "$input" ]]; then
        input="na"
    fi
    echo "$input"
}

is_windows_arch() {
    case "${1:-}" in
        x86_64-windows|win-x64|win64|windows) return 0 ;;
        *) return 1 ;;
    esac
}

build_gh_helper() {
    echo "[INFO] Building gh helper container..."
    "$DOCKER_CMD" build -t "${GH_HELPER_IMAGE}" - << 'GHEOF'
FROM debian:bookworm-slim
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg jq unzip p7zip-full \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update -qq \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*
GHEOF
}

gh_c() {
    "$DOCKER_CMD" run --rm \
        -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
        -v "${WORK_DIR}:/work" \
        -w /work \
        "${GH_HELPER_IMAGE}" \
        gh "$@"
}

parse_arguments() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --version VERSION --arch ARCH --type TYPE [OPTIONS]"
        echo "  --arch x86_64-linux-gnu --type tarball|deb|rpm"
        echo "  --arch x86_64-windows   --type msi|zip   (requires --binary FILE)"
        exit $EXIT_INVALID_PARAMS
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --version)
                require_value "$1" "${2:-}"
                APP_VERSION="$2"
                shift 2
                ;;
            --arch)
                require_value "$1" "${2:-}"
                APP_ARCH="$2"
                shift 2
                ;;
            --type)
                require_value "$1" "${2:-}"
                APP_TYPE="$2"
                shift 2
                ;;
            --binary)
                require_value "$1" "${2:-}"
                BINARY_PATH="$2"
                shift 2
                ;;
            --apk)
                if [[ $# -ge 2 && "${2:-}" != --* ]]; then
                    shift 2
                else
                    shift
                fi
                ;;
            --work-dir)
                require_value "$1" "${2:-}"
                CUSTOM_WORK_DIR="$2"
                shift 2
                ;;
            --no-cache)
                NO_CACHE=true
                shift
                ;;
            --keep-container)
                KEEP_CONTAINER=true
                shift
                ;;
            --quiet)
                QUIET=true
                shift
                ;;
            *)
                warn "Ignoring unknown parameter: $1"
                if [[ $# -ge 2 && "${2:-}" != --* ]]; then
                    shift 2
                else
                    shift
                fi
                ;;
        esac
    done

    if [[ -z "$APP_VERSION" ]]; then
        die "Missing required parameter: --version" $EXIT_INVALID_PARAMS
    fi
    if [[ -z "$APP_ARCH" ]]; then
        die "Missing required parameter: --arch" $EXIT_INVALID_PARAMS
    fi

    if is_windows_arch "$APP_ARCH"; then
        if [[ -z "$BINARY_PATH" ]]; then
            die "Missing required parameter: --binary (required for Windows arch)" $EXIT_INVALID_PARAMS
        fi
        if [[ ! -f "$BINARY_PATH" ]]; then
            die "--binary path does not exist: $BINARY_PATH" $EXIT_INVALID_PARAMS
        fi
        BINARY_PATH=$(realpath "$BINARY_PATH")
        local bname
        bname=$(basename "$BINARY_PATH")
        if [[ -z "$APP_TYPE" ]]; then
            case "$bname" in
                *.msi) APP_TYPE="msi" ;;
                *.zip) APP_TYPE="zip" ;;
                *) die "--binary '$bname' must be .msi or .zip for Windows arch" $EXIT_INVALID_PARAMS ;;
            esac
        else
            case "$APP_TYPE" in
                msi) [[ "$bname" == *.msi ]] || die "--type msi but --binary '$bname' is not .msi" $EXIT_INVALID_PARAMS ;;
                zip) [[ "$bname" == *.zip ]] || die "--type zip but --binary '$bname' is not .zip" $EXIT_INVALID_PARAMS ;;
                *) die "Invalid --type '$APP_TYPE' for Windows (must be msi or zip)" $EXIT_INVALID_PARAMS ;;
            esac
        fi
    else
        if [[ -z "$APP_TYPE" ]]; then
            die "Missing required parameter: --type" $EXIT_INVALID_PARAMS
        fi
        if [[ "$APP_TYPE" != "tarball" ]] && [[ "$APP_TYPE" != "deb" ]] && [[ "$APP_TYPE" != "rpm" ]]; then
            die "Invalid type: $APP_TYPE (must be tarball, deb, or rpm)" $EXIT_INVALID_PARAMS
        fi
        if [[ -n "$BINARY_PATH" && ! -f "$BINARY_PATH" ]]; then
            die "--binary path does not exist: $BINARY_PATH" $EXIT_INVALID_PARAMS
        fi
        if [[ -n "$BINARY_PATH" ]]; then
            BINARY_PATH=$(realpath "$BINARY_PATH")
            local bname
            bname=$(basename "$BINARY_PATH")
            case "$APP_TYPE" in
                tarball) [[ "$bname" == *.tar.gz ]] || die "--binary '$bname' does not look like a tarball; expected .tar.gz for --type tarball" $EXIT_INVALID_PARAMS ;;
                deb)     [[ "$bname" == *.deb ]]    || die "--binary '$bname' does not look like a deb; expected .deb for --type deb" $EXIT_INVALID_PARAMS ;;
                rpm)     [[ "$bname" == *.rpm ]]    || die "--binary '$bname' does not look like an rpm; expected .rpm for --type rpm" $EXIT_INVALID_PARAMS ;;
            esac
        fi
    fi
}


build_and_verify() {
    local version_component arch_component type_component suffix execution_dir

    version_component=$(sanitize_component "$APP_VERSION")
    arch_component=$(sanitize_component "$APP_ARCH")
    type_component=$(sanitize_component "$APP_TYPE")
    suffix=$(sanitize_component "$(date +%s)-$$")

    local container_name="sparrow-verify-${version_component}-${arch_component}-${type_component}-${suffix}"
    local image_name="sparrow-verifier:${version_component}-${arch_component}-${type_component}-${suffix}"

    execution_dir="$(pwd)"

    if [[ -n "$CUSTOM_WORK_DIR" ]]; then
        WORK_DIR="$CUSTOM_WORK_DIR"
    else
        WORK_DIR="${execution_dir}/sparrow_desktop_${version_component}_${arch_component}_${type_component}_$$"
    fi

    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    # Always create sparrow_official_binary so the Dockerfile COPY always succeeds.
    # If --binary provided, populate it; otherwise leave it empty (wget path runs).
    if [[ -n "$BINARY_PATH" ]]; then
        cp "$BINARY_PATH" "${WORK_DIR}/sparrow_official_binary"
        BINARY_PROVIDED_FLAG="1"
        [[ "$QUIET" != true ]] && echo "Using provided binary: $(basename "$BINARY_PATH")"
    else
        touch "${WORK_DIR}/sparrow_official_binary"
        BINARY_PROVIDED_FLAG="0"
    fi

    [[ "$QUIET" != true ]] && echo "======================================================"
    [[ "$QUIET" != true ]] && echo "Sparrow Desktop v$APP_VERSION - Containerized Build"
    [[ "$QUIET" != true ]] && echo "======================================================"
    [[ "$QUIET" != true ]] && echo ""

    create_verify_script
    create_dockerfile

    [[ "$QUIET" != true ]] && echo "Building and verifying in container..."
    [[ "$QUIET" != true ]] && echo ""

    local cache_flag=""
    [[ "$NO_CACHE" == true ]] && cache_flag="--no-cache"

    if ! $DOCKER_CMD build $cache_flag \
        --build-arg SPARROW_VERSION="$APP_VERSION" \
        --build-arg BUILD_TYPE="$APP_TYPE" \
        --build-arg BUILD_ARCH="$APP_ARCH" \
        --build-arg SCRIPT_VERSION="$SCRIPT_VERSION" \
        --build-arg BINARY_PROVIDED="$BINARY_PROVIDED_FLAG" \
        --build-arg META_STRICT="${META_STRICT:-true}" \
        -t "$image_name" . 2>&1 | tee build.log; then
        echo ""
        die "Container build failed" $EXIT_BUILD_FAILED
    fi

    [[ "$QUIET" != true ]] && echo ""
    [[ "$QUIET" != true ]] && echo "Extracting results..."

    if $DOCKER_CMD ps -a --format '{{.Names}}' | grep -Fxq "$container_name"; then
        $DOCKER_CMD rm -f "$container_name" > /dev/null 2>&1
    fi

    $DOCKER_CMD create --name "$container_name" "$image_name" > /dev/null
    $DOCKER_CMD cp "$container_name:/output/COMPARISON_RESULTS.yaml" ./ 2>/dev/null || \
        die "Failed to extract YAML results" $EXIT_BUILD_FAILED

    if [[ "$execution_dir" != "$WORK_DIR" ]]; then
        cp ./COMPARISON_RESULTS.yaml "$execution_dir/" 2>/dev/null || \
            die "Failed to copy YAML to execution directory" $EXIT_BUILD_FAILED
    fi

    if [[ "$KEEP_CONTAINER" != true ]]; then
        $DOCKER_CMD rm "$container_name" > /dev/null 2>&1
    fi

    display_results "$execution_dir"
}

create_verify_script() {
    cat > verify.sh << 'VERIFY_END'
#!/bin/bash
set -euo pipefail

SCRIPT_VERSION="${SCRIPT_VERSION:-unknown}"
BUILD_TYPE="${BUILD_TYPE:-tarball}"
SPARROW_VERSION="${SPARROW_VERSION:-unknown}"
BUILD_ARCH="${BUILD_ARCH:-x86_64-linux-gnu}"

print_file_comparison() {
    local official_list="$1"
    local built_list="$2"
    local diff_count=0

    mapfile -t official_files < "$official_list"
    mapfile -t built_files < "$built_list"

    local i=0 j=0
    local official_total=${#official_files[@]}
    local built_total=${#built_files[@]}

    echo ""
    echo "  File comparison (Official >> Built) — differences only"
    printf "    %-55s | %-55s\n" "Official" "Built"
    printf "    %-55s | %-55s\n" "--------" "-----"

    while (( i < official_total || j < built_total )); do
        local official="${official_files[i]-}"
        local built="${built_files[j]-}"
        local left="" right=""

        if [[ -n "${official:-}" && -n "${built:-}" ]]; then
            if [[ "$official" == "$built" ]]; then
                ((++i)); ((++j)); continue
            fi
            if [[ "$official" < "$built" ]]; then
                left="$official"; right="(missing)"; ((++i))
            else
                left="(missing)"; right="$built"; ((++j))
            fi
        elif [[ -n "${official:-}" ]]; then
            left="$official"; right="(missing)"; ((++i))
        else
            left="(missing)"; right="$built"; ((++j))
        fi

        ((++diff_count))
        printf "    %-55s | %-55s\n" "$left" "$right"
    done

    if (( diff_count == 0 )); then
        echo "    (No file differences detected)"
    fi
}

echo "========================================================"
echo "VERIFICATION PHASE"
echo "========================================================"
echo ""

# Hash-compare every path listed in $1 between built root $2 and official root $3.
# Prints the standard four-line block per path. Sets CMP_TOTAL and CMP_DIFF.
cmp_tree() {
    local listing="$1" broot="$2" oroot="$3"
    local rel bf of bh oh st idx=0
    CMP_TOTAL=$(wc -l < "$listing" | tr -d ' ')
    CMP_DIFF=0
    while IFS= read -r rel; do
        idx=$((idx + 1))
        bf="${broot}/${rel#./}"
        of="${oroot}/${rel#./}"
        bh="(missing)"; oh="(missing)"; st="⚠ MISSING"
        [[ -f "$bf" ]] && bh=$(sha256sum "$bf" | cut -d' ' -f1)
        [[ -f "$of" ]] && oh=$(sha256sum "$of" | cut -d' ' -f1)
        [[ -L "$bf" ]] && bh="symlink -> $(readlink "$bf")"
        [[ -L "$of" ]] && oh="symlink -> $(readlink "$of")"
        if [[ -f "$bf" && -f "$of" ]]; then
            if [[ "$bh" == "$oh" ]]; then
                st="✓ MATCH"
            else
                st="⚠ DIFFER"; CMP_DIFF=$((CMP_DIFF + 1))
            fi
        else
            CMP_DIFF=$((CMP_DIFF + 1))
        fi
        printf "  %3d/%-3d: %s\n" "$idx" "$CMP_TOTAL" "${rel#./}"
        echo "          Built:    $bh"
        echo "          Official: $oh"
        echo "          Status:   $st"
        echo ""
    done < "$listing"
}

# Phase 1
echo "Phase 1: Critical Binaries Comparison"
echo "------------------------------------------------------"

CRITICAL_MATCH=true
for file in bin/Sparrow lib/libapplauncher.so lib/Sparrow.png lib/app/Sparrow.cfg; do
    built_hash=$(sha256sum /built/Sparrow/$file 2>/dev/null | cut -d' ' -f1)
    official_hash=$(sha256sum /official/Sparrow/$file 2>/dev/null | cut -d' ' -f1)

    echo "  $file:"
    echo "    Built:    $built_hash"
    echo "    Official: $official_hash"

    if [[ "$built_hash" != "$official_hash" ]]; then
        echo "    Status:   ✗ MISMATCH"
        CRITICAL_MATCH=false
    else
        echo "    Status:   ✓ MATCH"
    fi
    echo ""
done

# Phase 2
echo "Phase 2: Modules File Deep Inspection (jimage)"
echo "------------------------------------------------------"
echo ""

modules_built_hash=$(sha256sum /built/Sparrow/lib/runtime/lib/modules 2>/dev/null | cut -d' ' -f1)
modules_official_hash=$(sha256sum /official/Sparrow/lib/runtime/lib/modules 2>/dev/null | cut -d' ' -f1)

echo "  lib/runtime/lib/modules (side-by-side):"
echo "  ┌─────────────────────────────────────────────────────────────────┐"
echo "  │ Built:    $modules_built_hash │"
echo "  │ Official: $modules_official_hash │"
echo "  └─────────────────────────────────────────────────────────────────┘"
echo ""

if [[ "$modules_built_hash" == "$modules_official_hash" ]]; then
    echo "  ✓ Modules file: IDENTICAL"
    MODULES_MATCH=true
    MODULES_DIFF_COUNT=0
else
    echo "  ⚠ Modules file hash differs - performing deep inspection..."
    echo ""

    mkdir -p /extracted/built /extracted/official

    echo "  Extracting built modules..."
    if ! jimage extract --dir /extracted/built /built/Sparrow/lib/runtime/lib/modules 2>&1; then
        echo "  ✗ ERROR: Failed to extract built modules"
        MODULES_MATCH=false
        MODULES_DIFF_COUNT=-1
    else
        echo "  ✓ Built modules extracted"
        echo "  Extracting official modules..."
        if ! jimage extract --dir /extracted/official /official/Sparrow/lib/runtime/lib/modules 2>&1; then
            echo "  ✗ ERROR: Failed to extract official modules"
            MODULES_MATCH=false
            MODULES_DIFF_COUNT=-1
        else
            echo "  ✓ Official modules extracted"
            echo ""
            echo "  Comparing extracted class files..."
            diff_output=$(mktemp /tmp/sparrow-modules-diff.XXXXXX)

            diff_exit=0
            diff -r /extracted/built /extracted/official > "$diff_output" 2>&1 || diff_exit=$?

            if [[ $diff_exit -gt 1 ]]; then
                echo "  ✗ ERROR: diff failed (exit $diff_exit)"
                rm -f "$diff_output"
                MODULES_MATCH=false
                MODULES_DIFF_COUNT=-1
                exit 1
            fi

            MODULES_DIFF_COUNT=$(awk '/^Files .* differ$/ || /^Only in / {count++} END {print count+0}' "$diff_output")

            if [[ "$MODULES_DIFF_COUNT" -eq 0 ]]; then
                echo "  ✓ Deep inspection: All classes IDENTICAL"
                echo "  ℹ Hash difference due to compression/ordering only"
                MODULES_MATCH=true
                rm -f "$diff_output"
            else
                echo "  ✗ Deep inspection: $MODULES_DIFF_COUNT class differences"
                echo ""
                echo "  Differing files (first 20):"
                grep -E '^Files .* differ$|^Only in ' "$diff_output" | head -20 | while read -r line; do
                    f=$(echo "$line" | sed 's/Files \/extracted\/built\//  - /' | sed 's/ and.*//' | sed 's/^Only in /  + Only in /')
                    echo "$f"
                done
                MODULES_MATCH=false
                rm -f "$diff_output"
            fi
        fi
    fi
fi
echo ""

# Phase 3
echo "Phase 3: File Count Analysis"
echo "------------------------------------------------------"

built_listing=$(mktemp /tmp/sparrow-built-list.XXXXXX)
official_listing=$(mktemp /tmp/sparrow-official-list.XXXXXX)
built_legal_listing=$(mktemp /tmp/sparrow-built-legal.XXXXXX)
official_legal_listing=$(mktemp /tmp/sparrow-official-legal.XXXXXX)

(cd /built/Sparrow && find . \( -type f -o -type l \) | sort) > "$built_listing"
(cd /official/Sparrow && find . \( -type f -o -type l \) | sort) > "$official_listing"
(cd /built/Sparrow && find . \( -type f -o -type l \) -path '*/lib/runtime/legal/*' | sort) > "$built_legal_listing"
(cd /official/Sparrow && find . \( -type f -o -type l \) -path '*/lib/runtime/legal/*' | sort) > "$official_legal_listing"

build_total=$(wc -l < "$built_listing" | tr -d ' ')
official_total=$(wc -l < "$official_listing" | tr -d ' ')
built_legal_count=$(wc -l < "$built_legal_listing" | tr -d ' ')
official_legal_count=$(wc -l < "$official_legal_listing" | tr -d ' ')

build_count=$((build_total - built_legal_count))
official_count=$((official_total - official_legal_count))

echo "  Total files (built):    $build_total"
echo "  Total files (official): $official_total"
echo ""

if [[ "$built_legal_count" -ne "$official_legal_count" ]]; then
    echo "  ℹ EXCLUDED FROM VERDICT: lib/runtime/legal/ (JDK license texts)"
    echo "    Built has:    $built_legal_count legal files"
    echo "    Official has: $official_legal_count legal files"
    echo "    Difference:   $((official_legal_count - built_legal_count)) files"
    echo "    Reason: jpackage omits these in containers; not executable code"
    echo ""
    echo "    Missing legal files:"
    comm -23 "$official_legal_listing" "$built_legal_listing" | while read -r file; do
        echo "      - $file"
    done
    echo ""
fi

echo "  Comparable files (excluding legal):"
echo "    Built:    $build_count"
echo "    Official: $official_count"

if [[ "$build_count" -eq "$official_count" ]]; then
    echo "  ✓ File counts match"
    FILE_COUNT_MATCH=true
else
    echo "  ⚠ File count differs by $((official_count - build_count))"
    FILE_COUNT_MATCH=false
    grep -v 'lib/runtime/legal/' "$built_listing" > "${built_listing}.filtered"
    grep -v 'lib/runtime/legal/' "$official_listing" > "${official_listing}.filtered"
    print_file_comparison "${official_listing}.filtered" "${built_listing}.filtered"
    rm -f "${built_listing}.filtered" "${official_listing}.filtered"
fi
echo ""

ds=0; diff -q "$official_listing" "$built_listing" >/dev/null || ds=$?
[[ "$ds" -le 1 ]] || { echo "ERROR: diff status $ds"; exit "$ds"; }
if [[ "$ds" -eq 1 ]]; then
    echo "  ⚠ Tree file sets differ (official vs built):"
    diff "$official_listing" "$built_listing" | sed 's/^/    /' || [ $? -eq 1 ]
    FILE_COUNT_MATCH=false
fi
rm -f "$built_listing" "$official_listing" "$built_legal_listing" "$official_legal_listing"

# Phase 4
echo "Phase 4: File-by-file Verification"
echo "------------------------------------------------------"

full_listing=$(mktemp /tmp/sparrow-full-list.XXXXXX)
{ (cd /official/Sparrow && find . \( -type f -o -type l \) -print)
  (cd /built/Sparrow && find . \( -type f -o -type l \) -print); } | sort -u > "$full_listing"
cmp_tree "$full_listing" /built/Sparrow /official/Sparrow
diff_files=$CMP_DIFF
rm -f "$full_listing"

FILE_HASH_MATCH=true
if [[ "$diff_files" -gt 0 ]]; then
    FILE_HASH_MATCH=false
fi

# Compare two parallel trees: /built/$1 against /official/$1. Prints a numbered
# block per path. Sets AREA_MATCH to true/false, or leaves it n/a if absent.
compare_area() {
    AREA_MATCH="n/a"
    [[ -d "/official/$1" && -d "/built/$1" ]] || return 0
    echo "$2"
    echo "------------------------------------------------------"
    local ol bl un
    ol=$(mktemp); bl=$(mktemp); un=$(mktemp)
    (cd "/official/$1" && find . \( -type f -o -type l \) | sort) > "$ol"
    (cd "/built/$1" && find . \( -type f -o -type l \) | sort) > "$bl"
    sort -u "$ol" "$bl" > "$un"
    local ds=0; diff -q "$ol" "$bl" >/dev/null || ds=$?
    [[ "$ds" -le 1 ]] || { echo "ERROR: diff status $ds"; exit "$ds"; }
    if [[ "$ds" -eq 1 ]]; then
        echo "  ⚠ File sets differ (official vs built):"
        diff "$ol" "$bl" | sed 's/^/    /' || [ $? -eq 1 ]
        echo ""
    fi
    cmp_tree "$un" "/built/$1" "/official/$1"
    if [[ "$CMP_DIFF" -eq 0 ]]; then
        AREA_MATCH=true
        echo "  ✓ $CMP_TOTAL file(s) match"
    else
        AREA_MATCH=false
        echo "  ⚠ $CMP_DIFF difference(s) found"
    fi
    echo ""
}

compare_area meta "Phase 5: Package Metadata Comparison"
META_MATCH="$AREA_MATCH"
compare_area extra "Phase 6: Out-of-subtree Payload Comparison"
EXTRA_MATCH="$AREA_MATCH"

# META_STRICT=false downgrades a metadata mismatch to a warning that does not
# change the verdict. Default is strict.
META_STRICT="${META_STRICT:-true}"
META_OK=true
if [[ "$META_MATCH" == "false" && "$META_STRICT" != "false" ]]; then
    META_OK=false
fi
EXTRA_OK=true
[[ "$EXTRA_MATCH" == "false" ]] && EXTRA_OK=false

if [[ "$CRITICAL_MATCH" == "true" ]] && [[ "$MODULES_MATCH" == "true" ]] && [[ "$FILE_COUNT_MATCH" == "true" ]] && [[ "$FILE_HASH_MATCH" == "true" ]] && [[ "$META_OK" == "true" ]] && [[ "$EXTRA_OK" == "true" ]]; then
    STATUS="reproducible"
    VERDICT="✅ REPRODUCIBLE"
else
    STATUS="not_reproducible"
    VERDICT="❌ NOT REPRODUCIBLE"

    [[ "$CRITICAL_MATCH" != "true" ]] && echo "  Reason: Critical binaries differ"
    [[ "$MODULES_MATCH" != "true" ]]  && echo "  Reason: Module classes differ"
    [[ "$FILE_COUNT_MATCH" != "true" ]] && echo "  Reason: File set/count mismatch ($build_count built vs $official_count official)"
    [[ "$FILE_HASH_MATCH" != "true" ]]  && echo "  Reason: $diff_files file(s) have different content (Phase 4)"
    [[ "$META_OK" != "true" ]] && echo "  Reason: package install metadata differs (Phase 5); maintainer scripts may run as root"
    [[ "$EXTRA_OK" != "true" ]] && echo "  Reason: payload outside the application subtree differs (Phase 6)"
fi

mkdir -p /output

cat > /output/COMPARISON_RESULTS.yaml << YAML_END
script_version: ${SCRIPT_VERSION}
verdict: ${STATUS}
notes: |
  Built from source at tag ${SPARROW_VERSION} in Ubuntu 22.04 with Eclipse Temurin
  JDK 25.0.2+10, via ./gradlew jpackage; the tarball type additionally runs
  ./gradlew packageTarDistribution so the compared artifact is the tarball upstream
  ships, not the pre-packaging jpackage tree. Verdict is a file-by-file comparison of extracted
  contents, not of the outer archive. Built-only lib/runtime/legal/ modules are removed
  before comparison. Phase 5 additionally compares install-time package metadata (deb:
  control, preinst, postinst, prerm, postrm, debian-binary; rpm: PREIN/POSTIN/PREUN/
  POSTUN scriptlets and interpreters). Symlinks are compared as links (target text),
  not dereferenced. Built and official file sets are compared both ways. Not compared:
  archive structure, file modes, ownership, timestamps. Payload outside the selected
  application subtree is compared separately in Phase 6.
  critical_binaries=${CRITICAL_MATCH} modules=${MODULES_MATCH} file_count=${FILE_COUNT_MATCH} file_hashes=${FILE_HASH_MATCH} package_metadata=${META_MATCH} out_of_subtree=${EXTRA_MATCH}
YAML_END

echo "========================================================"
echo "FINAL VERDICT: $VERDICT"
echo "========================================================"
echo ""
VERIFY_END
    chmod +x verify.sh
}

create_dockerfile() {
    cat > Dockerfile << 'DOCKERFILE_END'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    wget \
    git \
    tar \
    xz-utils \
    zstd \
    rpm \
    cpio \
    fakeroot \
    binutils \
    diffutils \
    coreutils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN wget -q https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.2%2B10/OpenJDK25U-jdk_x64_linux_hotspot_25.0.2_10.tar.gz && \
    tar -xzf OpenJDK25U-jdk_x64_linux_hotspot_25.0.2_10.tar.gz && \
    rm OpenJDK25U-jdk_x64_linux_hotspot_25.0.2_10.tar.gz

ENV JAVA_HOME=/opt/jdk-25.0.2+10
ENV PATH=${JAVA_HOME}/bin:${PATH}

WORKDIR /build
RUN git clone --recursive https://github.com/sparrowwallet/sparrow.git

WORKDIR /build/sparrow
ARG SPARROW_VERSION
ENV SPARROW_VERSION=${SPARROW_VERSION}
RUN git checkout "${SPARROW_VERSION}" && \
    git submodule update --init --recursive && \
    echo "Resolved commit: $(git rev-parse HEAD)" && git submodule status

ARG BUILD_TYPE
RUN ./gradlew jpackage && \
    if [ "${BUILD_TYPE}" = "deb" ]; then \
        cd build/jpackage && \
        DEB_FILE=$(ls *.deb | head -1) && \
        echo "Repackaging $DEB_FILE: ZSTD -> XZ compression" && \
        ar x "$DEB_FILE" && \
        unzstd control.tar.zst && \
        unzstd data.tar.zst && \
        xz -c control.tar > control.tar.xz && \
        xz -c data.tar > data.tar.xz && \
        rm "$DEB_FILE" && \
        ar cr "$DEB_FILE" debian-binary control.tar.xz data.tar.xz && \
        rm -f control.tar* data.tar* debian-binary && \
        echo "Repackaging complete: $DEB_FILE"; \
    fi

ARG BUILD_TYPE
RUN mkdir -p /built && \
    if [ "${BUILD_TYPE}" = "deb" ]; then \
        cp build/jpackage/*.deb /built/ && \
        cd /built && \
        DEB_FILE=$(ls *.deb | head -1) && \
        ar x "$DEB_FILE" && \
        tar -xf data.tar.xz && \
        SPARROW_DIR=$(find . -maxdepth 3 -type d \( -name 'Sparrow' -o -name 'sparrow' -o -name 'sparrowwallet' \) | head -1) && \
        [ -n "$SPARROW_DIR" ] || { echo "ERROR: no Sparrow dir in repackaged deb"; exit 1; } && \
        mv "$SPARROW_DIR" Sparrow && \
        mkdir -p /built/meta/control && \
        (set -- control.tar.*; [ $# -eq 1 ] || { echo "ERROR: $# control archives"; exit 1; }; \
            tar -xf "$1" -C /built/meta/control) && \
        cp debian-binary /built/meta/debian-binary && \
        mkdir -p /built/extra && \
        find . -mindepth 1 -maxdepth 1 ! -name Sparrow ! -name meta ! -name extra \
            ! -name "*.tar.*" ! -name debian-binary ! -name "*.deb" -exec cp -a {} /built/extra/ \; && \
        rm -rf opt usr control.tar.* data.tar.* debian-binary; \
    elif [ "${BUILD_TYPE}" = "rpm" ]; then \
        RPM_FILE=$(ls /build/sparrow/build/jpackage/*.rpm 2>/dev/null | head -1) && \
        if [ -z "$RPM_FILE" ]; then \
            echo "ERROR: No .rpm file found in build/jpackage/" && exit 1; \
        fi && \
        cp "$RPM_FILE" /built/ && \
        mkdir -p /tmp/rpm_extract_built && \
        (cd /tmp/rpm_extract_built && rpm2cpio /built/$(basename "$RPM_FILE") | cpio -idmv 2>/dev/null) && \
        SPARROW_DIR=$(find /tmp/rpm_extract_built -maxdepth 6 -type d \( -name 'Sparrow' -o -name 'sparrow' -o -name 'sparrowwallet' \) | head -1) && \
        [ -n "$SPARROW_DIR" ] || { echo "ERROR: no Sparrow dir in built rpm"; exit 1; } && \
        mv "$SPARROW_DIR" /built/Sparrow && \
        mkdir -p /built/extra && \
        (cd /tmp/rpm_extract_built && cp -a . /built/extra/) && \
        mkdir -p /built/meta/scriptlets && \
        for tag in PREIN POSTIN PREUN POSTUN PRETRANS POSTTRANS PREINPROG POSTINPROG \
                     PREUNPROG POSTUNPROG PRETRANSPROG POSTTRANSPROG; do \
            rpm -qp --qf "%{$tag}" "/built/$(basename "$RPM_FILE")" 2>/dev/null \
                > "/built/meta/scriptlets/$tag"; \
        done; \
    else \
        ./gradlew packageTarDistribution && \
        cd build/jpackage && \
        (set -- *.tar.gz; [ $# -eq 1 ] || { echo "ERROR: $# tarballs"; exit 1; }; \
            echo "Built artifact SHA256:" && sha256sum "$1" && \
            tar -xzf "$1" -C /built); \
    fi

WORKDIR /official
ARG BUILD_TYPE
ARG SPARROW_VERSION
ARG BINARY_PROVIDED=0
COPY sparrow_official_binary /tmp/sparrow_official_binary

RUN if [ "${BUILD_TYPE}" = "deb" ]; then \
        if [ "${BINARY_PROVIDED}" = "1" ]; then \
            cp /tmp/sparrow_official_binary sparrowwallet_${SPARROW_VERSION}-1_amd64.deb; \
        else \
            wget -q https://github.com/sparrowwallet/sparrow/releases/download/${SPARROW_VERSION}/sparrowwallet_${SPARROW_VERSION}-1_amd64.deb; \
        fi && \
        ar x sparrowwallet_${SPARROW_VERSION}-1_amd64.deb && \
        (set -- data.tar.*; [ $# -eq 1 ] || { echo "ERROR: $# data archives"; exit 1; }; \
            tar -xf "$1") && \
        SPARROW_DIR=$(find . -maxdepth 3 -type d \( -name 'Sparrow' -o -name 'sparrow' -o -name 'sparrowwallet' \) | head -1) && \
        [ -n "$SPARROW_DIR" ] || { echo "ERROR: no Sparrow dir in official deb"; exit 1; } && \
        mv "$SPARROW_DIR" Sparrow && \
        mkdir -p /official/meta/control && \
        (set -- control.tar.*; [ $# -eq 1 ] || { echo "ERROR: $# control archives"; exit 1; }; \
            tar -xf "$1" -C /official/meta/control) && \
        cp debian-binary /official/meta/debian-binary && \
        mkdir -p /official/extra && \
        find . -mindepth 1 -maxdepth 1 ! -name Sparrow ! -name meta ! -name extra \
            ! -name "*.tar.*" ! -name debian-binary ! -name "*.deb" -exec cp -a {} /official/extra/ \; && \
        rm -rf opt usr control.tar.* data.tar.* debian-binary; \
    elif [ "${BUILD_TYPE}" = "rpm" ]; then \
        if [ "${BINARY_PROVIDED}" = "1" ]; then \
            cp /tmp/sparrow_official_binary sparrowwallet-${SPARROW_VERSION}-1.x86_64.rpm; \
        else \
            wget -q https://github.com/sparrowwallet/sparrow/releases/download/${SPARROW_VERSION}/sparrowwallet-${SPARROW_VERSION}-1.x86_64.rpm; \
        fi && \
        mkdir -p /tmp/rpm_extract_official && \
        (cd /tmp/rpm_extract_official && rpm2cpio /official/sparrowwallet-${SPARROW_VERSION}-1.x86_64.rpm | cpio -idmv 2>/dev/null) && \
        SPARROW_DIR=$(find /tmp/rpm_extract_official -maxdepth 6 -type d \( -name 'Sparrow' -o -name 'sparrow' -o -name 'sparrowwallet' \) | head -1) && \
        [ -n "$SPARROW_DIR" ] || { echo "ERROR: no Sparrow dir in official rpm"; exit 1; } && \
        mv "$SPARROW_DIR" /official/Sparrow && \
        mkdir -p /official/extra && \
        (cd /tmp/rpm_extract_official && cp -a . /official/extra/) && \
        mkdir -p /official/meta/scriptlets && \
        for tag in PREIN POSTIN PREUN POSTUN PRETRANS POSTTRANS PREINPROG POSTINPROG \
                     PREUNPROG POSTUNPROG PRETRANSPROG POSTTRANSPROG; do \
            rpm -qp --qf "%{$tag}" \
                "/official/sparrowwallet-${SPARROW_VERSION}-1.x86_64.rpm" 2>/dev/null \
                > "/official/meta/scriptlets/$tag"; \
        done; \
    else \
        if [ "${BINARY_PROVIDED}" = "1" ]; then \
            cp /tmp/sparrow_official_binary sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz; \
        else \
            wget -q https://github.com/sparrowwallet/sparrow/releases/download/${SPARROW_VERSION}/sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz; \
        fi && \
        tar -xzf sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz; \
    fi

# Align legal files: remove extra legal modules from built that are absent in official
RUN echo "Official artifact SHA256:" && sha256sum /official/sparrowwallet* 2>/dev/null || true

RUN if [ -d "/official/Sparrow/lib/runtime/legal" ] && [ -d "/built/Sparrow/lib/runtime/legal" ]; then \
        cd /built/Sparrow/lib/runtime/legal && \
        find . -mindepth 1 -maxdepth 1 -type d | while read -r module_dir; do \
            module="${module_dir#./}"; \
            if [ ! -d "/official/Sparrow/lib/runtime/legal/${module}" ]; then \
                echo "Removed built-only legal module: ${module}"; \
                rm -rf "$module_dir"; \
            fi; \
        done; \
    fi

ARG SCRIPT_VERSION
ARG BUILD_ARCH
ARG BUILD_TYPE
ARG META_STRICT=true
ENV META_STRICT=${META_STRICT}
ENV SCRIPT_VERSION=${SCRIPT_VERSION}
ENV BUILD_ARCH=${BUILD_ARCH}
ENV BUILD_TYPE=${BUILD_TYPE}

COPY verify.sh /verify.sh
RUN chmod +x /verify.sh
RUN /verify.sh

CMD ["cat", "/output/COMPARISON_RESULTS.yaml"]
DOCKERFILE_END
}

# Hash-compare every path listed in $1 between official root $2 and built root $3.
# Prints the standard four-line block per path. Sets CMP_TOTAL, CMP_OK, CMP_BAD.
compare_extracted() {
    local listing="$1" oroot="$2" broot="$3"
    local rel oh bh st idx=0
    CMP_TOTAL=$(wc -l < "$listing" | tr -d ' ')
    CMP_OK=0
    CMP_BAD=0
    while IFS= read -r rel; do
        idx=$((idx + 1))
        oh="(missing)"; bh="(missing)"
        [[ -f "${oroot}/${rel#./}" ]] && oh=$(sha256sum "${oroot}/${rel#./}" | cut -d' ' -f1)
        [[ -f "${broot}/${rel#./}" ]] && bh=$(sha256sum "${broot}/${rel#./}" | cut -d' ' -f1)
        if [[ "$oh" == "$bh" ]]; then
            st="✓ MATCH"; CMP_OK=$((CMP_OK + 1))
        else
            st="⚠ DIFFER"; CMP_BAD=$((CMP_BAD + 1))
        fi
        printf "  %3d/%-3d: %s\n" "$idx" "$CMP_TOTAL" "${rel#./}"
        echo "            Official: ${oh}"
        echo "            Built:    ${bh}"
        echo "            Status:   ${st}"
        echo ""
    done < "$listing"
}

# Write an ftbfs COMPARISON_RESULTS.yaml, copy it out, and abort. $1 is used as
# both the YAML note and the abort message.
ftbfs_die() {
    printf 'script_version: %s\nverdict: ftbfs\nnotes: "%s"\n' "$SCRIPT_VERSION" "$1" > "$results_file"
    cp "$results_file" "$execution_dir/" 2>/dev/null || true
    die "$1" $EXIT_BUILD_FAILED
}

build_and_verify_windows() {
    if [[ -z "${GITHUB_TOKEN}" ]]; then
        die "GITHUB_TOKEN (or GH_TOKEN) env var is required for Windows builds — needs 'workflow' scope" $EXIT_INVALID_PARAMS
    fi

    local version_component arch_component execution_dir
    version_component=$(sanitize_component "$APP_VERSION")
    arch_component=$(sanitize_component "$APP_ARCH")
    execution_dir="$(pwd)"

    if [[ -n "$CUSTOM_WORK_DIR" ]]; then
        WORK_DIR="$CUSTOM_WORK_DIR"
    else
        WORK_DIR="${execution_dir}/sparrow_desktop_${version_component}_${arch_component}_${APP_TYPE}_$$"
    fi

    local log_dir="${WORK_DIR}/logs"
    local official_dir="${WORK_DIR}/official"
    local built_dir="${WORK_DIR}/built"
    local results_file="${WORK_DIR}/COMPARISON_RESULTS.yaml"

    mkdir -p "$WORK_DIR" "$log_dir" "$official_dir" "$built_dir"
    cd "$WORK_DIR"

    echo "======================================================"
    echo "Sparrow Desktop v${APP_VERSION} — Windows ${APP_TYPE^^} Verification"
    echo "======================================================"
    echo ""

    if ! "$DOCKER_CMD" image inspect "${GH_HELPER_IMAGE}" >/dev/null 2>&1; then
        build_gh_helper
    fi

    local official_msi="${official_dir}/Sparrow-${APP_VERSION}.msi"
    local official_zip="${official_dir}/Sparrow-${APP_VERSION}.zip"

    if [[ "$APP_TYPE" == "msi" ]]; then
        echo "[INFO] Using provided MSI: $(basename "$BINARY_PATH")"
        cp "$BINARY_PATH" "$official_msi"
    else
        echo "[INFO] Using provided ZIP: $(basename "$BINARY_PATH")"
        cp "$BINARY_PATH" "$official_zip"
    fi

    local trigger_time
    trigger_time="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local -a _PRE_TRIGGER_IDS
    mapfile -t _PRE_TRIGGER_IDS < <(gh_c run list \
        --repo "${GH_REPO}" --workflow "${GH_WORKFLOW}" \
        --limit 20 --json databaseId --jq '.[].databaseId' 2>/dev/null || true)

    local jdk_workflow_version="${DEFAULT_JDK_VERSION%%+*}"
    echo "[INFO] Triggering GitHub Actions workflow on ${GH_REPO} (jdk_version=${jdk_workflow_version})..."
    if ! gh_c workflow run "${GH_WORKFLOW}" \
        --repo "${GH_REPO}" \
        --ref "${GH_WORKFLOW_REF}" \
        -f version="${APP_VERSION}" \
        -f jdk_version="${jdk_workflow_version}"; then
        ftbfs_die "Failed to trigger GitHub Actions workflow"
    fi

    echo "[INFO] Waiting for workflow run to appear..."
    local run_id=""
    local max_poll=30
    local poll_interval=10
    local -a _CANDIDATES
    local i cid is_new pid
    for i in $(seq 1 "$max_poll"); do
        sleep "$poll_interval"
        mapfile -t _CANDIDATES < <(gh_c run list \
            --repo "${GH_REPO}" \
            --workflow "${GH_WORKFLOW}" \
            --limit 10 \
            --json databaseId,createdAt \
            --jq "[.[] | select(.createdAt >= \"${trigger_time}\")] | .[].databaseId" \
            2>/dev/null || true)
        for cid in "${_CANDIDATES[@]:-}"; do
            [[ -z "$cid" || "$cid" == "null" ]] && continue
            is_new=true
            for pid in "${_PRE_TRIGGER_IDS[@]:-}"; do
                [[ "$cid" == "$pid" ]] && is_new=false && break
            done
            if [[ "$is_new" == "true" ]]; then
                run_id="$cid"
                break
            fi
        done
        [[ -n "$run_id" ]] && break
        echo "[INFO] Poll attempt ${i}/${max_poll}..."
    done

    if [[ -z "$run_id" || "$run_id" == "null" ]]; then
        ftbfs_die "Could not find workflow run after ${max_poll} attempts"
    fi
    echo "[INFO] Found workflow run ID: ${run_id}"

    echo "[INFO] Watching workflow run ${run_id}..."
    if ! gh_c run watch "${run_id}" --repo "${GH_REPO}" --exit-status; then
        gh_c run view "${run_id}" --repo "${GH_REPO}" --log \
            > "${log_dir}/gh-run-${run_id}.log" 2>&1 || true
        ftbfs_die "Workflow run ${run_id} failed"
    fi
    echo "[INFO] Workflow run ${run_id} completed."
    gh_c run view "${run_id}" --repo "${GH_REPO}" --log \
        > "${log_dir}/gh-run-${run_id}.log" 2>&1 || true

    local built_msi_dir="${built_dir}/msi"
    local built_zip_dir="${built_dir}/zip"
    mkdir -p "$built_msi_dir" "$built_zip_dir"

    if [[ "$APP_TYPE" == "msi" ]]; then
        echo "[INFO] Downloading built MSI artifact..."
        if ! gh_c run download "${run_id}" \
            --repo "${GH_REPO}" \
            --name "sparrow-${APP_VERSION}-win-msi" \
            --dir /work/built/msi; then
            ftbfs_die "Failed to download built MSI artifact"
        fi
    else
        echo "[INFO] Downloading built ZIP artifact..."
        if ! gh_c run download "${run_id}" \
            --repo "${GH_REPO}" \
            --name "sparrow-${APP_VERSION}-win-zip" \
            --dir /work/built/zip; then
            ftbfs_die "Failed to download built ZIP artifact"
        fi
    fi

    echo ""
    local zip_match=0
    local msi_match=0

    if [[ "$APP_TYPE" == "zip" ]]; then
        echo "[INFO] === ZIP Comparison ==="
        local built_zip_file
        built_zip_file=$(find "$built_zip_dir" -name "*.zip" | head -1)
        if [[ -z "$built_zip_file" ]]; then
            ftbfs_die "Built ZIP file not found in downloaded artifact"
        fi

        echo "[INFO] ZIP official SHA256: $(sha256sum "$official_zip" | cut -d' ' -f1)"
        echo "[INFO] ZIP built    SHA256: $(sha256sum "$built_zip_file" | cut -d' ' -f1)"

        local official_zip_extract="${WORK_DIR}/official-zip-extracted"
        local built_zip_extract="${WORK_DIR}/built-zip-extracted"
        mkdir -p "$official_zip_extract" "$built_zip_extract"
        unzip -q "$official_zip" -d "$official_zip_extract"
        unzip -q "$built_zip_file" -d "$built_zip_extract"

        local official_list="${WORK_DIR}/official-zip-files.txt"
        local built_list="${WORK_DIR}/built-zip-files.txt"
        (cd "$official_zip_extract" && find . -type f | sort) > "$official_list"
        (cd "$built_zip_extract" && find . -type f | sort) > "$built_list"

        local total_files match_files diff_files
        local zip_union="${WORK_DIR}/zip-union-files.txt"
        sort -u "$official_list" "$built_list" > "$zip_union"
        total_files=$(wc -l < "$zip_union" | tr -d ' ')
        echo "[INFO] ${total_files} files to verify (union of both extractions)"
        echo ""
        compare_extracted "$zip_union" "$official_zip_extract" "$built_zip_extract"
        total_files=$CMP_TOTAL; match_files=$CMP_OK; diff_files=$CMP_BAD
        rm -f "$zip_union"

        rm -f "$official_list" "$built_list"

        echo "[INFO] ZIP: ${match_files}/${total_files} files verified"
        if [[ "$diff_files" -eq 0 ]]; then
            zip_match=1
            echo "[INFO] ZIP: ALL FILES MATCH"
        else
            echo "[INFO] ZIP: MISMATCH — ${diff_files} difference(s)"
        fi

    elif [[ "$APP_TYPE" == "msi" ]]; then
        echo "[INFO] === MSI Comparison ==="
        local built_msi_file
        built_msi_file=$(find "$built_msi_dir" -name "*.msi" | head -1)
        if [[ -z "$built_msi_file" ]]; then
            ftbfs_die "Built MSI file not found in downloaded artifact"
        fi

        local official_msi_sha built_msi_sha
        official_msi_sha=$(sha256sum "$official_msi" | awk '{print $1}')
        built_msi_sha=$(sha256sum "$built_msi_file" | awk '{print $1}')

        if [[ "$official_msi_sha" == "$built_msi_sha" ]]; then
            msi_match=1
            echo "[INFO] MSI: SHA256 MATCH"
            echo "[INFO]   ${official_msi_sha}"
        else
            echo "[INFO] MSI: SHA256 MISMATCH"
            echo "[INFO]   Official: ${official_msi_sha}"
            echo "[INFO]   Built:    ${built_msi_sha}"
            echo "[INFO] Attempting 7z content extraction for deeper MSI comparison..."

            local official_msi_extract="${WORK_DIR}/official-msi-extracted"
            local built_msi_extract="${WORK_DIR}/built-msi-extracted"
            mkdir -p "$official_msi_extract" "$built_msi_extract"

            local built_msi_basename
            built_msi_basename=$(basename "$built_msi_file")

            "$DOCKER_CMD" run --rm \
                -v "${WORK_DIR}:/work" \
                "${GH_HELPER_IMAGE}" \
                bash -c "7z x /work/official/Sparrow-${APP_VERSION}.msi -o/work/official-msi-extracted -y >/dev/null 2>&1" \
                || ftbfs_die "7z extraction of the official MSI failed"
            "$DOCKER_CMD" run --rm \
                -v "${WORK_DIR}:/work" \
                "${GH_HELPER_IMAGE}" \
                bash -c "7z x /work/built/msi/${built_msi_basename} -o/work/built-msi-extracted -y >/dev/null 2>&1" \
                || ftbfs_die "7z extraction of the built MSI failed"

            local msi_file_list="${WORK_DIR}/official-msi-files.txt"
            local msi_built_list="${WORK_DIR}/built-msi-files.txt"
            local msi_union="${WORK_DIR}/msi-union-files.txt"
            (cd "$official_msi_extract" && find . -type f | sort) > "$msi_file_list"
            (cd "$built_msi_extract" && find . -type f | sort) > "$msi_built_list"
            [[ -s "$msi_file_list" && -s "$msi_built_list" ]] \
                || ftbfs_die "MSI extraction produced no files on one or both sides"
            local ds=0
            diff -q "$msi_file_list" "$msi_built_list" >/dev/null || ds=$?
            [[ "$ds" -le 1 ]] || die "diff status $ds" $EXIT_BUILD_FAILED
            if [[ "$ds" -eq 1 ]]; then
                echo "[INFO] MSI: stream sets differ (official vs built):"
                diff "$msi_file_list" "$msi_built_list" | sed 's/^/    /' || [ $? -eq 1 ]
            fi
            sort -u "$msi_file_list" "$msi_built_list" > "$msi_union"
            local msi_total msi_ok msi_bad
            msi_total=$(wc -l < "$msi_union" | tr -d ' ')
            echo "[INFO] ${msi_total} streams to verify (union of both extractions)"
            echo ""
            compare_extracted "$msi_union" "$official_msi_extract" "$built_msi_extract"
            msi_total=$CMP_TOTAL; msi_ok=$CMP_OK; msi_bad=$CMP_BAD
            echo "[INFO] MSI: ${msi_ok}/${msi_total} files verified"
            if [[ "$msi_bad" -eq 0 ]]; then
                msi_match=1
                echo "[INFO] MSI: PAYLOAD STREAM MATCH (MSI bytes differ; all ${msi_ok} streams identical)"
            else
                echo "[INFO] MSI: CONTENT MISMATCH — ${msi_bad} file(s) differ"
            fi
        fi
    fi

    echo ""
    local verdict notes=""
    if [[ "$APP_TYPE" == "zip" && "$zip_match" -eq 1 ]]; then
        verdict="reproducible"
    elif [[ "$APP_TYPE" == "msi" && "$msi_match" -eq 1 ]]; then
        verdict="reproducible"
    else
        verdict="not_reproducible"
        notes="${APP_TYPE^^} content differs"
    fi

    if [[ -n "$notes" ]]; then
        printf 'script_version: %s\nverdict: %s\nnotes: "%s"\n' \
            "$SCRIPT_VERSION" "$verdict" "$notes" > "$results_file"
    else
        printf 'script_version: %s\nverdict: %s\n' \
            "$SCRIPT_VERSION" "$verdict" > "$results_file"
    fi
    cp "$results_file" "$execution_dir/" 2>/dev/null || true

    display_results "$execution_dir"
}

display_results() {
    local exec_dir="$1"

    echo ""
    echo "======================================================"
    echo "RESULTS"
    echo "======================================================"
    cat COMPARISON_RESULTS.yaml
    echo ""
    echo "Workspace: $WORK_DIR/COMPARISON_RESULTS.yaml"
    if [[ "$exec_dir" != "$WORK_DIR" ]]; then
        echo "Build server location: $exec_dir/COMPARISON_RESULTS.yaml"
    fi
    echo ""

    local verdict
    verdict=$(grep "^verdict:" COMPARISON_RESULTS.yaml | cut -d' ' -f2)

    if [[ "$verdict" == "reproducible" ]]; then
        echo "✅ VERDICT: REPRODUCIBLE"
        echo "Exit code: $EXIT_SUCCESS"
        exit $EXIT_SUCCESS
    else
        echo "❌ VERDICT: NOT REPRODUCIBLE"
        echo "Exit code: $EXIT_BUILD_FAILED"
        exit $EXIT_BUILD_FAILED
    fi
}

main() {
    echo "sparrowdesktop_build.sh - Version: $SCRIPT_VERSION"
    echo ""

    parse_arguments "$@"
    detect_container_cmd

    if is_windows_arch "$APP_ARCH"; then
        build_and_verify_windows
    else
        build_and_verify
    fi
}

main "$@"
