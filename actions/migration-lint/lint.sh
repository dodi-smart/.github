#!/usr/bin/env bash
# Lint the SQL migrations a pull request added or changed with squawk.
#
# Two decisions live here and nowhere else:
#   - WHICH files: only the pull request's added, modified and renamed `*.sql`
#     files under MIGRATIONS_PATH. A migration already applied can never be
#     edited, so linting the whole directory would fail every pull request on
#     history. A list that cannot be trusted (see `complete` in changed-files)
#     lints every `*.sql` under the path instead: doubt means run.
#   - WHAT FAILS: findings fail the job only when BLOCKING is `true`. A lint that
#     could not run (no binary, a crash, output that is not squawk's) always
#     fails it, because a lint that did not run is not a pass.
#
# squawk exits 1 both for findings and for an error (an unreadable file, a bad
# rule name), so the exit code alone cannot tell them apart. This runs it with
# `--reporter json` and trusts "findings" only when stdout is a JSON array that
# agrees with the exit code. It also keeps squawk from printing its own GitHub
# annotations, which are always warnings, so this script can choose the level.
#
# A repo's `.squawk.toml` is found by squawk itself and is never overridden here,
# with one exception squawk defines: `--exclude` replaces the file's
# `excluded_rules` rather than adding to it, so EXCLUDED_RULES, when set, wins.
#
# Env: MIGRATIONS_PATH, EXCLUDED_RULES, BLOCKING, NUMBER (the pull request, empty
# for any other event), CHANGED_FILES_PATH (changed-files'
# `files-path`) or CHANGED_FILES (the list itself), LIST_COMPLETE.
# test.sh sets SQUAWK to a stub; otherwise squawk is installed by install.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

fail() { echo "::error title=Migration lint::$1"; exit 1; }

# Nothing to diff on any event but a pull request, so there is nothing to lint.
if [ -z "${NUMBER:-}" ]; then
  echo "::notice::not a pull request, so there is no diff to lint"
  echo "Migration lint: not a pull request, nothing to lint." >> "$SUMMARY"
  exit 0
fi

path="${MIGRATIONS_PATH:-}"
path="${path#"${path%%[![:space:]]*}"}"; path="${path%"${path##*[![:space:]]}"}"
while [[ "$path" == ./* ]]; do path="${path#./}"; done
while [[ "$path" == */ ]]; do path="${path%/}"; done
[ -n "$path" ] || fail "migrations-path is empty"

# `--exclude` takes squawk's own rule names. Anything else is refused here, so
# a typo fails by name instead of squawk's usage error, and a value starting
# with a dash can never be read as another option.
excluded=""
while IFS= read -r rule || [ -n "$rule" ]; do
  [ -n "$rule" ] || continue
  [[ "$rule" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "'$rule' is not a squawk rule name (lowercase words joined by dashes, separated by commas or spaces)"
  excluded="${excluded:+$excluded,}$rule"
done < <(printf '%s' "${EXCLUDED_RULES:-}" | tr -s '[:space:],' '\n')

files=()
if [ "${LIST_COMPLETE:-false}" = true ]; then
  # A deleted file, and the old name of a renamed one, are in the list but not
  # in the checkout, so the existence test drops them.
  [ -z "${CHANGED_FILES_PATH:-}" ] || CHANGED_FILES=$(<"$CHANGED_FILES_PATH")
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in "$path"/*.sql) ;; *) continue ;; esac
    [ -f "$f" ] || continue
    files+=("$f")
  done <<<"$(printf '%s\n' "${CHANGED_FILES:-}" | sort -u)"
else
  echo "::notice::the pull request's file list could not be trusted (unreadable, empty or cut off at the API's cap), so every .sql file under $path is linted"
  if [ -d "$path" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && files+=("$f")
    done <<<"$(find "$path" -type f -name '*.sql' | sort)"
  fi
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "No added or changed .sql files under $path, nothing to lint."
  echo "Migration lint: no added or changed \`.sql\` files under \`$path\`." >> "$SUMMARY"
  exit 0
fi

command -v jq >/dev/null 2>&1 || fail "jq is not installed, so squawk's report cannot be read"

if [ -z "${SQUAWK:-}" ]; then
  if ! bin=$("$HERE/install.sh"); then
    fail "squawk could not be installed"
  fi
  SQUAWK="$bin/squawk"
fi
[ -x "$SQUAWK" ] || command -v "$SQUAWK" >/dev/null 2>&1 || fail "squawk is not installed"

# squawk reads each argument as a glob, so a file name holding one is escaped.
args=(--reporter json)
[ -z "$excluded" ] || args+=("--exclude=$excluded")
for f in "${files[@]}"; do
  g="${f//\[/[[]}"; g="${g//\*/[*]}"; g="${g//\?/[?]}"
  args+=("$g")
done

echo "Linting ${#files[@]} file(s) with squawk${excluded:+ (excluding $excluded)}:"
printf '  %s\n' "${files[@]}"

err="$(mktemp "${TMPDIR:-/tmp}/squawk-err.XXXXXX")"
trap 'rm -f "$err"' EXIT
rc=0
out=$("$SQUAWK" "${args[@]}" </dev/null 2>"$err") || rc=$?

count=-1
if printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
  count=$(printf '%s' "$out" | jq 'length')
fi
# 0 findings with exit 0, or some with exit 1. Anything else is an error that
# happened to print, or print nothing.
if { [ "$rc" -eq 0 ] && [ "$count" -eq 0 ]; } || { [ "$rc" -eq 1 ] && [ "$count" -gt 0 ]; }; then :
else
  [ ! -s "$err" ] || cat "$err" >&2
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  fail "squawk did not run to completion (exit $rc), so nothing was linted"
fi

if [ "$count" -eq 0 ]; then
  echo "No findings in ${#files[@]} file(s)."
  echo "Migration lint: no findings in ${#files[@]} file(s)." >> "$SUMMARY"
  exit 0
fi

level=warning
[ "${BLOCKING:-false}" != true ] || level=error

# Workflow-command escaping: the message may hold a newline or a percent sign,
# and a property may not hold a colon or a comma. squawk counts lines and
# columns from 0.
printf '%s' "$out" | jq -r --arg level "$level" '
  def esc:  gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
  def escp: esc | gsub(":"; "%3A") | gsub(","; "%2C");
  .[] | "::\($level) file=\(.file | escp),line=\(.line + 1),endLine=\(.line_end + 1),col=\(.column + 1),title=\(.rule_name | escp)::\(.message + (if (.help // "") != "" then " " + .help else "" end) | esc)"'

{
  echo "### Migration lint"
  echo
  echo "$count finding(s) in ${#files[@]} file(s) checked. Rules: <https://squawkhq.com/docs/rules>"
  echo
  echo "| File | Line | Rule | Message |"
  echo "|---|---|---|---|"
  printf '%s' "$out" | jq -r '.[0:200][] | "| `\(.file)` | \(.line + 1) | `\(.rule_name)` | \(.message | gsub("\n"; " ") | gsub("\\|"; "\\|")) |"'
  if [ "$count" -gt 200 ]; then echo; echo "$((count - 200)) more in the job log."; fi
} >> "$SUMMARY"

if [ "$level" = error ]; then
  fail "$count finding(s) in the migrations this pull request changed"
fi
echo "::notice::$count finding(s) are advisory. Set migration-lint-blocking: true to fail the job on them."
exit 0
