#!/usr/bin/env bash

# Source this file from release automation. Component comparison is string
# based so arbitrarily large nonnegative decimal components do not overflow.
export LC_ALL=C

canonical_decimal() {
    local value="$1"
    while [[ ${#value} -gt 1 && ${value:0:1} == 0 ]]; do
        value="${value:1}"
    done
    printf '%s' "$value"
}

decimal_is_greater() {
    local left_value right_value
    left_value="$(canonical_decimal "$1")"
    right_value="$(canonical_decimal "$2")"
    if (( ${#left_value} != ${#right_value} )); then
        (( ${#left_value} > ${#right_value} ))
    else
        [[ "$left_value" > "$right_value" ]]
    fi
}

version_is_greater() {
    local left_version="$1"
    local right_version="$2"
    local left_major left_minor left_patch
    local right_major right_minor right_patch

    IFS=. read -r left_major left_minor left_patch <<< "$left_version"
    IFS=. read -r right_major right_minor right_patch <<< "$right_version"
    if decimal_is_greater "$left_major" "$right_major"; then
        return 0
    elif decimal_is_greater "$right_major" "$left_major"; then
        return 1
    elif decimal_is_greater "$left_minor" "$right_minor"; then
        return 0
    elif decimal_is_greater "$right_minor" "$left_minor"; then
        return 1
    elif decimal_is_greater "$left_patch" "$right_patch"; then
        return 0
    fi
    return 1
}
