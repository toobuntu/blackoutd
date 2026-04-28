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
| Pre-commit hook (`.githooks/pre-commit`) | Each staged text blob is scanned for invisible Unicode (bidi overrides U+202A–202E, bidi isolates U+2066–2069, zero-width U+200B/200C/200D, LTR/RTL marks U+200E/200F, ALM U+061C, BOM U+FEFF) using `grep` against a UTF-8 bracket expression. Approach is RedHat's [RHSB-2021-007](https://access.redhat.com/security/vulnerabilities/RHSB-2021-007). The hook is `#!/bin/sh` and uses POSIX `printf '\NNN'` octal byte escapes to construct the pattern, so it does not depend on bash 4.2+, ksh93, or any specific shell version. Binary blobs are skipped via `grep --binary-files=without-match`. |
| CI job `lint-unicode` | Every non-binary file is decoded as **strict UTF-8** on the Ubuntu runner using Python. Every character in Unicode category **Cf (Format)** or **Cc (Control)** is rejected, except a small allowlist of TAB/LF/CR. This is automatically future-proof — new invisible characters added in future Unicode revisions are caught without code changes. UTF-16 and UTF-32 text are explicitly rejected (project policy is UTF-8 only). |

The pre-commit hook intentionally avoids Python because future macOS versions
may not ship Python by default
([Apple Catalina release notes](https://developer.apple.com/documentation/macos-release-notes/macos-catalina-10_15-release-notes#Scripting-Language-Runtimes)).
The CI Python check provides defense in depth and broader coverage.

This check covers Trojan Source attacks (CVE-2021-42574). It does NOT cover
homoglyph attacks (CVE-2021-42694), which would require Unicode confusables
tables and are tracked separately.

### Opt-out for legitimate bidi use

Some files legitimately require bidi controls (e.g. an i18n library, an
iCalendar writer that emits LRM around LTR times in an RTL string). To
allow specific codepoints in a single file, add a `bidi-allow:` annotation
anywhere in the file:

```go
// bidi-allow: U+200E
package icalwriter
```

The annotation lists comma-separated `U+XXXX` codepoints from the blocked
set that the file is allowed to contain. Both the pre-commit hook and the
CI scanner honor it. The annotation is reviewable in PR diff and grep-able
across the repo (`grep -r bidi-allow:`).

Rationale, alternatives considered, and the Cf/Cc category-based approach:
[ADR 0001](docs/decisions/0001-trojan-source-detection-strategy.md).

To install the pre-commit hook:

```sh
git config core.hooksPath .githooks
```

## Language and style

- Objective-C, ARC, AppKit. No Swift. See `docs/architecture.md`.
- `.clang-format`: LLVM base style, 2-space indent, 80-column limit.
- Run `clang-format --style=file -i` on any changed `.m` or `.h` before committing.
- Minimal comments; self-documenting names preferred.

## Tests

Behavioral tests for the pre-commit hook and CI Unicode scanner live in
`spec/integration/`. They exercise the actual hook script and the actual
embedded Python from `ci.yml` against planted inputs.

```sh
bundle install
bundle exec rspec
```

The `spec` job in CI runs these on every push and pull request.

## Commit conventions

- Subject line ≤ 50 characters.
- Body wraps at 72 characters.
- Reference issues with `Closes #N` in the commit body.
- No verbose AI commentary in commit messages or PR descriptions.

## Merging pull requests

PRs are merged with **merge commits** (not squash, not rebase). This
preserves PR identity in `git log --graph` and keeps original commit
authorship and dates intact. See
[ADR 0004](docs/decisions/0004-merge-strategy.md) for the full rationale.

## Build

```sh
make            # build to build/blackoutd
make clean      # remove build artifacts
make install    # build + install binary + bootstrap LaunchAgent (requires sudo)
make dev        # build + restart agent from build dir, no sudo (development cycle)
make release    # verify clean tree, build, and create annotated git tag
```
