#!/usr/bin/env bash
# Push one round of an agent's commits to a pull request branch, or refuse it.
# The agent commits and never pushes; this checks what it committed, rewrites
# the round as ONE commit by a fixed identity with a round trailer, and pushes
# it with the App token. Two phases, because the token must not exist while
# the lock command runs dependency tooling:
#
#   check  every refusal, then relock. No token. Outputs ready, refused,
#          record (the refusal's durable marker), recorded (whether a
#          recorded path changed).
#   push   squash, trailers, push. Refuses a branch that moved.
#
# `record KIND ROUND [HITS]` prints a refusal's marker, for factory.sh's
# round 0. `trailers` prints the replaced commits' trailers a round keeps, for push
# and for the factory's round 0, so one rule decides it.
#
# MERGE=true is the one other kind of round: the update job's one merge of the
# base into a conflicted branch, first parent BASE_SHA, amended in place and
# never squashed. Only the paths the resolution changed count as the round's.
#
# A round is refused, never forced, when:
#   - ALLOWED is not true (the caller's own precondition, DENIED_WHY says why)
#   - the round cap is reached
#   - a commit carries an author outside AGENT_EMAILS
#   - the range holds a merge commit (a soft reset across one would squash the
#     base's changes into the round), or MERGE=true and HEAD is not one merge
#     of the base onto BASE_SHA
#   - a commit touches a path matching REFUSE_PATHS (lockfiles; a holdout list)
#   - guard.sh finds the round weakening a test or touching a gate file
#     (a workflow, the merge gate, lint, test-runner or coverage config). Every
#     round, no input turns it off; a merge round is checked for gate files on
#     what its resolution changed
#   - a commit removes or rewrites a line that a commit in KEEP_RANGE not by
#     AUTHOR_EMAIL added (the dependency bot's chosen versions)
#   - a path matching RECORD_PATHS changed with no entry in RECORDS
#   - the lock command fails, or changes anything but a LOCKFILES path
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out() { echo "$1" >> "$GITHUB_OUTPUT"; }
# refuse KIND WHY [HITS]: every refusal also writes `record`, the durable,
# metadata-only line a caller appends to its hand-off comment (see record).
refuse() {
  git reset -q --hard HEAD
  out "refused=$2"
  out "record=$(record "$1" "$(( ${ROUNDS:-0} + 1 ))" "${3:-}")"
  echo "::warning title=Round not pushed::$2"
  exit 0
}

