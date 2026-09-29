#!/usr/bin/env bash
# Decide whether deps-verify's agent has anything new to judge.
#
# Renovate re-pushes a branch for reasons that change nothing the agent reads: a
# rebase of the same update, lock file maintenance. Each push used to run the
# agent again, at about 8 minutes of large-pool time. The agent is skipped only
# when ALL of these hold, and the previous label and comment then stand:
#   - the build is green (a red build always goes to the agent),
#   - the PR carries `deps:verified`, or `deps:fixed` with its fix commits still
#     on the branch,
#   - the manifest diff hashes to what the last comment recorded.
# Lock file maintenance with a green build skips the agent too: there is no
# changelog to read, and the build result is the whole verdict.
#
# The hash covers dependency manifests and never lockfiles: the update is the
# version Renovate chose, not the tree it resolved to. It keeps only the changed
# lines (-U0, no hunk headers), so a rebase onto a moved base gives the same
# hash. An EMPTY manifest diff never matches, because a transitive bump with the
# same manifests would look unchanged when it is not.
#
# Reads its inputs from the environment; `run` writes intent/path/reason to
# $GITHUB_OUTPUT. `hash`, `previous` and `decide` are the parts test.sh runs.
set -euo pipefail

MARKER='<!-- dodi-sticky: deps-verify -->'

# Manifests only. Lockfiles and version resolution files are left out on purpose.
PATHSPECS=(
  ':(glob)**/package.json'
  ':(glob)**/*.gradle'
  ':(glob)**/*.gradle.kts'
  ':(glob)**/gradle/libs.versions.toml'
  ':(glob)**/Cargo.toml'
  ':(glob)**/pubspec.yaml'
  ':(glob)**/Package.swift'
  ':(glob)**/go.mod'
)

sha() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }

# Hash of the manifest diff against the base branch, or nothing when there is no
# diff or git could not produce one. Nothing sends the run to the agent.
#
# The checkout is a partial clone with no stored credentials, so the base side's
# blobs are fetched on demand. The token is given to git for this one command.
hash_diff() {
  local auth=() lines
  if [ -n "${GH_TOKEN:-}" ]; then
    auth=(-c "http.${GITHUB_SERVER_URL:-https://github.com}/.extraheader=AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')")
  fi
  lines=$(git ${auth[@]+"${auth[@]}"} diff --no-color --no-ext-diff -U0 "origin/$1...HEAD" -- "${PATHSPECS[@]}" \
            | grep -E '^[+-]' || true)
  [ -n "$lines" ] || return 0
  printf '%s\n' "$lines" | sha
}

# The intent hash the previous deps-verify comment recorded, from a comments
# payload on stdin (one JSON array per page). Bot-authored only, like the sticky
# lookup: a person quoting the comment back must not decide what is skipped.
previous_hash() {
  jq -rs --arg m "$MARKER" \
    '[.[][] | select(.user.type == "Bot") | select((.body // "") | contains($m))]
     | (first | .body) // ""' \
    | sed -n 's/.*<!-- deps-intent: \([0-9a-f]\{64\}\) -->.*/\1/p' | head -n 1
}

# Sets path (agent | unchanged | lockfile) and reason from VERDICT, UPDATE,
# LABELS (a JSON array), ROUNDS, INTENT and PREVIOUS.
decide() {
  has() { printf '%s' "$LABELS" | jq -e --arg l "$1" 'index($l) != null' >/dev/null; }
  if [ "$VERDICT" != green ]; then
    path=agent;     reason="the build is $VERDICT, so the agent reads the failure"
  elif [ "$UPDATE" = lockfile ] && [ -z "$INTENT" ]; then
    path=lockfile;  reason="lock file maintenance with a green build: nothing to read"
  elif [ -z "$INTENT" ]; then
    path=agent;     reason="no manifest diff to compare, so this update is judged again"
  elif [ "$INTENT" != "$PREVIOUS" ]; then
    path=agent;     reason="the manifest diff is new since the last verdict"
  elif has deps:verified; then
    path=unchanged; reason="same manifest diff as the verdict already on the PR (deps:verified)"
  elif has deps:fixed && [ "${ROUNDS:-0}" -gt 0 ]; then
    path=unchanged; reason="same manifest diff, and the fix commits are still on the branch (deps:fixed)"
  else
    path=agent;     reason="the PR carries no verified or fixed label to keep"
  fi
}

case "${1:-run}" in
  hash)     hash_diff "${2:?hash needs the base branch}"; exit 0 ;;
  previous) previous_hash; exit 0 ;;
  decide)   : "${VERDICT:?}" "${UPDATE:?}" "${LABELS:?}"; INTENT="${INTENT:-}" PREVIOUS="${PREVIOUS:-}"
            decide; printf 'path=%s\nreason=%s\n' "$path" "$reason"; exit 0 ;;
esac

: "${BASE_REF:?}" "${REPO:?}" "${NUMBER:?}" "${VERDICT:?}" "${UPDATE:?}" "${LABELS:?}"
INTENT="$(hash_diff "$BASE_REF" || true)"
PREVIOUS=""
# The comments are only worth reading when a match could skip the agent.
if [ "$VERDICT" = green ] && [ -n "$INTENT" ]; then
  PREVIOUS="$(gh api "/repos/$REPO/issues/$NUMBER/comments?per_page=100" --paginate | previous_hash || true)"
fi
decide

{
  echo "intent=$INTENT"
  echo "path=$path"
  echo "reason=$reason"
} >> "$GITHUB_OUTPUT"
echo "intent: ${INTENT:-none} (previous: ${PREVIOUS:-none})"
echo "path: $path, $reason"
