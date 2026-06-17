<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Claude Code isolation: assessment of common patterns

This document evaluates two patterns commonly recommended for "agent
sandboxing" — git worktrees and APFS snapshots — against blackoutd's
actual development workflow. Worktrees are useful when you need
parallel work on different branches; APFS snapshots are not the right
tool for this purpose. Neither provides genuine *capability* isolation
on its own; the load-bearing protections are the permission rules and
sandbox in `.claude/settings.json`. Workspace patterns layer on top.

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
   propose (Claude Code's `permissions.allow`/`ask`/`deny`, plus the
   Seatbelt sandbox).
3. **Output review** — whether you read each diff before approving.

Worktrees and snapshots address (1). The serious controls are (2) and
(3), and those are configured in `.claude/settings.json`. Combining (1)
with (2) is defense in depth: a workspace pattern that restricts the
remote URLs reachable from a clone makes the permission `deny` rules
on `git push` redundant rather than load-bearing.

---

## Git worktrees: useful for parallel work, not for capability isolation

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
  (already in `permissions.deny`, but the worktree does not change
  that protection).
- They do not isolate environment variables, network access, or
  long-running processes.
- A `git push` from the worktree pushes to the same remote your main
  checkout pushes to.

### Recommendation

**Adopt worktrees only when you have a concrete reason to do parallel
work.** For day-to-day single-task Claude Code sessions, a plain
`cd <repo-root> && claude` is simpler and adds no
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
cd <repo-root>
aiwt
# → Worktree: ../_sandboxes/blackoutd-ai-20260428-153012
# → Branch:   ai/20260428-153012

# Open Claude Code in the worktree:
cd ../_sandboxes/blackoutd-ai-20260428-153012
claude

# (work happens; Claude Code makes commits on ai/20260428-153012)

# When the experiment is good, integrate. Worktrees share .git, so the
# branch is already visible from the main checkout — no fetch needed.
cd <repo-root>
# Open a PR from ai/20260428-153012 the normal way, OR cherry-pick:
git cherry-pick <sha>..<sha>

# Tear down:
git worktree remove ../_sandboxes/blackoutd-ai-20260428-153012
git branch -d ai/20260428-153012   # only after merging or discarding
```

### Caveats

- **Worktrees share `.git`**. Commits made in the worktree are visible
  to `git log` in the main checkout immediately, with no fetch
  required. This is a feature, not a bug — it is how you integrate
  the work — but a mental model of "completely isolated copy" is
  wrong.
- **Pre-commit hook applies in worktrees.** The hook is in
  `.githooks/pre-commit` and `core.hooksPath` is repo-wide config, so
  the hook runs in both the main checkout and any worktree. This is
  the correct behavior — the hook should run on every commit
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

---

## Fresh clones: stronger workspace isolation

For work that must not touch the primary repository — large
experiments, dependency upgrades you might abandon, anything you'd
rather walk away from cleanly — a fresh clone in `~/devel/claude/sandbox/`
is stronger than a worktree. The clone has its own `.git` directory,
its own object database, and its own remote configuration. Two
patterns are useful, with different tradeoffs:

### Option A: keep `origin` pointed at GitHub, add a second `local` remote

Pushes still default to `origin` (GitHub), but you have a deliberate
named target for sandbox work. `gh` commands continue to work because
`origin` still identifies the GitHub repo. Use this when you want
isolation from your primary checkout but still want to be able to
inspect PR state, fetch upstream changes, etc., from inside the
sandbox.

```sh
mkdir -p ~/devel/claude/sandbox
cd ~/devel/claude/sandbox
git clone <repo-root> blackoutd-fresh
cd blackoutd-fresh
git remote add local <repo-root>
git remote -v
# origin   git@github.com:toobuntu/blackoutd.git (fetch/push)
# local    <repo-root> (fetch/push)

# Sandbox-only push (cannot reach GitHub):
git push local <branch>
# Real push (reaches GitHub if permissions allow):
git push origin <branch>
```

The `git push:*` permission deny in `.claude/settings.json` still
applies, so Claude Code cannot push to either remote without the
maintainer running the command directly.

### Option B: repoint `origin` to the local path (maximum sandbox)

Use this when the agent should have **no path to GitHub at all** from
inside the sandbox. `origin` itself points at your primary working
copy, so even if Claude Code somehow circumvented the `git push`
permission deny, the most it could do is push to your local repo —
not to the public origin on GitHub. `gh` commands are intentionally
broken in this clone because the configured `origin` is not a GitHub
URL.

```sh
mkdir -p ~/devel/claude/sandbox
cd ~/devel/claude/sandbox
git clone <repo-root> blackoutd-fresh
cd blackoutd-fresh
git remote set-url origin <repo-root>
git remote -v
# origin   <repo-root> (fetch/push)

# Any push goes only to your local repo; GitHub is unreachable from this clone.
git push origin <branch>
# Then, from your primary checkout, push to GitHub if/when ready:
cd <repo-root>
git push origin <branch>
```

The cost of Option B is that `gh pr view`, `gh pr create`, etc. fail
inside the sandbox (no GitHub remote to consult). For some workflows
that's a deliberate feature: if the agent cannot fabricate a PR or
pull review state, all PR-flow work happens in your primary checkout
where you have full visibility.

### Choosing between Options A and B

| Goal                                         | Use      |
|----------------------------------------------|----------|
| Isolation from primary checkout, keep `gh`   | A (second remote)  |
| Maximum sandbox; `gh` should be unreachable  | B (repointed origin) |
| Default day-to-day work                      | Neither — just `cd` and `claude` |

There is no wrong choice between A and B; it depends on whether you
want `gh` to work inside the sandbox. The original framing in some
external reviews ("never repoint origin because it breaks gh") treats
a deliberate restriction as an accident. If the goal is "Claude Code
in this clone cannot reach GitHub", Option B is exactly right.

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
   what Claude Code did to `<repo-root>` would
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

| Pattern                                | Use it when                                                                | Use a simpler option when           |
|----------------------------------------|---------------------------------------------------------------------------|-------------------------------------|
| Plain `cd` + `claude`                  | Single-task day-to-day work; permissions are the gate                     | (default)                           |
| Worktree (`aiwt`)                      | Parallel work on different branches in the same repo                      | Only one task at a time             |
| Fresh clone, second `local` remote     | Strong workspace separation, keep `gh` working                            | A worktree's shared `.git` is fine  |
| Fresh clone, repointed `origin`        | Maximum sandbox; `gh` and GitHub deliberately unreachable from the clone   | You need `gh` inside the sandbox    |
| APFS snapshot                          | Before major OS update or kernel-level install                             | (almost always)                     |
| `git stash`                            | Quick rewind point in active session                                      | (rarely worse)                      |
| `git branch`                           | The default unit of work; cheap, granular, integrable                     | (rarely worse)                      |

The capability filtering in `.claude/settings.json` and the merge-PR
ruleset on `main` (see `docs/branch-protection.md`) are the
load-bearing protections. Workspace patterns layer on top: a fresh
clone with repointed `origin` makes the `git push` deny rule
redundant rather than load-bearing, which is the right direction
for a sensitive task.
