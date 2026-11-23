#!/usr/bin/env bash
# Fail when the committed migrations do not build the schema declared under
# SCHEMA_PATH. Runs the sync a developer runs (`db:sync`), on a clean checkout:
# the CLI replays the migrations into one throwaway database, loads the schema
# files into another and diffs them. Sync exits 0 whether or not they differ,
# so a migration it writes is the only signal; it is printed and the step fails.
#
# Env: SCHEMA_PATH, STRICT ('true' adds --strict-coverage). Stack mode is on for
# this script alone (action.yml), so the throwaway databases run natively, with
# no Docker daemon, and a Docker stack started earlier in the job is untouched.
set -euo pipefail

if ! supabase db schema declarative sync --help > /dev/null 2>&1; then
  echo "::error::schema-drift needs a Supabase CLI with \`db schema declarative sync\` (CLI 3); this is $(supabase --version 2>/dev/null || echo 'no CLI')."
  exit 1
fi
if [ ! -d "${SCHEMA_PATH:?}" ]; then
  echo "::error::schema-drift is on, but $SCHEMA_PATH does not exist. Set schema-path, or turn schema-drift off."
  exit 1
fi
# Postgres `initdb` refuses to run as root, how a job inside a container runs.
if [ "$(id -u)" = 0 ] && [ -z "${SUPABASE_NATIVE_POSTGRES_USER:-}" ]; then
  id supabase > /dev/null 2>&1 || useradd --create-home supabase
  export SUPABASE_NATIVE_POSTGRES_USER=supabase
fi

args=(--no-apply --name ci_schema_drift)
[ "${STRICT:-}" = true ] && args+=(--strict-coverage)
supabase db schema declarative sync "${args[@]}"

# The checkout is clean, so any untracked migration is the one sync just wrote.
# supabase/migrations is where the CLI writes, whatever the lint's path says.
# No --exclude-standard: an ignore rule for *.sql would hide the drift itself.
new="$(git ls-files --others -- supabase/migrations)"
if [ -z "$new" ]; then
  echo "The committed migrations match $SCHEMA_PATH."
  exit 0
fi
hint="supabase db schema declarative sync ${args[*]/ci_schema_drift/<name>}"
echo "::error::The committed migrations do not match $SCHEMA_PATH. Run \`$hint\` (the repo's db:sync), review the migration it writes, and commit it with the schema change."
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
{
  echo "### Migrations drift from \`$SCHEMA_PATH\`"
  echo
  echo "The schema files describe changes no committed migration makes. Regenerate the migration with \`$hint\` and commit it. What is missing:"
} >> "$summary"
while IFS= read -r f; do
  echo "::group::$f"
  cat "$f"
  echo "::endgroup::"
  # shellcheck disable=SC2016 # the backticks are a Markdown fence, not a command
  printf '\n```sql\n%s\n```\n' "$(cat "$f")" >> "$summary"
done <<<"$new"
exit 1
