<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Contributing to blackoutd

## Encoding requirements

All source, documentation, and configuration files **must** be:

- Valid **UTF-8**, decoded without error.
- **Without BOM** — U+FEFF must not appear anywhere in any file, including
  as a leading byte-order mark.

These requirements are enforced automatically:

| Where | What is checked |
|-------|-----------------|
| Pre-commit hook (`.githooks/pre-commit`) | Each staged text blob is scanned for invisible Unicode: bidi overrides (U+202A–202E), bidi isolates (U+2066–2069), zero-width chars (U+200B/200C/200D/200F), and UTF-8 BOM (U+FEFF). Binary blobs (NUL bytes present) are skipped. |
| CI job `lint-unicode` | Every non-binary file in the repository tree is decoded as **strict UTF-8** (non-UTF-8 files fail the check), then scanned for the same invisible-character set. |

To install the pre-commit hook:

```sh
git config core.hooksPath .githooks
```

## Language and style

- Objective-C, ARC, AppKit. No Swift. See `docs/architecture.md`.
- `.clang-format`: LLVM base style, 2-space indent, 80-column limit.
- Run `clang-format --style=file -i` on any changed `.m` or `.h` before committing.
- Minimal comments; self-documenting names preferred.

## Commit conventions

- Subject line ≤ 50 characters.
- Body wraps at 72 characters.
- Reference issues with `Closes #N` in the commit body.
- No verbose AI commentary in commit messages or PR descriptions.

## Build

```sh
make            # build to build/blackoutd
make clean      # remove build artifacts
make install    # build + install binary + bootstrap LaunchAgent (requires sudo)
make reinstall  # build + restart agent from build dir, no sudo
make release    # tag, build, codesign (requires clean working tree)
```
