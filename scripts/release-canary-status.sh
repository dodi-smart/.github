#!/usr/bin/env bash
# Posts the `release-canary` commit status that promote.yml reads through
# canary-gate.sh (AGENTS.md has the reasoning). `success` only when the
# pr-checks call succeeded: failed, cancelled and skipped all post `failure`.
#
# Needs gh, GH_TOKEN, and REPO, SHA, RESULT (the call's result, which may be
# empty and then posts `failure`) and RUN_URL in the environment.
# GITHUB_STEP_SUMMARY is optional.
# Tests: scripts/release-canary-status.test.sh, with a stubbed `gh`.
set -euo pipefail

: "${REPO:?REPO is not set}" "${SHA:?SHA is not set}" "${RESULT?RESULT is not set}" "${RUN_URL:?RUN_URL is not set}"

state=failure
[ "$RESULT" = success ] && state=success

gh api "repos/$REPO/statuses/$SHA" \
  -f state="$state" \
  -f context=release-canary \
  -f description="pr-checks result against this release: $RESULT" \
  -f target_url="$RUN_URL"
echo "release-canary: $state on $SHA ($RESULT)" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
