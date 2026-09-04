#!/usr/bin/env bash
# ==============================================================================
# walletscrutinyandroid_build.sh - WalletScrutiny Android Build Verification
# ==============================================================================
# Version:       v0.2.0
# Organization:  WalletScrutiny.com
# Last modified by: Codex wallet-build-forensics
# Last modified on: 2026-09-04
# Project:       https://gitlab.com/walletscrutiny/walletscrutinyandroid
# License:       MIT
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for reproducible-build verification and technical
# analysis. Review it before running it. No warranty is provided.
#
# LEGAL DISCLAIMER:
# Use this script only for lawful security research. The operator is responsible
# for compliance with applicable law.
#
# SCRIPT SUMMARY:
# - Accepts an official standalone APK or downloads an exact GitLab release.
# - Verifies downloaded APKs against the release checksum asset.
# - Clones the matching source tag inside the upstream digest-pinned CI image.
# - Builds and tests the release with the committed dummy signing key.
# - Uses apksigcopier to compare the signed APKs without requiring the release key.
# - Preserves build/comparison evidence and emits COMPARISON_RESULTS.yaml.

set -uo pipefail

readonly SCRIPT_VERSION="v0.2.0"
readonly APP_ID="com.walletscrutiny.ng_app"
readonly REPOSITORY="https://gitlab.com/walletscrutiny/walletscrutinyandroid.git"
readonly BUILD_IMAGE="docker.io/mobiledevops/android-sdk-image:34.0.0-jdk17@sha256:e593140503932fc9f32ca5a8f01163713108f1649c5bb0f07bc9f9a968bdb8ec"
readonly TOOLS_IMAGE="docker.io/library/debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241"
readonly RELEASE_SIGNER_1_99_8="615bf6cba1c73c90b0515e74f871224ba4e7ed6d6355b9d5ee4a5d1c9d28cfb2"
readonly RELEASE_SHA256_1_99_8="652817d8a929fd318f623a56f5f47a7bc9d5f0885a2ea456088389fb1359b462"
readonly COMMIT_1_99_8="d9b57dfa8f8fee5f3c943b8c1c62daf47db1fe92"
readonly DUMMY_SIGNER="833df9af46ea76a857320b9573c511dbe4116dba0914a82bfc5cc428ee4ea16f"

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
SCRIPT_SHA256=""
RUNTIME=""
BINARY=""
REQUESTED_VERSION=""
REQUESTED_ARCH=""
REQUESTED_TYPE=""
WORK_DIR=""
DOWNLOADED_RELEASE="no"

log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARNING] %s\n' "$*" >&2; }
log_fail() { printf '[FAIL] %s\n' "$*" >&2; }

sha256_of() {
    if [[ -f "$1" ]]; then
        sha256sum "$1" | awk '{print $1}'
    else
        printf 'N/A\n'
    fi
}

write_yaml() {
    local verdict="$1"
    local notes="$2"
    {
        printf 'script_version: %s\n' "$SCRIPT_VERSION"
        printf 'verdict: %s\n' "$verdict"
        if [[ -n "$notes" ]]; then
            printf 'notes: |\n'
            printf '  %s\n' "$notes"
        fi
    } > "$RESULTS_FILE"
}

usage() {
    printf 'Usage: %s --version VERSION [--arch VALUE] [--type VALUE]\n' "$(basename "$0")"
    printf '       %s --binary APK [--version VERSION]\n' "$(basename "$0")"
    printf '       %s --apk APK\n' "$(basename "$0")"
}

die_invalid() {
    log_fail "$1"
    write_yaml ftbfs "$1"
    usage >&2
    exit 2
}

