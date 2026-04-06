#!/usr/bin/env bash
# Annotates non-REUSE-compliant files with SPDX copyright and license headers.
# Requires: reuse (pip install reuse or brew install reuse), jq
#
# Designed to be template-worthy across all toobuntu repos.  Handles:
#   .m/.h/.c          → --style=c      (C-style block comments)
#   .go               → --style=go     (Go-style line comments)
#   completions/      → --force-dot-license (preserve generated content)
#   .1, .1.md         → --force-dot-license (preserve man page content)
#   no-extension files→ --style=python --fallback-dot-license
#   everything else   → --fallback-dot-license
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

# Objective-C / C source files need C-style block comments (/* ... */).
c_files=$(printf '%s\n' "${files}" | grep -E '\.(m|h|c)$' || true)
# Go source files need Go-style line comments (// ...).
go_files=$(printf '%s\n' "${files}" | grep -E '\.go$' || true)
# Generated completion and man page files must keep their content intact, so annotate
# them with a .license sidecar instead of inline SPDX comment headers.
# This covers: fish completions, bash completions (no extension), zsh completions
# (prefixed with _), man pages (.1, .1.md).
compl_files=$(printf '%s\n' "${files}" | grep -E '(^|/)completions/' || true)
man_files=$(printf '%s\n' "${files}" | grep -E '\.(1|1\.md)$' || true)
# Shell scripts with no file extension need --style=python for reuse to infer the # comment style.
# The pattern (^|/)[^./]+$ matches basenames with no dot (no extension).
remaining=$(printf '%s\n' "${files}" | grep -vE '\.(m|h|c)$' | grep -vE '\.go$' | grep -vE '(^|/)completions/' | grep -vE '\.(1|1\.md)$' || true)
no_ext_files=$(printf '%s\n' "${remaining}" | grep -E '(^|/)[^./]+$' || true)
other_files=$(printf '%s\n' "${remaining}" | grep -vE '(^|/)[^./]+$' || true)

[[ -n ${c_files} ]]     && printf '%s\n' "${c_files}"     | annotate --style=c
[[ -n ${go_files} ]]    && printf '%s\n' "${go_files}"    | annotate --style=go
[[ -n ${compl_files} ]] && printf '%s\n' "${compl_files}" | annotate --force-dot-license
[[ -n ${man_files} ]]   && printf '%s\n' "${man_files}"   | annotate --force-dot-license
[[ -n ${no_ext_files} ]] && printf '%s\n' "${no_ext_files}" | annotate --style=python --fallback-dot-license
[[ -n ${other_files} ]]  && printf '%s\n' "${other_files}"  | annotate --fallback-dot-license
