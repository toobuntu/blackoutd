<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Branch protection ruleset for `main`

This document describes the branch protection ruleset enforced on
`main`, why each rule was chosen, and how to create or modify it.

## Goals

The ruleset enforces these properties:

1. No direct pushes to `main`. Every change arrives via a pull request.
2. PRs can only be merged after CI passes.
3. PRs cannot be merged via squash or rebase — only merge commits
   (per [ADR 0004](decisions/0004-merge-strategy.md)).
4. The branch cannot be force-pushed or deleted.
5. The maintainer is subject to the same rules as any contributor;
   there is no general bypass.

A single-maintainer public repository does not gain much from required
*reviews* (GitHub forbids self-approval), so the gating is on **status
checks** and **policy** rather than on review approvals.

## Chosen rules

| Rule                                       | Setting                              |
|--------------------------------------------|--------------------------------------|
| Require a pull request before merging      | Enabled, **0 required approvals**    |
| Dismiss stale approvals on new commits     | Enabled (defensive; cheap)           |
| Require approval of most recent reviewable push | Enabled                          |
| Require status checks to pass              | Enabled, list below                  |
| Require branches up to date before merging | **Disabled**                         |
| Allowed merge methods                      | **Merge commit only**                |
| Require linear history                     | **Disabled**                         |
| Require signed commits                     | Optional; recommended                |
| Block force pushes                         | Enabled                              |
| Block branch deletion                      | Enabled                              |
| Bypass list                                | **Empty**                            |

### Required status checks

These check names match the job names in `.github/workflows/ci.yml`.
GitHub matches by exact job name as it appears on completed runs.

- `build`
- `lint-plist`
- `lint-format`
- `lint-unicode`
- `lint-tidy`
- `spec`

CodeQL is **not** required as a status check. It runs on a schedule
(`cron: '27 3 * * 1'`) and on PRs, but `lint-actions` coverage from
`actionlint` plus `zizmor` is the practical floor; CodeQL is a free
backstop, not a blocker.

### Why "branches up to date" is disabled

Requiring a feature branch to be rebased onto the latest `main` before
merge sounds like a good hygiene rule but conflicts with the
merge-commit strategy in ADR 0004. The merge commit itself is the
explicit point where `main` and the feature branch are reconciled; a
preceding rebase erases authorship dates and original commit hashes
from the feature branch. A solo maintainer on a low-traffic repo
rarely encounters drift that "branches up to date" actually catches.

### Why merge-commit-only

ADR 0004 explains the full reasoning. Summary: merge commits preserve
PR identity in `git log --graph`, retain original authorship and
dates, and avoid the historical-rewriting that squash and rebase
impose. The repo also has `scripts/rewrite-pr-as-merge-commit.sh` for
the rare case where a PR is accidentally rebase-merged and needs to
be rewritten as a merge commit; this tool only makes sense if
merge-commit is the chosen and enforced strategy.

### Why no required approvals

GitHub does not allow a PR's author to approve their own PR. Setting
"required approvals" to 1 on a single-maintainer repo would
effectively block all merges. The status-check gate is the primary
quality bar here. A second pair of eyes on the work comes from
external code-review tools (CodeRabbit, Copilot review, ChatGPT
review) whose feedback is captured in `docs/reviews/` and addressed
before merge.

If the project gains a regular co-maintainer, raise this to 1
required approval.

### Why no bypass list

A bypass list weakens the ruleset's promise. The maintainer should
follow the same flow as any contributor: feature branch → PR → CI
→ merge. The cost of doing so for a hotfix is one extra `git push`
and one click on the merge button.

For genuine emergencies (CI is broken and a one-line fix is needed
to unblock everyone), the ruleset can be temporarily disabled and
re-enabled. This is intentional friction.

## Creating the ruleset

GitHub's UI under **Settings → Rules → Rulesets** is the most
discoverable path. The CLI (`gh api`) is faster once you have a
JSON definition. Both are documented below.

### Via the GitHub UI

