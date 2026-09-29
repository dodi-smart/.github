#!/usr/bin/env bash
# Assert what a caller relies on: phases run in order, each in its own subshell,
# the first failure stops the rest, an empty phase is skipped, and a command with
# several lines, quotes or `$` in it runs exactly as written. The phases are fake
# commands that write marker files, so nothing here needs a toolchain.
#
# The commands are single-quoted on purpose: they must reach the script unexpanded.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/run-phases.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/run-phases-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
W="$WORK/w"
pass=0; fail=0

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (rc=%s)\n' "$1" "$RC"; fail=$((fail + 1)); }

# expect NAME COMMAND...: passes when the command succeeds.
expect() {
  local name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

# Runs the script in a fresh directory with only the given environment. Sets RC,
# and leaves the summary in $WORK/summary and the log in $WORK/log.
RC=0
run() {
  rm -rf "$W"; mkdir "$W"; : > "$WORK/summary"; : > "$WORK/output"
  ( cd "$W" && env -i PATH="$PATH" HOME="$HOME" GITHUB_STEP_SUMMARY="$WORK/summary" GITHUB_OUTPUT="$WORK/output" "$@" "$SCRIPT" ) > "$WORK/log" 2>&1
  RC=$?
}

row()     { grep -qE "^\| $1 \| $2 \| ([0-9]+|-) \|$" "$WORK/summary"; }
no_row()  { ! grep -qE "^\| $1 \|" "$WORK/summary"; }
exists()  { [ -e "$W/$1" ]; }
absent()  { [ ! -e "$W/$1" ]; }
holds()   { [ "$(tr '\n' ' ' < "$W/$1")" = "$2" ]; }
logged()  { grep -qF -- "$1" "$WORK/log"; }

echo 'export FROM_ENV=plain' > "$WORK/env.sh"
echo 'export FROM_ENV=build' > "$WORK/build-env.sh"

# 1. Everything passes, in order, and every phase is timed.
run PHASE_INSTALL='echo i >> order' PHASE_LINT='echo l >> order' PHASE_TEST='echo t >> order'
expect "a passing run exits 0" [ "$RC" -eq 0 ]
expect "phases run in the fixed order" holds order 'i l t '
expect "summary has the header" grep -qxF '| phase | result | seconds |' "$WORK/summary"
expect "summary has the install row" row install passed
expect "summary has the lint row" row lint passed
expect "summary has the test row" row test passed
expect "each phase is a log group" logged '::group::install: echo i >> order'

# 2. An empty phase is skipped and never runs.
run PHASE_INSTALL='' PHASE_LINT='touch lint-ran' PHASE_TYPECHECK='   '
expect "empty and blank phases skip and the run passes" [ "$RC" -eq 0 ]
expect "the phase that has a command runs" exists lint-ran
expect "an empty phase has no row" no_row install
expect "a blank phase has no row" no_row typecheck

# 3. The first failure stops the run, and the rest are reported, not run.
run PHASE_INSTALL='touch i' PHASE_LINT='exit 3' PHASE_TYPECHECK='touch typecheck-ran' PHASE_TEST='touch test-ran'
expect "a failed phase fails the run" [ "$RC" -ne 0 ]
expect "the typecheck after it never runs" absent typecheck-ran
expect "the test after it never runs" absent test-ran
expect "the phase before it passed" row install passed
expect "the failed phase reports its exit code" row lint 'failed \(exit 3\)'
expect "a later phase is listed as not run" row typecheck 'not run'
expect "every later phase is listed" row test 'not run'

# 4. Inside one command, `-e` still applies.
run PHASE_LINT=$'false\ntouch after-false'
expect "a failing line stops its own command" absent after-false
expect "and fails the phase" [ "$RC" -ne 0 ]
run PHASE_LINT='false | cat; touch after-pipe' PHASE_TEST='touch never'
expect "a failed pipeline fails the phase" [ "$RC" -ne 0 ]
expect "and the next phase never runs" absent never

# 5. A multi-line command runs every line.
run PHASE_LINT=$'echo one > multi\necho two >> multi\nif true; then\n  echo three >> multi\nfi'
expect "a multi-line command runs whole" holds multi 'one two three '
expect "its group title stays one line" logged '::group::lint: echo one > multi ...'

# 6. Quotes and `$` in a command mean what they mean in a script.
run PHASE_LINT="printf '%s|' \"it's\" '\$literal' \"\$((1 + 2))\" > quoted"
expect "quotes and dollars are not mangled" [ "$(cat "$W/quoted")" = "it's|\$literal|3|" ]
run PHASE_LINT='touch "a b" && echo "$(pwd)" > cwd'
expect "a command can quote and substitute" exists 'a b'

# 7. Each phase gets its own subshell: nothing carries to the next one.
run PHASE_INSTALL='mkdir sub && cd sub && export LEAK=1' PHASE_LINT='pwd > where; echo "${LEAK:-unset}" > leak'
expect "a cd does not carry to the next phase" [ "$(cat "$W/where")" = "$(cd "$W" && pwd -P)" ]
expect "an export does not carry to the next phase" holds leak 'unset '

# 8. The env file is sourced first, and `build` takes its own.
run ENV_FILE="$WORK/env.sh" BUILD_ENV_FILE="$WORK/build-env.sh" \
    PHASE_LINT='echo "$FROM_ENV" > lint-env' PHASE_BUILD='echo "$FROM_ENV" > build-env'
expect "a phase sources env-file" holds lint-env 'plain '
expect "build sources build-env-file" holds build-env 'build '
run ENV_FILE="$WORK/env.sh" PHASE_BUILD='echo "$FROM_ENV" > build-env'
expect "build falls back to env-file" holds build-env 'plain '
run PHASE_LINT='echo "${FROM_ENV:-none}" > lint-env'
expect "no env file sources nothing" holds lint-env 'none '

# 9. Nothing to run is a pass with no table.
run PHASE_LINT=''
expect "no phases exits 0" [ "$RC" -eq 0 ]
expect "no phases writes no table" [ ! -s "$WORK/summary" ]

# 10. A command's own output reaches the log.
run PHASE_LINT='echo visible-output'
expect "command output reaches the log" logged visible-output

# 11. `smoke` runs last, after build, and is stopped by an earlier failure.
run PHASE_SMOKE='echo s >> order' PHASE_BUILD='echo b >> order' PHASE_TEST='echo t >> order'
expect "smoke runs after build" holds order 't b s '
run PHASE_BUILD='exit 1' PHASE_SMOKE='touch smoke-ran'
expect "a failed build stops smoke" absent smoke-ran

# 12. `failed` lists the failed phases, in order, and is empty on a pass.
run PHASE_LINT='true'
expect "a pass reports an empty failed" grep -qxF 'failed=' "$WORK/output"
run PHASE_LINT='exit 1' PHASE_TEST='true'
expect "a stop reports the one failed phase" grep -qxF 'failed=lint' "$WORK/output"

# 13. keep-going runs every phase and reports all the failures.
run KEEP_GOING=true PHASE_INSTALL='exit 1' PHASE_TYPECHECK='touch typecheck-ran' PHASE_TEST='exit 2' PHASE_SMOKE='touch smoke-ran'
expect "keep-going still fails the run" [ "$RC" -ne 0 ]
expect "keep-going runs the phase after a failure" exists typecheck-ran
expect "keep-going runs smoke after a failed test" exists smoke-ran
expect "keep-going lists every failed phase" grep -qxF 'failed=install test' "$WORK/output"
expect "keep-going marks no phase not run" row typecheck passed
run KEEP_GOING=false PHASE_INSTALL='exit 1' PHASE_TEST='touch test-ran'
expect "keep-going false still stops" absent test-ran

# 14. log-dir keeps each phase's full output, and the log still shows it too.
run LOG_DIR="$W/logs" PHASE_INSTALL='echo from-install' PHASE_TEST=$'echo from-test\nexit 4'
expect "log-dir gets one file per phase" holds logs/install.log 'from-install '
expect "a failed phase is logged in full" holds logs/test.log 'from-test '
expect "the job log still shows the output" logged from-install
expect "log-dir keeps the exit code" row test 'failed \(exit 4\)'

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
