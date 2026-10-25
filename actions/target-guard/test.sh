#!/usr/bin/env bash
# Assert what may target the release branch. The costly mistake is a pull
# request that reaches it when it should not, so the rejects outnumber the
# passes. `decide` runs on fixed inputs; `run` is exercised against a `gh` on
# PATH that prints a fixture, so nothing here needs a network.
# The backticks in the greps are literal; `A && B || C` is a report, not control flow.
# shellcheck disable=SC2016,SC2015
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/guard.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/target-guard-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

NONE='[]'
FEAT='["fix: a","feat(api): add x"]'
CLEAN='["fix(deps): bump x","chore: tidy"]'

# $1 name, $2 want verdict, then env assignments. The default is a same-repo
# `fix/security-` branch with a fix title, the lane on and one fix commit.
decide() {
  local name="$1" want="$2" got v r; shift 2
  got="$(env -i PATH="$PATH" EVENT=pull_request BASE=main HEAD=fix/security-x DEFAULT_BRANCH=develop \
         FORK=false TITLE='fix(deps): bump x' AUTHOR=someone HOTFIX=enabled COMMITS="$CLEAN" "$@" \
         "$SCRIPT" decide)"
  v=$(sed -n 's/^verdict=//p' <<<"$got"); r=$(sed -n 's/^reason=//p' <<<"$got")
  if [ "$v" = "$want" ]; then ok "$(printf '%-62s -> %s' "$name" "$v")"
  else bad "$(printf '%-62s -> %s (wanted %s: %s)' "$name" "$v" "$want" "$r")"; fi
}

# Not the guard's business.
decide "a push event"                                         skip   EVENT=push
decide "a workflow_dispatch"                                  skip   EVENT=workflow_dispatch
decide "a pull request into the default branch"               skip   BASE=develop HEAD=feat/x
decide "a pull request into some other branch"                skip   BASE=staging HEAD=feat/x
decide "a repo whose default branch is the release branch"    skip   DEFAULT_BRANCH=main HEAD=feat/x
decide "a custom release branch is the base"                  skip   RELEASE_BRANCH=prod

# A release.
decide "develop into main is a release"                       release HEAD=develop
decide "a release needs no lane property"                     release HEAD=develop HOTFIX=disabled
decide "a release ignores its title"                          release HEAD=develop TITLE='feat: everything'
decide "a custom release branch takes the default branch"     release RELEASE_BRANCH=prod BASE=prod HEAD=develop
decide "a fork's own develop is not a release"                reject  HEAD=develop FORK=true
decide "an unknown default branch lets nothing pass as one"   reject  HEAD=develop DEFAULT_BRANCH= HOTFIX=disabled

# Everything else into the release branch.
decide "a feature branch into main"                           reject  HEAD=feat/x
decide "a plain fix branch into main"                         reject  HEAD=fix/typo
decide "a branch named for security but not the prefix"       reject  HEAD=security/x
decide "a fix/security branch from a fork"                    reject  FORK=true
decide "Renovate without [SECURITY] in the title"             reject  HEAD=renovate/x AUTHOR='renovate[bot]'
decide "[SECURITY] in the title of a person's PR"             reject  HEAD=chore/x 'TITLE=fix(deps): bump x [SECURITY]'
decide "[SECURITY] by a look-alike author"                    reject  HEAD=renovate/x AUTHOR='renovate-bot' 'TITLE=fix(deps): bump x [SECURITY]'

# A lane PR.
decide "a fix/security branch, the lane on, a clean fix"      lane
decide "the same with a scope-less fix title"                 lane   'TITLE=fix: patch it'
decide "Renovate's [SECURITY] update on its own branch"       lane   HEAD=renovate/lodash-vulnerability AUTHOR='renovate[bot]' 'TITLE=fix(deps): update dependency lodash to v4.17.21 [SECURITY]'
decide "Renovate's app/ form is the same bot"                lane   HEAD=renovate/x AUTHOR='App/Renovate' 'TITLE=fix(deps): bump x [SECURITY]'
decide "Dependabot is a dependency bot, but not the lane's"    reject HEAD=dependabot/npm/x AUTHOR='dependabot[bot]' 'TITLE=fix(deps): bump x [SECURITY]'
decide "a lane PR with no commits listed"                     lane   COMMITS="$NONE"

# The lane has to be on.
decide "the lane is disabled"                                 reject HOTFIX=disabled
decide "the property is absent"                               reject HOTFIX=
decide "the property says something else"                     reject HOTFIX=Enabled
decide "Renovate [SECURITY] with the lane off"                reject HEAD=renovate/x AUTHOR='renovate[bot]' 'TITLE=fix(deps): bump x [SECURITY]' HOTFIX=disabled

