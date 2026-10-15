#!/usr/bin/env bash
# The picker's decision, as a standalone script so `test.sh` can assert the
# policy table without a runner or a token.
#
#   pick.sh resolve   guard + weight -> selector. Writes selector, hosted.
#   pick.sh decide    selector + fleet listing -> runner. Writes runner, fell-back.
#
# `resolve` runs first so action.yml knows whether a fleet listing is needed at
# all. `decide` then works from ONE listing file (a JSON array of
# {name, labels: [string], status, busy}) and never calls the API itself.
# A missing listing file means the fleet could not be read.
set -euo pipefail

: "${GITHUB_OUTPUT:=/dev/stdout}"

WEIGHT="${WEIGHT:-light}"
LABELS="${LABELS:-}"
FALLBACK="${FALLBACK:-}"
FALLBACK_WHEN="${FALLBACK_WHEN:-}"
HOSTED_RUNNER="${HOSTED_RUNNER:-ubuntu-latest}"

# A comma-separated selector as the JSON array `runs-on` reads through fromJson().
runner_json() {
  jq -cn --arg s "$1" '$s | split(",") | map(gsub("^\\s+|\\s+$"; "")) | tojson' -r
}

# pool_counts <selector> <fleet file>: the runners that carry every label in
# the selector, as tab-separated total, online, idle, and the selector's labels
# that no runner carries at all (space-separated, empty when none).
pool_counts() {
  jq -r --arg s "$1" '
    ($s | split(",") | map(gsub("^\\s+|\\s+$"; ""))) as $want
    | . as $all
    | [ .[] | select(. as $r | all($want[]; . as $l | ($r.labels | index($l)) != null)) ] as $m
    | [ ($m | length),
        ($m | map(select(.status == "online")) | length),
        ($m | map(select(.status == "online" and .busy != true)) | length),
        ([ $want[] | select(. as $l | any($all[]; .labels | index($l)) | not) ] | join(" ")) ]
    | @tsv' "$2"
}

# The decision's two outputs: a comma-separated selector, and whether it is a fall back.
emit() { { echo "runner=$(runner_json "$1")"; echo "fell-back=$2"; } >> "$GITHUB_OUTPUT"; }

resolve() {
  case "$FALLBACK_WHEN" in
    ""|busy|offline) ;;
    *) echo "::error::unknown fallback-when '$FALLBACK_WHEN' (expected busy|offline, or leave it empty)"; exit 1 ;;
  esac

  # Public repos and fork PRs never touch self-hosted, with no opt-out.
  # The runner group refuses public repos, and a fork PR would otherwise
  # run attacker-authored code on our hardware against a cache the next
  # job inherits. This path resolves through `hosted-runner` and never
  # reads `fallback`.
  if [ "${GUARD:-true}" = "true" ] && { [ "${PRIVATE:-}" != "true" ] || [ "${FORK:-}" = "true" ]; }; then
    echo "public repo or fork PR, hosted only"
    { echo "selector="; echo "hosted=true"; } >> "$GITHUB_OUTPUT"
    return
  fi

  local sel
  if [ -n "$LABELS" ]; then
    sel="$LABELS"
  else
    case "$WEIGHT" in
      light)  sel="self-hosted,Linux,light" ;;
      heavy)  sel="self-hosted,Linux,large" ;;
      apple)  sel="self-hosted,macOS,ARM64" ;;
      hosted) sel="" ;;
      *)
        echo "::error::unknown weight '$WEIGHT' (expected light|heavy|apple|hosted, or set the labels input)"
        exit 1 ;;
    esac
  fi

  if [ -z "$sel" ]; then
    { echo "selector="; echo "hosted=true"; } >> "$GITHUB_OUTPUT"
  else
    { echo "selector=$sel"; echo "hosted=false"; } >> "$GITHUB_OUTPUT"
    echo "resolved selector: $sel"
  fi
}

