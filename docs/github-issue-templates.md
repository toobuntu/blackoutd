<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# GitHub issue templates for Claude Code pickup

Items that are well-scoped enough for Claude Code to pick up autonomously (with the maintainer reviewing the resulting PR):

### P10 — _actionInProgress signaling + dispatch_source efficiency
```shell
gh issue create \
  --title "P10: replace _actionInProgress heuristic with explicit signaling" \
  --body "See \`docs/technical-debt.md\` P10. Two related changes:

1. Replace the 2-second \`_actionInProgress\` window with a mechanism that
   distinguishes echoes of our own action from new external events
   (per-display sequence numbers, or a short pending-operation queue).
2. Replace the wake-settle timer's create+cancel-per-callback with a
   single \`dispatch_source_t\` reused via \`dispatch_source_set_timer\`
   to reset the fire date.

Acceptance criteria in \`docs/technical-debt.md\`. Verification needs a
manual rapid-plug/unplug test." \
  --label "tech-debt,correctness"
```

### P11 — sleep-disconnect single ivar
```shell
gh issue create \
  --title "P11: sleep-time external-disconnect tracking is single-display-only" \
  --body "See \`docs/technical-debt.md\` P11. Pick one of:
- Document single-external-display as the supported configuration in
  \`docs/architecture.md\` and add a clarifying comment in
  \`DisplayController.m\`.
- Replace \`_externalDisconnectedDuringSleep\` with a per-CGDirectDisplayID
  set evaluated at wake.

Single-display setups are unaffected by the current behavior; this is
about correctness for the multi-external case." \
  --label "tech-debt,needs-decision"
```

### P13 — pref keys
```shell
gh issue create \
  --title "P13: extract NSUserDefaults keys to a typed constants header" \
  --body "See \`docs/technical-debt.md\` P13. \`@\"autoBlackoutOnExternalConnect\"\`
appears in 3 files; \`@\"blackoutActive\"\` in 2. Move to
\`src/Preferences.h\` (extern NSString *const) + \`src/Preferences.m\`,
update all readers and writers. No behavior change.

Good-first-PR fodder." \
  --label "tech-debt,good-first-issue"
```

### P14 — user vs system blackout (needs ADR)
```shell
gh issue create \
  --title "P14: ADR — user-disabled vs system-disabled blackout" \
  --body "See \`docs/technical-debt.md\` P14. \`kBlackoutActiveKey\`
currently does not distinguish 'user clicked Disable' from 'external
unplugged during sleep'. Decide deliberately and document in a new ADR
(0005). Implementation should match the ADR; logging should expose the
distinction." \
  --label "tech-debt,needs-decision,docs"
```

### P15 — NSTask helpers
```shell
gh issue create \
  --title "P15: consolidate NSTask wrappers in main.m" \
  --body "See \`docs/technical-debt.md\` P15. Four near-duplicate
helpers (\`runLaunchctl\`, \`runShellToFile\`, \`runToFile\`,
\`runAndPrint\`) collapse to one \`runProcess(path, args, output)\`.
~30 lines duplicate plumbing removed. No behavior change." \
  --label "tech-debt,refactor"
```

### P16 — verify reuse annotate frontmatter behavior
```shell
gh issue create \
  --title "P16: verify reuse annotate handles Markdown YAML frontmatter" \
  --body "See \`docs/technical-debt.md\` P16. The repo follows two
SPDX-placement conventions (ADRs: inside frontmatter as \`#\` comments;
skills: HTML comment after closing \`---\`). \`scripts/annotate.sh\`'s
behavior with these conventions is documented but not verified.

Construct minimal repros, run \`reuse annotate --style=html\` against
each, capture output, and either (a) confirm the script does the right
thing and add regression tests, or (b) fix the script / update the docs
to match reality." \
  --label "tech-debt,verification"
```

### P17 — make release hardening
```shell
gh issue create \
  --title "P17: make release hardening — semver validation, undo, dry-run" \
  --body "See \`docs/technical-debt.md\` P17. \`make release\` has minor
sharp edges:

- No semver regex check on \`CFBundleShortVersionString\`.
- No \`make release-undo\` (cleanup is manual \`git tag -d\`).
- No \`make release-dry-run\`.

Implementation is straightforward Makefile additions. None blocking." \
  --label "tech-debt,tooling"
```

### P18 — find_unicode_control2 reference dir
```shell
gh issue create \
  --title "P18: decide on scripts/find_unicode_control2--*/" \
  --body "See \`docs/technical-debt.md\` P18. The RedHat reference
script directory is gitignored but in the working tree. Pick: move to
\`docs/decisions/0001-references/\` and commit, remove entirely, or
keep gitignored and add an ADR note. Trivial." \
  --label "tech-debt,housekeeping"
```
