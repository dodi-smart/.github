#!/usr/bin/env bash
# The test-weakening guard: does a round loosen the checks that judge it?
# An agent whose round is graded by tests, lint and CI can turn red green by
# changing the judge instead of the code. The holdout list freezes the
# acceptance tests by name; this freezes the rest by kind, from the diff alone.
# No model reads anything here.
#
#   guard.sh [--allow ERE] BASE HEAD   every rule below, on `git diff BASE HEAD`
#   guard.sh [--allow ERE] --paths     the gate-file rule only, on paths read
#                                      from stdin (merge mode: what a merge
#                                      resolution changed)
#   guard.sh --rules                   prints TEST_RE, SNAP_RE and GATE_RE, one
#                                      per line: the path rules dirahq-cloud's
#                                      proba copies (factory.ts) and pins by hash
#
# Prints one `path: what` line per finding. Exit 0: nothing found. Exit 1:
# findings. Anything else is a guard that could not run, and a caller refuses
# on any non-zero exit, so a broken guard can only refuse more.
#
# A round is refused when it:
#   - deletes a test file, or renames one to a path that is not a test
#   - deletes a snapshot file, or removes a snapshot entry from one
#   - touches a gate file: a workflow, a composite action, the merge gate,
#     CODEOWNERS, anything under .factory/ (the holdout lists, and the
#     observe-lane declaration that says which credentials are read-only), or
#     lint, format, test-runner, coverage or hook config
#   - changes a test, lint, typecheck or coverage script in a package.json
#   - adds a skip, focus or retry marker to a test (it.skip, .only, xit,
#     @pytest.mark.skip, #[ignore], t.Skip, @Disabled, XCTSkip, skip: true)
#   - removes test cases, assertions, or exact assertions from a test file:
#     each counted on the round's removed lines against its added lines, so a
#     moved or rewritten test nets to zero and a deleted one does not
#
# The counts are per file and by line, so they are a floor, not a parser: a
# changed expected value keeps every count and passes, a `toEqual` turned
# into `toBeTruthy` loses an exact assertion and is refused. A refusal hands
# the PR to a person, who can make the change the guard will not.
#
# --allow ERE exempts matching paths from the gate-file rule, and from no
# other: round 0 passes the issue's own holdout list, which it must write.
#
# Needs: git, grep -E, awk. POSIX classes only, so BSD and GNU tools agree.
set -uo pipefail

ALLOW=''; MODE='diff'
while [ $# -gt 0 ]; do
  case "$1" in
    --allow) ALLOW="$2"; shift 2 ;;
    --paths) MODE=paths; shift ;;
    --rules) MODE=rules; shift ;;
    -h|--help) sed -n '2,/^set /p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) echo "guard.sh: unknown flag $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

# A word boundary BSD and GNU grep both read the same way.
W='(^|[^[:alnum:]_$])'
E='([^[:alnum:]_]|$)'
S='[[:space:]]*'

# A test file, by where it lives or what it is called, in every stack the
# fleet runs. A snapshot is a test file too.
TEST_RE='(^|/)(tests?|__tests__|specs?|e2e|integration_test|androidTest|testFixtures|[A-Za-z0-9]+Tests)/|[._-](test|spec)s?\.[A-Za-z0-9]+$|(^|/)test_[^/]*\.py$|(Test|Tests|Spec)\.(kt|kts|java|swift|scala|cs)$|(^|/)test\.(sh|bash)$'
SNAP_RE='(^|/)__snapshots__/|\.snap$|(^|/)__screenshots__/|-snapshots/'

# A gate file: what decides whether a round is green, or who must look.
GATE_RE=$(printf '%s|' \
  '(^|/)\.github/(workflows|actions)/' \
  '(^|/)\.github/j?actionlint\.ya?ml$' \
  '(^|/)merge-gate/' \
  '(^|/)CODEOWNERS$' \
  '(^|/)\.factory/' \
  '(^|/)\.zavet/(check\.sh|config|bin/)' \
  '(^|/)(eslint\.config\.[cm]?[jt]s|\.eslintrc(\.[a-z]+)?|\.eslintignore|biome\.jsonc?|\.oxlintrc\.json|oxlint\.json)$' \
  '(^|/)(\.prettierrc(\.[a-z]+)?|prettier\.config\.[cm]?js|\.prettierignore|\.stylelintrc(\.[a-z]+)?|stylelint\.config\.[cm]?js)$' \
  '(^|/)(hk\.pkl|lefthook\.ya?ml|\.pre-commit-config\.ya?ml|commitlint\.config\.[cm]?[jt]s|\.commitlintrc(\.[a-z]+)?)$' \
  '(^|/)\.husky/' \
  '(^|/)(\.?clippy\.toml|\.?rustfmt\.toml|deny\.toml|[._]?typos\.toml)$' \
  '(^|/)(\.golangci\.ya?ml|\.?ruff\.toml|\.flake8|mypy\.ini|\.pylintrc|pytest\.ini|tox\.ini|\.coveragerc)$' \
  '(^|/)(analysis_options\.yaml|detekt\.ya?ml|lint\.xml|\.swiftlint\.ya?ml|\.swiftformat)$' \
  '(^|/)(jest|vitest|playwright)\.config\.[cm]?[jt]s$' \
  '(^|/)(vitest\.workspace\.[cm]?[jt]s|karma\.conf\.[cm]?js|\.mocharc(\.[a-z]+)?|\.nycrc(\.[a-z]+)?|\.c8rc(\.[a-z]+)?|\.?codecov\.ya?ml)$')
