#!/usr/bin/env bash
# Exit 0 when <sha> is a release tool's version-bump commit, 1 otherwise.
#
#   release-commit.sh <sha>
#
# The guard step skips these. semantic-release commits the bumped version file
# straight onto develop and main, and a decision that guards that file (a
# Cargo.toml, a package.json) then fails every develop-to-main promotion on a
# trailer no bot can write. Nobody on the PR can act on that, and a check that
# is red on every promotion teaches people to merge over it.
#
# BOTH halves must hold, so neither alone opens a hole:
#   - the author is a bot: a GitHub App (`name[bot]`, or its
#     `…[bot]@users.noreply.github.com` address), or `semantic-release-bot`,
#     semantic-release's committer when GIT_AUTHOR_NAME is unset;
#   - the subject is the release commit's shape: `chore(release): … [skip ci]`.
# A person's `chore(release):` commit is still checked, and so is anything else
# a bot commits (a scheduled sync can carry a trailer). Forging both is
# possible, but whoever can do that can write the trailer too: the guard wall
# is a prompt to cite a decision, not access control.
#
# The zavet CLI applies the same rule in `zavet check`. It lives here as well
# because this action runs each repo's vendored copy of the CLI, which may
# predate it.
set -uo pipefail

[ $# -eq 1 ] || { echo "usage: release-commit.sh <sha>" >&2; exit 2; }
line=$(git log -1 --format='%an%x09%ae%x09%s' "$1" -- 2>/dev/null) || exit 1
[ -n "$line" ] || exit 1
IFS=$'\t' read -r name email subject <<<"$line"

case "$name" in
  *'[bot]' | semantic-release-bot) ;;
  *) case "$email" in *'[bot]@users.noreply.github.com') ;; *) exit 1 ;; esac ;;
esac
[[ "$subject" =~ ^chore\(release\)!?:\  ]] || exit 1
case "$subject" in *'[skip ci]'*) exit 0 ;; esac
exit 1
