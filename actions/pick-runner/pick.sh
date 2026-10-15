#!/usr/bin/env bash
# The picker's whole decision, as a standalone script so `test.sh` can assert it
# without a runner. Writes `runner`, `selector` and `fell-back` to $GITHUB_OUTPUT.
#
# It is STATIC: no API call, no token, no fleet listing. A weight is a fixed list
# of capability labels, and when a pool is busy GitHub's own queue sends the job to
# any runner that carries the labels (the large pool carries `light` too), so the
# picker needs neither a health check nor a fallback. `fell-back` stays in the
# output for callers that read it, and is always false.
#
# Reads WEIGHT, LABELS, HOSTED_RUNNER, GUARD, PRIVATE, FORK, and FALLBACK and
# FALLBACK_WHEN, which are deprecated: set, they only print a warning. Nothing
# repoints a weight at run time; its labels change here, in a release.
set -euo pipefail

: "${GITHUB_OUTPUT:=/dev/stdout}"

WEIGHT="${WEIGHT:-light}"
LABELS="${LABELS:-}"
HOSTED_RUNNER="${HOSTED_RUNNER:-ubuntu-latest}"

# A comma-separated selector as the JSON array `runs-on` reads through fromJson().
runner_json() {
  jq -cn --arg s "$1" '$s | split(",") | map(gsub("^\\s+|\\s+$"; ""))'
}

emit() { # <comma-separated selector, empty when hosted> <runner selector>
  { echo "runner=$(runner_json "$2")"; echo "selector=$1"; echo "fell-back=false"; } >> "$GITHUB_OUTPUT"
}

# A caller written for the fleet-listing picker may still pass these. They change
# nothing, so the caller should drop them before they are removed.
for v in FALLBACK FALLBACK_WHEN; do
  if [ -n "${!v:-}" ]; then
    name=$(printf '%s' "$v" | tr '[:upper:]_' '[:lower:]-')
    echo "::warning title=Deprecated pick-runner input::\`$name\` is ignored and will be removed. Delete it from the caller."
  fi
done

# Public repos and fork PRs never touch self-hosted, with no opt-out. The runner
# group refuses public repos, and a fork PR would otherwise run attacker-authored
# code on our hardware against a cache the next job inherits. This path ignores
# `labels`.
if [ "${GUARD:-true}" = "true" ] && { [ "${PRIVATE:-}" != "true" ] || [ "${FORK:-}" = "true" ]; }; then
  echo "public repo or fork PR, hosted only"
  emit "" "$HOSTED_RUNNER"
  exit 0
fi

if [ -n "$LABELS" ]; then
  sel="$LABELS"
else
  case "$WEIGHT" in
    light)  sel="self-hosted,Linux,light" ;;
    heavy)  sel="self-hosted,Linux,large" ;;
    agent)  sel="self-hosted,Linux,agent" ;;
    apple)  sel="self-hosted,macOS,ARM64" ;;
    hosted) sel="" ;;
    *)
      echo "::error::unknown weight '$WEIGHT' (expected light|heavy|agent|apple|hosted, or set the labels input)"
      exit 1 ;;
  esac
fi

if [ -z "$sel" ]; then
  emit "" "$HOSTED_RUNNER"
else
  echo "resolved selector: $sel"
  emit "$sel" "$sel"
fi