# record KIND ROUND [HITS]: one HTML comment that proba's factory.*
# checks and the factory scorecard count refusals by:
#
#   <!-- dodi-factory:refusal {"v":1,"kind":"guard","round":2,"rules":{"deletes_test":1},"findings":1} -->
#
# Metadata only: a kind, the round it would have been, and for the guard the
# rule ids it found and how many. Never a path, a line or the reason's text,
# so anyone who can read the PR can count it without reading the change.
# Kinds: precondition cap merge-shape author refuse-path guard guard-error
# keep-range record lock moved token; from factory.sh round 0 also exists;
# and from pr-iterate's update job `conflict`, a merge it would not resolve. A reader keys on `v` and skips a kind it does not know. Callers post
# it with the org App's token, the one login a reader trusts it from.
# HITS is guard.sh's findings, one `path: what` line each. Matched on the
# whole wording, as a suffix: the path is the agent's and may hold anything.
rule_of() {
  case "$1" in
    *': deletes a snapshot') echo deletes_snapshot ;;
    *': deletes a test file') echo deletes_test ;;
    *': renames a test file to '*', which is not a test path') echo renames_test_away ;;
    *': touches a gate file') echo touches_gate_file ;;
    *': changes a test, lint or check script') echo changes_check_script ;;
    *': removes a snapshot entry') echo removes_snapshot_entry ;;
    *': adds a skip, focus or retry marker') echo adds_skip_marker ;;
    *': removes a test case') echo removes_test_case ;;
    *': removes an assertion') echo removes_assertion ;;
    *': loosens an exact assertion') echo loosens_assertion ;;
    *) echo other ;;
  esac
}
record() {
  local kind="$1" round="$2" rules l
  rules=$(while IFS= read -r l; do [ -z "$l" ] || rule_of "$l"; done <<<"${3:-}")
  printf '<!-- dodi-factory:refusal %s -->' "$(printf '%s\n' "$rules" | jq -Rnc --arg kind "$kind" --argjson round "$round" '
    [inputs | select(length > 0)] | group_by(.) | map({(.[0]): length}) | add // {}
    | {v: 1, kind: $kind, round: $round, rules: ., findings: ([.[]] | add // 0)}')"
}
oneline() { tr '\n' ' ' | sed 's/ *$//'; }

check() {
  git reset -q --hard HEAD   # uncommitted edits are not part of a round
  out ready=false
  if [ "$(git rev-list --count "$BASE_SHA..HEAD")" = 0 ]; then echo "no commits"; exit 0; fi
  [ "${ALLOWED:-}" = true ] || refuse precondition "${DENIED_WHY:-the caller precondition was not met}"
  [ "$ROUNDS" -lt "${MAX_ROUNDS:-2}" ] || refuse cap "round cap of ${MAX_ROUNDS:-2} reached"
  local fp=''
  if [ "${MERGE:-}" = true ]; then
    # Those checks diff all of BASE..HEAD, which here includes the base's own changes.
    [ -z "${KEEP_RANGE:-}${RECORD_PATHS:-}${LOCK:-}" ] \
      || refuse merge-shape "a merge round takes no keep-range, record-paths or lock"
    [ "$(git rev-list --parents -n 1 HEAD | awk '{ print NF }')" = 3 ] && [ "$(git rev-parse HEAD^1)" = "$(git rev-parse "$BASE_SHA")" ] \
      || refuse merge-shape "a merge round is a merge commit whose first parent is the head it started from"
    fp=--first-parent   # the base's own commits come in by the second parent
  else
    [ -z "$(git rev-list --merges "$BASE_SHA..HEAD")" ] \
      || refuse merge-shape "a round may not contain a merge commit; only the update job merges"
  fi
  others=$(git log ${fp:+"$fp"} --format='%ae' "$BASE_SHA..HEAD" | grep -vxF -f <(printf '%s' "$AGENT_EMAILS") || true)
  [ -z "$others" ] || refuse author "a commit carries another author: $(printf '%s' "$others" | oneline)"
  if [ "${MERGE:-}" = true ]; then
    # Paths the resolution changed: HEAD differs from both parents.
    changed=$(comm -12 <(git diff --name-only --no-renames HEAD^1 HEAD | sort) <(git diff --name-only --no-renames HEAD^2 HEAD | sort))
  else
    changed=$(git diff --name-only "$BASE_SHA" HEAD)
  fi
  if [ -n "${REFUSE_PATHS:-}" ]; then
    hit=$(printf '%s\n' "$changed" | grep -E "$REFUSE_PATHS" || true)
    [ -z "$hit" ] || refuse refuse-path "a commit touched a path it may not: $(printf '%s' "$hit" | oneline)"
  fi
  guard "$changed"
  if [ -n "${KEEP_RANGE:-}" ]; then
    # The lines another author's commits in the range added: a round may sit
    # beside them, never replace them.
    kept=$(git log --format='%H %ae' "$KEEP_RANGE" \
             | while read -r c e; do [ "$e" = "$AUTHOR_EMAIL" ] || git show --format= --name-only "$c"; done | sort -u)
    while read -r f; do
      [ -n "$f" ] || continue
      grep -qxF "$f" <<<"$kept" || continue
      added=$(git diff "${KEEP_RANGE%%..*}" "${KEEP_RANGE##*..}" -- "$f" | sed -n 's/^+//p' | grep -v '^++' || true)
      removed=$(git diff "$BASE_SHA" HEAD -- "$f" | sed -n 's/^-//p' | grep -v '^--' || true)
      if [ -n "$added" ] && [ -n "$removed" ] && grep -qxF -f <(printf '%s\n' "$added") <<<"$removed"; then
        refuse keep-range "a commit changed a line another author set, in $f"
      fi
    done <<<"$changed"
  fi
  recorded=$(printf '%s\n' "$changed" | grep -E "${RECORD_PATHS:-^$}" || true)
  if [ -n "$recorded" ]; then
    n=$(jq -r 'if type == "array" then [.[] | select(.name and .from and .to)] | length else 0 end' "$RECORDS" 2>/dev/null || echo 0)
    [ "$n" -gt 0 ] || refuse record "$(printf '%s' "$recorded" | oneline) changed with no record in $(basename "$RECORDS")"
    relock "$recorded"
  fi
  out ready=true
  out "recorded=$([ -n "$recorded" ] && echo true || echo false)"
}

# The test-weakening guard, for every round here and round 0 in factory.sh
# (`round.sh guard ARGS...`), so one rule words the refusal. Sets `why` (why a
# round is refused) and `hits` (guard.sh's findings, for the record) and
# returns 1 on findings, 2 when the guard could not run: a broken guard may
# only refuse more.
guard_refusal() {
  local rc=0
  why=''
  hits=$("$HERE/guard.sh" "$@") || rc=$?
  case "$rc" in
    0) hits=''; return 0 ;;
    1) why="a round may not weaken a test or touch a gate file: $(printf '%s' "$hits" | paste -sd ';' - | sed 's/;/; /g')"
       return 1 ;;
    *) hits=''; why="the test guard could not run (exit $rc), so the round is refused"; return 2 ;;
  esac
}
guard() {
  local why hits rc=0
  if [ "${MERGE:-}" = true ]; then
    guard_refusal --paths <<<"$1" || rc=$?
  else
    guard_refusal "$BASE_SHA" HEAD || rc=$?
  fi
  case "$rc" in
    0) ;;
    1) refuse guard "$why" "$hits" ;;
    *) refuse guard-error "$why" ;;
  esac
}

