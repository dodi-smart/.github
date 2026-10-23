#!/usr/bin/env bash
# Assert what the back-merge decides, against real git repositories (a bare
# "origin" and a clone of it per case) with `gh` replaced by a shim on PATH that
# logs every call and answers from fixtures. Nothing here needs a network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/backmerge.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/backmerge-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

# Hermetic git: no user or system config, no prompts.
export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME"
git config --global user.name  "Test"
git config --global user.email "test@example.test"
git config --global init.defaultBranch main
git config --global commit.gpgsign false

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', wanted '$3'"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "'$3' not in: $2"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then bad "$1" "'$3' found in: $2"; else ok "$1"; fi; }

# The gh shim. It logs each call as one line and answers from FAKE_* variables.
mkdir "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s ' "$@" | tr '\n' ' ' >> "$GH_LOG"; echo >> "$GH_LOG"
all="$*"
case "$1" in
  pr)
    case "$2" in
      list)   printf '%s\n' "${FAKE_PR_LIST:-[]}" ;;
      create) [ -z "${FAKE_PR_CREATE_FAIL:-}" ] || { echo "boom" >&2; exit 1; }
              echo "https://example.test/o/r/pull/7" ;;
    esac ;;
  issue)
    case "$2" in
      list)    printf '%s\n' "${FAKE_ISSUE_LIST:-[]}" ;;
      comment) ;;
    esac ;;
  api)
    case "$all" in
      *setIssueFieldValue*)
        [ -z "${FAKE_GRAPHQL_FAIL:-}" ] || { echo "HTTP 500" >&2; exit 1; }
        echo '{"data":{}}' ;;
      *issueFields*)
        [ -z "${FAKE_GRAPHQL_FAIL:-}" ] || { echo "HTTP 500" >&2; exit 1; }
        cat <<'JSON'
{"data":{"repository":{"issueFields":{"nodes":[
 {"id":"IFSS_pri","name":"Priority","options":[{"id":"IFSSO_pri_hi","name":"High"},{"id":"IFSSO_pri_lo","name":"Low"}]},
 {"id":"IFSS_risk","name":"Risk","options":[{"id":"IFSSO_risk_hi","name":"High"}]},
 {"id":"IFSS_src","name":"Source","options":[{"id":"IFSSO_src_bot","name":"Bot"}]},
 {"id":"IFSS_mode","name":"Agent mode","options":[{"id":"IFSSO_mode_h","name":"Human only"}]},
 {"id":"IFSS_state","name":"Triage state","options":[{"id":"IFSSO_state_r","name":"Ready for plan"}]},
 {}
]}}}}
JSON
        ;;
      *"/issues"*)
        if [ -n "${FAKE_TYPE_FAIL:-}" ] && [[ "$all" == *"type=Task"* ]]; then
          echo "HTTP 422: type is invalid" >&2; exit 1
        fi
        echo '{"number":12,"node_id":"I_node12","html_url":"https://example.test/o/r/issues/12"}' ;;
    esac ;;
esac
exit 0
GH
chmod +x "$WORK/bin/gh"

# The commands the script and the shim need, and nothing else: a directory of
# links to them is the whole PATH of a run, so the cases that need a package
# manager absent really have none, whatever is installed on this machine.
mkdir "$WORK/sysbin"
for c in bash env sh git jq perl sed grep tr wc mktemp cat cp mv rm mkdir awk sort uniq dirname basename \
         head tail cut date ls chmod touch find xargs diff tee uname id sleep ln; do
  p=$(command -v "$c" 2>/dev/null) && [ -x "$p" ] && ln -s "$p" "$WORK/sysbin/$c"
done
export PM_LOG="$WORK/pm.log"

# A bare origin with main and develop at one commit, built once and cloned per case.
SEED="$WORK/seed.git"
(
  git init -q --bare "$SEED"
  git clone -q "$SEED" "$WORK/seed-work" 2>/dev/null
  cd "$WORK/seed-work" || exit 1
  echo '{"version":"0.1.0"}' > package.json
  echo base > a.txt
  echo "# changes" > CHANGELOG.md
  git add -A && git commit -q -m "chore: base"
  git push -q origin main
  git push -q origin main:develop
)

