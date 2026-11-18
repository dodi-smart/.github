#!/usr/bin/env bash
# Remove an `agent:*` request label from one or more issues or pull requests.
#
# A request label is a REQUEST, never a record: it comes off on every stop, so
# applying it again emits a fresh `labeled` event and asks for another pass.
# GitHub emits no `labeled` event for a label already present, so a removal
# that silently failed is a request that can never be made again. That is why
# the three outcomes are told apart:
#
#   removed    the label came off.
#   404        the label was not on the item (already cleared, or never
#              applied). Nothing to do, and nothing to warn about.
#   any other  a 403, a 5xx, a bad token. The label is still on, so the
#              request stays on, and the run says so with a ::warning.
#
# It never fails the step: it runs in clean-up steps under `always()`, and a
# clean-up that turns a refusal red hides the refusal's own message.
#
# Env: LABEL, NUMBER (one or more numbers, whitespace-separated), REPO
# (owner/name), GH_TOKEN. Writes `kept`, the numbers that still carry it. Also called directly by actions/judge-verdict, whose
# sweep clears many pull requests from inside a loop.
set -uo pipefail

# The colon in `agent:review` and any space or slash in a label are part of
# the name, not the path, so the name goes out as one percent-encoded segment.
enc=$(jq -rn --arg l "$LABEL" '$l|@uri')

# Split on whitespace only: a stray `*` must not expand to file names.
set -f
kept=''
for n in ${NUMBER:-}; do
  case "$n" in
    ''|*[!0-9]*)
      echo "::warning title=$LABEL not removed::'$n' is not an issue or pull request number"
      continue ;;
  esac
  if err=$(gh api -X DELETE "/repos/$REPO/issues/$n/labels/$enc" 2>&1 >/dev/null); then
    echo "removed $LABEL from #$n; apply it again to request another pass"
  elif grep -q 'HTTP 404' <<<"$err"; then
    echo "$LABEL was not on #$n"
  else
    err=$(tr '\n' ' ' <<<"$err")
    kept+="${kept:+ }$n"
    echo "::warning title=$LABEL not removed::#$n keeps $LABEL, so the request stays on and applying it again starts nothing. Remove it by hand before asking again. ${err:-no reason given}"
  fi
done
# For a caller that re-adds the label next (a relay): a label still on emits no
# `labeled` event, so it must not count on one for these.
[ -z "${GITHUB_OUTPUT:-}" ] || echo "kept=$kept" >> "$GITHUB_OUTPUT"
exit 0
