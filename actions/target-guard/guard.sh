#!/usr/bin/env bash
# Keep the release branch for releases. In a repo that develops on an
# integration branch, the release branch (`main`) must only receive that branch
# merged in, plus, where the repo opted in, a security patch. Anything else
# aimed at it fails here, and the ruleset that requires `PR Checks` on the
# release branch is what makes the failure bind.
#
# In order:
#   1. not a pull_request, or the base is not the release branch, or the release
#      branch IS the default branch -> `skip`: nothing to guard
#   2. a fork -> `reject`: the lane and the release PR are same-repo only, and
#      a fork's own `develop` must not pass for ours
#   3. the head is the default branch -> `release`
#   4. the head is not a lane PR (`fix/security-*`, or Renovate's [SECURITY]
#      update) -> `reject`
#   5. a lane PR needs the repository property `security_hotfix` to be exactly
#      `enabled`; absent, anything else, or an API error is off (fail closed)
#   6. a lane PR may only cut a patch: its title is a conventional `fix`
#      without `!`, and no commit on it is a `feat`, has `!` before the colon,
#      or carries a BREAKING CHANGE footer. The title counts because a squash
#      merge writes it as the commit; the commits count because a merge commit
#      or a rebase keeps them. More than 250 commits cannot be listed in full,
#      so that is a reject too.
#   -> `lane`
#
# `route` is steps 1-4 and `judge` steps 5-6; both are pure, set verdict and
# reason from the environment, and `decide` is the two together, which test.sh
# runs. `verdict` reads the property and the commits from the API, only when a
# lane PR makes them matter, and prints verdict/reason: merge-gate's `hotfix`
# policy derives the verdict that way. `run` is `verdict` writing to
# $GITHUB_OUTPUT with an annotation, and exits 1 on `reject`.
set -euo pipefail

# The one place that says who is a bot.
GATE="$(dirname "${BASH_SOURCE[0]}")/../agent-gate/gate.sh"
# Renovate only (DODI-00048): it is the bot whose security PRs carry `[SECURITY]`.
# The gate's dependency kind normalises case and the `app/` form; it also counts
# Dependabot, which the lane does not admit.
renovate() {
  [ "$("$GATE" kind "$1")" = dependency ] || return 1
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in *renovate*) return 0 ;; esac
  return 1
}

RELEASE_BRANCH="${RELEASE_BRANCH:-main}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"

# The API lists at most this many commits of a pull request, however many
# pages you ask for.
COMMIT_CAP=250

FIX_RE='^fix(\([^)]*\))?: '
# The first line of a message: `type`, optional `(scope)`, optional `!`, colon.
FEAT_RE='^feat(\([^)]*\))?!?:'
BANG_RE='^[A-Za-z]+(\([^)]*\))?!:'
# Case-insensitive on purpose: a doubtful footer is a reject, not a pass.
BREAKING_RE='^[[:space:]|*]*BREAKING[ -]CHANGE[:[:space:]]'

how_to() {
  # shellcheck disable=SC2016  # the backticks are Markdown
  printf 'Open the pull request against `%s` instead. For a security-critical patch, use a branch named `fix/security-*` in a repository that has the security hotfix lane enabled (the `security_hotfix` repository property).' "${DEFAULT_BRANCH:-the default branch}"
}

# Inputs: EVENT BASE HEAD RELEASE_BRANCH DEFAULT_BRANCH FORK(true|false) TITLE AUTHOR.
# Sets verdict (skip|release|lane-check|reject) and reason.
route() {
  verdict=skip
  if [ "${EVENT:-}" != pull_request ]; then
    reason="not a pull request"; return
  fi
  if [ "${BASE:-}" != "$RELEASE_BRANCH" ]; then
    reason="the base is not the release branch ($RELEASE_BRANCH)"; return
  fi
  if [ "$RELEASE_BRANCH" = "$DEFAULT_BRANCH" ]; then
    reason="the release branch is the default branch, so this repository has no separate integration branch"; return
  fi
  if [ "${FORK:-}" = true ]; then
    verdict=reject
    reason="a pull request from a fork cannot target \`$RELEASE_BRANCH\`. $(how_to)"
    return
  fi
  if [ -n "$DEFAULT_BRANCH" ] && [ "${HEAD:-}" = "$DEFAULT_BRANCH" ]; then
    verdict=release; reason="a release: \`$DEFAULT_BRANCH\` merged into \`$RELEASE_BRANCH\`"; return
  fi
  if [[ "${HEAD:-}" == fix/security-* ]] \
     || { [[ "${TITLE:-}" == *'[SECURITY]'* ]] && renovate "${AUTHOR:-}"; }; then
    verdict=lane-check; reason="a security patch, to be checked"; return
  fi
  verdict=reject
  reason="\`$RELEASE_BRANCH\` only receives releases from \`${DEFAULT_BRANCH:-the default branch}\`, plus security patches. $(how_to)"
}

