#!/usr/bin/env bash
# Remove a request label on every labelled run, served or not.
#
# A request label is a REQUEST, never a record, and GitHub emits no `labeled`
# event for a label already present. A clear that lives in the job the gate
# starts misses every refused, skipped or cancelled request, and the label then
# swallows the next request. This runs from a separate `always()` job instead.
#
# One owner per request, so neither workflow strips the label while the other
# is still serving it: a person's request on a dependency bot's PR is
# deps-verify's (pr-review's gate skips it), every other request is
# pr-review's. Both logins are classified by agent-gate's `gate.sh kind`, where
# the bot list lives.
#
# Only a 404 (already gone) is silent. Any other failure is a ::warning, never
# a failed step: the label stays on and the run says so.
#
# Env: OWNER, LABEL, PR, AUTHOR, SENDER, REPO, GH_TOKEN.
set -euo pipefail

kind="$(dirname "${BASH_SOURCE[0]}")/../agent-gate/gate.sh"
deps=false
if [ "$("$kind" kind "$AUTHOR")" = dependency ] && [ "$("$kind" kind "$SENDER")" = human ]; then
  deps=true
fi
case "$OWNER:$deps" in
  pr-review:true)    echo "deps-verify serves and clears this request"; exit 0 ;;
  deps-verify:false) echo "pr-review serves and clears this request"; exit 0 ;;
  pr-review:false|deps-verify:true) ;;
  *) echo "::warning title=$LABEL not removed::unknown owner '$OWNER'"; exit 0 ;;
esac

enc=$(jq -rn --arg l "$LABEL" '$l|@uri')
if err="$(gh api -X DELETE "/repos/$REPO/issues/$PR/labels/$enc" --silent 2>&1)"; then
  echo "removed $LABEL, apply it again to request another pass"
elif grep -q 'HTTP 404' <<<"$err"; then
  echo "$LABEL was not on this PR"
else
  echo "::warning title=$LABEL not removed::#$PR keeps $LABEL, so applying it again starts nothing until someone removes it: ${err//$'\n'/ }"
fi
