#!/usr/bin/env bash
# Assert the three rules that live in scripts beside the action: which commits
# the guard step skips as release commits (release-commit.sh), what needs
# installing (need.sh) and which PRs are promotions (promotion.sh). Each half
# of a rule alone must still not trigger it, so the negatives come first.
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

# need.sh: `cli` is a regular executable file, `declared` counts decision and
# spec files with a top-level `checks:` key, `install` is both together.
# $1 case, $2 want cli, $3 want declared, $4 want install, $5 dir
need_() {
  local got; got=$("$HERE/need.sh" "$5" | tr '\n' ' ')
  if [ "$got" = "cli=$2 declared=$3 install=$4 " ]; then ok "$1"; else bad "$1" "got ${got% }, wanted cli=$2 declared=$3 install=$4"; fi
}
N="$WORK/need"
cli_()    { mkdir -p "$N/$1/bin"; printf '#!/bin/sh\n' > "$N/$1/bin/zavet"; chmod "$2" "$N/$1/bin/zavet"; }
checks_() { mkdir -p "$N/$1"; printf -- '---\nid: x\nchecks:\n  - run: true\n---\n' > "$N/$1/$2.md"; }

cli_ plain +x;       mkdir -p "$N/plain/decisions"
# `checks:` anywhere but the start of a line is prose or a nested key, not a declaration.
printf -- '---\nid: a\n---\nThe checks: below are run.\n  checks: indented\n' > "$N/plain/decisions/a.md"
cli_ nodecisions +x
cli_ withchecks +x;  checks_ withchecks/decisions b; checks_ withchecks/decisions c
printf -- '---\nid: d\n---\n' > "$N/withchecks/decisions/d.md"
checks_ nocli/decisions e
cli_ noexec -x;      checks_ noexec/decisions f
mkdir -p "$N/dircli/bin/zavet"
cli_ specsonly +x;   checks_ specsonly/specs s1
cli_ both +x;        checks_ both/specs s2; checks_ both/decisions b2
cli_ "space dir" +x; checks_ "space dir/decisions" g

need_ "no zavet directory at all" false 0 false "$N/absent"
need_ "decisions that only mention checks: in prose" true 0 false "$N/plain"
need_ "no decisions directory" true 0 false "$N/nodecisions"
need_ "declared checks without a CLI" false 1 false "$N/nocli"
need_ "a CLI that is not executable" false 1 false "$N/noexec"
need_ "a directory named zavet is not a CLI" false 0 false "$N/dircli"
need_ "only decisions that declare checks: are counted" true 2 true "$N/withchecks"
need_ "checks only in specs" true 1 true "$N/specsonly"
need_ "checks in both decisions and specs" true 2 true "$N/both"
need_ "a directory name with a space" true 1 true "$N/space dir"

# promotion.sh: $1 case, $2 want (promotion|walk), then head repo, this repo,
# head ref, base ref, integration branch
promo_() {
  local got=walk
  "$HERE/promotion.sh" "${@:3}" && got=promotion
  if [ "$got" = "$2" ]; then ok "$1"; else bad "$1" "got $got, wanted $2"; fi
}

promo_ "a fork's branch named develop is walked" walk fork/repo org/repo develop main develop
promo_ "a feature branch into develop is walked" walk org/repo org/repo feat/x develop develop
promo_ "a branch that only starts with develop is walked" walk org/repo org/repo develop-2 main develop
promo_ "an empty integration branch turns it off" walk org/repo org/repo develop main ""
promo_ "no head repo (not a pull request) is walked" walk "" org/repo develop main develop
promo_ "a head repo naming nothing is walked" walk "" "" develop main develop
promo_ "develop into develop is walked" walk org/repo org/repo develop develop develop
promo_ "another branch than the configured one is walked" walk org/repo org/repo develop main staging
promo_ "develop into main is a promotion" promotion org/repo org/repo develop main develop
promo_ "develop into a release branch is a promotion" promotion org/repo org/repo develop release/1 develop
promo_ "a configured integration branch is honoured" promotion org/repo org/repo staging main staging

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
