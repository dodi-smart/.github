#!/usr/bin/env bash
# Apply agent:review to PR at SHA, unless the org App has already posted a
# `review / verdict` there. Which status counts is merge-gate's statuses.sh, so
# a verdict anyone else posted neither stops this request nor counts at the
# gate. test.sh runs it with `gh` stubbed.
#
# env: GH_TOKEN (the App token; empty means no App), REPO, PR, SHA,
#      APP_BOT (the App's login, `<slug>[bot]`)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }

out requested false
if [ -z "${GH_TOKEN:-}" ]; then
  echo "::warning title=No review requested::GH_APP_CLIENT_ID is not set, and only an App label starts PR Review."
  exit 0
fi
# The context and its creator are the contract; see the README's Review verdict section.
verdict=$("$HERE/../merge-gate/statuses.sh" read "$REPO" "$SHA" | "$HERE/../merge-gate/statuses.sh" app 'review / verdict' "${APP_BOT:-}")
if [ -n "$verdict" ]; then
  echo "review / verdict ($verdict) from $APP_BOT already on $SHA"
  exit 0
fi
gh api "/repos/$REPO/issues/$PR/labels" -f "labels[]=agent:review" >/dev/null
out requested true
echo "requested a review of #$PR at $SHA"
