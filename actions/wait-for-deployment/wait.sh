#!/usr/bin/env bash
# Wait until the frontend host has deployed the commit this job checked out, so a
# health check after it tests that commit and not the deployment it replaces.
#
# A host builds the same push in parallel with the caller's deploy job, and moves
# its stable URL only when its own build ends. A check that runs right after
# `db push` therefore passes against whatever was already live.
#
# Two proofs, either or both:
#   ENVIRONMENT  a successful GitHub Deployment of the commit in that environment.
#                Hosts post these as their build progresses.
#   SHA_URL      a URL whose body carries the commit's sha, for a host that posts
#                no Deployments.
#
# The commit is HEAD of the checkout. A release commit carries `[skip ci]`, which
# hosts honour, so what the host builds is the commit before it; that one counts
# too. Fails on timeout and on a failed deployment, never warns: a warning here
# is a green check that proved nothing.
#
# Reads its inputs from the environment and writes deployment-id/sha/url to
# $GITHUB_OUTPUT. action.yml is a thin wrapper; test.sh runs the `--` modes.
set -euo pipefail

# The commits whose deployment counts: HEAD, and its first parent when HEAD's own
# message says CI should skip it.
candidates() {
  git rev-parse HEAD
  if git log -1 --format=%B HEAD | grep -qiE '\[(ci skip|skip [a-z ]+)\]'; then
    if ! git rev-parse --verify --quiet 'HEAD^'; then
      echo "::warning::HEAD asks CI to skip it, but its parent is not in this checkout (fetch-depth: 2 or more)" >&2
    fi
  fi
}

# Deployments array on stdin -> the newest one the host made, as one JSON line, or
# nothing. The job this workflow runs in creates its own Deployment in the same
# environment through the `github-actions` app; it succeeds when the job does, so
# counting it would pass every time.
pick() {
  jq -c 'map(select(.performed_via_github_app.slug != "github-actions"))
         | sort_by(.created_at) | last // empty'
}

# Statuses array on stdin, newest first -> `state<TAB>url`. `environment_url` is
# the address hosts fill in; `target_url` is the fallback.
state() {
  jq -r 'first // {} | [(.state // "none"), (.environment_url // .target_url // "")] | @tsv'
}

case "${1:-}" in
  --candidates) candidates; exit 0 ;;
  --pick)       pick; exit 0 ;;
  --state)      state; exit 0 ;;
esac

: "${REPO:?}"
INTERVAL="${INTERVAL:-15}"
deadline=$((SECONDS + ${TIMEOUT_MINUTES:-10} * 60))
out="${GITHUB_OUTPUT:-/dev/stdout}"
shas=()
while IFS= read -r sha; do shas+=("$sha"); done < <(candidates)
echo "commits that count as this deploy: ${shas[*]}"

# Fills $RESP. Three failed calls in a row is a permission or a typo, not a slow
# host, and waiting out the timeout would hide it.
api_failures=0
RESP=
api() {
  if RESP=$(gh api "$1"); then
    api_failures=0
    return 0
  fi
  api_failures=$((api_failures + 1))
  if [ "$api_failures" -ge 3 ]; then
    echo "::error::the GitHub API refused three calls in a row (reading deployments needs deployments: read)"
    exit 1
  fi
  return 1
}

timed_out() {
  echo "::error::$1 within ${TIMEOUT_MINUTES:-10} min; failing the deploy rather than checking a deployment that may not be this commit"
  exit 1
}

if [ -n "${ENVIRONMENT:-}" ]; then
  while :; do
    all='[]'
    for sha in "${shas[@]}"; do
      if api "repos/$REPO/deployments?sha=$sha&environment=$ENVIRONMENT&per_page=100"; then
        all=$(printf '%s\n%s' "$all" "$RESP" | jq -s 'add')
      fi
    done
    dep=$(printf '%s' "$all" | pick)
    if [ -z "$dep" ]; then
      echo "no deployment of ${shas[*]} in '$ENVIRONMENT' yet"
    else
      id=$(jq -r .id <<< "$dep")
      dsha=$(jq -r .sha <<< "$dep")
      if api "repos/$REPO/deployments/$id/statuses?per_page=1"; then
        IFS=$'\t' read -r st url <<< "$(state <<< "$RESP")"
        echo "deployment $id of $dsha is $st"
        case "$st" in
          success)
            echo "::notice::deployment $id of $dsha is live${url:+ at $url}"
            {
              echo "deployment-id=$id"
              echo "sha=$dsha"
              echo "url=$url"
            } >> "$out"
            break ;;
          failure|error)
            echo "::error::the host reports deployment $id of $dsha as $st"
            exit 1 ;;
        esac
      fi
    fi
    [ "$SECONDS" -lt "$deadline" ] || timed_out "no successful deployment of ${shas[*]} in '$ENVIRONMENT'"
    sleep "$INTERVAL"
  done
fi

if [ -n "${SHA_URL:-}" ]; then
  deadline=$((SECONDS + ${TIMEOUT_MINUTES:-10} * 60))
  while :; do
    body=$(curl -fsS --max-time 15 "$SHA_URL" 2>/dev/null || true)
    for sha in "${shas[@]}"; do
      if [ -n "$body" ] && grep -qF "${sha:0:7}" <<< "$body"; then
        echo "::notice::$SHA_URL reports ${sha:0:7}"
        echo "sha=$sha" >> "$out"
        exit 0
      fi
    done
    echo "$SHA_URL does not report ${shas[*]} yet"
    [ "$SECONDS" -lt "$deadline" ] || timed_out "$SHA_URL never reported one of ${shas[*]}"
    sleep "$INTERVAL"
  done
fi
