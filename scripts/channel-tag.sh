#!/usr/bin/env bash
# Release channels for this repo's tags.
#
#   channel-tag.sh pin     [--version X.Y.Z] [--remote R] [--no-push] [--force]
#   channel-tag.sh promote [--version X.Y.Z] [--auto] [--min-age-hours N]
#                          [--canary-gate PATH] [--remote R] [--no-push]
#
# `pin` runs after semantic-release has cut vX.Y.Z on main. It builds a child
# commit of that tag, which is NOT on main, where every internal reference to
# this repo's own actions and reusable workflows is rewritten from the floating
# major (`@v1`) to `@pinned/vX.Y.Z`: the tag of that same child commit. A caller
# on `@next` then runs the workflows AND every action they call, at any depth,
# from that one commit. Pinning to `@vX.Y.Z` instead would not hold: that tag is
# the release commit, whose own internal references still float on `@v1`, so an
# action called by a pinned action (or a pinned reusable workflow's own steps)
# would run whatever `v1` is, and fail outright when `v1` predates it.
#
# `promote` force-moves `v<major>` onto the pinned commit of a version. With no
# --version it promotes whatever `next` points at. Promoting an older version is
# the rollback. A version cut before channels existed has no pinned commit, so
# its own tag is used: its internal references say `@v1`, which is exactly the
# tag being moved onto it.
#
# With --canary-gate PATH, `promote` asks that script about the target commit
# right before it moves the tag, as `PATH auto <sha>` for --auto and `PATH
# manual <sha>` otherwise (scripts/canary-gate.sh). An automatic promotion the
# script refuses moves nothing and reports promoted=false; a manual one always
# goes ahead, and the script's own warning says what the canary said.
#
# Both are idempotent: running one twice leaves the same tags in the same place.
# Progress goes to stderr; stdout carries key=value lines a workflow can append
# to its step summary or output. With CHANNEL_TOKEN set the pushes go to
# github.com/$GITHUB_REPOSITORY with that token, which is how a workflow pushes
# workflow files (GITHUB_TOKEN may not); --remote overrides it.
set -euo pipefail

usage() { sed -n '2,/^set -e/p' "$0" | sed '$d;s/^# \{0,1\}//' >&2; exit 2; }
die() { echo "channel-tag: $*" >&2; exit 1; }
note() { echo "channel-tag: $*" >&2; }

cmd="${1:-}"; [ -n "$cmd" ] || usage
shift
version="" remote=origin push=1 force=0 auto=0 min_age=24 canary_gate=""
# actions/checkout persists GITHUB_TOKEN as an http extraheader, and git sends
# that header in place of the token in the URL. Pushing workflow files with it
# is refused, so the token remote clears the header for this script's own
# fetches and pushes. An empty value resets the list.
remote_opts=()
if [ -n "${CHANNEL_TOKEN:-}" ]; then
  remote="https://x-access-token:${CHANNEL_TOKEN}@github.com/${GITHUB_REPOSITORY:?CHANNEL_TOKEN needs GITHUB_REPOSITORY}.git"
  remote_opts=(-c "http.https://github.com/.extraheader=")
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="${2:?--version needs a value}"; shift 2 ;;
    --remote) remote="${2:?--remote needs a value}"; shift 2 ;;
    --no-push) push=0; shift ;;
    --force) force=1; shift ;;
    --auto) auto=1; shift ;;
    --min-age-hours) min_age="${2:?--min-age-hours needs a value}"; shift 2 ;;
    --canary-gate) canary_gate="${2:?--canary-gate needs a value}"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
version="${version#v}"
if [ -n "$version" ] && ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "version must look like 1.2.3, got: $version"
fi

# Wait for nothing and prompt for nothing: a CI run has no one to answer.
export GIT_TERMINAL_PROMPT=0

version_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }

tag_commit() { git rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null || true; }

# The version a pinned commit was cut for, read from the tag that names it.
version_at() {
  local t
  t="$(git tag --points-at "$1" --list 'pinned/v*' | sed -n 1p)"
  [ -n "$t" ] && echo "${t#pinned/v}"
  return 0
}