# $1 case name. Sets O (origin path) and W (clone path).
mk() {
  O="$WORK/$1/origin.git"; W="$WORK/$1/work"
  mkdir -p "$WORK/$1"
  git clone -q --bare "$SEED" "$O" 2>/dev/null
  git clone -q "$O" "$W" 2>/dev/null
}

# A commit on a branch of the clone from a shell snippet, pushed.
# $1 branch, $2 subject, $3 snippet (run in the clone).
edit_on() {
  (
    cd "$W" || exit 1
    git fetch -q origin
    git checkout -q -B "$1" "origin/$1"
    eval "$3"
    git add -A && git commit -q -m "$2"
    git push -q origin "$1"
  )
}

# $1 branch, $2 file, $3 content, $4 subject.
# shellcheck disable=SC2016  # the snippet is evaluated in the clone
commit_on() { F="$2" C="$3" edit_on "$1" "$4" 'printf "%s\n" "$C" > "$F"'; }

# a.txt changed on both branches: a conflict beyond the version files.
conflicting() {
  commit_on develop a.txt "develop side" "feat: develop change"
  commit_on main a.txt "main side" "fix: main change"
}

# A case with app/pkg.json changed on both branches, a path only the caller can name.
# $1 case name.
mk_app() {
  mk "$1"
  (cd "$W" && mkdir -p app && echo v0 > app/pkg.json && git add -A && git commit -q -m "chore: app" \
    && git push -q origin main && git push -q -f origin main:develop)
  commit_on develop app/pkg.json dev "chore(release): app dev [skip ci]"
  commit_on main app/pkg.json rel "chore(release): app rel [skip ci]"
}

# A fake package manager that logs its arguments to PM_LOG, then runs a body in
# the clone. $1 names the directory (put it in PM_STUBS), $2 the tool, $3 the body.
stub_pm() {
  mkdir -p "$WORK/stubs-$1"
  # shellcheck disable=SC2016  # $* is the stub's own
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$PM_LOG"\n%s\n' "$2" "$3" > "$WORK/stubs-$1/$2"
  chmod +x "$WORK/stubs-$1/$2"
}

# Runs the script in the clone. Env: TAG ($1), plus whatever the case exports.
# Sets RC, OUT (stdout), LOG (gh calls) and OUTPUTS (the $GITHUB_OUTPUT lines).
run() {
  GH_LOG="$WORK/gh.log"; : > "$GH_LOG"
  GITHUB_OUTPUT="$WORK/outputs"; : > "$GITHUB_OUTPUT"
  # PM_STUBS names a directory of fake package managers; with or without it the
  # PATH is the minimal one, so no real bun, npm, pnpm or yarn can answer.
  local path="$WORK/bin:$WORK/sysbin"
  [ -z "${PM_STUBS:-}" ] || path="$PM_STUBS:$path"
  OUT=$(cd "$W" && FROM=main TO=develop REPO=o/r TAG="${1:-}" RESOLVE_EXTRA="${RESOLVE_EXTRA:-}" \
        GH_LOG="$GH_LOG" GITHUB_OUTPUT="$GITHUB_OUTPUT" PATH="$path" "$SCRIPT" 2>&1)
  RC=$?
  LOG=$(cat "$GH_LOG"); OUTPUTS=$(cat "$GITHUB_OUTPUT")
}

rev()  { git -C "$O" rev-parse "$1"; }
subj() { git -C "$O" log -1 --format=%s "$1"; }
nparents() { git -C "$O" log -1 --format=%p "$1" | wc -w | tr -d ' '; }
show() { git -C "$O" show "$1:$2"; }

echo "up to date"
mk uptodate
run v1.0.0
eq "exits 0" "$RC" 0
has "result is up-to-date" "$OUTPUTS" "result=up-to-date"
eq "no gh call" "$LOG" ""
eq "develop untouched" "$(rev develop)" "$(rev main)"

echo "release commits only: straight to develop, [skip ci]"
mk plain
commit_on main package.json '{"version":"1.0.0"}' "chore(release): 1.0.0 [skip ci]"
before=$(rev develop)
run v1.0.0
eq "exits 0" "$RC" 0
has "result is merged" "$OUTPUTS" "result=merged"
eq "develop moved" "$([ "$(rev develop)" != "$before" ] && echo yes)" yes
eq "merge commit subject" "$(subj develop)" "chore(release): merge main into develop [skip ci]"
eq "it is a merge commit" "$(nparents develop)" 2
eq "main is an ancestor of develop" "$(git -C "$O" merge-base --is-ancestor main develop && echo yes)" yes
eq "no gh call" "$LOG" ""
eq "no backmerge branch" "$(git -C "$O" branch --list 'chore/backmerge-*')" ""

