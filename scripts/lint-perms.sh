#!/bin/sh
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# scripts/lint-perms.sh — verify execute bit on shipped scripts.
# Single source of truth for the policy used by .githooks/pre-commit
# (--staged) and the lint-perms job in .github/workflows/ci.yml
# (--tracked). NUL transport throughout so whitespace or newlines in
# paths cannot corrupt the check.
set -eu

# Anchored regex: anything under scripts/ ending in .sh (recursive),
# plus an explicit allowlist of supported git hooks under .githooks/.
# Add a new hook to the alternation when one is introduced; do not
# replace the allowlist with a pattern. .sample suffixes and
# subdirectories are deliberately excluded.
PERMS_PATTERN='^scripts/.*\.sh$|^\.githooks/pre-commit$'

scope=${1:-}
fmt=${LINT_PERMS_FORMAT:-shell}

usage() {
    rc=${1:-2}
    if [ "$rc" = "0" ]; then
        cat <<EOF
Usage: $0 --staged|--tracked

  --staged   Check files staged for commit; used by .githooks/pre-commit
  --tracked  Check all tracked files; used by the CI lint-perms job

Environment:
  LINT_PERMS_FORMAT=shell  Human-readable errors to stderr (default)
  LINT_PERMS_FORMAT=ci     GitHub Annotations to stdout
EOF
        exit 0
    fi
    cat <<EOF >&2
Usage: $0 --staged|--tracked
  LINT_PERMS_FORMAT=shell|ci  (default shell)
EOF
    exit "$rc"
}

case "$scope" in
    --help | -h) usage 0 ;;
    --staged | --tracked) ;;
    *) usage 2 ;;
esac

# --staged restricts to the index diff with --diff-filter=ACMRT:
# Added, Copied, Modified, Renamed, Type-changed. Deletions (D) and
# unmerged (U) are excluded — there is no present blob to check.
# Renames are included so a script moved to a new path is re-checked
# at its destination (--name-only emits the post-image path); type
# changes so a symlink->regular-file flip is re-checked.
emit_paths() {
    case "$scope" in
        --staged) git diff --cached --name-only --diff-filter=ACMRT -z ;;
        --tracked) git ls-files -z ;;
    esac
}

# Filter NUL records with /usr/bin/grep (BSD-GNU-compat on macOS 13+,
# GNU on Linux); then run a per-file sub-shell via `xargs -0 -n 1`.
# `-r` suppresses xargs invocation on empty input. Each offending file
# exits non-zero from its sub-shell; xargs returns the worst exit code,
# and set -e propagates it as the script's exit status. grep's
# exit-1-on-no-match in the middle of the pipeline is invisible to
# set -e (pipefail is not set), so xargs's 0 stands.
emit_paths \
    | /usr/bin/grep --extended-regexp --null-data "$PERMS_PATTERN" \
    | xargs -0 -r -n 1 sh -c '
        fmt=$1
        file=$2
        mode=$(git ls-files --stage -- "$file" | cut -d " " -f 1)
        # 100755: executable regular file (correct). 120000: symlink —
        # the exec bit lives on the target, not the link, so skip.
        # Empty: path not in the index (e.g. a vanished race entry);
        # nothing to check.
        case "$mode" in
            "" | 100755 | 120000) exit 0 ;;
        esac
        fix="chmod 755 \"$file\" && git update-index --chmod=+x \"$file\""
        case "$fmt" in
            ci)
                printf "::error file=%s::missing execute bit (mode %s)\nFix: %s\n" \
                    "$file" "$mode" "$fix"
                ;;
            shell)
                printf "error: %s: missing execute bit (mode %s)\n  Fix: %s\n" \
                    "$file" "$mode" "$fix" >&2
                ;;
            *)
                printf "error: unknown LINT_PERMS_FORMAT: %s (want shell|ci)\n" \
                    "$fmt" >&2
                exit 2
                ;;
        esac
        exit 1
    ' _ "$fmt"
