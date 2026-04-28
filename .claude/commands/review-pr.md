---
description: Fetch latest PR review state and summarize action items
---

Fetch and summarize the current state of a pull request. Default to the
PR for the current branch; if I provide an argument, treat it as the PR
number.

Steps:

1. If no argument: `gh pr view --json number,state,reviews,comments,statusCheckRollup`
2. If argument: `gh pr view $ARGUMENTS --json number,state,reviews,comments,statusCheckRollup`

Output:

- One-line PR state (open/merged/closed, mergeable, CI status)
- Reviewers and their decisions (APPROVED, CHANGES_REQUESTED, COMMENTED)
- Unresolved review comments grouped by reviewer, with file:line refs
- Failing CI checks, if any

Do NOT propose code changes.
Do NOT modify any files.
Do NOT push commits.

The goal is a status snapshot I can use to decide what to address.
