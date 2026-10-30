#!/usr/bin/env bash
# ==============================================================================
# apk_exfiltration_scan.sh - Static APK Exfiltration-Risk Triage
# ==============================================================================
# Version:       v0.1.0
# Organization:  WalletScrutiny.com
# Last modified by: Codex
# Last modified on: 2026-09-04
# License:       Apache-2.0
# ==============================================================================
#
# This script performs static triage. It does not execute the APK, transmit
# data, or prove that an app is safe or malicious. A finding means that a
# capability or code clue deserves review, not that exfiltration occurs.

set -uo pipefail

readonly SCRIPT_VERSION="v0.1.0"

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
SCRIPT_HASH="$(sha256sum "$SCRIPT_PATH" | awk '{print $1}')"

APK=""
OUTPUT_DIR=""
DECODE_DIR=""
REPORT_FILE=""
INDICATORS_FILE=""
ENDPOINTS_FILE=""
DOMAINS_FILE=""
CORRELATIONS_FILE=""
APK_ENTRIES_FILE=""

log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARNING] %s\n' "$*" >&2; }
log_fail() { printf '[FAIL] %s\n' "$*" >&2; }

usage() {
    printf 'Usage: %s --binary APK [--output DIRECTORY]\n' "$SCRIPT_NAME"
    printf '       %s --apk APK [--output DIRECTORY]\n' "$SCRIPT_NAME"
    printf '\n'
    printf 'Static analysis only. The APK is never installed or executed.\n'
}

die() {
    log_fail "$1"
    exit "${2:-1}"
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "Required tool not found: $1"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --binary|--apk)
                [[ $# -ge 2 ]] || die "$1 requires an APK path." 2
                APK="$2"
                shift 2
                ;;
            --output)
                [[ $# -ge 2 ]] || die "--output requires a directory path." 2
                OUTPUT_DIR="$2"
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

relative_path() {
    local path="$1"
    printf '%s\n' "${path#"$DECODE_DIR"/}"
}

count_lines() {
    local file="$1"
    if [[ -s "$file" ]]; then
        wc -l < "$file" | tr -d ' '
    else
        printf '0\n'
    fi
}

scan_smali_indicator() {
    local category="$1"
    local confidence="$2"
    local label="$3"
    local pattern="$4"
    local matches_file="$OUTPUT_DIR/.indicator-matches"
    local count=0
    local examples=""

    : > "$matches_file"
    rg -l --glob '*.smali' -e "$pattern" "$DECODE_DIR" \
        2>/dev/null | sort -u > "$matches_file" || true
    count="$(count_lines "$matches_file")"

    if (( count > 0 )); then
        examples="$({
            while IFS= read -r path; do
                relative_path "$path"
            done < "$matches_file"
        } | head -n 5 | paste -sd ', ' -)"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$category" "$confidence" "$label" "$count" "$examples" \
            >> "$INDICATORS_FILE"
    fi
}

scan_manifest_permissions() {
    local manifest="$DECODE_DIR/AndroidManifest.xml"
    local permission=""
    local severity=""
    local reason=""

    : > "$OUTPUT_DIR/permissions.tsv"
    rg '<uses-permission' "$manifest" 2>/dev/null \
        | rg -o 'android\.permission\.[A-Z0-9_]+' \
        | sort -u > "$OUTPUT_DIR/.permissions" || true

    while IFS= read -r permission; do
        [[ -n "$permission" ]] || continue
        severity="context"
        reason="Declared Android capability"
        case "$permission" in
            android.permission.READ_CONTACTS)
                severity="high"; reason="Can read contacts" ;;
            android.permission.READ_SMS|android.permission.RECEIVE_SMS)
                severity="high"; reason="Can access SMS content" ;;
            android.permission.READ_CALL_LOG)
                severity="high"; reason="Can read call history" ;;
            android.permission.READ_PHONE_NUMBERS|android.permission.READ_PHONE_STATE)
                severity="high"; reason="Can access phone identity or state" ;;
            android.permission.ACCESS_FINE_LOCATION|android.permission.ACCESS_BACKGROUND_LOCATION)
                severity="high"; reason="Can access precise or background location" ;;
            android.permission.ACCESS_COARSE_LOCATION)
                severity="medium"; reason="Can access approximate location" ;;
            android.permission.GET_ACCOUNTS)
                severity="high"; reason="Can enumerate device accounts" ;;
            android.permission.READ_CALENDAR)
                severity="high"; reason="Can read calendar data" ;;
            android.permission.RECORD_AUDIO)
                severity="high"; reason="Can capture microphone audio" ;;
            android.permission.CAMERA)
                severity="medium"; reason="Can capture camera input" ;;
            android.permission.READ_EXTERNAL_STORAGE|android.permission.READ_MEDIA_IMAGES|android.permission.READ_MEDIA_VIDEO|android.permission.READ_MEDIA_AUDIO)
                severity="high"; reason="Can read user files or media" ;;
            android.permission.QUERY_ALL_PACKAGES|android.permission.PACKAGE_USAGE_STATS)
                severity="high"; reason="Can enumerate installed apps or usage" ;;
            android.permission.BLUETOOTH_SCAN|android.permission.BLUETOOTH_CONNECT)
                severity="medium"; reason="Can observe or connect to nearby devices" ;;
            android.permission.INTERNET)
                severity="capability"; reason="Can communicate over the network" ;;
            android.permission.SEND_SMS)
                severity="channel"; reason="Can transmit data through SMS" ;;
            android.permission.NFC)
                severity="channel"; reason="Can communicate over NFC" ;;
        esac
        printf '%s\t%s\t%s\n' "$severity" "$permission" "$reason" \
            >> "$OUTPUT_DIR/permissions.tsv"
    done < "$OUTPUT_DIR/.permissions"
}

