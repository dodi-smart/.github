#!/usr/bin/env bash
# Assert what push-round accepts, rewrites and refuses, in throwaway git repos.
# The push itself is never reached: with no App token the push phase refuses
# after it has written the round's commit, which is the part asserted here.
# The emails and stub bodies are single-quoted on purpose.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/push-round-test.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
expect() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

FIX_NAME='github-actions[bot]'
FIX_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
CLAUDE_EMAIL='41898282+claude[bot]@users.noreply.github.com'
AGENT_EMAILS="$(printf '%s\n%s' "$FIX_EMAIL" "$CLAUDE_EMAIL")"
LOCKS="$(cat "$HERE/../setup-stack/lockfiles.re")"
VERSIONS='(^|/)(package\.json|gradle/wrapper/gradle-wrapper\.properties|mise\.toml)$'

# A repo with the dependency bot's commit on a branch, as a job finds it after
# checkout. Sets BASE and leaves claude-code-action's identity in the config.
repo() {
  local r="$WORK/r"
  rm -rf "$r" "$WORK/origin.git" "$WORK/records.json"
  git init -q --bare -b main "$WORK/origin.git"
  git clone -q "$WORK/origin.git" "$r" 2>/dev/null
  git -C "$r" config user.name t; git -C "$r" config user.email t@example.com
  printf '{\n  "x": "1"\n}\n' > "$r/package.json"
  [ -n "${LOCKFILE:-}" ] && printf 'lock 1\n' > "$r/$LOCKFILE"
  git -C "$r" add -A; git -C "$r" commit -q -m init
  git -C "$r" push -q origin main
  git -C "$r" checkout -q -b renovate/x
  printf '{\n  "x": "2"\n}\n' > "$r/package.json"
  git -C "$r" add -A
  git -C "$r" -c user.name=renovate -c user.email=renovate@example.com commit -q -m 'chore(deps): bump x'
  BASE="$(git -C "$r" rev-parse HEAD)"
  git -C "$r" config user.name 'claude[bot]'
  git -C "$r" config user.email "$CLAUDE_EMAIL"
}
# commit EMAIL FILE [CONTENT] [TRAILERS]: a commit as the agent would leave it;
# TRAILERS is a paragraph of its own.
commit() {
  mkdir -p "$(dirname "$WORK/r/$2")"
  printf '%s\n' "${3:-$RANDOM}" > "$WORK/r/$2"
  git -C "$WORK/r" add -A
  git -C "$WORK/r" -c user.name=who -c "user.email=$1" commit -q -m "fix: adapt to x ($2)" ${4:+-m "$4"}
}
records() { printf '%s' "$1" > "$WORK/records.json"; }

# round [ROUNDS]: check, then push when ready, as the action chains them. A
# merge round takes no keep-range, record-paths or lock; KEEPR, RECP and LOCK
# set them anyway.
phase() {
  local kr="origin/main..$BASE" rp="$VERSIONS" lk='npm install --package-lock-only --ignore-scripts'
  [ -z "${MERGE:-}" ] || { kr=''; rp=''; lk=''; }
  ( cd "$WORK/r" && env -i PATH="$WORK/bin:$PATH" HOME="$WORK" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      AUTHOR_NAME="$FIX_NAME" AUTHOR_EMAIL="$FIX_EMAIL" AGENT_EMAILS="$AGENT_EMAILS" \
      ALLOWED="${ALLOWED-true}" DENIED_WHY="${DENIED_WHY:-}" BASE_SHA="$BASE" ROUNDS="${ROUNDS:-0}" MAX_ROUNDS=2 \
      REFUSE_PATHS="${REFUSE:-$LOCKS}" MERGE="${MERGE:-}" KEEP_RANGE="${KEEPR-$kr}" RECORD_PATHS="${RECP-$rp}" RECORDS="$WORK/records.json" \
      LOCK="${LOCK-$lk}" LOCKFILES="$LOCKS" ENV_FILE='' \
      TRAILER_KEY=Deps-Verify-Round RECORD_TRAILER=Deps-Verify-Bump RECORDED="$(sed -n 's/^recorded=//p' "$WORK/out")" \
      HEAD_REF=renovate/x REPO=o/r APP_TOKEN='' GITHUB_OUTPUT="$WORK/out" bash "$HERE/round.sh" "$1" ) >> "$WORK/log" 2>&1
}
round() {
  : > "$WORK/out"; : > "$WORK/log"
  ROUNDS="${1:-0}" phase check
  grep -qx 'ready=true' "$WORK/out" && ROUNDS="${1:-0}" phase push
  return 0
}
field()   { git -C "$WORK/r" log -1 --format="$1"; }
body()    { git -C "$WORK/r" log -1 --format=%B; }
refused() { sed -n 's/^refused=//p' "$WORK/out"; }
NO_TOKEN='GH_APP_CLIENT_ID is not set, and a GITHUB_TOKEN push starts no checks'
mkdir -p "$WORK/bin"

