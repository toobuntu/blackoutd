---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 7
title: Disable Homebrew analytics in agent and CI contexts
status: accepted
date: 2026-06-14
decision-makers:
  - toobuntu
---

# Disable Homebrew analytics in agent and CI contexts

## Context and Problem Statement

Homebrew sends usage analytics over the network on essentially every
invocation. blackoutd's tooling shells out to `brew` repeatedly — the
pre-commit hook's clang-tidy/llvm toolchain probe, and `make tidy` / `make
lint` via `brew exec` — so each commit and lint run triggers analytics traffic.
Inside the Claude Code agent sandbox this also surfaced as a recurring
`curl (56) 404` against the Homebrew packages API for a pre-release macOS the
API does not yet recognize (`dunno_tahoe`), polluting otherwise-clean lint
output. This traffic is automated and non-representative: the same probe fires
on every commit, the kind of usage Homebrew's own guidance asks CI to exclude.

## Considered Options

- Disable analytics for agent/CI `brew` calls (`HOMEBREW_NO_ANALYTICS=1` in the
  Claude Code session `env`).
- Allowlist the Homebrew analytics endpoint and leave analytics enabled.
- Do nothing.

## Decision Outcome

Chosen option: **disable analytics for agent/CI `brew` calls**, via
`HOMEBREW_NO_ANALYTICS=1` in the `env` key of `.claude/settings.json`. A Claude
Code `env` applies only to processes the agent spawns, not the maintainer's
interactive login shell — so it suppresses exactly the repetitive automated
traffic while leaving normal interactive `brew` usage untouched, and it needs no
telemetry host in the sandbox network allowlist.

(The separate packages-API 404 is handled where it occurs:
`HOMEBREW_NO_INSTALL_FROM_API=1` scoped to the pre-commit toolchain probe in
`.githooks/pre-commit`; `HOMEBREW_NO_AUTO_UPDATE` does not cover that fetch.)

### Consequences

- Good, because Homebrew's analytics keep reflecting representative human usage;
  the agent's automated traffic is excluded, which improves rather than degrades
  their dataset.
- Good, because no telemetry endpoint is added to the sandbox network allowlist.
- Good, because the maintainer still contributes analytics through ordinary
  interactive `brew` usage.
- Bad, because the agent's `brew` usage no longer contributes any analytics —
  accepted, since that traffic is non-representative and unwanted by Homebrew.

## Pros and Cons of the Options

### Allowlist the analytics endpoint and leave analytics on

Add Homebrew's InfluxDB host, `eu-central-1-1.aws.cloud2.influxdata.com`
(defined as `INFLUX_HOST` in `Library/Homebrew/utils/analytics.rb`), to
`sandbox.network.allowedDomains`.

- Good, because the agent's `brew` usage would then contribute to Homebrew
  analytics.
- Bad, because it opens sandbox egress to a telemetry endpoint and feeds
  non-representative automated traffic into Homebrew's dataset.
- Neutral: this remains the path to take if contributing the agent's usage is
  ever explicitly wanted — unset the env var and add the host.

### Do nothing

- Bad, because it leaves the recurring 404 noise and per-commit telemetry, and
  the agent's automated runs keep skewing Homebrew analytics.
