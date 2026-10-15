#!/usr/bin/env bash
# Say which runner a job got, so a slow or odd job can be traced to a machine.
#
# NEVER FAILS THE JOB. Callers often hold `contents: read` only, and the jobs
# API needs `actions: read`, so a 403 is the normal case, not an error. The
# shared workflows add no permission for this report (AGENTS.md says why), so
# their jobs read "queued n/a (needs actions: read)" unless the job already
# holds `actions: read` for something else, as pr-review and claude-assist do.
# Every lookup that can go wrong degrades to "n/a (reason)" and the runner name,
# OS and architecture, which the runner hands every step, are always reported.
# This is a debugging aid; a report that turns a green build red is worse than
# none.
#
# One API call serves both modes, and job mode stops paging once it has found its
# job. The job is matched by runner name + in_progress: `runner.labels` is not a
# context, and the jobs API is the only place a job's labels and created_at are
# visible. curl, not gh: the base runner image ships curl and jq but not gh.
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

# Sets POOL: the first of these found in the job's labels, then in the runner's
# name; otherwise a self-hosted runner without one is `self-hosted`, else `hosted`.
# nocasematch (bash 3.2 has it) avoids a lowercasing subshell per call.
pool_of() { # $1 comma-separated labels, $2 runner name, $3 runner environment
  shopt -s nocasematch
  case ",$1,$2," in
    *hetzner*) POOL=hetzner ;;
    *beelink*) POOL=beelink ;;
    *rpi5*)    POOL=rpi5 ;;
    *m4pro*)   POOL=m4pro ;;
    *,self-hosted,*) POOL=self-hosted ;;
    *) if [ "${3:-}" = self-hosted ]; then POOL=self-hosted; else POOL=hosted; fi ;;
  esac
  shopt -u nocasematch
}

case "$MODE" in
  job|run) ;;
  *) echo "::warning title=Runner::runner-report: unknown mode '$MODE', using 'job'"; MODE=job ;;
esac

# Every job of the run attempt as one JSON array. Job mode ($1 = 1) stops at the
# page holding this runner's in-progress job, so the usual case is one request.
# The token goes to curl on stdin so it never shows in a process list.
fetch_jobs() {
  local path="/repos/$REPO/actions/runs/$RUN_ID/attempts/$RUN_ATTEMPT/jobs"
  local page=1 pages="" resp n hit
  while [ "$page" -le 10 ]; do
    resp="$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" \
      | curl -fsS -K - -H 'Accept: application/vnd.github+json' \
          "${GITHUB_API_URL:-https://api.github.com}$path?per_page=100&page=$page" 2>/dev/null)" || return 1
    pages="$pages$resp"$'\n'
    read -r n hit < <(jq -r --arg r "$NAME" \
      '"\(.jobs | length) \(any(.jobs[]; .runner_name == $r and .status == "in_progress"))"' \
      <<< "$resp") || return 1
    [ "$n" -lt 100 ] && break
    [ "${1:-}" = 1 ] && [ "$hit" = true ] && break
    page=$((page + 1))
  done
  jq -s '[.[].jobs[]]' <<< "$pages"
}

# One jq definition for a job's row, used by both modes: name, runner, labels,
# queued seconds, duration seconds (or "running"), result; unit-separated so an
# empty field survives `read`.
ROW='def secs(a; b): ((b | fromdateiso8601) - (a | fromdateiso8601)) | if . < 0 then 0 else . end;
  def row: [ (.name | gsub("\\|"; "\\|")), (.runner_name // ""), ((.labels // []) | join(",")),
    (if (.runner_name // "") != "" and .started_at and .created_at then secs(.created_at; .started_at) | tostring else "" end),
    (if .status == "completed" and .started_at and .completed_at then secs(.started_at; .completed_at) | tostring
     elif .status == "in_progress" then "running" else "" end),
    (.conclusion // .status // "") ] | join($us);'

note=""      # why the API-derived fields are missing, empty when they are not
jobs_json=""
jname=""; labels=""; queued=""
if [ -z "$TOKEN" ]; then
  note="no token"
elif ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  note="jq or curl missing"
elif [ -z "$REPO" ] || [ -z "$RUN_ID" ]; then
  note="no run context"
elif jobs_json="$(fetch_jobs "$([ "$MODE" = job ] && echo 1)")" && [ -n "$jobs_json" ]; then
  IFS="$US" read -r jname _ labels queued _ _ < <(jq -r --arg us "$US" --arg r "$NAME" \
    "$ROW"'[.[] | select(.runner_name == $r and .status == "in_progress")] | first // empty | row' \
    <<< "$jobs_json" 2>/dev/null)
  [ -z "$jname" ] && note="job not found"
else
  jobs_json=""
  note="needs actions: read"
fi

pool_of "$labels" "$NAME" "${RUNNER_ENVIRONMENT:-}"; pool="$POOL"
queued_short="${queued:+${queued}s}"
labels_txt="n/a (${note:-none})"
[ -n "$labels" ] && labels_txt="\`$(printf '%s' "$labels" | sed 's/,/`, `/g')\`"
image="${RUNNER_IMAGE_TAG:-n/a}"
[ -n "${RUNNER_IMAGE_TAG:-}" ] && [ -n "${RUNNER_IMAGE_REVISION:-}" ] && image="$image @ $RUNNER_IMAGE_REVISION"

job_table() {
  printf '### Runner\n\n| | |\n|---|---|\n'
  printf '| Runner | `%s` |\n' "$NAME"
  printf '| Pool | %s |\n' "$pool"
  printf '| Labels | %s |\n' "$labels_txt"
  printf '| OS / arch | %s / %s |\n' "$OS" "$ARCH"
  [ -n "${SELECTOR:-}" ] && printf '| Selector | `%s` |\n' "$SELECTOR"
  printf '| Image | %s |\n' "$image"
  printf '| Queued | %s |\n' "${queued_short:-n/a (${note:-no timestamps})}"
}

run_table() {
  printf '### Where it ran\n\n'
  if [ -z "$jobs_json" ]; then
    printf 'n/a (%s)\n' "${note:-no jobs}"
    return
  fi
  printf '| Job | Runner | Pool | Queued | Duration | Result |\n|---|---|---|---|---|---|\n'
  jq -r --arg us "$US" "$ROW"'.[] | row' <<< "$jobs_json" 2>/dev/null \
  | while IFS="$US" read -r jn rn lb q d res; do
      if [ -n "$rn" ]; then pool_of "$lb" "$rn" ""; p="$POOL"; rn="\`$rn\`"; else p="-"; rn="-"; fi
      [ -z "$q" ] && q="-" || q="${q}s"
      if [ -z "$d" ]; then d="-"; elif [ "$d" != running ]; then d="${d}s"; fi
      printf '| %s | %s | %s | %s | %s | %s |\n' "$jn" "$rn" "$p" "$q" "$d" "${res:--}"
    done
}

if [ "$MODE" = run ]; then md="$(run_table)"; else md="$(job_table)"; fi

printf '%s\n' "$md" >> "$SUMMARY" 2>/dev/null
# The notice is all most readers see, so it carries the reason as the summary does.
echo "::notice title=Runner::$NAME ($pool) queued ${queued_short:-n/a (${note:-no timestamps})}"

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