detect_runtime() {
    if command -v podman >/dev/null 2>&1; then
        RUNTIME="podman"
    elif command -v docker >/dev/null 2>&1; then
        RUNTIME="docker"
    else
        die_invalid "podman or docker is required."
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --binary|--apk)
                [[ $# -ge 2 ]] || die_invalid "$1 requires a file path."
                BINARY="$2"
                shift 2
                ;;
            --version)
                [[ $# -ge 2 ]] || die_invalid "--version requires a value."
                REQUESTED_VERSION="${2#v}"
                shift 2
                ;;
            --arch)
                [[ $# -ge 2 ]] || die_invalid "--arch requires a value."
                REQUESTED_ARCH="$2"
                shift 2
                ;;
            --type)
                [[ $# -ge 2 ]] || die_invalid "--type requires a value."
                REQUESTED_TYPE="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_warn "Unknown argument: $1 (ignored)"
                shift
                ;;
        esac
    done
}

container_user_args() {
    if [[ "$RUNTIME" == "podman" ]]; then
        printf '%s\n' '--userns=keep-id' '-e' 'HOME=/tmp'
    else
        printf '%s\n' '--user' "$(id -u):$(id -g)" '-e' 'HOME=/tmp'
    fi
}

download_release_apk() {
    local version="$1"
    local target="$2"
    local chown_output="no"
    [[ "$RUNTIME" == "docker" ]] && chown_output="yes"

    "$RUNTIME" run --rm --platform linux/amd64 \
        -e "WS_VERSION=$version" \
        -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" -e "CHOWN_OUTPUT=$chown_output" \
        --volume "${WORK_DIR}:/output" \
        "$TOOLS_IMAGE" sh -lc '
            set -eu
            apt-get update -qq || exit 3
            apt-get install -y -qq --no-install-recommends ca-certificates curl jq >/dev/null || exit 3

            release_api="https://gitlab.com/api/v4/projects/walletscrutiny%2Fwalletscrutinyandroid/releases/v${WS_VERSION}"
            expected_apk="walletscrutiny-v${WS_VERSION}.apk"
            expected_checksum="${expected_apk}.sha256"

            if ! curl -fsSL --retry 2 "$release_api" -o /output/release.json; then
                printf "Release v%s is unavailable at %s\n" "$WS_VERSION" "$release_api" >&2
                exit 4
            fi

            apk_url="$(jq -er --arg name "$expected_apk" \
                ".assets.links | map(select(.name == \$name)) | .[0] | (.direct_asset_url // .url)" \
                /output/release.json)" || {
                printf "Release v%s has no %s asset.\n" "$WS_VERSION" "$expected_apk" >&2
                exit 4
            }
            checksum_url="$(jq -er --arg name "$expected_checksum" \
                ".assets.links | map(select(.name == \$name)) | .[0] | (.direct_asset_url // .url)" \
                /output/release.json)" || {
                printf "Release v%s has no %s asset.\n" "$WS_VERSION" "$expected_checksum" >&2
                exit 4
            }
            release_commit="$(jq -er --arg tag "v${WS_VERSION}" \
                "select(.tag_name == \$tag) | .commit.id" /output/release.json)" || {
                printf "Release metadata does not identify tag v%s and its commit.\n" "$WS_VERSION" >&2
                exit 4
            }

            case "$apk_url" in https://gitlab.com/*) ;; *) printf "Refusing non-GitLab APK URL: %s\n" "$apk_url" >&2; exit 4 ;; esac
            case "$checksum_url" in https://gitlab.com/*) ;; *) printf "Refusing non-GitLab checksum URL: %s\n" "$checksum_url" >&2; exit 4 ;; esac

            curl -fsSL --retry 2 "$apk_url" -o /output/official.apk || {
                printf "APK asset for release v%s is unavailable.\n" "$WS_VERSION" >&2
                exit 5
            }
            curl -fsSL --retry 2 "$checksum_url" -o /output/official.apk.sha256 || {
                printf "Checksum asset for release v%s is unavailable.\n" "$WS_VERSION" >&2
                exit 5
            }

            expected_sha="$(awk "NF { print \$1; exit }" /output/official.apk.sha256)"
            actual_sha="$(sha256sum /output/official.apk | awk "{ print \$1 }")"
            printf "%s\n" "$expected_sha" | grep -Eq "^[0-9a-fA-F]{64}$" || {
                printf "Release checksum asset is malformed.\n" >&2
                exit 6
            }
            if [ "$(printf "%s" "$expected_sha" | tr "A-F" "a-f")" != "$actual_sha" ]; then
                printf "Downloaded APK checksum mismatch: expected %s, got %s.\n" "$expected_sha" "$actual_sha" >&2
                exit 6
            fi

            printf "%s\n" "$apk_url" > /output/release-apk-url.txt
            printf "%s\n" "$release_commit" > /output/release-commit.txt
            if [ "$CHOWN_OUTPUT" = "yes" ]; then
                chown "$HOST_UID:$HOST_GID" /output/release.json /output/official.apk \
                    /output/official.apk.sha256 /output/release-apk-url.txt \
                    /output/release-commit.txt
            fi
        '

    [[ -s "$target" ]]
}

metadata_from_apk() {
    local apk="$1"
    "$RUNTIME" run --rm --platform linux/amd64 \
        --volume "${apk}:/official.apk:ro" \
        "$BUILD_IMAGE" bash -lc '
            set -euo pipefail
            export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/android-sdk}}"
            AAPT="$(find "$ANDROID_HOME/build-tools" -type f -name aapt | sort -V | tail -n1)"
            APKSIGNER="$(find "$ANDROID_HOME/build-tools" -type f -name apksigner | sort -V | tail -n1)"
            BADGING="$("$AAPT" dump badging /official.apk)"
            printf "package=%s\n" "$(printf "%s\n" "$BADGING" | sed -n "s/^package: name='\''\([^'\'']*\)'\''.*/\1/p" | head -n1)"
            printf "version_name=%s\n" "$(printf "%s\n" "$BADGING" | sed -n "s/^package:.*versionName='\''\([^'\'']*\)'\''.*/\1/p" | head -n1)"
            printf "version_code=%s\n" "$(printf "%s\n" "$BADGING" | sed -n "s/^package:.*versionCode='\''\([^'\'']*\)'\''.*/\1/p" | head -n1)"
            printf "signer=%s\n" "$("$APKSIGNER" verify --print-certs /official.apk | sed -n "s/^Signer #1 certificate SHA-256 digest: //p" | head -n1)"
        '
}

