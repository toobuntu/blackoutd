#!/usr/bin/env bash
# Annotates non-REUSE-compliant files with SPDX copyright and license headers.
# Requires: reuse (pip install reuse OR brew install reuse), jq.
#
# Canonical version intended for cross-toobuntu use; keep this in sync
# with the copy in toobuntu/homebrew-cask-tools (the nominal source of
# truth). When updating, change both copies in the same PR cycle.
#
# Categorization (in declared order; each category is removed from the
# working set before the next is matched, so ORDER MATTERS):
#
#   1. C / Objective-C source (.m/.h/.c)               → --style=c     (// comments)
#   2. Go source (.go)                                  → --style=go    (// comments)
#   3. Generated completion files (completions/**)      → sidecar       (--force-dot-license)
#   4. Man pages (.[1-9], .[1-9][a-z]*, with optional   → sidecar       (--force-dot-license)
#      .md suffix; e.g. progname.1, progname.3p,
#      progname.1ssl, progname.1.md)
#      Matched BEFORE markup so ronn/md2man source
#      (.1.md) is treated as a man page rather than
#      as Markdown.
#   5. Markup / structured-text family (.md, .markdown,  → --style=html  (<!-- ... --> comments)
#      .html, .htm, .xhtml, .xml, .xsl, .xslt, .svg,
#      .plist, with optional .template suffix)
#      reuse-tool's auto-detection on these has been
#      inconsistent across versions; specifying the
#      style explicitly removes the ambiguity. For
#      Markdown files with YAML frontmatter
#      (--- ... ---), reuse-tool 4+ correctly inserts
#      the SPDX block AFTER the frontmatter rather
#      than before — important for files whose
#      frontmatter is parsed by another tool such as
#      Claude Code skills (.claude/skills/<name>/SKILL.md).
#   6. Files with no extension (Makefile, Dockerfile,   → --style=python (# comments)
#      Gemfile, hook scripts)                              with --fallback-dot-license safety
#   7. Everything else                                   → --fallback-dot-license
#      Relies on reuse-tool's auto-detection for .yml,
#      .toml, .json, .rb, .sh, .py, .css, .lua, .tex,
#      etc. Falls back to a sidecar .license file if
#      the comment style is unknown for the extension
#      (notably for .json, which has no comment syntax,
#      and .mermaid/.mmd which reuse-tool does not yet
#      know about).
#
# REUSE.toml alternative: a top-level REUSE.toml file can declare SPDX
# coverage for a path glob (e.g. ".claude/skills/**") in lieu of inline
# annotations. Reasonable choice for directory trees of homogeneous
# files where the per-file SPDX comment is unwanted clutter. Not used
# in blackoutd by default — inline + sidecar is the established pattern.
# To switch a directory to REUSE.toml-only, delete the inline blocks
# and add an [[annotations]] entry; reuse-tool 4+ honors both styles
# simultaneously.
#
# Override defaults via environment:
#   ANNOTATE_COPYRIGHT="<name>"   default: Todd Schulman
#   ANNOTATE_LICENSE="<spdx-id>"  default: GPL-3.0-or-later
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
c_re='\.(m|h|c)$'
c_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp "${c_re}" || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp "${c_re}" || true)

# 2. Go source.
go_re='\.go$'
go_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp "${go_re}" || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp "${go_re}" || true)

# 3. Generated completion files: keep verbatim, use sidecar.
#    Covers fish (.fish), bash (no-extension), zsh (_-prefixed) under completions/.
compl_re='(^|/)completions/'
compl_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp "${compl_re}" || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp "${compl_re}" || true)

# 4. Man pages — must run BEFORE markup category so ronn/md2man source
#    (.1.md) is treated as a man page, not as Markdown. Matches any
#    section [1-9], optionally with subsection letter suffix
#    (.3p for POSIX, .1ssl for OpenSSL, etc.), and optionally with a
#    trailing .md for source-form (ronn / md2man).
#    Caveat: a non-man-page file like "release-notes.1.md" will match
#    this regex. The consequence is "uses sidecar instead of inline
#    HTML comment" — still a valid REUSE annotation, just less
#    convenient. If a project frequently triggers the false positive,
#    tighten this regex to require a man/ or share/man/ path prefix.
man_re='\.[1-9][a-zA-Z]*(\.md)?$'
man_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp "${man_re}" || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp "${man_re}" || true)

# 5. Markup / structured-text family that uses HTML-style comments.
#    Covers Markdown (where # is a header marker, NOT a comment),
#    HTML and XHTML, XML and XSL/XSLT transforms, SVG, and plist files.
#    Each may optionally have a .template suffix (e.g. blackoutd.plist.template
#    or doc.html.template).
markup_re='\.(md|markdown|html|htm|xhtml|xml|xsl|xslt|svg|plist)(\.template)?$'
markup_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp "${markup_re}" || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp "${markup_re}" || true)

# 6. Files with no extension (Makefile, Dockerfile, Gemfile, hook
#    scripts, etc.) typically use hash comments. --style=python is
#    reuse-tool's hash-comment style alias.
#    Note: dotfiles like .gitignore have a leading dot and therefore
#    contain a `.`, so they do NOT match this pattern; they fall
#    through to category 7.
no_ext_re='(^|/)[^./]+$'
no_ext_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp "${no_ext_re}" || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp "${no_ext_re}" || true)

# 7. Everything else: rely on reuse-tool's auto-detection. Falls back
#    to a sidecar .license file if the comment style is unknown for
#    the extension.
other_files=$(printf '%s\n' "${remaining}" || true)

[[ -n ${c_files} ]]      && printf '%s\n' "${c_files}"      | annotate --style=c
[[ -n ${go_files} ]]     && printf '%s\n' "${go_files}"     | annotate --style=go
[[ -n ${compl_files} ]]  && printf '%s\n' "${compl_files}"  | annotate --force-dot-license
[[ -n ${man_files} ]]    && printf '%s\n' "${man_files}"    | annotate --force-dot-license
[[ -n ${markup_files} ]] && printf '%s\n' "${markup_files}" | annotate --style=html
[[ -n ${no_ext_files} ]] && printf '%s\n' "${no_ext_files}" | annotate --style=python --fallback-dot-license
[[ -n ${other_files} ]]  && printf '%s\n' "${other_files}"  | annotate --fallback-dot-license
