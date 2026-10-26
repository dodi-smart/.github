#!/usr/bin/env bash
# Write the files this run changed into <out>, one per line, and print what
# the checks step needs as lines for $GITHUB_OUTPUT.
#
#   scope.sh <event> <base> <head> <out>   ->   scoped=true|false
#                                              changed=<n>   (scoped runs only)
#
# A decision's checks prove it still holds after its guarded code changed, and
# a spec's after its paths changed. So a pull request verifies the records its
# diff touches, base...head, and a push the commits it added, before..head. A
# dependency bump that touches no guarded path runs nothing, and installs no
# toolchain for nothing. The repo's test job, not this one, runs the suites.
#
# Anything else falls back to scoped=false, which verifies every record: a
# manual or scheduled run, the zero sha of a newly pushed branch, or a base the
# checkout cannot see (shallow history). Unscoped is slower, never wrong.
set -uo pipefail

[ $# -eq 4 ] || { echo "usage: scope.sh <event> <base> <head> <out>" >&2; exit 2; }
event=$1 base=$2 head=$3 out=$4
: > "$out"

unscoped() { echo "scoped=false"; exit 0; }

case "$event" in
  pull_request|pull_request_target|merge_group) range="$base...$head" ;;
  push) range="$base..$head" ;;
  *) unscoped ;;
esac
case "$base" in ''|*[!0]*) ;; *) unscoped ;; esac   # empty passes on, all zeros stops
[ -n "$base" ] || unscoped
git cat-file -e "$base^{commit}" 2>/dev/null || unscoped
git cat-file -e "$head^{commit}" 2>/dev/null || unscoped

# --no-renames lists both sides of a rename, so moving a guarded file away
# still verifies the decision that guarded it.
git diff --name-only --no-renames "$range" > "$out" 2>/dev/null || { : > "$out"; unscoped; }
echo "scoped=true"
echo "changed=$(wc -l < "$out" | tr -d ' ')"
