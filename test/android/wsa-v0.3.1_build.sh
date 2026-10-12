#!/usr/bin/env bash
# ==============================================================================
# wsa-v0.3.1_build.sh - WalletScrutiny Android app reproducible build verification
# ==============================================================================
# Version:          v0.3.1
# Organization:     WalletScrutiny.com
# Last modified by: Dan-Opus-5.5 (WalletScrutiny agent)
# Last modified on: 2026-10-02
# Project:          https://gitlab.com/walletscrutiny/walletscrutinyandroid
# App ID:           com.walletscrutiny.ng_app
# ==============================================================================
#
# TECHNICAL DISCLAIMER: provided for reproducible-build verification and
# technical analysis only, without warranty of any kind. Review it before you
# run it.
# LEGAL DISCLAIMER: use only for lawful security research. The operator is
# responsible for compliance with applicable law.
#
# SCRIPT SUMMARY:
# 1. Hash itself, parse arguments (unknown ones are warned about, never fatal).
# 2. Create a new workspace for this run in the caller's directory.
# 3. Take the official APK from --binary (file or directory), or download the
#    GitLab release asset for --version and check it against the release's
#    published .sha256 file.
# 4. Read package, version, signer and ABIs from the APK; the ABIs pick the
#    product flavour (arm or x86) the release was built as.
# 5. Clone tag v<version> inside the digest-pinned image upstream's CI uses and
#    run upstream's own release command:
#    ./gradlew --no-daemon assembleRelease testArmReleaseUnitTest
#    (releases before flavours: testReleaseUnitTest). Without keystore.properties
#    Gradle signs with the repository's dummy key, as upstream's CI does.
# 6. apksigcopier transplants the official signature onto our build; the
#    verdict is reproducible only if that yields a validly signed APK. The
#    script also rebuilds the official file byte for byte from our build and
#    records the result, and lists every file that differs.
# 7. Print the results block, write COMPARISON_RESULTS.yaml next to the script,
#    and hand the workspace back to the caller.
#
# Requirements: podman or docker. No sudo, no smartphone.
# Exit codes: 0 reproducible, 1 not reproducible or failed to build, 2 invalid
# input.

set -uo pipefail

readonly SCRIPT_VERSION="v0.3.1"
readonly APP_ID="com.walletscrutiny.ng_app"
readonly REPOSITORY="https://gitlab.com/walletscrutiny/walletscrutinyandroid.git"
readonly RELEASE_API="https://gitlab.com/api/v4/projects/16054680/releases"
# The image upstream's .gitlab-ci.yml builds releases in, pinned by digest.
readonly BUILD_IMAGE="docker.io/mobiledevops/android-sdk-image:34.0.0-jdk17@sha256:e593140503932fc9f32ca5a8f01163713108f1649c5bb0f07bc9f9a968bdb8ec"
readonly TOOLS_IMAGE="docker.io/library/debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241"
# Certificate SHA-256 of dummy.keystore (committed upstream; the fallback signer).
readonly DUMMY_SIGNER="833df9af46ea76a857320b9573c511dbe4116dba0914a82bfc5cc428ee4ea16f"

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
EXEC_DIR="$(pwd -P)"
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
RUN_ID="$(date +%s)-$$"
SCRIPT_SHA256=""
RUNTIME=""
BINARY=""
REQ_VERSION=""
REQ_ARCH=""
REQ_TYPE=""
WORK_DIR=""
RELEASE_COMMIT=""
RESULT_WRITTEN="no"

log_info() { printf '[INFO] %s\n' "$*"; }
log_ok() { printf '[OK] %s\n' "$*"; }
log_warn() { printf '[WARNING] %s\n' "$*" >&2; }
log_fail() { printf '[FAIL] %s\n' "$*" >&2; }

sha256_of() {
    if [[ -f "$1" ]]; then sha256sum "$1" | awk '{print $1}'; else printf 'N/A\n'; fi
}

