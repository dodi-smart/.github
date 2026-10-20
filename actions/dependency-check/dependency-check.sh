#!/usr/bin/env bash
# Scan the lockfiles a pull request changed with osv-scanner, and report only the
# vulnerabilities the pull request brought in.
#
# osv-scanner reports every known vulnerability in a lockfile, so scanning the
# head alone would fail an unrelated change over a problem that was already
# there. Each changed lockfile is also read at the base commit through the
# contents API (no second checkout, and the caller's may be shallow) and scanned
# too. A finding is NEW only when its (package, vulnerability id) pair is absent
# at base. The version is left out of the pair on purpose: moving to another
# vulnerable version of the same package is not a new problem. A lockfile the
# base does not have (a 404) is new, so all of its findings are.
#
# Three results are kept apart, because a reader acts differently on each:
#   - a new finding at or above `fail-on`: the change made the code less safe;
#   - a finding that was already there: reported by count, never blocking;
#   - a scan that could not run (osv.dev unreachable, an unparsable lockfile, a
#     base that could not be read): "I could not check" is not "I checked and it
#     is fine", so with a threshold set it fails the job and says so, and only
#     `fail-on: none` lets it through, with a warning.
# osv-scanner exits 1 when it finds something and 127 on an error, which is why
# the exit code is read and not just tested for zero. 128 means the file listed
# no packages at all.
#
# Severity is osv-scanner's `max_severity`, a CVSS base score. 9.0 and up is
# critical, 7.0 high, 4.0 moderate, above 0 low. A score of 0 is `none` and never
# blocks. A finding with NO usable score is `unknown` and ranks as high: an
# advisory with no score is usually one nobody has scored yet, not a harmless
# one, so letting it through would let a gate be passed by the newest advisories.
#
# Not run for dependency PRs (author-kind `dependency`). deps-verify owns those:
# it reads the changelogs and the build, labels the PR and decides what happens
# next, and a second check here would block the very updates that fix things.
#
# Env: LOCKFILES (newline list; overrides the computed one), AUTHOR_KIND
# (action.yml classifies the author), FAIL_ON, REPO, NUMBER, BASE_SHA, GH_TOKEN,
# FILES and LIST_COMPLETE (changed-files' `files` and `complete`: every changed
# path, and whether the list was read in full), OSV_SCANNER (a binary to use
# instead of installing one). Writes a short report to $GITHUB_STEP_SUMMARY and
# logs a one-line verdict. test.sh runs it with a fake binary and gh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
fail_on="${FAIL_ON:-none}"

case "$fail_on" in
  none|low|moderate|high|critical) ;;
  *) echo "::error::fail-on is '$fail_on'; it must be none, low, moderate, high or critical" >&2; exit 2 ;;
esac

# The lockfiles osv-scanner can read, by file name, as of the pinned version. A
# name it cannot read (go.sum, Podfile.lock) is not here, because passing it
# makes the scanner fail rather than skip. This is the only list of names: the
# action hands changed-files no patterns, so a name added here is picked up.
is_lockfile() {
  case "${1##*/}" in
    bun.lock|package-lock.json|pnpm-lock.yaml|yarn.lock|Cargo.lock|go.mod|gradle.lockfile|\
    Gemfile.lock|poetry.lock|uv.lock|composer.lock|pubspec.lock|requirements*.txt) return 0 ;;
  esac
  return 1
}

# The band's weight against the `fail-on` threshold. `unknown` ranks as high
# (see the top). `none` is 0 so it never meets a threshold, and a threshold of
# `none` is 0, which means no gate at all.
rank() {
  case "$1" in
    low) echo 1 ;;
    moderate) echo 2 ;;
    high|unknown) echo 3 ;;
    critical) echo 4 ;;
    *) echo 0 ;;
  esac
}
limit="$(rank "$fail_on")"

finish() { # result new existing errors
  echo "dependency-check: result=$1 new=$2 existing=$3 errors=$4"
}

skip() { # reason
  echo "::notice::dependency-check: $1"
  printf '**Dependency check:** skipped, %s.\n' "$1" >> "$summary"
  finish skipped 0 0 0
  exit 0
}

# Nothing could be checked at all. Reported apart from a failed check, and with
# `fail-on: none` it warns and passes like every other error here.
cannot_run() { # reason
  printf '**Dependency check:** could not run, %s.\n' "$1" >> "$summary"
  if [ "$limit" -eq 0 ]; then
    echo "::warning::dependency-check could not run: $1"
    finish skipped 0 0 1
    exit 0
  fi
  echo "::error::dependency-check could not run, so nothing was checked: $1"
  finish failed 0 0 1
  exit 1
}

# ---- which lockfiles ---------------------------------------------------------

