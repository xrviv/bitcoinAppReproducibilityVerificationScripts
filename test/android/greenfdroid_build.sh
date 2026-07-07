#!/bin/bash
# ==============================================================================
# greenfdroid_build.sh - Blockstream Green F-Droid Reproducible Build Verification
# ==============================================================================
# Version:       v0.2.5
# Organization:  WalletScrutiny.com
# Last Modified: 2026-07-07
# Project:       https://github.com/Blockstream/green_android
# F-Droid:       https://f-droid.org/packages/com.greenaddress.greenbits_android_wallet/
# License:       MIT
# Changelog + design rationale: ws-notes/script-notes/android/com.greenaddress.greenbits_android_wallet/changelog.md
# ==============================================================================
# Verifies the F-Droid distribution: compiles GDK from source (like F-Droid;
# Play Store ships a prebuilt GDK), builds the APK, compares with apksigcopier.
# The fdroiddata recipe is the source of truth: its commit: is built, its build
# block must sha256-match the audited EXPECTED_RECIPE_SHA256 (any change =>
# exit 2, re-audit), and the release tag is cross-checked for provenance.
#
# Env must match F-Droid's build servers (see changelog for the 5.4.0 Build ID
# root cause): Debian Trixie; user vagrant; checkout path
# /home/vagrant/build/com.greenaddress.greenbits_android_wallet/ (clone into
# ".", no subdir); SDK/NDK at /opt/android-sdk (path feeds the Build ID);
# NDK r26b; JDK 21; Rust from gdk Dockerfile; SOURCE_DATE_EPOCH from commit.
# Deviations from literal fdroidserver: patch 5 +4d (recipe's +3d orphans a
# brace); apt packages unpinned. GDK cloned full + tag checkout (srclib-equiv).
# GDK compile ~30-60 min first run; Docker layers cached after.
# ==============================================================================

set -euo pipefail

# ----------------------------------------
# Constants
# ----------------------------------------
SCRIPT_VERSION="v0.2.5"
APP_ID="com.greenaddress.greenbits_android_wallet"
REPO_URL="https://github.com/Blockstream/green_android.git"
GDK_REPO_URL="https://github.com/Blockstream/gdk.git"
WS_CONTAINER="docker.io/walletscrutiny/android:5"
FDROID_RECIPE_URL="https://gitlab.com/fdroid/fdroiddata/-/raw/master/metadata/com.greenaddress.greenbits_android_wallet.yml"
# sha256 of the recipe build block minus blank + versionName/versionCode/commit
# lines; recompute with the guard pipeline below after re-auditing a change.
EXPECTED_RECIPE_SHA256="bd2b5c1324b1cebfb17591b7bf79ff247f9ad14eff58dd1eb2a6ab7356cd4baf"
ENV_VALIDATED_THROUGH_CODE="22000525"  # newest env-validated versionCode
APP_COMMIT=""                          # resolved at runtime from the F-Droid recipe

EXIT_SUCCESS=0
EXIT_FAILED=1
EXIT_INVALID=2

execution_dir="$(pwd)"
script_name="$(basename "$0")"

should_cleanup=false
downloaded_apk=""
requested_version=""
requested_arch="universal"
requested_type=""

version_name=""
version_code=""
additional_info=""

work_dir=""
build_image_tag=""
build_container_name=""
built_apk=""
_run_id=""
_staging_tag=""

# ----------------------------------------
# Logging
# ----------------------------------------
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }

append_additional_info() {
  local line="$1"
  if [[ -n "${additional_info}" ]]; then
    additional_info="${additional_info}
${line}"
  else
    additional_info="${line}"
  fi
}

die_invalid() {
  log_error "$*"
  echo "Exit code: ${EXIT_INVALID}"
  exit "${EXIT_INVALID}"
}

die_failed() {
  log_error "$*"
  generate_error_yaml "ftbfs"
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
}

on_error() {
  local exit_code=$?
  local line_no=$1
  set +e
  log_error "Script failed at line ${line_no} (exit code ${exit_code})"
  if [[ -n "${build_container_name}" ]]; then
    ${CONTAINER_CMD} rm -f "${build_container_name}" 2>/dev/null || true
  fi
  [[ -n "${build_image_tag}" ]] && ${CONTAINER_CMD} rmi "${build_image_tag}" 2>/dev/null || true
  [[ -n "${_staging_tag}" ]] && ${CONTAINER_CMD} rmi "${_staging_tag}" 2>/dev/null || true
  generate_error_yaml "ftbfs"
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
}
trap 'on_error $LINENO' ERR

# ----------------------------------------
# Container runtime detection
# ----------------------------------------
CONTAINER_CMD=""
VOLUME_RO_SUFFIX=""
VOLUME_RW_SUFFIX=""

if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD="podman"
  VOLUME_RO_SUFFIX=":ro,Z"
  VOLUME_RW_SUFFIX=":Z"
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD="docker"
  VOLUME_RO_SUFFIX=":ro"
  VOLUME_RW_SUFFIX=""
else
  die_invalid "Neither podman nor docker found. Install one to continue."
fi

# ----------------------------------------
# Usage
# ----------------------------------------
usage() {
  cat <<EOF
NAME
       ${script_name} ${SCRIPT_VERSION} - Blockstream Green F-Droid reproducible build verification

SYNOPSIS
       ${script_name} --binary <apk_file> [OPTIONS]

DESCRIPTION
       Builds the F-Droid flavor of Blockstream Green Android from source in
       a Debian Trixie container matching F-Droid's build environment. Version
       is auto-detected from the APK; the fdroiddata recipe supplies the source
       commit (cross-checked against the release_<version> tag) and its build
       block must hash-match the audited recipe before building.

       Compiles GDK from source, applies all F-Droid recipe patches, builds
       the unsigned APK, then compares against the official APK with
       apksigcopier --unsigned. Captures linker commands, pre-strip .so and
       .syms per ABI for Build ID diagnostics.

       First run: 30-60 min (GDK C++/Rust compilation).
       Subsequent runs: ~5 min (Docker layer cache reused).

OPTIONS
       --binary <file>      Path to the official F-Droid APK (required).
       --apk <file>         Alias for --binary.
       --version <version>  Optional override (auto-detected from APK).
       --arch <arch>        Arch label for YAML output (default: universal).
       --type <type>        Accepted for build server compatibility.
       --cleanup            Remove work directory and Docker image after completion.
       --script-version     Print script version and exit.
       --help               Show this help and exit.

EXIT CODES
       0    Reproducible (apksigcopier verifies)
       1    Not reproducible or build failure
       2    Invalid parameters

EXAMPLES
       ${script_name} --binary ~/Downloads/com.greenaddress.greenbits_android_wallet_22000525.apk
       ${script_name} --binary green.apk --version 5.5.1
EOF
}