1. Open the repo on github.com.
2. Settings → Rules → Rulesets → **New ruleset → New branch ruleset**.
3. **Ruleset name**: `main protection`.
4. **Enforcement status**: `Active`.
5. **Bypass list**: leave empty.
6. **Target branches** → **Add target** → **Include default branch**.
7. **Branch rules** — enable in this order:
   - `Restrict deletions`.
   - `Require linear history` — **leave OFF**.
   - `Require a pull request before merging`:
     - `Required approvals`: `0`.
     - `Dismiss stale pull request approvals when new commits are pushed`: **on**.
     - `Require approval of the most recent reviewable push`: **on**.
     - `Allowed merge methods`: **Merge** only (uncheck `Squash` and `Rebase`).
   - `Require status checks to pass`:
     - `Require branches to be up to date before merging`: **OFF**.
     - Add status checks (one per line, exact job names):
       - `build`
       - `lint-plist`
       - `lint-format`
       - `lint-unicode`
       - `lint-tidy`
       - `spec`
   - `Block force pushes`.
   - (Optional) `Require signed commits`.
8. Click **Create**.

The ruleset takes effect immediately for the default branch.

### Via the GitHub CLI

The Rulesets REST API takes a JSON body. The command below creates
the ruleset directly. Edit `OWNER` and `REPO` at the top, then run.

```sh
OWNER=toobuntu
REPO=blackoutd

gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  "/repos/${OWNER}/${REPO}/rulesets" \
  --input - <<'JSON'
{
  "name": "main protection",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": true,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["merge"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          { "context": "build" },
          { "context": "lint-plist" },
          { "context": "lint-format" },
          { "context": "lint-unicode" },
          { "context": "lint-tidy" },
          { "context": "spec" }
        ]
      }
    }
  ]
}
JSON
```

The `~DEFAULT_BRANCH` ref-name is a GitHub-special token meaning
"whatever the default branch happens to be" — preferable to
hardcoding `refs/heads/main` because it survives a future rename
(see Homebrew's transition from `master`).

`strict_required_status_checks_policy: false` is the JSON equivalent
of "Require branches to be up to date before merging" being OFF.

### Verifying

```sh
# List rulesets on the repo:
gh api "/repos/${OWNER}/${REPO}/rulesets" | jq '.[] | {id, name, enforcement}'

# Show the full ruleset (substitute the id from the list):
gh api "/repos/${OWNER}/${REPO}/rulesets/<ID>" | jq .
```

To test that the ruleset is active, attempt a direct push to `main`
from a clone:

```sh
git switch main
git commit --allow-empty -m "test: should be blocked"
git push
# expected: remote rejects with "GH013: Repository rule violations found".
git reset --hard HEAD~1
```

## Modifying

Modifications go through the same UI page (Settings → Rules → Rulesets
→ click the ruleset name) or via `gh api -X PUT
/repos/${OWNER}/${REPO}/rulesets/<ID>` with the same JSON shape.

When CI jobs are added or renamed in `.github/workflows/ci.yml`, the
required status check list must be updated to match. A common
oversight is renaming a job and forgetting to update the ruleset —
the ruleset will then wait forever for a check that never runs and
block all merges. To diagnose this, look at a stuck PR's "Checks"
tab; the missing required check is shown with status "Expected".

## Disabling temporarily

For a genuine emergency where the ruleset itself is the obstacle
(e.g. a CI infrastructure outage):

```sh
# Get the ruleset id:
RULESET_ID=$(gh api "/repos/${OWNER}/${REPO}/rulesets" | jq '.[] | select(.name=="main protection") | .id')

# Disable:
gh api -X PUT "/repos/${OWNER}/${REPO}/rulesets/${RULESET_ID}" \
  -f enforcement=disabled

# ... do the emergency work ...

# Re-enable:
gh api -X PUT "/repos/${OWNER}/${REPO}/rulesets/${RULESET_ID}" \
  -f enforcement=active
```

The ruleset definition is preserved; only enforcement is toggled.
Always re-enable as soon as the emergency passes.

## Why a ruleset and not classic branch protection

GitHub maintains two parallel systems: **classic branch protection
rules** (older, tied directly to a branch name) and **rulesets**
(newer, more flexible, can target multiple branches and run in
"evaluate" mode for testing). New repositories should prefer
rulesets. Classic branch protection is in long-term maintenance
mode but not deprecated.

If a classic protection rule already exists on `main`, it will
co-exist with the ruleset (both apply, AND-ed). For clarity,
remove the classic rule once the ruleset is active and verified.

```sh
# Check for classic protection (returns 404 if none):
gh api "/repos/${OWNER}/${REPO}/branches/main/protection" 2>/dev/null && echo "classic protection exists"

# Remove if present (irreversible):
gh api -X DELETE "/repos/${OWNER}/${REPO}/branches/main/protection"
```