extract_endpoints() {
    local raw_urls="$OUTPUT_DIR/.urls-raw"
    local native_urls="$OUTPUT_DIR/.native-urls"
    local value=""

    : > "$raw_urls"
    : > "$native_urls"

    rg -a -o --no-filename \
        --glob '*.smali' --glob '*.xml' --glob '*.json' --glob '*.js' \
        --glob '*.txt' --glob '*.properties' \
        -e 'https?://[^[:space:]"<>\\]+' "$DECODE_DIR" \
        2>/dev/null >> "$raw_urls" || true

    while IFS= read -r -d '' library; do
        strings -a "$library" 2>/dev/null \
            | rg -o 'https?://[^[:space:]"<>]+' \
            >> "$native_urls" || true
    done < <(find "$DECODE_DIR/lib" -type f -name '*.so' -print0 2>/dev/null)

    cat "$native_urls" >> "$raw_urls"

    : > "$ENDPOINTS_FILE"
    while IFS= read -r value; do
        value="${value%%\?*}"
        value="${value%%#*}"
        value="${value%,}"
        value="${value%;}"
        value="${value%)}"
        case "$value" in
            http://schemas.android.com/*|https://schemas.android.com/*|http://www.w3.org/*|https://www.w3.org/*)
                continue
                ;;
        esac
        printf '%s\n' "$value"
    done < "$raw_urls" | sort -u | head -n 500 > "$ENDPOINTS_FILE"

    : > "$DOMAINS_FILE"
    sed -E 's#^[A-Za-z]+://([^/@]+@)?([^/:]+).*#\2#' "$ENDPOINTS_FILE" \
        | tr '[:upper:]' '[:lower:]' \
        | rg -v '^(localhost|127\.0\.0\.1|0\.0\.0\.0|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
        | sort -u > "$DOMAINS_FILE" || true
}

scan_correlations() {
    local sources="$OUTPUT_DIR/.source-files"
    local sinks="$OUTPUT_DIR/.sink-files"
    local common="$OUTPUT_DIR/.correlated-files"
    local source_regex='Landroid/provider/(ContactsContract|CallLog|CalendarContract|MediaStore|Telephony)|Landroid/telephony/(TelephonyManager|SubscriptionManager)|Landroid/accounts/AccountManager|Landroid/location/LocationManager|Lcom/google/android/gms/location|Landroid/content/ClipboardManager|Landroid/provider/Settings\$Secure|Landroid/app/usage/UsageStatsManager|Landroid/accessibilityservice/AccessibilityService|Landroid/service/notification/NotificationListenerService'
    local sink_regex='Ljava/net/(HttpURLConnection|URLConnection|Socket|DatagramSocket)|Lokhttp3/|Lretrofit2/|Lcom/android/volley/|Lio/grpc/|Landroid/webkit/WebView;->(loadUrl|postUrl)|Lcom/google/firebase/(analytics|crashlytics|storage)|Lio/sentry/|Lcom/amplitude/|Lcom/mixpanel/|Lcom/segment/|Landroid/telephony/SmsManager;->send'

    rg -l --glob '*.smali' -e "$source_regex" "$DECODE_DIR" \
        2>/dev/null | sort -u > "$sources" || true
    rg -l --glob '*.smali' -e "$sink_regex" "$DECODE_DIR" \
        2>/dev/null | sort -u > "$sinks" || true
    comm -12 "$sources" "$sinks" > "$common"

    : > "$CORRELATIONS_FILE"
    while IFS= read -r path; do
        relative_path "$path"
    done < "$common" | head -n 200 > "$CORRELATIONS_FILE"
}