# ----------------------------------------
# Argument parsing
# ----------------------------------------
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version)        [[ "$#" -lt 2 ]] && die_invalid "--version requires a value"; requested_version="$2"; shift ;;
    --apk|--binary)   [[ "$#" -lt 2 ]] && die_invalid "--binary requires a value"; downloaded_apk="$2"; shift ;;
    --arch)           [[ "$#" -lt 2 ]] && die_invalid "--arch requires a value"; requested_arch="$2"; shift ;;
    --type)           [[ "$#" -lt 2 ]] && die_invalid "--type requires a value"; requested_type="$2"; shift ;;
    --cleanup)        should_cleanup=true ;;
    --script-version) echo "${script_name} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    --help)           usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    *)                log_warn "Ignoring unknown parameter: $1" ;;
  esac
  shift
done

[[ -z "${downloaded_apk}" ]] && die_invalid "Required: --binary or --apk <path-to-official-fdroid-apk>"
[[ "$(id -u)" -eq 0 ]] && die_invalid "Do not run this script as root."

[[ "${downloaded_apk}" != /* ]] && downloaded_apk="${execution_dir}/${downloaded_apk}"
[[ ! -f "${downloaded_apk}" ]] && die_invalid "APK file not found: ${downloaded_apk}"

log_info "Starting ${script_name} ${SCRIPT_VERSION}"

# ----------------------------------------
# YAML output helpers
# ----------------------------------------
generate_error_yaml() {
  local status="$1"
  cat > "${execution_dir}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${status}
EOF
}

generate_comparison_yaml() {
  local verdict="$1"
  {
    echo "script_version: ${SCRIPT_VERSION}"
    echo "verdict: ${verdict}"
    echo "notes: |"
    echo "  App: ${APP_ID}"
    echo "  Version: ${version_name} (versionCode ${version_code})"
    echo "  Build flavor: productionFDroid (F-Droid distribution)"
    echo "  Build environment: Debian Trixie, username vagrant, cmake 3.31.6+, NDK r26b (26.1.10909125)"
    echo "  Checkout path: /home/vagrant/build/com.greenaddress.greenbits_android_wallet/ (matches fdroidserver)"
    echo "  SOURCE_DATE_EPOCH: derived from app git commit timestamp"
    echo "  Comparison method: apksigcopier compare --unsigned"
    echo "  Expected non-content differences: META-INF/F-Droid signature files (MANIFEST.MF, *.SF, *.RSA)"
    echo "  Deviations from literal fdroidserver: patch5 +4d (recipe +3d orphans a brace); apt packages unpinned"
    if [[ -n "${additional_info}" ]]; then
      while IFS= read -r _ai_line; do
        echo "  ${_ai_line}"
      done <<< "${additional_info}"
    fi
  } > "${execution_dir}/COMPARISON_RESULTS.yaml"
}

# ----------------------------------------
# Build Trixie+vagrant Docker image (inline Dockerfile) — staging tag
# ----------------------------------------
# ----------------------------------------
_run_id="$$-$(date +%s)"
_staging_tag="greenfdroid-build-${_run_id}:staging"

log_info "Building Debian Trixie + vagrant Docker image (tag: ${_staging_tag}; cached after first run)..."

${CONTAINER_CMD} build --tag "${_staging_tag}" - <<'DOCKERFILE'
# Green F-Droid build env: Debian Trixie, user vagrant, NDK r26b, Rust 1.85.0.
# SOURCE_DATE_EPOCH must be set at runtime (git log -1 --format=%ct) before
# prepare_gdk_clang.sh — OpenSSL embeds it as "built on:".

FROM debian:trixie

ARG ANDROID_COMMAND_LINE_TOOLS=commandlinetools-linux-9477386_latest.zip
ARG ANDROID_COMMAND_LINE_TOOLS_SHA256=bd1aa17c7ef10066949c88dc6c9c8d536be27f992a1f3b5a584f9bd2ba5646a0
ARG ANDROID_NDK_VERSION=26.1.10909125
ARG USER_ID=1000
ARG GROUP_ID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_NDK=/opt/android-sdk/ndk/26.1.10909125 \
    ANDROID_NDK_HOME=/opt/android-sdk/ndk/26.1.10909125 \
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
    PATH=/usr/lib/jvm/java-21-openjdk-amd64/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/build-tools/34.0.0:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        autoconf automake bison build-essential ca-certificates clang cmake \
        curl file flex gettext git gperf jq libffi-dev libtool make \
        ninja-build openjdk-21-jdk patch perl pkg-config python3 python3-dev \
        python3-pip python3-virtualenv rsync rustup swig unzip wget xz-utils \
        zip zlib1g-dev \
    && pip3 install --break-system-packages --no-cache-dir apksigcopier==1.1.1 setuptools \
    && rm -rf /var/lib/apt/lists/* \
    && cmake --version \
    && cmake --version | awk 'NR==1{split($3,v,"."); if(v[1]<3||(v[1]==3&&v[2]<19)){print "cmake >= 3.19 required: "$3; exit 1}}'

WORKDIR /opt
RUN curl --fail --location --output "${ANDROID_COMMAND_LINE_TOOLS}" \
        "https://dl.google.com/android/repository/${ANDROID_COMMAND_LINE_TOOLS}" \
    && echo "${ANDROID_COMMAND_LINE_TOOLS_SHA256}  ${ANDROID_COMMAND_LINE_TOOLS}" | sha256sum --check \
    && mkdir -p "${ANDROID_HOME}/cmdline-tools" \
    && unzip -q "${ANDROID_COMMAND_LINE_TOOLS}" -d /tmp/android-command-line-tools \
    && mv /tmp/android-command-line-tools/cmdline-tools "${ANDROID_HOME}/cmdline-tools/latest" \
    && rm "${ANDROID_COMMAND_LINE_TOOLS}" \
    && yes | sdkmanager --licenses >/dev/null

RUN sdkmanager \
        "build-tools;34.0.0" \
        "build-tools;36.0.0" \
        "ndk;${ANDROID_NDK_VERSION}" \
        "platform-tools" \
        "platforms;android-36" \
    && test -x "${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"

RUN groupadd --gid "${GROUP_ID}" vagrant \
    && useradd --create-home --uid "${USER_ID}" --gid "${GROUP_ID}" --shell /bin/bash vagrant \
    && mkdir -p /home/vagrant/build/com.greenaddress.greenbits_android_wallet /output \
    && chown -R vagrant:vagrant /home/vagrant /output

USER vagrant
ENV HOME=/home/vagrant \
    CARGO_HOME=/home/vagrant/.cargo \
    RUSTUP_HOME=/home/vagrant/.rustup \
    GRADLE_USER_HOME=/home/vagrant/.gradle \
    PATH=/home/vagrant/.cargo/bin:/home/vagrant/.local/bin:/usr/lib/jvm/java-21-openjdk-amd64/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/build-tools/34.0.0:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN rustup toolchain install 1.85.0 \
    && rustup default 1.85.0 \
    && rustup target add aarch64-linux-android armv7-linux-androideabi

WORKDIR /home/vagrant/build/com.greenaddress.greenbits_android_wallet
CMD ["/bin/bash"]
DOCKERFILE

log_info "Docker image ready: ${_staging_tag}"

# ----------------------------------------
# Validate APK and extract version using aapt from the build image
# ----------------------------------------
# ----------------------------------------
apk_dir="$(dirname "${downloaded_apk}")"
apk_file="$(basename "${downloaded_apk}")"
filename_version_code="$(basename "${downloaded_apk}" .apk | grep -oE '[0-9]+$' || true)"

# Filename is injected into container bash -c strings — reject unsafe chars.
if [[ "${apk_file}" =~ [^[:alnum:]._-] ]]; then
  die_invalid "APK filename '${apk_file}' contains unsafe characters. Rename it using only alphanumeric, '.', '-', '_'."
fi

log_info "Validating APK metadata with aapt..."
_badge="$(${CONTAINER_CMD} run --rm \
  --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
  "${_staging_tag}" \
  bash -c "aapt dump badging /apk/${apk_file} 2>/dev/null | grep '^package:'" 2>/dev/null || true)"

if [[ -z "${_badge}" ]]; then
  die_invalid "Could not read APK manifest. Is the file a valid Android APK?"
fi

_pkg_name="$(echo "${_badge}" | sed "s/^package: name='\\([^']*\\)'.*/\\1/")"
if [[ "${_pkg_name}" != "${APP_ID}" ]]; then
  die_invalid "APK package '${_pkg_name}' does not match expected '${APP_ID}'."
fi

_apk_version_name="$(echo "${_badge}" | sed "s/.*versionName='\\([^']*\\)'.*/\\1/")"
_apk_version_code="$(echo "${_badge}" | sed "s/.*versionCode='\\([^']*\\)'.*/\\1/")"
[[ -z "${_apk_version_name}" ]] && die_invalid "versionName not found in APK manifest."

