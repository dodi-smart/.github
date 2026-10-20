#!/usr/bin/env bash
# What a release's canary said, and what promotion does about it (AGENTS.md has
# the reasoning).
#
#   canary-gate.sh state  <sha>    print the newest `release-canary` state on <sha>
#   canary-gate.sh auto   <sha>    exit 0 only when that state is `success`
#   canary-gate.sh manual <sha>    always exit 0, but warn unless it is `success`
#
# `state` prints success | failure | error | pending | none | unreadable. `none`
# is no status at all; `unreadable` is an API error. Stdout is one line saying
# why; warnings go to stderr as annotations. Needs gh, jq, GH_TOKEN and
# GITHUB_REPOSITORY. Tests: scripts/canary-gate.test.sh, with a stubbed `gh`.
set -euo pipefail

usage() { sed -n '2,/^set -e/p' "$0" | sed '$d;s/^# \{0,1\}//' >&2; exit 2; }

mode="${1:-}"
sha="${2:-}"
case "$mode" in state|auto|manual) ;; *) usage ;; esac
[ -n "$sha" ] || usage
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"

# The list is newest first, and a rerun posts a new status, so the first match
# is the latest word.
state="unreadable" url=""
if raw="$(gh api "repos/$repo/commits/$sha/statuses?per_page=100" 2>/dev/null)" \
   && row="$(jq -r '[.[] | select(.context == "release-canary")][0] | if . == null then "none\t" else "\(.state)\t\(.target_url // "")" end' <<<"$raw" 2>/dev/null)"; then
  state="${row%%$'\t'*}"
  url="${row#*$'\t'}"
fi

if [ "$mode" = state ]; then
  echo "$state"
  exit 0
fi

why="the release canary is $state on ${sha:0:12}${url:+ ($url)}"
case "$state" in
  none)       why="no release canary result on ${sha:0:12}" ;;
  unreadable) why="the release canary result on ${sha:0:12} could not be read" ;;
esac

if [ "$state" = success ]; then
  echo "$why"
elif [ "$mode" = auto ]; then
  echo "::warning title=Promotion held::$why. Only a passing canary lets an automatic promotion through." >&2
  echo "held: $why"
  exit 1
else
  echo "::warning title=Promoting without a passing canary::$why." >&2
  echo "$why (promoted by hand anyway)"
fi
