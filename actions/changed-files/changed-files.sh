#!/usr/bin/env bash
# List a pull request's changed files through the API, with no checkout, and say
# whether any of them matches a set of globs.
#
# A skip built on this must be a positive claim: "every changed file is outside
# these paths". So every doubt resolves to `matched=true`, which runs the work:
# no pull request number, a diff the API could not return, an empty diff, and a
# diff at the API's 3000-file cap, where the list is cut off and a file that
# matters could be past the cut.
#
# Reads its inputs from the environment and writes files/matched to
# $GITHUB_OUTPUT. action.yml is a thin wrapper; test.sh runs `--names` and
# `--match` directly.
set -euo pipefail

# Where the API stops listing files, however many pages you ask for.
CAP=3000

# `filename<TAB>previous_filename` lines on stdin -> one path per line. A rename
# counts under both names, since the old path leaving a directory is a change to it.
names() {
  awk -F'\t' 'NF && $1 != "" { print $1; if ($2 != "") print $2 }' | sort -u
}

# Paths on stdin, newline-separated patterns in $1. `fnmatch`-style, so `*` crosses
# `/`, the same as pr-checks' `docs-only-paths`. A pattern also matches everything
# under it, so a directory needs no `dir/*` of its own.
matches() {
  python3 -c '
import fnmatch, sys
pats = [p.strip().rstrip("/") for p in sys.argv[1].splitlines() if p.strip()]
pats += [p + "/*" for p in pats]
files = [f for f in sys.stdin.read().splitlines() if f]
print("true" if any(fnmatch.fnmatchcase(f, p) for f in files for p in pats) else "false")
' "$1"
}

case "${1:-}" in
  --names) names; exit 0 ;;
  --match) matches "${2-}"; exit 0 ;;
esac

: "${REPO:?}"
out="${GITHUB_OUTPUT:-/dev/stdout}"

finish() { # matched, files
  {
    echo "matched=$1"
    echo "files<<CHANGED_FILES_EOF"
    [ -z "$2" ] || printf '%s\n' "$2"
    echo "CHANGED_FILES_EOF"
  } >> "$out"
  echo "matched=$1"
  exit 0
}

if [ -z "${NUMBER:-}" ]; then
  echo "::notice::not a pull request, so nothing to diff; treating the change as matching"
  finish true ""
fi

if ! entries=$(gh api --paginate "repos/$REPO/pulls/$NUMBER/files?per_page=100" \
  --jq '.[] | [.filename, (.previous_filename // "")] | @tsv'); then
  echo "::warning::could not list the files of $REPO#$NUMBER (the token needs pull-requests: read); treating the change as matching"
  finish true ""
fi

count=$(printf '%s\n' "$entries" | grep -c . || true)
files=$(printf '%s\n' "$entries" | names)
echo "$count changed file(s)"
[ -z "$files" ] || printf '%s\n' "$files"

if [ "$count" -eq 0 ]; then
  echo "::notice::the pull request lists no files; treating the change as matching"
  finish true ""
fi
if [ "$count" -ge "$CAP" ]; then
  echo "::notice::the pull request has $CAP files or more, which is where the API stops listing; treating the change as matching"
  finish true "$files"
fi
if [ -z "$(printf '%s' "${PATTERNS:-}" | tr -d '[:space:]')" ]; then
  finish true "$files"
fi
finish "$(printf '%s\n' "$files" | matches "$PATTERNS")" "$files"