if [[ -n "${requested_version}" ]]; then
  if [[ "${_apk_version_name}" != "${requested_version}" ]]; then
    die_invalid "APK versionName '${_apk_version_name}' does not match --version '${requested_version}'."
  fi
  version_name="${requested_version}"
  version_code="${_apk_version_code:-${filename_version_code:-unknown}}"
  log_info "Version: ${version_name} (versionCode: ${version_code} — validated via aapt)"
else
  version_name="${_apk_version_name}"
  version_code="${_apk_version_code}"
  log_info "Version: ${version_name} (versionCode: ${version_code})"
fi

# ----------------------------------------
# F-Droid recipe: source of truth for the built commit + build-step guard
# ----------------------------------------
# Ref -> commit; prefers the peeled ^{} line, falls back to the plain ref.
resolve_ref() {
  ${CONTAINER_CMD} run --rm "${_staging_tag}" \
    git ls-remote --tags "${REPO_URL}" "refs/tags/$1" "refs/tags/$1^{}" 2>/dev/null \
    | awk '$2 ~ /\^\{\}$/ {p=$1} $2 !~ /\^\{\}$/ {t=$1} END {if (p) print p; else if (t) print t}' || true
}

log_info "Fetching F-Droid recipe (fdroiddata) for versionCode ${version_code}..."
recipe_block="$(${CONTAINER_CMD} run --rm "${_staging_tag}" \
  curl -fsSL --max-time 60 "${FDROID_RECIPE_URL}" 2>/dev/null \
  | awk -v vc="${version_code}" '
      /^  - versionName:/ { if (found) exit; blk=""; inb=1 }
      inb && /^[A-Za-z]/ { exit }
      { if (inb) blk = blk $0 ORS }
      inb && $1=="versionCode:" && $2==vc { found=1 }
      END { if (found) printf "%s", blk }
    ' || true)"
[[ -z "${recipe_block}" ]] && die_invalid "F-Droid recipe block for versionCode ${version_code} not found (fdroiddata unreachable or version unpublished). The recipe is the source of truth — cannot proceed."

recipe_hash="$(echo "${recipe_block}" | grep -vE '^[[:space:]]*$|^[[:space:]]+(- )?(versionName|versionCode|commit):' | sha256sum | awk '{print $1}')"
if [[ "${recipe_hash}" != "${EXPECTED_RECIPE_SHA256}" ]]; then
  die_invalid "F-Droid recipe changed for versionCode ${version_code}: block sha256 ${recipe_hash} != audited value. Diff the recipe (ndk/prebuild/srclibs/rm/gradle) vs this script, re-audit, update EXPECTED_RECIPE_SHA256."
fi
log_info "Recipe guard: build steps match the audited recipe block."
append_additional_info "Recipe guard: normalized fdroiddata block sha256 matches audited value"

