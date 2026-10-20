#!/usr/bin/env bash
# lint.sh against a fake squawk and a fake file list: which files reach squawk,
# what fails the job, and that a lint which could not run never passes. Then
# install.sh against a fake gh: the asset it picks and the digest it demands.
# Nothing here needs a network or a real squawk.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/migration-lint-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }
# $1 name, $2 want, $3 got
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$3', wanted '$2'"; fi; }
# $1 name, $2 file, $3 fixed string that must be in it
has() { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1" "'$3' not in $(tr '\n' '|' < "$2")"; fi; }
lacks() { if grep -qF -- "$3" "$2"; then bad "$1" "'$3' is in $(tr '\n' '|' < "$2")"; else ok "$1"; fi; }

# A fake squawk. STUB_MODE picks what it does; it records its arguments.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/squawk" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_ARGS"
case "${STUB_MODE:-clean}" in
  clean)    echo '[]' ;;
  findings) echo '[{"file":"supabase/migrations/2_b.sql","line":3,"column":4,"level":"Warning","message":"adding a column\nwith a default","help":"use a nullable column","rule_name":"adding-field-with-default","column_end":9,"line_end":3}]'; exit 1 ;;
  crash)    echo "thread panicked" >&2; exit 2 ;;
  noreport) echo "Failed to find files for provided patterns" >&2; exit 1 ;;
  garbage)  echo "not json" ;;
  empty1)   echo '[]'; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/squawk"

# A repo: two migrations, one outside the path, and a rename's new name. The
# deleted one and a rename's old name are listed by the API but not on disk.
REPO="$WORK/repo"
mkdir -p "$REPO/supabase/migrations" "$REPO/supabase/tests" "$REPO/src"
for f in 1_a.sql 2_b.sql 3_c.sql 4_new_name.sql; do echo "select 1;" > "$REPO/supabase/migrations/$f"; done
echo "select 1;" > "$REPO/supabase/tests/t.sql"
echo "select 1;" > "$REPO/supabase/migrations/odd[1]*.sql"
echo "# notes" > "$REPO/supabase/migrations/README.md"

# $1 name, $2 want exit code; env for lint.sh comes from the caller as VAR=val.
# The output is left in $WORK/out and the arguments squawk saw in $WORK/args.
lint() {
  local name="$1" want="$2" rc
  rm -f "$WORK/args"
  (cd "$REPO" && env \
      SQUAWK="$WORK/bin/squawk" STUB_ARGS="$WORK/args" \
      MIGRATIONS_PATH="${MIGRATIONS_PATH-supabase/migrations}" EXCLUDED_RULES="${EXCLUDED_RULES-}" \
      BLOCKING="${BLOCKING-false}" NUMBER="${NUMBER-7}" \
      CHANGED_FILES="${CHANGED_FILES-}" LIST_COMPLETE="${LIST_COMPLETE-true}" \
      STUB_MODE="${STUB_MODE-clean}" GITHUB_STEP_SUMMARY="$WORK/summary" \
      "$HERE/lint.sh") > "$WORK/out" 2>&1
  rc=$?
  eq "$name (exit)" "$want" "$rc"
}
squawk_ran() { [ -f "$WORK/args" ]; }
: > "$WORK/summary"

LISTED=$'supabase/migrations/1_a.sql\nsupabase/migrations/2_b.sql'

# --- which files are linted ------------------------------------------------
CHANGED_FILES=$'src/app.ts\nsupabase/tests/t.sql\nsupabase/migrations/README.md' \
  lint "no matching files succeeds" 0
if squawk_ran; then bad "no matching files: squawk is not run" "it ran"; else ok "no matching files: squawk is not run"; fi
has "no matching files says so" "$WORK/out" "nothing to lint"

CHANGED_FILES=$'supabase/migrations/gone.sql\nsupabase/migrations/old_name.sql\nsupabase/migrations/4_new_name.sql' \
  lint "deleted files and a rename's old name are ignored" 0
eq "only the file still on disk is linted" "supabase/migrations/4_new_name.sql" "$(grep '\.sql' "$WORK/args")"