echo "version file conflict: resolved toward main, no hotfix"
mk versions
commit_on develop package.json '{"version":"0.2.0-develop.1"}' "chore(release): 0.2.0-develop.1 [skip ci]"
commit_on develop CHANGELOG.md '# develop notes' "chore(release): changelog [skip ci]"
commit_on main package.json '{"version":"0.2.0"}' "chore(release): 0.2.0 [skip ci]"
commit_on main CHANGELOG.md '# main notes' "chore(release): changelog main [skip ci]"
run v0.2.0
eq "exits 0" "$RC" 0
has "result is merged" "$OUTPUTS" "result=merged"
eq "package.json is main's" "$(show develop package.json)" '{"version":"0.2.0"}'
eq "CHANGELOG.md is main's" "$(show develop CHANGELOG.md)" '# main notes'
eq "pushed with [skip ci]" "$(subj develop)" "chore(release): merge main into develop [skip ci]"
eq "no gh call" "$LOG" ""

echo "extra resolve path from the caller"
mk_app extra
RESOLVE_EXTRA="app/pkg.json" run v0.3.0
eq "exits 0" "$RC" 0
has "result is merged" "$OUTPUTS" "result=merged"
eq "extra path is main's" "$(show develop app/pkg.json)" rel
mk_app extra2
RESOLVE_EXTRA="" run v0.3.0
has "without the extra path it is a real conflict" "$OUTPUTS" "result=conflict"
unset RESOLVE_EXTRA

echo "hotfix, clean: a branch and a pull request, no [skip ci]"
mk hotfix
commit_on main hotfix.txt fixed "fix(deps): patch a vulnerable dependency"
commit_on main package.json '{"version":"0.1.1"}' "chore(release): 0.1.1 [skip ci]"
before=$(rev develop)
run v0.1.1
eq "exits 0" "$RC" 0
has "result is pull-request" "$OUTPUTS" "result=pull-request"
has "pr output" "$OUTPUTS" "pr=https://example.test/o/r/pull/7"
eq "develop untouched" "$(rev develop)" "$before"
eq "branch named for the tag" "$(git -C "$O" branch --list 'chore/backmerge-v0.1.1' | tr -d ' ')" "chore/backmerge-v0.1.1"
eq "merge commit subject has no [skip ci]" "$(subj chore/backmerge-v0.1.1)" "chore(release): merge main into develop"
eq "it is a merge commit" "$(nparents chore/backmerge-v0.1.1)" 2
eq "the fix is on the branch" "$(show chore/backmerge-v0.1.1 hotfix.txt)" fixed
has "pr create called" "$LOG" "pr create"
has "pr base is develop" "$LOG" "--base develop"
has "pr head is the branch" "$LOG" "--head chore/backmerge-v0.1.1"
has "pr title" "$LOG" "--title chore(release): merge main into develop after v0.1.1"
has "pr body forbids squash" "$LOG" "Never squash or rebase"
lacks "no issue filed" "$LOG" "issues"
lacks "never merges" "$LOG" "pr merge"

echo "hotfix, an open pull request already exists: reused"
mk reuse
commit_on main hotfix.txt fixed "fix: patch"
FAKE_PR_LIST='[{"url":"https://example.test/o/r/pull/3"}]' run v0.1.1
eq "exits 0" "$RC" 0
has "pr output is the existing one" "$OUTPUTS" "pr=https://example.test/o/r/pull/3"
lacks "no second pr" "$LOG" "pr create"

echo "hotfix, no tag: the branch is named for the short sha"
mk notag
commit_on main hotfix.txt fixed "fix: patch"
run ""
short=$(git -C "$O" rev-parse --short=8 main)
eq "branch named for the short sha" "$(git -C "$O" branch --list "chore/backmerge-$short" | tr -d ' ')" "chore/backmerge-$short"

echo "hotfix, the pull request cannot be opened: still exits 0, files an issue"
mk prfail
commit_on main hotfix.txt fixed "fix: patch"
FAKE_PR_CREATE_FAIL=1 run v0.1.1
eq "exits 0" "$RC" 0
has "result needs a person" "$OUTPUTS" "result=conflict"
has "an issue was filed" "$LOG" "api -X POST /repos/o/r/issues"

