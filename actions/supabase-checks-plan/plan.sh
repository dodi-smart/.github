#!/usr/bin/env bash
# The lanes a supabase-checks run needs, one matrix leg each (DODI-00056): a
# check that is off, or a pull request that touches none of its paths, books no
# runner. The rules live here and nowhere else, so test.sh can hold one row each.
#
# Inputs, from the environment:
#   TYPES SEED PGTAP DRIFT LINT   'true' when that check is on
#   DENO_DIR                      the Deno source directory; empty is off
#   MIGRATIONS_PATHS              newline-separated paths that start a database
#                                 check; blank means no filter
#   MIGRATIONS_PATH               the directory the lint reads
#   SCHEMA_PATH                   the declarative schema directory
#   FILES_PATH COMPLETE           changed-files' `files-path` and `complete`
#   HOSTED LIGHT                  pick-runner `runner` selectors, as JSON
#
# A database check runs on a change to its own paths only: types and the seed
# on MIGRATIONS_PATHS, pgTAP also on supabase/tests, the drift check also on
# SCHEMA_PATH and supabase/config.toml. Edge Functions runs on DENO_DIR, the
# root Deno config or supabase/config.toml; the lint on MIGRATIONS_PATH. Doubt means run, the rule changed-files
# follows: a list that was not read in full (no pull request, an API error, the
# 3000-file cap) runs every check that is on.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
on() { [ "${1:-}" = true ]; }

files=""
if [ "${COMPLETE:-}" = true ] && [ -n "${FILES_PATH:-}" ] && [ -r "$FILES_PATH" ]; then
  files="$(cat "$FILES_PATH")"
fi
# touched PATTERNS...: true when the change hits any of them. Blank
# MIGRATIONS_PATHS is no filter, so a pattern list holding it always matches.
touched() {
  [ "${COMPLETE:-}" = true ] || return 0
  local pats
  pats="$(printf '%s\n' "$@")"
  [ -n "$(printf '%s' "$pats" | tr -d '[:space:]')" ] || return 0
  [ "$(printf '%s\n' "$files" | "$HERE/../changed-files/changed-files.sh" --match "$pats")" = true ]
}
mig="${MIGRATIONS_PATHS:-}"
nofilter=false
[ -n "$(printf '%s' "$mig" | tr -d '[:space:]')" ] || nofilter=true

db=false
if on "${TYPES:-}" || on "${SEED:-}"; then
  { $nofilter || touched "$mig"; } && db=true
fi
if on "${PGTAP:-}"; then
  { $nofilter || touched "$mig" supabase/tests; } && db=true
fi
if on "${DRIFT:-}"; then
  { $nofilter || touched "$mig" "${SCHEMA_PATH:-supabase/schemas}" supabase/config.toml; } && db=true
fi
# Edge functions also read the root Deno config and the [functions] import maps
# in supabase/config.toml, so those start the lane too.
deno=false
[ -n "${DENO_DIR:-}" ] && touched "$DENO_DIR" deno.json deno.jsonc import_map.json supabase/config.toml && deno=true
lint=false
on "${LINT:-}" && touched "${MIGRATIONS_PATH:-supabase/migrations}" && lint=true

need() { # lane runner: fail closed when a lane has no runner
  [ -n "$2" ] || { echo "::error::no runner was picked for the $1 lane"; exit 1; }
}
$db   && need database "${HOSTED:-}"
$deno && need "Edge Functions" "${LIGHT:-}"
$lint && need "Migration Lint" "${LIGHT:-}"

lanes="$(jq -nc --argjson db "$db" --argjson deno "$deno" --argjson lint "$lint" \
  --arg hosted "${HOSTED:-}" --arg light "${LIGHT:-}" '[
    (select($db)   | {lane: "database",       name: "Database",       runs_on: $hosted}),
    (select($deno) | {lane: "deno",           name: "Edge Functions", runs_on: $light}),
    (select($lint) | {lane: "migration-lint", name: "Migration Lint", runs_on: $light})
  ]')"
echo "lanes=$lanes" >> "${GITHUB_OUTPUT:-/dev/stdout}"
echo "lanes: $lanes"