# Steps 5-6 for a lane-check. Inputs: HOTFIX (the property's value) and COMMITS
# (a JSON array of commit messages; empty or invalid means they could not be read).
judge() {
  if [ "${HOTFIX:-}" != enabled ]; then
    verdict=reject
    reason="a security patch cannot target \`$RELEASE_BRANCH\`: the security hotfix lane is not enabled in this repository (\`security_hotfix\` is '${HOTFIX:-unreadable}'). $(how_to)"
    return
  fi
  if ! [[ "${TITLE:-}" =~ $FIX_RE ]]; then
    verdict=reject
    reason="a security patch must have a conventional \`fix\` title without \`!\` (\`fix(scope): …\`) so it cuts a patch release, not '${TITLE:-}'"
    return
  fi
  if ! jq -e 'type == "array"' <<<"${COMMITS:-}" >/dev/null 2>&1; then
    verdict=reject; reason="the commits of the pull request could not be read, so a feature or breaking change cannot be ruled out"; return
  fi
  local n msg first
  n=$(jq 'length' <<<"$COMMITS")
  if [ "$n" -ge "$COMMIT_CAP" ]; then
    verdict=reject; reason="the pull request has $COMMIT_CAP commits or more, which is where the API stops listing, so a feature or breaking change cannot be ruled out"; return
  fi
  while IFS= read -r msg; do
    msg=$(base64 -d <<<"$msg")
    first="${msg%%$'\n'*}"
    if [[ "$first" =~ $FEAT_RE ]]; then
      verdict=reject; reason="a security patch may only cut a patch, but a commit is a feature: '$first'"; return
    fi
    if [[ "$first" =~ $BANG_RE ]]; then
      verdict=reject; reason="a security patch may only cut a patch, but a commit is a breaking change: '$first'"; return
    fi
    if grep -qiE "$BREAKING_RE" <<<"$msg"; then
      verdict=reject; reason="a security patch may only cut a patch, but the commit '$first' carries a BREAKING CHANGE footer"; return
    fi
  done < <(jq -r '.[] | @base64' <<<"$COMMITS")
  verdict=lane
  reason="a security patch (\`${HEAD:-}\`) into \`$RELEASE_BRANCH\`: the lane is enabled and it only cuts a patch"
}

decide() {
  route
  [ "$verdict" != lane-check ] || judge
}

emit() {
  local out="${GITHUB_OUTPUT:-/dev/stdout}"
  { echo "verdict=$verdict"; echo "reason=$reason"; } >> "$out"
  case "$verdict" in
    reject) echo "::error title=Wrong target branch::$reason" ;;
    lane)   echo "::notice title=Security hotfix lane::$reason" ;;
    *)      echo "target guard: $verdict: $reason" ;;
  esac
  [ "$verdict" != reject ] || exit 1
}

# Sets verdict and reason, reading the API for a lane-check.
assess() {
  : "${REPO:?}"
  route
  if [ "$verdict" = lane-check ]; then
    # Anything but `enabled` is off, an API error included.
    HOTFIX=$(gh api "repos/$REPO" --jq '.custom_properties.security_hotfix // ""' 2>/dev/null || true)
    COMMITS=""
    if [ "$HOTFIX" = enabled ] && [ -n "${NUMBER:-}" ]; then
      # Not `|| true` on the pipeline: a page that failed would leave a partial
      # list that reads as the whole one.
      if pages=$(gh api --paginate "repos/$REPO/pulls/$NUMBER/commits?per_page=100" \
                   --jq '[.[].commit.message]' 2>/dev/null); then
        COMMITS=$(jq -s 'add // []' <<<"$pages" 2>/dev/null || true)
      fi
    fi
    judge
  fi
}

run() { assess; emit; }
print() { printf 'verdict=%s\nreason=%s\n' "$verdict" "$reason"; }

case "${1:-run}" in
  decide)  decide; print ;;
  verdict) assess; print ;;
  run)     run ;;
  *)       echo "usage: guard.sh [run|verdict|decide]" >&2; exit 2 ;;
esac
