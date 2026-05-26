#!/bin/ksh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

readonly DEBUG_DIR="docs/debug"

list_present() {
    find "${DEBUG_DIR}" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; |
        sort
}

list_tracked() {
    git ls-files "${DEBUG_DIR}" | cut -d/ -f3 | sort -u
}

list_allowed() {
    grep '^!docs/debug/blackoutd-diag' .gitignore |
        sed 's|^!docs/debug/||; s|/$||' |
        sort
}

# Count non-empty lines, reporting 0 (not 1) for the empty set.
count() {
    printf '%s' "$1" | grep -c . || true
}

report_diff() {
    printf '\n=== %s ===\n' "$1"
    comm -23 <(printf '%s\n' "$2") <(printf '%s\n' "$3")
}

main() {
    present=$(list_present)
    tracked=$(list_tracked)
    allowed=$(list_allowed)

    printf '\n=== COUNTS ===\n'
    printf 'present: %3u\n' "$(count "${present}")"
    printf 'tracked: %3u\n' "$(count "${tracked}")"
    printf 'allowed: %3u\n' "$(count "${allowed}")"

    report_diff 'PRESENT BUT NOT ALLOWED' "${present}" "${allowed}"
    report_diff 'ALLOWED BUT NOT TRACKED' "${allowed}" "${tracked}"
    report_diff 'TRACKED BUT NOT ALLOWED' "${tracked}" "${allowed}"

    printf '\n=== RAW HEAVY LOGS TRACKED (should be empty; commit .zst) ===\n'
    git ls-files "${DEBUG_DIR}/*/windowserver.txt" "${DEBUG_DIR}/*/ioreg.txt"
}

main "$@"
