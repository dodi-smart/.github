#!/usr/bin/env bash
# Runs plan.sh over a table of inputs. Each lane it lists is a job a pull request
# pays a runner for, and each one it drops is a check that no longer runs, so
# every rule that used to be a job-level `if:` in pr-checks.yml is a row here.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pr-checks-plan-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

LIGHT='["self-hosted","Linux","light"]'
HEAVY='["self-hosted","Linux","large"]'

# plan [VAR=value...]: runs plan.sh on a split bun repo with a test and a build
# command, changed by the arguments. Sets $LANES, $COVERAGE and $STATUS.
plan() {
  : > "$WORK/out"
  env -i PATH="$PATH" GITHUB_OUTPUT="$WORK/out" STACK=bun LIGHT="$LIGHT" HEAVY="$HEAVY" \
    HAS_TEST=true HAS_BUILD=true COVERAGE=none IOS=@stack "$@" \
    "$HERE/plan.sh" > "$WORK/log" 2>&1
  STATUS=$?
  LANES="$(sed -n 's/^lanes=//p' "$WORK/out")"
  COVERAGE="$(sed -n 's/^coverage=//p' "$WORK/out")"
}
# expect NAME FILTER WANT: jq FILTER over the lanes prints WANT.
expect() {
  local got
  got="$(jq -r "$2" <<<"${LANES:-null}" 2>&1)"
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1" "got '$got', want '$3'"; fi
}
ids='map(.id) | join(" ")'
# is NAME GOT WANT
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
lane() { printf '(map(select(.id == "%s"))[0] | %s)' "$1" "$2"; }
# both FILTER FILTER: the two printed on one line.
both() { printf '"\\(%s) \\(%s)"' "$1" "$2"; }

# --- split, the default shape
plan
expect "split: checks, test and build" "$ids" "checks test build"
expect "the visible names are the old job names" 'map(.name) | join(",")' "checks,test,build"
expect "checks is on light" "$(lane checks .runs_on)" "$LIGHT"
expect "test and build are on heavy" 'map(select(.id != "checks") | .runs_on) | unique | join(" ")' "$HEAVY"
expect "checks runs install, lint, design-lint, typecheck" "$(lane checks '.phases | join(" ")')" "install lint design-lint typecheck"
expect "test runs install, test" "$(lane test '.phases | join(" ")')" "install test"
expect "build runs install, build" "$(lane build '.phases | join(" ")')" "install build"
expect "no lane runs zavet without the input" 'map(.zavet) | any' "false"
expect "every lane carries every field" 'map(keys | join(",")) | unique | join(" ")' \
  "commitlint,coverage_upload,dependency_check,hk,id,name,phases,react_doctor,runs_on,zavet"
expect "the output is one line" 'type' "array"
is "two output lines, lanes and coverage" "$(wc -l < "$WORK/out" | tr -d ' ')" 2
is "coverage none uploads nothing" "$COVERAGE" false

plan HAS_TEST=false
expect "no test command, no test lane" "$ids" "checks build"
plan HAS_BUILD=false
expect "no build command, no build lane" "$ids" "checks test"
plan HAS_TEST=false HAS_BUILD=false
expect "neither command, checks alone" "$ids" "checks"

# --- hk, dependency-check, React Doctor and commitlint ride on checks (or all) only
plan HK=true DEPENDENCY_CHECK=true COMMITLINT=true REACT_DOCTOR=true
expect "React Doctor on checks only" 'map(select(.react_doctor) | .id) | join(" ")' "checks"
expect "hk on checks only" 'map(select(.hk) | .id) | join(" ")' "checks"
expect "dependency-check on checks only" 'map(select(.dependency_check) | .id) | join(" ")' "checks"
expect "commitlint on checks only" 'map(select(.commitlint) | .id) | join(" ")' "checks"
plan HK=false DEPENDENCY_CHECK=false COMMITLINT=false
expect "off inputs leave every lane off" 'map(.hk or .dependency_check or .commitlint or .react_doctor) | any' "false"

# --- single-job
plan SINGLE_JOB=true HK=true DEPENDENCY_CHECK=true COMMITLINT=true REACT_DOCTOR=true COVERAGE=lcov
expect "single-job: one all lane" "$ids" "all"
expect "all is on heavy" "$(lane all .runs_on)" "$HEAVY"
expect "all runs every phase" "$(lane all '.phases | join(" ")')" "install lint design-lint typecheck test build"
expect "all carries hk, dependency-check, React Doctor, commitlint and the coverage upload" \
  "$(lane all '[.hk, .dependency_check, .react_doctor, .commitlint, .coverage_upload] | all')" "true"
is "single-job coverage is uploaded" "$COVERAGE" true
plan SINGLE_JOB=true HAS_TEST=false HAS_BUILD=false
expect "single-job runs all without a test or build command" "$ids" "all"

# --- coverage
plan COVERAGE=lcov
expect "split coverage is uploaded by test only" 'map(select(.coverage_upload) | .id) | join(" ")' "test"
is "split coverage is an output" "$COVERAGE" true
plan COVERAGE=vitest HAS_TEST=false
expect "no test lane, no upload" 'map(select(.coverage_upload)) | length' "0"
is "no test lane, coverage output false" "$COVERAGE" false

