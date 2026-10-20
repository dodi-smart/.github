#!/usr/bin/env bash
# Exit 0 when the pull request promotes the integration branch, 1 otherwise.
#
#   promotion.sh <head-repo> <this-repo> <head-ref> <base-ref> <integration-branch>
#
# A promotion PR (develop into main) carries only commits that are already on
# the integration branch, and they got there through that branch's own pull
# requests, where the guard wall ran (or was report-only on purpose, for a
# bot). Walking them again fails on commits nobody can fix without rewriting
# the integration branch: one repo's promotion PR went red seven times in a
# week on two of them. The guard step walks nothing when this says yes.
#
# ALL of these must hold:
#   - the head is in this repository: a fork can name its branch `develop`
#     too, and its commits were never walked anywhere;
#   - the head ref is the integration branch, exactly;
#   - the base is a different branch;
#   - the integration branch is set. An empty value turns the rule off.
#
# The trade-off: a commit pushed straight to the integration branch with no
# pull request is not walked on promotion, so that branch has to require PRs.
set -uo pipefail

[ $# -eq 5 ] || { echo "usage: promotion.sh <head-repo> <this-repo> <head-ref> <base-ref> <integration-branch>" >&2; exit 2; }
head_repo="$1" this_repo="$2" head_ref="$3" base_ref="$4" integration="$5"

[ -n "$integration" ] || exit 1
[ -n "$head_repo" ] && [ "$head_repo" = "$this_repo" ] || exit 1
[ "$head_ref" = "$integration" ] || exit 1
[ "$base_ref" != "$head_ref" ] || exit 1
exit 0