# Authors.
repo; commit "$CLAUDE_EMAIL" src/a.ts; commit "$CLAUDE_EMAIL" src/b.ts
round
expect "claude[bot] commits pass the author check"   test "$(refused)" = "$NO_TOKEN"
expect "the round is one commit on the base"         test "$(git -C "$WORK/r" rev-list --count "$BASE..HEAD")" = 1
expect "its author is the fix identity"              test "$(field '%an <%ae>')" = "$FIX_NAME <$FIX_EMAIL>"
expect "its committer is the fix identity"           test "$(field '%cn <%ce>')" = "$FIX_NAME <$FIX_EMAIL>"
expect "it carries the round trailer"                grep -qx 'Deps-Verify-Round: 1' <(body)
expect "a code-only round carries no record trailer" bash -c '! grep -q Deps-Verify-Bump <<<"$1"' _ "$(body)"
expect "it keeps both changes"                       test "$(git -C "$WORK/r" show --format= --name-only HEAD | sort | tr '\n' ' ')" = 'src/a.ts src/b.ts '
repo; commit "$FIX_EMAIL" src/a.ts
round
expect "fix-identity commits pass too"               test "$(field '%ae')" = "$FIX_EMAIL"
repo; commit 'person@example.com' src/a.ts
before="$(git -C "$WORK/r" rev-parse HEAD)"
round
expect "a person's commit is refused"                test "$(refused)" = 'a commit carries another author: person@example.com'
expect "and nothing is rewritten"                    test "$(git -C "$WORK/r" rev-parse HEAD)" = "$before"
repo; commit "$CLAUDE_EMAIL" src/a.ts; commit 'renovate@example.com' src/b.ts
round
expect "one stranger among agent commits refuses the round" test "$(refused)" = 'a commit carries another author: renovate@example.com'

# What else the agent signed its commits with is kept, after the round's own.
# The trailers the loop counts or writes are never the agent's to supply.
trailers() { git -C "$WORK/r" log -1 --format='%(trailers:only,unfold)' | sed '/^$/d'; }
repo; commit "$CLAUDE_EMAIL" src/a.ts '' $'Decision: D-12\nCo-Authored-By: A <a@example.com>'
commit "$CLAUDE_EMAIL" src/b.ts '' 'Decision: D-12'
round
expect "a trailer the agent wrote is kept after the round's, once though two commits carried it" \
  test "$(trailers)" = $'Deps-Verify-Round: 1\nDecision: D-12\nCo-Authored-By: A <a@example.com>'
expect "and git parses it as part of the one trailer block" \
  test "$(body | git interpret-trailers --parse | grep -c '^Decision: D-12$')" = 1
repo; commit "$CLAUDE_EMAIL" src/a.ts '' $'Deps-Verify-Round: 9\nDeps-Verify-Bump: peer 1 -> 9\nFactory-Round: 7\nDecision: D-3'
commit "$CLAUDE_EMAIL" src/b.ts '' $'deps-verify-round : 8'
round
expect "forged round and record trailers are dropped" test "$(trailers)" = $'Deps-Verify-Round: 1\nDecision: D-3'
expect "and no forged value is anywhere in the message" \
  bash -c '! grep -qE "Round: 9|Round: 7|peer 1 -> 9|round : 8" <<<"$1"' _ "$(body)"
