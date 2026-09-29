#!/usr/bin/env bash
# Assert the two claims a skip rests on: which paths match, and that every doubt
# comes out as `matched=true`. The API is faked with a `gh` on PATH that prints
# a fixture, so nothing here needs a network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/changed-files.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/changed-files-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

mkdir "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
[ -z "${FAKE_GH_FAIL:-}" ] || { echo "HTTP 403" >&2; exit 1; }
cat "$FAKE_GH_FILE"
GH
chmod +x "$WORK/bin/gh"

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

# $1 name, $2 patterns, $3 want, paths on stdin
match() {
  local got
  got="$("$SCRIPT" --match "$2")"
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1" "got $got, wanted $3"; fi
}

# $1 name, $2 patterns, $3 want, paths on stdin: every path must match.
allmatch() {
  local got
  got="$("$SCRIPT" --all "$2")"
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1" "got $got, wanted $3"; fi
}

P=$'supabase/migrations\nsupabase/seed.sql'
printf 'supabase/migrations/a/b.sql\n'           | match "a directory covers what is under it" $'supabase/migrations/\n' true
printf 'supabase/migrations-old/a.sql\n'         | match "a directory is not a name prefix" "$P" false
printf 'src/a.ts\nsupabase/migrations/1_x.sql\n' | match "a migration matches"        "$P" true
printf 'src/a.ts\nREADME.md\n'                   | match "nothing relevant"           "$P" false
printf 'supabase/migrations/a/b/c.sql\n'         | match "a star crosses a slash"     "$P" true
printf 'supabase/seed.sql\n'                     | match "an exact path matches"      "$P" true
printf 'supabase/seed.sql.bak\n'                 | match "an exact path is not a prefix" "$P" false
printf 'docs/a/b.md\n'                           | match "the docs-only shape"        $'**.md\ndocs/**' true
printf '\n'                                      | match "no files"                   "$P" false
printf 'supabase/migrations/1.sql\n'             | match "blank pattern lines ignored" $'\n  \nsupabase/migrations/*\n' true

D=$'**.md\ndocs/**'
printf 'README.md\ndocs/a/b.png\n'  | allmatch "every file docs-only"          "$D" true
printf 'README.md\nsrc/a.ts\n'      | allmatch "one file outside is not docs-only" "$D" false
printf 'docs/a.md\n'                | allmatch "a single docs file"            "$D" true
printf '\n'                          | allmatch "no files is never all-matched" "$D" false
printf 'README.md\n'                | allmatch "no patterns is never all-matched" $'\n  \n' false
printf 'a/b/CHANGELOG.md\n'         | allmatch "a star crosses a slash"        "$D" true
printf 'README.md.bak\n'            | allmatch "the extension must be the end" "$D" false

# $1 name, $2 want matched, $3 fixture file, extra env in $4.. as VAR=val.
# WANT_ALL, when set in the caller, is the all-matched value to assert too.
run() {
  local name="$1" want="$2" fixture="$3" out; shift 3
  out="$WORK/out"; : > "$out"
  env PATH="$WORK/bin:$PATH" FAKE_GH_FILE="$fixture" GITHUB_OUTPUT="$out" REPO=o/r "$@" \
    "$SCRIPT" > "$WORK/log" 2>&1
  local got; got="$(sed -n 's/^matched=//p' "$out")"
  local gotall; gotall="$(sed -n 's/^all-matched=//p' "$out")"
  if [ "$got" != "$want" ]; then bad "$name" "got ${got:-<none>}, wanted $want"
  elif [ -n "${WANT_ALL:-}" ] && [ "$gotall" != "$WANT_ALL" ]; then
    bad "$name (all-matched)" "got ${gotall:-<none>}, wanted $WANT_ALL"
  else ok "$name"; fi
}

