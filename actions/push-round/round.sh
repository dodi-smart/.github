#!/usr/bin/env bash
# Push one round of an agent's commits to a pull request branch, or refuse it.
# The agent commits and never pushes; this checks what it committed, rewrites
# the round as ONE commit by a fixed identity with a round trailer, and pushes
# it with the App token. Two phases, because the token must not exist while
# the lock command runs dependency tooling:
#
#   check  every refusal, then relock. No token. Outputs ready, refused,
#          recorded (whether a recorded path changed).
#   push   squash, trailers, push. Refuses a branch that moved.
#
# `trailers` prints the replaced commits' trailers a round keeps, for push
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
#   - a commit removes or rewrites a line that a commit in KEEP_RANGE not by
#     AUTHOR_EMAIL added (the dependency bot's chosen versions)
#   - a path matching RECORD_PATHS changed with no entry in RECORDS
#   - the lock command fails, or changes anything but a LOCKFILES path
set -euo pipefail

out() { echo "$1" >> "$GITHUB_OUTPUT"; }
refuse() { git reset -q --hard HEAD; out "refused=$1"; echo "::warning title=Round not pushed::$1"; exit 0; }
oneline() { tr '\n' ' ' | sed 's/ *$//'; }

check() {
  git reset -q --hard HEAD   # uncommitted edits are not part of a round
  out ready=false
  if [ "$(git rev-list --count "$BASE_SHA..HEAD")" = 0 ]; then echo "no commits"; exit 0; fi
  [ "${ALLOWED:-}" = true ] || refuse "${DENIED_WHY:-the caller precondition was not met}"
  [ "$ROUNDS" -lt "${MAX_ROUNDS:-2}" ] || refuse "round cap of ${MAX_ROUNDS:-2} reached"
  local fp=''
  if [ "${MERGE:-}" = true ]; then
    # Those checks diff all of BASE..HEAD, which here includes the base's own changes.
    [ -z "${KEEP_RANGE:-}${RECORD_PATHS:-}${LOCK:-}" ] \
      || refuse "a merge round takes no keep-range, record-paths or lock"
    [ "$(git rev-list --parents -n 1 HEAD | awk '{ print NF }')" = 3 ] && [ "$(git rev-parse HEAD^1)" = "$(git rev-parse "$BASE_SHA")" ] \
      || refuse "a merge round is a merge commit whose first parent is the head it started from"
    fp=--first-parent   # the base's own commits come in by the second parent
  else
    [ -z "$(git rev-list --merges "$BASE_SHA..HEAD")" ] \
      || refuse "a round may not contain a merge commit; only the update job merges"
  fi
  others=$(git log ${fp:+"$fp"} --format='%ae' "$BASE_SHA..HEAD" | grep -vxF -f <(printf '%s' "$AGENT_EMAILS") || true)
  [ -z "$others" ] || refuse "a commit carries another author: $(printf '%s' "$others" | oneline)"
  if [ "${MERGE:-}" = true ]; then
    # Paths the resolution changed: HEAD differs from both parents.
    changed=$(comm -12 <(git diff --name-only --no-renames HEAD^1 HEAD | sort) <(git diff --name-only --no-renames HEAD^2 HEAD | sort))
  else
    changed=$(git diff --name-only "$BASE_SHA" HEAD)
  fi
  if [ -n "${REFUSE_PATHS:-}" ]; then
    hit=$(printf '%s\n' "$changed" | grep -E "$REFUSE_PATHS" || true)
    [ -z "$hit" ] || refuse "a commit touched a path it may not: $(printf '%s' "$hit" | oneline)"
  fi
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
        refuse "a commit changed a line another author set, in $f"
      fi
    done <<<"$changed"
  fi
  recorded=$(printf '%s\n' "$changed" | grep -E "${RECORD_PATHS:-^$}" || true)
  if [ -n "$recorded" ]; then
    n=$(jq -r 'if type == "array" then [.[] | select(.name and .from and .to)] | length else 0 end' "$RECORDS" 2>/dev/null || echo 0)
    [ "$n" -gt 0 ] || refuse "$(printf '%s' "$recorded" | oneline) changed with no record in $(basename "$RECORDS")"
    relock "$recorded"
  fi
  out ready=true
  out "recorded=$([ -n "$recorded" ] && echo true || echo false)"
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
    ( [ -z "${ENV_FILE:-}" ] || . "$ENV_FILE"; cd "$d" && $LOCK ) || refuse "the lock command failed in $d: $LOCK"
  done <<<"$1"
  local status other
  status=$(git status --porcelain)
  other=$(printf '%s\n' "$status" | awk 'NF { print $2 }' | grep -vE "$LOCKFILES" || true)
  [ -z "$other" ] || refuse "the lock command changed more than lockfiles: $(printf '%s' "$other" | oneline)"
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
  [ -n "${APP_TOKEN:-}" ] || refuse "GH_APP_CLIENT_ID is not set, and a GITHUB_TOKEN push starts no checks"
  url="https://x-access-token:${APP_TOKEN}@github.com/${REPO}.git"
  remote=$(git ls-remote "$url" "refs/heads/$HEAD_REF" | cut -f1)
  [ "$remote" = "$BASE_SHA" ] || refuse "the branch moved since checkout"
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
  *) echo "usage: round.sh check|push|trailers" >&2; exit 2 ;;
esac
