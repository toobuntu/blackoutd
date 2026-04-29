---
name: dev-cycle
description: Run blackoutd's edit/build/reload cycle — clean build artifacts, rebuild from source, restart the LaunchAgent in dev mode, and verify daemon status. Use when the maintainer asks to test a code change end-to-end on the running daemon, or after any non-trivial edit to src/ files.
---

<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

Run a fast development build cycle for blackoutd. Each step is a
separate command so it matches the per-command permission rules in
`.claude/settings.json` (a chained `make clean && make` would not match
the individual entries):

1. `make clean` — remove previous build artifacts
2. `make` — rebuild from source
3. `make dev` — bootout the running agent and bootstrap with `build/blackoutd`

Stop and report verbatim if any step fails. Do not modify source files
to clear errors unless explicitly asked.

If all three steps succeed, run `blackoutd status` and report its output.

Do not commit anything as part of this skill.
