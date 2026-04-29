#!/usr/bin/env bash
# Annotates non-REUSE-compliant files with SPDX copyright and license headers.
# Requires: reuse (pip install reuse OR brew install reuse), jq.
#
# Canonical version intended for cross-toobuntu use; keep this in sync
# with the copy in toobuntu/homebrew-cask-tools (the nominal source of
# truth). When updating, change both copies in the same PR cycle.
#
# Categorization (in order; each category is removed from the working
# set before the next is matched):
#
#   1. C / Objective-C / C++ source (.m/.h/.c)         → --style=c     (// comments)
#   2. Go source (.go)                                  → --style=go    (// comments)
#   3. Markdown / HTML / XML / SVG / plist              → --style=html  (<!-- ... --> comments)
#      (covers .md, .markdown, .html, .htm, .xml, .svg, .plist,
#       .plist.template; reuse-tool's auto-detection for these has been
#       inconsistent across versions, so specify the style explicitly)
#   4. Generated completion files (completions/**)      → sidecar       (--force-dot-license)
#   5. Man pages (.[1-9], .[1-9][a-z]*, with optional   → sidecar       (--force-dot-license)
#      .md suffix; e.g. progname.1, progname.3p,
#      progname.1.md)
#   6. Files with no extension (Makefile, Dockerfile,   → --style=python (# comments)
#      Gemfile, hook scripts)                              with --fallback-dot-license safety
#   7. Everything else                                   → --fallback-dot-license
#      (relies on reuse-tool's auto-detection for .yml,
#       .toml, .json, .rb, .sh, .py, etc.; falls back to
#       a sidecar .license file if the style is unknown)
#
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

: "${ANNOTATE_COPYRIGHT:=Todd Schulman}"
: "${ANNOTATE_LICENSE:=GPL-3.0-or-later}"

annotate() {
  xargs reuse annotate \
    --copyright="${ANNOTATE_COPYRIGHT}" \
    --merge-copyrights \
    --license="${ANNOTATE_LICENSE}" \
    --copyright-prefix=spdx-string \
    "$@"
}

files=$(reuse lint --json |
  jq -r '.non_compliant | (.missing_copyright_info + .missing_licensing_info) | unique[]') || true

[[ -z ${files} ]] && exit 0

remaining=$(printf '%s\n' "${files}")

# 1. C-family source: line-comment SPDX header.
c_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp '\.(m|h|c)$' || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp '\.(m|h|c)$' || true)

# 2. Go source.
go_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp '\.go$' || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp '\.go$' || true)

# 3. Markup / structured-text family that uses HTML-style comments.
#    Includes Markdown (where # is a header marker, NOT a comment) and
#    XML-derived formats (plist, SVG). reuse-tool's auto-detection for
#    .md has produced hash comments in some installations; specifying
#    --style=html explicitly removes the ambiguity.
html_re='\.(md|markdown|html|htm|xml|svg)$|\.plist(\.template)?$'
html_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp "${html_re}" || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp "${html_re}" || true)

# 4. Generated completion files: keep verbatim, use sidecar.
#    Covers fish (.fish), bash (no-extension), zsh (_-prefixed) under completions/.
compl_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp '(^|/)completions/' || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp '(^|/)completions/' || true)

# 5. Man pages: any section [1-9], optionally with letter suffix
#    (e.g. .3p for POSIX, .1ssl for OpenSSL), and optionally with
#    a trailing .md for source-form (ronn / md2man).
#    Caveat: this regex may false-match an unrelated file like
#    "version.5.md". If that's a problem in a future repo, exclude
#    such paths explicitly before this step.
man_re='\.[1-9][a-zA-Z]*(\.md)?$'
man_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp "${man_re}" || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp "${man_re}" || true)

# 6. Files with no extension (Makefile, Dockerfile, Gemfile, hook
#    scripts, etc.) typically use hash comments. --style=python is
#    reuse-tool's hash-comment style alias.
no_ext_re='(^|/)[^./]+$'
no_ext_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp "${no_ext_re}" || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp "${no_ext_re}" || true)

# 7. Everything else: rely on reuse-tool's auto-detection. Falls back
#    to a sidecar .license file if the comment style is unknown for
#    the extension (notably for .json, which has no comment syntax).
other_files=$(printf '%s\n' "${remaining}" || true)

[[ -n ${c_files} ]]      && printf '%s\n' "${c_files}"      | annotate --style=c
[[ -n ${go_files} ]]     && printf '%s\n' "${go_files}"     | annotate --style=go
[[ -n ${html_files} ]]   && printf '%s\n' "${html_files}"   | annotate --style=html
[[ -n ${compl_files} ]]  && printf '%s\n' "${compl_files}"  | annotate --force-dot-license
[[ -n ${man_files} ]]    && printf '%s\n' "${man_files}"    | annotate --force-dot-license
[[ -n ${no_ext_files} ]] && printf '%s\n' "${no_ext_files}" | annotate --style=python --fallback-dot-license
[[ -n ${other_files} ]]  && printf '%s\n' "${other_files}"  | annotate --fallback-dot-license
