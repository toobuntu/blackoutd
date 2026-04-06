#!/usr/bin/env bash
# Annotates non-REUSE-compliant files with SPDX copyright and license headers.
# Requires: reuse (pip install reuse or brew install reuse), jq
#
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

files=$(reuse lint --json |
  jq -r '.non_compliant | (.missing_copyright_info + .missing_licensing_info) | unique[]') || true

[[ -z ${files} ]] && exit 0

annotate() {
  xargs reuse annotate \
    --copyright="Todd Schulman" \
    --merge-copyrights \
    --license=GPL-3.0-or-later \
    --copyright-prefix=spdx-string \
    "$@"
}

# Objective-C source files need C-style block comments (/* ... */).
c_files=$(printf '%s\n' "${files}" | grep -E '\.(m|h|c)$' || true)
# Shell scripts with no file extension need --style=python for the # comment style.
remaining=$(printf '%s\n' "${files}" | grep -vE '\.(m|h|c)$' || true)
no_ext_files=$(printf '%s\n' "${remaining}" | grep -E '(^|/)[^./]+$' || true)
other_files=$(printf '%s\n' "${remaining}" | grep -vE '(^|/)[^./]+$' || true)

[[ -n ${c_files} ]]     && printf '%s\n' "${c_files}"     | annotate --style=c
[[ -n ${no_ext_files} ]] && printf '%s\n' "${no_ext_files}" | annotate --style=python --fallback-dot-license
[[ -n ${other_files} ]]  && printf '%s\n' "${other_files}"  | annotate --fallback-dot-license
