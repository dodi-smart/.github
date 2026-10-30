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
# `all-matched` is the same claim turned round, for a skip that needs EVERY file
# inside the paths (a docs-only change). It is `true` only when the list was read
# in full, is not empty, and every file matches, so every doubt is `false` there.
#
# `complete` is the claim a caller needs when it works from `files` itself rather
# than from `matched`: `true` only when the whole list was read, so `files` is
# every changed path. It is `false` on the same doubts, whatever the patterns.
#
# Reads its inputs from the environment and writes files/files-path/matched/
# all-matched/complete to $GITHUB_OUTPUT. action.yml is a thin wrapper; test.sh runs `--names`, `--match`
# and `--all` directly.
set -euo pipefail

# Where the API stops listing files, however many pages you ask for.
CAP=3000

# `filename<TAB>previous_filename` lines on stdin -> one path per line. A rename
# counts under both names, since the old path leaving a directory is a change to it.
names() {
  awk -F'\t' 'NF && $1 != "" { print $1; if ($2 != "") print $2 }' | sort -u
}

# Paths on stdin, newline-separated patterns in $1, `any` or `all` in $2.
# `fnmatch`-style, so `*` crosses `/`, the same as pr-checks' `docs-only-paths`. A
# pattern also matches everything under it, so a directory needs no `dir/*` of its
# own. `all` needs at least one path and one pattern, so it is never vacuously true.
matches() {
  # Pure bash, so it runs on an image that ships no scripting runtime. A `case` pattern is
  # an fnmatch pattern in which `*` also crosses `/`, which is the semantics
  # this needs.
  local mode="${2:-any}" pats=() p f hit n=0 total=0 ok
  while IFS= read -r p; do
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    while [[ "$p" == */ ]]; do p="${p%/}"; done
    [ -n "$p" ] || continue
    pats+=("$p" "$p/*")
  done <<<"$1"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    total=$((total + 1))
    hit=0
    for p in ${pats[@]+"${pats[@]}"}; do
      # shellcheck disable=SC2254  # $p is a pattern on purpose
      case "$f" in $p) hit=1; break ;; esac
    done
    n=$((n + hit))
  done
  ok=false
  if [ "$mode" = "all" ]; then
    [ "$total" -gt 0 ] && [ "${#pats[@]}" -gt 0 ] && [ "$n" -eq "$total" ] && ok=true
  else
    [ "$n" -gt 0 ] && ok=true
  fi
  echo "$ok"
}

case "${1:-}" in
  --names) names; exit 0 ;;
  --match) matches "${2-}" any; exit 0 ;;
  --all)   matches "${2-}" all; exit 0 ;;
esac

: "${REPO:?}"
out="${GITHUB_OUTPUT:-/dev/stdout}"

# The list also goes to a file, `files-path`. Linux caps one environment string at
# 128 KiB, and a few thousand paths in an `env:` stop the next step's shell from
# starting at all ("Argument list too long"), so a step reads the file instead.
finish() { # matched, files, all-matched (false unless given), complete (false unless given)
  local path
  path=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/changed-files.XXXXXX")
  [ -z "$2" ] || printf '%s\n' "$2" > "$path"
  {
    echo "matched=$1"
    echo "all-matched=${3:-false}"
    echo "complete=${4:-false}"
    echo "files-path=$path"
    echo "files<<CHANGED_FILES_EOF"
    cat "$path"
    echo "CHANGED_FILES_EOF"
  } >> "$out"
  echo "matched=$1 all-matched=${3:-false} complete=${4:-false}"
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
  finish true "$files" false true
fi
finish "$(printf '%s\n' "$files" | matches "$PATTERNS" any)" "$files" \
       "$(printf '%s\n' "$files" | matches "$PATTERNS" all)" true