printf 'src/a.ts\t\nREADME.md\t\n' > "$WORK/irrelevant"
printf 'supabase/migrations/1.sql\t\n' > "$WORK/relevant"
printf 'src/a.ts\tsupabase/migrations/1.sql\n' > "$WORK/renamed-out"
: > "$WORK/empty"
for i in $(seq 1 2999); do printf 'src/f%s.ts\t\n' "$i"; done > "$WORK/just-under"
for i in $(seq 1 3000); do printf 'src/f%s.ts\t\n' "$i"; done > "$WORK/at-cap"

printf 'README.md\t\ndocs/a.md\t\n' > "$WORK/docs-only"
printf 'README.md\t\nsrc/a.ts\t\n' > "$WORK/docs-and-code"
for i in $(seq 1 3000); do printf 'docs/f%s.md\t\n' "$i"; done > "$WORK/docs-at-cap"

# Only a fully read, fully matching list is all-matched. Every doubt is false.
WANT_ALL=true  run "all-matched: a docs-only diff"          true  "$WORK/docs-only"     NUMBER=1 PATTERNS="$D"
WANT_ALL=false run "all-matched: docs plus code"            true  "$WORK/docs-and-code" NUMBER=1 PATTERNS="$D"
WANT_ALL=false run "all-matched: no pull request number"    true  "$WORK/docs-only"     NUMBER= PATTERNS="$D"
WANT_ALL=false run "all-matched: no patterns"               true  "$WORK/docs-only"     NUMBER=1 PATTERNS=
WANT_ALL=false run "all-matched: an empty diff"             true  "$WORK/empty"         NUMBER=1 PATTERNS="$D"
WANT_ALL=false run "all-matched: an unreadable diff"        true  "$WORK/docs-only"     NUMBER=1 PATTERNS="$D" FAKE_GH_FAIL=1
WANT_ALL=false run "all-matched: the cap, even if every file matches" true "$WORK/docs-at-cap" NUMBER=1 PATTERNS="$D"
printf 'docs/a.md\tsrc/a.ts\n' > "$WORK/renamed-out-of-docs"
WANT_ALL=false run "all-matched: a file renamed out of docs" true "$WORK/renamed-out-of-docs" NUMBER=1 PATTERNS="$D"

run "irrelevant files skip"            false "$WORK/irrelevant" NUMBER=1 PATTERNS="$P"
run "a relevant file runs"             true  "$WORK/relevant"   NUMBER=1 PATTERNS="$P"
run "a file renamed out of a directory runs" true "$WORK/renamed-out" NUMBER=1 PATTERNS="$P"
run "no pull request number runs"      true  "$WORK/irrelevant" NUMBER= PATTERNS="$P"
run "no patterns runs"                 true  "$WORK/irrelevant" NUMBER=1 PATTERNS=
run "an empty diff runs"               true  "$WORK/empty"      NUMBER=1 PATTERNS="$P"
run "an unreadable diff runs"          true  "$WORK/irrelevant" NUMBER=1 PATTERNS="$P" FAKE_GH_FAIL=1
run "one under the cap still skips"    false "$WORK/just-under" NUMBER=1 PATTERNS="$P"
run "the cap counts as matched"        true  "$WORK/at-cap"     NUMBER=1 PATTERNS="$P"

# The list a caller reads: both names of a rename, once each, sorted.
out="$WORK/out"; : > "$out"
env PATH="$WORK/bin:$PATH" FAKE_GH_FILE="$WORK/renamed-out" GITHUB_OUTPUT="$out" REPO=o/r NUMBER=1 PATTERNS="$P" \
  "$SCRIPT" > /dev/null 2>&1
want=$'files<<CHANGED_FILES_EOF\nsrc/a.ts\nsupabase/migrations/1.sql\nCHANGED_FILES_EOF'
if grep -qxF 'matched=true' "$out" && [ "$(sed -n '/^files</,$p' "$out")" = "$want" ]; then
  ok "files output lists both names of a rename"
else
  bad "files output lists both names of a rename" "$(cat "$out")"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
