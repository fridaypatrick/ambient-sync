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
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/AmbientSync.xcodeproj"
RELEASE_BUILD_DIR="$ROOT_DIR/.build/release"
DERIVED_DATA_PATH="$RELEASE_BUILD_DIR/DerivedData"
PRODUCTS_PATH="$DERIVED_DATA_PATH/Build/Products/Release"
DIST_PATH="$ROOT_DIR/dist"
PRE_NOTARY_ZIP="$RELEASE_BUILD_DIR/AmbientSync-${VERSION}.pre-notarization.zip"
FINAL_ZIP="$DIST_PATH/AmbientSync-${VERSION}.zip"
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
    local log_file="$1"
    local parse_error_file="$2"

    python3 - "$log_file" 2> "$parse_error_file" <<'PY'
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
    with open(sys.argv[1], "rb") as log:
        payload = json.load(log)
except (OSError, TypeError, UnicodeError, ValueError):
    fail("notarytool log response is not valid JSON")

if not isinstance(payload, dict):
    fail("notarytool log response is not a JSON object")

print("status: {}".format(clean(payload.get("status"))))
print("statusSummary: {}".format(clean(payload.get("statusSummary"))))

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
    print("issue:")
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

[[ -d "$PROJECT_PATH" ]] || die "Xcode project not found at $PROJECT_PATH"

for command in xcodebuild codesign ditto lipo spctl xcrun plutil python3; do
    command -v "$command" >/dev/null 2>&1 || die "required command not found: $command"
done
[[ -x "$PLIST_BUDDY" ]] || die "required command not found: $PLIST_BUDDY"

cleanup() {
    rm -f \
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
}
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

APP_EXECUTABLE="$APP_PATH/Contents/MacOS/AmbientSync"
[[ -x "$APP_EXECUTABLE" ]] || die "AmbientSync executable not found at $APP_EXECUTABLE"
[[ "$(lipo -archs "$APP_EXECUTABLE")" == arm64 ]] \
    || die "AmbientSync executable is not arm64-only"

printf 'Verifying Developer ID signature before notarization\n'
codesign --verify --deep --strict --verbose=4 "$APP_PATH"
SIGNATURE_DETAILS="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)" \
    || die "unable to inspect AmbientSync.app signature"
[[ "$SIGNATURE_DETAILS" == *"Authority=$APPLE_SIGNING_IDENTITY"* ]] \
    || die "AmbientSync.app is not signed with APPLE_SIGNING_IDENTITY"
[[ "$SIGNATURE_DETAILS" == *"TeamIdentifier=$APPLE_TEAM_ID"* ]] \
    || die "AmbientSync.app is not signed for APPLE_TEAM_ID"

CODE_DIRECTORY_LINE=''
while IFS= read -r signature_line; do
    if [[ "$signature_line" =~ ^CodeDirectory[[:space:]] ]]; then
        [[ -z "$CODE_DIRECTORY_LINE" ]] \
            || die "AmbientSync.app signature contains multiple CodeDirectory lines"
        CODE_DIRECTORY_LINE="$signature_line"
    fi
done <<< "$SIGNATURE_DETAILS"
[[ -n "$CODE_DIRECTORY_LINE" ]] \
    || die "AmbientSync.app signature does not contain a CodeDirectory line"

CODE_DIRECTORY_FLAGS=''
CODE_DIRECTORY_FLAGS_PATTERN='flags=0x[[:xdigit:]]+\(([^)]*)\)'
if [[ "$CODE_DIRECTORY_LINE" =~ $CODE_DIRECTORY_FLAGS_PATTERN ]]; then
    CODE_DIRECTORY_FLAGS="${BASH_REMATCH[1]}"
fi
[[ ",$CODE_DIRECTORY_FLAGS," == *,runtime,* ]] \
    || die "AmbientSync.app signature does not enable hardened runtime"

TIMESTAMP_VALUE=''
while IFS= read -r signature_line; do
    if [[ "$signature_line" == Timestamp=* ]]; then
        TIMESTAMP_VALUE="${signature_line#Timestamp=}"
        break
    fi
done <<< "$SIGNATURE_DETAILS"
[[ -n "$TIMESTAMP_VALUE" && "$TIMESTAMP_VALUE" != none* ]] \
    || die "AmbientSync.app signature does not contain a secure timestamp"

printf 'Verifying effective signed entitlements before notarization\n'
validate_signed_entitlements

printf 'Creating pre-notarization archive\n'
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$PRE_NOTARY_ZIP"

printf 'Submitting archive for notarization\n'
NOTARY_SUBMIT_EXIT_STATUS=0
if xcrun notarytool submit "$PRE_NOTARY_ZIP" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" \
    --wait \
    --timeout 30m \
    --output-format json \
    --no-progress \
    > "$NOTARY_SUBMIT_RESPONSE_FILE" \
    2> "$NOTARY_SUBMIT_ERROR_FILE"; then
    NOTARY_SUBMIT_EXIT_STATUS=0