echo "real conflict: aborted, branch at main, pull request and issue, exit 0"
mk conflict
conflicting
dev_before=$(rev develop)
run v0.1.1
eq "exits 0, not 1" "$RC" 0
has "result is conflict" "$OUTPUTS" "result=conflict"
has "pr output" "$OUTPUTS" "pr=https://example.test/o/r/pull/7"
has "issue output" "$OUTPUTS" "issue=https://example.test/o/r/issues/12"
has "a warning is emitted" "$OUT" "::warning title=Back-merge needs a person"
eq "develop untouched" "$(rev develop)" "$dev_before"
eq "branch is main as released" "$(rev chore/backmerge-v0.1.1)" "$(rev main)"
has "pr create called" "$LOG" "pr create"
has "issue created with the title" "$LOG" "title=Back-merge of main into develop needs a person (v0.1.1)"
has "issue created with the Task type" "$LOG" "type=Task"
has "issue body lists the conflicted file" "$LOG" "- \`a.txt\`"
has "issue body links the pr" "$LOG" "Pull request: https://example.test/o/r/pull/7"
has "fields are set by node id" "$LOG" 'issueId:"I_node12"'
has "Priority is set" "$LOG" 'fieldId:"IFSS_pri", singleSelectOptionId:"IFSSO_pri_hi"'
has "Risk is set" "$LOG" 'fieldId:"IFSS_risk", singleSelectOptionId:"IFSSO_risk_hi"'
has "Source is set" "$LOG" 'fieldId:"IFSS_src", singleSelectOptionId:"IFSSO_src_bot"'
has "Agent mode is set" "$LOG" 'fieldId:"IFSS_mode", singleSelectOptionId:"IFSSO_mode_h"'
has "Triage state is set" "$LOG" 'fieldId:"IFSS_state", singleSelectOptionId:"IFSSO_state_r"'
lacks "never merges" "$LOG" "pr merge"
eq "the work tree is not left mid-merge" "$(git -C "$W" rev-parse -q --verify MERGE_HEAD || echo clean)" clean

echo "real conflict, an open issue with the title exists: commented on"
mk conflict2
conflicting
FAKE_ISSUE_LIST='[{"number":9,"title":"Back-merge of main into develop needs a person (v0.1.1)","url":"https://example.test/o/r/issues/9"},{"number":4,"title":"Something else","url":"https://example.test/o/r/issues/4"}]' run v0.1.1
eq "exits 0" "$RC" 0
has "issue output is the existing one" "$OUTPUTS" "issue=https://example.test/o/r/issues/9"
has "commented on it" "$LOG" "issue comment 9"
lacks "no second issue" "$LOG" "api -X POST"

echo "real conflict, an issue with another title does not count"
mk conflict3
conflicting
FAKE_ISSUE_LIST='[{"number":4,"title":"Back-merge of main into develop needs a person (v0.0.9)","url":"https://example.test/o/r/issues/4"}]' run v0.1.1
has "a new issue is filed" "$LOG" "api -X POST /repos/o/r/issues"
lacks "no comment" "$LOG" "issue comment"

echo "real conflict, the org has no Task type: filed without it"
mk conflict4
conflicting
FAKE_TYPE_FAIL=1 run v0.1.1
eq "exits 0" "$RC" 0
has "issue output" "$OUTPUTS" "issue=https://example.test/o/r/issues/12"
eq "two create calls" "$(grep -c 'api -X POST' <<<"$LOG")" 2
eq "the second has no type" "$(grep 'api -X POST' <<<"$LOG" | sed -n 2p | grep -c 'type=Task')" 0

echo "real conflict, the field step fails: a warning, never fatal"
mk conflict5
conflicting
FAKE_GRAPHQL_FAIL=1 run v0.1.1
eq "exits 0" "$RC" 0
has "result is conflict" "$OUTPUTS" "result=conflict"
has "issue still reported" "$OUTPUTS" "issue=https://example.test/o/r/issues/12"
has "warns about the fields" "$OUT" "::warning::Could not read the issue fields"