run_build() {
    local version="$1"
    local -a user_args
    mapfile -t user_args < <(container_user_args)

    "$RUNTIME" run --rm --platform linux/amd64 \
        "${user_args[@]}" \
        -e "WS_VERSION=$version" \
        -e "WS_REPOSITORY=$REPOSITORY" \
        --volume "${WORK_DIR}:/workspace" \
        --workdir /workspace \
        "$BUILD_IMAGE" bash -lc '
            set -euo pipefail
            export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/android-sdk}}"
            export GRADLE_USER_HOME=/workspace/gradle-home
            git clone --depth 1 --branch "v${WS_VERSION}" "$WS_REPOSITORY" source
            cd source
            COMMIT="$(git rev-parse HEAD)"
            printf "%s\n" "$COMMIT" > /workspace/commit.txt
            TAG_TYPE="$(git cat-file -t "v${WS_VERSION}")"
            printf "%s\n" "$TAG_TYPE" > /workspace/tag-type.txt
            if git verify-tag "v${WS_VERSION}" > /workspace/tag-verification.log 2>&1; then
                printf "valid\n" > /workspace/tag-signature.txt
            else
                printf "unsigned-or-invalid\n" > /workspace/tag-signature.txt
            fi
            if git verify-commit HEAD > /workspace/commit-verification.log 2>&1; then
                printf "valid\n" > /workspace/commit-signature.txt
            else
                printf "unsigned-or-invalid\n" > /workspace/commit-signature.txt
            fi
            test ! -e keystore.properties
            printf "sdk.dir=%s\n" "$ANDROID_HOME" > local.properties
            ./gradlew --no-daemon --no-build-cache clean assembleRelease testReleaseUnitTest 2>&1 \
                | tee /workspace/build.log
            cp app/build/outputs/apk/release/app-release.apk /workspace/built.apk
        '
}