repo; commit "$CLAUDE_EMAIL" package.json "$(printf '{\n  "peer": "5",\n  "x": "2"\n}')" $'Deps-Verify-Bump: peer 1 -> 9\nDecision: D-3'
records '[{"name":"peer","from":"4","to":"5","why":"w"}]'
round
expect "a recorded bump's own trailer replaces a forged one" \
  test "$(trailers)" = $'Deps-Verify-Round: 1\nDeps-Verify-Bump: peer 4 -> 5\nDecision: D-3'

# The caller's precondition and the cap.
repo; commit "$CLAUDE_EMAIL" src/a.ts
before="$(git -C "$WORK/r" rev-parse HEAD)"
ALLOWED=false DENIED_WHY='Renovate does not ignore the fix author here' round
expect "the caller's precondition refuses first"      test "$(refused)" = 'Renovate does not ignore the fix author here'
expect "and leaves the commits as they were"         test "$(git -C "$WORK/r" rev-parse HEAD)" = "$before"
repo; commit "$CLAUDE_EMAIL" src/a.ts
ALLOWED='' round
expect "an unread precondition refuses, never guesses" test "$(refused)" = "the caller precondition was not met"
repo; commit "$CLAUDE_EMAIL" src/a.ts
round 2
expect "the round cap refuses"                       test "$(refused)" = 'round cap of 2 reached'

# Paths and lines.
repo; commit "$CLAUDE_EMAIL" yarn.lock
round
expect "a hand-edited lockfile is refused"           test "$(refused)" = 'a commit touched a path it may not: yarn.lock'
repo; commit "$CLAUDE_EMAIL" package.json "$(printf '{\n  "x": "3"\n}')"
records '[{"name":"x","from":"2","to":"3","why":"w"}]'
round
expect "a line the bot set is never changed, record or not" test "$(refused)" = 'a commit changed a line another author set, in package.json'
repo; commit "$CLAUDE_EMAIL" package.json "$(printf '{\n  "peer": "5",\n  "x": "2"\n}')"
round
expect "a version declaration with no record is refused" test "$(refused)" = 'package.json changed with no record in records.json'

# A recorded companion version goes through, with its trailer.
repo; commit "$CLAUDE_EMAIL" package.json "$(printf '{\n  "peer": "5",\n  "x": "2"\n}')"
records '[{"name":"peer","from":"4","to":"5","why":"x 2 needs peer 5"}]'
round
expect "a recorded bump beside the bot's line passes" test "$(refused)" = "$NO_TOKEN"
expect "and carries its record trailer"              grep -qx 'Deps-Verify-Bump: peer 4 -> 5' <(body)
expect "beside the round trailer"                    grep -qx 'Deps-Verify-Round: 1' <(body)
repo; commit "$CLAUDE_EMAIL" gradle/wrapper/gradle-wrapper.properties 'distributionUrl=gradle-9.6-bin.zip'
records '[{"name":"gradle","from":"9.5.0","to":"9.6.0","why":"AGP needs it"}]'
round
expect "a Gradle wrapper bump the bot did not touch passes" grep -qx 'Deps-Verify-Bump: gradle 9.5.0 -> 9.6.0' <(body)