# Rewrite the lockfile nearest each changed declaration with LOCK, once per
# directory, and commit the result as part of the round.
relock() {
  [ -n "${LOCK:-}" ] || return 0
  local f d
  declare -A seen=()
  has_lock() { find "$1" -maxdepth 1 -type f 2>/dev/null | sed 's|^\./||' | grep -qE "$LOCKFILES"; }
  while read -r f; do
    [ -n "$f" ] || continue
    d=$(dirname "$f")
    until has_lock "$d" || [ "$d" = . ]; do d=$(dirname "$d"); done
    has_lock "$d" || continue
    if [ -n "${seen[$d]:-}" ]; then continue; fi
    seen[$d]=1
    echo "relock in $d: $LOCK"
    # LOCK is the caller's one command, split into words on purpose.
    # shellcheck disable=SC1090,SC2086
    ( [ -z "${ENV_FILE:-}" ] || . "$ENV_FILE"; cd "$d" && $LOCK ) || refuse lock "the lock command failed in $d: $LOCK"
  done <<<"$1"
  local status other
  status=$(git status --porcelain)
  other=$(printf '%s\n' "$status" | awk 'NF { print $2 }' | grep -vE "$LOCKFILES" || true)
  [ -z "$other" ] || refuse lock "the lock command changed more than lockfiles: $(printf '%s' "$other" | oneline)"
  if [ -n "$status" ]; then
    git add -A
    GIT_COMMITTER_NAME="$AUTHOR_NAME" GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
      git commit -q --author="$AUTHOR_NAME <$AUTHOR_EMAIL>" -m "chore(deps): regenerate lockfiles"
  fi
}