compare_apks() {
    local official="$1"
    local built="$2"
    local chown_output="no"
    [[ "$RUNTIME" == "docker" ]] && chown_output="yes"

    "$RUNTIME" run --rm --platform linux/amd64 \
        -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" -e "CHOWN_OUTPUT=$chown_output" \
        --volume "${official}:/official.apk:ro" \
        --volume "${built}:/built.apk:ro" \
        --volume "${WORK_DIR}:/output" \
        "$TOOLS_IMAGE" sh -lc '
            set -u
            apt-get update -qq || exit 3
            apt-get install -y -qq --no-install-recommends apksigcopier apksigner unzip >/dev/null || exit 3

            apksigcopier compare /official.apk /built.apk > /output/apksigcopier.log 2>&1
            compare_status=$?

            mkdir -p /tmp/official /tmp/built
            unzip -q /official.apk -d /tmp/official
            unzip -q /built.apk -d /tmp/built
            diff -qr /tmp/official /tmp/built > /output/diff-full.log 2>&1

            reconstruct_status=1
            if [ "$compare_status" -eq 0 ]; then
                APKSIGCOPIER_EXCLUDE_ALL_META=1 apksigcopier copy \
                    /official.apk /built.apk /output/reconstructed.apk \
                    > /output/reconstruction.log 2>&1
                reconstruct_status=$?
                if [ "$reconstruct_status" -eq 0 ]; then
                    apksigner verify --verbose /output/reconstructed.apk \
                        >> /output/reconstruction.log 2>&1 || reconstruct_status=$?
                    cmp -s /official.apk /output/reconstructed.apk || reconstruct_status=$?
                fi
            fi

            printf "%s\n" "$compare_status" > /output/apksigcopier.status
            printf "%s\n" "$reconstruct_status" > /output/reconstruction.status
            if [ "$CHOWN_OUTPUT" = "yes" ]; then
                chown "$HOST_UID:$HOST_GID" /output/apksigcopier.log \
                    /output/diff-full.log /output/apksigcopier.status \
                    /output/reconstruction.status /output/reconstruction.log \
                    /output/reconstructed.apk 2>/dev/null || true
            fi
            exit 0
        '
}

print_results() {
    local package_name="$1"
    local version_name="$2"
    local version_code="$3"
    local signer="$4"
    local official_hash="$5"
    local commit="$6"
    local verdict="$7"
    local display_verdict="$verdict"
    [[ "$verdict" == "not_reproducible" ]] && display_verdict="differences found"

    printf '\n===== Begin Results =====\n'
    printf 'appId:          %s\n' "$package_name"
    printf 'signer:         %s\n' "$signer"
    printf 'apkVersionName: %s\n' "$version_name"
    printf 'apkVersionCode: %s\n' "$version_code"
    printf 'verdict:        %s\n' "$display_verdict"
    printf 'appHash:        %s\n' "$official_hash"
    printf 'commit:         %s\n' "$commit"
    printf 'scriptVersion:  %s\n' "$SCRIPT_VERSION"
    printf 'scriptHash:     %s\n' "$SCRIPT_SHA256"
    printf '\nDiff (first 5 lines; full output in %s):\n' "$WORK_DIR/diff-full.log"
    head -n 5 "$WORK_DIR/diff-full.log" 2>/dev/null || true
    local diff_lines
    diff_lines="$(wc -l < "$WORK_DIR/diff-full.log" 2>/dev/null || printf '0')"
    [[ "$diff_lines" -gt 5 ]] && printf '... (%s lines total)\n' "$diff_lines"
    printf '\nRevision, tag (and its signature):\n'
    printf 'v%s -> %s\n' "$version_name" "$commit"
    printf '\nSignature Summary:\n'
    printf 'Tag type: %s\n' "$(cat "$WORK_DIR/tag-type.txt")"
    if [[ "$(cat "$WORK_DIR/tag-signature.txt")" == "valid" ]]; then
        printf '[OK] Good signature on annotated tag\n'
    else
        printf '[WARNING] No valid signature found on tag\n'
    fi
    if [[ "$(cat "$WORK_DIR/commit-signature.txt")" == "valid" ]]; then
        printf '[OK] Good signature on commit\n'
    else
        printf '[WARNING] No valid signature found on commit\n'
    fi
    printf '===== End Results =====\n'
    printf '\nEvidence directory: %s\n' "$WORK_DIR"
    printf 'Run diffoscope "%s" "%s" for deeper failure analysis.\n' "$BINARY" "$WORK_DIR/built.apk"
}

