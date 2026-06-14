<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Contributing to blackoutd

## Language and style

- Objective-C, ARC, AppKit. No Swift. See `docs/architecture.md`.
- `.clang-format`: LLVM base style, 2-space indent, 80-column limit.
- Run `clang-format --style=file -i` on any changed `.m` or `.h` before
  committing.
- Minimal comments; self-documenting names preferred.

## Building and running

Run all `make` targets as your normal logged-in user, **not** under `sudo`.
The `install` and `reinstall` targets invoke `sudo` internally only for the
privileged writes to `/usr/local/bin` and `/usr/local/share`. Running the
whole `make` command under `sudo` would make `$HOME` resolve to `/var/root`
and `id -u` return `0`, breaking plist generation and `launchctl bootstrap`
domain targeting.

```sh
make            # build to build/blackoutd
make clean      # remove build artifacts
make install    # first-time install: build, install binary, bootstrap agent
make reinstall  # upgrade: bootout running agent, install, bootstrap
make dev        # build, restart agent from build dir; never invokes sudo
make uninstall  # remove all installed files and the agent
make release    # verify clean tree, build, and create a signed git tag
```

Install the git hooks once (this activates both the pre-commit checks and the
maintainer pre-push signing gate described below):

```sh
git config core.hooksPath .githooks
```

### Tests

Behavioral tests for the pre-commit hook and CI Unicode scanner live in
`spec/integration/`. They exercise the actual hook script and the actual
embedded Python from `ci.yml` against planted inputs.

```sh
# RSpec runs under Homebrew's portable Ruby (system Ruby 2.6 is only a
# fallback). Install the gems under that Ruby once:
env -P"$(brew --repository)/Library/Homebrew/vendor/portable-ruby/current/bin:$PATH" bundle install

# Then run the suite via the make target (it wraps the same Ruby):
make test
```

The `spec` job in CI runs the suite via `Homebrew/actions/setup-ruby`
(the same portable Ruby) on every push and pull request.

## License headers (REUSE)

Every file must carry SPDX license metadata *before* it is committed, enforced
by the CI `lint-reuse` job ([reuse.software](https://reuse.software/)). The
expected format is:

```
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
```

The annotation can live inline (preferred) or in a sidecar `<file>.license`
file — used when a file's format has no comment syntax (such as `.json`) or
when tooling rewrites the file and would strip an inline comment (such as a
`.plist` edited by PlistBuddy).

### How to add headers to new files

Run `scripts/annotate.sh` from the repo root. It scans for non-compliant
files, classifies them by extension and path, and inserts SPDX blocks in
the right comment style (or creates a sidecar where inline is unsafe).
The script is idempotent — already-compliant files are skipped.

```sh
scripts/annotate.sh
```

To use a different copyright owner or license (e.g. when running this
script in a non-toobuntu repo), set environment variables:

```sh
ANNOTATE_COPYRIGHT="Some Other Person" \
ANNOTATE_LICENSE="MIT" \
scripts/annotate.sh
```

The script is the canonical version intended for cross-toobuntu use; the
mirror in `toobuntu/homebrew-cask-tools/scripts/annotate.sh` is the nominal
source of truth and should be kept in sync.

### YAML frontmatter and SPDX placement

Markdown files with YAML frontmatter (Architectural Decision Records,
Claude Code skills, MkDocs pages) need special handling. Two patterns are
both valid for `reuse lint`, but only one is safe in all contexts:

**Inside frontmatter (works for ADRs, fragile for skills):**

```markdown
---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 1
title: ADR title
---
```

YAML allows `#` comments, and `reuse lint` finds the SPDX strings via
substring search regardless of YAML structure. ADRs in `docs/decisions/`
use this pattern.

**After frontmatter (required for Claude Code skills):**

```markdown
---
name: skill-name
description: ...
---

<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->
```

Claude Code's skill loader parses the frontmatter strictly, and content
inside the `---` fences is consumed as YAML data. Putting the SPDX block
*after* the closing `---` keeps the frontmatter clean and is the format
that `reuse annotate --style=html` produces automatically for any
Markdown file with frontmatter.

**Practical guidance:** let `scripts/annotate.sh` handle this. It uses
`reuse annotate --style=html` for `.md` files, which is frontmatter-aware
and inserts the SPDX block in the right place. ADRs that already have
inline SPDX in frontmatter are recognized as compliant and left alone.

## Commits and pull requests

- Subject line ≤ 50 characters; body wraps at 72.
- Reference issues with `Closes #N` in the commit body.
- No verbose AI commentary in commit messages or PR descriptions; note AI
  assistance and what manual verification was performed.
- PRs are merged with **merge commits** (not squash, not rebase), preserving
  PR identity in `git log --graph` and keeping original commit authorship and
  dates. See [ADR 0004](docs/decisions/0004-merge-strategy.md).

### Signed pushes (maintainer policy, not a contribution gate)

The `.githooks/pre-push` hook validates that every commit a push introduces
carries a valid signature. Signed history is a policy the maintainers impose
on themselves; it is not a barrier to contributing:

- With no extra configuration, the hook **enforces** only where commit
  signing is configured locally (`commit.gpgsign=true` or `user.signingkey`
  set) — i.e. on maintainer machines. If signing is not configured, the
  same scan runs but prints a warning and the push proceeds, so a
  contributor who enabled the hooks for the pre-commit checks is informed
  but never blocked.
- `git config hooks.requireSignedPush true|false` overrides the detection
  in either direction. A one-off bypass that keeps every other check:
  `git -c hooks.requireSignedPush=false push ...` (prefer this over
  `--no-verify`, which skips the hook entirely).
- A signature is the committer's attestation, not the author's, so a
  maintainer may re-sign contributor commits before merging
  (`git rebase --exec 'git commit --amend --no-edit --gpg-sign' ...`);
  authorship is preserved. Any server-side signed-commit rule on `main`
  applies regardless of local hooks — keep the GitHub ruleset consistent
  with this policy.

## Encoding and invisible Unicode

All source, documentation, and configuration files must be valid **UTF-8**
and contain **no BOM** (U+FEFF anywhere, including a leading byte-order mark);
UTF-16/UTF-32 are rejected. This is enforced automatically: the pre-commit
hook scans each staged blob for invisible bidi/zero-width control characters
(RedHat's [RHSB-2021-007](https://access.redhat.com/security/vulnerabilities/RHSB-2021-007)
approach, in POSIX `/bin/sh`), and the CI `lint-unicode` job rejects any
Unicode Cf/Cc-category character on the Ubuntu runner. Rationale, full
codepoint coverage, and alternatives considered live in
[ADR 0001](docs/decisions/0001-trojan-source-detection-strategy.md).

A file that legitimately needs a blocked codepoint (e.g. an i18n library, an
iCalendar writer emitting LRM in an RTL string) can opt out with a
`bidi-allow:` annotation anywhere in it:

```go
// bidi-allow: U+200E
package icalwriter
```

The annotation lists comma-separated `U+XXXX` codepoints from the blocked set;
both the pre-commit hook and the CI scanner honor it, and it is reviewable in
the PR diff and grep-able (`grep -r bidi-allow:`). Use it sparingly — each
exemption widens the attack surface.
