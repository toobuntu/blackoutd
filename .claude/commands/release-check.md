---
description: Pre-release verification (clean tree, build, tag — does not push)
---

Run `make release` and report the outcome.

`make release` is non-destructive: it verifies a clean working tree,
verifies the version tag does not already exist, builds the binary, and
creates an annotated git tag locally. It does NOT push the tag, sign
artifacts, or produce a packaged release.

If the working tree is dirty or the tag already exists, the command fails
fast. Report the failure verbatim. Do not modify the working tree to
clear errors unless I explicitly ask.

If it succeeds, report:
1. The tag created (e.g. `v0.2.0`)
2. The path to the built binary
3. The exact `git push origin <tag>` command needed to publish (do NOT run it)
