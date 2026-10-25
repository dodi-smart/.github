#!/usr/bin/env bash
# Merge FROM back into TO after a release, as a real merge commit.
#
# Never a force-push: the release commit must stay reachable from both branches,
# or the next run recomputes versions from a history that no longer matches the
# tags.
#
# Five outcomes, all of which end the step successfully:
#   skipped       TO does not exist on the remote (a repo with only FROM): there
#                 is nothing to merge into, and nothing to fail over.
#   up-to-date    nothing on FROM that TO lacks.
#   merged        FROM carries only release commits: push the merge straight to
#                 TO, [skip ci] so it does not trigger the release workflow again.
#   pull-request  FROM carries a real change TO lacks (a hotfix cut from FROM),
#                 or a lockfile had to be regenerated to resolve the merge.
#                 Push the merge to chore/backmerge-<tag> and open a pull request,
#                 WITHOUT [skip ci], so the checks run on it before anything
#                 reaches TO.
#   conflict      a conflict beyond the version files, or a merge that would
#                 lower a version TO has. Push FROM itself to the
#                 same branch so the pull request shows the conflict, and file an
#                 issue. Exits 0, not 1: a deploy chained on the release job must
#                 still ship the fix that was just released, and the issue and
#                 the pull request are the signal, where a red job would only
#                 hold back a production fix over a bookkeeping merge.
#
# Reads its inputs from the environment (FROM, TO, RESOLVE_EXTRA, TAG, REPO,
# GH_TOKEN) and writes result/pr/issue to $GITHUB_OUTPUT. test.sh runs it
# against local git repositories with `gh` stubbed.
set -euo pipefail

: "${FROM:?}" "${TO:?}" "${REPO:?}"
RESOLVE_EXTRA="${RESOLVE_EXTRA:-}"
TAG="${TAG:-}"

out() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/null}"; printf '%s=%s\n' "$1" "$2"; }

PR_URL=""
ISSUE_URL=""
hotfix=""
regenerated=""

# ---------------------------------------------------------------------------
# Thin wrappers over git and gh, so every decision below reads the same in the
# test, where gh is a stub.
# ---------------------------------------------------------------------------

# Newest history of both branches, as the remote has it now. semantic-release
# just pushed a commit to FROM, and another push may have landed since the
# checkout, so merge what the remote has now. --force drops release output that
# was never committed.
sync_branches() {
  git config user.name  "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"
  git fetch origin "$FROM" "$TO"
  git checkout --force -B "$TO" "origin/$TO"
}

# Subjects of the commits FROM has and TO lacks that are not release commits.
# Merges are left out (they carry no change of their own), and so is every
# `chore(release): ` commit, which is the release bot's own bookkeeping. Anything
# left is a change made on FROM directly: a hotfix.
hotfix_subjects() {
  git log --no-merges --format=%s "origin/$TO..origin/$FROM" | grep -v '^chore(release): ' || true
}

# Push a ref to the backmerge branch. A branch that already exists is left as it
# is rather than overwritten: a re-run of the same release must not discard what
# a person pushed to it while resolving a conflict.
push_branch() {
  local src="$1" branch="$2"
  if git push origin "$src:refs/heads/$branch"; then return 0; fi
  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    echo "::notice::$branch already exists on the remote; leaving it as it is."
    return 0
  fi
  return 1
}

# The open pull request for a head branch, or a new one, in PR_URL. A global
# rather than printed, so a warning from inside cannot end up in the URL.
open_pr() {
  local branch="$1" title="$2" body="$3" url
  url=$(gh pr list --repo "$REPO" --head "$branch" --base "$TO" --state open --json url 2>/dev/null \
        | jq -r '.[0].url // empty' 2>/dev/null || true)
  if [ -z "$url" ]; then
    url=$(gh pr create --repo "$REPO" --base "$TO" --head "$branch" --title "$title" --body "$body") || return 1
  fi
  PR_URL="$url"
}

# Label pull request $1 with $2, creating the label (description $3) if the
# repository lacks it. A failure is a warning: the pull request stands.
label_pr() {
  gh label create "$2" --repo "$REPO" --color c5def5 --description "$3" >/dev/null 2>&1 || true
  gh pr edit "$1" --repo "$REPO" --add-label "$2" >/dev/null \
    || echo "::warning::Could not label $1 with $2."
}

