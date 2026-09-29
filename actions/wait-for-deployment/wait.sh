#!/usr/bin/env bash
# Wait until the frontend host has deployed the commit this job checked out, so a
# health check after it tests that commit and not the deployment it replaces.
#
# A host builds the same push in parallel with the caller's deploy job, and moves
# its stable URL only when its own build ends. A check that runs right after
# `db push` therefore passes against whatever was already live.
#
# Two proofs, either or both. TIMEOUT_MINUTES covers the whole wait, not each one.
#   ENVIRONMENT  a successful GitHub Deployment of the commit in that environment.
#                Hosts post these as their build progresses.
#   SHA_URL      a URL whose body carries the commit's sha, for a host that posts
#                no Deployments.
#
# The commit is HEAD of the checkout. A release commit carries `[skip ci]`, which
# hosts honour, so what the host builds is the commit before it; that one counts
# too, which needs a checkout of two commits. Fails on timeout and on a failed
# deployment, never warns: a warning here is a green check that proved nothing.
#
# Reads its inputs from the environment and writes deployment-id and sha to
# $GITHUB_OUTPUT. action.yml is a thin wrapper.
set -euo pipefail

: "${REPO:?}"
: "${GITHUB_OUTPUT:?}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-10}"
INTERVAL="${INTERVAL:-15}"
deadline=$((SECONDS + TIMEOUT_MINUTES * 60))

shas=("$(git rev-parse HEAD)")
if git log -1 --format=%B HEAD | grep -qiE '\[(ci skip|skip [a-z ]+)\]'; then
  shas+=("$(git rev-parse HEAD^)")
fi
echo "commits that count as this deploy: ${shas[*]}"

# Calls the API into $RESP. Three failed calls in a row is a permission or a typo,
# not a slow host, and waiting out the timeout would hide it.
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

# Runs check function $2 until it succeeds; $1 says what was being waited for.
wait_until() {
  until "$2"; do
    [ "$SECONDS" -lt "$deadline" ] || {
      echo "::error::$1 within ${TIMEOUT_MINUTES} min; failing the deploy rather than checking a deployment that may not be this commit"
      exit 1
    }
    sleep "$INTERVAL"
  done
}

dep_id=
proved_sha=

deployment_is_live() {
  local all='[]' sha dep id dsha st
  for sha in "${shas[@]}"; do
    if api "repos/$REPO/deployments?sha=$sha&environment=$ENVIRONMENT&per_page=100"; then
      all=$(printf '%s\n%s' "$all" "$RESP" | jq -s 'add')
    fi
  done
  # The job this workflow runs in creates its own Deployment in the same
  # environment through the `github-actions` app, and it succeeds when the job
  # does. Counting it would pass every time.
  dep=$(jq -c 'map(select(.performed_via_github_app.slug != "github-actions"))
                | sort_by(.created_at) | last // empty' <<< "$all")
  if [ -z "$dep" ]; then
    echo "no deployment of ${shas[*]} in '$ENVIRONMENT' yet"
    return 1
  fi
  id=$(jq -r .id <<< "$dep")
  dsha=$(jq -r .sha <<< "$dep")
  api "repos/$REPO/deployments/$id/statuses?per_page=1" || return 1
  st=$(jq -r 'first // {} | .state // "none"' <<< "$RESP")
  echo "deployment $id of $dsha is $st"
  case "$st" in
    success) dep_id=$id; proved_sha=$dsha; return 0 ;;
    failure|error)
      echo "::error::the host reports deployment $id of $dsha as $st"
      exit 1 ;;
  esac
  return 1
}

route_reports_sha() {
  local body sha
  body=$(curl -fsS --max-time 15 "$SHA_URL" 2>/dev/null || true)
  for sha in "${shas[@]}"; do
    if [ -n "$body" ] && grep -qF "${sha:0:7}" <<< "$body"; then
      echo "$SHA_URL reports ${sha:0:7}"
      proved_sha=$sha
      return 0
    fi
  done
  echo "$SHA_URL does not report ${shas[*]} yet"
  return 1
}

[ -z "${ENVIRONMENT:-}" ] || wait_until "no successful deployment of ${shas[*]} in '$ENVIRONMENT'" deployment_is_live
[ -z "${SHA_URL:-}" ] || wait_until "$SHA_URL never reported one of ${shas[*]}" route_reports_sha

printf 'deployment-id=%s\nsha=%s\n' "$dep_id" "$proved_sha" >> "$GITHUB_OUTPUT"
