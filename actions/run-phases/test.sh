#!/usr/bin/env bash
# Assert what a caller relies on: phases run in order, each in its own subshell,
# the first failure stops the rest, an empty phase is skipped, and a command with
# several lines, quotes or `$` in it runs exactly as written. The phases are fake
# commands that write marker files, so nothing here needs a toolchain.
#
# Peak memory is tested against fakes of everything it reads: a memory.peak in a
# temp dir with a fake /proc/self/cgroup, and one stand-in for GNU and BSD time.
# A real run of whatever this machine has comes last, and skips if it has nothing.
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
  ( cd "$W" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" GITHUB_STEP_SUMMARY="$WORK/summary" GITHUB_OUTPUT="$WORK/output" "$@" "$SCRIPT" ) > "$WORK/log" 2>&1
  RC=$?
}

row()     { grep -qE "^\| $1 \| $2 \| ([0-9]+|-) \| ${3:-[^|]+} \|$" "$WORK/summary"; }
no_row()  { ! grep -qE "^\| $1 \|" "$WORK/summary"; }
exists()  { [ -e "$W/$1" ]; }
absent()  { [ ! -e "$W/$1" ]; }
holds()   { [ "$(tr '\n' ' ' < "$W/$1")" = "$2" ]; }
logged()  { grep -qF -- "$1" "$WORK/log"; }
output_is() { grep -qxF -- "$1" "$WORK/output"; }
summary_has() { grep -qF -- "$1" "$WORK/summary"; }

echo 'export FROM_ENV=plain' > "$WORK/env.sh"
echo 'export FROM_ENV=build' > "$WORK/build-env.sh"

# 1. Everything passes, in order, and every phase is timed.
run PHASE_INSTALL='echo i >> order' PHASE_LINT='echo l >> order' PHASE_TEST='echo t >> order'
expect "a passing run exits 0" [ "$RC" -eq 0 ]
expect "phases run in the fixed order" holds order 'i l t '
expect "summary has the header" grep -qxF '| phase | result | seconds | peak memory |' "$WORK/summary"
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


# --- peak memory -------------------------------------------------------------

skip()     { printf '  skip %s\n' "$1"; }
no_upper() { ! grep -qE '\| <= ' "$WORK/summary"; }
lacks()    { ! summary_has "$1"; }

# A fake job cgroup: /proc/self/cgroup names /job, and its memory.peak holds a
# value (1000 MiB unless given), the old maximum a long-lived container keeps.
PEAK="$WORK/cg/job/memory.peak"
fake_cgroup() {
  rm -rf "$WORK/cg"; mkdir -p "$WORK/cg/job"
  echo "${1:-1048576000}" > "$PEAK"
  echo '0::/job' > "$WORK/proc-cgroup"
}
mkdir "$WORK/empty" "$WORK/bin"
CG=(RUN_PHASES_CGROUP_ROOT="$WORK/cg" RUN_PHASES_PROC_CGROUP="$WORK/proc-cgroup" RUN_PHASES_TIME_BIN=/nonexistent PEAK="$PEAK")
NO_CG=(RUN_PHASES_CGROUP_ROOT="$WORK/empty" RUN_PHASES_PROC_CGROUP=/nonexistent)

# cg START ENV...: a fresh fake cgroup holding START bytes, then a run in it.
cg() { fake_cgroup "$1"; shift; run "${CG[@]}" "$@"; }

# One stand-in for time. FLAVOR=gnu takes `-f FMT -o FILE COMMAND` and writes
# kibibytes, with a line first when the command failed. FLAVOR=bsd takes `-l -o
# FILE COMMAND` and writes bytes in the middle of a longer report. Each refuses
# the other's flags, as the real ones do. Any other FLAVOR fails outright.
cat > "$WORK/bin/time" <<'STUB'
#!/usr/bin/env bash
case "${FLAVOR:-}" in
  gnu)
    { [ "$1" = -f ] && [ "$3" = -o ]; } || { echo "time: unknown option" >&2; exit 1; }
    out="$4"; shift 4 ;;
  bsd)
    { [ "$1" = -l ] && [ "$2" = -o ]; } || { echo "time: illegal option" >&2; exit 1; }
    out="$3"; shift 3 ;;
  *) exit 1 ;;
