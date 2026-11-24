#!/usr/bin/env bash
# mixinandroid-v0.2.0_build.sh - Mixin Messenger (one.mixin.messenger) Android Verification
# Version:          v0.2.0
# Last modified by: Claude Code for Danny
# Last modified on: 2026-11-24
# Organization:     WalletScrutiny.com
# Project:          https://github.com/MixinNetwork/android-app
# Host deps: podman or docker, curl.
# DISCLAIMER: for reproducible build verification and research only, without warranty; users
# assume all risks and are responsible for complying with applicable laws.
#
# SCRIPT SUMMARY:
# - Reads version, signer and Firebase/API-key values from the official GitHub APK or Play splits.
# - Clones the tag, injects those inputs, builds :app:bundle<Flavor>Release and renders it with
#   bundletool in the official artifact's mode (universal or split set).
# - Unpacks both sides and diffs them; signing files and the Play SourceStamp are excluded,
#   resources.arsc and AndroidManifest.xml are judged on their apktool-decoded form (WS #574).
# - Library ws-rb-core (GitLab #1023) pinned below (offline: WS_LIB_FILE). The workspace is new per
#   run in the caller's directory. After the build, ws-buildlock.sh (#1000, pinned) writes
#   <workspace>/build-lock/build-lock.json; it never changes the verdict.
# Exit: 0 reproducible; 1 not reproducible, ftbfs or no verdict; 2 invalid input or library unavailable.
#
# Five things to know:
#  1. Reuses the pins of upstream's verify-mixin-apk.sh (image digest, bundletool 1.18.3,
#     tag) but compares files, not a phone.
#  2. Official APKs are bundletool renderings of the release AAB (GitHub: universal;
#     Play: base + ABI splits); bundletool renders the same shape from our AAB.
#  3. Two flavors exist, googlePlay and otherChannel; they differ only in
#     BuildConfig.IS_GOOGLE_PLAY. Default is googlePlay (the GitHub asset carries a
#     Google SourceStamp, so it came out of Play). --flavor overrides.
#  4. The repo does not contain google-services.json nor the API keys the secrets
#     plugin bakes into the manifest and BuildConfig (blank " " defaults). Both are
#     rebuilt from values the official APK itself carries (Firebase string resources,
#     manifest meta-data). Values that only live in dex cannot be recovered that way
#     and will show up as dex differences.
#  5. Bugsnag upload tasks need an account and are excluded (-x); the AAB is unchanged.

SCRIPT_VERSION="v0.2.0"
SCRIPT_NAME="mixinandroid-v0.2.0_build.sh"
SCRIPT_PATH="$(readlink -f "$0")"
if [[ -f "$SCRIPT_PATH" ]]; then
    SCRIPT_SHA256="$(sha256sum "$SCRIPT_PATH" | awk '{print $1}')"
else
    SCRIPT_SHA256="N/A"
fi
printf '%s %s sha256:%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$SCRIPT_SHA256"

set -uo pipefail   # no -e; the library's ERR trap turns any unguarded failure into no verdict

# ---- WalletScrutiny library (GitLab #1023), pinned by sha256 ------------------
# Goes in each build script right after its self-hash line, before anything else.
# Source: WS_LIB_FILE (offline, must match), else the cache, else GitLab by
# commit. Nothing else. A wrong hash is rejected whichever source sent it.
# No matching copy, or a different version inside: no verdict, no YAML, exit 2.
# First, before anything can fail: no earlier verdict may survive this run. A run
# that holds this folder's lock is still writing its own; that one stays, and the
# library refuses this run when it takes the lock.
WS_LIB_DIR0="$(dirname "$(readlink -f "$0")")"
if command -v flock >/dev/null 2>&1; then
  flock -n "$WS_LIB_DIR0/.comparison_results.lock" true 2>/dev/null && rm -f -- "$WS_LIB_DIR0/COMPARISON_RESULTS.yaml"
else
  WS_LIB_P="$(cat "$WS_LIB_DIR0/.comparison_results.lock.d/pid" 2>/dev/null || true)"
  case "$WS_LIB_P" in ''|*[!0-9]*) WS_LIB_P="";; esac
  { [ -n "$WS_LIB_P" ] && kill -0 "$WS_LIB_P" 2>/dev/null; } || rm -f -- "$WS_LIB_DIR0/COMPARISON_RESULTS.yaml"
