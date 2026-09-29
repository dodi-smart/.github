#!/usr/bin/env bash
# Turn an LCOV file into a short markdown coverage report and a pass/fail verdict.
#
# Overall coverage is the sum of LH over the sum of LF across every record.
# Changed-file coverage is the same sum over the records whose path is in the
# pull request's changed-file list. A changed file the report never mentions
# (docs, config, or code the tests do not load) has no lines to measure, so it
# stays out of the figure instead of counting as 0%.
#
# LCOV paths are the test runner's, often absolute. ROOT is that runner's
# workspace, which is not this job's: the report was written on another machine.
#
# Reads its inputs from the environment and writes overall/changed/failed to
# $GITHUB_OUTPUT. It never exits non-zero for a breached floor, so the comment
# can be posted first; the action fails the job from `failed` afterwards.
# action.yml is a thin wrapper; test.sh runs this script directly.
set -euo pipefail

: "${LCOV_FILE:?}" "${OUT:?}"
out="${GITHUB_OUTPUT:-/dev/stdout}"

# The path may be a glob: the coverage job points it at the download directory,
# which holds the one report under whatever name the test command gave it.
match="$(compgen -G "$LCOV_FILE" | head -n 1 || true)"
[ -z "$match" ] || LCOV_FILE="$match"
if [ ! -f "$LCOV_FILE" ]; then
  echo "::error::lcov-report: $LCOV_FILE does not exist. Check that the test command writes it and that coverage-path points at it."
  exit 1
fi

LCOV_FILE="$LCOV_FILE" ROOT="${ROOT:-}" CHANGED="${CHANGED_FILES:-}" \
MIN_OVERALL="${MIN_OVERALL:-0}" MIN_CHANGED="${MIN_CHANGED:-0}" OUT="$OUT" \
awk '
function norm(p) {
  sub(/\r$/, "", p)
  if (ROOT != "" && index(p, ROOT "/") == 1) p = substr(p, length(ROOT) + 2)
  sub(/^\.\//, "", p)
  return p
}
function pct(h, l) { return l > 0 ? 100 * h / l : -1 }
function fmt(h, l) { return l > 0 ? sprintf("%.1f%%", 100 * h / l) : "n/a" }
# Names come from the test runner, so keep them from breaking the table.
function clean(s) { gsub(/[|`\r]/, "", s); return s }
function floor_(m) { return m > 0 ? m "%" : "none" }
BEGIN {
  ROOT = ENVIRON["ROOT"]; sub(/\/+$/, "", ROOT)
  n = split(ENVIRON["CHANGED"], list, "\n")
  for (i = 1; i <= n; i++) { c = norm(list[i]); if (c != "") { changed[c] = 1; nlisted++ } }
  min_o = ENVIRON["MIN_OVERALL"] + 0; min_c = ENVIRON["MIN_CHANGED"] + 0
  cur = ""
  while ((getline line < ENVIRON["LCOV_FILE"]) > 0) {
    if (line ~ /^SF:/)      { cur = norm(substr(line, 4)); seen[cur] = 1 }
    else if (cur == "")     { continue }
    else if (line ~ /^LF:/) { lf[cur] += substr(line, 4) }
    else if (line ~ /^LH:/) { lh[cur] += substr(line, 4) }
  }
  for (f in seen) {
    oh += lh[f]; ol += lf[f]
    if (f in changed) {
      nrep++
      if (lf[f] > 0) { ch += lh[f]; cl += lf[f]; meas[++nm] = f }
    }
  }

  dest = ENVIRON["OUT"]
  print "### Code coverage\n" > dest
  print "| Scope | Lines | Coverage | Minimum |" > dest
  print "| --- | --- | --- | --- |" > dest
  printf "| Overall | %d / %d | %s | %s |\n", oh, ol, fmt(oh, ol), floor_(min_o) > dest
  if (nlisted == 0)
    printf "| Changed files | not listed | n/a | %s |\n", floor_(min_c) > dest
  else
    printf "| Changed files (%d of %d in the report) | %d / %d | %s | %s |\n",
           nrep, nlisted, ch, cl, fmt(ch, cl), floor_(min_c) > dest

  # The lowest few changed files, worst first, by repeated selection: the list
  # is short and awk has no sort.
  shown = nm < 5 ? nm : 5
  if (shown > 0) {
    print "\nLowest changed files:\n" > dest
    print "| File | Lines | Coverage |" > dest
    print "| --- | --- | --- |" > dest
    for (k = 1; k <= shown; k++) {
      best = ""
      for (j = 1; j <= nm; j++) {
        f = meas[j]
        if (used[f]) continue
        if (best == "" || pct(lh[f], lf[f]) < pct(lh[best], lf[best])) best = f
      }
      used[best] = 1
      printf "| `%s` | %d / %d | %s |\n", clean(best), lh[best], lf[best], fmt(lh[best], lf[best]) > dest
    }
  }

  failed = ""
  if (min_o > 0 && ol == 0)
    failed = "the report has no instrumented lines, so overall coverage cannot meet the " min_o "% minimum"
  else if (min_o > 0 && oh * 100 < min_o * ol)
    failed = sprintf("overall coverage %s is below the %s%% minimum", fmt(oh, ol), min_o)
  if (min_c > 0 && cl > 0 && ch * 100 < min_c * cl)
    failed = failed (failed != "" ? "; " : "") sprintf("changed-file coverage %s is below the %s%% minimum", fmt(ch, cl), min_c)
  if (failed != "") printf "\n**Below the minimum:** %s.\n", failed > dest
  close(dest)

  printf "overall=%s\nchanged=%s\nfailed=%s\n", (ol > 0 ? sprintf("%.1f", 100 * oh / ol) : ""), (cl > 0 ? sprintf("%.1f", 100 * ch / cl) : ""), failed
}' >> "$out"
