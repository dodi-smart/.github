#!/usr/bin/env bash
# Assert the four rules that live in scripts beside the action: which commits
# the guard step skips as release commits (release-commit.sh), what needs
# installing (need.sh), which PRs are promotions (promotion.sh), which files a
# run changed, the scope of its checks (scope.sh), and the yq install
# (install-yq.sh, against a fake curl and uname). Each half
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

# scope.sh: $1 case, $2 want scoped, $3 want changed files (space-joined, or
# "-" for none), then event, base, head. Runs in a repo with two commits.
S="$WORK/scope"
git init -q "$S" && git -C "$S" config commit.gpgsign false
# CI runners have no git identity; the test repo carries its own.
git -C "$S" config user.name "Scope Test" && git -C "$S" config user.email scope@example.invalid
mkdir -p "$S/lib" && echo a > "$S/lib/a.dart" && echo m > "$S/mise.toml"
git -C "$S" add -A && git -C "$S" commit -qm one
first=$(git -C "$S" rev-parse HEAD)
echo b > "$S/lib/a.dart" && git -C "$S" mv mise.toml tools.toml && git -C "$S" commit -qam two
second=$(git -C "$S" rev-parse HEAD)
scope_() {
  local out="$WORK/scope.out" got want="$2" files
  got=$(cd "$S" && "$HERE/scope.sh" "$4" "$5" "$6" "$out" | sed -n 's/^scoped=//p')
  files=$(sort "$out" | tr '\n' ' ' | sed 's/ $//'); [ -n "$files" ] || files=-
  if [ "$got" = "$want" ] && [ "$files" = "$3" ]; then ok "$1"; else bad "$1" "got scoped=$got files=$files, wanted $want $3"; fi
}
scope_ "a pull request lists its diff, both sides of a rename" true "lib/a.dart mise.toml tools.toml" pull_request "$first" "$second"
scope_ "a push lists the commits it added" true "lib/a.dart mise.toml tools.toml" push "$first" "$second"
scope_ "a push that added nothing lists nothing" true - push "$second" "$second"
scope_ "a dispatch is unscoped" false - workflow_dispatch "$first" "$second"
scope_ "a schedule is unscoped" false - schedule "$first" "$second"
scope_ "a new branch's zero base is unscoped" false - push 0000000000000000000000000000000000000000 "$second"
scope_ "an empty base is unscoped" false - pull_request "" "$second"
scope_ "a base the checkout cannot see is unscoped" false - pull_request 1234567890abcdef1234567890abcdef12345678 "$second"

# install-yq.sh: RUNNER_OS/ARCH say Linux X64, a fake python `yq` shadows any
# real one, and a fake curl serves the asset and checksums-bsd (FAKE_SUM=bad
# serves a wrong digest, FAKE_SUM=none an empty list) and logs every call.
B="$WORK/yq-bin"; mkdir -p "$B"
printf '#!/bin/sh\necho "yq 3.4.3 (python)"\n' > "$B/yq"
cat > "$B/curl" <<'SH'
#!/bin/sh
echo "$*" >> "$CURL_LOG"
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift ;; http*) url=$1 ;; esac; shift; done
case "$url" in
  */checksums-bsd)
    sum=$(printf 'yq-binary' | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
    case "${FAKE_SUM:-good}" in bad) sum=0000 ;; none) : > "$out"; exit 0 ;; esac
    echo "SHA256 (yq_linux_amd64) = $sum" > "$out" ;;
  *) printf 'yq-binary' > "$out" ;;
esac
SH
chmod +x "$B/yq" "$B/curl"
expect() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$WORK/yq.out" "$WORK/curl.log" 2>/dev/null)"; fi; }
yq_() { # $1 case, $2 want (ok|fail), env assignments follow
  local name=$1 want=$2 got=ok; shift 2
  : > "$WORK/curl.log"
  env PATH="$B:/usr/bin:/bin" CURL_LOG="$WORK/curl.log" RUNNER_TOOL_CACHE="$WORK/tc" RUNNER_OS=Linux RUNNER_ARCH=X64 "$@" \
    "$HERE/install-yq.sh" v4.0.0 > "$WORK/yq.out" 2>/dev/null || got=fail
  if [ "$got" = "$want" ]; then ok "$name"; else bad "$name" "got $got, wanted $want"; fi
}
yq_ "a wrong checksum stops the install" fail FAKE_SUM=bad
expect "a refused download leaves nothing in the cache" test ! -e "$WORK/tc/yq/v4.0.0/amd64/yq"
yq_ "a release that lists no checksum stops the install" fail FAKE_SUM=none
yq_ "a good download installs into the tool cache" ok
expect "it installs an executable" test -x "$WORK/tc/yq/v4.0.0/amd64/yq"
expect "it prints the directory to put on PATH" test "$(cat "$WORK/yq.out")" = "$WORK/tc/yq/v4.0.0/amd64"
expect "downloads retry within a bounded time" grep -q -- '--retry-max-time' "$WORK/curl.log"
yq_ "a cached version is reused" ok
expect "the cached version downloads nothing" test ! -s "$WORK/curl.log"
printf '#!/bin/sh\necho "yq (https://github.com/mikefarah/yq/) version v4.9.9"\n' > "$B/yq"
yq_ "mikefarah yq already on PATH is used as it is" ok
expect "it prints that yq's directory" test "$(cat "$WORK/yq.out")" = "$B"
expect "and nothing is downloaded" test ! -s "$WORK/curl.log"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