esac
"$@"; rc=$?
if [ "$FLAVOR" = gnu ]; then
  { [ "$rc" -eq 0 ] || echo "Command exited with non-zero status $rc"; echo "${FAKE_KB:-1}"; } > "$out"
else
  printf '        0.01 real         0.00 user         0.00 sys\n %s  maximum resident set size\n       100  page reclaims\n' "${FAKE_BYTES:-1}" > "$out"
fi
exit "$rc"
STUB
chmod +x "$WORK/bin/time"
GNU=(RUN_PHASES_TIME_BIN="$WORK/bin/time" FLAVOR=gnu "${NO_CG[@]}")
BSD=(RUN_PHASES_TIME_BIN="$WORK/bin/time" FLAVOR=bsd "${NO_CG[@]}")

# 15. A rise in memory.peak during a phase is that phase's peak. The file starts
# at 100 MiB, and the script only reads it.
cg 104857600 PHASE_LINT='cat "$PEAK" > seen; echo 314572800 > "$PEAK"' PHASE_TEST='echo 1610612736 > "$PEAK"'
expect "a run with a cgroup exits 0" [ "$RC" -eq 0 ]
expect "memory.peak is left as it was" holds seen '104857600 '
expect "a rise is the phase's peak in MiB" row lint passed '300 MiB'
expect "a rise above 1024 MiB reads in GiB" row test passed '1\.5 GiB'
expect "peak-rss is the largest phase in whole MiB" output_is 'peak-rss=1536'
expect "a rise is plain, not an upper bound" no_upper
expect "the footnote is under the table" summary_has 'Peak memory:'
expect "the log names the sources" logged "peak memory: cgroup=$PEAK time=none"

# The path in /proc/self/cgroup is not under the root in a container: the
# container's own cgroup is the root.
fake_cgroup 104857600; mv "$PEAK" "$WORK/cg/memory.peak"; echo '0::/gone' > "$WORK/proc-cgroup"
run "${CG[@]}" PEAK="$WORK/cg/memory.peak" PHASE_LINT='echo 314572800 > "$PEAK"'
expect "a memory.peak at the cgroup root is found" row lint passed '300 MiB'

# 16. No rise, but time is there: time's figure. A phase that rose still uses the
# cgroup's. The file starts at 1000 MiB, an old maximum, so most phases do not rise.
cg "" RUN_PHASES_TIME_BIN="$WORK/bin/time" FLAVOR=gnu FAKE_KB=204800 PHASE_LINT='true' PHASE_TEST='echo 1258291200 > "$PEAK"' PHASE_BUILD='true'
expect "a phase that did not rise uses time's figure" row lint passed '200 MiB'
expect "a phase that rose still uses the cgroup's" row test passed '1\.2 GiB'
expect "and the next phase, with no rise on top of that, uses time again" row build passed '200 MiB'
expect "no phase is an upper bound" no_upper
expect "peak-rss is the largest plain figure" output_is 'peak-rss=1200'
expect "the log names both sources" logged "peak memory: cgroup=$PEAK time=gnu"

# 16b. No rise and no time: an upper bound, and not in peak-rss.
cg "" PHASE_LINT='true' PHASE_TEST='true'
expect "the old maximum is shown as an upper bound" row lint passed '<= 1000 MiB'
expect "for every phase that did not rise" row test passed '<= 1000 MiB'
expect "an upper bound is not a peak-rss" output_is 'peak-rss='
expect "the footnote explains the marker" summary_has 'the phase did not raise the cgroup'
cg "" PHASE_LINT='echo 1258291200 > "$PEAK"' PHASE_TEST='true'
expect "a rise is plain beside an upper bound" row lint passed '1\.2 GiB'
expect "the phase after it is an upper bound at the new maximum" row test passed '<= 1\.2 GiB'
expect "peak-rss is the plain one only" output_is 'peak-rss=1200'

