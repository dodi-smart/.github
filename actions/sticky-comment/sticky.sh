#!/usr/bin/env bash
# Post one comment per key, and edit it in place on every later run.
#
# claude-code-action's own sticky comment is tag-mode only, and tag mode is
# closed to both workflows that want one here. It rewrites the prompt, so a
# slash command never expands, and it enables commit tooling that deps-verify
# must never have.
#
# The comment is found by a hidden marker in the body, never by author or
# position: `gh pr comment --edit-last` edits the last comment by the token,
# which is the wrong one as soon as anything else comments in between.
#
# Reads its inputs from the environment and writes action/id/url to
# $GITHUB_OUTPUT. action.yml is a thin wrapper; test.sh runs `--pick` directly.
set -euo pipefail

marker() { printf '<!-- dodi-sticky: %s -->' "$1"; }

# Pick the sticky comment's id from a comments payload on stdin, or print
# nothing when there is none to update. Bot-authored only: the marker is visible
# in any raw body, so a person quoting one back would otherwise capture the key.
pick() {
  jq -r --arg m "$(marker "$1")" \
    'map(select((.body // "") | contains($m))
         | select(.user.type == "Bot"))
     | (first | .id) // empty'
}

if [ "${1:-}" = "--pick" ]; then
  pick "${2:?--pick needs a key}"
  exit 0
fi

: "${KEY:?}" "${BODY_FILE:?}" "${REPO:?}" "${NUMBER:?}"

if [ ! -f "$BODY_FILE" ]; then
  echo "::error::sticky-comment: $BODY_FILE does not exist. The step that was meant to write it did not."
  exit 1
fi
if [ ! -s "$BODY_FILE" ]; then
  echo "::error::sticky-comment: $BODY_FILE is empty. Refusing to post a blank comment."
  exit 1
fi

body="$(printf '%s\n\n%s\n' "$(marker "$KEY")" "$(cat "$BODY_FILE")")"

existing="$(gh api "/repos/$REPO/issues/$NUMBER/comments?per_page=100" --paginate | pick "$KEY")"

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
