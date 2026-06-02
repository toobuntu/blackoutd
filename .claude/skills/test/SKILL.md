---
name: test
description: Run the RSpec behavioral test suite for blackoutd's pre-commit hook and CI Unicode scanner. Use when the maintainer asks for a test report, after editing files in spec/ or .githooks/pre-commit, or before tagging a release.
---

<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

Run `make test` and report the result.

If tests pass, give a one-line summary (count, time).

If tests fail, report:
1. The failing test names
2. The first failing assertion verbatim
3. The relevant file:line reference

Do not attempt to fix failures unless explicitly asked. The goal of
this skill is to surface state, not to act on it.

This suite covers behavioral tests for `.githooks/pre-commit` and the
CI Unicode scanner only. It does not exercise the daemon's
Objective-C source — daemon test coverage is tracked under P3 in
`docs/technical-debt.md`.