recipe_commit="$(echo "${recipe_block}" | awk '$1=="commit:" {print $2; exit}')"
[[ -z "${recipe_commit}" ]] && die_invalid "commit: field missing from the F-Droid recipe block."
if [[ "${recipe_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  APP_COMMIT="${recipe_commit}"
else
  # Recipe may pin a ref name instead of a hash
  APP_COMMIT="$(resolve_ref "${recipe_commit}")"
  [[ -z "${APP_COMMIT}" ]] && die_invalid "Recipe commit ref '${recipe_commit}' not resolvable in ${REPO_URL}."
fi
log_info "Build source (from F-Droid recipe): commit ${APP_COMMIT}"
append_additional_info "Source commit (F-Droid recipe commit:): ${APP_COMMIT}"

# Provenance cross-check: upstream tag must match the recipe commit.
app_tag="release_${version_name}"
tag_commit="$(resolve_ref "${app_tag}")"
if [[ -z "${tag_commit}" ]]; then
  log_warn "Upstream tag ${app_tag} not found; building from recipe commit only."
  append_additional_info "WARNING: upstream tag ${app_tag} not found; recipe commit used unchecked"
elif [[ "${tag_commit}" != "${APP_COMMIT}" ]]; then
  die_invalid "Provenance mismatch: recipe builds ${APP_COMMIT}, tag ${app_tag} = ${tag_commit}. Investigate first."
else
  log_info "Cross-check: upstream tag ${app_tag} matches the recipe commit."
  append_additional_info "Cross-check: upstream tag ${app_tag} = recipe commit (match)"
fi

if [[ "${version_code}" =~ ^[0-9]+$ && "${version_code}" -gt "${ENV_VALIDATED_THROUGH_CODE}" ]]; then
  log_warn "versionCode ${version_code} is newer than the last env-validated build (${ENV_VALIDATED_THROUGH_CODE}); environment assumptions may be stale."
  append_additional_info "NOTE: env last validated for versionCode ${ENV_VALIDATED_THROUGH_CODE}; this run is newer (${version_code})."
fi

# Retag staging image to run-specific name (PID+timestamp ensures parallel-safety)
build_image_tag="greenfdroid-build-${_run_id}:${version_name}"
${CONTAINER_CMD} tag "${_staging_tag}" "${build_image_tag}"
log_info "Image tagged: ${build_image_tag}"

# ----------------------------------------
# Work directory
# ----------------------------------------
work_dir="$(mktemp -d "/tmp/greenfdroid_${version_name}_XXXXXX")"
mkdir -p "${work_dir}/artifacts"
log_info "Work directory: ${work_dir}"

# ----------------------------------------
# Write inner build script (runs inside the container as vagrant)
# ----------------------------------------
# Inner script mounted read-only; output written to /output, docker cp'd after.
# CRITICAL: green_android is cloned with "." directly into WORKDIR so the GDK
# compile path matches fdroidserver's layout exactly — a subdirectory clone
# adds "green_android/" to embedded paths, changing .rodata in the .so.
# ----------------------------------------

inner_script="${work_dir}/inner-build.sh"

cat > "${inner_script}" <<'INNER_BUILD'
#!/bin/bash
set -euo pipefail

CHECKOUT=/home/vagrant/build/com.greenaddress.greenbits_android_wallet
cd "${CHECKOUT}"

echo "[BUILD] Cloning green_android directly into checkout path (no subdirectory)..."
git clone "${APP_REPO_URL}" .
echo "[BUILD] Checking out immutable commit: ${APP_COMMIT}"
git checkout "${APP_COMMIT}"

echo "[BUILD] Confirming commit..."
git log -1 --format="%H %s"
git log -1 --format="%H" > /tmp/commit-hash.txt

echo "[BUILD] Setting SOURCE_DATE_EPOCH from commit timestamp..."
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(git log -1 --format="%ct")
echo "[BUILD] SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} ($(date -u -d "@${SOURCE_DATE_EPOCH}" 2>/dev/null || date -u -r "${SOURCE_DATE_EPOCH}" 2>/dev/null || echo 'date conversion unavailable'))"

echo "[BUILD] Applying F-Droid recipe patches (faithful except documented +4d)..."
cd androidApp

# Patch 1: remove JetBrains Compose Maven repository
sed -i -e '/packages.jetbrains.team/d' ../settings.gradle.kts

# Patch 2: remove :gms (Google Mobile Services) module references
sed -i -e '/:gms/d' ../settings.gradle.kts build.gradle.kts

# Patch 3: remove Breez/Zendesk/JetBrains repos and googleServices plugin
sed -i -e '/mvn.breez/d;/zendesk/d;/jetbrains/d;/googleServices/d' ../build.gradle.kts

# Patch 4: activate F-Droid Breez SDK fallback dependencies
sed -i -e '/libs.breez.sdk.kmp/d' -e '/jna/s|//||g' ../data/build.gradle.kts

# Patch 5: remove app signing configuration
# NOTE: recipe uses +3d but that leaves an orphaned brace (build.gradle.kts is
# unchanged across 5.4.0-5.5.1). +4d is correct (verified by brace counting).
sed -i -e '/signingConfigs {/,+8d' \
       -e '/signingConfigs.getByName/,+4d' \
       -e '/versionNameSuffix/d' \
       -e '/googleServices/d' \
       build.gradle.kts

# Patch 6: raise JVM target from 17 to 21
sed -i -e '/jvm/s/17/21/' ../gradle/libs.versions.toml

cd ../gdk

echo "[BUILD] Deriving GDK version from prepare_gdk_clang.sh..."
gdkVersion=$(sed -n -E 's/.*TAGNAME="(.*)"/\1/p' prepare_gdk_clang.sh)
echo "[BUILD] GDK version: ${gdkVersion}"

# srclib-equivalent: full clone + tag checkout (recipe: git -C $$gdk$$ checkout)
echo "[BUILD] Cloning GDK (full) and checking out ${gdkVersion}..."
git clone "${GDK_REPO_URL}" gdk
git -C gdk checkout "${gdkVersion}"

cd gdk

echo "[BUILD] Confirming Rust version from GDK Dockerfile..."
rustVersion=$(sed -n -E 's/.*RUST_VERSION=(.*)/\1/p' docker/android/Dockerfile)
echo "[BUILD] Rust version: ${rustVersion}"
rustup default "${rustVersion}"
# Recipe-faithful; covers a GDK Rust bump (image pre-installs 1.85.0 only)
rustup target add aarch64-linux-android armv7-linux-androideabi

# Patch 7: fix unreachable Boost mirror in GDK's dependency-build script
sed -i -e 's|boostorg.jfrog.io/artifactory/main|archives.boost.io|' tools/builddeps.sh

cd ..

# Patch 8: add set -x tracing and setuptools pip install to prepare_gdk_clang.sh
sed -i -e '1a set -x' -e '/requirements/a pip install setuptools' prepare_gdk_clang.sh

echo "[BUILD] Removing recipe rm: items..."
cd ..
rm -rf "gradle/verification-metadata.xml"
rm -rf "gms"
# scandelete: item — harmless if absent
rm -rf "gdk/gdk/subprojects/gdk_rust/gdk_electrum/test_data/store" 2>/dev/null || true

echo "[BUILD] Starting GDK compilation from source (arm64-v8a + armeabi-v7a)..."
echo "[BUILD] This is the slow step — expect 30-60 minutes."
cd gdk
JAVA_HOME=$(readlink -f /usr/bin/javac | sed "s:/bin/javac::") \
  PATH="${HOME}/.local/bin:${PATH}" \
  ./prepare_gdk_clang.sh "armeabi-v7a arm64-v8a"

echo "[BUILD] GDK compilation complete."

echo "[BUILD] Capturing linker command for both ABIs..."
# Makefile generator writes link.txt; Ninja stores commands in build.ninja.
for abi in arm64-v8a armeabi-v7a; do
  captured=false

  # Method 1: link.txt anywhere under gdk/ for this ABI
  linkfile=$(find "gdk" -path "*${abi}*" -name "link.txt" 2>/dev/null \
             | xargs grep -l -- "--build-id" 2>/dev/null | head -1 || true)
  if [[ -n "${linkfile}" ]]; then
    cp "${linkfile}" "/output/link-${abi}.txt"
    echo "[BUILD] Captured link.txt for ${abi}: ${linkfile}"
    cat "${linkfile}"
    captured=true
  fi

  # Method 2: Ninja — `ninja -t commands` prints fully-expanded commands
  # (grepping build.ninja alone misses the template in rules.ninja).
  if [[ "${captured}" == "false" ]]; then
    ninja_file=$(find "gdk" -path "*${abi}*" -name "build.ninja" 2>/dev/null | head -1 || true)
    if [[ -n "${ninja_file}" ]]; then
      ninja -C "$(dirname "${ninja_file}")" -t commands 2>/dev/null \
        | grep -- "libgreen_gdk_java" | head -5 > "/output/link-${abi}.txt" || true
      if [[ ! -s "/output/link-${abi}.txt" ]]; then
        # Fallback: raw grep of build.ninja (weaker — may show variables, not commands)
        grep -n -- "--build-id\|libgreen_gdk_java" "${ninja_file}" 2>/dev/null \
          | head -30 > "/output/link-${abi}.txt" || true
      fi
      if [[ -s "/output/link-${abi}.txt" ]]; then
        echo "[BUILD] Captured linker command via ninja for ${abi}: ${ninja_file}"
        cat "/output/link-${abi}.txt"
        captured=true
      fi
    fi
  fi

  if [[ "${captured}" == "false" ]]; then
    echo "[BUILD] WARNING: linker command not found for ${abi}"
    echo "WARNING: linker command not captured (neither link.txt nor build.ninja found)" \
      > "/output/link-${abi}.txt"
  fi
done

echo "[BUILD] Capturing Build IDs from built .so files..."
for abi in arm64-v8a armeabi-v7a; do
  # The built .so may be in the cmake build dir or copied into the wrapper jniLibs
  sofile=$(find "gdk" -name "libgreen_gdk_java.so" -path "*${abi}*" 2>/dev/null | head -1 || true)
  if [[ -n "${sofile}" ]]; then
    bid=$(readelf -n "${sofile}" 2>/dev/null | grep "Build ID" || true)
    echo "${bid}" > "/output/buildid-built-${abi}.txt"
    echo "[BUILD] Built ${abi} Build ID: ${bid}"
  else
    echo "[BUILD] WARNING: built libgreen_gdk_java.so not found for ${abi}"
  fi
done

echo "[BUILD] Capturing .syms and pre-strip .so artifacts (before Gradle assembly)..."
# GDK cmake runs objcopy --only-keep-debug on the linked lib, writing
# libgreen_gdk_java.syms next to the linker output .so — anchor pre-strip
# selection to the .syms location, size heuristic only as fallback.
LLVM_OBJCOPY="${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objcopy"
for abi in arm64-v8a armeabi-v7a; do
  prestrip_so=""
  select_method=""
  syms=$(find "gdk" -path "*/build-android-${abi}/*" \
    -name "libgreen_gdk_java.syms" 2>/dev/null | head -1 || true)
  if [[ -z "${syms}" ]]; then
    syms=$(find "gdk" -name "libgreen_gdk_java.syms" -path "*${abi}*" \
      2>/dev/null | head -1 || true)
  fi
  if [[ -n "${syms}" ]]; then
    cp "${syms}" "/output/syms-${abi}.syms"
    sha256sum "${syms}" | awk '{print $1}' > "/output/hash-syms-${abi}.txt"
    echo "[BUILD] Captured .syms for ${abi}: ${syms} ($(stat -c%s "${syms}") bytes)"
    prestrip_so=$(find "$(dirname "${syms}")" -name "libgreen_gdk_java.so" 2>/dev/null \
      | grep "swig_java" | head -1 || true)
    [[ -z "${prestrip_so}" ]] && prestrip_so=$(find "$(dirname "${syms}")" \
      -name "libgreen_gdk_java.so" 2>/dev/null | head -1 || true)
    select_method="adjacent-to-syms"
  else
    echo "[BUILD] WARNING: libgreen_gdk_java.syms not found for ${abi}"
  fi
  if [[ -z "${prestrip_so}" ]]; then
    prestrip_so=$(find "gdk" -name "libgreen_gdk_java.so" -path "*${abi}*" \
      -printf '%s %p\n' 2>/dev/null | sort -rn | awk '{print $2}' | head -1 || true)
    select_method="largest-size-heuristic"
  fi
  if [[ -n "${prestrip_so}" ]]; then
    sz=$(stat -c%s "${prestrip_so}")
    dbg_count=$(readelf -S "${prestrip_so}" 2>/dev/null | grep -c "\.debug_" || true)
    echo "[BUILD] Pre-strip ${abi}: ${prestrip_so} (${sz} bytes, ${dbg_count} .debug_* sections, selected: ${select_method})"
    if [[ "${dbg_count}" -eq 0 ]]; then
      echo "[BUILD] WARNING: ${abi} pre-strip candidate has NO .debug_* sections — Build ID hash input difference must lie in symtab/strtab, or this file is not the linker output"
    fi
    cp "${prestrip_so}" "/output/prestrip-${abi}.so"
    sha256sum "${prestrip_so}" | awk '{print $1}' > "/output/hash-prestrip-${abi}.txt"
    readelf -S  "${prestrip_so}" 2>/dev/null > "/output/prestrip-sections-${abi}.txt" || true
    readelf -n  "${prestrip_so}" 2>/dev/null >> "/output/prestrip-sections-${abi}.txt" || true
    echo "[BUILD] Pre-strip section headers saved to prestrip-sections-${abi}.txt"
    # Cross-check: regenerating .syms from the candidate proves it is the
    # exact file objcopy ran on.
    if [[ -n "${syms}" && -x "${LLVM_OBJCOPY}" ]]; then
      "${LLVM_OBJCOPY}" --only-keep-debug "${prestrip_so}" "/tmp/recheck-${abi}.syms" 2>/dev/null || true
      if cmp -s "/tmp/recheck-${abi}.syms" "${syms}" 2>/dev/null; then
        echo "[BUILD] Cross-check ${abi}: --only-keep-debug of pre-strip .so == captured .syms (linker output confirmed)"
      else
        echo "[BUILD] Cross-check ${abi}: pre-strip candidate does NOT regenerate .syms (may not be the exact linker output)"
      fi
    fi
  else
    echo "[BUILD] WARNING: pre-strip .so not found for ${abi}"
  fi
done

echo "[BUILD] Building F-Droid APK..."
cd ..
./gradlew assembleProductionFDroidRelease

echo "[BUILD] Locating built APK..."
built_apk=$(find androidApp/build/outputs/apk \
  -name "*productionFDroid*release*.apk" \
  -not -name "*.json" 2>/dev/null | head -1 || true)
if [[ -z "${built_apk}" ]]; then
  built_apk=$(find androidApp/build/outputs/apk -name "*.apk" \
    -not -name "*.json" 2>/dev/null | head -1 || true)
fi
[[ -z "${built_apk}" ]] && { echo "[BUILD] ERROR: built APK not found"; exit 1; }
echo "[BUILD] Built APK: ${built_apk}"

cp "${built_apk}" /output/green-fdroid-built-unsigned.apk
cp /tmp/commit-hash.txt /output/commit-hash.txt
sha256sum /output/green-fdroid-built-unsigned.apk | awk '{print $1}' \
  > /output/hash-built-apk.txt
for abi in arm64-v8a armeabi-v7a; do
  if ! unzip -p /output/green-fdroid-built-unsigned.apk \
    "lib/${abi}/libgreen_gdk_java.so" 2>/dev/null \
    | sha256sum | awk '{print $1}' > "/output/hash-built-so-${abi}.txt"; then
    echo "not captured" > "/output/hash-built-so-${abi}.txt"
  fi
done

echo "[BUILD] Artifacts in /output:"
ls -lh /output/
INNER_BUILD

chmod 644 "${inner_script}"

# ----------------------------------------
# Run build container (persistent — docker cp afterward)
# ----------------------------------------
build_container_name="greenfdroid-build-${_run_id}"

log_info "Starting build container: ${build_container_name}"
log_info "Source commit: ${APP_COMMIT}"
log_info "GDK compilation starts inside — this takes 30-60 minutes on first run."

${CONTAINER_CMD} run \
  --name "${build_container_name}" \
  --env APP_REPO_URL="${REPO_URL}" \
  --env GDK_REPO_URL="${GDK_REPO_URL}" \
  --env APP_COMMIT="${APP_COMMIT}" \
  --volume "${inner_script}:/home/vagrant/inner-build.sh${VOLUME_RO_SUFFIX}" \
  "${build_image_tag}" \
  bash /home/vagrant/inner-build.sh

log_info "Build complete. Copying artifacts from container..."
${CONTAINER_CMD} cp "${build_container_name}:/output/." "${work_dir}/artifacts/"
${CONTAINER_CMD} rm "${build_container_name}"
build_container_name=""

built_apk="${work_dir}/artifacts/green-fdroid-built-unsigned.apk"
[[ ! -f "${built_apk}" ]] && die_failed "Built APK not found — check build log above."

log_info "Built APK: ${built_apk} ($(stat -c%s "${built_apk}") bytes)"
log_info "Official APK: ${downloaded_apk} ($(stat -c%s "${downloaded_apk}") bytes)"

commit_hash="$(cat "${work_dir}/artifacts/commit-hash.txt" 2>/dev/null | tr -d '[:space:]' || echo "unknown")"
log_info "Source commit: ${commit_hash}"

official_sha256="$(${CONTAINER_CMD} run --rm \
  --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
  "${build_image_tag}" \
  sha256sum "/apk/${apk_file}" 2>/dev/null | awk '{print $1}' || echo "unknown")"
log_info "Official APK SHA256: ${official_sha256}"
read_hash_file() {
  local file="$1" fallback="$2"
  if [[ -f "${file}" ]]; then
    tr -d '[:space:]' < "${file}"
  else
    printf '%s' "${fallback}"
  fi
}
built_sha256="$(read_hash_file "${work_dir}/artifacts/hash-built-apk.txt" "unknown")"
log_info "Built APK SHA256:    ${built_sha256}"
append_additional_info "Official APK SHA256: ${official_sha256}"
append_additional_info "Built APK SHA256: ${built_sha256}"

for abi in arm64-v8a armeabi-v7a; do
  built_so_sha="$(read_hash_file "${work_dir}/artifacts/hash-built-so-${abi}.txt" "not captured")"
  prestrip_sha="$(read_hash_file "${work_dir}/artifacts/hash-prestrip-${abi}.txt" "not captured")"
  syms_sha="$(read_hash_file "${work_dir}/artifacts/hash-syms-${abi}.txt" "not captured")"
  log_info "${abi} built APK .so SHA256: ${built_so_sha}"
  log_info "${abi} pre-strip .so SHA256: ${prestrip_sha}"
  log_info "${abi} .syms SHA256:         ${syms_sha}"
  append_additional_info "${abi} hashes: built-so=${built_so_sha}, prestrip-so=${prestrip_sha}, syms=${syms_sha}"
done

# ----------------------------------------
# Log linker-command contents and diagnose Build ID behavior
# ----------------------------------------
log_info "======================================================================"
log_info "CMake linker command for libgreen_gdk_java.so"
log_info "======================================================================"
log_info "Examining --build-id and strip flags to explain Build ID non-determinism."

for abi in arm64-v8a armeabi-v7a; do
  linkfile="${work_dir}/artifacts/link-${abi}.txt"
  log_info "--- ${abi} ---"
  if [[ -f "${linkfile}" ]]; then
    cat "${linkfile}"
    echo ""
    if grep -qE -- "--strip-all|-S " "${linkfile}" 2>/dev/null; then
      log_info "[${abi}] linker command contains a strip flag"
      append_additional_info "${abi} link: strips during link (--strip-all or -S found)"
    else
      log_info "[${abi}] No strip flag in captured linker command"
      append_additional_info "${abi} link: no strip flag in link command (strip may occur in a separate post-link step)"
    fi
    build_id_flag=$(grep -oE -- "--build-id=[^ ]+" "${linkfile}" 2>/dev/null || echo "(not found)")
    log_info "[${abi}] Build ID flag: ${build_id_flag}"
    append_additional_info "${abi} --build-id flag: ${build_id_flag}"
  else
    log_warn "Linker command not found for ${abi}"
    append_additional_info "${abi} linker command: not captured"
  fi
done

# ----------------------------------------
# Report Build IDs (official vs built)
# ----------------------------------------
log_info "======================================================================"
log_info "GNU Build IDs"
log_info "======================================================================"

for abi in arm64-v8a armeabi-v7a; do
  log_info "--- ${abi} ---"

  official_buildid="$(${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${downloaded_apk}"):/official${VOLUME_RO_SUFFIX}" \
    "${build_image_tag}" \
    bash -c "
      mkdir -p /tmp/so-extract
      unzip -q /official/$(basename "${downloaded_apk}") lib/${abi}/libgreen_gdk_java.so \
        -d /tmp/so-extract 2>/dev/null || true
      readelf -n /tmp/so-extract/lib/${abi}/libgreen_gdk_java.so 2>/dev/null \
        | grep 'Build ID' || echo '(not found)'
    " )"

  built_buildid_file="${work_dir}/artifacts/buildid-built-${abi}.txt"
  built_buildid="$(cat "${built_buildid_file}" 2>/dev/null || echo "(not found)")"

  log_info "Official: ${official_buildid}"
  log_info "Built:    ${built_buildid}"
  append_additional_info "Build ID official ${abi}: ${official_buildid}"
  append_additional_info "Build ID built    ${abi}: ${built_buildid}"
