#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/ambient-sync-cask.XXXXXX")"
FIXTURE_PATH="$FIXTURE_DIRECTORY/ambientsync.rb"
FIXTURE_VERSION='1.2.3'
FIXTURE_SHA256='ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789'
EXPECTED_SHA256='abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
EXPECTED_URL="  url \"https://github.com/fridaypatrick/ambient-sync/releases/download/v${FIXTURE_VERSION}/AmbientSync-${FIXTURE_VERSION}-arm64.dmg\""

cleanup() {
    rm -rf "$FIXTURE_DIRECTORY"
}
trap cleanup EXIT

fail() {
    printf 'cask fixture: %s\n' "$*" >&2
    exit 1
}

CASK_OUTPUT_PATH="$FIXTURE_PATH" "$SCRIPT_DIR/update-cask.sh" "$FIXTURE_VERSION" "$FIXTURE_SHA256"
[[ -f "$FIXTURE_PATH" ]] || fail 'renderer did not create fixture output'
ruby -c "$FIXTURE_PATH"

version_count=0
version_value=''
sha_count=0
sha_value=''
rendered_url=''
arch_line_count=0
macos_line_count=0
app_line_count=0
version_line_pattern='^[[:space:]]*version[[:space:]]+"([0-9]+\.[0-9]+\.[0-9]+)"[[:space:]]*$'
sha_line_pattern='^[[:space:]]*sha256[[:space:]]+"([0-9A-Fa-f]{64})"[[:space:]]*$'
while IFS= read -r line; do
    if [[ "$line" =~ $version_line_pattern ]]; then
        version_count=$((version_count + 1))
        version_value="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ $sha_line_pattern ]]; then
        sha_count=$((sha_count + 1))
        sha_value="${BASH_REMATCH[1]}"
    elif [[ "$line" == '  url '* ]]; then
        [[ -z "$rendered_url" ]] || fail 'fixture contains multiple URL stanzas'
        rendered_url="$line"
    elif [[ "$line" == '  arch arm: "arm64"' ]]; then
        arch_line_count=$((arch_line_count + 1))
    elif [[ "$line" == '  depends_on arch: :arm64' || "$line" == '  depends_on macos: :tahoe' ]]; then
        if [[ "$line" == '  depends_on arch: :arm64' ]]; then
            arch_line_count=$((arch_line_count + 1))
        else
            macos_line_count=$((macos_line_count + 1))
        fi
    elif [[ "$line" == '  app "AmbientSync.app"' ]]; then
        app_line_count=$((app_line_count + 1))
    fi
done < "$FIXTURE_PATH"

[[ "$version_count" -eq 1 && "$version_value" == "$FIXTURE_VERSION" ]] \
    || fail "expected one exact version stanza, got count=$version_count value=$version_value"
[[ "$sha_count" -eq 1 && "$sha_value" == "$EXPECTED_SHA256" ]] \
    || fail "expected one lowercase normalized SHA stanza, got count=$sha_count value=$sha_value"
[[ "$rendered_url" == "$EXPECTED_URL" ]] \
    || fail "fixture URL mismatch: $rendered_url"
[[ "$arch_line_count" -eq 2 ]] || fail "expected arm64 architecture requirements"
[[ "$macos_line_count" -eq 1 ]] || fail 'expected macOS 26 dependency'
[[ "$app_line_count" -eq 1 ]] || fail 'expected one AmbientSync.app stanza'

assert_rejected() {
    local label="$1"
    local version="$2"
    local sha256="$3"
    local output_path="$FIXTURE_DIRECTORY/$label.rb"

    if CASK_OUTPUT_PATH="$output_path" "$SCRIPT_DIR/update-cask.sh" "$version" "$sha256" >/dev/null 2>&1; then
        fail "malformed $label input was accepted"
    fi
    [[ ! -e "$output_path" ]] || fail "malformed $label input created output"
}

assert_rejected 'bad-version' '1.2' "$FIXTURE_SHA256"
assert_rejected 'bad-sha' "$FIXTURE_VERSION" 'not-a-sha256'

printf 'Cask fixture contract passed: %s\n' "$rendered_url"