if [ "${AUTHOR_KIND:-}" = dependency ]; then
  skip "deps-verify owns dependency pull requests"
fi

trim() { awk 'NF { gsub(/\r/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print }'; }

list=""
if [ -n "$(printf '%s' "${LOCKFILES:-}" | tr -d '[:space:]')" ]; then
  list="$(printf '%s\n' "$LOCKFILES" | trim | sort -u)"
elif [ -z "${NUMBER:-}" ]; then
  skip "not a pull request, so there is no base to compare against"
else
  files="${FILES:-}"
  if [ "${LIST_COMPLETE:-}" != true ]; then
    # changed-files could not read the list in full (an API error, an empty list,
    # the 3000-file cap). That does not say no lockfile changed, so look at every
    # supported lockfile in the checkout. That is safe because only findings
    # absent at base are reported: a lockfile the change did not touch has none.
    # (A rename counts as new: its base path is not the new one.)
    echo "the changed-file list was not read in full; scanning every supported lockfile in the checkout"
    files="$(find . \( -name node_modules -o -name .git \) -prune -o -type f -print | sed 's|^\./||')"
  fi
  while IFS= read -r f; do
    if is_lockfile "$f"; then list="$list$f"$'\n'; fi
  done <<<"$files"
  list="$(printf '%s' "$list" | sort -u)"
fi
[ -n "$list" ] || skip "no lockfile changed"

: "${REPO:?}"
[ -n "${BASE_SHA:-}" ] || cannot_run "the pull request's base commit is unknown"

WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dependency-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---- scanning ----------------------------------------------------------------

# Installed on first use, so a pull request with no lockfile never downloads it.
OSV="${OSV_SCANNER:-}"
get_osv() {
  if [ -z "$OSV" ]; then
    OSV="$("$HERE/install.sh")" || cannot_run "osv-scanner could not be installed"
  fi
}