push_tag() { # push_tag <tag> [--force]
  [ "$push" = 1 ] || return 0
  local err rc=0
  err="$(git ${remote_opts[@]+"${remote_opts[@]}"} push ${2:+"$2"} "$remote" "refs/tags/$1:refs/tags/$1" 2>&1 >/dev/null)" || rc=$?
  [ -z "$err" ] || printf '%s\n' "$err" >&2
  [ "$rc" = 0 ] || explain_refusal "$1" "$err"
  return "$rc"
}

# Puts GitHub's own refusal on stdout, which the workflows add to the step
# summary, so a red run explains itself without its log. The hint after it
# covers the two refusals these workflows have actually met.
explain_refusal() { # explain_refusal <tag> <push stderr>
  echo "push: GitHub refused $1, so it did not move:"
  sed -nE '/^(remote|fatal|error):|\[remote rejected\]/{s/[[:space:]]*$//; s/^/push:   /; p;}' <<<"$2"
  case "$2" in
    *"denied to github-actions[bot]"*)
      echo "push: that is GITHUB_TOKEN, which may not push workflow-file changes. Set GH_APP_CLIENT_ID and GH_APP_PRIVATE_KEY so the App pushes instead." ;;
    *"Permission to "*" denied to "*|*"workflows"*" permission"*)
      echo "push: check that the App installation still has contents: write and workflows: write, then re-run the job for a fresh token. If a fresh token is refused too, an org owner re-saves the installation's permissions." ;;
  esac
}

move_tag() { # move_tag <tag> <commit>
  git tag -f "$1" "$2" >/dev/null
  push_tag "$1" --force
}

# Tags may exist on the remote only (a fresh checkout, a rerun elsewhere).
fetch_tags() {
  [ "$push" = 1 ] || return 0
  git ${remote_opts[@]+"${remote_opts[@]}"} fetch --quiet --force --tags "$remote" 2>/dev/null || note "could not fetch tags from the remote; using the local ones"
}

# Rewrites one file's content on stdin to `@pinned/v<version>`. Only a `uses:`
# line is touched, and only when it names this repo's own actions or reusable
# workflows at a bare major.
# `actions/checkout@v7`, `@v1.2.3` and a comment that merely mentions a ref stay
# as they are.
rewrite() {
  PIN="pinned/v$1" perl -pe '
    s{^(\s*(?:-\s+)?uses:\s*["\x27]?dodi-smart/\.github/(?:actions/[\w./-]+|\.github/workflows/[\w.-]+\.ya?ml))\@v\d+(?![\w.-])}{$1\@$ENV{PIN}}
  '
}

pin() {
  fetch_tags
  local tag commit pinned pinned_tag current cur_ver
  if [ -z "$version" ]; then
    tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)"
    [ -n "$tag" ] || die "no release tag is reachable from HEAD"
    version="${tag#v}"
  fi
  tag="v$version"
  commit="$(tag_commit "$tag")"
  [ -n "$commit" ] || die "tag $tag does not exist"
  pinned_tag="pinned/$tag"

  pinned="$(tag_commit "$pinned_tag")"
  if [ -n "$pinned" ]; then
    [ "$(git rev-parse "$pinned^")" = "$commit" ] || die "$pinned_tag exists but is not a child of $tag"
    note "$pinned_tag already exists ($pinned)"
  else
    local idx mode path old new changed=0 tree
    idx="$(mktemp -d "${TMPDIR:-/tmp}/channel-tag.XXXXXX")"
    export GIT_INDEX_FILE="$idx/index"
    git read-tree "$commit"
    while IFS=$' \t' read -r mode _ old path; do
      [[ "$path" =~ ^(\.github/workflows/[^/]+\.ya?ml|actions/.+/action\.ya?ml)$ ]] || continue
      new="$(git cat-file blob "$old" | rewrite "$version" | git hash-object -w --stdin)"
      [ "$new" != "$old" ] || continue
      git update-index --cacheinfo "$mode,$new,$path"
      changed=$((changed + 1))
    done < <(git ls-tree -r "$commit" -- .github/workflows actions)
    tree="$(git write-tree)"
    unset GIT_INDEX_FILE
    rm -rf "$idx"
    pinned="$(
      GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-github-actions[bot]}" \
      GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}" \
      GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-github-actions[bot]}" \
      GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}" \
      git commit-tree "$tree" -p "$commit" -m "chore(release): pin internal references to $tag [skip ci]" \
        -m "A channel commit, not on main. Internal references to this repo's own actions and reusable workflows are pinned to $pinned_tag, this commit's own tag, so a caller on @next runs one commit end to end at every depth. Built by scripts/channel-tag.sh."
    )"
    git tag "$pinned_tag" "$pinned"
    note "created $pinned_tag ($pinned), $changed file(s) rewritten"
  fi
  push_tag "$pinned_tag"

  # `next` never goes backwards on its own: a rerun of an older release must not
  # undo a newer one. --force is the deliberate way back.
  current="$(tag_commit next)"
  if [ -n "$current" ] && [ "$current" != "$pinned" ] && [ "$force" = 0 ]; then
    cur_ver="$(version_at "$current")"
    if [ -n "$cur_ver" ] && version_gt "$cur_ver" "$version"; then
      note "next already points at $cur_ver, which is newer than $version; leaving it (use --force to override)"
      echo "moved=false"
      return 0
    fi
  fi
  move_tag next "$pinned"
  note "next -> $pinned_tag"
  echo "moved=true"
  echo "version=$version"
  echo "pinned=$pinned"
}

