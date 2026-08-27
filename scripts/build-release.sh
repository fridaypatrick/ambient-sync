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
DERIVED_DATA_PATH="$ROOT_DIR/.build/release/DerivedData"
PRODUCTS_PATH="$DERIVED_DATA_PATH/Build/Products/Release"
DIST_PATH="$ROOT_DIR/dist"
PRE_NOTARY_ZIP="$ROOT_DIR/.build/release/AmbientSync-${VERSION}.pre-notarization.zip"
FINAL_ZIP="$DIST_PATH/AmbientSync-${VERSION}.zip"

[[ -d "$PROJECT_PATH" ]] || die "Xcode project not found at $PROJECT_PATH"

for command in xcodebuild codesign ditto lipo spctl xcrun; do
    command -v "$command" >/dev/null 2>&1 || die "required command not found: $command"
done

cleanup() {
    rm -f "$PRE_NOTARY_ZIP"
}
trap cleanup EXIT

rm -rf "$ROOT_DIR/.build/release" "$DIST_PATH"
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

printf 'Creating pre-notarization archive\n'
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$PRE_NOTARY_ZIP"

printf 'Submitting archive for notarization\n'
xcrun notarytool submit "$PRE_NOTARY_ZIP" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" \
    --wait

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