# $1 is clean or conflict; $label is the release, set in main below.
pr_body() {
  local kind="$1"
  {
    echo "Merges \`$FROM\` back into \`$TO\` after \`$label\`."
    echo
    if [ "$kind" = conflict ]; then
      echo "This does not merge cleanly. The branch is \`$FROM\` as released, so the conflicts show here, and an issue asks a person to resolve them."
    else
      if [ -n "$hotfix" ]; then
        echo "\`$FROM\` carries a fix that \`$TO\` does not have yet, so the release has to reach \`$TO\` through a pull request: the checks run on the merge before it lands."
      fi
      if [ -n "$regenerated" ]; then
        echo "The merge changed a lockfile that did not merge cleanly (${regenerated# }): it was rebuilt from the merged \`package.json\`, lockfile only, with no scripts run. The checks must pass on it before it lands."
      fi
      echo "The merge gate merges it once they pass."
    fi
    echo
    echo "**Merge it with a merge commit. Never squash or rebase it.** The release commit and the tag must stay reachable from \`$TO\`, or the next release computes its version from a history that no longer matches the tags."
  }
}

# ---------------------------------------------------------------------------
# Resolving the version and lock files exactly, not by whole-file choice.
#
# Taking the whole file from FROM (`git checkout --theirs`) is what this used to
# do, and it silently dropped every dependency change TO had made of its own:
# certain to matter after a hotfix, when the branches have moved their
# dependencies apart. What genuinely conflicts after a release is only the
# version lines, which a prerelease commit on TO and the release commit on FROM
# both rewrote. So make those lines agree and let git merge the rest.
#
# They agree on the HIGHER of the two, never on FROM's by default: a hotfix
# release on FROM (1.9.1) is behind the prerelease TO already carries
# (1.10.0-develop.14), and taking FROM's would move TO backwards. Where TO
# writes no prerelease (the shared config's default), TO is still on the last
# release and FROM's patch is the higher, so FROM's wins exactly when it should.
# versions.pl holds the comparison and the version files it knows, shared with
# actions/version-guard, which fails a pull request that lowers one.
# ---------------------------------------------------------------------------

VERSIONS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../version-guard" && pwd)/versions.pl"

# The three stages of conflicted file $1 as $2/base, $2/ours and $2/theirs. A
# missing stage (the file was added or deleted on one side) fails: that is a
# real conflict, not a version line.
stages() {
  git show ":1:$1" > "$2/base"   2>/dev/null || return 1
  git show ":2:$1" > "$2/ours"   2>/dev/null || return 1
  git show ":3:$1" > "$2/theirs" 2>/dev/null || return 1
}

# Stage $2/merged as file $1.
stage_merged() { cp "$2/merged" "$1" && git add -- "$1"; }

# A version file: every version key, in all three stages, to the higher of ours
# and theirs, then a three-way merge of the rest. Fails, leaving it conflicted,
# when two values cannot be compared or the rest does not merge cleanly.
resolve_keyed() {
  local f="$1" d="$2"
  stages "$f" "$d" || return 1
  perl "$VERSIONS" align "$f" "$d/base" "$d/ours" "$d/theirs" || return 1
  git merge-file -p "$d/ours" "$d/base" "$d/theirs" > "$d/merged" || return 1
  stage_merged "$f" "$d"
}

# A changelog: TO's, with each release section of FROM's that TO lacks placed
# before the first lower release. Never FROM's whole file, which would drop the
# prerelease notes TO has written since the merge base.
resolve_changelog() {
  local f="$1" d="$2"
  stages "$f" "$d" || return 1
  perl "$VERSIONS" changelog "$d/ours" "$d/theirs" > "$d/merged" || return 1
  stage_merged "$f" "$d"
}

# Whether $1 is one of the caller's resolve-extra paths.
in_extra() { tr -s ' ' '\n' <<<"$RESOLVE_EXTRA" | grep -qxF -- "$1"; }

# The version keys the merge at HEAD has LOWER than TO, as "path: key: a -> b"
# lines; empty when none. Run on every merge, clean ones too: git takes FROM's
# side of a line TO never touched, and no conflict means no resolution above.
version_regressions() {
  local d f
  d=$(mktemp -d)
  while IFS= read -r f; do
    git show "origin/$TO:$f" > "$d/old" 2>/dev/null || continue
    git show "HEAD:$f"       > "$d/new" 2>/dev/null || continue
    perl "$VERSIONS" regress "$f" "$d/old" "$d/new"
  done < <(git diff --name-only "origin/$TO" HEAD | perl "$VERSIONS" files)
  rm -rf "$d"
}