# COMPARISON_RESULTS.yaml: script_version, verdict, notes (one note per line).
write_yaml() {
    local verdict="$1" notes="$2"
    {
        printf 'script_version: %s\n' "$SCRIPT_VERSION"
        printf 'verdict: %s\n' "$verdict"
        if [[ -n "$notes" ]]; then
            printf 'notes: |\n'
            printf '%s\n' "$notes" | sed 's/^/  /'
        fi
    } > "$RESULTS_FILE"
    RESULT_WRITTEN="yes"
    log_info "COMPARISON_RESULTS.yaml written with verdict: ${verdict}"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") --version X.Y.Z [--arch arm|x86]
       $(basename "$0") --binary APK_OR_DIR [--version X.Y.Z]
  --version  release to verify (without the v); downloads the GitLab asset
  --binary   official APK (or a directory holding exactly one .apk); --apk is an alias
  --arch     flavour for --version downloads: arm (default, phones) or x86;
             with --binary the APK's own ABIs decide
  --type     accepted and ignored (single-APK app)
EOF
}

die_invalid() {
    log_fail "$1"
    write_yaml ftbfs "$1"
    usage >&2
    exit 2
}

ftbfs() {
    log_fail "$1"
    [[ -n "$WORK_DIR" ]] && log_fail "Evidence kept in: ${WORK_DIR}"
    write_yaml ftbfs "$1"
    exit 1
}

image_present() { "$RUNTIME" image inspect "$1" >/dev/null 2>&1; }

# Hand the workspace back to the caller, on success and on failure. Container
# root is the caller under rootless podman (0:0); under docker it is real root,
# so files are chowned to the caller's uid:gid.
cleanup() {
    local status=$?
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" && -n "$RUNTIME" ]] && image_present "$TOOLS_IMAGE"; then
        local owner="0:0"
        [[ "$RUNTIME" == "docker" ]] && owner="$(id -u):$(id -g)"
        "$RUNTIME" run --rm --user 0:0 --name "wsa-chown-${RUN_ID}" \
            --volume "${WORK_DIR}:/w" "$TOOLS_IMAGE" chown -R "$owner" /w >/dev/null 2>&1 || \
            log_warn "Could not hand ${WORK_DIR} back to the caller."
    fi
    if [[ "$RESULT_WRITTEN" == "no" && "$status" -ne 0 ]]; then
        write_yaml ftbfs "The script stopped before reaching a verdict (exit ${status})."
    fi
    exit "$status"
}

detect_runtime() {
    if command -v podman >/dev/null 2>&1; then
        RUNTIME="podman"
    elif command -v docker >/dev/null 2>&1; then
        RUNTIME="docker"
    else
        die_invalid "podman or docker is required."
    fi
    log_info "Container runtime: ${RUNTIME}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --binary|--apk)
                [[ $# -ge 2 && -n "$2" ]] || die_invalid "$1 requires a path."
                BINARY="$2"; shift 2 ;;
            --version)
                [[ $# -ge 2 && -n "$2" ]] || die_invalid "--version requires a value."
                REQ_VERSION="${2#v}"; shift 2 ;;
            --arch)
                [[ $# -ge 2 ]] || die_invalid "--arch requires a value."
                REQ_ARCH="$2"; shift 2 ;;
            --type)
                [[ $# -ge 2 ]] || die_invalid "--type requires a value."
                REQ_TYPE="$2"; shift 2 ;;
            --help|-h)
                usage; exit 0 ;;
            *)
                log_warn "Unknown argument ignored: $1"; shift ;;
        esac
    done
}

# arm / x86 from --arch; anything else is warned about and left to the APK.
normalize_arch() {
    case "${1,,}" in
        "") printf '' ;;
        arm|arm64|arm64-v8a|aarch64|armeabi-v7a|armv7) printf 'arm' ;;
        x86|x86_64|amd64|x86-64) printf 'x86' ;;
        *) log_warn "--arch $1 is not arm or x86; ignored."; printf '' ;;
    esac
}

