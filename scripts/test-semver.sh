#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090,SC1091 # Test sources helper beside this script.
source "$SCRIPT_DIR/semver.sh"

fail() {
    printf 'semver fixture: %s\n' "$*" >&2
    exit 1
}

assert_greater() {
    local left="$1"
    local right="$2"
    version_is_greater "$left" "$right" \
        || fail "expected $left to be greater than $right"
}

assert_not_greater() {
    local left="$1"
    local right="$2"
    if version_is_greater "$left" "$right"; then
        fail "expected $left not to be greater than $right"
    fi
}

assert_greater '18446744073709551616.0.0' '18446744073709551615.999.999'
assert_greater '1.18446744073709551616.0' '1.18446744073709551615.999'
assert_greater '1.2.18446744073709551616' '1.2.18446744073709551615'
assert_greater '1.10.0' '1.9.99'
assert_greater '2.0.0' '1.999.999'
assert_not_greater '0001.0002.0003' '1.2.3'
assert_not_greater '1.2.3' '1.2.3'

printf 'SemVer arbitrary-digit fixtures passed\n'
