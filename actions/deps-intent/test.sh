#!/usr/bin/env bash
# Assert when verification is skipped. The costly mistake is a skip that should
# not have happened, above all a `verified` on a red build, so those come first.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

H1=$(printf 'a%.0s' {1..64})
H2=$(printf 'b%.0s' {1..64})

# $1 name, $2 want judge, then env assignments for the run. Labels default to none.
decide() {
  local name="$1" want="$2" got; shift 2
  got="$(env VERDICT=green UPDATE=other LABELS='[]' ROUNDS=0 INTENT="$H1" PREVIOUS="$H1" "$@" \
         "$HERE/intent.sh" decide | sed -n 's/^judge=//p')"
  if [ "$got" = "$want" ]; then ok "$(printf '%-52s -> %s' "$name" "$got")"
  else bad "$(printf '%-52s -> %s (wanted %s)' "$name" "$got" "$want")"; fi
}

VER='LABELS=["deps:verified"]'
FIX='LABELS=["deps:fixed"]'

# Never skip on anything but green.
decide "red build, verified label, same diff"      agent "$VER" VERDICT=red:build
decide "infra failure, verified label"             agent "$VER" VERDICT=red:infra
decide "build not known yet, verified label"       agent "$VER" VERDICT=
decide "red lock file maintenance"                 agent UPDATE=lockfile INTENT= PREVIOUS= VERDICT=red:test
decide "red build, fixed label, fixes on branch"   agent "$FIX" ROUNDS=1 VERDICT=red:test

# The skip itself.
decide "green, verified, same diff"                skip "$VER"
decide "green, fixed, fix commits still there"     skip "$FIX" ROUNDS=1
decide "green, fixed, fix commits gone"            agent "$FIX" ROUNDS=0
decide "green, same diff, no verdict label yet"    agent
decide "green, same diff, needs-manual label"      agent 'LABELS=["deps:needs-manual"]'
decide "green, same diff, unrelated labels only"   agent 'LABELS=["dependencies","deps:major"]'

# A new or unknown diff is judged.
decide "green, verified, diff changed"             agent "$VER" INTENT="$H2"
decide "green, verified, no earlier record"        agent "$VER" PREVIOUS=
decide "green, verified, empty diff never matches" agent "$VER" INTENT= PREVIOUS=

# Lock file maintenance has nothing to read.
decide "lock file maintenance, green"              lockfile UPDATE=lockfile INTENT= PREVIOUS=
decide "lock file maintenance, green, any label"   lockfile UPDATE=lockfile INTENT= "$FIX"
decide "lock file title but other files changed"   agent UPDATE=lockfile

# The hash, from compare payloads. file NAME PATCH builds one entry.
file() { jq -nc --arg f "$1" --arg p "$2" '{filename: $f, sha: "s1", patch: $p}'; }
page() { printf '{"files":[%s]}\n' "$(paste -sd, -)"; }
hash_of() { "$HERE/intent.sh" hash; }

# $1 name; the hash must be empty.
no_hash() { if [ -z "$(cat | hash_of)" ]; then ok "$1"; else bad "$1"; fi; }

UPDATE_PATCH=$'@@ -2,3 +2,3 @@\n   "a": "1",\n-  "dep1": "1.0.0",\n+  "dep1": "2.0.0",\n   "b": "1",'
MOVED_PATCH=$'@@ -40,3 +40,3 @@\n   "x": "9",\n-  "dep1": "1.0.0",\n+  "dep1": "2.0.0",\n   "y": "9",'
OTHER_PATCH=$'@@ -2,3 +2,3 @@\n-  "dep1": "1.0.0",\n+  "dep1": "3.0.0",'
LOCK_PATCH=$'@@ -1 +1 @@\n-{"lock":1}\n+{"lock":2}'

h_first="$(file package.json "$UPDATE_PATCH" | page | hash_of)"
if [ -n "$h_first" ]; then ok "a manifest change has a hash"; else bad "a manifest change has a hash"; fi

# A rebase onto a moved base changes the context and the hunk header only.
if [ "$(file package.json "$MOVED_PATCH" | page | hash_of)" = "$h_first" ]; then
  ok "a rebase onto a moved base keeps the hash"; else bad "a rebase onto a moved base keeps the hash"; fi

# The lockfile moves with the update and does not count.
if [ "$( { file package.json "$UPDATE_PATCH"; file package-lock.json "$LOCK_PATCH"; } | page | hash_of)" = "$h_first" ]; then
  ok "a lockfile beside the manifest does not change the hash"; else bad "a lockfile beside the manifest does not change the hash"; fi
