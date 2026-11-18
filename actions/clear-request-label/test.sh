#!/usr/bin/env bash
# Assert clear.sh's three outcomes: removed, absent (404, silent) and any other
# failure (a ::warning that the request stays on), and that it never fails the
# step. `gh` is a stub that records each call and answers per number from
# STUB_<number>: empty is success, 404 or 403 prints gh's own error and fails.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/clear-request-label-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
expect() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_CALLS"
n=$(sed -n 's|.*/issues/\([0-9]*\)/labels/.*|\1|p' <<<"$*")
var="STUB_$n"
case "${!var:-}" in
  404) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  403) echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

# clear NUMBER LABEL [VAR=value ...]; sets $code, output in $WORK/out
clear() {
  : > "$WORK/calls"
  local n="$1" l="$2"; shift 2
  : > "$WORK/gho"
  env -i PATH="$WORK/bin:$PATH" STUB_CALLS="$WORK/calls" GH_TOKEN=t REPO=o/r GITHUB_OUTPUT="$WORK/gho" \
    NUMBER="$n" LABEL="$l" "$@" "$HERE/clear.sh" > "$WORK/out" 2>&1
  code=$?
}
out()  { grep -qF -- "$1" "$WORK/out"; }
warned() { grep -q '^::warning' "$WORK/out"; }
quiet()  { ! warned; }
called() { grep -qF -- "$1" "$WORK/calls"; }

clear 7 agent:review
expect "success: the step passes"                        test "$code" -eq 0
expect "and the label is deleted, percent-encoded"       called '-X DELETE /repos/o/r/issues/7/labels/agent%3Areview'
expect "and says it was removed"                         out 'removed agent:review from #7'
expect "and warns about nothing"                         quiet

clear 7 agent:review STUB_7=404
expect "404: the step passes"                            test "$code" -eq 0
expect "and says the label was not there"                out 'agent:review was not on #7'
expect "and warns about nothing"                         quiet

clear 7 agent:review STUB_7=403
expect "403: the step still passes"                      test "$code" -eq 0
expect "and warns"                                       warned
expect "that the request stays on"                       out '::warning title=agent:review not removed::#7 keeps agent:review, so the request stays on'
expect "with gh's reason"                                out 'HTTP 403'
expect "and never claims it was removed"                 bash -c '! grep -q "removed agent:review" "$1"' _ "$WORK/out"

clear '7 8 9' agent:iterate STUB_8=403 STUB_9=404
expect "several numbers: each is tried"                  test "$(wc -l < "$WORK/calls")" -eq 3
expect "the first is removed"                            out 'removed agent:iterate from #7'
expect "a failure on one does not stop the next"         out 'agent:iterate was not on #9'
expect "and only the failure warns"                      test "$(grep -c '^::warning' "$WORK/out")" -eq 1
expect "and names its number"                            out '#8 keeps agent:iterate'
expect "the step passes"                                 test "$code" -eq 0
expect "and reports the one still labelled"            grep -qx 'kept=8' "$WORK/gho"

clear 7 agent:review
expect "nothing kept after a removal"                   grep -qx 'kept=' "$WORK/gho"

clear '7 *' agent:review
expect "a stray * is not expanded to file names"        test "$(grep -c 'is not an issue' "$WORK/out")" -eq 1

clear 7 'needs: a/b c'
expect "a slash or space in a label stays in one segment" called '/labels/needs%3A%20a%2Fb%20c'

clear '7 #8' agent:review
expect "a non-number warns"                              out "'#8' is not an issue or pull request number"
expect "and is never sent to the API"                    test "$(wc -l < "$WORK/calls")" -eq 1

clear '' agent:review
expect "no number: calls nothing and passes"            bash -c '[ ! -s "$1" ] && [ "$2" -eq 0 ]' _ "$WORK/calls" "$code"

# The action passes every input through to the script, and defaults the token.
y="$HERE/action.yml"
for v in 'GH_TOKEN: +\$\{\{ inputs\.token \}\}' 'NUMBER: +\$\{\{ inputs\.number \}\}' 'LABEL: +\$\{\{ inputs\.label \}\}' \
         'REPO: +\$\{\{ github\.repository \}\}' 'default: +\$\{\{ github\.token \}\}' '"\$ACTION_PATH/clear\.sh"'; do
  expect "action.yml wires ${v//\\/}" grep -qE -- "$v" "$y"
done

# A tripwire, not enforcement: no workflow or action spells out an `agent:*`
# label removal by hand. A second copy is how the error handling drifted to
# `|| true`. A label held in a variable is not caught. judge-verdict calls clear.sh directly, from inside its sweep loop.
ROOT="$(cd "$HERE/../.." && pwd)"
hand=$(grep -nE -- "--remove-label[ =]*['\"]?agent:|labels/(agent:|agent%3A)" \
         "$ROOT"/.github/workflows/*.yml "$ROOT"/actions/*/*.sh "$ROOT"/actions/*/action.yml 2>/dev/null |
       grep -v -e "/clear-request-label/" | tr "\n" " " || true)
expect "no request label is removed outside this action${hand:+: $hand}" test -z "$hand"
expect "judge-verdict clears through clear.sh" \
  grep -qF '/../clear-request-label/clear.sh"' "$ROOT/actions/judge-verdict/verdict.sh"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
