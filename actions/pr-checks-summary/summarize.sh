#!/usr/bin/env bash
# The verdict of the `PR Checks` job: a needed job that failed or was cancelled
# fails it. A skipped one never does, which is what lets a job be off for a
# caller, and an advisory job (IGNORE) is read as skipped.
#
# NEEDS    the `needs` context as JSON: job id -> {result, outputs}
# IGNORE   space-separated job ids that must not fail the verdict
# DOCS_ONLY  'true' only changes the closing message
# LABEL    the workflow the messages name (default pr-checks)
set -euo pipefail
label="${LABEL:-pr-checks}"

# No jobs to judge is a broken call, never a pass.
jq -e 'type == "object" and length > 0' <<<"$NEEDS" > /dev/null \
  || { echo "::error::$label: no jobs to summarize, so there is no verdict"; exit 1; }

# Each name keeps a leading space and the input order, as the message below
# prints them. A parse error stops the script (pipefail), which fails closed.
failed="$(jq -r --arg ignore "${IGNORE:-}" '
  ($ignore | split(" ") | map(select(. != ""))) as $advisory
  | to_entries[]
  | select(.value.result == "failure" or .value.result == "cancelled")
  | select(.key as $id | any($advisory[]; . == $id) | not)
  | " \(.key)(\(.value.result))"' <<<"$NEEDS" | tr -d '\n')"

if [ -n "$failed" ]; then
  echo "::error::$label: failed jobs:$failed"
  exit 1
fi

if [ "${DOCS_ONLY:-}" = "true" ]; then
  echo "$label: docs-only change, checks skipped"
else
  echo "$label: all required jobs passed"
fi
