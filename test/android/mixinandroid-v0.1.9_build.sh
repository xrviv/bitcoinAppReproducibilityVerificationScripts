#!/usr/bin/env bash
# mixinandroid_build.sh - Mixin Messenger (one.mixin.messenger) Android Verification
# Version: v0.1.4
# Organization: WalletScrutiny.com
# Last modified by: Bob (WalletScrutiny agent), for Daniel Garcia
# Date last modified: 2026-09-14
# Project: https://github.com/MixinNetwork/android-app
# Host deps: docker or podman; curl only when downloading the official APK.
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes
# only. No warranty is provided regarding security, functionality, or fitness for any particular
# purpose. Users assume all risks associated with running this script and analyzing the software.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
#
# SCRIPT SUMMARY:
# - Reads versionName, versionCode, signer and the Firebase/API-key values out of the official
#   artifact (GitHub release APK or a Play split set) with aapt2/apksigner inside the pinned image.
# - Clones the release tag inside the image, injects the recovered build inputs, builds
#   :app:bundle<Flavor>Release with Gradle and renders it with bundletool in the same mode as the
#   official artifact (universal or split set).
# - Unpacks both sides and diffs them; signing files and the Play SourceStamp are excluded,
#   resources.arsc and AndroidManifest.xml are judged on their apktool-decoded form (WS #574).
# - Prints the results block, writes COMPARISON_RESULTS.yaml next to the script.
#
# Five things to know:
#  1. Upstream ships verify-mixin-apk.sh (needs adb + a phone). This script reuses
#     its pins: the mingc/android-build-box image digest, bundletool 1.18.3 and the
#     release tag, but compares files instead of a device.
#  2. Every official artifact is a bundletool rendering of the release AAB: the
#     GitHub asset is a universal APK, Play ships base + ABI splits. So the build
#     target is :app:bundle<Flavor>Release and bundletool renders the same shape.
#  3. Two flavors exist, googlePlay and otherChannel; they differ only in
#     BuildConfig.IS_GOOGLE_PLAY. Default is googlePlay (the GitHub asset carries a
#     Google SourceStamp, so it came out of Play). --flavor overrides.
#  4. The repo does not contain google-services.json nor the API keys the secrets
#     plugin bakes into the manifest and BuildConfig (blank " " defaults). Both are
#     rebuilt from values the official APK itself carries (Firebase string resources,
#     manifest meta-data). Values that only live in dex cannot be recovered that way
#     and will show up as dex differences.
#  5. Bugsnag mapping-upload tasks are chained onto every release bundle task and
#     need an account; they are excluded (-x), which does not change the AAB.

SCRIPT_VERSION="v0.1.9"
SCRIPT_NAME="mixinandroid_build.sh"
SCRIPT_PATH="$(readlink -f "$0")"
if [[ -f "$SCRIPT_PATH" ]]; then
    SCRIPT_SHA256="$(sha256sum "$SCRIPT_PATH" | awk '{print $1}')"
else
    SCRIPT_SHA256="N/A"
fi
printf '%s %s sha256:%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$SCRIPT_SHA256"

set -uo pipefail   # no -e: diff/cmp return 1 on differences

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ID="one.mixin.messenger"
REPO_URL="https://github.com/MixinNetwork/android-app"
# Pins copied from upstream verify-mixin-apk.sh at v6.2.2 (PR #6546 / #6610).
BUILD_IMAGE="docker.io/mingc/android-build-box@sha256:de4a27cbc13a22563f82e93fde01c7366a5cda2c8ff113353d3e24e75c9ae8b6"
BUNDLETOOL_VERSION="1.18.3"
BUNDLETOOL_SHA256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
APKTOOL_URL="https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

NC="\033[0m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BLUE="\033[1;34m"
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

banner() {
    echo ""; echo ""
    echo "############################################################"
    echo "##"; printf "##  %s\n" "$*"; echo "##"
    echo "############################################################"
}
section() {
    echo ""; echo "------------------------------------------------------------"
    printf "  %s\n" "$*"
    echo "------------------------------------------------------------"
}
sha256of() { sha256sum "$1" | awk '{print $1}'; }

execution_dir="$SCRIPT_DIR"
write_yaml() {   # write_yaml <verdict> <notes>
    cat > "${execution_dir}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${1}
notes: |
  ${2}
EOF
    log_info "COMPARISON_RESULTS.yaml written with verdict: ${1}"
}
die() {   # die <exit-code> <log message> [yaml note; defaults to the log message]
    log_error "$2"; write_yaml ftbfs "${3:-$2}"
    echo ""; echo "Exit code: $1"; exit "$1"
}

[[ "$EUID" -eq 0 ]] && die 2 "Do not run this script as root." "Script was run as root; refusing to proceed"

version_arg=""; binary_arg=""; arch_arg=""; type_arg=""; flavor="googlePlay"

require_arg() {
    local flag="$1" val="${2:-}"
    if [[ -z "$val" || "$val" == --* ]]; then
        die 2 "${flag} requires a value (got: '${val:-<nothing>}')" "${flag} requires a value"
    fi
}
usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME [--binary <apk | directory of Play splits>] [--version <x.y.z>] [--flavor googlePlay|otherChannel] [--arch a] [--type t]

  --binary   Official artifact: the GitHub release APK, or a directory holding a Play
             split set (base.apk + split_config.<abi>.apk). If omitted, the GitHub
             release asset mixin-android-<version>.apk is downloaded.
  --version  Release version without the v prefix (tag v<version>). Read from the
             artifact when omitted; when nothing is given the latest GitHub release is used.
  --flavor   Gradle product flavor to build; default googlePlay.
  --arch/--type  accepted and ignored; the artifact decides which ABIs are compared.
USAGE
}
while [[ $# -gt 0 ]]; do
    case $1 in
        --version) require_arg --version "${2:-}"; version_arg="$2"; shift 2 ;;
        --binary|--apk) require_arg "$1" "${2:-}"; binary_arg="$2"; shift 2 ;;
        --flavor)  require_arg --flavor "${2:-}";  flavor="$2";      shift 2 ;;
        --arch)    require_arg --arch "${2:-}";    arch_arg="$2";    shift 2 ;;
        --type)    require_arg --type "${2:-}";    type_arg="$2";    shift 2 ;;
        -h|--help) usage; echo "Exit code: 0"; exit 0 ;;
        *) log_warn "Unknown parameter ignored: $1"; shift ;;
    esac
