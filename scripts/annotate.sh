#!/usr/bin/env bash
# Annotates non-REUSE-compliant files with SPDX copyright and license headers.
# Requires: reuse (pip install reuse OR brew install reuse), jq.
#
# This file is synced from the repo-foundation repository, do not modify it
# directly. Make changes in toobuntu/repo-foundation and re-sync.
#
# Categorization (in declared order; each category is removed from the
# working set before the next is matched, so ORDER MATTERS):
#
#   1. C / Objective-C source (.m/.h/.c)               → --style=c     (// comments)
#   2. Go source (.go)                                  → --style=c    (// comments)
#   3. Generated completion files (completions/**)      → sidecar       (--force-dot-license)
#   4. Man pages (.[1-9], .[1-9][a-z]*, with optional   → sidecar       (--force-dot-license)
#      .md suffix; e.g. progname.1, progname.3p,
#      progname.1ssl, progname.1.md)
#      Matched BEFORE markup so ronn/md2man source
#      (.1.md) is treated as a man page rather than
#      as Markdown.
#   5. Property lists (.plist, optional .template)       → sidecar       (--force-dot-license)
#      PlistBuddy / plutil / Xcode rewrite plists and do
#      not preserve XML comments, so an inline header is
#      stripped by the next programmatic edit (e.g. a
#      scripts/bump.sh version bump) and the file fails
#      REUSE again. Matched BEFORE markup, which would
#      otherwise claim .plist for inline comments.
#   6. Markup / structured-text family (.md, .markdown,  → --style=html  (<!-- ... --> comments)
#      .html, .htm, .xhtml, .xml, .xsl, .xslt, .svg,
#      with optional .template suffix)
#      reuse-tool's auto-detection on these has been
#      inconsistent across versions; specifying the
#      style explicitly removes the ambiguity. For
#      Markdown files with YAML frontmatter
#      (--- ... ---), reuse-tool 4+ correctly inserts
#      the SPDX block AFTER the frontmatter rather
#      than before — important for files whose
#      frontmatter is parsed by another tool such as
#      Claude Code skills (.claude/skills/<name>/SKILL.md).
#   7. Files with no extension (Makefile, Dockerfile,   → --style=python (# comments)
#      Gemfile, hook scripts)                              with --fallback-dot-license safety
#   8. Hash-checksum files (.md5/.sha1/.sha224/.sha256/  → sidecar       (--force-dot-license)
#      .sha384/.sha512). The SHA256SUMS-style format
#      verified by `shasum -c` is positional; introducing
#      a comment line either breaks parsing or works
#      accidentally (depending on the verifier). Force a
#      .license sidecar to keep the hash file content
#      mechanically untouched. reuse-tool may grow inline
#      handling for these extensions in the future, but
#      forcing the sidecar removes the dependency on its
#      behavior staying compatible.
#   9. Everything else                                   → --fallback-dot-license
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

# Fail early with an actionable message if a required tool is absent.
# Without this, a missing `reuse` makes the pipeline below exit 0 with
# an empty result (the `|| true` swallows the failure), so the script
# silently no-ops while the user believes annotation ran.
require_tool() {
  command -v "$1" >/dev/null 2>&1 && return 0
  printf 'error: %s not found; required by %s\n' "$1" "${0##*/}" >&2
  printf '  Install: brew install %s\n' "$1" >&2
  exit 1
}

require_tool reuse
require_tool jq

annotate() {
  xargs reuse annotate \
    --copyright="${ANNOTATE_COPYRIGHT}" \
    --merge-copyrights \
    --license="${ANNOTATE_LICENSE}" \
    --copyright-prefix=spdx-string \
    "$@"
}

# --no-multiprocessing: Python's ProcessPoolExecutor probes the
# SC_SEM_NSEMS_MAX sysconf, which macOS Seatbelt sandboxes deny; without
# the flag the lint aborts when run from an agent sandbox (see
# docs/agent-principles.md). Single-process is plenty at repo scale.
files=$(reuse --no-multiprocessing lint --json |
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

# 5. Property lists: sidecar, never inline. PlistBuddy / plutil / Xcode
#    rewrite plists without preserving XML comments, so an inline header
#    is stripped by the next programmatic edit (e.g. a scripts/bump.sh
#    version bump). Must run BEFORE the markup category, which would
#    otherwise claim .plist for inline HTML-style comments.
plist_re='\.plist(\.template)?$'
plist_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp "${plist_re}" || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp "${plist_re}" || true)

# 6. Markup / structured-text family that uses HTML-style comments.
#    Covers Markdown (where # is a header marker, NOT a comment),
#    HTML and XHTML, XML and XSL/XSLT transforms, and SVG.
#    Each may optionally have a .template suffix (e.g. doc.html.template).
markup_re='\.(md|markdown|html|htm|xhtml|xml|xsl|xslt|svg)(\.template)?$'
markup_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp "${markup_re}" || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp "${markup_re}" || true)

# 7. Files with no extension (Makefile, Dockerfile, Gemfile, hook
#    scripts, etc.) typically use hash comments. --style=python is
#    reuse-tool's hash-comment style alias.
#    Note: dotfiles like .gitignore have a leading dot and therefore
#    contain a `.`, so they do NOT match this pattern; they fall
#    through to category 9.
no_ext_re='(^|/)[^./]+$'
no_ext_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp "${no_ext_re}" || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp "${no_ext_re}" || true)

# 8. Hash-checksum files (SHA256SUMS-style): the format verified by
#    `shasum -c` is positional, so a comment line breaks (or accidentally
#    survives) parsing. Force a sidecar to keep the file content
#    mechanically untouched, independent of whether reuse-tool ever grows
#    inline handling for these extensions.
hash_re='\.(md5|sha1|sha224|sha256|sha384|sha512)$'
hash_files=$(printf '%s\n' "${remaining}" | grep --extended-regexp "${hash_re}" || true)
remaining=$(printf '%s\n' "${remaining}" | grep --invert-match --extended-regexp "${hash_re}" || true)

# 9. Everything else: rely on reuse-tool's auto-detection. Falls back
#    to a sidecar .license file if the comment style is unknown for
#    the extension.
other_files=$(printf '%s\n' "${remaining}" || true)

[[ -n ${c_files} ]]      && printf '%s\n' "${c_files}"      | annotate --style=c
[[ -n ${go_files} ]]     && printf '%s\n' "${go_files}"     | annotate --style=c
[[ -n ${compl_files} ]]  && printf '%s\n' "${compl_files}"  | annotate --force-dot-license
[[ -n ${man_files} ]]    && printf '%s\n' "${man_files}"    | annotate --force-dot-license
[[ -n ${plist_files} ]]  && printf '%s\n' "${plist_files}"  | annotate --force-dot-license
[[ -n ${markup_files} ]] && printf '%s\n' "${markup_files}" | annotate --style=html
[[ -n ${no_ext_files} ]] && printf '%s\n' "${no_ext_files}" | annotate --style=python --fallback-dot-license
[[ -n ${hash_files} ]]   && printf '%s\n' "${hash_files}"   | annotate --force-dot-license
[[ -n ${other_files} ]]  && printf '%s\n' "${other_files}"  | annotate --fallback-dot-license
