#!/usr/bin/env bash
# Runs plan.sh over a table of inputs and changed files. Each lane it lists is a
# runner a pull request pays for, and each one it drops is a check that does not
# run, so every rule is a row here.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/supabase-checks-plan-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

HOSTED='"ubuntu-latest"'
LIGHT='["self-hosted","Linux","light"]'
MIG=$'supabase/migrations\nsupabase/seed.sql'

# plan FILES [VAR=value...]: FILES is the changed list (one per line), read in
# full. Sets $LANES and $STATUS.
plan() {
  printf '%s\n' "$1" > "$WORK/files"; shift
  : > "$WORK/out"
  env -i PATH="$PATH" GITHUB_OUTPUT="$WORK/out" HOSTED="$HOSTED" LIGHT="$LIGHT" \
    MIGRATIONS_PATHS="$MIG" FILES_PATH="$WORK/files" COMPLETE=true "$@" \
    "$HERE/plan.sh" > "$WORK/log" 2>&1
  STATUS=$?
  LANES="$(sed -n 's/^lanes=//p' "$WORK/out")"
}
# expect NAME WANT: the lane names, space-separated.
expect() {
  local got; got="$(jq -r 'map(.lane) | join(" ")' <<<"${LANES:-null}" 2>&1)"
  if [ "$got" = "$2" ]; then ok "$1"; else bad "$1" "got '$got', want '$2' ($(cat "$WORK/log"))"; fi
}

# --- off is off
plan "supabase/migrations/1_a.sql"
expect "nothing on, nothing runs" ""
plan "supabase/migrations/1_a.sql" TYPES=true PGTAP=true LINT=true DRIFT=true DENO_DIR=supabase/functions
expect "every check on and a migration changed" "database migration-lint"

# --- each database check on its own paths only
plan "supabase/tests/a.sql" TYPES=true
expect "a test change does not start types" ""
plan "supabase/tests/a.sql" PGTAP=true
expect "a test change starts pgTAP" "database"
plan "supabase/schemas/10_a.sql" TYPES=true PGTAP=true
expect "a schema change does not start types or pgTAP" ""
plan "supabase/schemas/10_a.sql" DRIFT=true
expect "a schema change starts the drift check" "database"
plan "supabase/config.toml" DRIFT=true
expect "a config change starts the drift check" "database"
plan "db/decl/a.sql" DRIFT=true SCHEMA_PATH=db/decl
expect "schema-path moves the drift trigger" "database"
plan "supabase/seed.sql" SEED=true
expect "a seed change starts the seed re-run" "database"
plan "src/app.ts" TYPES=true PGTAP=true DRIFT=true SEED=true
expect "an app-only change starts no database check" ""
plan "src/app.ts" TYPES=true MIGRATIONS_PATHS=$'\n'
expect "blank migrations-paths is no filter" "database"

# --- file-only lanes
plan "supabase/functions/x/index.ts" DENO_DIR=supabase/functions
expect "a function change starts Edge Functions" "deno"
plan "src/app.ts" DENO_DIR=supabase/functions
expect "an unrelated change does not" ""
plan "deno.json" DENO_DIR=supabase/functions
expect "a root Deno config change starts Edge Functions" "deno"
plan "supabase/config.toml" DENO_DIR=supabase/functions
expect "a config change starts Edge Functions (its import maps)" "deno"
plan "db/m/1.sql" LINT=true MIGRATIONS_PATH=db/m
expect "the lint follows migrations-path" "migration-lint"

# --- doubt means run
plan "" TYPES=true LINT=true DENO_DIR=supabase/functions COMPLETE=false
expect "a list not read in full runs every check that is on" "database deno migration-lint"

# --- runners
plan "supabase/migrations/1.sql" TYPES=true LINT=true
got="$(jq -r 'map(.runs_on) | join(" ")' <<<"$LANES")"
if [ "$got" = "$HOSTED $LIGHT" ]; then ok "database is hosted, the lint light"; else bad "runners" "$got"; fi
plan "supabase/migrations/1.sql" TYPES=true HOSTED=
if [ "$STATUS" -ne 0 ] && grep -q 'no runner was picked for the database lane' "$WORK/log"; then ok "a lane with no runner fails"; else bad "no runner" "$STATUS"; fi
plan "db/m/1.sql" LINT=true MIGRATIONS_PATH=db/m LIGHT=
if [ "$STATUS" -ne 0 ] && grep -q 'no runner was picked for the Migration Lint lane' "$WORK/log"; then ok "the error names the lane"; else bad "lane name" "$(cat "$WORK/log")"; fi
plan "src/app.ts" HOSTED= LIGHT=
if [ "$STATUS" -eq 0 ] && [ "$LANES" = "[]" ]; then ok "no lanes needs no runner"; else bad "no lanes" "$STATUS $LANES"; fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