echo "an existing backmerge branch is not overwritten"
mk keep
commit_on main hotfix.txt fixed "fix: patch"
# A person already pushed their own work to the branch, which the merge commit does not contain.
(cd "$W" && git fetch -q origin && git checkout -q -B chore/backmerge-v0.1.1 origin/develop \
  && echo mine > mine.txt && git add -A && git commit -q -m "chore: resolve by hand" \
  && git push -q origin chore/backmerge-v0.1.1)
kept=$(rev chore/backmerge-v0.1.1)
run v0.1.1
eq "exits 0" "$RC" 0
eq "the branch is as a person left it" "$(rev chore/backmerge-v0.1.1)" "$kept"

# ---------------------------------------------------------------------------
# Exact resolution of the version and lock files
# ---------------------------------------------------------------------------

# Realistic manifests, small enough to read. $1 version, $2 an extra dependency.
gen_pkg() {
  local ver="$1" dep="${2:-}" extra=""
  [ -z "$dep" ] || extra=$(printf ',\n    "%s": "^2.0.0"' "$dep")
  cat <<EOF
{
  "name": "app",
  "version": "$ver",
  "private": true,
  "license": "MIT",
  "scripts": {
    "build": "x"
  },
  "dependencies": {
    "alpha": "^1.0.0"$extra
  }
}
EOF
}

# $1 version, $2 an extra dependency, $3 the version of gamma, a dependency that
# happens to be at the same version as the root was.
gen_lock() {
  local ver="$1" dep="${2:-}" gamma="${3:-0.1.0}" extra=""
  [ -z "$dep" ] || extra=$(printf '\n    "node_modules/%s": {\n      "version": "2.0.0"\n    },' "$dep")
  cat <<EOF
{
  "name": "app",
  "version": "$ver",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "app",
      "version": "$ver",
      "dependencies": {
        "alpha": "^1.0.0"
      }
    },
    "node_modules/alpha": {
      "version": "1.0.0"
    },$extra
    "node_modules/gamma": {
      "version": "$gamma"
    }
  }
}
EOF
}

# $1 version, $2 an extra dependency, $3 the resolution of alpha.
gen_bun() {
  local ver="$1" dep="${2:-}" alpha="${3:-1.0.0}" extra=""
  [ -z "$dep" ] || extra=$(printf '\n    "%s": ["%s@2.0.0", "", {}, "sha-%s"],' "$dep" "$dep" "$dep")
  cat <<EOF
{
  "lockfileVersion": 1,
  "workspaces": {
    "": {
      "name": "app",
      "version": "$ver",
      "dependencies": {
        "alpha": "^1.0.0",
      },
    },
  },
  "packages": {
    "alpha": ["alpha@$alpha", "", {}, "sha-$alpha"],$extra
    "gamma": ["gamma@0.1.0", "", {}, "sha-gamma"],
  }
}
EOF
}

# The three manifests at 0.1.0 on main, with develop level with it.
seed() {
  (
    cd "$W" || exit 1
    gen_pkg 0.1.0 > package.json; gen_lock 0.1.0 > package-lock.json; gen_bun 0.1.0 > bun.lock
    git add -A && git commit -q -m "chore: manifests"
    git push -q origin main && git push -q -f origin main:develop
  )
}

# Every version of the three manifests in one commit, as a release or a
# prerelease commit makes it.
bump() { # $1 branch, $2 version, $3 subject
  edit_on "$1" "$3" "gen_pkg $2 > package.json; gen_lock $2 > package-lock.json; gen_bun $2 > bun.lock"
}

echo "develop added a dependency after the prerelease: the merge keeps it and main's version"
mk keepdep; seed
bump develop 0.2.0-develop.1 "chore(release): 0.2.0-develop.1 [skip ci]"
edit_on develop "feat: add beta" "gen_pkg 0.2.0-develop.1 beta > package.json; gen_lock 0.2.0-develop.1 beta > package-lock.json; gen_bun 0.2.0-develop.1 beta > bun.lock"
bump main 0.2.0 "chore(release): 0.2.0 [skip ci]"
run v0.2.0
eq "exits 0" "$RC" 0
has "result is merged" "$OUTPUTS" "result=merged"
eq "package.json: main's version, develop's dependency" "$(show develop package.json)" "$(gen_pkg 0.2.0 beta)"
eq "package-lock.json: main's version, develop's dependency" "$(show develop package-lock.json)" "$(gen_lock 0.2.0 beta)"
eq "bun.lock: main's version, develop's dependency" "$(show develop bun.lock)" "$(gen_bun 0.2.0 beta)"
has "develop's dependency is not lost" "$(show develop package.json)" '"beta"'
lacks "no prerelease version is left" "$(show develop package.json)$(show develop bun.lock)" "develop.1"
eq "pushed with [skip ci]" "$(subj develop)" "chore(release): merge main into develop [skip ci]"
eq "it is a merge commit" "$(nparents develop)" 2
eq "no gh call" "$LOG" ""
eq "no package manager was needed" "$(cat "$PM_LOG" 2>/dev/null)" ""

