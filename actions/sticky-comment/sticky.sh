#!/usr/bin/env bash
# Post one comment per key, and edit it in place on every later run.
#
# claude-code-action's own sticky comment is tag-mode only, and tag mode is
# closed to both workflows that want one here. It rewrites the prompt, so a
# slash command never expands, and it sets up its own branch and push tooling,
# where deps-verify pushes only from a deterministic step that checks the
# commits first.
#
# The comment is found by a hidden marker in the body, never by author or
# position: `gh pr comment --edit-last` edits the last comment by the token,
# which is the wrong one as soon as anything else comments in between.
#
# With DELETE=true it removes that comment instead, or does nothing when there
# is none, so a report that has gone clean can retract itself.
#
# Reads its inputs from the environment and writes action/id/url to
# $GITHUB_OUTPUT. action.yml is a thin wrapper; test.sh runs `--pick` and `--body`
# directly. `--body` is how deps-verify reads back a value it stored in a comment.
set -euo pipefail

marker() { printf '<!-- dodi-sticky: %s -->' "$1"; }

# Pick the sticky comment for a key from comments payloads on stdin (one JSON
# array per page) and print its `id` or `body`, or nothing when there is none.
# Bot-authored only: the marker is visible in any raw body, so a person quoting
# one back would otherwise capture the key.
pick() {
  jq -rs --arg m "$(marker "$1")" --arg f "$2" \
    '[.[][] | select((.body // "") | contains($m))
            | select(.user.type == "Bot")]
     | (first | .[$f]) // empty'
}

case "${1:-}" in
  --pick) pick "${2:?--pick needs a key}" id;   exit 0 ;;
  --body) pick "${2:?--body needs a key}" body; exit 0 ;;
esac

: "${KEY:?}" "${REPO:?}" "${NUMBER:?}"
delete="${DELETE:-false}"

if [ "$delete" != "true" ]; then
  : "${BODY_FILE:?}"
  if [ ! -f "$BODY_FILE" ]; then
    echo "::error::sticky-comment: $BODY_FILE does not exist. The step that was meant to write it did not."
    exit 1
  fi
  if [ ! -s "$BODY_FILE" ]; then
    echo "::error::sticky-comment: $BODY_FILE is empty. Refusing to post a blank comment."
    exit 1
  fi
  body="$(printf '%s\n\n%s\n' "$(marker "$KEY")" "$(cat "$BODY_FILE")")"
fi

existing="$(gh api "/repos/$REPO/issues/$NUMBER/comments?per_page=100" --paginate | pick "$KEY" id)"

if [ "$delete" = "true" ]; then
  if [ -n "$existing" ]; then
    gh api -X DELETE "/repos/$REPO/issues/comments/$existing" >/dev/null
    verb=deleted
  else
    verb=none
  fi
  echo "action=$verb" >> "$GITHUB_OUTPUT"
  echo "sticky comment '$KEY' $verb"
  exit 0
fi

if [ -n "$existing" ]; then
  verb=updated
  written="$(gh api -X PATCH "/repos/$REPO/issues/comments/$existing" \
             -f body="$body" --jq '"\(.id) \(.html_url)"')"
else
  verb=created
  written="$(gh api "/repos/$REPO/issues/$NUMBER/comments" \
             -f body="$body" --jq '"\(.id) \(.html_url)"')"
fi
read -r id url <<< "$written"

{
  echo "action=$verb"
  echo "id=$id"
  echo "url=$url"
} >> "$GITHUB_OUTPUT"
echo "sticky comment '$KEY' $verb: $url"
