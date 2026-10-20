#!/usr/bin/env bash
# Run a job's command phases in order, each in its own shell, and leave a
# `| phase | result | seconds | peak memory |` table in the job summary.
#
# Reads its inputs from the environment: ENV_FILE and BUILD_ENV_FILE (sourced
# before a phase; `build` takes BUILD_ENV_FILE, every other phase ENV_FILE) and
# one PHASE_<NAME> command per phase, `-` written as `_`. An empty command means
# the repo has no such step. The order is fixed: install, lint, design-lint,
# typecheck, test, build, smoke.
#
# LOG_DIR, when set, also writes each phase's full output to LOG_DIR/<phase>.log,
# for a reader that diagnoses from the log. KEEP_GOING=true runs every phase
# instead of stopping at the first failure. Either way the failed phases go to
# $GITHUB_OUTPUT as `failed`, space-separated.
#
# Each phase's peak memory goes in the table and, as the largest plain figure in
# whole MiB, to $GITHUB_OUTPUT as `peak-rss` (empty when there is none), so a
# caller can tell whether its test or build needs a heavy runner. It is read from
# the job cgroup's memory.peak and from /usr/bin/time; the order is in the README.
# Measuring never changes a phase's exit code or its output. test.sh fakes the
# inputs with RUN_PHASES_CGROUP_ROOT (/sys/fs/cgroup), RUN_PHASES_PROC_CGROUP
# (/proc/self/cgroup) and RUN_PHASES_TIME_BIN (/usr/bin/time).
#
# The commands reach `eval` through the environment, never through the script
# text, so a quote or a `$` in one cannot change what this script does.
set -uo pipefail

PHASES="install lint design-lint typecheck test build smoke"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
cg_root="${RUN_PHASES_CGROUP_ROOT:-/sys/fs/cgroup}"
proc_cgroup="${RUN_PHASES_PROC_CGROUP:-/proc/self/cgroup}"
time_bin="${RUN_PHASES_TIME_BIN:-/usr/bin/time}"

rows=""
failed=""
status=0
[ -z "${LOG_DIR:-}" ] || mkdir -p "$LOG_DIR"

# What a phase runs in: a child bash, so /usr/bin/time can wrap it. The command
# and the env file arrive in the environment, never in this text.
# shellcheck disable=SC2016 # single-quoted on purpose: the child expands it
RUNNER='set -euo pipefail
if [ -n "$RUN_PHASES_ENV_FILE" ]; then
  . "$RUN_PHASES_ENV_FILE"
fi
eval "$RUN_PHASES_CMD"'
runner=("$BASH" -c "$RUNNER")

FOOTNOTE="Peak memory: the job cgroup's memory.peak when it rose during the phase, else /usr/bin/time's largest single process; \`<=\` is an upper bound (the phase did not raise the cgroup's peak)."

# --- peak memory -------------------------------------------------------------
peak_file=""   # the job's cgroup v2 memory.peak, when it is readable
time_flavor="" # gnu or bsd, when /usr/bin/time is usable; every phase then runs under it
tmp=""
before=""      # memory.peak right before the phase
upper=0        # this phase's figure is an upper bound
any_fig=0
max_bytes=""

is_number() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# memory.peak of $1 into peak_now, empty when unreadable. No fork.
read_peak() {
  peak_now=""
  { IFS= read -r peak_now < "$1"; } 2> /dev/null || :
}

cgroup_path=""
if [ -r "$proc_cgroup" ]; then
  while IFS= read -r line; do
    case "$line" in 0::*) cgroup_path="${line#0::}"; break ;; esac
  done < "$proc_cgroup"
fi
# That path is relative to the cgroup root, but a container with its own cgroup
# namespace has its own cgroup mounted as the root.
for cand in "$cg_root$cgroup_path/memory.peak" "$cg_root/memory.peak"; do
  read_peak "$cand"
  if is_number "$peak_now"; then
    peak_file="$cand"
    break
  fi
done

# The resident set in a time report ($1 the flavor, $2 the file) into
# report_bytes. Fails, with it empty, when there is none.
time_report() {
  local line n="" rest
  report_bytes=""
  [ -r "$2" ] || return 1
  case "$1" in
    gnu) # KiB, on the last all-digit line: a failed command adds a "Command exited" line before it
      while IFS= read -r line; do
        case "$line" in '' | *[!0-9]*) ;; *) n="$line" ;; esac
      done < "$2"
      ! is_number "$n" || report_bytes=$((n * 1024))
      ;;
    bsd) # bytes, in the middle of a longer report
      while read -r n rest; do
        if [ "$rest" = "maximum resident set size" ] && is_number "$n"; then
          report_bytes="$n"
          break
        fi
      done < "$2"
      ;;
  esac
  [ -n "$report_bytes" ]
}

