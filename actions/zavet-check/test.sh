#!/usr/bin/env bash
# Assert which commits the guard step skips as release commits. Each half of
# the rule alone must still be checked, so the negatives come first.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/release-commit.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zavet-check-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

git -C "$WORK" init -q
git -C "$WORK" config commit.gpgsign false
n=0
# $1 case, $2 want (skip|check), $3 author name, $4 author email, $5 subject
case_() {
  n=$((n + 1))
  echo "$n" > "$WORK/version"
  git -C "$WORK" add -A
  GIT_AUTHOR_NAME="$3" GIT_AUTHOR_EMAIL="$4" GIT_COMMITTER_NAME="$3" GIT_COMMITTER_EMAIL="$4" \
    git -C "$WORK" commit -qm "$5"
  local got=check
  (cd "$WORK" && "$SCRIPT" HEAD) && got=skip
  if [ "$got" = "$2" ]; then ok "$1"; else bad "$1" "got $got, wanted $2"; fi
}

case_ "a person's release-shaped commit is checked" check "Jane Doe" jane@example.invalid "chore(release): v1.2.3 [skip ci]"
case_ "a bot release commit without [skip ci] is checked" check semantic-release-bot semantic-release-bot@martynus.net "chore(release): v1.2.3"
case_ "a bot's other commit is checked" check "renovate[bot]" "29139614+renovate[bot]@users.noreply.github.com" "fix(deps): bump x [skip ci]"
case_ "chore(release) needs the colon form" check "github-actions[bot]" "41898282+github-actions[bot]@users.noreply.github.com" "chore(releases): v1 [skip ci]"
case_ "a bot name in the subject is not an author" check "Jane Doe" jane@example.invalid "chore(release): by semantic-release-bot [skip ci]"
case_ "semantic-release's default identity" skip semantic-release-bot semantic-release-bot@martynus.net "chore(release): v1.2.3 [skip ci]"
case_ "a GitHub App by name" skip "github-actions[bot]" "41898282+github-actions[bot]@users.noreply.github.com" "chore(release): v1.2.4-develop.1 [skip ci]"
case_ "a GitHub App by address alone" skip "Org Release" "123+org-release[bot]@users.noreply.github.com" "chore(release): 1.23.0 [skip ci]"
case_ "a breaking-change release marker" skip "org-release[bot]" x@example.invalid "chore(release)!: 2.0.0 [skip ci]"

if (cd "$WORK" && "$SCRIPT" deadbeef 2>/dev/null); then bad "an unknown sha is checked" "got skip"; else ok "an unknown sha is checked"; fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