GATE_RE=${GATE_RE%|}

# package.json script keys that run a check.
SCRIPT_RE="^[+-]$S\"(test|lint|check|typecheck|type-check|coverage|format:check|ci)[^\"]*\"$S:"

# Markers that switch a test off, focus a run on one (which switches the
# rest off), or retry until it passes.
SKIP_RE=$(printf '%s|' \
  "$W(it|test|describe|context|suite|bench|scenario)\.(skip|only|todo|fixme|skipIf|runIf)$E" \
  "$W(xit|xtest|xdescribe|xcontext|fit|fdescribe|fcontext)$S\(" \
  "\.only$S\(" \
  '@pytest\.mark\.(skip|skipif|xfail|flaky)' \
  "${W}pytest\.skip$S\(" \
  '@unittest\.(skip|skipIf|skipUnless|expectedFailure)' \
  '#\[ignore' \
  "${W}t\.Skip(f|Now)?$S\(" \
  "@(Ignore|Disabled|Flaky)$E" \
  'XCTSkip' \
  "\.disabled$S\(" \
  "${W}skip:$S(true|['\"])" \
  "${W}markTestSkipped$S\(" \
  "\.retryTimes$S\(" \
  "${W}retries${S}[(:=]")
SKIP_RE=${SKIP_RE%|}

# A test case being declared. `it.skip(` is not one, so a test turned off
# also counts as a test removed.
DECL_RE=$(printf '%s|' \
  "$W(it|test|bench)(\.(each|concurrent|serial|sequential)[^(]*)?$S\(${S}['\"\`]" \
  "^$S(async$S)?def${S}test_" \
  "^${S}func${S}[Tt]est[A-Z_]" \
  '#\[([a-z_]+::)?test[]( ]' \
  '#\[rstest' \
  "@Test$E" \
  "${W}testWidgets$S\(")
DECL_RE=${DECL_RE%|}

# Any assertion, and the exact ones: a value compared, a call checked, a
# snapshot matched. A loosened assertion keeps the first count and loses the second.
ASSERT_RE=$(printf '%s|' \
  "${W}expect$S\(" \
  "${W}assert[A-Za-z_]*!?$S\(" \
  "${W}assert[[:space:]]+[^[:space:]]" \
  "${W}XCTAssert[A-Za-z]*$S\(" \
  "\.should$E" \
  "${W}require\.[A-Z][A-Za-z]*$S\(" \
  "${W}t\.(Error|Errorf|Fatal|Fatalf|Fail|FailNow)$S\(" \
  "#(expect|require)$S\(")
ASSERT_RE=${ASSERT_RE%|}
STRICT_RE=$(printf '%s|' \
  "\.(toBe|toEqual|toStrictEqual|toMatchSnapshot|toMatchInlineSnapshot|toHaveBeenCalledWith|toHaveBeenNthCalledWith|toHaveBeenCalledTimes|toThrow|toThrowError|toHaveLength|toMatchObject|toContainEqual|toHaveProperty|toBeCloseTo)$S\(" \
  "${W}assert_(eq|ne|matches)!" \
  "${W}assert(Equals|NotEquals|Same|NotSame|ArrayEquals|Throws|Equal|NotEqual|Raises|Is|IsNot|In|NotIn)$S\(" \
  "${W}XCTAssert(Equal|NotEqual|Identical|NotIdentical|Throws[A-Za-z]*)$S\(" \
  "${W}assert[[:space:]][^=]*(==|!=|[[:space:]](is|in)[[:space:]])" \
  "${W}(equals|isA|throwsA|same)$S\(" \
  "${W}is(Equal|EqualTo)$S\(" \
  "#expect$S\([^)]*(==|!=)")
STRICT_RE=${STRICT_RE%|}

SNAP_ENTRY_RE='^exports\['