file package-lock.json "$LOCK_PATCH" | page | no_hash "a lockfile-only change has no hash"
file crates/x/Cargo.lock "$LOCK_PATCH" | page | no_hash "a nested lockfile has no hash"
file gradle/verification.lockfile "$LOCK_PATCH" | page | no_hash "a .lockfile has no hash"
printf '{"files":[]}\n' | no_hash "an empty diff has no hash"
printf '{}\n' | no_hash "a payload with no files has no hash"

# A different version is a different intent.
h_other="$(file package.json "$OTHER_PATCH" | page | hash_of)"
if [ -n "$h_other" ] && [ "$h_other" != "$h_first" ]; then ok "another version has another hash"
else bad "another version has another hash"; fi

# Any other file counts, so an unknown stack is covered.
h_cat="$(file gradle/libs.versions.toml $'@@ -1 +1 @@\n-a = "1"\n+a = "2"' | page | hash_of)"
if [ -n "$h_cat" ]; then ok "a version catalog change has a hash"; else bad "a version catalog change has a hash"; fi
h_rb="$(file Gemfile $'@@ -1 +1 @@\n-gem "a", "1"\n+gem "a", "2"' | page | hash_of)"
if [ -n "$h_rb" ]; then ok "a manifest of an unlisted stack has a hash"; else bad "a manifest of an unlisted stack has a hash"; fi

# Same lines in another file is another intent.
if [ "$(file other/package.json "$UPDATE_PATCH" | page | hash_of)" != "$h_first" ]; then
  ok "the file name is part of the hash"; else bad "the file name is part of the hash"; fi

# No patch (binary, too large): the blob id stands in, so a change still shows.
a="$(jq -nc '{filename:"tool.jar", sha:"aaa"}' | page | hash_of)"
b="$(jq -nc '{filename:"tool.jar", sha:"bbb"}' | page | hash_of)"
if [ -n "$a" ] && [ "$a" != "$b" ]; then ok "a file with no patch hashes its blob id"; else bad "a file with no patch hashes its blob id"; fi

# Pages and their order do not matter.
p1="$(file package.json "$UPDATE_PATCH" | page)"; p2="$(file a.txt $'@@ -1 +1 @@\n-x\n+y' | page)"
one="$(printf '{"files":[%s,%s]}\n' "$(file package.json "$UPDATE_PATCH")" "$(file a.txt $'@@ -1 +1 @@\n-x\n+y')" | hash_of)"
two="$(printf '%s\n%s\n' "$p2" "$p1" | hash_of)"
if [ "$one" = "$two" ]; then ok "the hash is the same across pages"; else bad "the hash is the same across pages"; fi

# The API stops listing at 300 files: a cut-off list cannot prove anything.
many="$(for i in $(seq 1 300); do file "f$i.txt" $'@@ -1 +1 @@\n-x\n+y'; done | page)"
printf '%s' "$many" | no_hash "a diff cut off at 300 files has no hash"

# Fix commits are counted from the trailer, on any page.
count() {
  local name="$1" want="$2" json="$3" got
  got="$(printf '%s' "$json" | "$HERE/intent.sh" rounds)"
  if [ "$got" = "$want" ]; then ok "$(printf '%-52s -> %s' "$name" "$got")"; else bad "$(printf '%-52s -> %s (wanted %s)' "$name" "$got" "$want")"; fi
}
c() { jq -nc --arg m "$1" '{commit:{message:$m}}'; }
count "no commits"                     0 '{}'
count "a renovate commit"              0 "{\"commits\":[$(c 'chore(deps): update x')]}"
count "a fix commit with the trailer"  1 "{\"commits\":[$(c $'chore(deps): adapt\n\nbody\n\nDeps-Verify-Round: 1')]}"
count "a trailer quoted mid-line"      0 "{\"commits\":[$(c 'notes about Deps-Verify-Round: 1')]}"
count "rounds on two pages"            2 "{\"commits\":[$(c $'a\n\nDeps-Verify-Round: 1')]} {\"commits\":[$(c $'b\n\nDeps-Verify-Round: 2')]}"

# The previous hash comes from the comment body sticky-comment hands back.
prev() {
  local name="$1" want="$2" body="$3" got
  got="$(printf '%s' "$body" | "$HERE/intent.sh" previous)"
  if [ "$got" = "$want" ]; then ok "$(printf '%-52s -> %s' "$name" "${got:0:8}")"
  else bad "$(printf '%-52s -> %s (wanted %s)' "$name" "${got:-<none>}" "${want:-<none>}")"; fi
}
prev "no comment"                      ""    ""
prev "hash read from the comment"      "$H1" "$(printf '**deps:verified** ok\n<!-- deps-intent: %s -->' "$H1")"
prev "comment from before the marker"  ""    "**deps:verified** ok"
prev "a short or malformed hash"       ""    "<!-- deps-intent: abc -->"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