append_permissions_report() {
    local severity=""
    local permission=""
    local reason=""

    printf '## Declared permissions\n\n' >> "$REPORT_FILE"
    if [[ ! -s "$OUTPUT_DIR/permissions.tsv" ]]; then
        printf 'No Android permissions were parsed. This is an analysis gap.\n\n' >> "$REPORT_FILE"
        return
    fi

    printf '| Triage | Permission | Meaning |\n' >> "$REPORT_FILE"
    printf '|---|---|---|\n' >> "$REPORT_FILE"
    while IFS=$'\t' read -r severity permission reason; do
        printf '| %s | `%s` | %s |\n' "$severity" "$permission" "$reason" \
            >> "$REPORT_FILE"
    done < "$OUTPUT_DIR/permissions.tsv"
    printf '\n' >> "$REPORT_FILE"
}

append_indicator_report() {
    local category=""
    local confidence=""
    local label=""
    local count=""
    local examples=""

    printf '## Code indicators\n\n' >> "$REPORT_FILE"
    printf 'Counts are classes containing a matching API or SDK string. They are not call counts or proven flows.\n\n' >> "$REPORT_FILE"
    if [[ ! -s "$INDICATORS_FILE" ]]; then
        printf 'No configured indicator matched. This does not prove absence.\n\n' >> "$REPORT_FILE"
        return
    fi

    printf '| Category | Confidence | Indicator | Classes | Examples |\n' >> "$REPORT_FILE"
    printf '|---|---|---|---:|---|\n' >> "$REPORT_FILE"
    while IFS=$'\t' read -r category confidence label count examples; do
        printf '| %s | %s | %s | %s | `%s` |\n' \
            "$category" "$confidence" "$label" "$count" "$examples" \
            >> "$REPORT_FILE"
    done < "$INDICATORS_FILE"
    printf '\n' >> "$REPORT_FILE"
}

append_list_report() {
    local heading="$1"
    local description="$2"
    local file="$3"
    local limit="$4"
    local count=0
    local value=""

    count="$(count_lines "$file")"
    printf '## %s\n\n' "$heading" >> "$REPORT_FILE"
    printf '%s\n\n' "$description" >> "$REPORT_FILE"
    printf 'Count: %s\n\n' "$count" >> "$REPORT_FILE"
    if (( count == 0 )); then
        printf 'None extracted.\n\n' >> "$REPORT_FILE"
        return
    fi

    while IFS= read -r value; do
        printf -- '- `%s`\n' "$value" >> "$REPORT_FILE"
    done < <(head -n "$limit" "$file")
    if (( count > limit )); then
        printf -- '- ... %s more; see `%s`\n' "$((count - limit))" "$(basename "$file")" \
            >> "$REPORT_FILE"
    fi
    printf '\n' >> "$REPORT_FILE"
}

