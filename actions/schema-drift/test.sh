#!/usr/bin/env bash
# Runs drift.sh in a throwaway git repo against a stub `supabase`. The step is a
# required check, so a drift that reads as a match ships a schema nobody
# declared, and a match that reads as drift blocks every pull request.
# Each check is a condition string eval'd after run() sets STATUS, OUT, ARGS and SUMMARY.
# shellcheck disable=SC2016,SC2034
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/schema-drift-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

# The stub: `--help` fails when OLD_CLI is set; sync records its arguments,
# writes a migration when DRIFT is set, and exits SYNC_EXIT.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/supabase" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = --version ]; then echo 3.3.0; exit 0; fi
for a in "$@"; do [ "$a" = --help ] && { [ -n "${OLD_CLI:-}" ] && exit 1; exit 0; }; done
echo "$*" > "$ARGS_FILE"
[ -n "${DRIFT:-}" ] && printf 'CREATE TABLE drift_probe (id bigint);\n' > supabase/migrations/20990101000000_ci_schema_drift.sql
exit "${SYNC_EXIT:-0}"
STUB
chmod +x "$WORK/bin/supabase"

# run [VAR=value...]: a fresh repo with one committed migration and a schema dir.
# Sets $STATUS, $OUT, $ARGS and $SUMMARY.
run() {
  local repo="$WORK/repo"
  rm -rf "$repo"; mkdir -p "$repo/supabase/migrations" "$repo/supabase/schemas"
  echo 'create table a ();' > "$repo/supabase/migrations/1_a.sql"
  ( cd "$repo" && git init -q && git add -Af \
    && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm init ) > /dev/null
  : > "$WORK/args"; : > "$WORK/summary"
  OUT="$(cd "$repo" && env PATH="$WORK/bin:$PATH" ARGS_FILE="$WORK/args" GITHUB_STEP_SUMMARY="$WORK/summary" \
    SCHEMA_PATH=supabase/schemas STRICT=true "$@" "$HERE/drift.sh" 2>&1)"
  STATUS=$?
  ARGS="$(cat "$WORK/args")"; SUMMARY="$(cat "$WORK/summary")"
}
check() { if eval "$2"; then ok "$1"; else bad "$1" "status $STATUS: $OUT"; fi; }

run
check "in sync passes" '[ "$STATUS" -eq 0 ] && grep -q "match supabase/schemas" <<<"$OUT"'
check "it runs sync without applying, strict by default" '[ "$ARGS" = "db schema declarative sync --no-apply --name ci_schema_drift --strict-coverage" ]'
run STRICT=false
check "strict off drops the flag" '[ "$ARGS" = "db schema declarative sync --no-apply --name ci_schema_drift" ]'
run DRIFT=1
check "a written migration fails" '[ "$STATUS" -eq 1 ] && grep -q "::error::The committed migrations do not match" <<<"$OUT"'
check "and prints it" 'grep -q "CREATE TABLE drift_probe" <<<"$OUT" && grep -q "CREATE TABLE drift_probe" <<<"$SUMMARY"'
check "the hint is the command CI ran" 'grep -qF "sync --no-apply --name <name> --strict-coverage" <<<"$OUT"'
run DRIFT=1 STRICT=false
check "the hint follows strict off" 'grep -qF "sync --no-apply --name <name>\`" <<<"$OUT"'
run SYNC_EXIT=3
check "a failing sync fails" '[ "$STATUS" -eq 3 ]'
run OLD_CLI=1
check "a CLI without declarative sync fails, saying so" '[ "$STATUS" -eq 1 ] && grep -q "needs a Supabase CLI" <<<"$OUT"'
run SCHEMA_PATH=db/none
check "a missing schema dir fails, saying so" '[ "$STATUS" -eq 1 ] && grep -q "db/none does not exist" <<<"$OUT"'

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
