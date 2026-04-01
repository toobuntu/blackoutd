<!--
SPDX-FileCopyrightText: Copyright 2026-Present Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Copilot Instructions for toobuntu/blackoutd

Full instructions are in [AGENTS.md](../AGENTS.md) and [CLAUDE.md](../CLAUDE.md).
Defer to those files for authoritative detail.

## Quick reference

- **Language**: Objective-C, ARC, AppKit. No Swift.
- **Build**: `make` (requires Xcode Command Line Tools)
- **Lint**: `find src -name '*.m' -o -name '*.h' | xargs clang-format --style=file --dry-run --Werror`
- **Test**: No automated tests yet. See AGENTS.md for manual checklist.

## Before committing

1. Run `clang-format --style=file -i` on any changed `.m` or `.h` files.
2. Verify the build still succeeds: `make clean && make`
3. Verify plist generation: `make postinstall`

## Safety invariant

The built-in display MUST be restored when the last external display disconnects.
The check in `handleReconfiguration:flags:` is unconditional — it must never be
gated on `_actionInProgress` or any other guard.
