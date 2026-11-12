#!/usr/bin/env bash
# The independent judge's verdict (dodi-smart/dev-standards DODI-00065). Grok Bot,
# acting as the review-only App `dodi-judge`, reviews a PR's head and writes one
# fenced `dodi-judge-verdict` JSON block in the review body. This script decides
# whether to trust that review and what `judge / verdict` says. The judge never
# posts the status: it has no statuses permission, and only the org App does.
#
#   decide  pure: reads REVIEW_FILE (the event's `review` object), HEAD_SHA and
#           JUDGE_LOGIN, and prints accept/state/description/reason lines.
#           test.sh runs it on fixed inputs.
#   expired pure: reads a status's updated_at as UPDATED, NOW and TIMEOUT_MINUTES,
#           and prints true when a pending request has waited too long.
#   run     the API part, for one event (MODE pending or verdict) or the sweep
#           (MODE timeout). Needs GH_TOKEN, REPO, and per mode PR/HEAD_SHA.
#
# Every untrusted byte here is the review body. It is only ever read by awk and
# jq, never evaluated, and nothing from it reaches a shell word.
set -euo pipefail

CONTEXT='judge / verdict'
LABEL='agent:judge'
FENCE='dodi-judge-verdict'

out() { printf '%s=%s\n' "$1" "$2"; }
# A commit status description holds at most 140 characters.
clip() { local s="$1"; [ "${#s}" -le 140 ] && printf '%s' "$s" || printf '%s...' "${s:0:137}"; }