# Rebuild lockfile $1 from the merged package.json, lockfile-only. It starts
# from FROM's lockfile, which carries any security pin made on FROM, and the
# package manager reconciles it with the merged package.json; a lock-only
# refresh that TO had made and this undoes is redone by Renovate. Never runs a
# lifecycle script: this job holds a push-capable App token. A missing tool or a
# failed run fails the function, and the lockfile stays conflicted.
regenerate() {
  local f="$1" tool
  local -a cmd
  case "$f" in
    bun.lock)          cmd=(bun install --lockfile-only) ;;
    package-lock.json) cmd=(npm install --package-lock-only --ignore-scripts) ;;
    pnpm-lock.yaml)    cmd=(pnpm install --lockfile-only --ignore-scripts) ;;
    yarn.lock)         cmd=(yarn install --mode update-lockfile) ;;
    *) return 1 ;;
  esac
  tool="${cmd[0]}"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "::notice::$f conflicts and $tool is not installed here, so it cannot be regenerated."
    return 1
  fi
  git checkout --theirs -- "$f" || return 1
  if ! "${cmd[@]}"; then
    echo "::notice::${cmd[*]} failed; $f stays conflicted."
    return 1
  fi
  # A lockfile-only install must not move the manifest the merge produced.
  git checkout -- package.json 2>/dev/null || true
  git add -- "$f"
}

# ---------------------------------------------------------------------------
# The issue a person is asked to act on.
# ---------------------------------------------------------------------------

issue_body() {
  local pr="$1" files="$2" why="$3" heading="${4:-Conflicted files:}"
  {
    echo "$why"
    echo
    [ -z "$pr" ] || echo "Pull request: $pr"
    if [ -n "$files" ]; then
      echo
      echo "$heading"
      # shellcheck disable=SC2016  # backticks are Markdown here
      while IFS= read -r f; do [ -z "$f" ] || printf -- '- `%s`\n' "$f"; done <<<"$files"
    fi
    echo
    echo "To resolve it:"
    echo
    echo "1. Check out the pull request's branch and merge \`$TO\` into it."
    echo "2. Resolve the conflicts, commit and push."
    echo "3. Merge the pull request with a **merge commit**, never a squash or a rebase, so the release commit and tag stay reachable from \`$TO\`."
  }
}

