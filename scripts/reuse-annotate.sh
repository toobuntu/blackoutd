#!/bin/sh
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# reuse-annotate.sh — Add SPDX headers to files.
#
# Usage:
#   scripts/reuse-annotate.sh <file> [file...]
#
# For files that support comments (.m, .h, .c, .sh, .yml, .yaml, Makefile):
#   Adds an inline SPDX header at the top.
#
# For files that do not support comments (.plist, .json, dotfiles like
# .gitignore, .clang-format, .rspec):
#   Creates a companion .license sidecar file per the REUSE spec.
#
# The REUSE spec: https://reuse.software/spec-3.3/

set -e

YEAR="2026"
HOLDER="Todd Schulman"
LICENSE="GPL-3.0-or-later"

comment_header() {
    printf '# SPDX-FileCopyrightText: Copyright %s %s\n' "$YEAR" "$HOLDER"
    printf '#\n'
    printf '# SPDX-License-Identifier: %s\n' "$LICENSE"
}

c_comment_header() {
    printf '/*\n'
    printf ' * SPDX-FileCopyrightText: Copyright %s %s\n' "$YEAR" "$HOLDER"
    printf ' *\n'
    printf ' * SPDX-License-Identifier: %s\n' "$LICENSE"
    printf ' */\n'
}

html_comment_header() {
    printf '<!--\n'
    printf 'SPDX-FileCopyrightText: Copyright %s %s\n' "$YEAR" "$HOLDER"
    printf '\n'
    printf 'SPDX-License-Identifier: %s\n' "$LICENSE"
    printf '-->\n'
}

sidecar_content() {
    printf 'SPDX-FileCopyrightText: Copyright %s %s\n' "$YEAR" "$HOLDER"
    printf '\n'
    printf 'SPDX-License-Identifier: %s\n' "$LICENSE"
}

annotate_file() {
    file="$1"
    base=$(/usr/bin/basename "$file")

    # Skip if already annotated.
    if /usr/bin/grep -q 'SPDX-FileCopyrightText' "$file" 2>/dev/null; then
        printf 'skip: %s (already annotated)\n' "$file"
        return
    fi

    case "$base" in
        *.m|*.h|*.c)
            { c_comment_header; printf '\n'; cat "$file"; } > "$file.tmp"
            mv "$file.tmp" "$file"
            printf 'annotated: %s (C comment)\n' "$file"
            ;;
        *.sh)
            # Preserve shebang if present.
            if head -1 "$file" | /usr/bin/grep -q '^#!'; then
                { head -1 "$file"; comment_header; /usr/bin/tail -n +2 "$file"; } > "$file.tmp"
            else
                { comment_header; printf '\n'; cat "$file"; } > "$file.tmp"
            fi
            mv "$file.tmp" "$file"
            printf 'annotated: %s (shell comment)\n' "$file"
            ;;
        *.yml|*.yaml|Makefile|Makefile.*)
            { comment_header; printf '\n'; cat "$file"; } > "$file.tmp"
            mv "$file.tmp" "$file"
            printf 'annotated: %s (# comment)\n' "$file"
            ;;
        *.md)
            { html_comment_header; printf '\n'; cat "$file"; } > "$file.tmp"
            mv "$file.tmp" "$file"
            printf 'annotated: %s (HTML comment)\n' "$file"
            ;;
        *)
            # Sidecar .license file for formats that do not support comments.
            sidecar="${file}.license"
            if [ -f "$sidecar" ]; then
                printf 'skip: %s (sidecar already exists)\n' "$file"
                return
            fi
            sidecar_content > "$sidecar"
            printf 'annotated: %s (sidecar %s)\n' "$file" "$sidecar"
            ;;
    esac
}

if [ $# -eq 0 ]; then
    printf 'Usage: %s <file> [file...]\n' "$0" >&2
    exit 1
fi

for f in "$@"; do
    annotate_file "$f"
done
