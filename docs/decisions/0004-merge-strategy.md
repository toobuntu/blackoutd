---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 4
title: Merge PRs with merge commits, not squash or rebase
status: accepted
date: 2026-04-27
decision-makers:
  - toobuntu
---

# Merge PRs with merge commits, not squash or rebase

## Context and Problem Statement

GitHub offers three merge strategies:

* **Create a merge commit** — preserves the PR branch's commits and adds a
  merge commit that has both the base branch tip and the PR head as
  parents. The PR is identifiable in `git log --graph` as a topology
  feature; the merge commit's message preserves the PR number and title.
* **Squash and merge** — collapses every PR commit into one commit on the
  base branch. The intermediate commits are gone; only the final state is
  preserved.
* **Rebase and merge** — replays the PR commits onto the base branch
  individually, with no merge commit. The PR's grouping into a logical
  unit is lost; commits appear interleaved with whatever else lands on
  main between the rebase and any subsequent merges.

A previous PR was merged via "rebase and merge" by accident, prompting the
authoring of `scripts/rewrite-pr-as-merge-commit.sh` to convert it after
the fact.

The project must commit to a single merge strategy and document it.

## Decision Drivers

* PR history visible in `git log --graph` after merge — a reviewer
  reading history a year later should be able to see what changed
  together
* Original commit dates and authorship preserved
* Intermediate commits available for `git bisect` and review
* PR number and title traceable from the merge commit message
* No need for tooling to "rescue" PRs that were merged the wrong way

## Considered Options

* **Merge commits**
* **Squash and merge**
* **Rebase and merge**

## Decision Outcome

Chosen option: **Create a merge commit**.

`scripts/rewrite-pr-as-merge-commit.sh` exists for the case where a PR was
accidentally merged with a different strategy. It rewrites the base branch
by resetting to the merge-base and re-replaying the PR commits as a merge
commit. The script requires `--force-with-lease` and is destructive; it
should not be needed in normal operation.

The repository's GitHub merge-button settings should be configured to:

* **Allow merge commits**: enabled
* **Allow squash merging**: disabled
* **Allow rebase merging**: disabled

This makes the correct choice the default and prevents accidental
strategy changes.

### Consequences

* Good, because PR groupings remain visible after merge — `git log
  --graph --oneline` shows each PR as a topology branch with a merge
  commit at the join.
* Good, because original commit dates and authorship are preserved
  unchanged. Squash merge collapses authorship to the merger; rebase
  merge rewrites commit dates.
* Good, because intermediate commits remain available to `git bisect`,
  preserving the project's ability to localize regressions.
* Good, because the merge commit message references the PR number and
  title, providing a stable link from history to GitHub.
* Bad, because `git log` (without `--graph`) shows more commits than
  squash merge would; reviewers wanting a "summary" view need to read
  PR titles or use `--first-parent`.
* Bad, because if a PR contains noise commits ("fix typo", "address
  review feedback"), those commits remain in history. Mitigation:
  PR authors are asked to clean up their branch before merging
  (`git rebase -i` on the PR branch is fine; that is local rewriting,
  not the merge strategy).

### Confirmation

The repository's "Pull request" settings on GitHub must show only "Allow
merge commits" enabled. CONTRIBUTING.md (or its successor) should
explicitly state the merge strategy so contributors do not propose
rebase- or squash-merge workflows.

## Pros and Cons of the Options

### Merge commits (chosen)

* Good, preserves PR identity in history.
* Good, preserves authorship and dates.
* Good, supports `git bisect` granularity.
* Bad, more commits in `git log` (without `--graph`).
* Bad, contributors must clean up their PR branches before merge.

### Squash and merge

* Good, single tidy commit per PR on main.
* Good, no review-noise commits in history.
* Bad, intermediate commits are gone — `git bisect` can only land on
  PR-sized changes, complicating regression localization.
* Bad, authorship of squashed commits is collapsed; multi-author PRs
  lose contribution history.
* Bad, the squash commit's date is the merge date, not the original
  authoring date.

### Rebase and merge

* Good, linear history.
* Bad, PR identity is lost — commits appear interleaved with whatever
  else lands on main between the rebase and any subsequent merges.
* Bad, commit dates are rewritten to the rebase time, distorting the
  authoring timeline.
* Bad, no merge commit means the PR number is not in history (only in
  the linked GitHub issue/PR data).
* Bad, accidental rebase-merge requires history rewriting (the
  `rewrite-pr-as-merge-commit.sh` script) to recover.

## More Information

* `scripts/rewrite-pr-as-merge-commit.sh` — recovery tool for PRs that
  were merged with the wrong strategy
* [GitHub: About merge methods on
  GitHub](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/about-merge-methods-on-github)