resolve_binary() {
    [[ -e "$BINARY" ]] || die_invalid "Not found: ${BINARY}"
    if [[ -d "$BINARY" ]]; then
        local -a apks
        mapfile -t apks < <(find "$BINARY" -maxdepth 1 -type f -name '*.apk' | sort)
        [[ ${#apks[@]} -eq 1 ]] || \
            die_invalid "Expected exactly one .apk in ${BINARY}, found ${#apks[@]}."
        BINARY="${apks[0]}"
    fi
    BINARY="$(readlink -f "$BINARY")"
}

# Download the release APK for $1 (version) / $2 (flavour) into the workspace
# and check it against the release's own .sha256 asset. Writes official.apk,
# release-commit.txt and release-asset.txt.
download_release() {
    local version="$1" flavor="$2"
    "$RUNTIME" run --rm --user 0:0 --name "wsa-dl-${RUN_ID}" \
        -e "V=$version" -e "F=$flavor" -e "API=$RELEASE_API" \
        --volume "${WORK_DIR}:/out" "$TOOLS_IMAGE" sh -c '
        set -eu
        apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends ca-certificates curl jq >/dev/null
        curl -fsSL --retry 3 "$API/v$V" -o /out/release.json || { echo "Release v$V not found." >&2; exit 4; }
        url_of() { jq -r --arg n "$1" ".assets.links[] | select(.name == \$n) | (.direct_asset_url // .url)" /out/release.json | head -n1; }
        asset="walletscrutiny-v$V-$F.apk"
        apk_url="$(url_of "$asset")"
        if [ -z "$apk_url" ]; then
            asset="walletscrutiny-v$V.apk"   # releases before the arm/x86 flavours
            apk_url="$(url_of "$asset")"
        fi
        sum_url="$(url_of "$asset.sha256")"
        [ -n "$apk_url" ] && [ -n "$sum_url" ] || { echo "Release v$V has no $asset with a .sha256." >&2; exit 4; }
        for u in "$apk_url" "$sum_url"; do
            case "$u" in https://gitlab.com/*) ;; *) echo "Refusing non-GitLab URL: $u" >&2; exit 4 ;; esac
        done
        curl -fsSL --retry 3 "$apk_url" -o /out/official.apk
        curl -fsSL --retry 3 "$sum_url" -o /out/official.apk.sha256
        want="$(awk "NF{print tolower(\$1); exit}" /out/official.apk.sha256)"
        got="$(sha256sum /out/official.apk | cut -d" " -f1)"
        [ "$want" = "$got" ] || { echo "Checksum mismatch: release says $want, download is $got." >&2; exit 6; }
        jq -r ".commit.id" /out/release.json > /out/release-commit.txt
        echo "$asset" > /out/release-asset.txt
    '
}

# package / versionName / versionCode / signer / ABIs of APK $1.
apk_metadata() {
    "$RUNTIME" run --rm --name "wsa-meta-${RUN_ID}-$2" \
        --volume "$1:/a.apk:ro" "$BUILD_IMAGE" bash -c '
        set -euo pipefail
        SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/android-sdk}}"
        AAPT="$(ls -1 "$SDK"/build-tools/*/aapt | sort -V | tail -n1)"
        SIGNER="$(ls -1 "$SDK"/build-tools/*/apksigner | sort -V | tail -n1)"
        B="$("$AAPT" dump badging /a.apk)"
        printf "package=%s\n" "$(sed -n "s/^package: name=.\([^'\'']*\).*/\1/p" <<<"$B" | head -n1)"
        printf "version_name=%s\n" "$(sed -n "s/.*versionName=.\([^'\'']*\).*/\1/p" <<<"$B" | head -n1)"
        printf "version_code=%s\n" "$(sed -n "s/.*versionCode=.\([^'\'']*\).*/\1/p" <<<"$B" | head -n1)"
        printf "abis=%s\n" "$(sed -n "s/^native-code: //p" <<<"$B" | tr -d "'\''" | head -n1)"
        printf "signer=%s\n" "$("$SIGNER" verify --print-certs /a.apk | sed -n "s/^Signer #1 certificate SHA-256 digest: //p" | head -n1)"
    '
}

field() { sed -n "s/^$1=//p" <<<"$2" | head -n1; }

# Gradle's "What went wrong" block from build.log (at most 8 lines), for the
# ftbfs notes, so the reason travels with the verdict.
gradle_reason() {
    awk '/^\* What went wrong:/{f=1; next} /^\* Try:/{f=0} f && NF' "${WORK_DIR}/build.log" 2>/dev/null | head -n 8
}

# Clone tag v$1 and build flavour $2 exactly as upstream's CI does.
run_build() {
    local version="$1" flavor="$2"
    "$RUNTIME" run --rm --user 0:0 --name "wsa-build-${RUN_ID}" \
        -e "V=$version" -e "F=$flavor" -e "REPO=$REPOSITORY" \
        -e "GRADLE_USER_HOME=/ws/gradle-home" -e "GRADLE_OPTS=-Dorg.gradle.daemon=false" \
        --volume "${WORK_DIR}:/ws" --workdir /ws "$BUILD_IMAGE" bash -c '
        set -euo pipefail
        export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/android-sdk}}"
        git clone --quiet --depth 1 --branch "v$V" "$REPO" source
        cd source
        git rev-parse HEAD > /ws/commit.txt
        git cat-file -t "refs/tags/v$V" > /ws/tag-type.txt 2>/dev/null || echo unknown > /ws/tag-type.txt
        test ! -e keystore.properties || { echo "keystore.properties is in the tag" >&2; exit 3; }
        echo "sdk.dir=$ANDROID_HOME" > local.properties
        if grep -q "productFlavors" app/build.gradle; then
            TASK=testArmReleaseUnitTest; OUT="app/build/outputs/apk/$F/release/app-$F-release.apk"
        else
            TASK=testReleaseUnitTest; OUT="app/build/outputs/apk/release/app-release.apk"
        fi
        echo "./gradlew --no-daemon assembleRelease $TASK" > /ws/build-command.txt
        ./gradlew --no-daemon assembleRelease "$TASK" > /ws/build.log 2>&1 || { tail -n 40 /ws/build.log >&2; exit 5; }
        tail -n 5 /ws/build.log
        cp "$OUT" /ws/built.apk
    '
}

