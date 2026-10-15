#!/usr/bin/env bash
# Say which runner a job got, so a slow or odd job can be traced to a machine.
#
# NEVER FAILS THE JOB. Callers often hold `contents: read` only, and the jobs
# API needs `actions: read`, so a 403 is the normal case, not an error. Every
# lookup that can go wrong degrades to "n/a (reason)" and the runner name, OS
# and architecture, which the runner hands every step, are always reported. This
# is a debugging aid; a report that turns a green build red is worse than none.
#
# One API call (the run attempt's jobs, paginated) serves both modes. The job is
# matched by runner name + in_progress: `runner.labels` is not a context, and the
# jobs API is the only place a job's labels and created_at are visible.
#
# Reads MODE, SELECTOR, GH_TOKEN, REPO, RUN_ID, RUN_ATTEMPT and the runner's own
# RUNNER_NAME / RUNNER_OS / RUNNER_ARCH / RUNNER_ENVIRONMENT, plus the optional
# RUNNER_IMAGE_TAG / RUNNER_IMAGE_REVISION baked into the self-hosted image.
# Writes the summary, a notice and the outputs. bash 3.2 (macOS): no mapfile, no
# associative arrays. test.sh covers every branch below.
# shellcheck disable=SC2016  # the backticks are markdown, not command substitution
set -uo pipefail

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
OUT="${GITHUB_OUTPUT:-/dev/null}"
MODE="${MODE:-job}"
TOKEN="${GH_TOKEN:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
RUN_ID="${RUN_ID:-${GITHUB_RUN_ID:-}}"
RUN_ATTEMPT="${RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-1}}"
NAME="${RUNNER_NAME:-unknown}"
OS="${RUNNER_OS:-unknown}"
ARCH="${RUNNER_ARCH:-unknown}"
US=$'\x1f'

# The pool is the first of these found in the job's labels, then in the runner's
# name; otherwise a self-hosted runner without one is `self-hosted`, else `hosted`.
pool_of() { # $1 comma-separated labels, $2 runner name, $3 runner environment
  local hay
  hay="$(printf ',%s,%s,' "$1" "$2" | tr '[:upper:]' '[:lower:]')"
  case "$hay" in
    *hetzner*) echo hetzner ;;
    *beelink*) echo beelink ;;
    *rpi5*)    echo rpi5 ;;
    *m4pro*)   echo m4pro ;;
    *,self-hosted,*) echo self-hosted ;;
    *) if [ "${3:-}" = self-hosted ]; then echo self-hosted; else echo hosted; fi ;;
  esac
}

# Print every job of the run attempt as one JSON array. Non-zero on any failure.
fetch_jobs() {
  local path="/repos/$REPO/actions/runs/$RUN_ID/attempts/$RUN_ATTEMPT/jobs"
  if command -v gh >/dev/null 2>&1; then
    GH_TOKEN="$TOKEN" gh api --paginate "$path?per_page=100" 2>/dev/null \
      | jq -s '[.[].jobs[]]'
    return
  fi
  # No gh (a bare self-hosted image): the same listing through curl. The token
  # goes in on stdin so it never shows in a process list.
  local page=1 acc='[]' resp n
  while [ "$page" -le 10 ]; do
    resp="$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" \
      | curl -fsS -K - -H 'Accept: application/vnd.github+json' \
          "${GITHUB_API_URL:-https://api.github.com}$path?per_page=100&page=$page" 2>/dev/null)" || return 1
    acc="$(jq -c --argjson a "$acc" '$a + .jobs' <<< "$resp")" || return 1
    n="$(jq '.jobs | length' <<< "$resp")" || return 1
    [ "$n" -lt 100 ] && break
    page=$((page + 1))
  done
  printf '%s' "$acc"
}

note=""      # why the API-derived fields are missing, empty when they are not
jobs_json=""
job=""
if [ -z "$TOKEN" ]; then
  note="no token"
elif ! command -v jq >/dev/null 2>&1; then
  note="jq missing"
elif [ -z "$REPO" ] || [ -z "$RUN_ID" ]; then
  note="no run context"
elif jobs_json="$(fetch_jobs)" && [ -n "$jobs_json" ]; then
  job="$(jq -c --arg r "$NAME" \
    '[.[] | select(.runner_name == $r and .status == "in_progress")] | first // empty' \
    <<< "$jobs_json" 2>/dev/null)"
  [ -z "$job" ] && note="job not found"
