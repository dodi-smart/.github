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
# Reads WEIGHT, LABELS, HOSTED_RUNNER, GUARD, PRIVATE, FORK, and for each weight
# an optional override, RUNS_ON_<WEIGHT> (the action input) or, when that is empty,
# DODI_RUNS_ON_<WEIGHT> (the org variable, exported by the caller's job `env`). An
# override is JSON, an array of labels or one label as a string.
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

# override <value> -> comma-separated labels on stdout, or a non-zero status when
# the value is not a non-empty JSON string or array of strings.
override() {
  jq -r 'if type == "string" and length > 0 then .
         elif type == "array" and length > 0 and all(type == "string" and length > 0) then join(",")
         else error("not a label or an array of labels") end' <<<"$1" 2>/dev/null
}

# Public repos and fork PRs never touch self-hosted, with no opt-out. The runner
# group refuses public repos, and a fork PR would otherwise run attacker-authored
# code on our hardware against a cache the next job inherits. This path ignores
# `labels` and every override.
if [ "${GUARD:-true}" = "true" ] && { [ "${PRIVATE:-}" != "true" ] || [ "${FORK:-}" = "true" ]; }; then
  echo "public repo or fork PR, hosted only"
  emit "" "$HOSTED_RUNNER"
  exit 0
fi

if [ -n "$LABELS" ]; then
  sel="$LABELS"
else
  case "$WEIGHT" in
    light)  sel="self-hosted,Linux,light";  var="${RUNS_ON_LIGHT:-${DODI_RUNS_ON_LIGHT:-}}" ;;
    heavy)  sel="self-hosted,Linux,large";  var="${RUNS_ON_HEAVY:-${DODI_RUNS_ON_HEAVY:-}}" ;;
    agent)  sel="self-hosted,Linux,agent";  var="${RUNS_ON_AGENT:-${DODI_RUNS_ON_AGENT:-}}" ;;
    apple)  sel="self-hosted,macOS,ARM64";  var="${RUNS_ON_APPLE:-${DODI_RUNS_ON_APPLE:-}}" ;;
    hosted) sel="";                         var="" ;;
    *)
      echo "::error::unknown weight '$WEIGHT' (expected light|heavy|agent|apple|hosted, or set the labels input)"
      exit 1 ;;
  esac
  # The emergency switch: an org variable repoints a weight, typically at
  # hosted, without a release. A value that does not parse is reported and
  # ignored, because failing every job over a typo in the switch is worse.
  if [ -n "$var" ]; then
    if o=$(override "$var"); then
      sel="$o"
      echo "weight '$WEIGHT' overridden by DODI_RUNS_ON_*: $sel"
    else
      echo "::warning title=Runner override ignored::DODI_RUNS_ON_$(printf '%s' "$WEIGHT" | tr '[:lower:]' '[:upper:]') is not a JSON label or array of labels ($var), so the default selector is used."
    fi
  fi
fi

if [ -z "$sel" ]; then
  emit "" "$HOSTED_RUNNER"
else
  echo "resolved selector: $sel"
  emit "$sel" "$sel"
fi