done

# ----------------------------------------
# Compare: apksigcopier --unsigned
# ----------------------------------------
log_info "======================================================================"
log_info "apksigcopier compare --unsigned"
log_info "======================================================================"

apksig_raw="$(${CONTAINER_CMD} run --rm \
  --volume "$(dirname "${downloaded_apk}"):/official${VOLUME_RO_SUFFIX}" \
  --volume "${work_dir}/artifacts:/built${VOLUME_RO_SUFFIX}" \
  "${build_image_tag}" \
  bash -c "apksigcopier compare --unsigned /official/$(basename "${downloaded_apk}") /built/green-fdroid-built-unsigned.apk 2>&1; echo APKSIG_EXIT:\$?")"
apksig_exit_code="$(echo "${apksig_raw}" | grep '^APKSIG_EXIT:' | sed 's/APKSIG_EXIT://' | tr -d '[:space:]' || true)"
[[ -z "${apksig_exit_code}" ]] && apksig_exit_code="1"
apksig_output="$(echo "${apksig_raw}" | grep -v '^APKSIG_EXIT:' || true)"

log_info "${apksig_output:-<no output>}"

apksig_ok=false
if [[ "${apksig_exit_code}" == "0" ]]; then
  apksig_ok=true
  [[ -n "${apksig_output}" ]] && log_warn "apksigcopier exited 0 with unexpected output: ${apksig_output}"
