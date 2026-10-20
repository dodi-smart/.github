#!/usr/bin/env bash
# Runs hk over the whole tree, writes what it said to the job summary and exits
# with its status.
#
# SARIF is where hk writes its report (hk.sarif; tests point it elsewhere). The whole tree, never `--pr`:
# type-aware and cross-file rules need it, and a changed-files run would pass
# what the full run fails.
set -euo pipefail

SARIF="${SARIF:-hk.sarif}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
# A job summary is capped at 1 MiB; the first 50 KB of hk's output is plenty.
MAX_BYTES=50000

log="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/hk-check.XXXXXX")"
trap 'rm -f "$log"' EXIT

# Not `set +e`: only hk's status may fail this script, and tee's must not.
status=0
hk check --all --sarif "$SARIF" 2>&1 | tee "$log" || status="${PIPESTATUS[0]}"

# ESC by printf: BSD sed (a macOS runner) has no \x1b.
esc="$(printf '\033')"
{
  echo '### hk check --all'
  echo '```'
  head -c "$MAX_BYTES" "$log" | sed "s/${esc}\[[0-9;]*[A-Za-z]//g"
  # A cut can end mid-line, and the fence must still start on its own line.
  echo
  echo '```'
} >> "$SUMMARY"

# hk dying mid-write leaves a truncated or empty file, which a later upload to
# code scanning would reject. The artifact still carries it, so say so here.
# `jq empty` passes an empty file; `-e type` needs a document to print.
if [ -f "$SARIF" ] && ! jq -e type "$SARIF" >/dev/null 2>&1; then
  echo "::warning title=hk wrote invalid SARIF::$SARIF is not valid JSON, so code scanning would reject it. The artifact holds it as written."
fi

exit "$status"