done
[[ -n "$arch_arg" ]] && log_info "--arch ${arch_arg} accepted but not used (ABIs come from the artifact)"
[[ -n "$type_arg" ]] && log_info "--type ${type_arg} accepted but not used"
case "$flavor" in googlePlay|otherChannel) ;; *) die 2 "--flavor must be googlePlay or otherChannel (got ${flavor})" ;; esac
FLAVOR_CAP="${flavor^}"   # GooglePlay / OtherChannel

if [[ -z "${CRUN:-}" ]]; then   # a docker CLI without daemon access must not win over a working podman
    for c in docker podman; do
        command -v "$c" &>/dev/null && "$c" info &>/dev/null && { CRUN="$c"; break; }
    done
    [[ -n "${CRUN:-}" ]] || die 2 "Neither docker nor podman is usable (installed and able to run 'info')" "No usable container runtime (docker or podman)"
fi
MEM_LIMIT="${MEM_LIMIT:-24g}"
MEM_ARGS=(); [[ -n "$MEM_LIMIT" ]] && MEM_ARGS=(--memory="$MEM_LIMIT")

banner "PRE-FLIGHT: HOST TOOL CHECK"
printf "  %-12s OK  (%s)\n" "$CRUN" "$(command -v "$CRUN")"
if [[ -z "$binary_arg" ]]; then
    command -v curl &>/dev/null || die 2 "curl not found in PATH and --binary was not supplied" "curl required to download the official APK; or pass --binary"
    printf "  %-12s OK  (%s)\n" "curl" "$(command -v curl)"
fi
echo "  Host requirement satisfied."

RUN_ID="mixinandroid-$(date +%s)-$$"
CTR_BASE="ws-mixinandroid-${RUN_ID}"
workspace="${execution_dir}/mixinandroid_verification_${RUN_ID}"
DL_DIR="${workspace}/official"; META_DIR="${workspace}/metadata"
SRC_DIR="${workspace}/source"; BUILD_DIR="${workspace}/built"
GRADLE_HOME="${workspace}/gradle-home"; CMP_DIR="${workspace}/comparison"
TOOLS_DIR="${workspace}/tools"
ctx=""

ensure_user_ownership() {
    [[ -e "$1" ]] || return 0
    # Rootless podman maps container root to the invoking user, so nothing is foreign-owned and a
    # chown to the numeric uid inside the container would land on a subordinate uid instead.
    [[ -n "$(find "$1" ! -user "$HOST_UID" -print -quit 2>/dev/null)" ]] || return 0
    $CRUN run --rm -v "${1}:/target" "$BUILD_IMAGE" \
        sh -c "chown -R ${HOST_UID}:${HOST_GID} /target" >/dev/null 2>&1 || \
        log_warn "Could not fix ownership for ${1}"
}
cleanup() {
    log_info "Cleaning up containers..."
    for c in meta build render cmp; do $CRUN rm -f "${CTR_BASE}-${c}" 2>/dev/null || true; done
    ensure_user_ownership "$workspace"
    [[ -n "$ctx" ]] && rm -rf "$ctx" 2>/dev/null || true
    log_success "Cleanup complete."
}
trap cleanup EXIT
mkdir -p "$DL_DIR" "$META_DIR" "$SRC_DIR" "$BUILD_DIR" "$GRADLE_HOME" "$CMP_DIR" "$TOOLS_DIR"
ctx=$(mktemp -d)

banner "MIXIN MESSENGER (ANDROID) REPRODUCIBLE BUILD VERIFICATION"
echo "  Script:    ${SCRIPT_NAME} ${SCRIPT_VERSION}"
echo "  App ID:    ${APP_ID}"
echo "  Flavor:    ${flavor} (:app:bundle${FLAVOR_CAP}Release rendered with bundletool ${BUNDLETOOL_VERSION})"
echo "  Image:     ${BUILD_IMAGE}"
echo "  Runtime:   ${CRUN} ($($CRUN --version 2>&1 | head -1))"
echo "  Workspace: ${workspace}"
echo "  Date:      $(date)"

