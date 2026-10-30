#!/usr/bin/env bash
# Fail a pull request that would move a version backwards on its base.
#
# A back-merge resolved by hand once took the release branch's version line and
# changelog wholesale, and the integration branch went from 1.10.0-develop.14 to
# 1.9.1 with every check green. This is the check that would have caught it.
#
# Only the version keys the pull request itself changes count: a feature branch
# cut before the base's last prerelease still carries the older version line,
# but never touched it, so the merge keeps the base's. For each version file in
# FILES_PATH (actions/changed-files' `files-path`; FILES, the list itself, for a
# caller with no path; versions.pl says which are version files),
# compare, through the API so this needs no checkout, the base as it is now
# with the head. Only when the head is lower is the merge base read, to tell a
# line the pull request lowered from one it never touched.
#
# A list that is not COMPLETE, or a file that cannot be read, is a warning and
# no block: this guards against a rare mistake and must not hold every pull
# request hostage to an outage. Writes verdict (skip|pass|reject) to
# $GITHUB_OUTPUT and exits 1 on reject.
set -euo pipefail

VERSIONS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/versions.pl"

emit() {
  echo "verdict=$1" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "version guard: $1: $2"
}

# The file at commit $2, raw, into $3. 0: written. 44: not there at that
# commit. 1: it could not be read, which is not the same as absent.
fetch() {
  local enc
  enc="$(jq -rn --arg p "$1" '$p | split("/") | map(@uri) | join("/")')"
  if gh api -H 'Accept: application/vnd.github.raw' "repos/$REPO/contents/$enc?ref=$2" > "$3" 2> "$3.err" < /dev/null; then
    return 0
  fi
  if grep -q 'HTTP 404' "$3.err"; then return 44; fi
  return 1
}

unreadable() { echo "::warning title=Version guard::$1 could not be read, so its versions were not checked."; }

if [ "${EVENT:-}" != pull_request ] || [ -z "${NUMBER:-}" ]; then
  emit skip "not a pull request"
  exit 0
fi
: "${REPO:?}" "${BASE_SHA:?}" "${HEAD_SHA:?}"

if [ "${COMPLETE:-}" != true ]; then
  echo "::warning title=Version guard::The changed files could not be listed in full, so versions were not checked."
  emit skip "the changed files could not be read in full"
  exit 0
fi
[ -z "${FILES_PATH:-}" ] || FILES=$(<"$FILES_PATH")
files=$(printf '%s\n' "${FILES:-}" | perl "$VERSIONS" files)
if [ -z "$files" ]; then
  emit pass "no version file changed"
  exit 0
fi

d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
found="" mb=""
while IFS= read -r f; do
  # Added or deleted by the pull request: nothing on the base to fall below.
  rc=0; fetch "$f" "$BASE_SHA" "$d/base" || rc=$?
  [ "$rc" -ne 44 ] || continue
  [ "$rc" -eq 0 ] || { unreadable "$f"; continue; }
  rc=0; fetch "$f" "$HEAD_SHA" "$d/head" || rc=$?
  [ "$rc" -ne 44 ] || continue
  [ "$rc" -eq 0 ] || { unreadable "$f"; continue; }
  lowered=$(perl "$VERSIONS" regress "$f" "$d/base" "$d/head")
  [ -n "$lowered" ] || continue
  # Lower than the base: the pull request's doing only if it changed the line.
  [ -n "$mb" ] || mb=$(gh api "repos/$REPO/compare/$BASE_SHA...$HEAD_SHA?per_page=1" --jq '.merge_base_commit.sha' 2>/dev/null || true)
  if [ -n "$mb" ] && fetch "$f" "$mb" "$d/mb"; then
    lowered=$(perl "$VERSIONS" regress "$f" "$d/base" "$d/head" "$d/mb")
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "::error file=$f,title=Version moves backwards::$line"
    found="$found$line"$'\n'
  done <<<"$lowered"
done <<<"$files"

if [ -n "$found" ]; then
  {
    echo "### A version would move backwards"
    echo
    echo "This pull request sets a version lower than the base already has:"
    echo
    printf '%s' "$found" | sed 's/^/- /'
    echo
    echo "Keep the base's version wherever it is the higher. A back-merge after a hotfix keeps the integration branch's version and adds the release's changelog section; it never takes the release branch's version or changelog wholesale."
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  emit reject "a version would move backwards"
  exit 1
fi
emit pass "no version moves backwards"