CHANGED_FILES=$'src/app.ts\nsupabase/tests/t.sql\nsupabase/migrations/README.md\nsupabase/migrations/1_a.sql\nsupabase/migrationsx/9.sql' \
  lint "non-SQL and outside-path files are ignored" 0
eq "only the migration is linted" "supabase/migrations/1_a.sql" "$(grep '\.sql' "$WORK/args")"

CHANGED_FILES="$LISTED" MIGRATIONS_PATH='./supabase/migrations/' lint "a path with ./ and a trailing slash" 0
eq "the path is normalised" "2" "$(grep -c '\.sql' "$WORK/args")"

CHANGED_FILES=$'supabase/migrations/odd[1]*.sql' lint "a glob character in a name" 0
has "is escaped so squawk reads the file, not a pattern" "$WORK/args" 'supabase/migrations/odd[[]1][*].sql'
has "star too" "$WORK/args" '[*]'

CHANGED_FILES="$LISTED" lint "squawk is given the files and a json report" 0
has "json reporter" "$WORK/args" "--reporter"
lacks "the repo's .squawk.toml is not overridden (no --config)" "$WORK/args" "--config"
lacks "no --exclude without the input, so the file's rules stay" "$WORK/args" "--exclude"

# --- the untrusted list ----------------------------------------------------
LIST_COMPLETE=false CHANGED_FILES="" lint "an untrusted list lints everything under the path" 0
eq "all four migrations plus the odd one" "5" "$(grep -c '\.sql' "$WORK/args")"
lacks "and nothing outside the path" "$WORK/args" "supabase/tests"
has "and says why" "$WORK/out" "could not be trusted"

LIST_COMPLETE=false MIGRATIONS_PATH=nowhere lint "an untrusted list and no migrations directory" 0
if squawk_ran; then bad "no directory: squawk is not run" "it ran"; else ok "no directory: squawk is not run"; fi

# --- not a pull request ----------------------------------------------------
NUMBER='' CHANGED_FILES="$LISTED" lint "not a pull request succeeds" 0
has "with a notice" "$WORK/out" "::notice::not a pull request"
if squawk_ran; then bad "not a pull request: squawk is not run" "it ran"; else ok "not a pull request: squawk is not run"; fi

# --- excluded rules --------------------------------------------------------
CHANGED_FILES="$LISTED" EXCLUDED_RULES=$'ban-drop-database, require-concurrent-index-creation\nadding-not-nullable-field' lint "excluded rules" 0
has "reach squawk as one comma list" "$WORK/args" "--exclude=ban-drop-database,require-concurrent-index-creation,adding-not-nullable-field"
CHANGED_FILES="$LISTED" EXCLUDED_RULES='ban-drop-database;rm' lint "a value that is not a rule name" 1
if squawk_ran; then bad "a bad rule name: squawk is not run" "it ran"; else ok "a bad rule name: squawk is not run"; fi
CHANGED_FILES="$LISTED" EXCLUDED_RULES='--config=x' lint "a rule that looks like an option" 1
CHANGED_FILES="$LISTED" EXCLUDED_RULES='*' lint "a glob is not a rule name" 1

# --- findings --------------------------------------------------------------
CHANGED_FILES="$LISTED" STUB_MODE=findings BLOCKING=false lint "non-blocking with findings stays green" 0
has "as a warning with file and line" "$WORK/out" "::warning file=supabase/migrations/2_b.sql,line=4,endLine=4,col=5,title=adding-field-with-default::adding a column%0Awith a default use a nullable column"
# shellcheck disable=SC2016  # backticks are literal table markup
has "and the summary" "$WORK/summary" '| `supabase/migrations/2_b.sql` | 4 | `adding-field-with-default` |'

CHANGED_FILES="$LISTED" STUB_MODE=findings BLOCKING=true lint "blocking with findings fails" 1
has "as an error" "$WORK/out" "::error file=supabase/migrations/2_b.sql,line=4"

CHANGED_FILES="$LISTED" STUB_MODE=clean BLOCKING=true lint "blocking with no findings passes" 0
CHANGED_FILES="$LISTED" STUB_MODE=clean BLOCKING=false lint "non-blocking with no findings passes" 0