fi
WS_LIB=ws-rb-core WS_LIB_VERSION=1.1.0
WS_LIB_REV=3bafe3b5961f11bcf1fa4fbbe3f4f206d53a61d0 WS_LIB_SHA256=4f0920dc8edb1e07aefbb4748d72fd3cc011eb769aaa40de8b5a6a9026312c7e
ws_lib_load() {
  local c f u t=""
  ws_lib_ok() { [ "$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)" = "$WS_LIB_SHA256" ]; }
  if [ -n "${WS_LIB_FILE:-}" ]; then
    f="$WS_LIB_FILE"
    ws_lib_ok "$f" || { echo "[FAIL] WS_LIB_FILE $f is not sha256 $WS_LIB_SHA256: no verdict" >&2; exit 2; }
  else
    # Cache in XDG_CACHE_HOME or HOME; with neither, or no way to create it, a
    # temporary folder for this run only. Every copy is hash-checked either way.
    c="${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}"
    if [ -n "$c" ] && mkdir -p "$c/ws-rb-lib" 2>/dev/null; then c="$c/ws-rb-lib"
    else t="$(mktemp -d 2>/dev/null)" || { echo "[FAIL] no folder to fetch $WS_LIB into: no verdict" >&2; exit 2; }; c="$t"; fi
    f="$c/$WS_LIB_SHA256.sh"
    if ! ws_lib_ok "$f"; then
      u="https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/$WS_LIB_REV/scripts/rb/lib/$WS_LIB-$WS_LIB_VERSION.sh"
      curl -fsSL --max-time 60 -o "$f.$$" "$u" 2>/dev/null && ws_lib_ok "$f.$$" && mv -f "$f.$$" "$f"
      rm -f "$f.$$"
    fi
  fi
  ws_lib_ok "$f" || { [ -z "$t" ] || rm -rf -- "$t"; echo "[FAIL] $WS_LIB $WS_LIB_VERSION ($WS_LIB_SHA256) unavailable or altered: no verdict" >&2; exit 2; }
  # 1.1.0 and later mount this file into the build container (WS_LIB_PATH)
  # and remove a temporary folder on exit; for 1.0.0 it goes now.
  WS_LIB_PATH="$f" WS_LIB_TMP="$t"
  . "$f"
  [ -z "$t" ] || [ -n "${WS_LIB_MOUNT:-}" ] || rm -rf -- "$t"
  [ "${WS_LIB_LOADED_VERSION:-}" = "$WS_LIB_VERSION" ] || { echo "[FAIL] $f holds ${WS_LIB_LOADED_VERSION:-no version}, not $WS_LIB_VERSION: no verdict" >&2; exit 2; }
  echo "Library: $WS_LIB $WS_LIB_VERSION sha256: $WS_LIB_SHA256"
}
ws_lib_load


APP_ID="one.mixin.messenger"
REPO_URL="https://github.com/MixinNetwork/android-app"
# Pins copied from upstream verify-mixin-apk.sh at v6.2.2 (PR #6546 / #6610).
BUILD_IMAGE="docker.io/mingc/android-build-box@sha256:de4a27cbc13a22563f82e93fde01c7366a5cda2c8ff113353d3e24e75c9ae8b6"
BUNDLETOOL_VERSION="1.18.3"
BUNDLETOOL_SHA256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
APKTOOL_URL="https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar"
APKTOOL_SHA256="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"
BUILDLOCK_REV="6eb3c49f860de9b6fbe152cb0c71dd9a4413a979"
BUILDLOCK_SHA256="fc1d41a45cd1fb455edab9478078c827937761c85966272f4487930f718f8812"

log_info()    { ws_info "$@"; }
log_success() { ws_ok "$@"; }
log_warn()    { ws_warn "$@"; }
log_error()   { ws_error "$@"; }
banner()  { ws_section "$*"; }
section() { echo ""; echo "--- $* ---"; }
sha256of() { ws_sha256 "$1"; }
nov() { ws_no_verdict "$1"; }   # runtime, network, tool or input-file problem: no YAML
inv() { ws_invalid "$1"; }      # invalid parameters: exit 2, no YAML
ftbfs() { ws_error "$1"; ws_write_yaml ftbfs "$2" ${YAML_HASHES[@]+"${YAML_HASHES[@]}"}; exit 1; }   # the source itself does not build this artifact

ws_refuse_root
ws_install_traps

version_arg=""; binary_arg=""; arch_arg=""; type_arg=""; flavor="googlePlay"

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME [--binary <apk | directory of Play splits>] [--version <x.y.z>] [--flavor googlePlay|otherChannel] [--arch a] [--type t]

  --binary   Official artifact: the GitHub release APK, or a directory holding a Play
             split set (base.apk + split_config.<abi>.apk). If omitted, the GitHub
             release asset mixin-android-<version>.apk is downloaded.
  --version  Release version without the v prefix (tag v<version>). Read from the
             artifact when omitted; when nothing is given the latest GitHub release is used.
  --flavor   Gradle product flavor to build; default googlePlay.
  --arch     ABI to check against the artifact (e.g. arm64-v8a); a mismatch is invalid input.
  --type     accepted and ignored.
USAGE
}
while [[ $# -gt 0 ]]; do
    case $1 in
        --version) ws_require_value --version "${2:-}"; version_arg="$2"; shift 2 ;;
        --binary|--apk) ws_require_value "$1" "${2:-}"; binary_arg="$2"; shift 2 ;;
        --flavor)  ws_require_value --flavor "${2:-}";  flavor="$2";      shift 2 ;;
        --arch)    ws_require_value --arch "${2:-}";    arch_arg="$2";    shift 2 ;;
        --type)    ws_require_value --type "${2:-}";    type_arg="$2";    shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) log_warn "Unknown parameter ignored: $1"; shift ;;
    esac