# Relock: the lock command rewrites the lockfile, never the agent.
printf '%s\n' '#!/usr/bin/env bash' 'echo "$*" > "$HOME/npm-args"; echo "lock 2" > package-lock.json' > "$WORK/bin/npm"
chmod +x "$WORK/bin/npm"
LOCKFILE=package-lock.json repo; commit "$CLAUDE_EMAIL" package.json "$(printf '{\n  "peer": "5",\n  "x": "2"\n}')"
records '[{"name":"peer","from":"4","to":"5","why":"w"}]'
round
expect "relock runs the lock command"                grep -qx 'install --package-lock-only --ignore-scripts' "$WORK/npm-args"
expect "the regenerated lockfile is in the round"    grep -qx 'package-lock.json' <(git -C "$WORK/r" show --format= --name-only HEAD)
expect "and the round is still one commit"           test "$(git -C "$WORK/r" rev-list --count "$BASE..HEAD")" = 1
printf '%s\n' '#!/usr/bin/env bash' 'echo "lock 2" > package-lock.json; echo x > stray.txt' > "$WORK/bin/npm"
LOCKFILE=package-lock.json repo; commit "$CLAUDE_EMAIL" package.json "$(printf '{\n  "peer": "5",\n  "x": "2"\n}')"
records '[{"name":"peer","from":"4","to":"5","why":"w"}]'
round
expect "a lock command that changes more than lockfiles refuses" test "$(refused)" = 'the lock command changed more than lockfiles: stray.txt'
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$WORK/bin/npm"
LOCKFILE=package-lock.json repo; commit "$CLAUDE_EMAIL" package.json "$(printf '{\n  "peer": "5",\n  "x": "2"\n}')"
records '[{"name":"peer","from":"4","to":"5","why":"w"}]'
round
expect "a failing lock command refuses"              test "$(refused)" = 'the lock command failed in .: npm install --package-lock-only --ignore-scripts'
expect "and nothing is pushed"                       bash -c '! grep -q pushed=true "$1"' _ "$WORK/out"
rm -f "$WORK/bin/npm"
repo; commit "$CLAUDE_EMAIL" package.json "$(printf '{\n  "peer": "5",\n  "x": "2"\n}')"
records '[{"name":"peer","from":"4","to":"5","why":"w"}]'
round
expect "no lockfile near the declaration: nothing to relock" test "$(refused)" = "$NO_TOKEN"

# Merge mode: the update job merges the base into a conflicted branch. The
# round is that one merge commit, pushed as a merge with the round trailer.
# Only what the resolution changed is the round's. REFUSE is the pattern the
# workflow builds: a holdout list or a lockfile.
HOLD='(^test/a\.test\.ts$)|('"$LOCKS"')'
advance() {  # advance EMAIL FILE [CONTENT] [TRAILERS]: a commit on main, the base moving
  git -C "$WORK/r" checkout -q main
  commit "$@"
  git -C "$WORK/r" push -q origin main
  git -C "$WORK/r" checkout -q renovate/x
}
# The job's BASE_SHA is the branch head it checked out, before the merge.
merge_in() { BASE="$(git -C "$WORK/r" rev-parse HEAD)"; git -C "$WORK/r" merge -q --no-edit --no-ff origin/main > /dev/null 2>&1; }
parents() { git -C "$WORK/r" rev-list --parents -n 1 HEAD; }
merged_repo() { repo; commit "$CLAUDE_EMAIL" src/a.ts; advance 'person@example.com' src/b.ts; merge_in; }
conflicted_repo() {  # conflicted_repo FILE: both sides changed FILE, the merge stopped
  repo; commit "$CLAUDE_EMAIL" "$1" branch; advance 'person@example.com' "$1" base; merge_in
}
resolve() { printf 'resolved\n' > "$WORK/r/$1"; git -C "$WORK/r" add -A; git -C "$WORK/r" commit -q --no-edit; }
merge_round() { MERGE=true REFUSE="$HOLD" round "$@"; }

repo; commit "$CLAUDE_EMAIL" src/a.ts
advance 'person@example.com' yarn.lock; advance 'other@example.com' test/a.test.ts
merge_in; before="$(git -C "$WORK/r" rev-parse HEAD)"
merge_round
expect "merge: a clean merge of a base that changed a lockfile and a holdout path is ready" test "$(refused)" = "$NO_TOKEN"
expect "merge: the pushed commit is still a merge, of three fields" test "$(parents | awk '{ print NF }')" = 3
expect "merge: its first parent is the head the job started from" test "$(parents | cut -d' ' -f2)" = "$BASE"
expect "merge: it keeps the merge's own subject" test "$(field %s)" = "Merge remote-tracking branch 'origin/main' into renovate/x"
expect "merge: it carries the round trailer, parsed as a trailer" test "$(body | git interpret-trailers --parse)" = 'Deps-Verify-Round: 1'
expect "merge: authored and committed as the fix identity" test "$(field '%an <%ae>|%cn <%ce>')" = "$FIX_NAME <$FIX_EMAIL>|$FIX_NAME <$FIX_EMAIL>"
expect "merge: the merge was rewritten, so the amend changed it" test "$(git -C "$WORK/r" rev-parse HEAD)" != "$before"
repo; commit "$CLAUDE_EMAIL" src/a.ts '' $'Decision: D-1'
advance 'person@example.com' src/b.ts '' $'Decision: D-2\nDeps-Verify-Round: 9'
merge_in
merge_round 1
expect "merge: no trailer of the base's or the branch's is kept" test "$(body | git interpret-trailers --parse)" = 'Deps-Verify-Round: 2'

