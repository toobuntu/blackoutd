#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# rewrite-pr-as-merge-commit.sh — v3
#
# Converts a "rebase and merge" PR into a true merge commit,
# preserving the original per-commit dates and authorship.
#
# The script rewrites the base branch by resetting it to the
# merge-base, then replaying the PR commits as a merge commit.
#
# requirements:
#   gh CLI
#   jq
#   git (with push access to repo)
#   gpg (optional; signing is skipped if no key is configured)
#

set -euo pipefail

PR=
BASE_BRANCH=
HEAD_BRANCH=
HEAD_SHA=
TITLE=
RECREATE_BRANCH=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--recreate-branch] <pr-number>

  --recreate-branch  Reconstruct the PR branch from its HEAD SHA
                     if the remote branch has already been deleted.
EOF
  exit 1
}

parse_args() {
  if [[ "${1:-}" == "--recreate-branch" ]]; then
    RECREATE_BRANCH=1
    shift
  fi

  [[ $# -eq 1 ]] || usage
  PR="$1"
}

fetch_pr_json() {
  gh pr view "$PR" \
    --json number,title,baseRefName,headRefName,headRefOid,commits
}

parse_pr_json() {
  local json="$1"
  BASE_BRANCH=$(jq --raw-output '.baseRefName' <<<"$json")
  HEAD_BRANCH=$(jq --raw-output '.headRefName'  <<<"$json")
  HEAD_SHA=$(jq --raw-output    '.headRefOid'   <<<"$json")
  TITLE=$(jq --raw-output       '.title'        <<<"$json")
}

fetch_refs() {
  git fetch origin "$BASE_BRANCH" || true
  git fetch origin "$HEAD_BRANCH" || true
}

branch_exists_remotely() {
  git show-ref \
    --verify \
    --quiet \
    "refs/remotes/origin/$HEAD_BRANCH"
}

#
# If the PR branch was deleted after merging, optionally recreate a
# local branch pointing at the recorded HEAD SHA so the merge can
# proceed.  The SHA must already be reachable in the local object
# store (fetch_refs will have pulled it via the base branch fetch if
# it is an ancestor, but a force-push or GC may have made it
# unreachable — warn in that case).
#
recreate_branch_if_needed() {
  if branch_exists_remotely; then
    return
  fi

  if [[ "$RECREATE_BRANCH" -ne 1 ]]; then
    echo "ERROR: PR branch '$HEAD_BRANCH' no longer exists on origin." >&2
    echo "       Rerun with --recreate-branch to reconstruct it from" >&2
    echo "       the recorded HEAD SHA ($HEAD_SHA)." >&2
    exit 1
  fi

  if ! git cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null; then
    echo "ERROR: HEAD SHA $HEAD_SHA is not reachable in the local" >&2
    echo "       object store.  Run 'git fetch --all' and retry." >&2
    exit 1
  fi

  HEAD_BRANCH="reconstructed-pr-$PR"
  echo "Reconstructing local branch '$HEAD_BRANCH' at $HEAD_SHA..."
  git branch "$HEAD_BRANCH" "$HEAD_SHA"
}

#
# Verify the base branch has not already been converted by checking
# whether HEAD_SHA appears as a parent of any merge commit reachable
# from it.
#
detect_already_converted() {
  echo "Checking whether PR #$PR is already a merge commit..."

  if git log \
       --merges \
       --format="%P" \
       "origin/${BASE_BRANCH}" \
     | grep --quiet "$HEAD_SHA"; then
    echo "PR #$PR is already represented as a merge commit." >&2
    echo "Nothing to do." >&2
    exit 0
  fi

  echo "Rebase-merge history detected — proceeding."
}

signing_flag() {
  local key
  key=$(git config --get user.signingkey 2>/dev/null || true)
  if [[ -n "$key" ]]; then
    echo "-S"
  else
    echo ""
  fi
}

compute_merge_base() {
  git merge-base "origin/$BASE_BRANCH" "$HEAD_SHA"
}

confirm_destructive_operation() {
  local merge_base="$1"

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  WARNING — history rewrite"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  echo "  Branch : $BASE_BRANCH"
  echo "  Reset to: $merge_base"
  echo
  echo "  '$BASE_BRANCH' will be reset to the merge-base and"
  echo "  force-pushed.  Anyone with a local checkout must run:"
  echo
  echo "    git fetch origin"
  echo "    git checkout $BASE_BRANCH"
  echo "    git reset --hard origin/$BASE_BRANCH"
  echo
  echo "  Unpushed local commits on '$BASE_BRANCH' WILL BE LOST"
  echo "  unless saved first (e.g. git branch backup/my-work)."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  printf "Proceed? [y/N] "
  read -r reply
  [[ "$reply" == [yY] ]] || { echo "Aborted."; exit 1; }
}

backup_branch() {
  local backup="backup/pre-rewrite-${PR}-$(date +%Y%m%d-%H%M%S)"
  git branch "$backup"
  echo "Backup created: $backup"
}

rewrite_base_branch() {
  local merge_base
  merge_base=$(compute_merge_base)

  confirm_destructive_operation "$merge_base"

  echo "Checking out '$BASE_BRANCH' and resetting to merge-base..."
  git checkout "$BASE_BRANCH"
  backup_branch

  git reset --hard "$merge_base"

  git push \
    --force-with-lease \
    origin \
    "$BASE_BRANCH"
}

merge_pr_branch() {
  local flag
  flag=$(signing_flag)

  local signing_label="${flag:+yes}"
  echo "Creating merge commit (signing: ${signing_label:-no})..."

  # word-splitting of $flag is intentional when non-empty
  # shellcheck disable=SC2086
  git merge \
    --no-ff \
    $flag \
    "$HEAD_SHA" \
    --message "Merge PR #$PR: $TITLE"

  git push origin "$BASE_BRANCH"
}

main() {
  parse_args "$@"

  echo "Fetching PR #$PR metadata..."
  local pr_json
  pr_json=$(fetch_pr_json)

  parse_pr_json "$pr_json"

  echo "PR #$PR — $TITLE"
  echo "  base : $BASE_BRANCH"
  echo "  head : $HEAD_BRANCH ($HEAD_SHA)"
  echo

  fetch_refs
  recreate_branch_if_needed
  detect_already_converted
  rewrite_base_branch
  merge_pr_branch

  echo
  echo "Done. PR #$PR is now represented as a merge commit on '$BASE_BRANCH'."
  echo
}

main "$@"