# Without a template, BSD mktemp ignores TMPDIR.
if [ -x "$time_bin" ] && tmp="$(mktemp -d "${TMPDIR:-/tmp}/run-phases.XXXXXX")"; then
  trap 'rm -rf "$tmp"' EXIT
  # GNU time takes -f. BSD/macOS time takes -l and reports bytes. Try each on
  # `true` and keep the one whose report parses.
  if "$time_bin" -f %M -o "$tmp/probe" true > /dev/null 2>&1 && time_report gnu "$tmp/probe"; then
    time_flavor=gnu
    runner=("$time_bin" -f %M -o "$tmp/report" "${runner[@]}")
  elif "$time_bin" -l -o "$tmp/probe" true > /dev/null 2>&1 && time_report bsd "$tmp/probe"; then
    time_flavor=bsd
    runner=("$time_bin" -l -o "$tmp/report" "${runner[@]}")
  fi
fi
echo "peak memory: cgroup=${peak_file:-none} time=${time_flavor:-none}"

# Right before a phase: where the shared peak stands, and no stale time report.
mem_start() {
  before=""
  if [ -n "$peak_file" ]; then
    read_peak "$peak_file"
    before="$peak_now"
  fi
  [ -z "$time_flavor" ] || rm -f "$tmp/report"
}

# Right after a phase. Sets peak_bytes, empty when there is nothing to read, and
# upper when it is only an upper bound. The first source that applies wins.
mem_end() {
  peak_bytes=""
  upper=0
  if [ -n "$peak_file" ]; then
    read_peak "$peak_file"
    if is_number "$peak_now" && is_number "$before" && [ "$peak_now" -gt "$before" ]; then peak_bytes="$peak_now"; fi
  fi
  if [ -z "$peak_bytes" ] && [ -n "$time_flavor" ] && time_report "$time_flavor" "$tmp/report"; then
    peak_bytes="$report_bytes"
  fi
  if [ -z "$peak_bytes" ] && is_number "$before"; then
    peak_bytes="$before"
    upper=1
  fi
  [ -n "$peak_bytes" ] || return 0
  any_fig=1
  if [ "$upper" -eq 0 ] && { [ -z "$max_bytes" ] || [ "$peak_bytes" -gt "$max_bytes" ]; }; then max_bytes="$peak_bytes"; fi
}

# bytes -> whole MiB, rounded up so a measured phase never reads 0
to_mib() { echo $((($1 + 1048575) / 1048576)); }

# bytes -> table cell: "812 MiB", "1.5 GiB" above 1024 MiB, "-" when unknown
mem_cell() {
  local mib tenths prefix=""
  [ -n "$1" ] || { printf -- '-'; return; }
  [ "$upper" -eq 0 ] || prefix='<= '
  mib="$(to_mib "$1")"
  if [ "$mib" -gt 1024 ]; then
    tenths=$(((mib * 10 + 1023) / 1024))
    printf '%s%d.%d GiB' "$prefix" $((tenths / 10)) $((tenths % 10))
  else
    printf '%s%d MiB' "$prefix" "$mib"
  fi
}

# phase name -> its environment variable holding the command
cmd_of() {
  local var
  var="PHASE_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
  printf '%s' "${!var-}"
}

# One phase, in a process of its own. Called without an `if`, which would switch
# `-e` off inside it.
phase() {
  RUN_PHASES_CMD="$cmd" RUN_PHASES_ENV_FILE="$envfile" "${runner[@]}"
}

for name in $PHASES; do
  cmd="$(cmd_of "$name")"
  if [ -z "$(printf '%s' "$cmd" | tr -d '[:space:]')" ]; then
    echo "skipping $name: no command"
    continue
  fi
  if [ -n "$failed" ] && [ "${KEEP_GOING:-}" != true ]; then
    rows="$rows| $name | not run | - | - |"$'\n'
    continue
  fi

  envfile="${ENV_FILE:-}"
  [ "$name" != build ] || envfile="${BUILD_ENV_FILE:-$envfile}"

  first="${cmd%%$'\n'*}"
  [ "$first" = "$cmd" ] || first="$first ..."
  echo "::group::$name: $first"
  start=$SECONDS
  mem_start
  # A process per phase: one shell for all of them let a `cd app && ...` in one
  # command break the next.
  if [ -n "${LOG_DIR:-}" ]; then
    phase 2>&1 | tee "$LOG_DIR/$name.log"
    rc=${PIPESTATUS[0]}
  else
    phase
    rc=$?
  fi
  mem_end
  took=$((SECONDS - start))
  echo "::endgroup::"

  mem="$(mem_cell "$peak_bytes")"
  if [ "$rc" -eq 0 ]; then
    rows="$rows| $name | passed | $took | $mem |"$'\n'
  else
    rows="$rows| $name | failed (exit $rc) | $took | $mem |"$'\n'
    echo "::error::$name failed with exit code $rc"
    failed="${failed:+$failed }$name"
    status=1
  fi
done

if [ -n "$rows" ]; then
  {
    printf '| phase | result | seconds | peak memory |\n|---|---|---|---|\n%s' "$rows"
    [ "$any_fig" -eq 0 ] || printf '\n%s\n' "$FOOTNOTE"
  } >> "$summary"
fi
{
  echo "failed=$failed"
  echo "peak-rss=$([ -z "$max_bytes" ] || to_mib "$max_bytes")"
} >> "${GITHUB_OUTPUT:-/dev/null}"
exit "$status"
