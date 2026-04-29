---
name: review-pr
description: Fetch the latest pull request review state from GitHub and summarize action items — overall mergeability, reviewer decisions, inline review comments grouped by file:line, and failing CI checks. Pure-read, no modifications. Use when the maintainer asks "what's the state of this PR" or wants a triage snapshot before addressing reviews.
---

<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

Fetch and summarize the current state of a pull request. Default to
the PR for the current branch; if the maintainer provides an argument,
treat it as the PR number.

`gh pr view --json reviews,comments` returns review-summary objects
and issue-style PR comments — but NOT the inline review-thread
comments that have file:line references. Inline review comments come
from the separate REST endpoint
`/repos/{owner}/{repo}/pulls/{N}/comments`. Both are needed for a
complete picture.

Steps:

1. Determine the PR number:
   - With no argument: `gh pr view --json number --jq .number`
   - With an argument: use `$ARGUMENTS` directly.
2. Fetch the high-level PR state and reviewer decisions:
   ```sh
   gh pr view <N> --json number,state,mergeable,reviews,comments,statusCheckRollup
   ```
3. Fetch inline review comments with file:line refs:
   ```sh
   gh api "/repos/{owner}/{repo}/pulls/<N>/comments" --paginate
   ```
   Substitute `{owner}/{repo}` with the values from
   `gh repo view --json nameWithOwner --jq .nameWithOwner`.

Output:

- One-line PR state (open/merged/closed, mergeable, CI status).
- Reviewers and their overall decisions (APPROVED, CHANGES_REQUESTED,
  COMMENTED) from step 2's `reviews` array.
- Inline review comments from step 3's response, grouped by reviewer
  (`user.login`), each with `path`, `line` (or `original_line`), and
  the first ~100 chars of `body`. Mark threads with
  `in_reply_to_id == null` as top-of-thread.
- Issue-style PR comments from step 2's `comments` array (these have
  no file:line — list them separately as "general comments").
- Failing CI checks from step 2's `statusCheckRollup`, if any.

Do NOT propose code changes.
Do NOT modify any files.
Do NOT push commits.

The goal is a status snapshot the maintainer uses to decide what to
address.