else
  jobs_json=""
  note="needs actions: read"
fi

labels=""; queued=""
if [ -n "$job" ]; then
  labels="$(jq -r '(.labels // []) | join(",")' <<< "$job" 2>/dev/null)"
  queued="$(jq -r 'if .started_at and .created_at
      then ((.started_at | fromdateiso8601) - (.created_at | fromdateiso8601)) | if . < 0 then 0 else . end
      else empty end' <<< "$job" 2>/dev/null)"
fi

pool="$(pool_of "$labels" "$NAME" "${RUNNER_ENVIRONMENT:-}")"
if [ -n "$queued" ]; then queued_txt="${queued}s"; else queued_txt="n/a (${note:-no timestamps})"; fi
if [ -n "$labels" ]; then
  labels_txt="$(printf '%s' "$labels" | sed 's/,/`, `/g; s/^/`/; s/$/`/')"
else
  labels_txt="n/a (${note:-none})"
fi
image="${RUNNER_IMAGE_TAG:-}"
if [ -n "$image" ]; then
  [ -n "${RUNNER_IMAGE_REVISION:-}" ] && image="$image @ ${RUNNER_IMAGE_REVISION}"
else
  image="n/a"
fi

job_table() {
  printf '### Runner\n\n| | |\n|---|---|\n'
  printf '| Runner | `%s` |\n' "$NAME"
  printf '| Pool | %s |\n' "$pool"
  printf '| Labels | %s |\n' "$labels_txt"
  printf '| OS / arch | %s / %s |\n' "$OS" "$ARCH"
  [ -n "${SELECTOR:-}" ] && printf '| Selector | `%s` |\n' "$SELECTOR"
  printf '| Image | %s |\n' "$image"
  printf '| Queued | %s |\n' "$queued_txt"
}

run_table() {
  printf '### Where it ran\n\n'
  if [ -z "$jobs_json" ]; then
    printf 'n/a (%s)\n' "${note:-no jobs}"
    return
  fi
  printf '| Job | Runner | Pool | Queued | Duration | Result |\n|---|---|---|---|---|---|\n'
  jq -r --arg us "$US" '.[] | [
      (.name | gsub("\\|"; "\\|")),
      (.runner_name // ""),
      ((.labels // []) | join(",")),
      (if (.runner_name // "") != "" and .started_at and .created_at
         then (((.started_at | fromdateiso8601) - (.created_at | fromdateiso8601)) | if . < 0 then 0 else . end | tostring)
         else "" end),
      (if .status == "completed" and .started_at and .completed_at
         then (((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601)) | if . < 0 then 0 else . end | tostring)
         elif .status == "in_progress" then "running" else "" end),
      (.conclusion // .status // "")
    ] | join($us)' <<< "$jobs_json" 2>/dev/null \
  | while IFS="$US" read -r jn rn lb q d res; do
      p="-"; [ -n "$rn" ] && p="$(pool_of "$lb" "$rn" "")"
      [ -z "$rn" ] && rn="-" || rn="\`$rn\`"
      [ -z "$q" ] && q="-" || q="${q}s"
      if [ -z "$d" ]; then d="-"; elif [ "$d" != running ]; then d="${d}s"; fi
      [ -z "$res" ] && res="-"
      printf '| %s | %s | %s | %s | %s | %s |\n' "$jn" "$rn" "$p" "$q" "$d" "$res"
    done
}

case "$MODE" in
  run) md="$(run_table)" ;;
  job) md="$(job_table)" ;;
  *)   echo "::warning title=Runner::runner-report: unknown mode '$MODE', using 'job'"
       md="$(job_table)" ;;
esac

printf '%s\n' "$md" >> "$SUMMARY" 2>/dev/null

if [ -n "$queued" ]; then
  echo "::notice title=Runner::$NAME ($pool) queued ${queued}s"
else
  echo "::notice title=Runner::$NAME ($pool) queued n/a"
fi

{
  echo "runner=$NAME"
  echo "pool=$pool"
  echo "queued-seconds=$queued"
  d="RUNNER_REPORT_EOF_$RANDOM$RANDOM"
  echo "markdown<<$d"
  printf '%s\n' "$md"
  echo "$d"
} >> "$OUT" 2>/dev/null

exit 0