echo "lock files with root version lines: normalised, only the root ones"
mk rootver; seed
bump develop 0.2.0-develop.1 "chore(release): 0.2.0-develop.1 [skip ci]"
bump main 0.2.0 "chore(release): 0.2.0 [skip ci]"
run v0.2.0
has "result is merged" "$OUTPUTS" "result=merged"
eq "package-lock.json is main's" "$(show develop package-lock.json)" "$(gen_lock 0.2.0)"
eq "bun.lock is main's" "$(show develop bun.lock)" "$(gen_bun 0.2.0)"
eq "both package-lock.json root lines moved" "$(show develop package-lock.json | grep -c '"version": "0.2.0"')" 2
eq "a dependency at the old root version stays" "$(show develop package-lock.json | grep -c '"version": "0.1.0"')" 1

echo "a lockfile genuinely in conflict, bun present: regenerated, through a pull request"
mk regenbun; seed
# shellcheck disable=SC2016  # evaluated by the stub, in the clone
stub_pm bun bun 'echo "regenerated beta=$(grep -c beta package.json)" > bun.lock'
: > "$PM_LOG"
edit_on develop "chore(release): 0.2.0-develop.1 [skip ci]" "gen_pkg 0.2.0-develop.1 beta > package.json; gen_lock 0.2.0-develop.1 > package-lock.json; gen_bun 0.2.0-develop.1 beta 1.0.1 > bun.lock"
edit_on main "chore(release): 0.2.0 [skip ci]" "gen_pkg 0.2.0 > package.json; gen_lock 0.2.0 > package-lock.json; gen_bun 0.2.0 '' 1.0.2 > bun.lock"
dev_before=$(rev develop)
PM_STUBS="$WORK/stubs-bun" run v0.2.0
eq "exits 0" "$RC" 0
has "result is pull-request, with no fix on main" "$OUTPUTS" "result=pull-request"
eq "develop untouched" "$(rev develop)" "$dev_before"
eq "bun ran lockfile-only" "$(cat "$PM_LOG")" "bun install --lockfile-only"
eq "the lockfile is what bun wrote" "$(show chore/backmerge-v0.2.0 bun.lock)" "regenerated beta=1"
eq "bun saw the merged package.json" "$(show chore/backmerge-v0.2.0 package.json)" "$(gen_pkg 0.2.0 beta)"
eq "package-lock.json still merged exactly" "$(show chore/backmerge-v0.2.0 package-lock.json)" "$(gen_lock 0.2.0)"
eq "merge subject has no [skip ci]" "$(subj chore/backmerge-v0.2.0)" "chore(release): merge main into develop"
eq "it is a merge commit" "$(nparents chore/backmerge-v0.2.0)" 2
has "pr create called" "$LOG" "pr create"
has "pr body says the lockfile was rebuilt" "$LOG" "bun.lock"
has "pr body says no scripts ran" "$LOG" "no scripts run"
lacks "no issue filed" "$LOG" "issues"
lacks "never merges" "$LOG" "pr merge"

echo "a lockfile genuinely in conflict, npm present: regenerated without scripts"
mk regennpm; seed
# shellcheck disable=SC2016  # evaluated by the stub, in the clone
stub_pm npm npm 'echo "regenerated beta=$(grep -c beta package.json)" > package-lock.json'
: > "$PM_LOG"
edit_on develop "chore(release): 0.2.0-develop.1 [skip ci]" "gen_pkg 0.2.0-develop.1 beta > package.json; gen_lock 0.2.0-develop.1 beta 0.1.5 > package-lock.json; gen_bun 0.2.0-develop.1 > bun.lock"
edit_on main "chore(release): 0.2.0 [skip ci]" "gen_pkg 0.2.0 > package.json; gen_lock 0.2.0 '' 0.1.7 > package-lock.json; gen_bun 0.2.0 > bun.lock"
PM_STUBS="$WORK/stubs-npm" run v0.2.0
has "result is pull-request" "$OUTPUTS" "result=pull-request"
eq "npm ran lockfile-only, scripts off" "$(cat "$PM_LOG")" "npm install --package-lock-only --ignore-scripts"
eq "the lockfile is what npm wrote" "$(show chore/backmerge-v0.2.0 package-lock.json)" "regenerated beta=1"
eq "bun.lock still merged exactly" "$(show chore/backmerge-v0.2.0 bun.lock)" "$(gen_bun 0.2.0)"