promote() {
  fetch_tags
  local nextc target major target_tag cur curc age now gate_mode gate_out
  if [ -z "$version" ]; then
    nextc="$(tag_commit next)"
    [ -n "$nextc" ] || die "no version given and there is no next tag"
    version="$(version_at "$nextc")"
    [ -n "$version" ] || die "next does not point at a pinned release commit"
  fi
  if [ -n "$(tag_commit "pinned/v$version")" ]; then target_tag="pinned/v$version"
  elif [ -n "$(tag_commit "v$version")" ]; then target_tag="v$version"
  else die "neither pinned/v$version nor v$version exists"; fi
  target="$(tag_commit "$target_tag")"
  major="v${version%%.*}"
  curc="$(tag_commit "$major")"

  if [ "$auto" = 1 ]; then
    if [ "$curc" = "$target" ]; then note "$major is already at $version"; echo "promoted=false"; return 0; fi
    cur="$(version_at "$curc")"
    [ -n "$cur" ] || cur="$(git tag --points-at "$curc" --list 'v[0-9]*' | sed 's/^v//' | sort -V | tail -n1)"
    if [ -n "$cur" ] && ! version_gt "$version" "$cur"; then
      note "automatic promotion never goes backwards ($major is at $cur, next is $version)"; echo "promoted=false"; return 0
    fi
    now="$(date +%s)"
    age=$(( (now - $(git log -1 --format=%ct "$target")) / 3600 ))
    if [ "$age" -lt "$min_age" ]; then
      note "$version has been on next for ${age}h; waiting for ${min_age}h"; echo "promoted=false"; return 0
    fi
  fi

  # Last of the checks, so a held promotion is reported only when everything
  # else would have moved the tag. The gate's stderr (its annotations) passes
  # through; its one stdout line is the reason.
  if [ -n "$canary_gate" ]; then
    gate_mode=manual; [ "$auto" = 1 ] && gate_mode=auto
    if gate_out="$("$canary_gate" "$gate_mode" "$target")"; then
      echo "canary: $gate_out"
    elif [ "$auto" = 1 ]; then
      echo "canary: ${gate_out:-the canary gate failed}"
      echo "promoted=false"
      return 0
    else
      # A gate that crashed must not stand between a person and a rollback.
      echo "::warning title=Canary gate failed::$canary_gate could not run; promoting by hand anyway." >&2
    fi
  fi

  move_tag "$major" "$target"
  note "$major -> $target_tag ($target), was ${curc:-unset}"
  echo "promoted=true"
  echo "version=$version"
  echo "major=$major"
  echo "previous=${curc:-}"
}

case "$cmd" in
  pin) pin ;;
  promote) promote ;;
  *) usage ;;
esac