# --- docs-only
plan DOCS_ONLY=true HK=true DEPENDENCY_CHECK=true COVERAGE=lcov
expect "docs-only with nothing to carry: no lanes" 'length' "0"
is "no lanes is exactly []" "$LANES" "[]"
plan DOCS_ONLY=true COMMITLINT=true HK=true DEPENDENCY_CHECK=true REACT_DOCTOR=true COVERAGE=lcov
expect "docs-only with commitlint: checks alone" "$ids" "checks"
expect "docs-only checks is on light" "$(lane checks .runs_on)" "$LIGHT"
expect "docs-only checks has no phases" "$(lane checks '.phases | length')" "0"
expect "docs-only checks carries commitlint and nothing else" \
  "$(lane checks '[.commitlint, .hk, .dependency_check, .react_doctor, .coverage_upload, .zavet] | map(tostring) | join(" ")')" "true false false false false false"
plan DOCS_ONLY=true COMMITLINT=true SINGLE_JOB=true
expect "docs-only single-job with commitlint: checks on light, never all" "$(both "$ids" "$(lane checks .runs_on)")" "checks $LIGHT"
plan DOCS_ONLY=true ZAVET=true
expect "docs-only with zavet: checks carries it" "$ids" "checks"
expect "docs-only zavet rides on checks, which has no install to share" "$(lane checks '[.zavet, .commitlint, (.phases | length)] | map(tostring) | join(" ")')" "true false 0"
plan DOCS_ONLY=true ZAVET=true ZAVET_INSTALL='bun run build'
expect "docs-only zavet stays in checks even when it could not fold" "$ids" "checks"
plan DOCS_ONLY=true STACK=kmm IOS_LABELLED=true
expect "docs-only never builds iOS" 'length' "0"
plan DOCS_ONLY=false COMMITLINT=true
expect "not docs-only: the usual lanes" "$ids" "checks test build"

# --- iOS
plan STACK=kmm IOS_LABELLED=true
expect "a labelled kmm PR gets the iOS lane" "$ids" "checks test build ios"
expect "the iOS lane is named iOS" "$(lane ios .name)" "iOS"
expect "the iOS lane runs on the hosted Mac" "$(lane ios .runs_on)" '"macos-latest"'
expect "the iOS lane runs install and the iOS command" "$(lane ios '.phases | join(" ")')" "install ios"
expect "only the iOS lane is on a Mac or runs the iOS command" \
  'map(select(((.runs_on | test("macos")) or (.phases | index("ios") != null)) | not) | .id) | join(" ")' "checks test build"
for stack in flutter xcode; do
  plan STACK=$stack IOS_LABELLED=true
  expect "a labelled $stack PR gets the iOS lane" 'map(select(.id == "ios")) | length' "1"
done
plan STACK=kmm IOS_LABELLED=false
expect "no label, no iOS lane" 'map(select(.id == "ios")) | length' "0"
plan STACK=kmm IOS_LABELLED=true IOS=
expect "ios off, no iOS lane" 'map(select(.id == "ios")) | length' "0"
for stack in bun node gradle android rust none; do
  plan STACK=$stack IOS_LABELLED=true
  expect "a labelled $stack PR builds no iOS" 'map(select(.id == "ios")) | length' "0"
done
plan STACK=kmm IOS_LABELLED=true SINGLE_JOB=true
expect "iOS is never folded into single-job" "$ids" "all ios"
plan STACK=kmm IOS_LABELLED=true HK=true DEPENDENCY_CHECK=true COMMITLINT=true REACT_DOCTOR=true COVERAGE=kover ZAVET=true
expect "the iOS lane carries no opt-in step" "$(lane ios '[.hk, .dependency_check, .react_doctor, .commitlint, .coverage_upload, .zavet] | any')" "false"

# --- zavet
plan ZAVET=true
expect "zavet-stack none folds into checks" "$ids" "checks test build"
expect "folded zavet shares the lane's install" "$(lane checks '[.zavet, (.phases | index("install") != null)] | map(tostring) | join(" ")')" "true true"
expect "only checks runs zavet" 'map(select(.zavet) | .id) | join(" ")' "checks"
plan ZAVET=true ZAVET_STACK=bun
expect "zavet-stack equal to the stack folds" "$(lane checks .zavet)" "true"
plan ZAVET=true SINGLE_JOB=true
expect "zavet folds into all" "$(both "$ids" "$(lane all .zavet)")" "all true"
plan ZAVET=true ZAVET_STACK=gradle
expect "another zavet-stack gets its own lane" "$ids" "checks test build zavet"
expect "the zavet lane is named Zavet Check" "$(lane zavet .name)" "Zavet Check"
expect "the zavet lane is light, with no phases" \
  "$(lane zavet '[.runs_on, (.phases | length)] | map(tostring) | join(" ")')" "$LIGHT 0"
expect "checks carries no zavet beside a zavet lane" "$(lane checks .zavet)" "false"
plan ZAVET=true ZAVET_INSTALL='bun run build'
expect "a zavet-install gets its own lane" "$ids" "checks test build zavet"
plan ZAVET=true ZAVET_STACK=gradle SINGLE_JOB=true COMMITLINT=true
expect "an unfolded zavet lane carries no commitlint" "$(both "$ids" "$(lane zavet .commitlint)")" "all zavet false"
plan ZAVET=false ZAVET_STACK=gradle
expect "zavet off, no zavet anywhere" 'map(select(.zavet)) | length' "0"

# --- fails closed
plan LIGHT=
is "a lane with no runner fails" "$([ "$STATUS" -eq 0 ] || echo failed) $(grep -c 'no runner was picked for the checks lane' "$WORK/log")" "failed 1"
plan DOCS_ONLY=true LIGHT= HEAVY=
is "no lanes needs no runner" "$STATUS $LANES" "0 []"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
