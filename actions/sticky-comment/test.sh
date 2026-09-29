#!/usr/bin/env bash
# Assert how the sticky comment is FOUND, which is the only part that can be
# wrong quietly. Posting is one API call; picking the wrong comment to edit
# means a later run overwrites something it did not write.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0

# $1 name, $2 key, $3 expected id (empty = no match), $4 comments JSON
check() {
  local name="$1" key="$2" want="$3" json="$4" got
  got="$(printf '%s' "$json" | "$HERE/sticky.sh" --pick "$key")"
  if [ "$got" = "$want" ]; then
    printf '  ok   %-46s -> %s\n' "$name" "${got:-<none>}"; pass=$((pass + 1))
  else
    printf '  FAIL %-46s -> %s (wanted %s)\n' "$name" "${got:-<none>}" "${want:-<none>}"
    fail=$((fail + 1))
  fi
}

bot()   { printf '{"id":%s,"user":{"type":"Bot"},"body":"%s"}' "$1" "$2"; }
human() { printf '{"id":%s,"user":{"type":"User"},"body":"%s"}' "$1" "$2"; }

M='<!-- dodi-sticky: review -->'
N='<!-- dodi-sticky: deps -->'

check "no comments at all"          review ""  '[]'
check "nothing carries the marker"  review ""  "[$(bot 1 'hello'),$(human 2 'hi')]"
check "the marker is found"         review 11  "[$(bot 11 "$M body")]"
check "found among others"          review 11  "[$(human 9 'x'),$(bot 10 'y'),$(bot 11 "$M b")]"
check "first wins when duplicated"  review 11  "[$(bot 11 "$M a"),$(bot 12 "$M b")]"

# Two workflows comment on the same Renovate PR. Each must edit its own.
check "another key is not ours"     review ""  "[$(bot 20 "$N table")]"
check "picks its own key"           deps   20  "[$(bot 19 "$M r"),$(bot 20 "$N t")]"

# A person quoting a previous sticky comment reproduces the marker verbatim.
# Editing their words on the next run would be worse than posting twice.
check "a human quoting it is not ours" review "" "[$(human 30 "quoting $M here")]"
check "human quote does not shadow"    review 31 "[$(human 30 "quoting $M"),$(bot 31 "$M real")]"

# The API omits body on a deleted comment; `.body // ""` must not blow up.
check "missing body field"          review ""  '[{"id":40,"user":{"type":"Bot"}}]'

# `--body` picks the same comment, so a caller that stores a value in it reads
# back the one that would be edited, never a person's quote of it.
body() {
  local name="$1" want="$2" json="$3" got
  got="$(printf '%s' "$json" | "$HERE/sticky.sh" --body review)"
  if [ "$got" = "$want" ]; then
    printf '  ok   %-46s\n' "$name"; pass=$((pass + 1))
  else
    printf '  FAIL %-46s -> %s (wanted %s)\n' "$name" "${got:-<none>}" "${want:-<none>}"
    fail=$((fail + 1))
  fi
}
body "no comments"                     ""            '[]'
body "the bot's body"                  "$M hi"       "[$(bot 11 "$M hi")]"
body "a multi-line body stays whole"   "$(printf '%s\nb' "$M")" "[$(bot 11 "$M\\nb")]"
body "a human quote is not the body"   "$M real"     "[$(human 30 "$M quote"),$(bot 31 "$M real")]"
body "found on a later page"           "$M two"      "[$(human 1 x)] [$(bot 2 "$M two")]"

# Whole-script runs against a fake `gh`, so argument handling and delete mode
# are checked without the API. The fake serves $COMMENTS for a read and logs
# every DELETE it is asked to make.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sticky-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"-X DELETE"*) echo "$*" >> "$CALLS" ;;
  *"/comments?per_page"*) printf '%s' "$COMMENTS" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$TMP/bin/gh"

# $1 name, $2 want exit code, $3 want action output, $4 want DELETE calls,
# $5 comments JSON; the rest is extra environment for the run.
run() {
  local name="$1" want_rc="$2" want_action="$3" want_calls="$4" rc action calls
  : > "$TMP/out"; : > "$TMP/calls"
  env PATH="$TMP/bin:$PATH" GITHUB_OUTPUT="$TMP/out" CALLS="$TMP/calls" COMMENTS="$5" \
    KEY=review REPO=o/r NUMBER=7 "${@:6}" "$HERE/sticky.sh" >"$TMP/log" 2>&1
  rc=$?
  action="$(grep '^action=' "$TMP/out" | cut -d= -f2)"
  calls="$(wc -l < "$TMP/calls" | tr -d ' ')"
  if [ "$rc" = "$want_rc" ] && [ "$action" = "$want_action" ] && [ "$calls" = "$want_calls" ]; then
    printf '  ok   %-42s rc=%s action=%s deletes=%s\n' "$name" "$rc" "${action:-<none>}" "$calls"; pass=$((pass + 1))
  else
    printf '  FAIL %-42s rc=%s action=%s deletes=%s (wanted %s %s %s)\n' "$name" "$rc" "${action:-<none>}" "$calls" "$want_rc" "${want_action:-<none>}" "$want_calls"
    fail=$((fail + 1))
  fi
}

: > "$TMP/empty"
CS="[$(bot 11 "$M b")]"

# A run that writes has to name a body, and the file has to exist and have content.
run "no body-file, not delete"             1 ""      0 "[]" BODY_FILE=
run "body-file missing"                    1 ""      0 "[]" BODY_FILE="$TMP/nope"
run "body-file empty"                      1 ""      0 "[]" BODY_FILE="$TMP/empty"

# Delete mode needs no body, removes the bot's comment, and leaves a person's alone.
run "delete, no body-file, comment found"  0 deleted 1 "$CS" DELETE=true
run "delete, nothing to delete"            0 none    0 "[]" DELETE=true
run "delete ignores a missing body-file"   0 none    0 "[]" DELETE=true BODY_FILE="$TMP/nope"
run "delete leaves a human quote alone"    0 none    0 "[$(human 30 "quoting $M")]" DELETE=true
run "delete touches only its own key"      0 none    0 "[$(bot 20 "$N t")]" DELETE=true

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