# Priority, Risk, Source, Agent mode and Triage state on an issue, so the
# triage agent leaves it for a person. The field ids come from the repository,
# not the organisation: a repo-scoped App token gets 403 on every /orgs/*
# endpoint. The mutation wants node ids, and its inner key is `fieldId`. A
# failure here is a warning and nothing more: the issue exists and says what to do.
set_issue_fields() {
  local node="$1" resp pairs n
  local want='{"Priority":"High","Risk":"High","Source":"Bot","Agent mode":"Human only","Triage state":"Ready for plan"}'
  # shellcheck disable=SC2016  # GraphQL variables, not shell ones
  resp=$(gh api graphql \
    -f query='query($o:String!,$r:String!){ repository(owner:$o,name:$r){ issueFields(first:50){ nodes{ ... on IssueFieldSingleSelect { id name options{ id name } } } } } }' \
    -f o="${REPO%%/*}" -f r="${REPO#*/}") || { echo "::warning::Could not read the issue fields; the issue has none set."; return 0; }
  pairs=$(jq -r --argjson want "$want" '
      [ .data.repository.issueFields.nodes[]?
        | select(.name != null) | . as $f | select($want[$f.name] != null)
        | ($f.options[]? | select(.name == $want[$f.name])) as $o
        | "{fieldId:\"\($f.id)\", singleSelectOptionId:\"\($o.id)\"}" ]
      | join(",")' <<<"$resp" 2>/dev/null) || pairs=""
  if [ -z "$pairs" ]; then
    echo "::warning::None of the issue fields (Priority, Risk, Source, Agent mode, Triage state) could be matched; the issue has none set."
    return 0
  fi
  n=$(grep -o 'fieldId' <<<"$pairs" | wc -l | tr -d ' ')
  [ "$n" -ge 5 ] || echo "::warning::Only $n of 5 issue fields could be matched; the others stay unset."
  gh api graphql -f query="mutation{ setIssueFieldValue(input:{issueId:\"$node\", issueFields:[$pairs]}){ clientMutationId } }" >/dev/null \
    || echo "::warning::Setting the issue fields failed; the issue has none set."
  return 0
}

# File the issue, or comment on the open one with the same title; its URL goes
# in ISSUE_URL.
ensure_issue() {
  local title="$1" body="$2" existing num resp url node
  existing=$(gh issue list --repo "$REPO" --state open --search "\"$title\" in:title" --json number,title,url 2>/dev/null \
             | jq -c --arg t "$title" '[.[] | select(.title == $t)][0] // empty' 2>/dev/null || true)
  if [ -n "$existing" ]; then
    num=$(jq -r '.number' <<<"$existing"); url=$(jq -r '.url' <<<"$existing")
    gh issue comment "$num" --repo "$REPO" --body "$body" >/dev/null \
      || echo "::warning::Could not comment on the open issue $url."
    ISSUE_URL="$url"
    return 0
  fi
  # `type` is org-level; an org without a Task type rejects it, and the issue
  # is worth more than its type.
  resp=$(gh api -X POST "/repos/$REPO/issues" -f title="$title" -f body="$body" -f type=Task 2>/dev/null) \
    || resp=$(gh api -X POST "/repos/$REPO/issues" -f title="$title" -f body="$body") \
    || { echo "::warning::Could not file the back-merge issue."; return 1; }
  url=$(jq -r '.html_url // empty' <<<"$resp"); node=$(jq -r '.node_id // empty' <<<"$resp")
  ISSUE_URL="$url"
  [ -z "$node" ] || set_issue_fields "$node"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

# A repo with only FROM has no integration branch to merge into. Look before
# any fetch of TO, which would fail on a branch that is not there. Exit status 2
# is "no matching ref"; any other failure (the network) is left to the fetch,
# which fails loudly. The full ref is matched: a bare name would also match
# `some/prefix/<to>`.
rc=0
git ls-remote --exit-code --heads origin "refs/heads/$TO" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  echo "::notice::$TO does not exist on the remote; there is nothing to merge $FROM into."
  out result skipped
  exit 0
fi

sync_branches

# The release, for the branch, pull request and issue names: stable across a
# re-run of the same one.
label="${TAG:-$(git rev-parse --short=8 "origin/$FROM")}"
branch="chore/backmerge-$(printf '%s' "$label" | tr -c 'A-Za-z0-9._\n-' '-')"

if git merge-base --is-ancestor "origin/$FROM" "origin/$TO"; then
  echo "$TO already contains $FROM; nothing to merge."
  out result up-to-date
  exit 0
fi

[ -z "$(hotfix_subjects)" ] || hotfix=1

# Only the direct merge carries [skip ci]: a merge that goes through a pull
# request needs its checks to run.
subject="chore(release): merge $FROM into $TO"
msg="$subject"
[ -n "$hotfix" ] || msg="$subject [skip ci]"

conflicted=""
regressed=""
# A stable release after a prerelease ALWAYS conflicts on the version files: the
# prerelease commit on $TO and the release commit on $FROM both rewrote the
# version lines (observed on a bun repo's package.json, bun.lock and
# CHANGELOG.md, and on a Gradle monorepo's per-module version.properties and
# changelogs). Resolve exactly what that is, and nothing wider, so $TO's own
# changes to the same files survive:
#
#   a version file versions.pl knows (package.json and its lockfiles,
#   version.properties, pubspec.yaml, ...), at any depth
#                 every version key to the higher of the two in every stage,
#                 then three-way merge.
#   CHANGELOG.md, at any depth
#                 $TO's, plus the release sections of $FROM's it lacks.
#   a lockfile still conflicted
#                 a genuine dependency divergence. Take $FROM's, then rebuild it
#                 from the merged package.json with the package manager. That
#                 forces the pull request path, whatever $FROM carries.
#   resolve-extra the caller's explicit choice, whole file toward $FROM. A
#                 version file or a changelog is resolved as above even when it
#                 is listed here (the one place this rule is stated): its whole
#                 file toward $FROM is the rollback this exists to prevent.
#
# Anything else that conflicts is a real conflict and goes to a person.
if ! git merge "origin/$FROM" --no-ff -m "$msg"; then
  if ! git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    echo "::error::git merge failed without a conflict to resolve."
    exit 1
  fi
  scratch=$(mktemp -d)
  unmerged=$(git diff --name-only --diff-filter=U)
  versioned=$(perl "$VERSIONS" files <<<"$unmerged")
  while IFS= read -r f; do
    case "$f" in
      pnpm-lock.yaml|yarn.lock) ;; # no version line to align; rebuilt below if still conflicted
      CHANGELOG.md|*/CHANGELOG.md) resolve_changelog "$f" "$scratch" || true ;;
      *)
        if grep -qxF -- "$f" <<<"$versioned"; then
          resolve_keyed "$f" "$scratch" || true
        elif in_extra "$f"; then
          git checkout --theirs -- "$f"
          git add -- "$f"
        fi
        ;;
    esac
  done <<<"$unmerged"
  rm -rf "$scratch"

  # Only lockfiles left: rebuild them. Anything else still conflicted (a
  # package.json included) means a person has to look anyway, so run nothing.
  unmerged=$(git diff --name-only --diff-filter=U)
  if [ -n "$unmerged" ] && ! grep -qvxE 'bun\.lock|package-lock\.json|pnpm-lock\.yaml|yarn\.lock' <<<"$unmerged"; then
    for f in bun.lock package-lock.json pnpm-lock.yaml yarn.lock; do
      grep -qx "$f" <<<"$unmerged" || continue
      if regenerate "$f"; then regenerated="$regenerated $f"; fi
    done
  fi

  conflicted=$(git diff --name-only --diff-filter=U)
  if [ -n "$conflicted" ]; then
    echo "::notice::Back-merge conflicts beyond the version files:"
    echo "$conflicted"
    git merge --abort
  elif [ -n "$regenerated" ]; then
    # The checks must run on a regenerated lockfile: no [skip ci].
    git commit -m "$subject"
  else
    git commit --no-edit
  fi
