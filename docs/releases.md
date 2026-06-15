<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Release process

How to cut a blackoutd release. The shape follows
[Homebrew's release doc](https://github.com/Homebrew/brew/blob/HEAD/docs/Releases.md):
mechanical steps first, then how to write notes humans actually want to read.

Versioning is SemVer with a `v` prefix (`v0.3.0`). The single source of truth
for the version is `CFBundleShortVersionString` in `src/Info.plist`; tags and
the GitHub release derive from it.

## Which part to bump

- **patch** (`0.3.0` → `0.3.1`) — bug fixes only, no new user-facing surface.
- **minor** (`0.3.0` → `0.4.0`) — new subcommands, flags, or behavior, backward
  compatible.
- **major** (`0.3.0` → `1.0.0`) — breaking changes (e.g. the planned
  signal → Mach IPC migration, P4 in `docs/technical-debt.md`).

## Procedure

Preconditions — clean `main`, full local gate green:

```sh
git switch main && git pull --ff-only
make check                  # CI's lint + RSpec gates (all but lint-plist)
```

`make check` runs every CI lint plus the RSpec suite. The one CI gate it
omits is `lint-plist`, which generates and validates the LaunchAgent plist —
that step writes to `~/Library/LaunchAgents`, so it stays out of the
read-only local gate (run `make postinstall && plutil -lint …` to cover it).

Park any merged feature branches (kept for local history, not deleted):

```sh
git branch --move feature/foo merged/feature/foo
```

1. **Bump**, on a branch (`bump.sh` refuses to run on `main`, and the
   pre-commit hook blocks direct `main` commits):

   ```sh
   git switch --create chore/release-X.Y.Z
   scripts/bump.sh minor     # edits Info.plist; commits "chore: bump version to X.Y.Z"
   ```

   `bump.sh` updates both `CFBundleShortVersionString` and `CFBundleVersion`
   via PlistBuddy. The SPDX metadata lives in the `src/Info.plist.license`
   sidecar precisely because PlistBuddy rewrites the plist and drops inline
   XML comments — see the plist category in `scripts/annotate.sh`. If a bump
   ever reports `Info.plist: no license identifier`, the sidecar is missing;
   run `scripts/annotate.sh`.

2. **PR and merge the bump** (merge commit, never squash — ADR 0004):

   ```sh
   git push --set-upstream origin chore/release-X.Y.Z
   gh pr create --title "chore: bump version to X.Y.Z" --body "Release housekeeping for vX.Y.Z."
   # after CI is green and review passes, merge via the web UI
   ```

3. **Tag** from the merged `main`:

   ```sh
   git switch main && git pull --ff-only
   make release              # preflight (clean tree, tag absent) + build + signed annotated tag
   git push origin vX.Y.Z
   ```

   `make release` creates a **signed** annotated tag (it runs `git tag
   --sign`, so signing is enforced regardless of global config). It does
   **not** push the tag, package a binary, or create the GitHub release —
   those are the deliberate manual steps that follow.

4. **Publish the GitHub release** with notes (next section):

   ```sh
   gh release create vX.Y.Z --title "blackoutd vX.Y.Z" --notes-file /tmp/relnotes.md
   # optional ad-hoc-signed binary: gh release upload vX.Y.Z build/blackoutd
   ```

## Writing the release notes

Borrowing Homebrew's standard: notes are for **humans**, and they explain not
just *what* changed but *why* it matters.

- **Group by user impact, not by commit.** Lead with what a user would notice;
  bury the refactors.
- **One line per notable change: the change and its reason or benefit.** "Fixed
  X" is half a note; "Fixed X, which left both displays active after wake" is a
  whole one.
- **Call out breaking changes explicitly**, with the migration step.
- **List known issues** a user might hit, with the workaround — but keep a
  terse hand on unfixed *security* gaps: name that they're tracked
  (`docs/technical-debt.md`, `ROADMAP.md`) rather than detailing how to trip an
  unpatched weakness. Advertising an exploitable gap helps no one.
- **Skim `git log --oneline vPREV..main`** before publishing so earlier work
  (log rotation, tooling, doc fixes) isn't under-credited by a notes draft that
  only remembers the recent commits.

A bullet that does this well: *"`diagnose` now records role-attributed DCP and
connection-mode state — so a bug report carries the below-CoreGraphics evidence
the cursor-on-black investigation needs, without a separate capture dance."*

## Undoing a release

- **Before the bump is pushed:** `scripts/bump.sh undo` reverts the bump commit
  and deletes the matching local tag if it points at `HEAD`.
- **After `make release` tags but before pushing the tag:** `git tag --delete vX.Y.Z`.
- **A pushed tag** is deliberate to retract and outside routine practice; if a
  release was wrong, prefer a follow-up patch release over rewriting a published
  tag.

## Signing notes

Agent-assisted commits are made unsigned inside the sandbox (the signing key is
unreadable there); the maintainer re-signs the batch before pushing
(`git rebase --exec 'git commit --amend --no-edit --gpg-sign' origin/main`).
The release tag itself is signed by `make release`, and the `pre-push` hook
rejects an unsigned tip — so a release branch cannot reach the remote unsigned.
