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
5. The repository administrator (sole maintainer) has bypass capability
   so they can self-merge their own PRs. See *Single-maintainer
   self-bypass* below for the rationale and trade-off.

A single-maintainer public repository does not gain much from required
*reviews* from humans (GitHub forbids self-approval), so the gating is on
**status checks** (CI must pass) and **policy** (the PR-and-merge-method
rules) rather than on review approvals from a person. Automated reviewers
(Copilot code review, CodeRabbit) provide a second pair of eyes whose
comments are addressed before merge but whose approval is not required
to merge.

## Chosen rules

| Rule                                       | Setting                              |
|--------------------------------------------|--------------------------------------|
| Require a pull request before merging      | Enabled, **0 required approvals**    |
| Dismiss stale approvals on new commits     | Enabled (defensive; cheap)           |
| Require approval of most recent reviewable push | **Disabled**                    |
| Automatically request Copilot review       | Enabled                              |
| Require status checks to pass              | Enabled, list below                  |
| Require branches up to date before merging | **Disabled**                         |
| Allowed merge methods                      | **Merge commit only**                |
| Require linear history                     | **Disabled**                         |
| Require signed commits                     | Optional; recommended                |
| Block force pushes                         | Enabled                              |
| Block branch deletion                      | Enabled                              |
| Bypass list                                | **Repository admin** (single maintainer) |

### Required status checks

These check names must exactly match the job names in
`.github/workflows/ci.yml`. GitHub matches by the job name as it appears
on completed runs. **When CI jobs are added, removed, or renamed, this
list must be updated in lockstep** — see "Modifying" below.

- `build`
- `lint-plist`
- `lint-format`
- `lint-unicode`
- `lint-reuse`
- `lint-tidy`
- `spec`

CodeQL is **not** required as a status check. It runs on a schedule
(`cron: '27 3 * * 1'`) and on PRs, but the practical floor for Actions-
workflow security scanning is `actionlint` plus `zizmor`, which run as
part of the pre-commit hook and (eventually) CI. CodeQL is a free
backstop, not a blocker. Copilot code review is also not required —
it produces comments to consider, not an approval gate.

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
external code-review tools (CodeRabbit, Copilot review, occasional
ChatGPT review) whose feedback is captured in `docs/reviews/` and
addressed before merge.

If the project gains a regular co-maintainer, raise this to 1
required approval and remove the admin bypass below.

### Why "approval of most recent reviewable push" is disabled

GitHub describes this rule as: "the most recent reviewable push must
be approved by someone other than the person who pushed it." On a
single-maintainer repo, "someone other than the person who pushed it"
does not exist among the repo's collaborators, so enabling this rule
blocks every merge by the maintainer. It's the right rule to enable
the moment a co-maintainer joins; until then, it's pure friction.

### Single-maintainer self-bypass

The bypass list contains **Repository admin** (the sole maintainer's
role). This grants bypass for the rules above, including the
"require a pull request" rule.

This is a deliberate concession to single-maintainer reality, with two
mitigations:

1. The maintainer's standard workflow remains feature-branch → PR →
   CI → merge. Bypass is invoked only via the merge button after the
   PR has CI-green status. This is enforced by **discipline**, not
   tooling; if the maintainer ever feels themselves reaching for
   `git push origin main` directly, the right response is to stop and
   open a PR.
2. The pre-commit hook in `.githooks/pre-commit` blocks direct commits
   to `main` regardless of bypass status (it runs locally before the
   push reaches GitHub). Combined with the Claude Code PreToolUse
   hook in `.claude/settings.json` that blocks Edit/Write/MultiEdit on
   the `main` branch, this preserves the no-direct-edits-to-main
   property at the workstation level even though GitHub itself
   permits it.

If the project gains a regular co-maintainer, **remove the admin
bypass** at the same time you enable required approvals.

### Automatic Copilot code review

The ruleset has Copilot code review configured to run automatically on
every PR. Its comments are advisory and not required to merge.
Copilot's strengths are catching obvious bugs, missed null checks, and
formatting issues; its weaknesses are over-eagerness on stylistic
nits and occasional invented bugs. Treat its output the same as
CodeRabbit: read every comment, accept the substantive ones, ignore
or rebut the rest.

If GitHub's pricing changes for Copilot review (the
[Copilot pricing changes announced 2026-04](https://github.blog/changelog/2026-04-20-changes-to-github-copilot-plans-for-individuals/)
moved Copilot to usage-based billing), the workflow falls back to
CodeRabbit alone, which is still active. No code change is needed if
Copilot review becomes unavailable; the PR conversation just gets one
fewer reviewer.

## Creating the ruleset

GitHub's UI under **Settings → Rules → Rulesets** is the most
discoverable path. The CLI (`gh api`) is faster once you have a
JSON definition. Both are documented below.

### Via the GitHub UI

1. Open the repo on github.com.
2. Settings → Rules → Rulesets → **New ruleset → New branch ruleset**.
3. **Ruleset name**: `main protection`.
4. **Enforcement status**: `Active`.
5. **Bypass list**: **Add bypass → Repository admin → Always**.
6. **Target branches** → **Add target** → **Include default branch**.
7. **Branch rules** — enable in this order:
   - `Restrict deletions`.
   - `Require linear history` — **leave OFF**.
   - `Require a pull request before merging`:
     - `Required approvals`: `0`.
     - `Dismiss stale pull request approvals when new commits are pushed`: **on**.
     - `Require approval of the most recent reviewable push`: **OFF** (single-maintainer repo).
     - `Automatically request Copilot code review`: **on**.
     - `Allowed merge methods`: **Merge** only (uncheck `Squash` and `Rebase`).
   - `Require status checks to pass`:
     - `Require branches to be up to date before merging`: **OFF**.
     - Add status checks (one per line, exact job names):
       - `build`
       - `lint-plist`
       - `lint-format`
       - `lint-unicode`
       - `lint-reuse`
       - `lint-tidy`
       - `spec`
   - `Block force pushes`.
   - (Optional) `Require signed commits`.
8. Click **Create**.

The ruleset takes effect immediately for the default branch.

### Via the GitHub CLI

The Rulesets REST API takes a JSON body. The command below creates
the ruleset directly. Edit `OWNER` and `REPO` at the top, then run.

The bypass list uses `actor_type: "RepositoryRole"` with the magic
integer `actor_id: 5` for the Admin role.

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
  "bypass_actors": [
    {
      "actor_type": "RepositoryRole",
      "actor_id": 5,
      "bypass_mode": "always"
    }
  ],
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
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "automatic_copilot_code_review_enabled": true,
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
          { "context": "lint-reuse" },
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
from a clone using a non-admin account. With the admin bypass, the
maintainer's own clone will not see the rejection (which is the point
of the bypass). To still validate the ruleset, look at the ruleset's
**Insights** tab on github.com — it shows a log of bypass events, so
you can confirm bypasses are recorded even when permitted.

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

The recommended sequence when adding a new required job:

1. Open a PR that adds the new job to `ci.yml`.
2. Confirm the job runs and passes on that PR (still optional, not yet
   required).
3. Merge that PR.
4. Update the ruleset to add the new check name to
   `required_status_checks`.

If you add the check to the ruleset *before* the workflow PR merges,
the workflow PR itself can't merge because the required check doesn't
exist yet. Order matters.

## Disabling temporarily

For a genuine emergency where the ruleset itself is the obstacle
(e.g. a CI infrastructure outage and the admin bypass is somehow
unavailable):

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
Always re-enable as soon as the emergency passes. Note that for a
single-maintainer repo with admin bypass, full disabling is rarely
needed — the bypass already exists for the same use case.

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