main() {
    SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
    log_info "Script:  $(basename "$SCRIPT_PATH") $SCRIPT_VERSION"
    log_info "         sha256: $SCRIPT_SHA256"

    [[ "$(id -u)" -ne 0 ]] || die_invalid "Do not run this script as root."
    parse_args "$@"
    detect_runtime
    [[ -n "$BINARY" || -n "$REQUESTED_VERSION" ]] || \
        die_invalid "Provide an APK with --binary/--apk or request a release with --version."
    if [[ -n "$REQUESTED_VERSION" && ! "$REQUESTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die_invalid "Invalid release version: $REQUESTED_VERSION (expected x.y.z)."
    fi
    if [[ -z "$BINARY" ]]; then
        local requested_safe_version
        requested_safe_version="${REQUESTED_VERSION//[^A-Za-z0-9._-]/_}"
        WORK_DIR="$(pwd)/walletscrutinyandroid-work_${requested_safe_version}_${$}"
        mkdir -p "$WORK_DIR"
        log_info "Downloading GitLab release v$REQUESTED_VERSION and its published checksum."
        if ! download_release_apk "$REQUESTED_VERSION" "$WORK_DIR/official.apk"; then
            write_yaml ftbfs "Release v$REQUESTED_VERSION or its required APK/checksum asset is unavailable or invalid."
            log_fail "Could not obtain a verified APK for release v$REQUESTED_VERSION."
            log_fail "Evidence: $WORK_DIR"
            exit 1
        fi
        BINARY="$WORK_DIR/official.apk"
        DOWNLOADED_RELEASE="yes"
        log_info "Downloaded release APK from $(cat "$WORK_DIR/release-apk-url.txt")"
    fi
    [[ -f "$BINARY" ]] || die_invalid "APK not found: $BINARY"
    BINARY="$(readlink -f "$BINARY")"

    log_info "Reading package, version and signer from the official APK in $BUILD_IMAGE."
    local metadata
    if ! metadata="$(metadata_from_apk "$BINARY")"; then
        write_yaml ftbfs "Could not read APK metadata with the pinned Android toolchain."
        log_fail "Could not read APK metadata."
        exit 1
    fi

    local package_name version_name version_code signer official_hash
    package_name="$(printf '%s\n' "$metadata" | sed -n 's/^package=//p')"
    version_name="$(printf '%s\n' "$metadata" | sed -n 's/^version_name=//p')"
    version_code="$(printf '%s\n' "$metadata" | sed -n 's/^version_code=//p')"
    signer="$(printf '%s\n' "$metadata" | sed -n 's/^signer=//p')"
    official_hash="$(sha256_of "$BINARY")"

    [[ "$package_name" == "$APP_ID" ]] || die_invalid "Package mismatch: expected $APP_ID, got $package_name."
    [[ -n "$version_name" && -n "$version_code" ]] || die_invalid "The APK has incomplete version metadata."
    if [[ -n "$REQUESTED_VERSION" && "$REQUESTED_VERSION" != "$version_name" ]]; then
        die_invalid "Version mismatch: --version $REQUESTED_VERSION, APK $version_name."
    fi
    if [[ "$version_name" == "1.99.8" && "$signer" != "$RELEASE_SIGNER_1_99_8" ]]; then
        die_invalid "Signer mismatch for official v1.99.8: $signer."
    fi
    if [[ "$version_name" == "1.99.8" && "$official_hash" != "$RELEASE_SHA256_1_99_8" ]]; then
        die_invalid "SHA-256 mismatch for official v1.99.8: $official_hash."
    fi

    local safe_version
    safe_version="${version_name//[^A-Za-z0-9._-]/_}"
    if [[ -z "$WORK_DIR" ]]; then
        WORK_DIR="$(pwd)/walletscrutinyandroid-work_${safe_version}_${$}"
        mkdir -p "$WORK_DIR"
    fi
    log_info "Official APK: $BINARY"
    log_info "Official SHA-256: $official_hash"
    log_info "Package/version: $package_name $version_name ($version_code)"
    log_info "Release signer: $signer"
    log_info "Building tag v$version_name in the exact CI image; evidence goes to $WORK_DIR."

    if ! run_build "$version_name"; then
        write_yaml ftbfs "The source build or unit tests failed; see the preserved build log."
        log_fail "Failed to build from source. Evidence: $WORK_DIR"
        exit 1
    fi

    local commit built_metadata built_package built_version_name built_version_code built_signer
    commit="$(cat "$WORK_DIR/commit.txt")"
    if [[ "$DOWNLOADED_RELEASE" == "yes" && "$commit" != "$(cat "$WORK_DIR/release-commit.txt")" ]]; then
        write_yaml ftbfs "The source tag resolved to a different commit than the GitLab release metadata."
        log_fail "Release/source commit mismatch: release $(cat "$WORK_DIR/release-commit.txt"), tag $commit"
        exit 1
    fi
    if [[ "$version_name" == "1.99.8" && "$commit" != "$COMMIT_1_99_8" ]]; then
        write_yaml ftbfs "Tag v1.99.8 resolved to an unexpected source commit."
        log_fail "Unexpected source commit: $commit"
        exit 1
    fi
    if ! built_metadata="$(metadata_from_apk "$WORK_DIR/built.apk")"; then
        write_yaml ftbfs "The rebuilt APK could not be inspected."
        log_fail "Could not inspect the rebuilt APK."
        exit 1
    fi
    built_package="$(printf '%s\n' "$built_metadata" | sed -n 's/^package=//p')"
    built_version_name="$(printf '%s\n' "$built_metadata" | sed -n 's/^version_name=//p')"
    built_version_code="$(printf '%s\n' "$built_metadata" | sed -n 's/^version_code=//p')"
    built_signer="$(printf '%s\n' "$built_metadata" | sed -n 's/^signer=//p')"
    if [[ "$built_package" != "$package_name" || "$built_version_name" != "$version_name" || "$built_version_code" != "$version_code" ]]; then
        write_yaml ftbfs "The rebuilt APK package or version does not match the official APK."
        log_fail "Built identity mismatch: $built_package $built_version_name ($built_version_code)"
        exit 1
    fi
    if [[ "$built_signer" != "$DUMMY_SIGNER" ]]; then
        write_yaml ftbfs "The local APK was not signed with the repository dummy key."
        log_fail "Unexpected local signer: $built_signer"
        exit 1
    fi

    log_info "Built commit: $commit"
    log_info "Built APK SHA-256: $(sha256_of "$WORK_DIR/built.apk")"
    log_info "Built APK has the expected dummy signer: $built_signer"
    log_info "Comparing official and built APKs with apksigcopier 1.1.1."

    if ! compare_apks "$BINARY" "$WORK_DIR/built.apk"; then
        write_yaml ftbfs "The comparison tool container failed."
        log_fail "Comparison tooling failed."
        exit 1
    fi

    local compare_status reconstruction_status verdict notes exit_status
    compare_status="$(cat "$WORK_DIR/apksigcopier.status")"
    reconstruction_status="$(cat "$WORK_DIR/reconstruction.status")"
    if [[ "$compare_status" == "0" && "$reconstruction_status" == "0" ]]; then
        verdict="reproducible"
        notes="apksigcopier 1.1.1 verified the v1/v2 signing-normalized APK, and signature transplantation reconstructed the official APK byte-for-byte."
        exit_status=0
    elif [[ "$compare_status" == "0" ]]; then
        verdict="reproducible"
        notes="apksigcopier 1.1.1 verified the v1/v2 signing-normalized APK; exact reconstruction was unavailable as a secondary diagnostic."
        exit_status=0
    else
        verdict="not_reproducible"
        notes="The rebuilt APK did not accept the official APK signature; inspect apksigcopier.log and diff-full.log."
        exit_status=1
    fi

    write_yaml "$verdict" "$notes"
    print_results "$package_name" "$version_name" "$version_code" "$signer" \
        "$official_hash" "$commit" "$verdict"
    exit "$exit_status"
}

main "$@"
