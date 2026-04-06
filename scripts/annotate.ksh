#! /bin/ksh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Annotate non-compliant files with SPDX headers using the reuse tool.
# Requires: reuse (pip install reuse), jq
#
# Usage: scripts/annotate.ksh

typeset files=$(reuse lint --json \
  | jq -r '.non_compliant
    | add(.missing_copyright_info, .missing_licensing_info)
    | unique[]') || true

[ -z "$files" ] && exit 0

function annotate {
    xargs -r reuse annotate \
        --copyright="Todd Schulman" \
        --merge-copyrights \
        --license=GPL-3.0-or-later \
        --copyright-prefix=spdx-string \
        "$@"
}

printf '%s\n' "$files" | grep -E '\.(m|h)$'  | annotate --style=c
printf '%s\n' "$files" | grep -vE '\.(m|h)$' | annotate --fallback-dot-license
