#!/usr/bin/env bash

set -Eeuo pipefail

die() {
    printf 'release build: %s\n' "$*" >&2
    exit 1
}

require_env() {
    local name="$1"

    [[ -n "${!name:-}" ]] || die "${name} is required"
}

if (( $# != 1 )); then
    die "usage: $0 VERSION"
fi

VERSION="$1"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must be a stable semantic version"

require_env GITHUB_RUN_NUMBER
[[ "$GITHUB_RUN_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "GITHUB_RUN_NUMBER must be a positive integer"

require_env APPLE_SIGNING_IDENTITY
[[ "$APPLE_SIGNING_IDENTITY" == 'Developer ID Application: '* ]] \
    || die "APPLE_SIGNING_IDENTITY must be a Developer ID Application identity"

require_env APPLE_TEAM_ID
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "APPLE_TEAM_ID must be a 10-character alphanumeric Team ID"

require_env APPLE_API_KEY_ID
[[ "$APPLE_API_KEY_ID" =~ ^[A-Za-z0-9]{10}$ ]] \
    || die "APPLE_API_KEY_ID must be a 10-character alphanumeric key ID"

require_env APPLE_API_ISSUER_ID
[[ "$APPLE_API_ISSUER_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || die "APPLE_API_ISSUER_ID must be a UUID"

require_env APPLE_API_KEY_PATH
[[ -r "$APPLE_API_KEY_PATH" ]] || die "APPLE_API_KEY_PATH must point to a readable API key file"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${RELEASE_ROOT_DIR:-}" ]]; then
    ROOT_DIR="$RELEASE_ROOT_DIR"
else
    ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
fi
PROJECT_PATH="$ROOT_DIR/AmbientSync.xcodeproj"
RELEASE_BUILD_DIR="$ROOT_DIR/.build/release"
DERIVED_DATA_PATH="$RELEASE_BUILD_DIR/DerivedData"
PRODUCTS_PATH="$DERIVED_DATA_PATH/Build/Products/Release"
DIST_PATH="$ROOT_DIR/dist"
PRE_NOTARY_ZIP="$RELEASE_BUILD_DIR/AmbientSync-${VERSION}.pre-notarization.zip"
FINAL_ZIP="$DIST_PATH/AmbientSync-${VERSION}.zip"
FINAL_DMG="$DIST_PATH/AmbientSync-${VERSION}-arm64.dmg"
ZIP_CHECKSUM="$FINAL_ZIP.sha256"
DMG_CHECKSUM="$FINAL_DMG.sha256"
DMG_STAGING_DIR="$RELEASE_BUILD_DIR/dmg-staging"
DMG_MOUNT_POINT="$RELEASE_BUILD_DIR/dmg-mount"
NOTARY_SUBMIT_RESPONSE_FILE="$RELEASE_BUILD_DIR/notary-submit-response.json"
NOTARY_SUBMIT_ERROR_FILE="$RELEASE_BUILD_DIR/notary-submit.stderr"
NOTARY_SUBMIT_FIELDS_FILE="$RELEASE_BUILD_DIR/notary-submit-fields"
NOTARY_SUBMIT_PARSE_ERROR_FILE="$RELEASE_BUILD_DIR/notary-submit-parse.stderr"
NOTARY_LOG_RESPONSE_FILE="$RELEASE_BUILD_DIR/notary-log.json"
NOTARY_LOG_ERROR_FILE="$RELEASE_BUILD_DIR/notary-log.stderr"
NOTARY_LOG_PARSE_ERROR_FILE="$RELEASE_BUILD_DIR/notary-log-parse.stderr"
ENTITLEMENTS_FILE="$RELEASE_BUILD_DIR/AmbientSync.entitlements.plist"
ENTITLEMENTS_ERROR_FILE="$RELEASE_BUILD_DIR/entitlements.stderr"
ENTITLEMENTS_LOOKUP_ERROR_FILE="$RELEASE_BUILD_DIR/entitlements-lookup.stderr"
PLIST_BUDDY='/usr/libexec/PlistBuddy'
EXPECTED_BUNDLE_IDENTIFIER='cloud.piatkowski.AmbientSync'
DMG_MOUNT_ATTACHED=false

print_captured_output() {
    local label="$1"
    local path="$2"

    if [[ -s "$path" ]]; then
        printf '%s\n' "$label" >&2
        while IFS= read -r line || [[ -n "$line" ]]; do
            printf '%s\n' "$line" >&2
        done < "$path"
    fi
}

parse_notary_submission_response() {
    local response_file="$1"
    local fields_file="$2"
    local parse_error_file="$3"

    python3 - "$response_file" > "$fields_file" 2> "$parse_error_file" <<'PY'
import json
import re
import sys


def clean_response_value(value):
    if value is None:
        return ""
    if isinstance(value, bool):
        text = "true" if value else "false"
    elif isinstance(value, (str, int, float)):
        text = str(value)
    else:
        return "[non-scalar value omitted]"
    text = " ".join(text.splitlines())
    text = "".join(character if character.isprintable() else " " for character in text)
    return text[:4096]


def fail(message, payload=None):
    print(message, file=sys.stderr)
    if isinstance(payload, dict):
        for field in ("status", "message", "code"):
            if field in payload:
                print("{}: {}".format(field, clean_response_value(payload[field])), file=sys.stderr)
    raise SystemExit(1)


try:
    with open(sys.argv[1], "rb") as response:
        payload = json.load(response)
except (OSError, TypeError, UnicodeError, ValueError):
    fail("notarytool submit response is not valid JSON")

if not isinstance(payload, dict):
    fail("notarytool submit response is not a JSON object")

status = payload.get("status")
submission_id = payload.get("id")
if not isinstance(status, str) or not status or status != status.strip():
    fail("notarytool submit response has no valid status", payload)
if not isinstance(submission_id, str) or not submission_id or submission_id != submission_id.strip():
    fail("notarytool submit response has no valid id", payload)
if any(ord(character) < 0x20 or ord(character) == 0x7F for character in status + submission_id):
    fail("notarytool submit response contains control characters", payload)
if re.fullmatch(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", submission_id) is None:
    fail("notarytool submit response id is not a canonical UUID", payload)

print("{}\t{}".format(status, submission_id))
PY
}

print_notary_log_diagnostics() {
    local artifact_kind="$1"
    local log_file="$2"
    local parse_error_file="$3"

    python3 - "$artifact_kind" "$log_file" 2> "$parse_error_file" <<'PY'
import json
import sys


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def clean(value):
    if value is None:
        return ""
    if isinstance(value, bool):
        text = "true" if value else "false"
    elif isinstance(value, (str, int, float)):
        text = str(value)
    else:
        return "[non-scalar value omitted]"
    text = " ".join(text.splitlines())
    text = "".join(character if character.isprintable() else " " for character in text)
    return text[:4096]


try:
    with open(sys.argv[2], "rb") as log:
        payload = json.load(log)
except (OSError, TypeError, UnicodeError, ValueError):
    fail("notarytool log response is not valid JSON")

if not isinstance(payload, dict):
    fail("notarytool log response is not a JSON object")

artifact_kind = clean(sys.argv[1])
print("{} notarization status: {}".format(artifact_kind, clean(payload.get("status"))))
print("{} notarization summary: {}".format(artifact_kind, clean(payload.get("statusSummary"))))

issues = payload.get("issues", [])
if issues is None:
    issues = []
if not isinstance(issues, list):
    fail("notarytool log issues field is not an array")

issue_fields = ("severity", "code", "path", "message", "architecture", "docUrl")
for issue in issues:
    if not isinstance(issue, dict):
        continue
    values = [(field, clean(issue[field])) for field in issue_fields if field in issue]
    if not values:
        continue
    print("{} notarization issue:".format(artifact_kind))
    for field, value in values:
        print("  {}: {}".format(field, value))
PY
}

validate_signed_entitlements() {
    if ! codesign --display --entitlements :- "$APP_EXECUTABLE" > "$ENTITLEMENTS_FILE" 2> "$ENTITLEMENTS_ERROR_FILE"; then
        print_captured_output 'codesign entitlement extraction stderr:' "$ENTITLEMENTS_ERROR_FILE"
        die "unable to extract effective signed entitlements from AmbientSync executable"
    fi

    if [[ ! -s "$ENTITLEMENTS_FILE" ]]; then
        printf 'No signed entitlements found; continuing\n'
        return
    fi

    if ! plutil -lint -s "$ENTITLEMENTS_FILE" > /dev/null 2> "$ENTITLEMENTS_ERROR_FILE"; then
        print_captured_output 'entitlement plist validation stderr:' "$ENTITLEMENTS_ERROR_FILE"
        die "effective signed entitlements are not a valid property list"
    fi

    local get_task_allow=''
    if get_task_allow="$("$PLIST_BUDDY" -c 'Print :com.apple.security.get-task-allow' "$ENTITLEMENTS_FILE" 2> "$ENTITLEMENTS_LOOKUP_ERROR_FILE")"; then
        case "$get_task_allow" in
            [tT][rR][uU][eE]|1)
                die "forbidden com.apple.security.get-task-allow entitlement is true"
                ;;
            [fF][aA][lL][sS][eE]|0)
                printf 'Effective signed entitlements do not allow get-task-allow\n'
                ;;
            *)
                die "com.apple.security.get-task-allow entitlement has unexpected value"
                ;;
        esac
        return
    fi

    printf 'No com.apple.security.get-task-allow entitlement found; continuing\n'
}

verify_signature_metadata() {
    local artifact_kind="$1"
    local artifact_path="$2"
    local require_runtime="$3"
    local signature_details=''

    if ! signature_details="$(codesign --display --verbose=4 "$artifact_path" 2>&1)"; then
        die "unable to inspect ${artifact_kind} signature"
    fi
    [[ "$signature_details" == *"Authority=$APPLE_SIGNING_IDENTITY"* ]] \
        || die "${artifact_kind} is not signed with APPLE_SIGNING_IDENTITY"
    [[ "$signature_details" == *"TeamIdentifier=$APPLE_TEAM_ID"* ]] \
        || die "${artifact_kind} is not signed for APPLE_TEAM_ID"

    local timestamp_value=''
    while IFS= read -r signature_line; do
        if [[ "$signature_line" == Timestamp=* ]]; then
            timestamp_value="${signature_line#Timestamp=}"
            break
        fi
    done <<< "$signature_details"
    [[ -n "$timestamp_value" && "$timestamp_value" != none* ]] \
        || die "${artifact_kind} signature does not contain a secure timestamp"

    if [[ "$require_runtime" == true ]]; then
        local code_directory_line=''
        while IFS= read -r signature_line; do
            if [[ "$signature_line" =~ ^CodeDirectory[[:space:]] ]]; then
                [[ -z "$code_directory_line" ]] \
                    || die "${artifact_kind} signature contains multiple CodeDirectory lines"
                code_directory_line="$signature_line"
            fi
        done <<< "$signature_details"
        [[ -n "$code_directory_line" ]] \
            || die "${artifact_kind} signature does not contain a CodeDirectory line"

        local code_directory_flags=''
        local code_directory_flags_pattern='flags=0x[[:xdigit:]]+\(([^)]*)\)'
        if [[ "$code_directory_line" =~ $code_directory_flags_pattern ]]; then
            code_directory_flags="${BASH_REMATCH[1]}"
        fi
        [[ ",$code_directory_flags," == *,runtime,* ]] \
            || die "${artifact_kind} signature does not enable hardened runtime"
    fi
}

notarize_artifact() {
    local artifact_kind="$1"
    local artifact_path="$2"

    [[ -s "$artifact_path" ]] \
        || die "${artifact_kind} artifact is missing or empty: $artifact_path"

    rm -f \
        "$NOTARY_SUBMIT_RESPONSE_FILE" \
        "$NOTARY_SUBMIT_ERROR_FILE" \
        "$NOTARY_SUBMIT_FIELDS_FILE" \
        "$NOTARY_SUBMIT_PARSE_ERROR_FILE" \
        "$NOTARY_LOG_RESPONSE_FILE" \
        "$NOTARY_LOG_ERROR_FILE" \
        "$NOTARY_LOG_PARSE_ERROR_FILE"

    printf 'Submitting %s for notarization\n' "$artifact_kind"
    local notary_submit_exit_status=0
    if xcrun notarytool submit "$artifact_path" \
        --key "$APPLE_API_KEY_PATH" \
        --key-id "$APPLE_API_KEY_ID" \
        --issuer "$APPLE_API_ISSUER_ID" \
        --wait \
        --timeout 30m \
        --output-format json \
        --no-progress \
        > "$NOTARY_SUBMIT_RESPONSE_FILE" \
        2> "$NOTARY_SUBMIT_ERROR_FILE"; then
        notary_submit_exit_status=0
    else
        notary_submit_exit_status=$?
    fi

    if [[ ! -s "$NOTARY_SUBMIT_RESPONSE_FILE" ]]; then
        print_captured_output "${artifact_kind} notarytool submit stderr:" "$NOTARY_SUBMIT_ERROR_FILE"
        die "${artifact_kind} notarytool submit returned no JSON response (exit status $notary_submit_exit_status)"
    fi
    if ! parse_notary_submission_response \
        "$NOTARY_SUBMIT_RESPONSE_FILE" \
        "$NOTARY_SUBMIT_FIELDS_FILE" \
        "$NOTARY_SUBMIT_PARSE_ERROR_FILE"; then
        print_captured_output "${artifact_kind} notarytool submit stderr:" "$NOTARY_SUBMIT_ERROR_FILE"
        print_captured_output "${artifact_kind} notarytool submit JSON parse stderr:" "$NOTARY_SUBMIT_PARSE_ERROR_FILE"
        die "${artifact_kind} notarytool submit returned empty or malformed JSON (exit status $notary_submit_exit_status)"
    fi

    local notary_status=''
    local notary_id=''
    if ! IFS=$'\t' read -r notary_status notary_id < "$NOTARY_SUBMIT_FIELDS_FILE"; then
        print_captured_output "${artifact_kind} notarytool submit stderr:" "$NOTARY_SUBMIT_ERROR_FILE"
        die "unable to read parsed ${artifact_kind} notarytool status and id"
    fi
    [[ -n "$notary_status" && -n "$notary_id" ]] \
        || die "${artifact_kind} notarytool submit response did not contain status and id"
    [[ "$notary_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
        || die "${artifact_kind} notarytool submit response id is not a canonical UUID"

    printf '%s notarization status: %s\n' "$artifact_kind" "$notary_status"
    if (( notary_submit_exit_status != 0 )) || [[ "$notary_status" != Accepted ]]; then
        print_captured_output "${artifact_kind} notarytool submit stderr:" "$NOTARY_SUBMIT_ERROR_FILE"

        if [[ "$notary_status" != Accepted ]]; then
            printf 'Fetching %s notarization diagnostics\n' "$artifact_kind" >&2
            local notary_log_exit_status=0
            if xcrun notarytool log "$notary_id" \
                --key "$APPLE_API_KEY_PATH" \
                --key-id "$APPLE_API_KEY_ID" \
                --issuer "$APPLE_API_ISSUER_ID" \
                --output-format json \
                > "$NOTARY_LOG_RESPONSE_FILE" \
                2> "$NOTARY_LOG_ERROR_FILE"; then
                notary_log_exit_status=0
            else
                notary_log_exit_status=$?
            fi

            if (( notary_log_exit_status != 0 )); then
                print_captured_output "${artifact_kind} notarytool log stderr:" "$NOTARY_LOG_ERROR_FILE"
                die "unable to fetch ${artifact_kind} notarization diagnostics (exit status $notary_log_exit_status)"
            fi
            if [[ ! -s "$NOTARY_LOG_RESPONSE_FILE" ]]; then
                print_captured_output "${artifact_kind} notarytool log stderr:" "$NOTARY_LOG_ERROR_FILE"
                die "${artifact_kind} notarytool log returned no JSON response"
            fi
            if ! print_notary_log_diagnostics \
                "$artifact_kind" \
                "$NOTARY_LOG_RESPONSE_FILE" \
                "$NOTARY_LOG_PARSE_ERROR_FILE" >&2; then
                print_captured_output "${artifact_kind} notarytool log stderr:" "$NOTARY_LOG_ERROR_FILE"
                print_captured_output "${artifact_kind} notarytool log JSON parse stderr:" "$NOTARY_LOG_PARSE_ERROR_FILE"
                die "${artifact_kind} notarytool log returned malformed JSON"
            fi
        fi

        if (( notary_submit_exit_status != 0 )); then
            die "${artifact_kind} notarytool submit failed before stapling (exit status $notary_submit_exit_status)"
        fi
        die "${artifact_kind} notarization was not accepted before stapling"
    fi
}

detach_dmg() {
    [[ "$DMG_MOUNT_ATTACHED" == true ]] || return 0

    local attempt=1
    for ((attempt = 1; attempt <= 5; attempt++)); do
        if hdiutil detach "$DMG_MOUNT_POINT" >/dev/null 2>&1; then
            DMG_MOUNT_ATTACHED=false
            return 0
        fi
        sleep 2
    done

    printf 'DMG mount remained busy; attempting forced detach\n' >&2
    if hdiutil detach -force "$DMG_MOUNT_POINT" >/dev/null 2>&1; then
        DMG_MOUNT_ATTACHED=false
        return 0
    fi

    printf 'unable to detach DMG mount at %s\n' "$DMG_MOUNT_POINT" >&2
    return 1
}

cleanup() {
    local exit_status=$?
    set +e

    detach_dmg || true
    rm -rf \
        "$DMG_STAGING_DIR" \
        "$PRE_NOTARY_ZIP" \
        "$NOTARY_SUBMIT_RESPONSE_FILE" \
        "$NOTARY_SUBMIT_ERROR_FILE" \
        "$NOTARY_SUBMIT_FIELDS_FILE" \
        "$NOTARY_SUBMIT_PARSE_ERROR_FILE" \
        "$NOTARY_LOG_RESPONSE_FILE" \
        "$NOTARY_LOG_ERROR_FILE" \
        "$NOTARY_LOG_PARSE_ERROR_FILE" \
        "$ENTITLEMENTS_FILE" \
        "$ENTITLEMENTS_ERROR_FILE" \
        "$ENTITLEMENTS_LOOKUP_ERROR_FILE"
    if [[ "$DMG_MOUNT_ATTACHED" != true ]]; then
        rm -rf "$RELEASE_BUILD_DIR"
    else
        printf 'Leaving release build directory in place because DMG mount is still attached\n' >&2
    fi

    exit "$exit_status"
}

[[ -d "$PROJECT_PATH" ]] || die "Xcode project not found at $PROJECT_PATH"

for command in xcodebuild codesign ditto find hdiutil lipo readlink shasum spctl xcrun plutil python3; do
    command -v "$command" >/dev/null 2>&1 || die "required command not found: $command"
done
[[ -x "$PLIST_BUDDY" ]] || die "required command not found: $PLIST_BUDDY"

trap cleanup EXIT

rm -rf "$RELEASE_BUILD_DIR" "$DIST_PATH"
mkdir -p "$DERIVED_DATA_PATH" "$DIST_PATH"

printf 'Building AmbientSync %s (build %s) for arm64\n' "$VERSION" "$GITHUB_RUN_NUMBER"
xcodebuild -version
printf 'macOS SDK: '
xcrun --sdk macosx --show-sdk-version

xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme AmbientSync \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS='--timestamp'

APP_PATH=''
while IFS= read -r -d '' candidate; do
    if [[ -n "$APP_PATH" ]]; then
        die "multiple AmbientSync.app products found under $PRODUCTS_PATH"
    fi
    APP_PATH="$candidate"
done < <(find "$PRODUCTS_PATH" -type d -name AmbientSync.app -print0)

[[ -n "$APP_PATH" ]] || die "AmbientSync.app not found under $PRODUCTS_PATH"

APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -r "$APP_INFO_PLIST" ]] || die "AmbientSync Info.plist not found at $APP_INFO_PLIST"
APP_BUNDLE_IDENTIFIER=''
if ! APP_BUNDLE_IDENTIFIER="$("$PLIST_BUDDY" -c 'Print :CFBundleIdentifier' "$APP_INFO_PLIST" 2>/dev/null)"; then
    die 'unable to read AmbientSync bundle identifier'
fi
[[ "$APP_BUNDLE_IDENTIFIER" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] \
    || die "AmbientSync bundle identifier $APP_BUNDLE_IDENTIFIER does not match $EXPECTED_BUNDLE_IDENTIFIER"

APP_EXECUTABLE="$APP_PATH/Contents/MacOS/AmbientSync"
[[ -x "$APP_EXECUTABLE" ]] || die "AmbientSync executable not found at $APP_EXECUTABLE"
[[ "$(lipo -archs "$APP_EXECUTABLE")" == arm64 ]] \
    || die "AmbientSync executable is not arm64-only"

printf 'Verifying Developer ID signature before notarization\n'
codesign --verify --deep --strict --verbose=4 "$APP_PATH"
verify_signature_metadata 'AmbientSync.app' "$APP_PATH" true

printf 'Verifying effective signed entitlements before notarization\n'
validate_signed_entitlements

printf 'Creating pre-notarization archive\n'
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$PRE_NOTARY_ZIP"
notarize_artifact 'app ZIP' "$PRE_NOTARY_ZIP"

printf 'Stapling app notarization ticket\n'
xcrun stapler staple -v "$APP_PATH"
xcrun stapler validate -v "$APP_PATH"

printf 'Performing final app signature and Gatekeeper checks\n'
codesign --verify --deep --strict --verbose=4 "$APP_PATH"
verify_signature_metadata 'AmbientSync.app' "$APP_PATH" true
spctl --assess --type execute --verbose=4 "$APP_PATH"

printf 'Creating final ZIP archive\n'
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$FINAL_ZIP"
[[ -f "$FINAL_ZIP" ]] || die "final archive was not created at $FINAL_ZIP"

printf 'Staging plain AmbientSync DMG\n'
mkdir -p "$DMG_STAGING_DIR"
ditto "$APP_PATH" "$DMG_STAGING_DIR/AmbientSync.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

printf 'Creating compressed read-only UDZO DMG\n'
hdiutil create \
    -volname AmbientSync \
    -srcfolder "$DMG_STAGING_DIR" \
    -format UDZO \
    -ov \
    "$FINAL_DMG"

printf 'Signing DMG with secure timestamp\n'
codesign --force --sign "$APPLE_SIGNING_IDENTITY" --timestamp "$FINAL_DMG"
codesign --verify --strict --verbose=4 "$FINAL_DMG"
verify_signature_metadata 'DMG' "$FINAL_DMG" false
notarize_artifact 'DMG' "$FINAL_DMG"

printf 'Stapling DMG notarization ticket\n'
xcrun stapler staple -v "$FINAL_DMG"
xcrun stapler validate -v "$FINAL_DMG"

printf 'Verifying final DMG container\n'
hdiutil verify "$FINAL_DMG"
codesign --verify --strict --verbose=4 "$FINAL_DMG"
verify_signature_metadata 'DMG' "$FINAL_DMG" false
spctl -a -t open --context context:primary-signature -vv "$FINAL_DMG"

printf 'Mounting DMG for read-only contents verification\n'
mkdir -p "$DMG_MOUNT_POINT"
hdiutil attach \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$DMG_MOUNT_POINT" \
    "$FINAL_DMG" \
    >/dev/null
DMG_MOUNT_ATTACHED=true

found_app=false
found_applications=false
while IFS= read -r -d '' entry; do
    entry_name="${entry##*/}"
    case "$entry_name" in
        AmbientSync.app)
            [[ "$found_app" == false ]] || die 'DMG contains duplicate AmbientSync.app root entries'
            found_app=true
            ;;
        Applications)
            [[ "$found_applications" == false ]] || die 'DMG contains duplicate Applications root entries'
            found_applications=true
            ;;
        .DS_Store|.Trashes|.fseventsd|.vol|.VolumeIcon.icns|.metadata_never_index)
            printf 'Tolerating explicit DMG filesystem metadata: %s\n' "$entry_name"
            ;;
        *)
            die "DMG contains unexpected root entry: $entry_name"
            ;;
    esac
done < <(find "$DMG_MOUNT_POINT" -mindepth 1 -maxdepth 1 -print0)

[[ "$found_app" == true ]] || die 'DMG is missing AmbientSync.app at root'
[[ "$found_applications" == true ]] || die 'DMG is missing Applications symlink at root'
[[ -d "$DMG_MOUNT_POINT/AmbientSync.app" && ! -L "$DMG_MOUNT_POINT/AmbientSync.app" ]] \
    || die 'DMG AmbientSync.app root entry is not a bundle directory'
[[ -L "$DMG_MOUNT_POINT/Applications" ]] || die 'DMG Applications root entry is not a symlink'
[[ "$(readlink "$DMG_MOUNT_POINT/Applications")" == /Applications ]] \
    || die 'DMG Applications symlink does not target /Applications'

MOUNTED_APP_PATH="$DMG_MOUNT_POINT/AmbientSync.app"
MOUNTED_APP_EXECUTABLE="$MOUNTED_APP_PATH/Contents/MacOS/AmbientSync"
[[ -x "$MOUNTED_APP_EXECUTABLE" ]] || die 'mounted DMG app executable is missing'
[[ "$(lipo -archs "$MOUNTED_APP_EXECUTABLE")" == arm64 ]] \
    || die 'mounted DMG app is not arm64-only'
codesign --verify --deep --strict --verbose=4 "$MOUNTED_APP_PATH"
xcrun stapler validate -v "$MOUNTED_APP_PATH"
spctl -a -t exec -vv "$MOUNTED_APP_PATH"

detach_dmg || die 'unable to detach DMG before publishing'
[[ "$DMG_MOUNT_ATTACHED" == false ]] || die 'DMG mount is still attached before publishing'

printf 'Writing SHA-256 checksum assets\n'
(cd "$DIST_PATH" && shasum -a 256 "$(basename "$FINAL_ZIP")" > "$(basename "$ZIP_CHECKSUM")")
(cd "$DIST_PATH" && shasum -a 256 "$(basename "$FINAL_DMG")" > "$(basename "$DMG_CHECKSUM")")
[[ -s "$ZIP_CHECKSUM" ]] || die "ZIP checksum asset was not created at $ZIP_CHECKSUM"
[[ -s "$DMG_CHECKSUM" ]] || die "DMG checksum asset was not created at $DMG_CHECKSUM"

printf 'Release asset: %s\n' "$FINAL_ZIP"
printf 'Release asset: %s\n' "$FINAL_DMG"
printf 'Release checksum: %s\n' "$ZIP_CHECKSUM"
printf 'Release checksum: %s\n' "$DMG_CHECKSUM"
