---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 8
title: Pre-push signing gate is a maintainer self-guardrail, not a contribution gate
status: accepted
date: 2026-06-21
decision-makers:
  - toobuntu
---

# Pre-push signing gate is a maintainer self-guardrail, not a contribution gate

## Context and Problem Statement

The `.githooks/pre-push` hook validates commit signatures before a push. As it
evolved — and through a round of bot code review — its *purpose* was repeatedly
mis-stated, by both an AI assistant and review bots, as if it enforced an
integrity property of the repository or of its remotes. That framing produced a
sequence of wrong "fixes": validate the entire history on a raw-URL push; scope
grandfathering per-remote ("this-target" vs "published-anywhere"); exempt
commits authored by other people. None of those serve the actual policy.

This ADR records what the gate is *for*, so future changes — and the promotion
of this hook to repo-foundation as the org-wide canonical version — are measured
against the intended policy rather than re-derived from the mechanics.

## Decision Drivers

- Signing must not become a barrier to contribution (CONTRIBUTING.md, "Signed
  pushes").
- A commit's identity fields (author, committer) are trivially forgeable and
  cannot be the basis of any security decision.
- The hook is shared across repos and is destined for repo-foundation; its
  intent must be documented, not just its code.

## Considered Options

- **Maintainer self-guardrail** — the gate exists so a maintainer who has
  signing configured does not *accidentally* push commits they forgot to sign.
- **Repository/remote integrity invariant** — enforce that the repo, or each
  remote, contains only signed commits.
- **Contribution gate** — require every committer to sign.

## Decision Outcome

Chosen: **the gate is a maintainer self-guardrail.** Concretely, as implemented
in `.githooks/pre-push`:

- **Scoped by local signing config.** Enforce (reject) only when signing is
  configured locally (`commit.gpgsign=true` or `user.signingkey` set), or when
  `hooks.requireSignedPush=true` forces it. Otherwise the same scan runs but only
  **warns** and the push proceeds — a contributor who enabled the hooks for the
  pre-commit checks is informed, never blocked. `git config hooks.requireSignedPush
  true|false` overrides detection either way; a one-off bypass that keeps every
  other check is `git -c hooks.requireSignedPush=false push …` (preferred over
  `--no-verify`, which skips the hook entirely).
- **Validates the whole introduced range, regardless of author or committer.**
  The range is `remote_oid..local_oid`, or `--not --remotes[=<dest>]` for a new
  ref / unfetched tip — what the push *adds*, never the full history, so
  already-published commits (including pre-policy ones) are not re-flagged.
  Within that range every commit must carry an accepted signature. Author and
  committer are **not** used to exempt commits: both are forgeable
  (`git commit --author=… ` / `GIT_COMMITTER_*`), so an identity-based exemption
  would be a hole. Maintainer-scoping is achieved entirely by the enforce-vs-warn
  split above, plus the fact that a maintainer re-signs whatever they push (an
  `--amend`/rebase records them as committer; the author is preserved).
- **`%G?` acceptance:** `G`/`U`/`X`/`Y` pass (a good signature was made);
  `N`/`B`/`R`/`E` are rejected.
- **No signing check in CI.** A signature check that *rejects* would gate
  contributions, contradicting the policy; CI therefore does not check
  signatures. Any server-side requirement on `main` is a GitHub ruleset,
  configured to match this policy — separate from CI, and applying regardless of
  local hooks.
- **GitHub web-flow merges.** These originate on the remote, so on a normal push
  they sit behind `remote_oid` and are never validated. In the rare case one is
  in the introduced range and unverifiable (`E`, because GitHub's public key is
  absent), the hook recognizes the web-flow committer (`GitHub
  <noreply@github.com>`) and points at the one-time import
  (`curl -fsSL https://github.com/web-flow.gpg | gpg --import`; an untrusted
  import is sufficient — it makes the signature *verifiable* as `U`/`Y` without
  extending trust). This is a **hint, not an exemption**: the gate still rejects
  until the commit verifies, so no security decision rests on the forgeable
  committer field.

Because the gate is local-only and concerns just "what am I, the configured
signer, about to push," **the number of remotes is irrelevant** — the `--remotes`
machinery exists only to identify newly-introduced commits, not to assert
anything about remote state.

### Consequences

- Good, because contributors are never blocked; the policy is the maintainers'
  own.
- Good, because no security decision rests on a forgeable identity field.
- Good, because nothing about remote topology or CI is load-bearing, so the gate
  stays simple and the multi-remote question does not arise.
- Bad (accepted), because a maintainer must re-sign commits they push but did not
  author (e.g., taking a contributor's unsigned work forward by rebase). This is
  the intended flow — the signature is the committer's attestation; authorship is
  preserved.
- Bad (accepted), because re-signing unpushed commits rewrites their SHAs (the
  signature lives in the commit object). Safe while unpushed; the gate itself
  keeps an un-re-signed batch from reaching the remote.

## Pros and Cons of the Options

### Repository/remote integrity invariant

Treating the gate as "the repo / each remote contains only signed commits."

- Bad, because it isn't true and was never the goal — pre-policy unsigned commits
  exist and are grandfathered, and contributors' unsigned commits are allowed.
- Bad, because it invented a "multi-remote scoping" question (grandfather
  per-target vs per-any-remote) with no bearing on a local self-guardrail.
- Bad, because it motivated "validate the entire history on a raw-URL push,"
  which re-flags grandfathered legacy commits for no benefit.

### Contribution gate (every committer must sign)

- Bad, because it directly violates CONTRIBUTING.md — signing is a maintainer
  policy, not a barrier to contributing.
- This is why enforcement is scoped to locally-configured signing, and why CI
  must not reject on signatures.

### Author/committer-based exemption

Exempting commits whose author/committer is "someone else."

- Bad, because the author field is set with `git commit --author=…` and the
  committer via `GIT_COMMITTER_*`; either can be forged to carry an unsigned
  commit past the gate. The gate therefore validates the whole range and lets
  enforce-vs-warn plus re-signing do the scoping.

## More Information

- CONTRIBUTING.md, "Signed pushes (maintainer policy, not a contribution gate)".
- `.githooks/pre-push` — the implementation; the canonical version across the
  org's repos.
- `docs/agent-principles.md`, "Agent commit + signing procedure under sandbox
  isolation" — the re-sign incantation and why SHAs change.
- Promotion: this hook and policy move to repo-foundation during the W1
  bootstrap; the other repos' `pre-push` hooks are synced from this one.
