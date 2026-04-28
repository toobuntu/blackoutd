<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Claude Code isolation: assessment of common patterns

This document evaluates two patterns commonly recommended for "agent
sandboxing" — git worktrees and APFS snapshots — against blackoutd's
actual development workflow. The conclusion: worktrees are useful when
you need parallel work on different branches; APFS snapshots are not
the right tool for this purpose. Neither provides genuine capability
isolation.

---

## What "isolation" can and cannot mean for Claude Code

Claude Code runs as your user on your Mac. It has the same file system
access, network access, and process privileges that you have. There is
no kernel-level sandbox around it the way there is around an iOS app
or a Docker container.

Three things can be controlled:

1. **Workspace separation** — what working tree the agent sees and
   modifies.
2. **Capability filtering** — which commands the agent is allowed to
   propose (Claude Code's `permissions.allow`/`ask`/`deny`).
3. **Output review** — whether you read each diff before approving.

Worktrees and snapshots address (1) only. The serious controls are (2)
and (3), and those are already configured for blackoutd in
`.claude/settings.json`. Treat this document as a workspace-management
discussion, not a security one.

---

## Git worktrees: useful for parallel work, not for isolation

### What they are

`git worktree add` creates a second working tree backed by the same
`.git` directory. Both working trees share branches, history, hooks,
and config; only the checked-out files differ. A worktree on branch
`ai/2026-04-28-153012` and the main working tree on
`copilot/prepare-for-v0-2-0` can coexist on disk and be edited
independently.

### When they help

- You want Claude Code to work on an experimental refactor while you
  continue editing the v0.2 PR branch in your main checkout.
- You want to run two Claude Code sessions concurrently against the
  same repo, each on its own branch.
- You want the agent's commits and uncommitted edits to be physically
  separate from your own working tree, reducing the chance of
  accidentally staging the agent's work into your commit.

### What they do NOT do

- They do not protect against `rm -rf ~/important`. The agent has the
  same file system access from a worktree as from the main checkout.
- They do not protect against `git push --force` to a shared remote
  (already in `permissions.deny`, but the worktree is irrelevant to
  that protection).
- They do not isolate environment variables, network access, or
  long-running processes.
- A `git push` from the worktree pushes to the same remote your main
  checkout pushes to. Removing the remote from the worktree
  (`git remote remove origin`) is a possibility but creates surprises:
  Claude Code may try `gh pr create` and get a confusing error.

### Recommendation

**Adopt worktrees only when you have a concrete reason to do parallel
work.** For day-to-day single-task Claude Code sessions, a plain
`cd ~/devel/claude/desktop/blackoutd && claude` is simpler and adds no
new failure modes (e.g., forgotten worktrees, abandoned branches).

For blackoutd specifically, the v0.3 work (Mach IPC) is a single
focused task. Do not introduce worktrees for it. They will become
useful if v0.3 and v0.4 development overlap.

### Setup, when you do want them

The helper from ChatGPT is reasonable; here is a slightly tightened
version. Keep this in your shell profile (`~/.zshrc` or
`~/.config/ksh/kshrc`) — it is not part of the blackoutd repo.

```sh
aiwt() {
  set -e
  repo_name=$(basename "$PWD")
  ts=$(date +%Y%m%d-%H%M%S)
  sandbox_dir="../_sandboxes/${repo_name}-ai-${ts}"
  branch="ai/${ts}"
  mkdir -p ../_sandboxes
  git worktree add -b "$branch" "$sandbox_dir" HEAD
  printf 'Worktree: %s\nBranch:   %s\n' "$sandbox_dir" "$branch"
}
```

The differences from ChatGPT's version: `set -e` so a failed
`git worktree add` does not silently leave the user in an inconsistent
state, explicit `mkdir -p ../_sandboxes` so the first invocation
succeeds, and clearer output so it is obvious what was created.

### Workflow

```sh
# Start a worktree session:
cd ~/devel/claude/desktop/blackoutd
aiwt
# → Worktree: ../_sandboxes/blackoutd-ai-20260428-153012
# → Branch:   ai/20260428-153012

# Open Claude Code in the worktree:
cd ../_sandboxes/blackoutd-ai-20260428-153012
claude

# (work happens; Claude Code makes commits on ai/20260428-153012)

# When the experiment is good, integrate:
cd ~/devel/claude/desktop/blackoutd     # back to main checkout
git fetch . ai/20260428-153012:ai/20260428-153012   # bring branch over
# Open a PR from ai/20260428-153012 the normal way, OR cherry-pick:
git cherry-pick <sha>..<sha>

# Tear down:
git worktree remove ../_sandboxes/blackoutd-ai-20260428-153012
git branch -D ai/20260428-153012   # only after merging or discarding
```

### Caveats

- **Worktrees share `.git`**. Commits made in the worktree are visible
  to `git log` in the main checkout (after a `git fetch .` or by
  inspecting the worktree's branch directly). This is a feature, not
  a bug — it is how you integrate the work — but a mental model of
  "completely isolated copy" is wrong.
- **Pre-commit hook applies in worktrees.** The hook is in
  `.githooks/pre-commit` and `core.hooksPath` is repo-wide config, so
  the hook runs in both the main checkout and any worktree. This is
  the correct behaviour — the hook should run on every commit
  regardless of where it originates.
- **Ruby gems and build artifacts are NOT shared.** Each worktree
  needs its own `bundle install` and its own `make` to populate
  `vendor/bundle` and `build/`. Trivial cost, but worth knowing.
- **Forgotten worktrees accumulate.** If you frequently use `aiwt` and
  rarely `git worktree remove`, the `_sandboxes` directory grows
  without bound. Periodic cleanup:
  ```sh
  git worktree list                       # see what is registered
  git worktree prune                      # remove stale entries whose dirs are gone
  ```

### Should you remove the remote inside the sandbox?

ChatGPT raises the question. The honest answer: **no, because it
breaks `gh` commands**, and the protection is illusory. Claude Code
already cannot push to the real remote — `git push:*` is in
`permissions.deny` in `.claude/settings.json`. Removing the remote
on top of that adds nothing except confusing failure modes.

If you want stronger isolation, use a fresh clone instead of a
worktree:

```sh
mkdir -p ~/devel/claude/sandbox
cd ~/devel/claude/sandbox
git clone ~/devel/claude/desktop/blackoutd blackoutd-fresh
cd blackoutd-fresh
git remote set-url origin ~/devel/claude/desktop/blackoutd  # local-only "remote"
```

The clone has its own `.git`, its own object database, its own remote
pointing only to your local copy. Pushes go to your local copy, not
to GitHub. The cost is full duplication of history (small for
blackoutd) and a slightly more complex integration step (`git push`
to local, then push from local to GitHub). For most work this is
overkill.

---

## APFS snapshots: not the right tool for this

### What they are

APFS supports volume-level snapshots — copy-on-write checkpoints of
the entire boot volume. Time Machine creates them automatically. You
can create them manually:

```sh
tmutil localsnapshot                        # create
tmutil listlocalsnapshots /                  # list
```

A snapshot is a point-in-time view of the *entire volume*, not a
specific directory.

### Why they look attractive

A casual reading suggests snapshots are a free undo button: snapshot
before agent work, roll back if it goes wrong. This is the wrong
mental model.

### Why they are wrong-fit for Claude Code work

1. **Granularity.** A snapshot is volume-wide. Rolling back to undo
   what Claude Code did to `~/devel/claude/desktop/blackoutd` would
   also roll back every other file you touched in that interval —
   email, downloads, browser history, work in other repos, system
   updates. There is no "restore just this directory" operation
   built on snapshots.

2. **Restoration is heavy.** To restore a snapshot you typically boot
   into Recovery Mode and use Disk Utility to revert the volume. This
   is not a per-file operation; it is a replace-the-whole-volume
   operation.

3. **Git already does this better.** Git is a versioning system
   designed for exactly the granularity you want: per-file, per-commit,
   per-branch. `git stash`, `git restore`, `git reflog`, and branch
   creation cover every "I want to undo this" scenario at zero cost
   and full granularity.

4. **For non-git artefacts** (build/, install state, NSUserDefaults),
   the right tools are `make clean`, `make uninstall`, and
   `defaults delete blackoutd`. Snapshots would over-restore these
   and bring back files unrelated to your experiment.

### When snapshots ARE useful

- Before a major macOS update, in case the update breaks something
  system-wide. (Time Machine does this automatically.)
- Before installing system-modifying software (kernel extensions,
  privileged helpers). Not relevant to blackoutd; the blackoutd
  daemon is a user-level LaunchAgent.

### Recommendation

**Do not use APFS snapshots as part of the Claude Code workflow.**
Use git: branches are free, commits are free, and the granularity
matches the actual unit of work.

If you genuinely want a "rewind point" for a Claude Code session
that does not yet have a clean commit, use `git stash --include-untracked`:

```sh
git stash push --include-untracked --message "before-claude-experiment"
# ... let Claude Code work ...
# To rewind:
git stash pop  # or: git stash drop, then start over
```

---

## Summary

| Pattern             | Use it when                                               | Use git instead when               |
|---------------------|-----------------------------------------------------------|------------------------------------|
| Worktree (`aiwt`)   | You want parallel work on different branches              | You only have one task at a time   |
| Fresh clone         | You want true workspace separation, accept duplication    | A worktree's shared `.git` is fine |
| APFS snapshot       | Before major OS update or kernel-level install            | (almost always)                    |
| `git stash`         | Quick rewind point in active session                      | (rarely worse)                     |
| `git branch`        | The default unit of work; cheap, granular, integrable     | (rarely worse)                     |

The capability filtering in `.claude/settings.json` and the merge-PR
ruleset on `main` (see `docs/branch-protection.md`) are the
load-bearing protections. Workspace tricks are convenience, not
safety.
