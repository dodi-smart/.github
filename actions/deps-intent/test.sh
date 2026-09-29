#!/usr/bin/env bash
# Assert when the agent is skipped. The costly mistake is a skip that should not
# have happened, above all a `verified` on a red build, so those cases come first.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

H1=$(printf 'a%.0s' {1..64})
H2=$(printf 'b%.0s' {1..64})

# $1 name, $2 want path, then env assignments for the run. Labels default to none.
decide() {
  local name="$1" want="$2" got; shift 2
  got="$(env VERDICT=green UPDATE=other LABELS='[]' ROUNDS=0 INTENT="$H1" PREVIOUS="$H1" "$@" \
         "$HERE/intent.sh" decide | sed -n 's/^path=//p')"
  if [ "$got" = "$want" ]; then ok "$(printf '%-52s -> %s' "$name" "$got")"
  else bad "$(printf '%-52s -> %s (wanted %s)' "$name" "$got" "$want")"; fi
}

VER='LABELS=["deps:verified"]'
FIX='LABELS=["deps:fixed"]'

# Never skip on anything but green.
decide "red build, verified label, same intent"   agent "$VER" VERDICT=red:build
decide "infra failure, verified label"            agent "$VER" VERDICT=red:infra
decide "red lock file maintenance"                agent UPDATE=lockfile INTENT= PREVIOUS= VERDICT=red:test
decide "red build, fixed label, fixes on branch"  agent "$FIX" ROUNDS=1 VERDICT=red:test

# The skip itself.
decide "green, verified, same intent"             unchanged "$VER"
decide "green, fixed, fix commits still there"    unchanged "$FIX" ROUNDS=1
decide "green, fixed, fix commits gone"           agent "$FIX" ROUNDS=0
decide "green, needs-manual label"                agent 'LABELS=["deps:needs-manual"]'
decide "green, no verdict label yet"              agent
decide "green, unrelated labels only"             agent 'LABELS=["dependencies","deps:major"]'

# A new or unknown intent is judged.
decide "green, verified, intent changed"          agent "$VER" INTENT="$H2"
decide "green, verified, no earlier record"       agent "$VER" PREVIOUS=
decide "green, verified, empty diff never matches" agent "$VER" INTENT= PREVIOUS=

# Lock file maintenance has nothing to read.
decide "lock file maintenance, green"             lockfile UPDATE=lockfile INTENT= PREVIOUS=
decide "lock file maintenance, green, any label"  lockfile UPDATE=lockfile INTENT= "$FIX"
decide "lock file title but manifests changed"    agent UPDATE=lockfile

# The lookup reads the sticky comment's hidden line, and only a bot's.
bot()   { printf '{"id":%s,"user":{"type":"Bot"},"body":"%s"}' "$1" "$2"; }
human() { printf '{"id":%s,"user":{"type":"User"},"body":"%s"}' "$1" "$2"; }
M='<!-- dodi-sticky: deps-verify -->'

prev() {
  local name="$1" want="$2" json="$3" got
  got="$(printf '%s' "$json" | "$HERE/intent.sh" previous)"
  if [ "$got" = "$want" ]; then ok "$(printf '%-52s -> %s' "$name" "${got:0:8}")"
  else bad "$(printf '%-52s -> %s (wanted %s)' "$name" "${got:-<none>}" "${want:-<none>}")"; fi
}

prev "no comments"                     ""  '[]'
prev "hash read from the sticky"       "$H1" "[$(bot 1 "$M\\n\\n**deps:verified** ok\\n<!-- deps-intent: $H1 -->")]"
prev "comment from before the marker"  ""  "[$(bot 1 "$M\\n\\n**deps:verified** ok")]"
prev "another key's comment"           ""  "[$(bot 1 "<!-- dodi-sticky: zavet-check -->\\n<!-- deps-intent: $H1 -->")]"
prev "a person quoting it"             ""  "[$(human 1 "$M <!-- deps-intent: $H1 -->")]"
prev "first page and second page"      "$H2" "[$(human 1 x)] [$(bot 2 "$M <!-- deps-intent: $H2 -->")]"
prev "a short or malformed hash"       ""  "[$(bot 1 "$M <!-- deps-intent: abc -->")]"

# The hash, against a real repository.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/deps-intent-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 2
git init -q -b main .
git config user.name t; git config user.email t@example.com
mkdir -p app gradle
seq_json() { printf '{\n  "dependencies": {\n'; for i in 1 2 3 4 5 6 7 8; do printf '    "dep%s": "%s",\n' "$i" "${!i:-1.0.0}"; done; printf '    "last": "1.0.0"\n  }\n}\n'; }
seq_json > package.json
echo '{"lock":1}' > package-lock.json
echo 'plugins {}' > app/build.gradle.kts
echo 'a = "1"' > gradle/libs.versions.toml
echo readme > README.md
git add -A && git commit -qm base
git update-ref refs/remotes/origin/main main

hash_of() { "$HERE/intent.sh" hash main; }

# $1 name. The hash must exist / be empty / equal $h_first.
has_hash() { if [ -n "$(hash_of)" ]; then ok "$1"; else bad "$1"; fi; }
no_hash()  { if [ -z "$(hash_of)" ]; then ok "$1"; else bad "$1"; fi; }

# The update: dep1 goes to 2.0.0, and the lockfile moves with it.
git switch -q -c update
seq_json 2.0.0 > package.json
echo '{"lock":2}' > package-lock.json
git commit -qam "update dep1"
h_first="$(hash_of)"
has_hash "a manifest change has a hash"

# Rebase onto a base that moved: another dependency bumped on the base, far from
# the update, so the context around the update changes.
git switch -q main
seq_json 1.0.0 1.0.0 1.0.0 1.0.0 1.0.0 1.0.0 1.0.0 9.9.9 > package.json
echo readme2 > README.md
git commit -qam "base moves"
git update-ref refs/remotes/origin/main main
git switch -q update
git rebase -q main
grep -q '"dep1": "2.0.0"' package.json || bad "test setup: the rebase kept the update"
if [ "$(hash_of)" = "$h_first" ]; then ok "a rebase onto a moved base keeps the hash"
else bad "a rebase onto a moved base changed the hash"; fi

# Only the lockfile moves: no manifest diff, no hash.
git switch -q -c lockonly main
echo '{"lock":3}' > package-lock.json
git commit -qam "lock file maintenance"
no_hash "a lockfile-only change has no hash"

# A different version is a different intent.
git switch -q -c other main
seq_json 3.0.0 > package.json
git commit -qam "another version"
if [ -n "$(hash_of)" ] && [ "$(hash_of)" != "$h_first" ]; then ok "another version has another hash"
else bad "another version has another hash"; fi

# Nested manifests and catalogs count, other files do not.
git switch -q -c gradleonly main
echo 'a = "2"' > gradle/libs.versions.toml
git commit -qam "catalog"
has_hash "a version catalog change has a hash"
git switch -q -c srconly main
echo 'plugins { x }' > app/build.gradle.kts
git commit -qam "build script"
has_hash "a nested gradle build file has a hash"
git switch -q -c docsonly main
echo more >> README.md
git commit -qam "docs"
no_hash "a non-manifest change has no hash"

# git failing (no such base) must give no hash, so the agent runs.
if [ -z "$("$HERE/intent.sh" hash nonexistent 2>/dev/null)" ]; then ok "an unreadable base gives no hash"
else bad "an unreadable base gives a hash"; fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