elif echo "${apksig_output}" | grep -q "DOES NOT VERIFY"; then
  log_warn "apksigcopier: APK does not verify unsigned (files differ)"
elif [[ -z "${apksig_output}" ]]; then
  die_failed "apksigcopier produced no output (exit ${apksig_exit_code}) — comparison tool malfunction"
else
  die_failed "apksigcopier tool error (exit ${apksig_exit_code}): $(echo "${apksig_output}" | head -1)"
fi
append_additional_info "apksigcopier exit=${apksig_exit_code}: $(echo "${apksig_output}" | head -1)"

# ----------------------------------------
# Compare: full file diff (all files in APK)
# ----------------------------------------
log_info "======================================================================"
log_info "Full APK file diff (diff -rq on unzipped contents)"
log_info "======================================================================"

diff_output="$(${CONTAINER_CMD} run --rm \
  --volume "$(dirname "${downloaded_apk}"):/official${VOLUME_RO_SUFFIX}" \
  --volume "${work_dir}/artifacts:/built${VOLUME_RO_SUFFIX}" \
  "${build_image_tag}" \
  bash -c "
    mkdir -p /tmp/apk-official /tmp/apk-built
    unzip -q /official/$(basename "${downloaded_apk}") -d /tmp/apk-official
    unzip -q /built/green-fdroid-built-unsigned.apk -d /tmp/apk-built
    diff -rq /tmp/apk-official /tmp/apk-built 2>&1 || true
  " )"