found=0
hit() { printf '%s: %s\n' "$1" "$2"; found=1; }
# Bash's own ERE match: a path is judged without a subprocess.
is() { [[ $2 =~ $1 ]]; }
gate_check() { { [ -n "$ALLOW" ] && is "$ALLOW" "$1"; } || ! is "$GATE_RE" "$1" || hit "$1" "touches a gate file"; }

if [ "$MODE" = rules ]; then
  printf '%s\n' "$TEST_RE" "$SNAP_RE" "$GATE_RE"
  exit 0
fi

if [ "$MODE" = paths ]; then
  while IFS= read -r p; do [ -n "$p" ] && gate_check "$p"; done
  exit "$found"
fi

[ $# -eq 2 ] || { echo "usage: guard.sh [--allow ERE] BASE HEAD | guard.sh [--allow ERE] --paths" >&2; exit 2; }
BASE="$1"; HEAD="$2"
if ! git rev-parse -q --verify "$BASE^{commit}" >/dev/null || ! git rev-parse -q --verify "$HEAD^{commit}" >/dev/null; then
  echo "guard.sh: cannot resolve $BASE or $HEAD" >&2; exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/guard.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT

# Paths, with renames found, so a moved test is judged by where it went.
git -c core.quotePath=false diff -M --name-status "$BASE" "$HEAD" > "$work/status" || exit 2
deleted=$'\n'
while IFS=$'\t' read -r st a b; do
  [ -n "$st" ] || continue
  case "$st" in
    D)
      deleted="$deleted$a"$'\n'
      if is "$SNAP_RE" "$a"; then hit "$a" "deletes a snapshot"
      elif is "$TEST_RE" "$a"; then hit "$a" "deletes a test file"
      fi
      gate_check "$a" ;;
    R*)
      if is "$TEST_RE" "$a" && ! is "$TEST_RE" "$b"; then hit "$a" "renames a test file to $b, which is not a test path"; fi
      gate_check "$a"; gate_check "$b" ;;
    *)
      gate_check "$a" ;;
  esac
done < "$work/status"

# Every changed line, by the file it is in now. Headers come before a file's
# first @@ and never after it, so a removed line that starts with `--` is
# still content.
git -c core.quotePath=false diff -M --unified=0 --no-color --no-ext-diff "$BASE" "$HEAD" > "$work/diff" || exit 2
mkdir -p "$work/f"
awk -v dir="$work/f" '
  /^diff --git / { inhunk = 0; path = ""; next }
  !inhunk && /^\+\+\+ / { p = substr($0, 5); if (p != "/dev/null") { sub(/^b\//, "", p); path = p }; next }
  !inhunk && /^--- / { p = substr($0, 5); if (p != "/dev/null") { sub(/^a\//, "", p); path = p }; next }
  /^@@/ { inhunk = 1; if (!(path in id)) { id[path] = ++n; print path > (dir "/" n ".path") }; next }
  inhunk && /^\+/ { print substr($0, 2) > (dir "/" id[path] ".add"); next }
  inhunk && /^-/  { print substr($0, 2) > (dir "/" id[path] ".del"); next }
' "$work/diff" || exit 2

count() { local c=0; [ -f "$2" ] && c=$(grep -cE "$1" "$2"); echo "${c:-0}"; }
net() { echo $(( $(count "$1" "$2.add") - $(count "$1" "$2.del") )); }

for pf in "$work"/f/*.path; do
  [ -e "$pf" ] || break
  f=${pf%.path}; read -r p < "$pf"
  # A deleted file was judged whole above.
  [[ $deleted == *$'\n'"$p"$'\n'* ]] && continue
  if [ "${p##*/}" = package.json ]; then
    if cat "$f.add" "$f.del" 2>/dev/null | sed 's/^/+/' | grep -qE "$SCRIPT_RE"; then
      hit "$p" "changes a test, lint or check script"
    fi
  fi
  if is "$SNAP_RE" "$p"; then
    [ "$(net "$SNAP_ENTRY_RE" "$f")" -ge 0 ] || hit "$p" "removes a snapshot entry"
    continue
  fi
  # Rust keeps unit tests beside the code, so a .rs file is read for markers
  # and test cases wherever it lives; assertions only in a test path.
  is "$TEST_RE" "$p" || is '\.rs$' "$p" || continue
  [ "$(net "$SKIP_RE" "$f")" -le 0 ] || hit "$p" "adds a skip, focus or retry marker"
  [ "$(net "$DECL_RE" "$f")" -ge 0 ] || hit "$p" "removes a test case"
  is "$TEST_RE" "$p" || continue
  [ "$(net "$ASSERT_RE" "$f")" -ge 0 ] || hit "$p" "removes an assertion"
  [ "$(net "$STRICT_RE" "$f")" -ge 0 ] || hit "$p" "loosens an exact assertion"
done

exit "$found"