# OFFICIAL ARTIFACT(S) -------------------------------------------------------
banner "OFFICIAL ARTIFACT"
declare -a OFFICIAL=()      # absolute paths; OFFICIAL[0] is the base/universal APK
mode=""                     # universal | splits
gh_curl() {   # gh_curl <url> [curl args...]  -- GITHUB_TOKEN is optional
    local url="$1"; shift
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$@" "$url"
    else curl -fsSL "$@" "$url"; fi
}
if [[ -n "$binary_arg" ]]; then
    [[ -e "$binary_arg" ]] || die 2 "--binary path does not exist: ${binary_arg}"
    binary_arg=$(realpath "$binary_arg")
    if [[ -d "$binary_arg" ]]; then
        single=$(find "$binary_arg" -maxdepth 1 -type f -name '*.apk' | head -2)
        if [[ ! -f "${binary_arg}/base.apk" && -n "$single" && $(wc -l <<<"$single") -eq 1 ]]; then
            binary_arg="$single"   # a directory holding one APK is the single-artifact case
        fi
    fi
    if [[ -d "$binary_arg" ]]; then
        mode="splits"
        [[ -f "${binary_arg}/base.apk" ]] || die 2 "--binary directory has no base.apk: ${binary_arg}" "Split directory without base.apk"
        OFFICIAL+=("${binary_arg}/base.apk")
        while IFS= read -r f; do OFFICIAL+=("$f"); done < <(find "$binary_arg" -maxdepth 1 -type f -name 'split_config.*.apk' | sort)
        [[ ${#OFFICIAL[@]} -gt 1 ]] || die 2 "No split_config.*.apk next to base.apk; a single APK must be passed as a file" "Split directory without ABI splits"
        # Only ABI splits exist for this app (language/density splits are disabled in the bundle config).
        for f in "${OFFICIAL[@]:1}"; do
            case "$(basename "$f")" in
                split_config.arm64_v8a.apk|split_config.armeabi_v7a.apk|split_config.x86_64.apk) ;;
                *) die 2 "Unsupported split $(basename "$f"); this app only ships ABI splits" ;;
            esac
        done
        log_info "Play split set: ${#OFFICIAL[@]} APKs in ${binary_arg}"
    else
        mode="universal"; OFFICIAL+=("$binary_arg")
        log_info "Using supplied official APK: ${binary_arg}"
    fi
else
    mode="universal"
    if [[ -n "$version_arg" ]]; then rel_tag="v${version_arg}"
    else
        rel_tag=$(gh_curl "https://api.github.com/repos/MixinNetwork/android-app/releases/latest" 2>/dev/null \
            | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/' | head -1)
        [[ -n "$rel_tag" ]] || die 2 "Could not resolve the latest GitHub release; pass --version or --binary"
        log_info "No --version given; latest GitHub release is ${rel_tag}"
    fi
    apk_url="${REPO_URL}/releases/download/${rel_tag}/mixin-android-${rel_tag#v}.apk"
    dl="${DL_DIR}/mixin-android-${rel_tag#v}.apk"
    log_info "Downloading ${apk_url}"
    gh_curl "$apk_url" --retry 3 --retry-delay 5 -o "$dl" || die 2 "Download failed: ${apk_url}" "Failed to download official APK: ${apk_url}"
    OFFICIAL+=("$dl")
    log_success "Downloaded $(basename "$dl") ($(stat -c%s "$dl") bytes)"
fi
for f in "${OFFICIAL[@]}"; do printf '  %-28s %s  %s bytes\n' "$(basename "$f")" "$(sha256of "$f")" "$(stat -c%s "$f")"; done
app_hash=$(sha256of "${OFFICIAL[0]}")

# Bind-mount the official APKs read-only under /official/<basename>.
OFF_MOUNTS=(); for f in "${OFFICIAL[@]}"; do OFF_MOUNTS+=(-v "${f}:/official/$(basename "$f"):ro"); done
BASE_NAME="$(basename "${OFFICIAL[0]}")"

# PHASE 0: METADATA -----------------------------------------------------------
banner "PHASE 0: OFFICIAL APK METADATA + BUILD INPUTS"
echo "  versionName/versionCode/signer, plus the Firebase and manifest values the build needs."
echo "  Started: $(date)"
cat > "$ctx/meta.sh" <<'META'
#!/bin/bash
set -uo pipefail
BT=$(ls -d "${ANDROID_HOME}/build-tools"/* | sort -V | tail -1)
apk="/official/${BASE_NAME}"
badging=$("$BT/aapt2" dump badging "$apk" 2>/dev/null) || { echo "ERROR: aapt2 cannot read ${BASE_NAME}"; exit 1; }
pkg=$(sed -nE "s/^package: name='([^']+)'.*/\1/p" <<<"$badging" | head -1)
vname=$(grep -oE "versionName='[^']+'" <<<"$badging" | head -1 | sed "s/versionName='//;s/'$//")
vcode=$(grep -oE "versionCode='[^']+'" <<<"$badging" | head -1 | sed "s/versionCode='//;s/'$//")
abis=$(grep -oE "^native-code: .*" <<<"$badging" | tr -d "'" | sed 's/^native-code: //')
sig=$("$BT/apksigner" verify --verbose --print-certs "$apk" 2>&1) || { echo "ERROR: signature verification failed for ${BASE_NAME}"; printf '%s\n' "$sig"; exit 1; }
signer=$(sed -nE 's/^Signer( #[0-9]+| \(minSdkVersion=[^)]*\))? certificate SHA-256 digest: //p' <<<"$sig" | sort -u | paste -sd, -)
stamp=$(sed -nE 's/^Source Stamp Signer certificate DN: //p' <<<"$sig" | head -1)
for other in /official/*.apk; do
    [[ "$other" == "$apk" ]] && continue
    s2=$("$BT/apksigner" verify --print-certs "$other" 2>&1 | sed -nE 's/^Signer( #[0-9]+)? certificate SHA-256 digest: //p' | sort -u | paste -sd, -)
    [[ "$s2" == "$signer" ]] || { echo "ERROR: $(basename "$other") signed by ${s2:-nobody}, base by ${signer}"; exit 1; }
done
printf '%s\n' "$pkg" > /out/pkg; printf '%s\n' "$vname" > /out/vname; printf '%s\n' "$vcode" > /out/vcode
printf '%s\n' "$signer" > /out/signer; printf '%s\n' "$abis" > /out/abis; printf '%s\n' "$stamp" > /out/stamp
# bundletool emits one variant per minSdk threshold (26 / 29 uncompressed dex / 32 sparse resources);
# Play serves the device the highest one it qualifies for, so the base APK's minSdkVersion names it.
minsdk=$("$BT/aapt2" dump xmltree --file AndroidManifest.xml "$apk" 2>/dev/null | grep -oE 'minSdkVersion\([^)]*\)=[0-9]+' | grep -oE '[0-9]+$' | head -1)
[[ -n "$minsdk" ]] || { echo "ERROR: no minSdkVersion in the manifest of ${BASE_NAME}"; exit 1; }
printf '%s\n' "$minsdk" > /out/minsdk
# AGP's VCS info names the commit the vendor built from; the Play build may sit one commit off the tag.
vcs_rev=$(unzip -p "$apk" META-INF/version-control-info.textproto 2>/dev/null | sed -nE 's/^ *revision: *"([0-9a-f]{40})".*/\1/p' | head -1)
printf '%s\n' "$vcs_rev" > /out/vcs_rev
echo "[META] source revision named by the artifact (version-control-info.textproto): ${vcs_rev:-none}"
echo "[META] package: ${pkg}  versionName: ${vname}  versionCode: ${vcode}  minSdkVersion: ${minsdk}"
echo "[META] native-code: ${abis}"
echo "[META] signer SHA-256: ${signer}"
echo "[META] source stamp: ${stamp:-none}"
# Firebase values -> google-services.json (the plugin turns the json into exactly these strings).
"$BT/aapt2" dump resources "$apk" > /tmp/res.txt 2>/dev/null
val() { awk -v k="string/$1" '$0 ~ k"$" {getline; if (match($0,/"[^"]*"/)) print substr($0,RSTART+1,RLENGTH-2); exit}' /tmp/res.txt; }
API_KEY=$(val google_api_key); GAPP=$(val google_app_id); SENDER=$(val gcm_defaultSenderId); PROJECT=$(val project_id)
DBURL=$(val firebase_database_url); BUCKET=$(val google_storage_bucket); WEBCLIENT=$(val default_web_client_id); GA=$(val ga_trackingId)
if [[ -z "$GAPP" || -z "$SENDER" || -z "$PROJECT" || -z "$API_KEY" ]]; then
    echo "ERROR: Firebase strings missing from the official APK; cannot rebuild google-services.json"; exit 1
fi
{
    echo '{'; echo '  "project_info": {'
    printf '    "project_number": "%s",\n' "$SENDER"
    [[ -n "$DBURL" ]] && printf '    "firebase_url": "%s",\n' "$DBURL"
    printf '    "project_id": "%s"' "$PROJECT"
    [[ -n "$BUCKET" ]] && printf ',\n    "storage_bucket": "%s"' "$BUCKET"
    echo; echo '  },'; echo '  "client": [{'
    printf '    "client_info": {"mobilesdk_app_id": "%s", "android_client_info": {"package_name": "%s"}},\n' "$GAPP" "$pkg"
    # The Firebase project has a web OAuth client: the plugin turns it into string/default_web_client_id,
    # which the resource shrinker later removes from the APK but whose id slot stays allocated (official
    # 6.2.2 has a hole at 0x7f1506c2 between default_time and delete_account_hint). Without an entry here
    # every later string id shifts by one and all resource-referencing files differ. The value itself
    # never reaches the APK, so a placeholder is used when the string was shrunk out.
    printf '    "oauth_client": [{"client_id": "%s", "client_type": 3}],\n' "${WEBCLIENT:-placeholder-web-client-id.apps.googleusercontent.com}"
    printf '    "api_key": [{"current_key": "%s"}],\n' "$API_KEY"
    if [[ -n "$GA" ]]; then printf '    "services": {"analytics_service": {"status": 2, "analytics_property": {"tracking_id": "%s"}}, "appinvite_service": {"other_platform_oauth_client": []}}\n' "$GA"
    else echo '    "services": {"appinvite_service": {"other_platform_oauth_client": []}}'; fi
    echo '  }],'; echo '  "configuration_version": "1"'; echo '}'
} > /out/google-services.json
echo "[META] google-services.json rebuilt: project ${PROJECT}, sender ${SENDER}, app id ${GAPP}"
# Manifest placeholders -> local.properties (secrets-gradle-plugin reads it before local.defaults.properties).
"$BT/aapt2" dump xmltree --file AndroidManifest.xml "$apk" > /tmp/manifest.txt 2>/dev/null
mval() { grep -A2 "android:name(0x[0-9a-f]*)=\"$1\"" /tmp/manifest.txt | grep -oE 'android:value\([^)]*\)="[^"]*"' | sed -E 's/.*="(.*)"/\1/' | head -1; }
: > /out/local.properties
for pair in "com.google.android.geo.API_KEY:GOOGLE_MAP_KEY" "com.bugsnag.android.API_KEY:BUGSNAG_KEY"; do
    v=$(mval "${pair%%:*}")
    if [[ -n "$v" ]]; then echo "${pair##*:}=${v}" >> /out/local.properties; echo "[META] ${pair##*:} recovered from the official manifest (${#v} chars)"
    else echo "[META] ${pair##*:} not present in the official manifest"; fi
done
META
sed -i "s/\${BASE_NAME}/${BASE_NAME}/g" "$ctx/meta.sh"
$CRUN run --rm --name "${CTR_BASE}-meta" "${OFF_MOUNTS[@]}" -v "${META_DIR}:/out" -v "${ctx}/meta.sh:/meta.sh:ro" \
    "$BUILD_IMAGE" bash /meta.sh || die 1 "Phase 0 metadata extraction failed" "APK metadata extraction failed"
pkg_id=$(cat "$META_DIR/pkg"); wallet_version=$(cat "$META_DIR/vname"); version_code=$(cat "$META_DIR/vcode")
signer=$(cat "$META_DIR/signer"); abis=$(cat "$META_DIR/abis"); stamp=$(cat "$META_DIR/stamp"); min_sdk=$(cat "$META_DIR/minsdk"); official_rev=$(cat "$META_DIR/vcs_rev")
[[ "$pkg_id" == "$APP_ID" ]] || die 1 "APK app ID mismatch: expected ${APP_ID}, got ${pkg_id}"
[[ -n "$wallet_version" ]] || die 1 "Could not derive versionName from the official APK"
if [[ -n "$version_arg" && "$version_arg" != "$wallet_version" ]]; then
    die 2 "Requested --version ${version_arg} but the official APK reports ${wallet_version}" "Requested version ${version_arg} but official APK is ${wallet_version}"
fi
if [[ "$mode" == "universal" && "$abis" != *arm64-v8a*armeabi-v7a*x86_64* ]]; then
    log_warn "Universal APK expected three ABIs, found: ${abis}"
fi
log_success "APK metadata: v${wallet_version} (code ${version_code}), signer ${signer}"

# PHASE 1: BUILD --------------------------------------------------------------
tag="v${wallet_version}"
banner "PHASE 1: SOURCE BUILD (${tag}, :app:bundle${FLAVOR_CAP}Release)"
echo "  Clone, version check, input injection and Gradle all run inside the pinned image."
echo "  Started: $(date)"
cat > "$ctx/build.sh" <<'BUILD'
#!/bin/bash
set -uo pipefail
tag="__TAG__"; want="__VERSION__"; vcode="__VCODE__"
export GRADLE_USER_HOME=/gradle-home GRADLE_OPTS="-Dorg.gradle.daemon=false"
echo "[BUILD] java: $(java -version 2>&1 | head -1)"
# /project is a host directory; under a rootful runtime its owner is not the container user and
# git refuses every command after the clone ("dubious ownership"), silently blanking the commit.
git config --global --add safe.directory /project
if [[ ! -f /project/app/build.gradle.kts ]]; then
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "__REPO__" /project || { echo "[BUILD] ERROR: tag ${tag} not found at __REPO__"; exit 7; }
fi
cd /project || exit 7
tag_commit=$(git rev-parse HEAD 2>/dev/null)
[[ -n "$tag_commit" ]] || { echo "[BUILD] ERROR: git cannot read HEAD in /project"; git rev-parse HEAD; exit 9; }
echo "[BUILD] ${tag} = ${tag_commit} ($(git cat-file -t "refs/tags/${tag}" 2>/dev/null || echo lightweight) tag object)"
# The artifact may name the exact commit it was built from. When that commit is public it is the
# honest thing to build; the tag is the fallback. Either way both commits are reported.
offrev="__OFFREV__"; source_note="tag ${tag} (artifact names no revision)"
if [[ -n "$offrev" && "$offrev" != "$tag_commit" ]]; then
    if git fetch -q --depth 1 origin "$offrev" 2>/dev/null && git -c advice.detachedHead=false checkout -q "$offrev"; then
        changed=$(git diff --name-only "$offrev" "$tag_commit" | paste -sd, -)
        source_note="artifact-named revision ${offrev:0:12} built instead of ${tag} (${tag_commit:0:12}), files differing between the two: ${changed:-none}"
    else
        source_note="WARNING: artifact names revision ${offrev:0:12}, not fetchable from the public repository, built ${tag} (${tag_commit:0:12}) instead"
    fi
elif [[ -n "$offrev" ]]; then source_note="artifact names ${tag}'s commit ${tag_commit:0:12}"; fi
printf '%s\n' "$source_note" > /out/source_note.txt; echo "[BUILD] ${source_note}"
git rev-parse HEAD > /out/commit.txt
src_vname=$(awk -F'= *' '/^val versionMajor/{a=$2} /^val versionMinor/{b=$2} /^val versionPatch/{c=$2} END{print a"."b"."c}' app/build.gradle.kts)
if [[ "$src_vname" != "$want" ]]; then
    [[ "$(cat /out/commit.txt)" != "$tag_commit" ]] || { echo "[BUILD] ERROR: source at ${tag} declares version ${src_vname}, artifact says ${want}"; exit 8; }
    IFS=. read -r wa wb wc <<<"$want"
    sed -i -E "s/^(val versionMajor *= *)[0-9]+/\1${wa}/;s/^(val versionMinor *= *)[0-9]+/\1${wb}/;s/^(val versionPatch *= *)[0-9]+/\1${wc}/" app/build.gradle.kts
    echo "[BUILD] version patched ${src_vname} -> ${want}: the artifact-named revision predates the version bump the vendor applied at build time"
    echo "version patched ${src_vname} -> ${want}" >> /out/source_note.txt
fi
# versionCode = major*1000000 + minor*10000 + patch*100 + versionBuild. The tag may carry a
# lower versionBuild than the shipped artifact (v6.2.2 declares 1, the store build has 2). Only
# the manifest versionCode depends on it, so it is aligned with the artifact and reported.
src_build=$(sed -nE 's/^val versionBuild *= *([0-9]+).*/\1/p' app/build.gradle.kts | head -1)
art_build=$((10#${vcode} % 100))
note="versionBuild ${src_build} (matches artifact)"
if [[ -n "$src_build" && "$src_build" != "$art_build" ]]; then
    sed -i -E "s/^(val versionBuild *= *)[0-9]+/\1${art_build}/" app/build.gradle.kts
    note="versionBuild patched ${src_build} -> ${art_build} to match versionCode ${vcode} (source declares $((10#${vcode} - art_build + src_build)))"
fi
printf '%s\n' "$note" > /out/version_build_note.txt; echo "[BUILD] ${note}"
cp /inputs/google-services.json app/google-services.json && cp /inputs/local.properties local.properties || exit 7
echo "[BUILD] gradle wrapper: $(sed -nE 's/^distributionUrl=.*gradle-([0-9.]+)-.*/\1/p' gradle/wrapper/gradle-wrapper.properties)"
# Bugsnag upload/create tasks are finalizers on the bundle task; they need credentials and do not touch the AAB.
./gradlew --no-daemon --stacktrace ":app:bundle__FLAVOR__Release" \
    -x "bugsnagUpload__FLAVOR__ReleaseProguardMapping" -x "bugsnagCreate__FLAVOR__ReleaseBuild" 2>&1 | tee /out/gradle.log \
    | grep -E "^> Task :app:(bundle|package|minify|merge.*Native|externalNative)|BUILD |FAILURE|What went wrong|^> [A-Z]|^e: " | tail -60
rc=${PIPESTATUS[0]}
aab=$(ls app/build/outputs/bundle/*Release/*.aab 2>/dev/null | head -1)
if [[ "$rc" -ne 0 || -z "$aab" ]]; then echo "[BUILD] gradle exit ${rc}, aab: ${aab:-none}"; tail -40 /out/gradle.log; exit 1; fi
cp "$aab" /out/app.aab; sha256sum /out/app.aab
BUILD
sed -i -e "s/__FLAVOR__/${FLAVOR_CAP}/g" -e "s/__TAG__/${tag}/g" -e "s/__VERSION__/${wallet_version}/g" \
    -e "s/__VCODE__/${version_code}/g" -e "s|__REPO__|${REPO_URL}|g" -e "s/__OFFREV__/${official_rev}/g" "$ctx/build.sh"
$CRUN run --rm --name "${CTR_BASE}-build" "${MEM_ARGS[@]}" \
    -v "${SRC_DIR}:/project" -v "${META_DIR}:/inputs:ro" -v "${GRADLE_HOME}:/gradle-home" -v "${BUILD_DIR}:/out" \
    -v "${ctx}/build.sh:/build.sh:ro" "$BUILD_IMAGE" bash /build.sh
build_rc=$?
case "$build_rc" in
    0) ;;
    7) die 2 "Clone of ${tag} failed (see output above)" "Tag ${tag} could not be cloned from ${REPO_URL}" ;;
    9) die 1 "git cannot read the checkout in /project (ownership or permissions, see output above)" "git could not read the source checkout" ;;
    8) die 1 "Source at ${tag} does not declare version ${wallet_version}" "Source version at ${tag} does not match the artifact version ${wallet_version}" ;;
    *) die 1 "Gradle build failed (see built/gradle.log)" "Gradle :app:bundle${FLAVOR_CAP}Release failed" ;;
esac
[[ -f "$BUILD_DIR/app.aab" ]] || die 1 "Build finished without an AAB" "Gradle :app:bundle${FLAVOR_CAP}Release produced no AAB"
commit=$(cat "$BUILD_DIR/commit.txt"); version_build_note=$(cat "$BUILD_DIR/version_build_note.txt")
source_note=$(paste -sd'|' "$BUILD_DIR/source_note.txt" | sed 's/|/; /g')
[[ "$version_build_note" == *patched* ]] && log_warn "$version_build_note"
[[ "$source_note" == *WARNING* || "$source_note" == *patched* ]] && log_warn "$source_note"
log_success "Checked out ${tag} = ${commit}; AAB built: $(sha256of "$BUILD_DIR/app.aab")"

section "Rendering APKs with bundletool ${BUNDLETOOL_VERSION} (${mode})"
bt_jar="${TOOLS_DIR}/bundletool-all-${BUNDLETOOL_VERSION}.jar"
if [[ ! -f "$bt_jar" ]]; then
    $CRUN run --rm --name "${CTR_BASE}-render" -v "${TOOLS_DIR}:/tools" "$BUILD_IMAGE" \
        curl -fsSL --retry 3 -o "/tools/$(basename "$bt_jar")" \
        "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar" \
        || die 2 "bundletool download failed"
fi
[[ "$(sha256of "$bt_jar")" == "$BUNDLETOOL_SHA256" ]] || die 1 "bundletool checksum mismatch: $(sha256of "$bt_jar")" "bundletool jar checksum mismatch"
if [[ "$mode" == "universal" ]]; then bt_mode="--mode=universal"; else bt_mode="--mode=default"; fi
$CRUN run --rm --name "${CTR_BASE}-render" -v "${TOOLS_DIR}:/tools:ro" -v "${BUILD_DIR}:/out" "$BUILD_IMAGE" bash -c "
    set -e; cd /out; rm -rf rendered; mkdir rendered
    java -jar /tools/$(basename "$bt_jar") build-apks --bundle=/out/app.aab --output=/out/rendered.apks ${bt_mode} --overwrite
    cd rendered && unzip -q -o ../rendered.apks && find . -name '*.apk' | sort | sed 's|^\./||' > list.txt && cat list.txt
    BT=\$(ls -d \"\${ANDROID_HOME}/build-tools\"/* | sort -V | tail -1); : > variants.txt
    for a in \$(grep '^splits/' list.txt); do
        m=\$(\"\$BT/aapt2\" dump xmltree --file AndroidManifest.xml \"\$a\" 2>/dev/null | grep -oE 'minSdkVersion\\([^)]*\\)=[0-9]+' | grep -oE '[0-9]+\$' | head -1)
        echo \"\$a \${m:-?}\" >> variants.txt
    done" \
    || die 1 "bundletool build-apks failed"
# Pair every official APK with its rendered counterpart.
declare -a PAIRS=()   # "official-basename|rendered-relative-path"
if [[ "$mode" == "universal" ]]; then
    PAIRS+=("${BASE_NAME}|universal.apk")
else
    echo "  Official base.apk has minSdkVersion ${min_sdk}; pairing with the bundletool variant that declares the same:"
    for f in "${OFFICIAL[@]}"; do
        n=$(basename "$f")
        case "$n" in base.apk) stem="base-master" ;; split_config.*.apk) stem="base-${n#split_config.}"; stem="${stem%.apk}" ;; esac
        r=$(awk -v s="splits/${stem}" -v m="$min_sdk" '($1 == s ".apk" || $1 ~ ("^" s "_[0-9]+\\.apk$")) && $2 == m { print $1; exit }' "$BUILD_DIR/rendered/variants.txt")
        [[ -n "$r" && -f "$BUILD_DIR/rendered/$r" ]] \
            || die 1 "bundletool produced no ${stem} variant with minSdkVersion ${min_sdk} for ${n} (see built/rendered/variants.txt)" "Rendered split set lacks a minSdk ${min_sdk} variant for ${n}"
        PAIRS+=("${n}|${r}")
    done
fi
for p in "${PAIRS[@]}"; do printf '  %-28s <-> %s\n' "${p%%|*}" "${p##*|}"; done

# PHASE 2: COMPARISON ---------------------------------------------------------
banner "PHASE 2: CONTENTS COMPARISON (${#PAIRS[@]} artifact(s))"
echo "  Signing material and the Play SourceStamp are excluded; resources.arsc and"
echo "  AndroidManifest.xml are judged on their decoded form (WS #574)."
echo "  Started: $(date)"
if [[ ! -f "${TOOLS_DIR}/apktool.jar" ]]; then
    $CRUN run --rm --name "${CTR_BASE}-render" -v "${TOOLS_DIR}:/tools" "$BUILD_IMAGE" \
        curl -fsSL --retry 3 -o /tools/apktool.jar "$APKTOOL_URL" || die 2 "apktool download failed"
fi
cat > "$ctx/compare.sh" <<'CMP'
#!/bin/bash
set -uo pipefail
APKTOOL="java -jar /tools/apktool.jar"
total_raw=0; total_acc=0; total_mat=0; : > /out/material.txt; : > /out/acceptable.txt; : > /out/diff_full.txt
while IFS='|' read -r off rel; do
    tag="${off%.apk}"
    o=/tmp/o-$tag; b=/tmp/b-$tag; rm -rf "$o" "$b"; mkdir -p "$o" "$b"
    echo ""; echo "== ${off} vs ${rel}"
    unzip -q -o "/official/${off}" -d "$o" || { echo "ERROR: cannot unpack ${off}"; exit 3; }
    unzip -q -o "/built/rendered/${rel}" -d "$b" || { echo "ERROR: cannot unpack ${rel}"; exit 3; }
    for d in "$o" "$b"; do [[ -n "$(find "$d" -type f | head -1)" ]] || { echo "ERROR: ${d} empty after unpack"; exit 3; }; done
    # Signing material (upstream signs, we do not) and the Play SourceStamp file (written by
    # Google Play, certificate CN=Android O=Google Inc.) can never come out of a rebuild.
    find "$o" "$b" -maxdepth 2 -path '*/META-INF/*' \
        \( -iname '*.RSA' -o -iname '*.DSA' -o -iname '*.EC' -o -iname '*.SF' -o -iname 'MANIFEST.MF' \) \
        -print -delete | sed 's|^/tmp/[ob]-[^/]*/|  excluded (signing): |'
    find "$o" "$b" -maxdepth 1 -name 'stamp-cert-sha256' -print -delete | sed 's|^/tmp/[ob]-[^/]*/|  excluded (Play SourceStamp): |'
    echo "  files: $(find "$o" -type f | wc -l) official, $(find "$b" -type f | wc -l) built"
    diff -rq "$o" "$b" > /tmp/raw.txt 2>&1; rc=$?
    if [[ $rc -ne 0 && $rc -ne 1 ]]; then echo "ERROR: diff exit ${rc}"; head -20 /tmp/raw.txt; exit 3; fi
    unparsed=$(grep -vE '^(Files|Only in)' /tmp/raw.txt | grep -v '^$' || true)
    [[ -z "$unparsed" ]] || { echo "ERROR: unrecognised diff output"; printf '%s\n' "$unparsed" | head -20; exit 3; }
    cnt=$(grep -E '^(Files|Only in)' /tmp/raw.txt || true)
    raw=$(printf '%s\n' "$cnt" | grep -c . || true); raw=${raw:-0}
    [[ $rc -eq 1 && $raw -eq 0 ]] && { echo "ERROR: diff reported differences but none were parsed"; exit 3; }
    echo "  raw differences: ${raw}"
    printf '%s\n' "$cnt" | sed "s|/tmp/o-${tag}/||;s|/tmp/b-${tag}/||" | head -5 | sed 's/^/    /'
    [[ $raw -gt 5 ]] && echo "    ... full list: comparison/diff_full.txt"
    { echo "## ${off}"; printf '%s\n' "$cnt"; } >> /out/diff_full.txt
    acc=0; mat=0; decoded=0
    decode_both() {   # apktool failure is a tool error (exit 3 -> ftbfs), never a verdict on the artifact
        [[ $decoded -eq 1 ]] && return 0; decoded=1
        rm -rf /tmp/do /tmp/db
        $APKTOOL d -f --no-src --no-debug-info -o /tmp/do "/official/${off}" > /tmp/apktool.log 2>&1 \
            || { echo "ERROR: apktool could not decode ${off}"; tail -5 /tmp/apktool.log; exit 3; }
        $APKTOOL d -f --no-src --no-debug-info -o /tmp/db "/built/rendered/${rel}" > /tmp/apktool.log 2>&1 \
            || { echo "ERROR: apktool could not decode ${rel}"; tail -5 /tmp/apktool.log; exit 3; }
        # Only the manifest is guaranteed: ABI config splits carry no resources.arsc, so no res/.
        [[ -f /tmp/do/AndroidManifest.xml && -f /tmp/db/AndroidManifest.xml ]] \
            || { echo "ERROR: apktool output incomplete for ${off} (missing AndroidManifest.xml)"; exit 3; }
    }
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^Files\ /tmp/o-[^/]+/(.*)\ and\ /tmp/b-.*\ differ$ ]]; then f="${BASH_REMATCH[1]}"
        else   # "Only in /tmp/o-<tag>/dir: file" -> "only in official: dir/file"
            rest="${line#Only in }"; odir="${rest%%: *}"; ofile="${rest#*: }"
            case "$odir" in /tmp/o-*) side="only in official" ;; *) side="only in built" ;; esac
            odir="${odir#/tmp/[ob]-"${tag}"}"; odir="${odir#/}"
            echo "${off}: ${side}: ${odir:+$odir/}${ofile}" >> /out/material.txt; mat=$((mat+1)); continue; fi
        case "$f" in
            resources.arsc)
                decode_both
                [[ -d /tmp/do/res && -d /tmp/db/res ]] \
                    || { echo "ERROR: apktool output incomplete for ${off} (resources.arsc present but no decoded res/)"; exit 3; }
                rf="/out/diff_res_${tag}.txt"
                diff -r /tmp/do/res /tmp/db/res > "$rf" 2>&1; drc=$?
                # Everything that is not diff structure must be the Crashlytics mapping id, a per-build
                # R8 UUID that WS #574 accepts; anything else in the decoded tree is material.
                rest=$(grep -vE '^([0-9,]+[acd][0-9,]+|---|diff (-r )?/tmp/.*)$' "$rf" | grep -v 'crashlytics\.mapping_file_id' || true)
                if [[ $drc -eq 0 ]]; then
                    echo "  resources.arsc: binary differs, decoded res/ IDENTICAL, acceptable (WS #574)"; acc=$((acc+1))
                    echo "${off}: resources.arsc binary differs, decoded res/ identical" >> /out/acceptable.txt
                elif [[ $drc -eq 1 && -z "$rest" ]]; then
                    echo "  resources.arsc: decoded res/ differs only in crashlytics mapping_file_id (per-build R8 id), acceptable (WS #574)"
                    grep '^[<>]' "$rf" | head -2 | sed 's/^/    /'; acc=$((acc+1))
                    echo "${off}: resources.arsc decoded diff limited to crashlytics.mapping_file_id" >> /out/acceptable.txt
                else
                    echo "  resources.arsc: decoded res/ DIFFERS (comparison/diff_res_${tag}.txt), material"
                    printf '%s\n' "$rest" | head -5 | sed 's/^/    /'
                    echo "${off}: resources.arsc (decoded res/ differs)" >> /out/material.txt; mat=$((mat+1))
                fi ;;
            AndroidManifest.xml)
                decode_both; mf="/out/diff_manifest_${tag}.txt"
                diff -u /tmp/do/AndroidManifest.xml /tmp/db/AndroidManifest.xml > "$mf" 2>&1; drc=$?
                # Google Play stamps the manifest of everything it serves (stamp.source, stamp.type,
                # vending.derived.apk.id); a rebuild cannot carry those. Any other changed line is material.
                changed=$(grep -E '^[-+][^-+]' "$mf" || true)
                # Judge on both manifests with the stamp lines removed and an element left childless
                # collapsed to its self-closing form (that is how the stamp shows up in a config split).
                norm() { grep -vE 'com\.android\.(stamp\.(source|type)|vending\.derived\.apk\.id)' "$1" | awk '
                    { if (held != "") { if ($0 ~ ("^[ \t]*</" tag ">$")) { sub(/>$/, "/>", held); print held; held = ""; next }
                                        print held; held = "" }
                      if (match($0, /^[ \t]*<[A-Za-z][A-Za-z0-9_.:-]*( [^>]*[^\/?])?>$/)) { held = $0; tag = $0; sub(/^[ \t]*</, "", tag); sub(/[ \t>].*$/, "", tag); next }
                      print } END { if (held != "") print held }'; }
                rest=$(diff <(norm /tmp/do/AndroidManifest.xml) <(norm /tmp/db/AndroidManifest.xml) | grep -E '^[<>]' || true)
                if [[ $drc -eq 0 ]]; then
                    echo "  AndroidManifest.xml: binary differs, decoded XML IDENTICAL, acceptable"; acc=$((acc+1))
                    echo "${off}: AndroidManifest.xml binary differs, decoded XML identical" >> /out/acceptable.txt
                elif [[ $drc -eq 1 && -z "$rest" ]]; then
                    echo "  AndroidManifest.xml: decoded XML differs only in Play SourceStamp meta-data, acceptable"
                    printf '%s\n' "$changed" | head -3 | sed 's/^/    /'; acc=$((acc+1))
                    printf '%s\n' "$changed" | sed "s/^/${off}: manifest /" >> /out/acceptable.txt
                else
                    echo "  AndroidManifest.xml: decoded XML DIFFERS (comparison/diff_manifest_${tag}.txt), material"
                    printf '%s\n' "$rest" | head -5 | sed 's/^/    /'
                    echo "${off}: AndroidManifest.xml (decoded XML differs)" >> /out/material.txt; mat=$((mat+1))
                fi ;;
            *) echo "${off}: ${f}" >> /out/material.txt; mat=$((mat+1)) ;;
        esac
    done < <(printf '%s\n' "$cnt")
    echo "  acceptable: ${acc}   material: ${mat}"
    echo "${off} raw=${raw} acceptable=${acc} material=${mat}" >> /out/per_artifact.txt
    total_raw=$((total_raw+raw)); total_acc=$((total_acc+acc)); total_mat=$((total_mat+mat))
    rm -rf "$o" "$b" /tmp/do /tmp/db
