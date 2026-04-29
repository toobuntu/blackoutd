<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Claude Code MCP server configuration

This file documents which MCP servers are appropriate for which kinds
of work the maintainer does, and how to configure them. Most projects
need few or no MCP servers; the maintainer's Homebrew-related work is
the main exception.

## When MCP is and isn't useful

Claude Code's built-in tools cover most needs:

- File reads and writes via `Read`, `Edit`, `Write`, `MultiEdit`
- Web search and fetch via `WebSearch` and `WebFetch`
- Shell commands via `Bash`
- Git operations via `Bash` against `git`/`gh`

An MCP server is worth adding when:

1. A specialized tool exposes structured data that would be tedious to
   parse from CLI output (e.g., a Homebrew formula's full metadata
   rather than `brew info` text).
2. The agent benefits from knowing the *schema* of available operations
   in advance, rather than guessing CLI flags.
3. The tool is one the maintainer uses in *most* sessions for that
   project, not occasionally.

An MCP server is **not** worth adding when:

1. The CLI form works fine and is in the permission allow-list (e.g.,
   `Bash(git:*)`-style operations).
2. The MCP would primarily duplicate existing Bash permissions.
3. The MCP is rarely used; every connected MCP adds tools to the
   context window, increasing token cost on every request.

## Recommendations by project type

### blackoutd (Objective-C + macOS LaunchAgent)

**No MCP servers recommended.** Everything blackoutd development needs
is covered by Bash permissions (Make, clang, log, pmset, ioreg, ipsw,
otool) and Claude Code's built-in tools. Adding `brew mcp-server` here
would only help if the project gained Homebrew formula or cask work,
which is not on the roadmap.

### Homebrew-focused repositories (homebrew-cask-tools, homebrew taps)

**Add `brew mcp-server`.** This is the official Homebrew MCP server,
shipped with Homebrew itself
(see [docs.brew.sh/MCP-Server][docs] and
[Homebrew/brew#20041][pr20041]). It exposes the standard Homebrew
subcommands as MCP tools, which means:

- The agent knows the exact set of `brew` operations available in the
  current Homebrew version, without you having to maintain them in
  the Bash allow-list.
- Output is structured JSON, easier for the agent to reason about
  than parsing `brew info --json=v2` from a Bash invocation.
- Read-only operations (`info`, `list`, `search`, `outdated`, `deps`,
  `desc`, `uses`) are the typical case; mutating operations
  (`install`, `uninstall`, `upgrade`, `cleanup`, `tap`) still go
  through Claude Code's permission system.

The server is launched as a stdio MCP process by Claude Code on
demand. It does not run continuously.

#### Configuration

Per-project `.mcp.json` at the repository root (committed to the
repo so collaborators get the same configuration):

```json
{
  "mcpServers": {
    "homebrew": {
      "command": "brew",
      "args": ["mcp-server"]
    }
  }
}
```

Or per-user via `claude mcp add`:

```sh
claude mcp add homebrew brew mcp-server
```

The user-level configuration stores in `~/.claude.json` under the
project's entry. Project-level configuration in `.mcp.json` is the
preferred form for a Homebrew repo where the configuration is
inherent to the project's purpose.

#### Permission scope for Homebrew work

When `brew mcp-server` is configured, augment the project's
`.claude/settings.json` with permission rules for the Homebrew tool
namespace:

```json
{
  "permissions": {
    "allow": [
      "mcp__homebrew__info",
      "mcp__homebrew__list",
      "mcp__homebrew__search",
      "mcp__homebrew__outdated",
      "mcp__homebrew__deps",
      "mcp__homebrew__desc",
      "mcp__homebrew__uses",
      "mcp__homebrew__doctor"
    ],
    "ask": [
      "mcp__homebrew__install",
      "mcp__homebrew__uninstall",
      "mcp__homebrew__upgrade",
      "mcp__homebrew__cleanup",
      "mcp__homebrew__tap",
      "mcp__homebrew__untap",
      "mcp__homebrew__reinstall"
    ]
  }
}
```

The MCP tool naming convention is `mcp__<server-name>__<tool-name>`
where `<server-name>` is the key in `.mcp.json`'s `mcpServers` object.

When working on a tap or cask repository specifically, also allow
read-only audit and style commands:

```json
"Bash(brew audit:*)",
"Bash(brew style:*)",
"Bash(brew livecheck:*)",
"Bash(brew test:*)",
"Bash(brew bottle:*)"
```

These run via the regular Bash permission system (they are not
exposed by `brew mcp-server`'s default tool set, which focuses on
package-management operations rather than developer tooling).

### General-purpose projects

For most other repositories, no MCP server is needed. If a specific
need arises:

- **Database work**: postgres-mcp, mysql-mcp (read-only by default
  preferred).
- **Browser automation**: Chrome DevTools MCP for testing web UIs.
- **Container work**: docker-mcp.

The general principle: every MCP server adds tools to the context.
Add only those used in most sessions for the project.

## Trust prompts

The first time Claude Code sees an MCP server in `.mcp.json` for a
project, it prompts the maintainer to trust the directory. This is
the same mechanism that gates `enabledPlugins` on first encounter.

Server-managed `allowManagedMcpServersOnly: true` and
`disabledMcpjsonServers` settings exist for organizations that need
strict policy control; they are not needed for a single-maintainer
setup.

[docs]: https://docs.brew.sh/MCP-Server
[pr20041]: https://github.com/Homebrew/brew/pull/20041