# 17. Without a cgroup, time's report is the peak of the largest process.
run "${GNU[@]}" FAKE_KB=204800 KEEP_GOING=true PHASE_INSTALL='echo x >> order' PHASE_LINT='exit 3' PHASE_TEST='echo hello'
expect "GNU time: the figure is converted from KiB" row install passed '200 MiB'
expect "GNU time: a failed phase has a figure and keeps its exit code" row lint 'failed \(exit 3\)' '200 MiB'
expect "GNU time: the phase runs once, not once more for a probe" holds order 'x '
expect "GNU time: peak-rss is the largest phase" output_is 'peak-rss=200'
expect "GNU time: its report stays out of the log" [ "$(grep -c 'Command exited' "$WORK/log")" -eq 0 ]
expect "GNU time: the phase's own output is intact" logged hello
expect "GNU time: the log names the source" logged 'peak memory: cgroup=none time=gnu'
expect "GNU time: the footnote is there" summary_has 'Peak memory:'
run "${BSD[@]}" FAKE_BYTES=314572800 PHASE_INSTALL='echo x >> order' PHASE_LINT='exit 5'
expect "BSD time: the figure is read in bytes" row install passed '300 MiB'
expect "BSD time: a failed phase keeps its exit code" row lint 'failed \(exit 5\)'
expect "BSD time: peak-rss is in MiB" output_is 'peak-rss=300'
expect "BSD time: the phase runs once" holds order 'x '
run RUN_PHASES_TIME_BIN="$WORK/bin/time" FLAVOR=bad "${NO_CG[@]}" PHASE_LINT='echo ok > ran'
expect "a time that fails its probe is not used" row lint passed '-'
expect "and the phase still runs" holds ran 'ok '

# The script's output only reaches a caller if the action passes it on.
expect "the action exposes peak-rss" grep -qF 'steps.run.outputs.peak-rss' "$HERE/action.yml"

# 18. With nothing to measure with, the cell is `-` and nothing fails.
run RUN_PHASES_TIME_BIN=/nonexistent "${NO_CG[@]}" PHASE_INSTALL='true' PHASE_LINT='exit 2' PHASE_TEST='true'
expect "an unmeasured passing phase shows -" row install passed '-'
expect "an unmeasured failing phase keeps its exit code" row lint 'failed \(exit 2\)' '-'
expect "a phase that did not run shows -" row test 'not run' '-'
expect "peak-rss is empty when nothing was measured" output_is 'peak-rss='
expect "no footnote without a figure" lacks 'Peak memory:'
expect "the log says there is no source" logged 'peak memory: cgroup=none time=none'

# 19. Measuring changes neither a phase's exit code, nor what stops the run, nor
# what lands in the phase's log file.
for m in cgroup gnu bsd; do
  case "$m" in
    cgroup) fake_cgroup; mode=("${CG[@]}") ;;
    gnu) mode=("${GNU[@]}" FAKE_KB=1024) ;;
    bsd) mode=("${BSD[@]}" FAKE_BYTES=1048576) ;;
  esac
  run "${mode[@]}" LOG_DIR="$W/logs" PHASE_INSTALL='echo from-install' PHASE_TEST=$'echo from-test\nexit 4' PHASE_BUILD='touch build-ran'
  expect "$m: the exit code is the phase's own" row test 'failed \(exit 4\)'
  expect "$m: the run still stops at the failure" absent build-ran
  expect "$m: a passing phase's log is only its output" holds logs/install.log 'from-install '
  expect "$m: a failing phase's log is only its output" holds logs/test.log 'from-test '
done

# 20. Whatever this machine has, run for real: a phase that holds ~250 MiB must
# not read as less than 100 MiB. Skips where neither time nor a cgroup is usable.
at_least() { # PHASE MIB
  local cell
  cell="$(awk -F'|' -v n=" $1 " '$2 == n { print $5 }' "$WORK/summary" | sed 's/^ *//; s/^<= *//; s/ *$//')"
  case "$cell" in
    *GiB) return 0 ;;
    *MiB) [ "${cell% MiB}" -ge "$2" ] ;;
    *) return 1 ;;
  esac
}
run PHASE_LINT='x=a; i=0; while [ "$i" -lt 27 ]; do x=$x$x; i=$((i + 1)); done'
if logged 'peak memory: cgroup=none time=none'; then
  skip "real measurement: nothing usable on this machine"
else
  expect "the real source sees a phase that holds ~250 MiB" at_least lint 100
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
