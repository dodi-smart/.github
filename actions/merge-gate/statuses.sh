#!/usr/bin/env bash
# The one reader of a commit's statuses that the automation trusts. merge-gate,
# the fix loop (actions/factory) and actions/request-review all call it, so
# "which status counts" is decided in one place.
#
#   statuses.sh read REPO SHA        -> the commit's statuses as a JSON array of
#                                       {context, state, creator, id}; [] when
#                                       they cannot be read
#   statuses.sh app CONTEXT LOGIN    -> (statuses on stdin) the state of the
#                                       newest status LOGIN posted for CONTEXT,
#                                       or nothing
#
# The statuses list names each status's creator; the combined /status does not.
# GitHub's ids grow with time, so the highest id is the newest whatever the list
# order. An empty LOGIN counts nothing: with no App login no status is trusted.
set -euo pipefail

case "${1:-}" in
  read)
    out=$(gh api "/repos/$2/commits/$3/statuses?per_page=100" --paginate \
            --jq '.[] | {context, state, creator: .creator.login, id}' 2>/dev/null | jq -cs . 2>/dev/null) || out='[]'
    printf '%s\n' "${out:-[]}" ;;
  app)
    # shellcheck disable=SC2016
    jq -r --arg c "$2" --arg by "${3:-}" \
      'map(select($by != "" and .context == $c and .creator == $by)) | max_by(.id) | .state // empty' ;;
  *) echo "usage: statuses.sh read REPO SHA | app CONTEXT LOGIN" >&2; exit 2 ;;
esac