append_configuration_report() {
    local manifest="$DECODE_DIR/AndroidManifest.xml"
    local native_count=0
    local dex_count=0
    local cleartext="not explicitly enabled"
    local network_security="not declared"
    local user_ca="not found"
    local dynamic_code="not found"
    local app_framework="Android/JVM"

    native_count="$(find "$DECODE_DIR/lib" -type f -name '*.so' 2>/dev/null | wc -l | tr -d ' ')"
    dex_count="$(find "$DECODE_DIR" -maxdepth 1 -type d -name 'smali*' 2>/dev/null | wc -l | tr -d ' ')"

    if rg -q 'android:usesCleartextTraffic="true"|cleartextTrafficPermitted="true"' \
        "$manifest" "$DECODE_DIR/res" 2>/dev/null; then
        cleartext="explicitly enabled somewhere in decoded configuration"
    fi
    if rg -q 'android:networkSecurityConfig=' "$manifest" 2>/dev/null; then
        network_security="declared; inspect the decoded XML"
    fi
    if rg -q '<certificates[^>]+src="user"' "$DECODE_DIR/res" 2>/dev/null; then
        user_ca="accepted by a network security configuration"
    fi
    if rg -q --glob '*.smali' \
        'LDalvik/system/(DexClassLoader|PathClassLoader|InMemoryDexClassLoader)|Ldalvik/system/DexFile' \
        "$DECODE_DIR" 2>/dev/null; then
        dynamic_code="class-loading API found; runtime code may be outside this scan"
    fi
    if rg -q '(^|/)libapp\.so$|^assets/flutter_assets/' "$APK_ENTRIES_FILE"; then
        app_framework="Flutter; most Dart application logic is outside the Smali correlation scan"
    elif rg -q '(^|/)index\.android\.bundle$' "$APK_ENTRIES_FILE"; then
        app_framework="React Native; JavaScript strings are searched, but JavaScript data flow is not traced"
    elif rg -q '^assets/www/' "$APK_ENTRIES_FILE"; then
        app_framework="Cordova/hybrid; web strings are searched, but JavaScript data flow is not traced"
    elif rg -q '(^|/)assemblies/|assemblies\.blob$' "$APK_ENTRIES_FILE"; then
        app_framework="Xamarin/.NET; managed application logic is outside the Smali correlation scan"
    fi

    printf '## Analysis coverage and configuration\n\n' >> "$REPORT_FILE"
    printf -- '- Decoded DEX groups: %s\n' "$dex_count" >> "$REPORT_FILE"
    printf -- '- Native libraries: %s\n' "$native_count" >> "$REPORT_FILE"
    printf -- '- Application framework clue: %s\n' "$app_framework" >> "$REPORT_FILE"
    printf -- '- Cleartext traffic: %s\n' "$cleartext" >> "$REPORT_FILE"
    printf -- '- Network security config: %s\n' "$network_security" >> "$REPORT_FILE"
    printf -- '- User-installed CA trust: %s\n' "$user_ca" >> "$REPORT_FILE"
    printf -- '- Dynamic code loading: %s\n\n' "$dynamic_code" >> "$REPORT_FILE"

    if (( native_count > 0 )); then
        printf '> Native code is only searched for printable URLs. Its behavior is otherwise an analysis gap.\n\n' \
            >> "$REPORT_FILE"
    fi
}

write_report() {
    local apk_sha="$1"
    local package_name="$2"
    local version_name="$3"
    local version_code="$4"
    local source_count="$5"
    local sink_count="$6"
    local correlation_count="$7"
    local status="manual_review_required"
    local internet="no"

    if rg -q '^.*android\.permission\.INTERNET' "$OUTPUT_DIR/permissions.tsv" 2>/dev/null; then
        internet="yes"
    fi

    {
        printf '# Static APK exfiltration-risk triage\n\n'
        printf -- '- APK: `%s`\n' "$(basename "$APK")"
        printf -- '- SHA-256: `%s`\n' "$apk_sha"
        printf -- '- Package: `%s`\n' "${package_name:-unknown}"
        printf -- '- Version: `%s` (`%s`)\n' "${version_name:-unknown}" "${version_code:-unknown}"
        printf -- '- Scanner: `%s` `%s`\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        printf -- '- Scanner SHA-256: `%s`\n' "$SCRIPT_HASH"
        printf -- '- Status: `%s`\n\n' "$status"
        printf '> This is static triage, not a safety verdict. A match is not proof of exfiltration, and no match is not proof of safety.\n\n'
        printf '## Triage summary\n\n'
        printf -- '- Internet permission: %s\n' "$internet"
        printf -- '- Classes containing configured sensitive-source clues: %s\n' "$source_count"
        printf -- '- Classes containing configured outbound-channel clues: %s\n' "$sink_count"
        printf -- '- Classes containing both kinds of clue: %s\n\n' "$correlation_count"
        printf 'A same-class correlation is a review lead only. It does not establish control flow, data flow, user consent, destination ownership, or actual transmission.\n\n'
    } > "$REPORT_FILE"

    append_permissions_report
    append_configuration_report
    append_indicator_report
    append_list_report \
        "Same-class review leads" \
        "These classes contain both a configured sensitive-source clue and an outbound-channel clue." \
        "$CORRELATIONS_FILE" 50
    append_list_report \
        "Extracted domains" \
        "Hardcoded domains are destinations or documentation clues, not proof that the app contacts them." \
        "$DOMAINS_FILE" 100
    append_list_report \
        "Extracted URLs" \
        "Queries and fragments are removed to avoid reproducing embedded tokens. The complete capped list is retained separately." \
        "$ENDPOINTS_FILE" 100

    {
        printf '## Required next steps for a defensible conclusion\n\n'
        printf '1. Inspect each same-class lead and trace values from source calls to outbound calls.\n'
        printf '2. Attribute domains and telemetry SDKs, then compare behavior with the privacy policy and user consent.\n'
        printf '3. Run the APK in an isolated instrumented Android environment seeded only with synthetic PII.\n'
        printf '4. Capture DNS and network traffic, including delayed/background behavior, without using real accounts or personal data.\n'
        printf '5. Treat TLS pinning, encrypted payloads, native code, reflection, dynamic loading, and server-triggered behavior as unresolved unless separately tested.\n\n'
        printf 'The strongest supportable negative statement from this report is: "No configured static clue was found." It is never: "The APK cannot exfiltrate data."\n'
    } >> "$REPORT_FILE"
}