# --- a lint that could not run is not a pass --------------------------------
for mode in crash noreport garbage empty1; do
  CHANGED_FILES="$LISTED" STUB_MODE=$mode BLOCKING=false lint "squawk $mode fails when non-blocking" 1
  CHANGED_FILES="$LISTED" STUB_MODE=$mode BLOCKING=true  lint "squawk $mode fails when blocking" 1
done
has "and says nothing was linted" "$WORK/out" "did not run to completion"

(cd "$REPO" && env SQUAWK="$WORK/nope/squawk" NUMBER=7 MIGRATIONS_PATH=supabase/migrations \
   CHANGED_FILES="$LISTED" LIST_COMPLETE=true BLOCKING=false GITHUB_STEP_SUMMARY=/dev/null \
   "$HERE/lint.sh") > "$WORK/out" 2>&1
eq "a missing binary fails" "1" "$?"
has "by name" "$WORK/out" "squawk is not installed"

# --- install.sh --------------------------------------------------------------
inst() { "$HERE/install.sh" --asset "$@"; }
eq "x86_64" "squawk-linux-x64"   "$(inst x86_64)"
eq "aarch64" "squawk-linux-arm64" "$(inst aarch64)"
eq "an unknown architecture" "1" "$(inst riscv64 >/dev/null 2>&1; echo $?)"

# A fake gh: `release view` prints the digest in FAKE_DIGEST, `release download`
# writes a fake binary named after the -p asset.
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$2" in
  view) printf '%s\n' "$FAKE_DIGEST" ;;
  download)
    while [ $# -gt 0 ]; do case "$1" in -p) asset=$2 ;; -D) dir=$2 ;; esac; shift; done
    printf '#!/bin/sh\necho "squawk 2.70.0"\n' > "$dir/$asset" ;;
esac
GH
chmod +x "$WORK/bin/gh"
if command -v sha256sum >/dev/null 2>&1; then
  digest=$(printf '#!/bin/sh\necho "squawk 2.70.0"\n' | sha256sum | cut -d' ' -f1)
else
  digest=$(printf '#!/bin/sh\necho "squawk 2.70.0"\n' | shasum -a 256 | cut -d' ' -f1)
fi

install() { # rc into $?, stdout to $WORK/dir
  rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"
  env PATH="$WORK/bin:$PATH" RUNNER_TEMP="$WORK/tmp" GH_LOG="$WORK/gh.log" FAKE_DIGEST="$1" \
    "$HERE/install.sh" > "$WORK/dir" 2> "$WORK/inst.err"
}
: > "$WORK/gh.log"
install "sha256:$digest"; rc=$?
eq "a matching digest installs" "0" "$rc"
if [ -x "$(cat "$WORK/dir")/squawk" ]; then ok "and leaves a runnable binary in RUNNER_TEMP"; else bad "binary" "$(cat "$WORK/dir")"; fi
case "$(cat "$WORK/dir")" in "$WORK/tmp"/*) ok "outside the checkout" ;; *) bad "outside the checkout" "$(cat "$WORK/dir")" ;; esac
has "from the pinned release" "$WORK/gh.log" "release download v"
install "sha256:0000"; rc=$?
eq "a digest that does not match fails" "1" "$rc"
has "by name" "$WORK/inst.err" "does not match"
install ""; rc=$?
eq "a release with no digest fails" "1" "$rc"
if [ -e "$WORK/tmp/squawk" ] && [ -x "$(find "$WORK/tmp/squawk" -name squawk -type f | head -1)" ]; then
  bad "no digest: nothing is installed" "a binary exists"
else ok "no digest: nothing is installed"; fi

# --- the pin ----------------------------------------------------------------
n=$(grep -c '^SQUAWK_VERSION="v[0-9][0-9.]*"$' "$HERE/install.sh")
eq "the version is pinned once, exact" "1" "$n"
if grep -B1 '^SQUAWK_VERSION=' "$HERE/install.sh" | grep -q '^# renovate: datasource=github-releases depName=sbdchd/squawk$'; then
  ok "with its Renovate marker"
else bad "with its Renovate marker" "marker missing"; fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