done
[[ -n "$type_arg" ]] && log_info "--type ${type_arg} accepted but not used"
[[ -z "$version_arg" || "$version_arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || inv "--version must be x.y.z (got ${version_arg})"
case "$flavor" in googlePlay|otherChannel) ;; *) inv "--flavor must be googlePlay or otherChannel (got ${flavor})" ;; esac
FLAVOR_CAP="${flavor^}"   # GooglePlay / OtherChannel

ws_results_init
ws_engine
# Rootless podman with cgroupfs cannot set memory limits: --memory (MEM_LIMIT, default 24g) is docker only.
MEM_ARGS=(); YAML_HASHES=()
if [[ "$WS_ENGINE" == docker ]]; then MEM_LIMIT="${MEM_LIMIT-24g}"; [[ -z "$MEM_LIMIT" ]] || MEM_ARGS=(--memory="$MEM_LIMIT"); fi

banner "PRE-FLIGHT: HOST TOOL CHECK"
printf "  %-12s OK  (%s)\n" "$WS_ENGINE" "$(command -v "$WS_ENGINE")"
command -v curl &>/dev/null || nov "curl not found in PATH"
printf "  %-12s OK  (%s)\n" "curl" "$(command -v curl)"
echo "  Host requirement satisfied."

CTR_BASE="ws-mixinandroid-${WS_RUN_ID}"
for c in meta build lock render cmp; do ws_track_container "${CTR_BASE}-${c}"; done
WS_CHOWN_IMAGE="$BUILD_IMAGE"   # docker hand-back uses the pinned image; it is never removed
ws_workspace mixinandroid "${version_arg:-artifact}"
workspace="$WS_WORKDIR"
DL_DIR="${workspace}/official"; META_DIR="${workspace}/metadata"
SRC_DIR="${workspace}/source"; BUILD_DIR="${workspace}/built"
GRADLE_HOME="${workspace}/gradle-home"; CMP_DIR="${workspace}/comparison"
TOOLS_DIR="${workspace}/tools"; ctx="${workspace}/ctx"; BL_DIR="${workspace}/build-lock"
mkdir -p "$DL_DIR" "$META_DIR" "$SRC_DIR" "$BUILD_DIR" "$GRADLE_HOME" "$CMP_DIR" "$TOOLS_DIR" "$ctx" "$BL_DIR"

banner "MIXIN MESSENGER (ANDROID) REPRODUCIBLE BUILD VERIFICATION"
echo "  Script:    ${SCRIPT_NAME} ${SCRIPT_VERSION}"
echo "  App ID:    ${APP_ID}"
echo "  Flavor:    ${flavor} (:app:bundle${FLAVOR_CAP}Release rendered with bundletool ${BUNDLETOOL_VERSION})"
echo "  Image:     ${BUILD_IMAGE}"
echo "  Runtime:   ${WS_ENGINE} ($(ws_ctr --version 2>&1 | head -1 || true))"
echo "  Workspace: ${workspace}"
echo "  Date:      $(date)"

# OFFICIAL ARTIFACT(S) -------------------------------------------------------
banner "OFFICIAL ARTIFACT"
declare -a OFFICIAL=()      # absolute paths; OFFICIAL[0] is the base/universal APK
mode=""                     # universal | splits
if [[ -n "$binary_arg" ]]; then
    [[ -e "$binary_arg" ]] || inv "--binary path does not exist: ${binary_arg}"
    binary_arg=$(realpath "$binary_arg")
    if [[ -d "$binary_arg" ]]; then
        single=$(find "$binary_arg" -maxdepth 1 -type f -name '*.apk' | head -2 || true)
        if [[ ! -f "${binary_arg}/base.apk" && -n "$single" && $(wc -l <<<"$single") -eq 1 ]]; then
            binary_arg="$single"   # a directory holding one APK is the single-artifact case
        fi
    fi
    if [[ -d "$binary_arg" ]]; then
        mode="splits"
        [[ -f "${binary_arg}/base.apk" ]] || inv "--binary directory has no base.apk: ${binary_arg}"
        OFFICIAL+=("${binary_arg}/base.apk")
        while IFS= read -r f; do OFFICIAL+=("$f"); done < <(find "$binary_arg" -maxdepth 1 -type f -name 'split_config.*.apk' | sort)
        [[ ${#OFFICIAL[@]} -gt 1 ]] || inv "No split_config.*.apk next to base.apk; a single APK must be passed as a file"
        # Only ABI splits exist for this app (language/density splits are disabled in the bundle config).
        for f in "${OFFICIAL[@]:1}"; do
            case "$(basename "$f")" in
                split_config.arm64_v8a.apk|split_config.armeabi_v7a.apk|split_config.x86_64.apk) ;;
                *) inv "Unsupported split $(basename "$f"); this app only ships ABI splits" ;;
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
        ws_fetch "https://api.github.com/repos/MixinNetwork/android-app/releases/latest" "${DL_DIR}/latest.json"
        rel_tag=$(grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' "${DL_DIR}/latest.json" | sed -E 's/.*"([^"]+)"$/\1/' | head -1 || true)
        [[ -n "$rel_tag" ]] || nov "Could not resolve the latest GitHub release; pass --version or --binary"
        log_info "No --version given; latest GitHub release is ${rel_tag}"
    fi
    apk_url="${REPO_URL}/releases/download/${rel_tag}/mixin-android-${rel_tag#v}.apk"
    dl="${DL_DIR}/mixin-android-${rel_tag#v}.apk"
    log_info "Downloading ${apk_url}"
    ws_fetch "$apk_url" "$dl"
    OFFICIAL+=("$dl"); downloaded=1
    log_success "Downloaded $(basename "$dl") ($(stat -c%s "$dl") bytes)"