decide() {
  local sel="${SELECTOR:-}" fleet="${FLEET_FILE:-}"

  if [ "${HOSTED_ONLY:-false}" = "true" ]; then
    emit "$HOSTED_RUNNER" false
    return
  fi

  # What a weight falls back to, and when. An explicit input always wins.
  #   light   the large pool, when no light runner is idle. Short jobs would
  #           rather run now than wait, and a light job fits on a large runner
  #           (the reverse does not). Without it every light job queued on the
  #           few light runners while the large pool sat idle.
  #   heavy   hosted, and only when no runner is online at all. Never the light
  #           pool: a heavy job there runs out of memory (exit 137). A busy
  #           large pool queues instead, because a long build costs more on
  #           hosted than in the queue.
  #   apple   nothing. The light pool cannot run Xcode, and hosted macOS is not
  #           ours to bill by surprise, so it queues on the apple pool.
  #   labels  a selector no preset describes keeps the original behaviour.
  local fb_def="self-hosted,Linux,light" when_def="busy"
  if [ -z "$LABELS" ]; then
    case "$WEIGHT" in
      light) fb_def="self-hosted,Linux,large" ;;
      heavy) fb_def="$HOSTED_RUNNER"; when_def="offline" ;;
      apple) fb_def="";               when_def="offline" ;;
    esac
  fi
  local fb="${FALLBACK:-$fb_def}" when="${FALLBACK_WHEN:-$when_def}"

  # An empty list is as unreadable as an error: a token that cannot see the
  # org returns nothing, and a registered runner that went offline still lists.
  if [ -s "$fleet" ] && [ "$(jq 'length' "$fleet")" = "0" ]; then
    FLEET_ERR="the list came back empty"
  fi
  if [ ! -s "$fleet" ] || [ -n "${FLEET_ERR:-}" ]; then
    # Without a listing there is no telling a busy pool from an offline one, so
    # queue on the primary selector instead of guessing. The old behaviour sent
    # every unreadable-fleet job to the fallback, and for `heavy` that meant
    # the light pool, where it ran out of memory.
    if [ -n "${FLEET_ERR:-}" ]; then
      echo "::warning title=Runner selector was NOT validated::Could not read the org runner list ($FLEET_ERR), so '$sel' was NOT checked against the live fleet and the job queues on it. This says nothing about whether the labels exist. Usually the GitHub App token is missing or lacks org scope. See GH_APP_CLIENT_ID."
    fi
    emit "$sel" false
    return
  fi

  local total online idle missing
  IFS=$'\t' read -r total online idle missing < <(pool_counts "$sel" "$fleet")

  local dest="the fallback '$fb'"
  [ -n "$fb" ] || dest="a queue with no fallback"

  if [ -n "$missing" ]; then
    local all
    all=$(jq -r '[.[].labels[]] | unique | join(" ")' "$fleet")
    echo "::warning title=Runner selector matches nothing::'$sel' asks for label(s): $missing, which no runner carries. This job goes to $dest. Fleet labels: $all"
  elif [ "$total" = "0" ]; then
    echo "::warning title=Runner selector matches nothing::Every label in '$sel' exists, but no single runner carries them together. This job goes to $dest."
  else
    echo "selector '$sel' matches $total runner(s): $online online, $idle idle"
    if [ "$online" = "0" ]; then
      echo "::warning title=Runner pool offline::All $total runner(s) matching '$sel' are offline. This job goes to $dest."
    fi
  fi

  # A busy pool overflows to a self-hosted fallback only when that pool has an
  # idle runner. Otherwise the job would queue there instead of here, behind
  # that pool's own jobs, and never come back when this pool frees up. An
  # offline pool goes regardless: there is nothing to wait for here.
  local fb_free=1
  if [ -n "$fb" ] && [ "$online" != "0" ] && [[ "$fb" == self-hosted* ]]; then
    fb_free=$(pool_counts "$fb" "$fleet" | cut -f3)
    [ "$fb_free" != "0" ] || echo "no idle runner in '$fb' either, so this job stays on '$sel'"
  fi

  # Fall back when the pool is offline, or busy and the policy says so. Skip it
  # when there is nowhere else to go: no fallback set, it is the selector
  # already, or (when busy) it has no idle runner. Then queue on the primary,
  # no fall back reported.
  if [ -n "$fb" ] && [ "$fb" != "$sel" ] \
     && { [ "$online" = "0" ] || { [ "$when" = "busy" ] && [ "$idle" = "0" ] && [ "$fb_free" != "0" ]; }; }; then
    echo "falling back to '$fb' ($online online, $idle idle, fallback-when: $when)"
    emit "$fb" true
  else
    emit "$sel" false
  fi
}

case "${1:-}" in
  resolve) resolve ;;
  decide)  decide ;;
  *) echo "usage: pick.sh resolve|decide" >&2; exit 2 ;;
esac