main() {
    local apk_sha=""
    local badging=""
    local package_name=""
    local version_name=""
    local version_code=""
    local timestamp=""
    local source_count=0
    local sink_count=0
    local correlation_count=0

    printf '[INFO] Script: %s\n' "$SCRIPT_NAME"
    printf '[INFO] Script version: %s\n' "$SCRIPT_VERSION"
    printf '[INFO] Script SHA-256: %s\n' "$SCRIPT_HASH"

    parse_args "$@"
    [[ -n "$APK" ]] || { usage >&2; die "An APK is required via --binary or --apk." 2; }
    APK="$(readlink -f "$APK")"
    [[ -f "$APK" ]] || die "APK not found: $APK" 2
    [[ -r "$APK" ]] || die "APK is not readable: $APK" 2

    require_tool apktool
    require_tool aapt
    require_tool unzip
    require_tool zipinfo
    require_tool strings
    require_tool sha256sum
    require_tool rg
    require_tool find
    require_tool sort
    require_tool comm

    unzip -tqq "$APK" >/dev/null 2>&1 || die "Input is not a valid ZIP/APK archive." 2

    badging="$(aapt dump badging "$APK" 2>/dev/null)" || die "aapt could not parse the APK." 2
    package_name="$(printf '%s\n' "$badging" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n 1)"
    version_name="$(printf '%s\n' "$badging" | sed -n "s/^package:.*versionName='\([^']*\)'.*/\1/p" | head -n 1)"
    version_code="$(printf '%s\n' "$badging" | sed -n "s/^package:.*versionCode='\([^']*\)'.*/\1/p" | head -n 1)"
    [[ -n "$package_name" ]] || die "Input has no parseable Android package name." 2

    timestamp="$(date +%Y%m%d_%H%M%S)"
    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="$PWD/apk-exfiltration_${package_name}_${version_name:-unknown}_${timestamp}"
    else
        OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"
    fi
    [[ ! -e "$OUTPUT_DIR" ]] || die "Output path already exists: $OUTPUT_DIR" 2

    umask 077
    mkdir -p "$OUTPUT_DIR"
    DECODE_DIR="$OUTPUT_DIR/decoded"
    REPORT_FILE="$OUTPUT_DIR/report.md"
    INDICATORS_FILE="$OUTPUT_DIR/indicators.tsv"
    ENDPOINTS_FILE="$OUTPUT_DIR/endpoints.txt"
    DOMAINS_FILE="$OUTPUT_DIR/domains.txt"
    CORRELATIONS_FILE="$OUTPUT_DIR/same-class-correlations.txt"
    APK_ENTRIES_FILE="$OUTPUT_DIR/apk-entries.txt"
    : > "$INDICATORS_FILE"
    zipinfo -1 "$APK" > "$APK_ENTRIES_FILE"

    apk_sha="$(sha256sum "$APK" | awk '{print $1}')"
    log_info "APK: $APK"
    log_info "APK SHA-256: $apk_sha"
    log_info "Package: $package_name"
    log_info "Version: ${version_name:-unknown} (${version_code:-unknown})"
    log_info "Decoding APK without executing it."

    apktool d -f --no-debug-info -p "$OUTPUT_DIR/framework" \
        -o "$DECODE_DIR" "$APK" > "$OUTPUT_DIR/apktool.log" 2>&1 \
        || die "apktool decode failed. See $OUTPUT_DIR/apktool.log" 3
    [[ -f "$DECODE_DIR/AndroidManifest.xml" ]] \
        || die "Decoded AndroidManifest.xml is missing." 3

    scan_manifest_permissions
    extract_endpoints

    scan_smali_indicator "sensitive source" "high" "Contacts provider" 'Landroid/provider/ContactsContract'
    scan_smali_indicator "sensitive source" "high" "SMS or call-log provider" 'Landroid/provider/(Telephony|CallLog)'
    scan_smali_indicator "sensitive source" "high" "Phone identifiers or subscriptions" 'Landroid/telephony/(TelephonyManager|SubscriptionManager)'
    scan_smali_indicator "sensitive source" "high" "Device accounts" 'Landroid/accounts/AccountManager'
    scan_smali_indicator "sensitive source" "high" "Precise or fused location" 'Landroid/location/LocationManager|Lcom/google/android/gms/location'
    scan_smali_indicator "sensitive source" "high" "Calendar provider" 'Landroid/provider/CalendarContract'
    scan_smali_indicator "sensitive source" "medium" "Clipboard" 'Landroid/content/ClipboardManager'
    scan_smali_indicator "sensitive source" "high" "Media or external content" 'Landroid/provider/MediaStore|Landroid/os/Environment;->getExternalStorage'
    scan_smali_indicator "sensitive source" "high" "Installed apps or usage" 'PackageManager;->getInstalled|Landroid/app/usage/UsageStatsManager'
    scan_smali_indicator "sensitive source" "high" "Accessibility or notification content" 'Landroid/accessibilityservice/AccessibilityService|Landroid/service/notification/NotificationListenerService'
    scan_smali_indicator "sensitive source" "medium" "Android ID or secure settings" 'Landroid/provider/Settings\$Secure'
    scan_smali_indicator "wallet-sensitive context" "low" "Seed, mnemonic, or private-key terms" '(?i)(mnemonic|seedphrase|seed_phrase|privatekey|private_key|xprv)'

    scan_smali_indicator "outbound channel" "high" "Java HTTP or socket APIs" 'Ljava/net/(HttpURLConnection|URLConnection|Socket|DatagramSocket)'
    scan_smali_indicator "outbound channel" "high" "OkHttp" 'Lokhttp3/'
    scan_smali_indicator "outbound channel" "high" "Retrofit" 'Lretrofit2/'
    scan_smali_indicator "outbound channel" "high" "Volley" 'Lcom/android/volley/'
    scan_smali_indicator "outbound channel" "high" "gRPC" 'Lio/grpc/'
    scan_smali_indicator "outbound channel" "medium" "WebView URL or POST" 'Landroid/webkit/WebView;->(loadUrl|postUrl)'
    scan_smali_indicator "outbound channel" "medium" "Android share intent" 'Landroid/content/Intent;->(putExtra|setData).*|Landroid/content/Intent;->setType'
    scan_smali_indicator "outbound channel" "high" "SMS transmission" 'Landroid/telephony/SmsManager;->send'
    scan_smali_indicator "telemetry" "medium" "Firebase Analytics or Crashlytics" 'Lcom/google/firebase/(analytics|crashlytics)'
    scan_smali_indicator "telemetry" "medium" "Sentry" 'Lio/sentry/'
    scan_smali_indicator "telemetry" "medium" "Amplitude, Mixpanel, or Segment" 'Lcom/(amplitude|mixpanel|segment)/'
    scan_smali_indicator "analysis obstacle" "high" "Runtime DEX or class loading" 'LDalvik/system/(DexClassLoader|PathClassLoader|InMemoryDexClassLoader)|Ldalvik/system/DexFile'
    scan_smali_indicator "transport control" "context" "Certificate pinning" 'Lokhttp3/CertificatePinner|Lcom/datatheorem/android/trustkit|Lorg/chromium/net/CronetEngine'

    scan_correlations
    source_count="$(count_lines "$OUTPUT_DIR/.source-files")"
    sink_count="$(count_lines "$OUTPUT_DIR/.sink-files")"
    correlation_count="$(count_lines "$CORRELATIONS_FILE")"

    write_report "$apk_sha" "$package_name" "$version_name" "$version_code" \
        "$source_count" "$sink_count" "$correlation_count"

    find "$OUTPUT_DIR" -type f -name '.*' -delete 2>/dev/null || true

    printf '\n===== Static Triage Summary =====\n'
    printf 'package:                 %s\n' "$package_name"
    printf 'version:                 %s (%s)\n' "${version_name:-unknown}" "${version_code:-unknown}"
    printf 'sensitive-source files:  %s\n' "$source_count"
    printf 'outbound-channel files:  %s\n' "$sink_count"
    printf 'same-class leads:        %s\n' "$correlation_count"
    printf 'status:                  manual_review_required\n'
    printf 'report:                  %s\n' "$REPORT_FILE"
    printf '=================================\n'
}

main "$@"
