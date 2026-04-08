#!/bin/bash
# Utilities for loading test skip patterns from config files.
# Source this file to use these functions in test wrapper scripts.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/load-skip-patterns.sh"
#   load_ginkgo_skip_patterns /usr/local/config/skip-sequential.txt
#   load_playwright_skip_patterns /usr/local/config/skip-ui-e2e.txt

# Load skip patterns from a config file and append to GINKGO_SKIP env var.
# Config file format: one pattern per line, # for comments, blank lines ignored.
# Patterns are joined with '|' to form a regex for ginkgo's --skip flag.
#
# Args:
#   $1 - skip_file: Path to skip patterns config file
#
# Sets:
#   GINKGO_SKIP environment variable (appends if already set)
#
# Returns:
#   0 on success, 1 if file not found
#
# Example:
#   load_ginkgo_skip_patterns /usr/local/config/skip-sequential.txt
#   # GINKGO_SKIP is now set to "pattern1|pattern2|pattern3"
load_ginkgo_skip_patterns() {
    local skip_file=$1

    if [[ ! -f "$skip_file" ]]; then
        return 1
    fi

    local skip_pattern
    skip_pattern=$(grep -v '^\s*#' "$skip_file" | grep -v '^\s*$' | paste -sd '|')

    if [[ -n "$skip_pattern" ]]; then
        if [[ -n "${GINKGO_SKIP:-}" ]]; then
            export GINKGO_SKIP="${GINKGO_SKIP}|${skip_pattern}"
        else
            export GINKGO_SKIP="$skip_pattern"
        fi
    fi

    return 0
}

# Load skip patterns from a config file for Playwright's --grep-invert flag.
# Config file format: one pattern per line, # for comments, blank lines ignored.
# Patterns are joined with '|' to form a regex.
#
# Args:
#   $1 - skip_file: Path to skip patterns config file
#
# Returns:
#   An array of playwright arguments: (--grep-invert "pattern1|pattern2")
#   Empty array if no patterns found or file doesn't exist
#
# Example:
#   PLAYWRIGHT_ARGS=($(load_playwright_skip_patterns /usr/local/config/skip-ui-e2e.txt))
#   npx playwright test "${PLAYWRIGHT_ARGS[@]}"
load_playwright_skip_patterns() {
    local skip_file=$1

    if [[ ! -f "$skip_file" ]]; then
        return 0
    fi

    local skip_pattern
    skip_pattern=$(grep -v '^\s*#' "$skip_file" | grep -v '^\s*$' | paste -sd '|')

    if [[ -n "$skip_pattern" ]]; then
        echo "--grep-invert"
        echo "$skip_pattern"
    fi

    return 0
}
