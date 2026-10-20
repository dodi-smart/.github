#!/usr/bin/env bash
# Runs hk-check.sh against a stub `hk` on PATH: the arguments it passes, the
# status it returns, what lands in the summary and when it warns about the SARIF.
# A summary that drops the log, or an exit that swallows hk's status, reads as a
# green check on a red tree.
# The backticks in the expected text are markdown, not command substitution.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/hk-check.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hk-check-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

# The stub records its arguments, prints HK_OUT, writes HK_SARIF_BODY to the path
# after --sarif when that is set, and exits HK_EXIT.
mkdir "$WORK/bin"
cat > "$WORK/bin/hk" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$HK_ARGS"
printf '%b' "${HK_OUT:-}"
if [ -n "${HK_SARIF_BODY+x}" ]; then
  while [ $# -gt 0 ]; do
    if [ "$1" = "--sarif" ]; then printf '%s' "$HK_SARIF_BODY" > "$2"; fi
    shift
  done
fi
exit "${HK_EXIT:-0}"
STUB
chmod +x "$WORK/bin/hk"

# The environment for the stub as VAR=value words; a later PATH= wins. With
# KEEP_SUMMARY set the summary is not emptied first. Sets $STATUS, and leaves
# the summary in $SUMMARY, the script's output in $LOG, hk's argv in
# $ARGS and the SARIF path it was given in $SARIF_PATH.
run() {
  SUMMARY="$WORK/summary.md"; LOG="$WORK/log"; ARGS="$WORK/args"
  SARIF_PATH="$WORK/out.sarif"
  [ -n "${KEEP_SUMMARY:-}" ] || : > "$SUMMARY"
  : > "$ARGS"; rm -f "$SARIF_PATH"
  env PATH="$WORK/bin:$PATH" RUNNER_TEMP="$WORK" GITHUB_STEP_SUMMARY="$SUMMARY" \
    HK_ARGS="$ARGS" SARIF="$SARIF_PATH" "$@" "$SCRIPT" > "$LOG" 2>&1
  STATUS=$?
}
has() { grep -qF -- "$1" "$2"; }
# $1 name, then a command that must succeed. $DETAIL says what was seen.
check() {
  local name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name" "${DETAIL:-}"; fi
}
exit_is() { [ "$STATUS" -eq "$1" ]; }
fences() { [ "$(grep -c '^```$' "$SUMMARY")" -eq 2 ]; }
count_x() { [ "$(tr -cd 'x' < "$1" | wc -c | tr -d ' ')" -eq "$2" ]; }

run HK_OUT='all good\n'
DETAIL="got: $(cat "$ARGS")"
check "hk runs check --all --sarif <path>" test "$(cat "$ARGS")" = "check --all --sarif $SARIF_PATH"
check "never --pr" test "$(grep -cF -- '--pr' "$ARGS")" -eq 0
DETAIL="got $STATUS"
check "a clean hk exits 0" exit_is 0

run HK_EXIT=1 HK_OUT='lint failed\n'
DETAIL="got $STATUS"
check "hk's exit 1 is the script's exit" exit_is 1
DETAIL="$(cat "$LOG")"
check "hk's output still reaches the job log" has 'lint failed' "$LOG"
DETAIL="$(cat "$SUMMARY")"
check "a red run still writes the summary heading" has '### hk check --all' "$SUMMARY"
check "the summary holds hk's output" has 'lint failed' "$SUMMARY"
check "the output sits in one fenced block" fences

run HK_EXIT=3 HK_OUT='lint failed\n'
DETAIL="got $STATUS"
check "hk's own status is kept, not flattened to 1" exit_is 3

# Appended, not overwritten: other steps write to the same file.
echo 'earlier step' > "$WORK/summary.md"
KEEP_SUMMARY=1 run HK_OUT='x\n'
DETAIL="$(cat "$SUMMARY")"
check "the summary is appended to" test "$(head -n 1 "$SUMMARY")" = 'earlier step'

ESC="$(printf '\033')"
run HK_OUT='\033[31mred\033[0m and \033[1;32mgreen\033[0m\n'
DETAIL="$(od -c "$SUMMARY" | head -5)"
check "ANSI codes are stripped from the summary" has 'red and green' "$SUMMARY"
check "no escape byte is left in the summary" test "$(grep -c "$ESC" "$SUMMARY")" -eq 0
DETAIL="stripped there too"
check "the job log keeps the colours" has "${ESC}[31mred" "$LOG"

# 60000 bytes in, 50000 in the summary: the cap, with the log left whole.
run HK_OUT="$(head -c 60000 /dev/zero | tr '\0' 'x')\n"
DETAIL="$(wc -c < "$SUMMARY") bytes in the summary"
check "the summary is cut at 50000 bytes" count_x "$SUMMARY" 50000
check "a cut line still closes its fence" fences
check "the job log is not cut" count_x "$LOG" 60000

run HK_OUT='fine\n' HK_SARIF_BODY='{"version":"2.1.0","runs":[]}'
DETAIL="$(cat "$LOG")"
check "valid SARIF does not warn" test "$(grep -c '::warning' "$LOG")" -eq 0
run HK_OUT='fine\n'
check "a missing SARIF does not warn" test "$(grep -c '::warning' "$LOG")" -eq 0
run HK_OUT='fine\n' HK_SARIF_BODY='{"version":"2.1.0","runs":['
check "truncated SARIF warns" has '::warning title=hk wrote invalid SARIF' "$LOG"
DETAIL="got $STATUS"
check "an invalid SARIF alone does not fail the run" exit_is 0
run HK_OUT='fine\n' HK_SARIF_BODY=''
DETAIL="$(cat "$LOG")"
check "an empty SARIF file warns" has '::warning' "$LOG"
run HK_EXIT=2 HK_OUT='bad\n' HK_SARIF_BODY='not json'
DETAIL="status $STATUS, $(cat "$LOG")"
check "a red run with a bad SARIF warns" has '::warning' "$LOG"
check "and keeps hk's status" exit_is 2

# hk itself missing is a failure of the script, never a quiet pass.
run PATH=/usr/bin:/bin
DETAIL="got $STATUS"
check "a runner without hk fails" test "$STATUS" -ne 0

# action.yml: mise writes where `cache-save` says, never by a branch rule of its own.
wiring="$(python3 - "$HERE/action.yml" <<'EOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
mise = [s for s in doc['runs']['steps'] if str(s.get('uses', '')).startswith('jdx/mise-action@')]
given = (mise[0].get('with') or {}) if mise else {}
save = str(given.get('cache_save', ''))
bad = [m for m, broken in (
    ('no jdx/mise-action step', not mise),
    ('no cache-save input', 'cache-save' not in doc.get('inputs', {})),
    ('cache-save does not default to false', str(doc.get('inputs', {}).get('cache-save', {}).get('default')) != 'false'),
    ('cache_save does not read inputs.cache-save', 'inputs.cache-save' not in save),
    ('cache_save does not also need inputs.cache', "inputs.cache == 'true'" not in save),
    ('cache_save restates the default-branch rule', 'github.ref' in save or 'default_branch' in save),
) if broken]
print('; '.join(bad) or 'ok')
EOF
)"
DETAIL="$wiring"
check "mise saves only where cache-save says, and owns no branch rule" test "$wiring" = ok

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