# Signature transplant + byte-for-byte reconstruction + full file diff.
compare_apks() {
    "$RUNTIME" run --rm --user 0:0 --name "wsa-cmp-${RUN_ID}" \
        --volume "${BINARY}:/official.apk:ro" --volume "${WORK_DIR}:/ws" \
        "$TOOLS_IMAGE" sh -c '
        set -u
        apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends \
            apksigcopier apksigner unzip diffutils >/dev/null || exit 3
        dpkg-query -W -f="\${Version}" apksigcopier > /ws/apksigcopier-version.txt
        apksigcopier compare /official.apk /ws/built.apk > /ws/apksigcopier.log 2>&1
        echo $? > /ws/compare.status
        rec=1
        if python3 -c "import apksigcopier as a; a.copy_apk(\"/ws/built.apk\", \"/ws/built-unsigned.apk\", exclude=a.exclude_meta)" >> /ws/apksigcopier.log 2>&1 &&
           apksigcopier copy /official.apk /ws/built-unsigned.apk /ws/reconstructed.apk >> /ws/apksigcopier.log 2>&1; then
            cmp -s /official.apk /ws/reconstructed.apk && rec=0
        fi
        echo "$rec" > /ws/reconstruct.status
        mkdir -p /tmp/o /tmp/b
        unzip -qq -o /official.apk -d /tmp/o; unzip -qq -o /ws/built.apk -d /tmp/b
        cd /tmp && diff -qr o b > /ws/diff-full.txt 2>&1
        # Differences outside the v1 signature files (official key vs dummy key).
        grep -vE "META-INF(/|: )([^/ ]+[.](SF|RSA|DSA|EC)|MANIFEST[.]MF)( |\$)" /ws/diff-full.txt > /ws/diff-unaccounted.txt
        exit 0
    '
}

