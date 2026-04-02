<!--
SPDX-FileCopyrightText: Copyright 2026-Present Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

## Summary

<!-- Brief description of the change. -->

## Changes

<!-- Bullet list of what was changed and why. -->

## Testing

<!-- How was this tested? Include log output or screenshots if applicable. -->

- [ ] `make clean && make` succeeds
- [ ] clang-format passes on changed files:
  - macOS: `xcrun clang-format --style=file --dry-run --Werror <files>`
  - Linux: `clang-format --style=file --dry-run --Werror <files>`
- [ ] Manual testing on hardware (if display behavior changed)

**Run these commands immediately after the issue occurs and paste the output:**

```sh
system_profiler SPHardwareDataType SPDisplaysDataType -detailLevel mini
sw_vers
uname -m
pmset -g log | grep -E "Sleep|Wake|Clamshell" | tail -30
log show --last 5m --predicate 'process == "blackoutd"'
```