done < /pairs.txt
echo ""; echo "  totals: raw=${total_raw} acceptable=${total_acc} material=${total_mat}"
# Every verdict-bearing entry is printed so the recording alone carries the full list (WS rule).
[[ -s /out/material.txt ]] && { echo "  material entries, complete list ($(wc -l < /out/material.txt), also comparison/material.txt):"; head -200 /out/material.txt | sed 's/^/    /'; [[ $(wc -l < /out/material.txt) -gt 200 ]] && echo "    ... truncated at 200, see the file"; }
[[ -s /out/acceptable.txt ]] && { echo "  acceptable entries, complete list ($(wc -l < /out/acceptable.txt), also comparison/acceptable.txt):"; sed 's/^/    /' /out/acceptable.txt; }
printf 'raw_total=%s\nacceptable=%s\nmaterial=%s\n' "$total_raw" "$total_acc" "$total_mat" > /out/summary.txt
CMP
printf '%s\n' "${PAIRS[@]}" > "$ctx/pairs.txt"
: > "$CMP_DIR/per_artifact.txt"
$CRUN run --rm --name "${CTR_BASE}-cmp" "${OFF_MOUNTS[@]}" -v "${BUILD_DIR}:/built:ro" -v "${TOOLS_DIR}:/tools:ro" \
    -v "${CMP_DIR}:/out" -v "${ctx}/compare.sh:/compare.sh:ro" -v "${ctx}/pairs.txt:/pairs.txt:ro" \
    "$BUILD_IMAGE" bash /compare.sh 2>&1 | tee "$CMP_DIR/comparison.log"
