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

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
