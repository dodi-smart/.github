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

# $1 name, $2 want matched, $3 fixture file, extra env in $4.. as VAR=val
run() {
  local name="$1" want="$2" fixture="$3" out; shift 3
  out="$WORK/out"; : > "$out"
  env PATH="$WORK/bin:$PATH" FAKE_GH_FILE="$fixture" GITHUB_OUTPUT="$out" REPO=o/r "$@" \
    "$SCRIPT" > "$WORK/log" 2>&1
  local got; got="$(sed -n 's/^matched=//p' "$out")"
  if [ "$got" = "$want" ]; then ok "$name"; else bad "$name" "got ${got:-<none>}, wanted $want"; fi
}

printf 'src/a.ts\t\nREADME.md\t\n' > "$WORK/irrelevant"
printf 'supabase/migrations/1.sql\t\n' > "$WORK/relevant"
printf 'src/a.ts\tsupabase/migrations/1.sql\n' > "$WORK/renamed-out"
: > "$WORK/empty"
for i in $(seq 1 2999); do printf 'src/f%s.ts\t\n' "$i"; done > "$WORK/just-under"
for i in $(seq 1 3000); do printf 'src/f%s.ts\t\n' "$i"; done > "$WORK/at-cap"

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