fi
for f in "${OFFICIAL[@]}"; do printf '  %-28s %s  %s bytes\n' "$(basename "$f")" "$(sha256of "$f")" "$(stat -c%s "$f")"; done
app_hash=$(sha256of "${OFFICIAL[0]}")
[[ -z "${downloaded:-}" ]] || YAML_HASHES=("$app_hash")   # ABS publishes a --version run by this hash

# Bind-mount the official APKs read-only under /official/<basename>.
OFF_MOUNTS=(); for f in "${OFFICIAL[@]}"; do OFF_MOUNTS+=(-v "${f}:/official/$(basename "$f"):ro"); done
BASE_NAME="$(basename "${OFFICIAL[0]}")"
[[ "$BASE_NAME" =~ ^[A-Za-z0-9._+-]+\.apk$ ]] || inv "official APK file name may only use A-Z a-z 0-9 . _ + -: ${BASE_NAME}"

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
[[ -n "$signer" ]] || { echo "ERROR: no signer certificate read from ${BASE_NAME}"; exit 1; }
: > /out/stamped; grep -q 'Verified for SourceStamp: true' <<<"$sig" && echo "${BASE_NAME}" >> /out/stamped
for other in /official/*.apk; do
    [[ "$other" == "$apk" ]] && continue
    n2=$(basename "$other"); sig2=$("$BT/apksigner" verify --verbose --print-certs "$other" 2>&1) || { echo "ERROR: signature verification failed for ${n2}"; exit 1; }
    s2=$(sed -nE 's/^Signer( #[0-9]+| \(minSdkVersion=[^)]*\))? certificate SHA-256 digest: //p' <<<"$sig2" | sort -u | paste -sd, -)
    [[ "$s2" == "$signer" ]] || { echo "ERROR: ${n2} signed by ${s2:-nobody}, base by ${signer}"; exit 1; }
    st2=$(sed -nE 's/^Source Stamp Signer certificate DN: //p' <<<"$sig2" | head -1)
    [[ "$st2" == "$stamp" ]] || { echo "ERROR: ${n2} SourceStamp '${st2:-none}' differs from the base's '${stamp:-none}'"; exit 1; }
    b2=$("$BT/aapt2" dump badging "$other" 2>/dev/null | head -1)
    [[ "$b2" == *"name='${pkg}'"* && "$b2" == *"versionCode='${vcode}'"* ]] || { echo "ERROR: ${n2} is not ${pkg} versionCode ${vcode}: ${b2}"; exit 1; }
    x="${n2#split_}"; [[ "$n2" != split_config.* || "$b2" == *"split='${x%.apk}'"* ]] || { echo "ERROR: ${n2} declares another split: ${b2}"; exit 1; }
    grep -q 'Verified for SourceStamp: true' <<<"$sig2" && echo "$n2" >> /out/stamped
    echo "[META] ${n2}: same package, versionCode, signer and SourceStamp"
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
ws_ctr run --rm --name "${CTR_BASE}-meta" "${OFF_MOUNTS[@]}" -v "${META_DIR}:/out" -v "${ctx}/meta.sh:/meta.sh:ro" \
    "$BUILD_IMAGE" bash /meta.sh || nov "Phase 0 metadata extraction failed"
pkg_id=$(cat "$META_DIR/pkg"); wallet_version=$(cat "$META_DIR/vname"); version_code=$(cat "$META_DIR/vcode")
signer=$(cat "$META_DIR/signer"); abis=$(cat "$META_DIR/abis"); stamp=$(cat "$META_DIR/stamp"); min_sdk=$(cat "$META_DIR/minsdk"); official_rev=$(cat "$META_DIR/vcs_rev")
[[ "$pkg_id" == "$APP_ID" ]] || nov "APK app ID mismatch: expected ${APP_ID}, got ${pkg_id}"
[[ -n "$wallet_version" ]] || nov "Could not derive versionName from the official APK"
if [[ -n "$version_arg" && "$version_arg" != "$wallet_version" ]]; then
    inv "Requested --version ${version_arg} but the official APK reports ${wallet_version}"
fi
if [[ "$mode" == "universal" && "$abis" != *arm64-v8a*armeabi-v7a*x86_64* ]]; then
    log_warn "Universal APK expected three ABIs, found: ${abis}"
fi
[[ "$wallet_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$version_code" =~ ^[0-9]+$ ]] || nov "Unexpected versionName '${wallet_version}' or versionCode '${version_code}' in the official APK"
[[ -z "$official_rev" || "$official_rev" =~ ^[0-9a-f]{40}$ ]] || nov "Unexpected source revision '${official_rev}' in the official APK"
if [[ -n "$arch_arg" ]]; then
    if [[ "$mode" == "splits" ]]; then [[ -f "${binary_arg}/split_config.${arch_arg//-/_}.apk" ]] || inv "--arch ${arch_arg}: the split set has no split_config.${arch_arg//-/_}.apk"
    else [[ " ${abis} " == *" ${arch_arg} "* ]] || inv "--arch ${arch_arg}: the APK ships ${abis}"; fi
    log_success "--arch ${arch_arg} present in the artifact"
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
tag_type=$(git cat-file -t "refs/tags/${tag}" 2>/dev/null || echo unknown); printf '%s\n' "$tag_type" > /out/tag_type.txt
echo "[BUILD] ${tag} = ${tag_commit} (${tag_type} object)"
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
st=("${PIPESTATUS[@]}"); rc=${st[0]}
[[ "${st[1]}" -eq 0 ]] || { echo "[BUILD] ERROR: tee exit ${st[1]}, Gradle log not written"; exit 90; }
aab=$(ls app/build/outputs/bundle/*Release/*.aab 2>/dev/null | head -1)
if [[ "$rc" -ne 0 || -z "$aab" ]]; then echo "[BUILD] gradle exit ${rc}, aab: ${aab:-none}"; tail -40 /out/gradle.log; exit 1; fi
cp "$aab" /out/app.aab; sha256sum /out/app.aab
BUILD
sed -i -e "s/__FLAVOR__/${FLAVOR_CAP}/g" -e "s/__TAG__/${tag}/g" -e "s/__VERSION__/${wallet_version}/g" \
    -e "s/__VCODE__/${version_code}/g" -e "s|__REPO__|${REPO_URL}|g" -e "s/__OFFREV__/${official_rev}/g" "$ctx/build.sh"
build_rc=0
ws_ctr run --rm --name "${CTR_BASE}-build" ${MEM_ARGS[@]+"${MEM_ARGS[@]}"} \
    -v "${SRC_DIR}:/project" -v "${META_DIR}:/inputs:ro" -v "${GRADLE_HOME}:/gradle-home" -v "${BUILD_DIR}:/out" \
    -v "${ctx}/build.sh:/build.sh:ro" "$BUILD_IMAGE" bash /build.sh || build_rc=$?
case "$build_rc" in
    0) ;;
    7) nov "Clone of ${tag} failed (see output above)" ;;
    9) nov "git cannot read the checkout in /project (ownership or permissions, see output above)" ;;
    8) nov "Source at ${tag} does not declare version ${wallet_version}; source and artifact identity unresolved" ;;
    90) nov "Gradle log not written (tee failed)" ;;
    1) kind=$(ws_gradle_failure_kind "$BUILD_DIR/gradle.log")
       [[ "$kind" == source ]] || nov "Gradle build failed, cause ${kind} (exit ${build_rc}; see ${BUILD_DIR}/gradle.log)"
       ftbfs "Gradle build failed with a source diagnostic (see ${BUILD_DIR}/gradle.log)" "Gradle :app:bundle${FLAVOR_CAP}Release failed with a compiler or resource error at ${tag}" ;;
    *) nov "Build container failed (exit ${build_rc})" ;;
esac
[[ -f "$BUILD_DIR/app.aab" ]] || nov "Build finished without an AAB"
commit=$(cat "$BUILD_DIR/commit.txt"); version_build_note=$(cat "$BUILD_DIR/version_build_note.txt"); tag_type=$(cat "$BUILD_DIR/tag_type.txt" 2>/dev/null || echo unknown)
source_note=$(paste -sd'|' "$BUILD_DIR/source_note.txt" | sed 's/|/; /g')
[[ "$version_build_note" == *patched* ]] && log_warn "$version_build_note"
[[ "$source_note" == *WARNING* || "$source_note" == *patched* ]] && log_warn "$source_note"
log_success "Checked out ${tag} = ${commit}; AAB built: $(sha256of "$BUILD_DIR/app.aab")"

section "BUILD RECORD (ws-buildlock, verdict unaffected)"
BUILD_LOCK_FILE=""; BL_SH="${TOOLS_DIR}/ws-buildlock.sh"; bl_rc=0
if curl -fsSL --max-time 60 -o "$BL_SH" "https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/${BUILDLOCK_REV}/scripts/rb/ws-buildlock.sh" < /dev/null \
   && [[ "$(ws_sha256 "$BL_SH")" == "$BUILDLOCK_SHA256" ]]; then
    ws_ctr run --rm --name "${CTR_BASE}-lock" -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
        -v "${GRADLE_HOME}:/gradle-home:ro" -v "${SRC_DIR}:/project:ro" -v "${BL_DIR}:/build-lock" -v "${BL_SH}:/ws-buildlock.sh:ro" \
        "$BUILD_IMAGE" bash /ws-buildlock.sh --out /build-lock --gradle-home /gradle-home --src /project --app-id "$APP_ID" \
        --version "$wallet_version" --platform android --commit "$commit" > "${workspace}/build-lock.log" 2>&1 || bl_rc=$?
    if [[ "$bl_rc" -eq 0 && -s "${BL_DIR}/build-lock.json" ]] && ! grep -q 'nothing recorded' "${workspace}/build-lock.log"; then
        bl_n=$(grep -o '"ecosystem": *"gradle"' "${BL_DIR}/build-lock.json" | wc -l || true)
        if [[ "${bl_n:-0}" -gt 0 ]]; then BUILD_LOCK_FILE="${BL_DIR}/build-lock.json"
            log_success "build-lock.json: ${BUILD_LOCK_FILE} (${bl_n} Gradle artifacts, sha256 $(ws_sha256 "$BUILD_LOCK_FILE"))"
        else log_warn "build-lock.json lists no Gradle artifacts; not offered for upload; verdict unaffected."; fi
    else
        log_warn "No build-lock.json (exit ${bl_rc}; see ${workspace}/build-lock.log); verdict unaffected."
    fi
else
    log_warn "build-lock skipped: no ws-buildlock.sh with the expected sha256; verdict unaffected."
fi

section "Rendering APKs with bundletool ${BUNDLETOOL_VERSION} (${mode})"
bt_jar="${TOOLS_DIR}/bundletool-all-${BUNDLETOOL_VERSION}.jar"
ws_fetch "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar" "$bt_jar" "$BUNDLETOOL_SHA256"
if [[ "$mode" == "universal" ]]; then bt_mode="--mode=universal"; else bt_mode="--mode=default"; fi
ws_ctr run --rm --name "${CTR_BASE}-render" -v "${TOOLS_DIR}:/tools:ro" -v "${BUILD_DIR}:/out" "$BUILD_IMAGE" bash -c "
    set -e; cd /out; rm -rf rendered; mkdir rendered
    java -jar /tools/$(basename "$bt_jar") build-apks --bundle=/out/app.aab --output=/out/rendered.apks ${bt_mode} --overwrite
    cd rendered && unzip -q -o ../rendered.apks && find . -name '*.apk' | sort | sed 's|^\./||' > list.txt && cat list.txt
    BT=\$(ls -d \"\${ANDROID_HOME}/build-tools\"/* | sort -V | tail -1); : > variants.txt
    for a in \$(grep '^splits/' list.txt); do
        m=\$(\"\$BT/aapt2\" dump xmltree --file AndroidManifest.xml \"\$a\" 2>/dev/null | grep -oE 'minSdkVersion\\([^)]*\\)=[0-9]+' | grep -oE '[0-9]+\$' | head -1)
        echo \"\$a \${m:-?}\" >> variants.txt
    done" \
    || nov "bundletool build-apks failed"
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
            || nov "bundletool produced no ${stem} variant with minSdkVersion ${min_sdk} for ${n} (see built/rendered/variants.txt)"
        PAIRS+=("${n}|${r}")
    done
fi
for p in "${PAIRS[@]}"; do printf '  %-28s <-> %s\n' "${p%%|*}" "${p##*|}"; done

# PHASE 2: COMPARISON ---------------------------------------------------------
banner "PHASE 2: CONTENTS COMPARISON (${#PAIRS[@]} artifact(s))"
echo "  Signing material and the Play SourceStamp are excluded; resources.arsc and"
echo "  AndroidManifest.xml are judged on their decoded form (WS #574)."
echo "  Started: $(date)"
ws_fetch "$APKTOOL_URL" "${TOOLS_DIR}/apktool.jar" "$APKTOOL_SHA256"
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
    # Official-only signing files, and the stamp file if it is one 32-byte root entry and apksigner verified
    # the SourceStamp (phase 0), are excluded; each counts as raw + acceptable. A built file at the path stays.
    ex=0; xl=""; sok=0; sg=0
    grep -Fqx -- "$off" /stamped && [[ $(unzip -Z1 "/official/${off}" | grep -cx stamp-cert-sha256) -eq 1 ]] && sok=1
    while IFS= read -r f; do r="${f#"$o"/}"; [[ -e "$b/$r" || ( "$r" == stamp-cert-sha256 && $sok -ne 1 ) ]] && continue
        rm -f -- "$f" || exit 3; ex=$((ex+1)); [[ "$r" == META-INF/* ]] && sg=1; xl+="Only in $(dirname "$f"): $(basename "$f")"$'\n'
        echo "  excluded (official-only): ${r}"; echo "${off}: official-only ${r} excluded" >> /out/acceptable.txt
    done < <(find "$o" -maxdepth 2 -type f \( -path "$o/META-INF/*" \( -iname '*.RSA' -o -iname '*.DSA' -o -iname '*.EC' -o -iname '*.SF' -o -iname 'MANIFEST.MF' \) -o -path "$o/stamp-cert-sha256" -size 32c \))
    [[ $sg -eq 0 || -d "$b/META-INF" ]] || rmdir "$o/META-INF" 2>/dev/null || true
    echo "  files: $(find "$o" -type f | wc -l) official, $(find "$b" -type f | wc -l) built"
    diff -rq "$o" "$b" > /tmp/raw.txt 2>&1; rc=$?
    if [[ $rc -ne 0 && $rc -ne 1 ]]; then echo "ERROR: diff exit ${rc}"; head -20 /tmp/raw.txt; exit 3; fi
    unparsed=$(grep -vE '^(Files|Only in)' /tmp/raw.txt | grep -v '^$' || true)
    [[ -z "$unparsed" ]] || { echo "ERROR: unrecognised diff output"; printf '%s\n' "$unparsed" | head -20; exit 3; }
    cnt=$(grep -E '^(Files|Only in)' /tmp/raw.txt || true)
    raw=$(printf '%s\n' "$cnt" | grep -c . || true); raw=${raw:-0}
    [[ $rc -eq 1 && $raw -eq 0 ]] && { echo "ERROR: diff reported differences but none were parsed"; exit 3; }
    raw=$((raw+ex)); echo "  raw differences: ${raw} (${ex} official-only signing/stamp file(s) excluded)"
    all=$(printf '%s%s\n' "$xl" "$cnt" | grep . || true)
    printf '%s\n' "$all" | sed "s|/tmp/o-${tag}/||;s|/tmp/b-${tag}/||" | head -5 | sed 's/^/    /'
    [[ $raw -gt 5 ]] && echo "    ... full list: comparison/diff_full.txt"
    { echo "## ${off}"; printf '%s\n' "$all"; } >> /out/diff_full.txt
    acc=$ex; mat=0; decoded=0
    decode_both() {   # apktool failure is a tool error: exit 3, no verdict
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
                [[ $drc -le 1 ]] || { echo "ERROR: decoded res/ diff failed (exit ${drc})"; exit 3; }
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
                [[ $drc -le 1 ]] || { echo "ERROR: manifest diff failed (exit ${drc})"; exit 3; }
                # Google Play stamps the manifest of everything it serves (stamp.source, stamp.type,
                # vending.derived.apk.id); a rebuild cannot carry those. Any other changed line is material.
                changed=$(grep -E '^[-+][^-+]' "$mf" || true)
                # Official side only: drop these exact Play lines. Both: collapse a childless element (config splits).
                norm() { if [[ $2 == o ]]; then grep -vE '^[[:space:]]*<meta-data android:name="com\.android\.(stamp\.source" android:value="https://play\.google\.com/store|stamp\.type" android:value="STAMP_TYPE_(DISTRIBUTION|STANDALONE)_APK|vending\.derived\.apk\.id" android:value="[0-9]+)"/>$' "$1"; else cat "$1"; fi | awk '
                    { if (held != "") { if ($0 ~ ("^[ \t]*</" tag ">$")) { sub(/>$/, "/>", held); print held; held = ""; next }
                                        print held; held = "" }
                      if (match($0, /^[ \t]*<[A-Za-z][A-Za-z0-9_.:-]*( [^>]*[^\/?])?>$/)) { held = $0; tag = $0; sub(/^[ \t]*</, "", tag); sub(/[ \t>].*$/, "", tag); next }
                      print } END { if (held != "") print held }'; }
                norm /tmp/do/AndroidManifest.xml o > /tmp/no.txt && norm /tmp/db/AndroidManifest.xml b > /tmp/nb.txt || { echo "ERROR: manifest normalization failed"; exit 3; }
                diff /tmp/no.txt /tmp/nb.txt > /tmp/mn.txt; nrc=$?
                [[ $nrc -le 1 ]] || { echo "ERROR: normalized manifest diff failed (exit ${nrc})"; exit 3; }
                rest=$(grep -E '^[<>]' /tmp/mn.txt || true)
                if [[ $drc -eq 0 ]]; then
                    echo "  AndroidManifest.xml: binary differs, decoded XML IDENTICAL, acceptable"; acc=$((acc+1))
                    echo "${off}: AndroidManifest.xml binary differs, decoded XML identical" >> /out/acceptable.txt
                elif [[ $drc -eq 1 && $nrc -eq 0 ]]; then
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
cmp_rc=0
ws_ctr run --rm --name "${CTR_BASE}-cmp" "${OFF_MOUNTS[@]}" -v "${BUILD_DIR}:/built:ro" -v "${TOOLS_DIR}:/tools:ro" \
    -v "${CMP_DIR}:/out" -v "${ctx}/compare.sh:/compare.sh:ro" -v "${ctx}/pairs.txt:/pairs.txt:ro" -v "${META_DIR}/stamped:/stamped:ro" \
    "$BUILD_IMAGE" bash /compare.sh 2>&1 | tee "$CMP_DIR/comparison.log" || cmp_rc=$?
[[ "$cmp_rc" -eq 0 && -s "$CMP_DIR/summary.txt" ]] || nov "Comparison phase failed (tool error, exit ${cmp_rc})"
raw_total=$(sed -nE 's/^raw_total=([0-9]+)$/\1/p' "$CMP_DIR/summary.txt"); acc_count=$(sed -nE 's/^acceptable=([0-9]+)$/\1/p' "$CMP_DIR/summary.txt")
mat_count=$(sed -nE 's/^material=([0-9]+)$/\1/p' "$CMP_DIR/summary.txt")
[[ "$raw_total" =~ ^[0-9]+$ && "$acc_count" =~ ^[0-9]+$ && "$mat_count" =~ ^[0-9]+$ ]] || nov "Comparison summary unreadable (${CMP_DIR}/summary.txt)"

section "VERDICT (judged on non-signature diffs across all artifacts)"
echo "  Raw differences:              ${raw_total:-?}"
echo "  Acceptable per WS #574:       ${acc_count:-?}"
echo "  Material (verdict-bearing):   ${mat_count}"
echo "  Acceptable-diffs policy: https://gitlab.com/walletscrutiny/walletScrutinyCom/-/issues/574"
if [[ "$mat_count" -eq 0 ]]; then VERDICT="reproducible"; log_success "Verdict: REPRODUCIBLE (0 material diffs; ${acc_count} acceptable)"
else VERDICT="not_reproducible"; log_error "Verdict: NOT_REPRODUCIBLE (${mat_count} material diff(s))"; fi

built_hash=$(sha256of "$BUILD_DIR/rendered/${PAIRS[0]##*|}")
diff_lines="${CMP_DIR}/diff_lines.txt"
awk '/^## /{a=substr($0,4); next} /^(Files|Only in)/{gsub(/\/tmp\/o-[^\/ :]+/,"o"); gsub(/\/tmp\/b-[^\/ :]+/,"b"); print a ": " $0}' \
    "$CMP_DIR/diff_full.txt" > "$diff_lines" || nov "cannot read ${CMP_DIR}/diff_full.txt"
diff_n=$(wc -l < "$diff_lines")
diff_text="$(
    if [[ "$diff_n" -eq 0 ]]; then echo "(no differing entries)"; else sed -n 1,5p "$diff_lines"
        [[ "$diff_n" -le 5 ]] || echo "    ... $((diff_n - 5)) more line(s); full list: ${CMP_DIR}/diff_full.txt"; fi
    echo ""
    echo "Revision, tag (and its signature):"
    echo "Tag: ${tag} ($(case "$tag_type" in tag) echo "annotated, signature not checked" ;; commit) echo "lightweight, no signature possible" ;; *) echo "$tag_type" ;; esac))"
    echo "Built from: ${source_note}"
)"
echo ""
ws_results_block "$APP_ID" "$signer" "$wallet_version" "$version_code" "$VERDICT" "$app_hash" "$commit" "$diff_text"
echo ""
echo "builtHash:       ${built_hash}"
echo "variant:         ${flavor} flavor, :app:bundle${FLAVOR_CAP}Release, bundletool ${BUNDLETOOL_VERSION} ${mode}"
echo "image:           ${BUILD_IMAGE} (${WS_ENGINE})"
echo "artifacts:       ${#PAIRS[@]} ($(paste -sd' ' "$CMP_DIR/per_artifact.txt"))"
echo "diffs:           raw ${raw_total} (incl. official-only signing/stamp files), acceptable ${acc_count} (WS #574; listed in ${CMP_DIR}/acceptable.txt), material ${mat_count}"
echo "excluded:        META-INF signing files, stamp-cert-sha256 and stamp meta-data (Play SourceStamp${stamp:+, signer $stamp})"
echo "buildInputs:     google-services.json + manifest API keys rebuilt from the official APK"
echo "versionBuild:    ${version_build_note}"
echo "workspace:       ${workspace}"
if [[ -n "$BUILD_LOCK_FILE" ]]; then echo "Upload with the verification: ${BUILD_LOCK_FILE} (sha256 $(ws_sha256 "$BUILD_LOCK_FILE"))"; fi
echo ""
ws_write_yaml "${VERDICT}" "Source-built ${flavor} AAB rendered with bundletool ${BUNDLETOOL_VERSION} (${mode}) vs official: ${raw_total} raw difference(s) over ${#PAIRS[@]} artifact(s), of which ${acc_count} acceptable per WS #574 and ${mat_count} material. Official ${app_hash}; built ${built_hash}. google-services.json and manifest API keys were rebuilt from values found in the official APK; ${version_build_note}; source: ${source_note}." ${YAML_HASHES[@]+"${YAML_HASHES[@]}"}
[[ "$VERDICT" == "reproducible" ]] && exit 0
exit 1