echo "a lockfile in conflict and the package manager fails: a real conflict"
mk regenfail; seed
stub_pm fail bun 'exit 1'
: > "$PM_LOG"
edit_on develop "chore(release): 0.2.0-develop.1 [skip ci]" "gen_pkg 0.2.0-develop.1 > package.json; gen_bun 0.2.0-develop.1 '' 1.0.1 > bun.lock"
edit_on main "chore(release): 0.2.0 [skip ci]" "gen_pkg 0.2.0 > package.json; gen_bun 0.2.0 '' 1.0.2 > bun.lock"
dev_before=$(rev develop)
PM_STUBS="$WORK/stubs-fail" run v0.2.0
eq "exits 0" "$RC" 0
has "result is conflict" "$OUTPUTS" "result=conflict"
eq "develop untouched" "$(rev develop)" "$dev_before"
eq "the branch is main as released" "$(rev chore/backmerge-v0.2.0)" "$(rev main)"
has "the issue lists the lockfile" "$LOG" "- \`bun.lock\`"
eq "the work tree is not left mid-merge" "$(git -C "$W" rev-parse -q --verify MERGE_HEAD || echo clean)" clean

echo "a lockfile in conflict and no package manager: a real conflict, pull request and issue"
mk regenmiss; seed
edit_on develop "chore(release): 0.2.0-develop.1 [skip ci]" "gen_pkg 0.2.0-develop.1 > package.json; gen_bun 0.2.0-develop.1 '' 1.0.1 > bun.lock"
edit_on main "chore(release): 0.2.0 [skip ci]" "gen_pkg 0.2.0 > package.json; gen_bun 0.2.0 '' 1.0.2 > bun.lock"
dev_before=$(rev develop)
run v0.2.0
eq "exits 0" "$RC" 0
has "result is conflict" "$OUTPUTS" "result=conflict"
has "the missing tool is said" "$OUT" "bun is not installed"
has "pr output" "$OUTPUTS" "pr=https://example.test/o/r/pull/7"
has "issue output" "$OUTPUTS" "issue=https://example.test/o/r/issues/12"
has "the issue lists the lockfile" "$LOG" "- \`bun.lock\`"
eq "develop untouched" "$(rev develop)" "$dev_before"

echo "a lockfile in conflict next to a package.json conflict: nothing is run"
mk regenpkg; seed
: > "$PM_LOG"
edit_on develop "feat: develop deps" "gen_pkg 0.1.0 beta > package.json; gen_bun 0.1.0 '' 1.0.1 > bun.lock"
edit_on main "fix: main deps" "gen_pkg 0.1.0 gamma > package.json; gen_bun 0.1.0 '' 1.0.2 > bun.lock"
PM_STUBS="$WORK/stubs-bun" run v0.1.1
has "result is conflict" "$OUTPUTS" "result=conflict"
eq "no package manager ran" "$(cat "$PM_LOG")" ""

echo "the target branch is missing: skipped, nothing pushed, nothing fetched"
mk nodevelop
git -C "$O" branch -q -D develop
commit_on main hotfix.txt fixed "fix: patch"
refs_before=$(git -C "$O" for-each-ref)
run v0.1.1
eq "exits 0" "$RC" 0
has "result is skipped" "$OUTPUTS" "result=skipped"
has "a notice says why" "$OUT" "::notice::develop does not exist on the remote"
eq "no gh call" "$LOG" ""
eq "nothing was pushed" "$(git -C "$O" for-each-ref)" "$refs_before"
eq "no other output" "$(grep -vc '^result=' <<<"$OUTPUTS")" 0
mk prefixed
git -C "$O" branch -q -D develop
git -C "$O" branch -q feature/develop main
run v0.1.1
has "a branch that only ends in the name does not count" "$OUTPUTS" "result=skipped"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
