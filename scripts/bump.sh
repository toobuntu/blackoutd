#!/bin/sh
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Bump CFBundleShortVersionString in src/Info.plist and create a chore
# commit. Companion to `make release`, which reads the bumped version
# and creates an annotated git tag.
#
# Usage:
#   scripts/bump.sh patch | minor | major
#   scripts/bump.sh undo
#   scripts/bump.sh show
#
# Workflow:
#   scripts/bump.sh minor                # 0.2.0 -> 0.3.0; commits
#   make release                         # builds and tags v0.3.0
#   git push origin HEAD --follow-tags

set -eu

PLIST=src/Info.plist
SHORT_KEY=:CFBundleShortVersionString
BUILD_KEY=:CFBundleVersion

usage() {
    cat <<USAGE
Usage: $(basename "$0") <command>

Commands:
  patch    X.Y.Z -> X.Y.(Z+1); also bumps CFBundleVersion; commits
  minor    X.Y.Z -> X.(Y+1).0; also bumps CFBundleVersion; commits
  major    X.Y.Z -> (X+1).0.0; also bumps CFBundleVersion; commits
  undo     Revert the most recent bump commit and delete its local tag
  show     Print the current CFBundleShortVersionString
USAGE
}

die() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

read_short_version() {
    /usr/libexec/PlistBuddy -c "Print $SHORT_KEY" "$PLIST"
}

read_build_version() {
    /usr/libexec/PlistBuddy -c "Print $BUILD_KEY" "$PLIST"
}

# Returns 0 if the argument is a valid decimal integer with no leading
# zero (except the literal "0"). Refusing leading zeros sidesteps shell
# arithmetic's octal interpretation of "08", "09" etc.
is_decimal() {
    case "$1" in
    "")            return 1 ;;
    0)             return 0 ;;
    [1-9])         return 0 ;;
    [1-9]*[!0-9]*) return 1 ;;
    [1-9]*)        return 0 ;;
    *)             return 1 ;;
    esac
}

# Validates that $1 is strict semver X.Y.Z with decimal components and
# no pre-release suffix. Pre-release versions (e.g. 0.3.0-rc1) are
# refused — bump's increment semantics on those are ambiguous; edit
# Info.plist by hand if needed.
validate_semver() {
    _v=$1
    case "$_v" in
    *[!0-9.]*) die "version \"$_v\" contains invalid character (digits and periods only)" ;;
    .*)        die "version \"$_v\" starts with a period" ;;
    *.)        die "version \"$_v\" ends with a period" ;;
    *..*)      die "version \"$_v\" has consecutive periods" ;;
    esac
    IFS=. read -r _vmaj _vmin _vpat _vrest <<EOF
$_v
EOF
    [ -z "${_vrest:-}" ] || die "version \"$_v\" has more than 3 components"
    [ -n "${_vmaj:-}" ] && [ -n "${_vmin:-}" ] && [ -n "${_vpat:-}" ] \
        || die "version \"$_v\" has fewer than 3 components"
    for _vc in "$_vmaj" "$_vmin" "$_vpat"; do
        is_decimal "$_vc" || die "invalid integer \"$_vc\" in version \"$_v\""
    done
}

# Prints the next semver version on stdout. Runs in a subshell so
# variable assignments do not leak.
next_version() (
    _cur=$1
    _bump=$2
    IFS=. read -r _maj _min _pat <<EOF
$_cur
EOF
    case "$_bump" in
    patch) printf '%s.%s.%s\n' "$_maj" "$_min" $((_pat + 1)) ;;
    minor) printf '%s.%s.0\n'  "$_maj" $((_min + 1)) ;;
    major) printf '%s.0.0\n'   $((_maj + 1)) ;;
    *)     printf 'invalid bump type: %s\n' "$_bump" >&2; exit 1 ;;
    esac
)

require_clean_tree() {
    if [ -n "$(git status --porcelain)" ]; then
        die "working tree is not clean; commit or stash before bumping"
    fi
}

require_branch_not_main() {
    _branch=$(git branch --show-current)
    if [ "$_branch" = "main" ]; then
        die "refusing to bump on main; create a feature branch first (e.g. chore/bump-version)"
    fi
}

cmd_show() {
    read_short_version
}

cmd_bump() {
    _bump_type=$1
    require_clean_tree
    require_branch_not_main

    _cur=$(read_short_version)
    validate_semver "$_cur"
    _new=$(next_version "$_cur" "$_bump_type")

    _cur_build=$(read_build_version)
    is_decimal "$_cur_build" || die "CFBundleVersion \"$_cur_build\" is not a decimal integer"
    _new_build=$((_cur_build + 1))

    /usr/libexec/PlistBuddy -c "Set $SHORT_KEY $_new" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set $BUILD_KEY $_new_build" "$PLIST"

    git add "$PLIST"
    git commit --message="chore: bump version to $_new"

    printf '\nBumped %s -> %s (build %s -> %s)\n' "$_cur" "$_new" "$_cur_build" "$_new_build"
    printf '\nNext steps:\n'
    printf '  make release                         # tag v%s and build\n' "$_new"
    printf '  git push origin HEAD --follow-tags   # push branch and tag\n'
}

cmd_undo() {
    require_clean_tree

    _subject=$(git log --max-count=1 --pretty=%s)
    case "$_subject" in
    'chore: bump version to '*) ;;
    *) die "HEAD is not a bump commit (subject: $_subject)" ;;
    esac

    _files=$(git diff-tree --no-commit-id --name-only -r HEAD)
    if [ "$_files" != "$PLIST" ]; then
        printf 'error: HEAD modifies more than %s; refusing\n' "$PLIST" >&2
        printf '%s\n' "$_files" | sed 's/^/  /' >&2
        exit 1
    fi

    _cur=$(read_short_version)
    if git rev-parse --verify --quiet "v$_cur" >/dev/null; then
        if [ "$(git rev-parse "v$_cur")" = "$(git rev-parse HEAD)" ]; then
            git tag --delete "v$_cur"
            printf 'Deleted local tag v%s\n' "$_cur"
        else
            printf 'warning: tag v%s exists but does not point at HEAD; not deleting\n' "$_cur" >&2
        fi
    fi

    git reset --soft HEAD~1
    git checkout HEAD -- "$PLIST"
    printf 'Reverted bump commit; working tree is clean.\n'
}

main() {
    [ -f "$PLIST" ] || die "$PLIST not found; run from the repo root"
    [ $# -ge 1 ] || { usage >&2; exit 1; }
    case "$1" in
    patch|minor|major) cmd_bump "$1" ;;
    undo)              cmd_undo ;;
    show)              cmd_show ;;
    -h|--help|help)    usage ;;
    *)                 usage >&2; exit 1 ;;
    esac
}

main "$@"