fi

# However the merge came about, it must not lower a version $TO has. A lowered
# version goes to a person exactly like a conflict: nothing reaches $TO.
if [ -z "$conflicted" ]; then
  regressed=$(version_regressions)
  if [ -n "$regressed" ]; then
    echo "::notice::The back-merge would move a version on $TO backwards:"
    echo "$regressed"
    git reset -q --hard "origin/$TO"
    conflicted="$regressed"
  fi
fi

if [ -z "$conflicted" ] && [ -z "$hotfix" ] && [ -z "$regenerated" ]; then
  git push origin "$TO"
  out result merged
  exit 0
fi

# Clean hotfix or a regenerated lockfile: the merge commit as built. Conflict:
# FROM as released, so the pull request shows the conflict. A failure to push or
# to open the pull request is not worth failing the job over (a deploy chained
# on it must still ship the fix); it falls through to the issue below, which is
# how a person finds out.
if [ -z "$conflicted" ]; then
  src=HEAD kind=clean
  why="The back-merge of \`$FROM\` into \`$TO\` has to go through a pull request (a fix that \`$TO\` lacked, or a regenerated lockfile), but it could not be opened."
elif [ -n "$regressed" ]; then
  src="refs/remotes/origin/$FROM" kind=conflict
  why="Merging \`$FROM\` into \`$TO\` after \`$label\` would move a version on \`$TO\` backwards, so it needs a person. Keep \`$TO\`'s version wherever it is the higher."
else
  src="refs/remotes/origin/$FROM" kind=conflict
  why="Merging \`$FROM\` into \`$TO\` after \`$label\` conflicts beyond the version files, so it needs a person."
fi
if push_branch "$src" "$branch" && open_pr "$branch" "$subject after $label" "$(pr_body "$kind")"; then
  if [ "$kind" = clean ]; then
    # The merge gate asks the review agent to look at a lockfile nobody wrote.
    [ -z "$regenerated" ] || label_pr "$PR_URL" backmerge:regenerated \
      "A back-merge whose lockfile was rebuilt: the merge gate wants a review verdict"
    out result pull-request
    out pr "$PR_URL"
    echo "Opened $PR_URL; the merge gate merges it once the checks pass."
    exit 0
  fi
else
  echo "::warning::Could not push $branch or open its pull request into $TO."
fi

title="Back-merge of $FROM into $TO needs a person ($label)"
heading="Conflicted files:"
[ -z "$regressed" ] || heading="Versions the merge would lower:"
ensure_issue "$title" "$(issue_body "$PR_URL" "$conflicted" "$why" "$heading")" || true
echo "::warning title=Back-merge needs a person::$FROM was released but not merged into $TO. ${ISSUE_URL:-No issue could be filed.} ${PR_URL}"
out result conflict
[ -z "$PR_URL" ] || out pr "$PR_URL"
[ -z "$ISSUE_URL" ] || out issue "$ISSUE_URL"
exit 0