decide() {
  local login type commit body blocks raw verdict sha nblock passed total scen
  login=$(jq -r '.user.login // ""' "$REVIEW_FILE")
  type=$(jq -r '.user.type // ""' "$REVIEW_FILE")
  commit=$(jq -r '.commit_id // ""' "$REVIEW_FILE")

  # Identity first: the exact login and an App account. A person or another bot
  # is not the judge, whatever the body says.
  if [ "$login" != "$JUDGE_LOGIN" ] || [ "$type" != Bot ]; then
    out accept false; out reason "not the judge: $login ($type)"; return
  fi
  # A review of an older commit says nothing about the head; the request stays
  # pending until the judge reviews the head.
  if [ "$commit" != "$HEAD_SHA" ]; then
    out accept false; out reason "review is of ${commit:0:7}, the head is ${HEAD_SHA:0:7}"; return
  fi

  out accept true
  body=$(jq -r '.body // ""' "$REVIEW_FILE")
  # Count opening fences, then take the first block's lines.
  blocks=$(printf '%s\n' "$body" | awk -v f="$FENCE" '$0 ~ "^[ \t]*```[ \t]*" f "[ \t]*$" {n++} END {print n+0}')
  if [ "$blocks" != 1 ]; then
    out state failure; out description "$(clip "Malformed verdict: expected one $FENCE block, found $blocks")"; return
  fi
  raw=$(printf '%s\n' "$body" | awk -v f="$FENCE" '
    !inb && $0 ~ "^[ \t]*```[ \t]*" f "[ \t]*$" {inb=1; next}
    inb && $0 ~ "^[ \t]*```[ \t]*$" {exit}
    inb {print}')
  if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    out state failure; out description "Malformed verdict: the block is not a JSON object"; return
  fi

  verdict=$(printf '%s' "$raw" | jq -r '.verdict // "" | tostring')
  sha=$(printf '%s' "$raw" | jq -r '.sha // "" | tostring')
  if [ "$verdict" != approve ] && [ "$verdict" != changes ]; then
    out state failure; out description "$(clip "Malformed verdict: unknown verdict '${verdict:0:20}'")"; return
  fi
  if [ "$sha" != "$HEAD_SHA" ]; then
    out state failure; out description "$(clip "Malformed verdict: it names ${sha:0:7}, not the head ${HEAD_SHA:0:7}")"; return
  fi
  if ! nblock=$(printf '%s' "$raw" | jq -e '(.blocking // []) | if type == "array" then length else error end' 2>/dev/null); then
    out state failure; out description "Malformed verdict: blocking is not a list"; return
  fi
  # Scenarios are optional (a product may have none yet), but when present they
  # must be two whole numbers with passed <= total.
  if printf '%s' "$raw" | jq -e 'has("scenarios")' >/dev/null; then
    if ! scen=$(printf '%s' "$raw" | jq -re '.scenarios
        | select(type == "object")
        | select((.passed | type) == "number" and (.total | type) == "number")
        | select(.passed == (.passed | floor) and .total == (.total | floor))
        | select(.passed >= 0 and .total >= .passed)
        | "\(.passed) \(.total)"' 2>/dev/null); then
      out state failure; out description "Malformed verdict: scenarios must be {passed, total} with passed <= total"; return
    fi
    read -r passed total <<<"$scen"
    scen="$passed/$total scenarios"
  else
    passed=0; total=0; scen="no scenarios run"
  fi

  if [ "$verdict" = approve ] && [ "$nblock" -gt 0 ]; then
    out state failure; out description "$(clip "Approve with $nblock blocking finding(s) counts as changes; $scen")"; return
  fi
  if [ "$verdict" = approve ] && [ "$passed" -lt "$total" ]; then
    out state failure; out description "$(clip "Approve with $passed/$total scenarios passed counts as changes")"; return
  fi
  if [ "$verdict" = approve ]; then
    out state success; out description "$(clip "Approved by the independent judge; $scen")"
  else
    out state failure; out description "$(clip "Changes requested: $nblock blocking; $scen")"
  fi
}

# NOW and UPDATED are ISO 8601 UTC. date differs between GNU and BSD, so jq does it.
expired() {
  jq -nr --arg u "$UPDATED" --arg n "$NOW" --argjson t "$TIMEOUT_MINUTES" \
    '(($n | fromdateiso8601) - ($u | fromdateiso8601)) >= ($t * 60)'
}

post() { # sha state description [target]
  local args=(-f "state=$2" -f "context=$CONTEXT" -f "description=$3")
  [ -n "${4:-}" ] && args+=(-f "target_url=$4")
  gh api "/repos/$REPO/statuses/$1" "${args[@]}" >/dev/null
}
unlabel() { gh api -X DELETE "/repos/$REPO/issues/$1/labels/$LABEL" >/dev/null 2>&1 || true; }

run() {
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "::warning title=No judge status::GH_APP_CLIENT_ID is not set; judge / verdict is posted with the org App token only."
    exit 0
  fi
  case "$MODE" in
    pending)
      post "$HEAD_SHA" pending "Waiting for the independent judge ($JUDGE_LOGIN)"
      echo "judge requested on #$PR at $HEAD_SHA" ;;
    verdict)
      local d accept state description reason
      d=$(decide)
      accept=$(sed -n 's/^accept=//p' <<<"$d")
      if [ "$accept" != true ]; then
        reason=$(sed -n 's/^reason=//p' <<<"$d")
        echo "ignored: $reason"; exit 0
      fi
      state=$(sed -n 's/^state=//p' <<<"$d")
      description=$(sed -n 's/^description=//p' <<<"$d")
      post "$HEAD_SHA" "$state" "$description" "$(jq -r '.html_url // ""' "$REVIEW_FILE")"
      unlabel "$PR"
      echo "judge / verdict on $HEAD_SHA: $state ($description)" ;;
    timeout)
      local n sha st upd
      NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      # Open PRs carrying the request; the issues endpoint filters by label.
      for n in $(gh api --paginate "/repos/$REPO/issues?state=open&labels=$LABEL&per_page=100" \
                   --jq '.[] | select(.pull_request) | .number'); do
        sha=$(gh api "/repos/$REPO/pulls/$n" --jq .head.sha)
        read -r st upd < <(gh api "/repos/$REPO/commits/$sha/status" \
          --jq "[.statuses[] | select(.context == \"$CONTEXT\")][0] | \"\(.state // \"none\") \(.updated_at // \"\")\"")
        if [ "$st" = none ]; then
          post "$sha" pending "Waiting for the independent judge ($JUDGE_LOGIN)"; echo "#$n: pending set"; continue
        fi
        [ "$st" = pending ] || { unlabel "$n"; echo "#$n: already $st, request cleared"; continue; }
        if [ "$(UPDATED="$upd" expired)" = true ]; then
          post "$sha" error "No verdict from the independent judge within $TIMEOUT_MINUTES minutes"
          unlabel "$n"; echo "#$n: timed out"
        fi
      done ;;
    *) echo "unknown MODE '$MODE'" >&2; exit 2 ;;
  esac
}

case "${1:-}" in
  decide) decide ;;
  expired) expired ;;
  run) run ;;
  *) echo "usage: verdict.sh decide|expired|run" >&2; exit 2 ;;
esac