print_results() {
    local pkg="$1" vname="$2" vcode="$3" signer="$4" hash="$5" commit="$6" verdict="$7" flavor="$8"
    local lines
    lines="$(wc -l < "${WORK_DIR}/diff-full.txt" 2>/dev/null || echo 0)"
    printf '\n===== Begin Results =====\n'
    printf 'appId:          %s\n' "$pkg"
    printf 'signer:         %s\n' "$signer"
    printf 'apkVersionName: %s\n' "$vname"
    printf 'apkVersionCode: %s\n' "$vcode"
    printf 'verdict:        %s\n' "$verdict"
    printf 'appHash:        %s\n' "$hash"
    printf 'commit:         %s\n' "$commit"
    printf 'flavor:         %s\n' "$flavor"
    printf 'scriptVersion:  %s\n' "$SCRIPT_VERSION"
    printf 'scriptHash:     %s\n' "$SCRIPT_SHA256"
    printf '\nDiff (unzipped official vs built, %s line(s); first 5 shown, full list in diff-full.txt):\n' "$lines"
    head -n 5 "${WORK_DIR}/diff-full.txt" 2>/dev/null
    printf '\nRevision, tag (and its signature):\n'
    printf 'Tag v%s (%s) -> %s; tag signature not checked (no signing key is published).\n' \
        "$vname" "$(cat "${WORK_DIR}/tag-type.txt" 2>/dev/null)" "$commit"
    printf '===== End Results =====\n\n'
    cat <<EOF
How to read this: the official APK is signed with the release key, ours with
the repository's dummy key. Differences outside the v1 signature files:
$(wc -l < "${WORK_DIR}/diff-unaccounted.txt" 2>/dev/null || echo ?) (list in diff-unaccounted.txt). The verdict does not rest on
the diff: it is reproducible only when apksigcopier can move the official
signature onto our build and the result verifies.
reconstructed.apk = our build carrying the official signature; byte-identical
to the official APK: $( [[ "$(cat "${WORK_DIR}/reconstruct.status" 2>/dev/null)" == 0 ]] && echo yes || echo no).
Workspace: ${WORK_DIR}
EOF
}