[[ ${PIPESTATUS[0]} -eq 0 ]] || die 1 "Comparison phase failed" "Comparison phase failed (tool error)"
raw_total=$(sed -nE 's/^raw_total=([0-9]+)$/\1/p' "$CMP_DIR/summary.txt"); acc_count=$(sed -nE 's/^acceptable=([0-9]+)$/\1/p' "$CMP_DIR/summary.txt")
mat_count=$(sed -nE 's/^material=([0-9]+)$/\1/p' "$CMP_DIR/summary.txt"); mat_count=${mat_count:-1}

section "VERDICT (judged on non-signature diffs across all artifacts)"
echo "  Raw differences:              ${raw_total:-?}"
echo "  Acceptable per WS #574:       ${acc_count:-?}"
echo "  Material (verdict-bearing):   ${mat_count}"
echo "  Acceptable-diffs policy: https://gitlab.com/walletscrutiny/walletScrutinyCom/-/issues/574"
if [[ "$mat_count" -eq 0 ]]; then VERDICT="reproducible"; log_success "Verdict: REPRODUCIBLE (0 material diffs; ${acc_count} acceptable)"
else VERDICT="not_reproducible"; log_error "Verdict: NOT_REPRODUCIBLE (${mat_count} material diff(s))"; fi

built_hash=$(sha256of "$BUILD_DIR/rendered/${PAIRS[0]##*|}")
echo ""
cat <<RESULTS
===== Begin Results =====
appId:          ${APP_ID}
signer:         ${signer}
apkVersionName: ${wallet_version}
apkVersionCode: ${version_code}
verdict:        ${VERDICT}
appHash:        ${app_hash}
builtHash:      ${built_hash}
commit:         ${commit}
scriptVersion:  ${SCRIPT_VERSION}
scriptHash:     ${SCRIPT_SHA256}
variant:        ${flavor} flavor, :app:bundle${FLAVOR_CAP}Release, bundletool ${BUNDLETOOL_VERSION} ${mode}
image:          ${BUILD_IMAGE}
artifacts:      ${#PAIRS[@]} ($(paste -sd' ' "$CMP_DIR/per_artifact.txt"))
rawDiffs:       ${raw_total}
acceptableDiffs:${acc_count} (WS #574; each one listed in comparison/acceptable.txt)
materialDiffs:  ${mat_count}
excluded:       META-INF signing files, stamp-cert-sha256 and stamp meta-data (Play SourceStamp${stamp:+, signer $stamp})
buildInputs:    google-services.json + manifest API keys rebuilt from the official APK
versionBuild:   ${version_build_note}
sourceRevision: ${source_note}
===== End Results =====
RESULTS
write_yaml "${VERDICT}" "Source-built ${flavor} AAB rendered with bundletool ${BUNDLETOOL_VERSION} (${mode}) vs official: ${raw_total} raw difference(s) over ${#PAIRS[@]} artifact(s) after excluding signing material and the Play SourceStamp, of which ${acc_count} acceptable per WS #574 and ${mat_count} material. Official ${app_hash}; built ${built_hash}. google-services.json and manifest API keys were rebuilt from values found in the official APK; ${version_build_note}; source: ${source_note}."
if [[ "$VERDICT" == "reproducible" ]]; then echo ""; echo "Exit code: 0"; exit 0
else echo ""; echo "Exit code: 1"; exit 1; fi
