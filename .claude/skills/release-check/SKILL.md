---
name: release-check
description: Pre-release verification — verify a clean working tree, build the binary, and create a local annotated git tag. Non-destructive (does not push, sign, or package). Use when the maintainer says they're ready to cut a release or asks for a release dry run.
---

<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

Run `make release` and report the outcome.

`make release` is non-destructive: it verifies a clean working tree,
verifies the version tag does not already exist, builds the binary,
and creates an annotated git tag locally. It does NOT push the tag,
sign artifacts, or produce a packaged release.

If the working tree is dirty or the tag already exists, the command
fails fast. Report the failure verbatim. Do not modify the working
tree to clear errors unless explicitly asked.

If it succeeds, report:
1. The tag created (e.g., `v0.2.0`)
2. The path to the built binary
3. The exact `git push origin <tag>` command needed to publish
   (do NOT run it — the maintainer pushes tags manually)