# Finding rows from osv-scanner's JSON, one per vulnerability group (a group is
# one vulnerability under all of its ids):
#   name, version, ecosystem, ids (comma), ids and aliases (space), band, score
extract() {
  jq -r '
    def band:
      ((.max_severity // "") | try tonumber catch null) as $n
      | if $n == null then "unknown"
        elif $n >= 9 then "critical"
        elif $n >= 7 then "high"
        elif $n >= 4 then "moderate"
        elif $n > 0 then "low"
        else "none" end;
    .results[]?.packages[]? | .package as $p | .groups[]?
    | [ ($p.name // "?"), ($p.version // "?"), ($p.ecosystem // "?"),
        (.ids | join(",")), ((.ids + (.aliases // [])) | unique | join(" ")),
        band, (.max_severity // "") ]
    | @tsv' "$1"
}

# Scan one file; $2 is a path prefix for its outputs. 0 means the scan ran and
# $2.tsv holds its findings (possibly none), 1 means it could not.
scan() {
  local rc=0
  "$OSV" scan source --format json -L "$1" > "$2.json" 2> "$2.err" < /dev/null || rc=$?
  case "$rc" in
    0|1) [ -s "$2.json" ] && extract "$2.json" > "$2.tsv" || return 1 ;;
    128) : > "$2.tsv" ;;
    *)   return 1 ;;
  esac
}

# The file at the base commit. 0: written to $2. 44: the base has no such file.
# 1: it could not be read, which is not the same as absent.
fetch_base() {
  local enc
  enc="$(jq -rn --arg p "$1" '$p | split("/") | map(@uri) | join("/")')"
  if gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/$enc?ref=$BASE_SHA" \
       > "$2" 2> "$2.err" < /dev/null; then
    return 0
  fi
  if grep -q 'HTTP 404' "$2.err"; then return 44; fi
  return 1
}

rows="$WORK/rows.tsv"; : > "$rows"
problems="$WORK/problems.txt"; : > "$problems"
errors=0; new=0; existing=0; scanned=0

problem() { # what, error file
  local why
  why="$(grep -v '^$' "$2" 2>/dev/null | tail -n 1 | tr -d '|`\r' | cut -c1-160 || true)"
  errors=$((errors + 1))
  printf '%s\t%s\n' "$1" "${why:-no detail}" >> "$problems"
  echo "::warning::dependency-check could not check $1: ${why:-no detail}"
}

check_file() { # path index
  local path="$1" dir="$WORK/$2" rc=0 base_keys="$WORK/$2/base.keys"
  local bfile="$WORK/$2/base/${path##*/}"
  mkdir -p "$dir/base"
  scanned=$((scanned + 1))
  if ! scan "$path" "$dir/head"; then problem "$path" "$dir/head.err"; return; fi
  if [ ! -s "$dir/head.tsv" ]; then echo "$path: no known vulnerabilities"; return; fi

  : > "$base_keys"
  fetch_base "$path" "$bfile" || rc=$?
  case "$rc" in
    0)  if scan "$bfile" "$dir/basescan"; then
          awk -F'\t' '{ n = split($5, a, " "); for (i = 1; i <= n; i++) print $3 "|" $1 "|" a[i] }' \
            "$dir/basescan.tsv" > "$base_keys"
        else
          problem "$path at the base commit" "$dir/basescan.err"; return
        fi ;;
    44) echo "$path: not in the base commit, so every finding is new" ;;
    *)  problem "$path (its base version could not be read)" "$bfile.err"; return ;;
  esac

  # `FILENAME == ARGV[1]` rather than the NR == FNR idiom, which misreads the
  # second file as the first when the first is empty.
  awk -F'\t' -v OFS='\t' -v lf="$path" '
    FILENAME == ARGV[1] { seen[$0] = 1; next }
    { n = split($5, a, " "); old = 0
      for (i = 1; i <= n; i++) if (($3 "|" $1 "|" a[i]) in seen) old = 1
      print (old ? "old" : "new"), lf, $0 }' "$base_keys" "$dir/head.tsv" >> "$rows"
  echo "$path: checked against the base commit"
}

i=0
while IFS= read -r path; do
  i=$((i + 1))
  if [ ! -f "$path" ]; then
    echo "$path: not in this checkout (the change removed it), nothing to scan"
    continue
  fi
  get_osv
  check_file "$path" "$i"
done <<<"$list"

[ "$scanned" -gt 0 ] || skip "every changed lockfile was removed"

# ---- report ------------------------------------------------------------------

blocked=0
table="$WORK/table.tsv"; : > "$table"
# status, lockfile, name, version, ecosystem, ids, ids+aliases, band, score
while IFS=$'\t' read -r st lf name ver eco ids _ band score; do
  if [ "$st" = old ]; then existing=$((existing + 1)); continue; fi
  new=$((new + 1))
  r="$(rank "$band")"
  if [ "$limit" -gt 0 ] && [ "$r" -ge "$limit" ]; then blocked=$((blocked + 1)); fi
  sev="$band"; [ -z "$score" ] || sev="$band ($score)"
  # shellcheck disable=SC2016  # the backticks are markdown, not a command substitution
  printf '%s\t| `%s` | %s | %s | %s | %s | `%s` |\n' "$r" "${name//|/}" "${ver//|/}" "${eco//|/}" \
    "${ids//,/, }" "$sev" "${lf//|/}" >> "$table"
done < "$rows"

{
  echo "### Dependency check"
  echo
  if [ "$new" -gt 0 ]; then
    echo "**$new new** known vulnerabilities in the lockfiles this pull request changed, and $existing already present at the base commit."
    [ "$limit" -eq 0 ] || echo "Failing on: $fail_on or worse (an unscored advisory counts as high)."
    echo
    echo "| Package | Version | Ecosystem | Advisories | Severity | Lockfile |"
    echo "|---|---|---|---|---|---|"
    sort -t$'\t' -k1,1nr -s "$table" | awk 'NR <= 30' | cut -f2-
    [ "$new" -le 30 ] || echo "| ... and $((new - 30)) more | | | | | |"
  elif [ "$errors" -eq 0 ]; then
    echo "No new known vulnerabilities in $scanned changed lockfile(s). $existing already present at the base commit."
  else
    echo "No new known vulnerabilities in the lockfiles that could be checked. $existing already present at the base commit."
  fi
  if [ "$errors" -gt 0 ]; then
    echo
    echo "**Could not check $errors:**"
    while IFS=$'\t' read -r what why; do echo "- \`$what\`: $why"; done < "$problems"
  fi
} >> "$summary"

# ---- verdict -----------------------------------------------------------------

failed=false
if [ "$blocked" -gt 0 ]; then
  echo "::error::dependency-check: $blocked new vulnerabilities at $fail_on or above (an unscored one counts as high)"
  failed=true
fi
if [ "$errors" -gt 0 ]; then
  if [ "$limit" -eq 0 ]; then
    echo "::warning::dependency-check could not check $errors lockfile(s); fail-on is none, so this does not fail the job"
  else
    echo "::error::dependency-check could not check $errors lockfile(s), so the check did not run to the end; this is not a finding"
    failed=true
  fi
fi

if [ "$failed" = true ]; then
  finish failed "$new" "$existing" "$errors"; exit 1
elif [ "$new" -gt 0 ]; then
  finish findings "$new" "$existing" "$errors"
elif [ "$errors" -gt 0 ]; then
  finish skipped "$new" "$existing" "$errors"   # fail-on none, and nothing could be checked
else
  finish clean "$new" "$existing" "$errors"
fi