# The trailers on the commits a round replaces, once each, minus the keys the
# loop counts or writes: a kept one would forge the round count or a bump
# record. Keys compare case-insensitively, as git's do.
keep_trailers() {
  git log --reverse --format='%(trailers:only,unfold)' "$BASE_SHA..HEAD" \
    | awk -v keys="Factory-Round Factory-Issue ${TRAILER_KEY:-} ${RECORD_TRAILER:-}" '
        BEGIN { n = split(tolower(keys), k, " "); for (i = 1; i <= n; i++) drop[k[i]] = 1 }
        /^[[:space:]]*$/ || seen[$0]++ { next }
        { key = tolower($0); sub(/[[:space:]]*:.*/, "", key); sub(/^[[:space:]]+/, "", key); if (!(key in drop)) print }'
}

# Merge mode: the merge commit stays a merge. Its message is its own subject
# (commitlint's default ignores match `Merge ... into ...`) and the round trailer.
push_merge() {
  GIT_COMMITTER_NAME="$AUTHOR_NAME" GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
    git commit -q --amend --author="$AUTHOR_NAME <$AUTHOR_EMAIL>" -m "$(git log -1 --format=%s)" -m "$TRAILER_KEY: $(( ROUNDS + 1 ))"
}

push() {
  out pushed=false
  if [ "${MERGE:-}" = true ]; then
    push_merge
  else
    push_squash
  fi
  [ -n "${APP_TOKEN:-}" ] || refuse token "GH_APP_CLIENT_ID is not set, and a GITHUB_TOKEN push starts no checks"
  url="https://x-access-token:${APP_TOKEN}@github.com/${REPO}.git"
  remote=$(git ls-remote "$url" "refs/heads/$HEAD_REF" | cut -f1)
  [ "$remote" = "$BASE_SHA" ] || refuse moved "the branch moved since checkout"
  git push -q "$url" "HEAD:refs/heads/$HEAD_REF"
  out pushed=true
  echo "::notice title=Round pushed::Round $(( ROUNDS + 1 )) to $HEAD_REF."
}

push_squash() {
  first=$(git log --reverse --format='%s' "$BASE_SHA..HEAD" | sed -n 1p)
  rest=$(git log --reverse --format='- %s' "$BASE_SHA..HEAD" | tail -n +2)
  trailers="$TRAILER_KEY: $(( ROUNDS + 1 ))"
  if [ "${RECORDED:-}" = true ] && [ -n "${RECORD_TRAILER:-}" ]; then
    trailers="$trailers"$'\n'$(jq -r --arg k "$RECORD_TRAILER" '.[] | select(.name and .from and .to) | "\($k): \(.name) \(.from) -> \(.to)"' "$RECORDS")
  fi
  kept=$(keep_trailers)
  [ -z "$kept" ] || trailers="$trailers"$'\n'"$kept"
  args=(-m "$first")
  [ -n "$rest" ] && args+=(-m "$rest")
  args+=(-m "$trailers")
  # The author is set outright, never read from git config: claude-code-action
  # rewrites that config. A bot's ignore list matches this exact author.
  git reset -q --soft "$BASE_SHA"
  GIT_COMMITTER_NAME="$AUTHOR_NAME" GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
    git commit -q --author="$AUTHOR_NAME <$AUTHOR_EMAIL>" "${args[@]}"
}

case "${1:-}" in
  check) check ;;
  push)  push ;;
  trailers) keep_trailers ;;
  # Prints why; with GUARD_HITS set, also writes the findings there, for record.
  guard) shift; rc=0; guard_refusal "$@" || rc=$?
    [ -z "$why" ] || echo "$why"
    [ -z "${GUARD_HITS:-}" ] || printf '%s\n' "$hits" > "$GUARD_HITS"
    exit "$rc" ;;
  record) shift; record "$@"; echo ;;
  *) echo "usage: round.sh check|push|trailers|guard|record" >&2; exit 2 ;;
esac