main() {
    SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
    log_info "Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
    log_info "         sha256: ${SCRIPT_SHA256}"
    trap cleanup EXIT

    [[ "$(id -u)" -ne 0 ]] || die_invalid "Do not run this script as root."
    parse_args "$@"
    detect_runtime
    [[ -n "$BINARY" || -n "$REQ_VERSION" ]] || die_invalid "Give --version or --binary."
    if [[ -n "$REQ_VERSION" && ! "$REQ_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die_invalid "Invalid --version ${REQ_VERSION} (expected X.Y.Z)."
    fi
    [[ -n "$REQ_TYPE" ]] && log_info "--type ${REQ_TYPE} ignored (single-APK app)."
    local want_flavor
    want_flavor="$(normalize_arch "$REQ_ARCH")"

    [[ -n "$BINARY" ]] && resolve_binary
    local ws_name="wsa_verification_${REQ_VERSION:-apk}_${RUN_ID}"
    WORK_DIR="${EXEC_DIR}/${ws_name}"
    mkdir "$WORK_DIR" || { WORK_DIR=""; die_invalid "Could not create a new workspace in ${EXEC_DIR}."; }
    log_info "Workspace: ${WORK_DIR}"

    if [[ -n "$BINARY" ]]; then
        log_info "Official APK supplied: ${BINARY}"
    else
        log_info "Downloading release v${REQ_VERSION} (${want_flavor:-arm}) from GitLab and checking its .sha256."
        download_release "$REQ_VERSION" "${want_flavor:-arm}" || \
            ftbfs "Could not obtain a checksum-verified APK for release v${REQ_VERSION}."
        BINARY="${WORK_DIR}/official.apk"
        RELEASE_COMMIT="$(cat "${WORK_DIR}/release-commit.txt")"
        log_ok "Downloaded $(cat "${WORK_DIR}/release-asset.txt"); hash matches the release's .sha256."
    fi

    log_info "Reading the official APK's metadata in the build image."
    local meta pkg vname vcode signer abis hash flavor
    meta="$(apk_metadata "$BINARY" official)" || ftbfs "Could not read the official APK's metadata."
    pkg="$(field package "$meta")"; vname="$(field version_name "$meta")"
    vcode="$(field version_code "$meta")"; signer="$(field signer "$meta")"
    abis="$(field abis "$meta")"; hash="$(sha256_of "$BINARY")"
    [[ "$pkg" == "$APP_ID" ]] || die_invalid "Package is ${pkg:-unknown}, expected ${APP_ID}."
    [[ "$vname" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die_invalid "Unexpected versionName: ${vname:-none}."
    if [[ -n "$REQ_VERSION" && "$REQ_VERSION" != "$vname" ]]; then
        log_warn "--version ${REQ_VERSION} but the APK is ${vname}; verifying ${vname}."
    fi
    case "$abis" in
        *x86*) flavor="x86" ;;
        *arm*) flavor="arm" ;;
        *) flavor="${want_flavor:-arm}" ;;
    esac
    if [[ -n "$want_flavor" && "$want_flavor" != "$flavor" ]]; then
        log_warn "--arch says ${want_flavor} but the APK's ABIs (${abis}) are ${flavor}; using ${flavor}."
    fi
    log_info "APK: ${pkg} ${vname} (${vcode}), ABIs: ${abis:-none}, flavour: ${flavor}"
    log_info "Official SHA-256: ${hash}"
    log_info "Official signer:  ${signer}"

    log_info "Building tag v${vname} in ${BUILD_IMAGE%%@*} (digest-pinned); this takes a few minutes."
    if ! run_build "$vname" "$flavor"; then
        local reason nl=$'\n'
        reason="$(gradle_reason)"
        ftbfs "Failed to build tag v${vname} (flavour ${flavor}) from source.${reason:+${nl}Gradle: }${reason}"
    fi
    local commit
    commit="$(cat "${WORK_DIR}/commit.txt")"
    log_ok "Built commit ${commit} with: $(cat "${WORK_DIR}/build-command.txt")"
    if [[ -n "$RELEASE_COMMIT" && "$RELEASE_COMMIT" != "$commit" ]]; then
        ftbfs "Tag v${vname} is ${commit}, but the GitLab release names ${RELEASE_COMMIT}."
    fi

    local bmeta
    bmeta="$(apk_metadata "${WORK_DIR}/built.apk" built)" || ftbfs "Could not read the built APK's metadata."
    if [[ "$(field package "$bmeta")" != "$pkg" || "$(field version_name "$bmeta")" != "$vname" ||
          "$(field version_code "$bmeta")" != "$vcode" ]]; then
        ftbfs "The built APK's package or version differs from the official APK."
    fi
    [[ "$(field signer "$bmeta")" == "$DUMMY_SIGNER" ]] || \
        ftbfs "The built APK is not signed with the repository's dummy key."
    log_ok "Built APK $(sha256_of "${WORK_DIR}/built.apk"), dummy signer as expected."

    log_info "Comparing with apksigcopier (signature transplant) and unzipped diff."
    compare_apks || ftbfs "The comparison container failed."
    local cstat rstat verdict notes status
    cstat="$(cat "${WORK_DIR}/compare.status" 2>/dev/null || echo 1)"
    rstat="$(cat "${WORK_DIR}/reconstruct.status" 2>/dev/null || echo 1)"
    local tool="apksigcopier $(cat "${WORK_DIR}/apksigcopier-version.txt" 2>/dev/null)"
    if [[ "$cstat" == 0 ]]; then
        verdict="reproducible"; status=0
        notes="${tool}: the official signature, moved onto our build of tag v${vname} (${commit}, flavour ${flavor}), verifies, so every signed byte matches."
        [[ "$rstat" == 0 ]] && notes+=$'\n'"Our build carrying that signature is byte-for-byte identical to the official APK ${hash}."
        notes+=$'\n'"$(wc -l < "${WORK_DIR}/diff-full.txt") file difference(s) between the unzipped APKs, $(wc -l < "${WORK_DIR}/diff-unaccounted.txt") outside the v1 signature files (META-INF *.SF/*.RSA/*.DSA/*.EC, MANIFEST.MF)."
    else
        verdict="not_reproducible"; status=1
        notes="${tool}: the official signature does not verify on our build of tag v${vname} (${commit}, flavour ${flavor})."
        notes+=$'\n'"$(wc -l < "${WORK_DIR}/diff-full.txt") file difference(s) between the unzipped APKs, $(wc -l < "${WORK_DIR}/diff-unaccounted.txt") outside the v1 signature files; see diff-full.txt."
    fi
    notes+=$'\n'"Built in ${BUILD_IMAGE#docker.io/} with: $(cat "${WORK_DIR}/build-command.txt")."
    write_yaml "$verdict" "$notes"
    print_results "$pkg" "$vname" "$vcode" "$signer" "$hash" "$commit" "$verdict" "$flavor"
    if [[ "$status" -eq 0 ]]; then log_ok "Verdict: reproducible"; else log_warn "Verdict: not_reproducible"; fi
    echo "Exit code: ${status}"
    exit "$status"
}

main "$@"
