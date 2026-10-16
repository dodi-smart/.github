#!/usr/bin/env bash
# Resolve the pull request a run is about, read it once from the API, and say
# whether it is still the same open, same-repo pull request at the expected
# head. Every workflow that acts on a PR from an event that does not carry one
# (workflow_run, status) or acts after a long queue reads it here, so the rules
# for "which PR, and is it still that PR" exist once.
#
# Inputs (environment):
#   REPO            owner/repo
#   NUMBER          a PR number; empty resolves it from the event below
#   EVENT           github.event_name
#   GITHUB_EVENT_PATH  the event payload
#   EXPECTED_SHA    the head the caller acted on; empty takes the event's own
#                   (workflow_run.head_sha, status sha), or skips the test
# Outputs: found, why, number, head-sha, head-ref, base-ref, author, draft,
# title, labels (JSON). `found=false` covers no PR, a closed PR, a fork, and a
# head that moved past EXPECTED_SHA; `why` says which.
set -euo pipefail

out() { echo "$1" >> "$GITHUB_OUTPUT"; }
none() { out found=false; out "why=$1"; echo "$1"; exit 0; }
ev() { jq -r "$1 // empty" "${GITHUB_EVENT_PATH:-/dev/null}" 2>/dev/null || true; }

n="${NUMBER:-}"
expected="${EXPECTED_SHA:-}"
if [ -z "$n" ]; then
  case "${EVENT:-}" in
    pull_request|pull_request_target) n=$(ev .pull_request.number) ;;
    workflow_run)
      [ "$(ev .workflow_run.event)" = pull_request ] || none "the run was for a $(ev .workflow_run.event) event, not a pull request"
      expected="${expected:-$(ev .workflow_run.head_sha)}"
      n=$(ev '.workflow_run.pull_requests[0].number')
      if [ -z "$n" ]; then
        branch=$(ev .workflow_run.head_branch)
        n=$(gh api "/repos/$REPO/pulls?state=open&head=${REPO%%/*}:$branch" --jq '.[0].number // empty')
      fi ;;
    status)
      expected="${expected:-$(ev .sha)}"
      n=$(gh api "/repos/$REPO/commits/$expected/pulls" \
            --jq "[.[] | select(.state == \"open\" and .head.sha == \"$expected\")][0].number // empty") ;;
    *) none "event ${EVENT:-none} names no pull request" ;;
  esac
fi
[ -n "$n" ] || none "no open pull request for this event"

pr=$(gh api "/repos/$REPO/pulls/$n")
f() { jq -r "$1" <<<"$pr" | tr -d '\r\n'; }
[ "$(f .state)" = open ] || none "#$n is $(f .state)"
[ "$(f .head.repo.full_name)" = "$REPO" ] || none "#$n comes from a fork"
head=$(f .head.sha)
[ -z "$expected" ] || [ "$expected" = "$head" ] || none "#$n has moved from $expected to $head"
jq -r '"found=true", "why=", "number=\(.number)", "head-sha=\(.head.sha)", "head-ref=\(.head.ref)",
       "base-ref=\(.base.ref)", "author=\(.user.login)", "draft=\(.draft)",
       "title=\(.title | gsub("[\r\n]"; " "))", "labels=\([.labels[].name] | tojson)"' <<<"$pr" >> "$GITHUB_OUTPUT"
echo "#$n at $head"