diff_file="${work_dir}/artifacts/apk-diff.txt"
echo "${diff_output}" > "${diff_file}"
log_info "Full diff saved to: ${diff_file}"
diff_line_count="$(echo "${diff_output}" | grep -c '.' || true)"
log_info "Diff preview (first 5 of ${diff_line_count} line(s)):"
echo "${diff_output}" | head -5
[[ "${diff_line_count}" -gt 5 ]] && log_info "... (${diff_line_count} lines total; full diff in ${diff_file})"
append_additional_info "diff -rq total lines: ${diff_line_count}"

# Classify differences
only_meta_and_so=true
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  if ! echo "${line}" | grep -qE "/META-INF/(MANIFEST\.MF|[A-Z0-9_-]+\.(SF|RSA|DSA|EC)) differ|/META-INF: (MANIFEST\.MF|[A-Z0-9_-]+\.(SF|RSA|DSA|EC))$|libgreen_gdk_java\.so"; then
    only_meta_and_so=false
    log_warn "Unexpected diff: ${line}"
    append_additional_info "Unexpected diff: ${line}"
  fi
done <<< "${diff_output}"

so_diff_count="$(echo "${diff_output}" | grep -c "libgreen_gdk_java.so" || true)"
meta_only_count="$(echo "${diff_output}" | grep -c "Only in.*META-INF" || true)"

append_additional_info "diff: ${so_diff_count} .so file(s) differ, ${meta_only_count} META-INF signature file(s) present only in official"

