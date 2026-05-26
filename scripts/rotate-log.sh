#!/bin/sh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Rotate a daemon log file. If the log is non-empty, move it aside to a
# UTC-timestamped archive and prune to the most recent N archives. Meant to be
# called from the Makefile (dev/reinstall) while the launchd agent is stopped,
# so no process holds the file open and the move is safe. Interim hygiene until
# P27 moves logging from NSLog to os_log and removes the plaintext file
# entirely. See docs/technical-debt.md P27.
#
# Usage: scripts/rotate-log.sh <logfile> [keep]
#   keep defaults to 5.

set -eu

die() {
    printf 'rotate-log: %s\n' "$1" >&2
    exit 1
}

is_decimal() {
    case "$1" in
    "" | *[!0-9]*) return 1 ;;
    *)             return 0 ;;
    esac
}

# Delete all but the newest _keep archives of _log. Archive names are UTC
# timestamps with no whitespace, so word-splitting the ls output is safe.
prune_archives() {
    _log=$1
    _keep=$2
    ls -1t -- "$_log".* 2>/dev/null \
        | tail -n +$((_keep + 1)) \
        | while IFS= read -r _old; do
            rm -f -- "$_old"
        done
}

rotate() {
    _log=$1
    _keep=$2
    [ -s "$_log" ] || return 0
    _archive=$_log.$(date -u +%Y%m%dT%H%M%SZ)
    if [ -e "$_archive" ]; then
        die "archive already exists: $_archive"
    fi
    mv -- "$_log" "$_archive"
    prune_archives "$_log" "$_keep"
    printf 'rotate-log: archived %s -> %s\n' "$_log" "$_archive"
}

main() {
    [ $# -ge 1 ] || die "usage: $(basename "$0") <logfile> [keep]"
    _logfile=$1
    _keep=${2:-5}
    is_decimal "$_keep" || die "keep must be a non-negative integer: $_keep"
    rotate "$_logfile" "$_keep"
}

main "$@"