# It may only cut a patch.
decide "a feat title"                                         reject 'TITLE=feat(api): add x'
decide "a chore title"                                        reject 'TITLE=chore(deps): bump x'
decide "a fix title with a bang"                              reject 'TITLE=fix!: drop the old api'
decide "a scoped fix title with a bang"                       reject 'TITLE=fix(api)!: drop it'
decide "a title that only starts with fix"                    reject 'TITLE=fixture: add'
decide "a fix title with no colon-space"                      reject 'TITLE=fix:no space'
decide "a feat commit"                                        reject COMMITS="$FEAT"
decide "a feat commit with a bang"                            reject 'COMMITS=["feat!: x"]'
decide "a bang on another type"                               reject 'COMMITS=["refactor(core)!: rename"]'
decide "a bang commit under a fix title"                      reject 'COMMITS=["fix!: drop the old api"]'
decide "a BREAKING CHANGE footer"                             reject 'COMMITS=["fix: a\n\nBody.\n\nBREAKING CHANGE: the api moved"]'
decide "a BREAKING-CHANGE footer"                             reject 'COMMITS=["fix: a\n\nBREAKING-CHANGE: moved"]'
decide "a lowercase breaking footer is doubted, not trusted"  reject 'COMMITS=["fix: a\n\nbreaking change: moved"]'
decide "a word that merely mentions feat is no feat"          lane   'COMMITS=["fix: undo feat(api) change"]'
decide "a body line mentioning a breaking change in prose"    lane   'COMMITS=["fix: a\n\nThis is not a breaking change."]'
decide "the commits could not be read"                        reject COMMITS=
decide "the commits are not a list"                           reject COMMITS='{"message":"Not Found"}'
decide "the API cap of commits"                               reject "COMMITS=$(jq -nc '[range(250) | "fix: c\(.)"]')"
decide "just under the cap passes"                            lane   "COMMITS=$(jq -nc '[range(249) | "fix: c\(.)"]')"

# `run` against a fake API: $FAKE_PROP is the property, $FAKE_COMMITS the commit
# pages (one array per line, as `gh --paginate --jq` prints them); FAKE_FAIL
# names the endpoint that errors.
mkdir "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *pulls/*/commits*)
    [ "${FAKE_FAIL:-}" != commits ] || { echo "HTTP 500" >&2; exit 1; }
    printf '%s\n' "$FAKE_COMMITS" ;;
  *)
    [ "${FAKE_FAIL:-}" != repo ] || { echo "HTTP 403" >&2; exit 1; }
    printf '%s\n' "$FAKE_PROP" ;;
esac
GH
chmod +x "$WORK/bin/gh"

# A lane PR on a repo with the lane enabled; `run` and `verdict` both start here.
LANE_PR=(PATH="$WORK/bin:$PATH" EVENT=pull_request REPO=o/r NUMBER=7 BASE=main HEAD=fix/security-x
         DEFAULT_BRANCH=develop FORK=false TITLE='fix(deps): bump x' AUTHOR=someone
         FAKE_PROP=enabled FAKE_COMMITS='["fix: a"]')

# $1 name, $2 want verdict, then env assignments.
runit() {
  local name="$1" want="$2" out v rc; shift 2
  out="$WORK/out"; : > "$out"
  env GITHUB_OUTPUT="$out" "${LANE_PR[@]}" "$@" "$SCRIPT" > "$WORK/log" 2>&1
  rc=$?
  v=$(sed -n 's/^verdict=//p' "$out")
  if [ "$v" != "$want" ]; then bad "$(printf '%-62s -> %s (wanted %s)' "$name" "${v:-<none>}" "$want")"
  elif [ "$want" = reject ] && [ "$rc" -ne 1 ]; then bad "$name: a reject must exit 1, exited $rc"
  elif [ "$want" != reject ] && [ "$rc" -ne 0 ]; then bad "$name: exited $rc"
  else ok "$(printf '%-62s -> %s (exit %s)' "$name" "$v" "$rc")"; fi
}

runit "run: a lane PR passes"                                 lane
grep -q '^::notice title=Security hotfix lane::' "$WORK/log" && ok "the pass is announced" || bad "the pass is not announced"
runit "run: commits on several pages are all read"            reject FAKE_COMMITS=$'["fix: a"]\n["feat: b"]'
runit "run: several clean pages"                              lane   FAKE_COMMITS=$'["fix: a"]\n["fix: b"]'
runit "run: the property is disabled"                         reject FAKE_PROP=disabled
grep -q '^::error title=Wrong target branch::' "$WORK/log" && ok "the reject is an error annotation" || bad "the reject is not annotated"
grep -q 'security_hotfix' "$WORK/log" && ok "the reject says what to enable" || bad "the reject does not name the property"
runit "run: the property is empty"                            reject FAKE_PROP=
runit "run: the repository call fails"                        reject FAKE_FAIL=repo
runit "run: the commits call fails"                           reject FAKE_FAIL=commits
runit "run: a release needs no API"                           release HEAD=develop FAKE_FAIL=repo
runit "run: a feature branch is rejected with the lane on"    reject HEAD=feat/x
runit "run: a push is skipped"                                skip   EVENT=push
runit "run: a pull request into develop is skipped"           skip   BASE=develop HEAD=feat/x
grep -q 'against `develop`' "$WORK/log" && bad "a skip should not give instructions" || ok "a skip stays quiet about instructions"

runit "run: the reject names the default branch"              reject HEAD=feat/x
grep -q 'against `develop`' "$WORK/log" && ok "the reject says where to open it" || bad "the reject does not say where to open it"

# verdict: the same reads, printed on stdout for merge-gate, with no annotation
# and exit 0 whatever the verdict.
vrun() { env -u GITHUB_OUTPUT "${LANE_PR[@]}" "$@" "$SCRIPT" verdict 2>&1; }
got=$(vrun); rc=$?
[ "$rc:$(sed -n 's/^verdict=//p' <<<"$got")" = 0:lane ] && ok "verdict: a lane PR prints lane, exit 0" || bad "verdict: a lane PR ($rc: $got)"
got=$(vrun FAKE_PROP=disabled); rc=$?
[ "$rc:$(sed -n 's/^verdict=//p' <<<"$got")" = 0:reject ] && ok "verdict: a reject prints reject, exit 0" || bad "verdict: a reject ($rc: $got)"
grep -q '^::' <<<"$got" && bad "verdict: prints an annotation" || ok "verdict: prints no annotation"
grep -q '^reason=a security patch cannot target' <<<"$got" && ok "verdict: prints the reason" || bad "verdict: no reason ($got)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
