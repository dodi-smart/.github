#!/usr/bin/env bash
# Run a job's command phases in order, each in its own subshell, and leave a
# `| phase | result | seconds |` table in the job summary.
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
# The commands reach `eval` through the environment, never through the script
# text, so a quote or a `$` in one cannot change what this script does.
set -uo pipefail

PHASES="install lint design-lint typecheck test build smoke"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

rows=""
failed=""
status=0
[ -z "${LOG_DIR:-}" ] || mkdir -p "$LOG_DIR"

# phase name -> its environment variable holding the command
cmd_of() {
  local var
  var="PHASE_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
  printf '%s' "${!var-}"
}

for name in $PHASES; do
  cmd="$(cmd_of "$name")"
  if [ -z "$(printf '%s' "$cmd" | tr -d '[:space:]')" ]; then
    echo "skipping $name: no command"
    continue
  fi
  if [ -n "$failed" ] && [ "${KEEP_GOING:-}" != true ]; then
    rows="$rows| $name | not run | - |"$'\n'
    continue
  fi

  envfile="${ENV_FILE:-}"
  [ "$name" != build ] || envfile="${BUILD_ENV_FILE:-$envfile}"

  first="${cmd%%$'\n'*}"
  [ "$first" = "$cmd" ] || first="$first ..."
  echo "::group::$name: $first"
  start=$SECONDS
  # A subshell per phase: one shell for all of them let a `cd app && ...` in one
  # command break the next. No `if` around it, which would switch `-e` off inside.
  phase() (
    set -euo pipefail
    if [ -n "$envfile" ]; then
      # shellcheck source=/dev/null
      . "$envfile"
    fi
    eval "$cmd"
  )
  if [ -n "${LOG_DIR:-}" ]; then
    phase 2>&1 | tee "$LOG_DIR/$name.log"
    rc=${PIPESTATUS[0]}
  else
    phase
    rc=$?
  fi
  took=$((SECONDS - start))
  echo "::endgroup::"

  if [ "$rc" -eq 0 ]; then
    rows="$rows| $name | passed | $took |"$'\n'
  else
    rows="$rows| $name | failed (exit $rc) | $took |"$'\n'
    echo "::error::$name failed with exit code $rc"
    failed="${failed:+$failed }$name"
    status=1
  fi
done

if [ -n "$rows" ]; then
  {
    printf '| phase | result | seconds |\n|---|---|---|\n%s' "$rows"
  } >> "$summary"
fi
echo "failed=$failed" >> "${GITHUB_OUTPUT:-/dev/null}"
exit "$status"
