#!/usr/bin/env bash

set -Eeuo pipefail

die() {
    printf 'cask update: %s\n' "$*" >&2
    exit 1
}

if (( $# != 2 )); then
    die "usage: $0 VERSION DMG_SHA256"
fi

VERSION="$1"
DMG_SHA256="$2"
STABLE_VERSION_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ "$VERSION" =~ $STABLE_VERSION_PATTERN ]] || die "VERSION must be a stable semantic version"
[[ "$DMG_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]] || die "DMG_SHA256 must be a 64-character SHA-256 digest"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CASK_DIRECTORY="$ROOT_DIR/Casks"
CASK_PATH="${CASK_OUTPUT_PATH:-$CASK_DIRECTORY/ambientsync.rb}"
CASK_DIRECTORY="$(dirname -- "$CASK_PATH")"
TEMP_PATH="$CASK_PATH.tmp.$$"
NORMALIZED_DMG_SHA256="$(printf '%s' "$DMG_SHA256" | tr '[:upper:]' '[:lower:]')"
EXPECTED_URL="  url \"https://github.com/fridaypatrick/ambient-sync/releases/download/v${VERSION}/AmbientSync-${VERSION}-arm64.dmg\""

cleanup() {
    if [[ -n "$TEMP_PATH" ]]; then
        rm -f "$TEMP_PATH"
    fi
}
trap cleanup EXIT

umask 022
mkdir -p "$CASK_DIRECTORY"
{
    printf 'cask "ambientsync" do\n'
    printf '  version "%s"\n' "$VERSION"
    printf '  sha256 "%s"\n\n' "$NORMALIZED_DMG_SHA256"
    printf '%s\n' "$EXPECTED_URL"
    printf '  name "AmbientSync"\n'
    printf '  desc "Synchronizes ambient display brightness and appearance"\n'
    printf '  homepage "https://github.com/fridaypatrick/ambient-sync"\n\n'
    printf '  arch arm: "arm64"\n'
    printf '  depends_on arch: :arm64\n'
    printf '  depends_on macos: :tahoe\n\n'
    printf '  # CFBundleIdentifier: cloud.piatkowski.AmbientSync\n'
    printf '  app "AmbientSync.app"\n\n'
    printf '  caveats <<~EOS\n'
    printf '    AmbientSync requires macOS 26 or newer on Apple silicon.\n'
    printf '    AmbientSync may request Automation access to System Events for appearance synchronization.\n'
    printf '  EOS\n'
    printf 'end\n'
} > "$TEMP_PATH"

mv "$TEMP_PATH" "$CASK_PATH"
TEMP_PATH=''

rendered_url=''
while IFS= read -r line; do
    if [[ "$line" == '  url '* ]]; then
        [[ -z "$rendered_url" ]] || die 'rendered cask contains multiple URL stanzas'
        rendered_url="$line"
    fi
done < "$CASK_PATH"
[[ "$rendered_url" == "$EXPECTED_URL" ]] \
    || die "rendered cask URL does not match expected arm64 asset: $rendered_url"

printf 'Rendered cask: %s\n' "$CASK_PATH"
