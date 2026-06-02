---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 5
title: Use reuse lint-file with --no-multiprocessing in the pre-commit hook
status: accepted
date: 2026-05-27
decision-makers:
  - toobuntu
---

# Use reuse lint-file with --no-multiprocessing in the pre-commit hook

## Context and Problem Statement

REUSE 3.0 compliance is enforced at two layers: the pre-commit hook in
`.githooks/pre-commit` and the CI job `lint-reuse` in
`.github/workflows/ci.yml`. The CI job runs `fsfe/reuse-action`, which
walks the whole tree. The hook needs a faster, scoped check that runs
on every local commit attempt.

Two subcommands are available for the hook:

* `reuse lint` — walks the entire working tree. Slow on a clean clone,
  redundant with CI, and produces noise for unstaged files (in-flight
  WIP elsewhere in the tree, partial commits via `git commit -p`).
* `reuse lint-file <paths>` — added in reuse-tool 5.x specifically for
  pre-commit-style use. Checks only the listed files.

Independent of the subcommand choice, reuse-tool launches a
`ProcessPoolExecutor` by default. This was historically benign but
became a runtime failure on macOS under Apple's Seatbelt sandbox:
Python's pool setup calls `os.sysconf("SC_SEM_NSEMS_MAX")`, which
Seatbelt blocks at the syscall level with "Operation not permitted".

## Decision Drivers

* Local commits must not stall on tree-walks the CI already covers.
* Hook output must reflect only what's about to land, not in-flight
  work elsewhere in the working tree.
* The hook must not fail with sandbox-related errors when a developer
  runs `git commit` from a sandboxed shell or editor integration.
* Multiprocessing overhead should be quantitatively justified, not
  defaulted to.

## Considered Options

### Subcommand

* `reuse lint` — full tree walk
* `reuse lint-file <staged paths>` — scoped to staged set

### Concurrency

* Default (`ProcessPoolExecutor`, multiprocessing on)
* `--no-multiprocessing` (serial execution)

## Decision Outcome

The hook runs `reuse --no-multiprocessing lint-file <staged ACM paths>`.

CI's `lint-reuse` job continues to run the full-repo lint via
`fsfe/reuse-action`. The two layers are complementary, not redundant:
the hook catches issues at the contributor's keyboard on the
about-to-land set; CI catches anything the hook missed (including
contributors who bypass the hook with `--no-verify`) and provides the
authoritative gate on the whole repo.

Because `lint-file` is scoped to staged paths, it is *not* a full-repo
compliance check. The local equivalent of CI's whole-tree gate is the
`lint` make target (see the Makefile), which runs `reuse lint` over
the entire working tree alongside the other repo-wide checks.

## Consequences

* Good, because `--no-multiprocessing` lets the hook run under macOS
  Seatbelt, where the default process pool aborts on a blocked
  `SC_SEM_NSEMS_MAX` syscall before any linting happens.
* Good, because serial execution beats spawning a pool for the ≤ ~20
  files typical of one commit — a win on Linux too, not just a sandbox
  workaround.
* Good, because `lint-file` scopes the check to staged paths, so the
  hook reports only what is about to land.
* Bad, because `lint-file` is not a whole-tree check; the full-repo
  REUSE gates are only CI's `lint-reuse` job and `make lint`.
* Bad, because the hook needs the `BLACKOUTD_SKIP_REUSE_LINT` test seam
  for the Unicode specs — a disable switch on a security check is a
  hazard if it ever leaks into real use.

## More Information

### Failure reporting

The hook lints twice: a `--quiet` detection pass, then — only on
failure — a verbose re-run so the contributor sees the full report
before the hook bails. The verbose re-run is a bare pipeline that
exits non-zero by definition (it runs only when the detection pass
already failed). Under `set -e` that non-zero exit terminated the
hook on the spot, before the `scripts/annotate.sh` hint and the
explicit `exit 1` could run — the commit was rejected with the report
on stdout but an empty stderr and no remediation guidance. Appending
`|| true` to the verbose re-run keeps `set -e` from preempting the
hint. The path is pinned by `spec/integration/precommit_reuse_spec.rb`,
which drives it with a stub `reuse` so no real install is required.

### Test seam

`BLACKOUTD_SKIP_REUSE_LINT=1` skips the REUSE block entirely. Used by
`spec/integration/precommit_unicode_spec.rb` so the Unicode scanner
can be tested in a throwaway repo without a `LICENSES/` directory.
This is an internal test seam, intentionally not documented in
`CONTRIBUTING.md`. The REUSE block keeps its own coverage: CI's
`lint-reuse` job (whole repo) and `spec/integration/precommit_reuse_spec.rb`
(the hook's failure path).

### REUSE.toml caveat

blackoutd uses individual SPDX headers and `.license` sidecars; no
`REUSE.toml`. `lint-file` *does* honor `REUSE.toml` declarations: a
directory-level `REUSE.toml` covers its globbed paths and `lint-file`
passes them without a `LICENSES/` directory present (verified locally;
this is also why a per-throwaway `REUSE.toml` was considered, and
rejected, as the test-isolation mechanism). If a future change adopts
`REUSE.toml`-based annotations repo-wide, confirm the behavior still
matches the full `reuse lint` path before relying on it.

### Sandbox

`--no-multiprocessing` makes the hook work under macOS Seatbelt. This
is the failure mode reported in
[fsfe/reuse-tool#280](https://github.com/fsfe/reuse-tool/issues/280)
and
[openai/codex#2486](https://github.com/openai/codex/issues/2486).
Without the flag, sandboxed commits fail with an
`os.sysconf("SC_SEM_NSEMS_MAX")` permission error before any actual
linting happens.