# A resolution that edits a refused path is the round's doing.
conflicted_repo test/a.test.ts; resolve test/a.test.ts
before="$(git -C "$WORK/r" rev-parse HEAD)"
merge_round
expect "merge: a resolution that changes a holdout path is refused" test "$(refused)" = 'a commit touched a path it may not: test/a.test.ts'
expect "merge: and nothing is rewritten" test "$(git -C "$WORK/r" rev-parse HEAD)" = "$before"
conflicted_repo test/a.test.ts
git -C "$WORK/r" checkout -q --ours test/a.test.ts; git -C "$WORK/r" add -A; git -C "$WORK/r" commit -q --no-edit
merge_round
expect "merge: a resolution that keeps the branch's file is not the round's" test "$(refused)" = "$NO_TOKEN"
conflicted_repo src/a.ts; resolve src/a.ts
merge_round
expect "merge: a resolution of an ordinary conflict is ready" test "$(refused)" = "$NO_TOKEN"
conflicted_repo yarn.lock; resolve yarn.lock
merge_round
expect "merge: a resolved lockfile is refused too" test "$(refused)" = 'a commit touched a path it may not: yarn.lock'

# Shape: one merge whose first parent is the head, and nothing else.
SHAPE='a merge round is a merge commit whose first parent is the head it started from'
merged_repo; commit "$CLAUDE_EMAIL" src/c.ts
merge_round
expect "merge: a commit on top of the merge is refused" test "$(refused)" = "$SHAPE"
repo; commit "$CLAUDE_EMAIL" src/a.ts
merge_round
expect "merge: one plain commit is no merge" test "$(refused)" = "$SHAPE"
repo; commit "$CLAUDE_EMAIL" src/a.ts; advance 'person@example.com' src/b.ts
git -C "$WORK/r" checkout -q -b other origin/main
git -C "$WORK/r" merge -q --no-edit --no-ff renovate/x > /dev/null 2>&1
merge_round
expect "merge: a merge of the branch into the base is refused" test "$(refused)" = "$SHAPE"
merged_repo
git -C "$WORK/r" commit -q --amend --author='Person <person@example.com>' --no-edit
merge_round
expect "merge: the merge itself must be by an agent identity" test "$(refused)" = 'a commit carries another author: person@example.com'
merged_repo
merge_round 2
expect "merge: the round cap applies" test "$(refused)" = 'round cap of 2 reached'
# Those checks diff all of BASE..HEAD, which here holds the base's own changes.
for v in 'KEEPR origin/main..HEAD' "RECP $VERSIONS" 'LOCK true'; do
  read -r k val <<<"$v"
  merged_repo
  ( export "$k=$val"; merge_round )
  expect "merge: a merge round with $k set is refused" test "$(refused)" = 'a merge round takes no keep-range, record-paths or lock'
done
repo
merge_round
expect "merge: nothing to merge is no round and no refusal" bash -c '! grep -q "ready=true\|refused" "$1"' _ "$WORK/out"

# Hardening: a normal round squashes with a soft reset, and across a merge
# that would fold the base's changes into the round.
merged_repo; before="$(git -C "$WORK/r" rev-parse HEAD)"
round
expect "a normal round with a merge commit in it is refused" test "$(refused)" = 'a round may not contain a merge commit; only the update job merges'
expect "and nothing is rewritten" test "$(git -C "$WORK/r" rev-parse HEAD)" = "$before"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