else
    NOTARY_SUBMIT_EXIT_STATUS=$?
fi

if [[ ! -s "$NOTARY_SUBMIT_RESPONSE_FILE" ]]; then
    print_captured_output 'notarytool submit stderr:' "$NOTARY_SUBMIT_ERROR_FILE"
    die "notarytool submit returned no JSON response (exit status $NOTARY_SUBMIT_EXIT_STATUS)"
fi
if ! parse_notary_submission_response \
    "$NOTARY_SUBMIT_RESPONSE_FILE" \
    "$NOTARY_SUBMIT_FIELDS_FILE" \
    "$NOTARY_SUBMIT_PARSE_ERROR_FILE"; then
    print_captured_output 'notarytool submit stderr:' "$NOTARY_SUBMIT_ERROR_FILE"
    print_captured_output 'notarytool submit JSON parse stderr:' "$NOTARY_SUBMIT_PARSE_ERROR_FILE"
    die "notarytool submit returned empty or malformed JSON (exit status $NOTARY_SUBMIT_EXIT_STATUS)"
fi

NOTARY_STATUS=''
NOTARY_ID=''
if ! IFS=$'\t' read -r NOTARY_STATUS NOTARY_ID < "$NOTARY_SUBMIT_FIELDS_FILE"; then
    print_captured_output 'notarytool submit stderr:' "$NOTARY_SUBMIT_ERROR_FILE"
    die "unable to read parsed notarytool status and id"
fi
[[ -n "$NOTARY_STATUS" && -n "$NOTARY_ID" ]] \
    || die "notarytool submit response did not contain status and id"
[[ "$NOTARY_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || die "notarytool submit response id is not a canonical UUID"

printf 'Notarization status: %s\n' "$NOTARY_STATUS"
if (( NOTARY_SUBMIT_EXIT_STATUS != 0 )) || [[ "$NOTARY_STATUS" != Accepted ]]; then
    print_captured_output 'notarytool submit stderr:' "$NOTARY_SUBMIT_ERROR_FILE"

    if [[ "$NOTARY_STATUS" != Accepted ]]; then
        printf 'Fetching notarization diagnostics\n' >&2
        NOTARY_LOG_EXIT_STATUS=0
        if xcrun notarytool log "$NOTARY_ID" \
            --key "$APPLE_API_KEY_PATH" \
            --key-id "$APPLE_API_KEY_ID" \
            --issuer "$APPLE_API_ISSUER_ID" \
            --output-format json \
            > "$NOTARY_LOG_RESPONSE_FILE" \
            2> "$NOTARY_LOG_ERROR_FILE"; then
            NOTARY_LOG_EXIT_STATUS=0
        else
            NOTARY_LOG_EXIT_STATUS=$?
        fi

        if (( NOTARY_LOG_EXIT_STATUS != 0 )); then
            print_captured_output 'notarytool log stderr:' "$NOTARY_LOG_ERROR_FILE"
            die "unable to fetch notarization diagnostics (exit status $NOTARY_LOG_EXIT_STATUS)"
        fi
        if [[ ! -s "$NOTARY_LOG_RESPONSE_FILE" ]]; then
            print_captured_output 'notarytool log stderr:' "$NOTARY_LOG_ERROR_FILE"
            die "notarytool log returned no JSON response"
        fi
        if ! print_notary_log_diagnostics \
            "$NOTARY_LOG_RESPONSE_FILE" \
            "$NOTARY_LOG_PARSE_ERROR_FILE" >&2; then
            print_captured_output 'notarytool log stderr:' "$NOTARY_LOG_ERROR_FILE"
            print_captured_output 'notarytool log JSON parse stderr:' "$NOTARY_LOG_PARSE_ERROR_FILE"
            die "notarytool log returned malformed JSON"
        fi
    fi

    if (( NOTARY_SUBMIT_EXIT_STATUS != 0 )); then
        die "notarytool submit failed before stapling (exit status $NOTARY_SUBMIT_EXIT_STATUS)"
    fi
    die "notarization was not accepted before stapling"
fi

printf 'Stapling notarization ticket\n'
xcrun stapler staple -v "$APP_PATH"
xcrun stapler validate -v "$APP_PATH"

rm -f "$PRE_NOTARY_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$FINAL_ZIP"
[[ -f "$FINAL_ZIP" ]] || die "final archive was not created at $FINAL_ZIP"

printf 'Performing final signature and Gatekeeper checks\n'
codesign --verify --deep --strict --verbose=4 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

printf 'Release asset: %s\n' "$FINAL_ZIP"