# Prove .so diffs are confined to .note.gnu.build-id: cmp -l gives exact byte
# positions; readelf -SW gives the section's file offset+size for range checks
# (objcopy --remove-section rewrites layout and produces false mismatches).
so_buildid_only=false
if [[ "${so_diff_count}" -gt 0 ]]; then
  log_info "======================================================================"
  log_info "Verifying .so differences are confined to .note.gnu.build-id (cmp -l)"
  log_info "======================================================================"
  so_buildid_only=true
  for abi in arm64-v8a armeabi-v7a; do
    if ! echo "${diff_output}" | grep -q "lib/${abi}/libgreen_gdk_java.so"; then
      continue
    fi
    _cmp_result="$(${CONTAINER_CMD} run --rm \
      --env CMP_ABI="${abi}" \
      --env OFF_APK="$(basename "${downloaded_apk}")" \
      --volume "$(dirname "${downloaded_apk}"):/official${VOLUME_RO_SUFFIX}" \
      --volume "${work_dir}/artifacts:/built${VOLUME_RO_SUFFIX}" \
      "${build_image_tag}" \
      bash -c '
        abi="${CMP_ABI}"
        mkdir -p /tmp/sc/off /tmp/sc/blt
        unzip -q "/official/${OFF_APK}" "lib/${abi}/libgreen_gdk_java.so" \
          -d /tmp/sc/off 2>/dev/null || true
        unzip -q /built/green-fdroid-built-unsigned.apk "lib/${abi}/libgreen_gdk_java.so" \
          -d /tmp/sc/blt 2>/dev/null || true
        off="/tmp/sc/off/lib/${abi}/libgreen_gdk_java.so"
        blt="/tmp/sc/blt/lib/${abi}/libgreen_gdk_java.so"
        [[ ! -f "$off" || ! -f "$blt" ]] && echo "MISSING" && exit 0

        sz_off=$(stat -c%s "$off")
        sz_blt=$(stat -c%s "$blt")
        if [[ "$sz_off" != "$sz_blt" ]]; then
          echo "MISMATCH:size_differs:off=${sz_off}_blt=${sz_blt}"
          exit 0
        fi

        off_layout=$(readelf -SW "$off" 2>/dev/null \
          | awk "{for(i=1;i<=NF;i++) if(\$i==\".note.gnu.build-id\"){print \$(i+3),\$(i+4); exit}}")
        blt_layout=$(readelf -SW "$blt" 2>/dev/null \
          | awk "{for(i=1;i<=NF;i++) if(\$i==\".note.gnu.build-id\"){print \$(i+3),\$(i+4); exit}}")
        if [[ -z "$off_layout" || -z "$blt_layout" ]]; then
          echo "NO_BUILDID_SECTION"
          exit 0
        fi
        if [[ "$off_layout" != "$blt_layout" ]]; then
          echo "MISMATCH:buildid_layout:off=${off_layout// /_}_blt=${blt_layout// /_}"
          exit 0
        fi
        read -r sec_off_hex sec_sz_hex <<< "$off_layout"
        if [[ -z "$sec_off_hex" || -z "$sec_sz_hex" ]]; then
          echo "PARSE_ERROR"
          exit 0
        fi
        sec_off=$((16#${sec_off_hex}))
        sec_sz=$((16#${sec_sz_hex}))
        bid_start=$((sec_off + 16))
        bid_end=$((sec_off + sec_sz - 1))

        # cmp positions are 1-based while ELF section offsets are 0-based.
        stats=$( (cmp -l "$off" "$blt" 2>/dev/null || true) \
          | awk -v s="$((bid_start + 1))" -v e="$((bid_end + 1))" \
            "{n++; if(\$1<s || \$1>e) out++} END{print n+0, out+0}" )
        [[ "$stats" =~ ^[0-9]+\ [0-9]+$ ]] || { echo "COUNT_ERROR"; exit 0; }
        read -r n outside <<< "$stats"
        [[ $n -eq 0 ]] && echo "MATCH" && exit 0

        if [[ $outside -eq 0 ]]; then
          echo "MATCH_BUILDID_ONLY:${n}"
        else
          echo "MISMATCH:${n}:${outside}_outside_buildid_range_${bid_start}-${bid_end}"
        fi
      ' 2>/dev/null || echo ERROR)"

    log_info "${abi} cmp check: ${_cmp_result}"
    append_additional_info "${abi} .so cmp check: ${_cmp_result}"
    case "${_cmp_result}" in
      MATCH|MATCH_BUILDID_ONLY:*)
        ;;
      *)
        so_buildid_only=false
        log_warn "${abi}: .so files differ beyond Build ID section (${_cmp_result})"
        ;;
    esac
  done
fi

if [[ "${so_diff_count}" -gt 0 ]]; then
  if "${only_meta_and_so}" && "${so_buildid_only}"; then
    log_info "CONFIRMED: only F-Droid signature files and GNU Build ID in .note.gnu.build-id differ."
    append_additional_info "Classification: only F-Droid signature files and .note.gnu.build-id differ."
    append_additional_info "All DEX, resources, assets, and other libraries are byte-for-byte identical."
  elif "${so_buildid_only}"; then
    log_warn ".so Build ID is the only difference in the library, but unexpected diffs exist elsewhere."
    append_additional_info "Classification: .so differs only in Build ID, but unexpected non-signature diffs present."
  else
    log_warn "libgreen_gdk_java.so differs beyond Build ID section — unexpected content difference."
    append_additional_info "Classification: .so difference exceeds Build ID section."
  fi
fi

# ----------------------------------------
# Determine verdict
# ----------------------------------------
verdict="not_reproducible"
if "${apksig_ok}"; then
  verdict="reproducible"
fi

# Annotate if Build ID is the only non-signing difference (proven by objcopy)
if [[ "${so_diff_count}" -gt 0 && "${only_meta_and_so}" == "true" && "${so_buildid_only}" == "true" && "${verdict}" == "not_reproducible" ]]; then
  append_additional_info ""
  append_additional_info "POLICY NOTE: The only content difference is .note.gnu.build-id in"
  append_additional_info "libgreen_gdk_java.so (both ABIs), confirmed by cmp -l byte-range check."
  append_additional_info "All executable code, data sections, resources, and assets are identical."
  append_additional_info "See cmake link.txt above for lld flags (--build-id, strip behavior)."
fi

log_info "======================================================================"
log_info "Verdict: ${verdict}"
log_info "======================================================================"

# ----------------------------------------
# Results summary block (ABS compliance)
# ----------------------------------------
echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         F-Droid"
echo "apkVersionName: ${version_name}"
echo "apkVersionCode: ${version_code}"
echo "verdict:        ${verdict}"
echo "appHash:        ${official_sha256}"
echo "commit:         ${commit_hash}"
echo ""
if [[ -n "${diff_output}" ]]; then
  echo "Diff (${diff_line_count} line(s); full diff in artifacts/apk-diff.txt):"
  echo "${diff_output}" | head -5
  [[ "${diff_line_count}" -gt 5 ]] && echo "... and $(( diff_line_count - 5 )) more line(s)"
  echo ""
else
  echo "Diff: (none)"
  echo ""
fi
echo "===== End Results ====="
echo ""

# ----------------------------------------
# Write COMPARISON_RESULTS.yaml
# ----------------------------------------
generate_comparison_yaml "${verdict}"
log_info "COMPARISON_RESULTS.yaml written."

# ----------------------------------------
# Cleanup run-specific image tags (always — layers remain cached; tags are useless after the run)
# ----------------------------------------
${CONTAINER_CMD} rmi "${build_image_tag}" 2>/dev/null || true
${CONTAINER_CMD} rmi "${_staging_tag}" 2>/dev/null || true
log_info "Run-specific image tags removed (layer cache preserved)."

# ----------------------------------------
# Cleanup work directory (optional — only with --cleanup)
# ----------------------------------------
if "${should_cleanup}"; then
  log_info "Cleaning up work directory..."
  ${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${work_dir}"):/parent${VOLUME_RW_SUFFIX}" \
    "${WS_CONTAINER}" \
    rm -rf "/parent/$(basename "${work_dir}")"
  log_info "Work directory removed."
fi

if [[ "${verdict}" == "reproducible" ]]; then
  echo "Exit code: ${EXIT_SUCCESS}"
  exit "${EXIT_SUCCESS}"
else
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
fi
