#!/usr/bin/env bash
# kover-report renders a breached minimum as a mark in its comment and exits 0,
# so a report at 0% passed a floor of 40 and a broken coverage plugin reached a
# default branch. The overall floor is enforced here from its output, as
# actions/lcov-report does itself. The changed-files floor stays comment-only:
# kover-report reports 0, not empty, when no changed file is in the report, so
# enforcing it would fail every pull request that touches no covered source.
#
# OVERALL      kover-report's coverage-overall output
# MIN_OVERALL  the floor in percent, 0 or empty is none
set -euo pipefail

MIN_OVERALL="${MIN_OVERALL:-0}"

if [ -z "${OVERALL:-}" ]; then
  echo "::error::coverage: kover-report produced no overall figure"
  exit 1
fi
if awk -v v="$OVERALL" -v m="$MIN_OVERALL" 'BEGIN { exit !(m > 0 && v + 0 < m + 0) }'; then
  echo "::error::coverage: overall ${OVERALL}% is below the ${MIN_OVERALL}% floor"
  exit 1
fi
echo "coverage: overall ${OVERALL}% (floor ${MIN_OVERALL}%)"
