#!/usr/bin/env bash
# Tests for scripts/channel-tag.sh against a throwaway repository with a bare
# remote, so the pushes are real. Nothing here touches this checkout.
#
# Run: scripts/channel-tag.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/channel-tag.sh"
# An explicit template is required: BSD/macOS `mktemp -d` with no template
# ignores TMPDIR.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/channel-tag-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1" >&2; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
ne() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1 (both '$2')"; fi; }
yes() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
no() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# A repo shaped like this one: workflows and composite actions that call each
# other at the floating major, plus things that must never be rewritten.
make_repo() { # make_repo <dir> <major>
  local d="$1" m="$2"
  git init -q -b main "$d" && git init -q --bare "$d.git"
  git -C "$d" remote add origin "$d.git"
  mkdir -p "$d/.github/workflows" "$d/actions/alpha" "$d/actions/beta/nested"
  cat >"$d/.github/workflows/wf.yml" <<YML
# caller example (a comment, left alone):
#   uses: dodi-smart/.github/.github/workflows/wf.yml@v$m
name: wf
on: workflow_call
jobs:
  a:
    uses: dodi-smart/.github/.github/workflows/other.yml@v$m
  b:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: dodi-smart/.github/actions/alpha@v$m
      - uses: "dodi-smart/.github/actions/beta/nested@v$m"   # trailing comment
      - uses: other-org/.github/actions/alpha@v$m
      - uses: dodi-smart/.github/actions/alpha@v$m.2.3
      - run: echo "dodi-smart/.github/actions/alpha@v$m in a script stays"
YML
  cat >"$d/.github/workflows/other.yml" <<YML
name: other
on: workflow_call
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-node@v7
YML
  cat >"$d/actions/alpha/action.yml" <<YML
name: alpha
runs:
  using: composite
  steps:
    - uses: dodi-smart/.github/actions/beta/nested@v$m
      with: { x: 1 }
YML
  cat >"$d/actions/beta/nested/action.yml" <<YML
name: beta
runs:
  using: composite
  steps:
    - uses: actions/cache@v5
YML
  echo "Pin to dodi-smart/.github/actions/alpha@v$m" >"$d/README.md"
  git -C "$d" add -A && git -C "$d" commit -q -m "feat: initial"
}
release() { # release <dir> <version>   (a main commit, then the tag on it)
  echo "$2" >>"$1/CHANGELOG.md"
  git -C "$1" add -A && git -C "$1" commit -q -m "chore(release): $2 [skip ci]"
  git -C "$1" tag "v$2"
  git -C "$1" push -q origin main "refs/tags/v$2"
}
sha() { git -C "$1" rev-parse -q --verify "$2^{commit}" 2>/dev/null || echo none; }
remote_sha() { git -C "$1.git" rev-parse -q --verify "refs/tags/$2^{commit}" 2>/dev/null || echo none; }
show() { git -C "$1" show "$2:$3"; }
run() { local d="$1"; shift; (cd "$d" && "$SCRIPT" "$@" 2>&1); }

# ---------------------------------------------------------------- pin
R="$TMP/r1"
make_repo "$R" 1
release "$R" 1.0.0
# The pre-channel world: v1 already sits on the last release.
git -C "$R" tag v1 v1.0.0 && git -C "$R" push -q origin refs/tags/v1
V1_BEFORE="$(sha "$R" v1)"
release "$R" 1.1.0
MAIN_BEFORE="$(sha "$R" main)"

out="$(run "$R" pin)" || { bad "pin exits 0 ($out)"; }
P="$(sha "$R" pinned/v1.1.0)"
ne "pin creates pinned/v1.1.0" "$P" none
eq "pin picks the latest release tag when no version is given" "$(sha "$R" "pinned/v1.1.0^")" "$(sha "$R" v1.1.0)"
eq "the pinned commit is a child of the release tag (single parent)" "$(git -C "$R" rev-list --parents -n1 "$P" | wc -w | tr -d ' ')" 2
no "the pinned commit is not on main" git -C "$R" merge-base --is-ancestor "$P" main
eq "main is untouched" "$(sha "$R" main)" "$MAIN_BEFORE"
eq "the release tag is untouched" "$(sha "$R" v1.1.0)" "$(sha "$R" "pinned/v1.1.0^")"
eq "next points at the pinned commit" "$(sha "$R" next)" "$P"
eq "next is pushed" "$(remote_sha "$R" next)" "$P"
eq "pinned tag is pushed" "$(remote_sha "$R" pinned/v1.1.0)" "$P"
eq "v1 is NOT moved by a release (first-release safety)" "$(sha "$R" v1)" "$V1_BEFORE"
eq "v1 is NOT moved on the remote" "$(remote_sha "$R" v1)" "$V1_BEFORE"

wf="$(show "$R" "$P" .github/workflows/wf.yml)"
case "$wf" in *"workflows/other.yml@pinned/v1.1.0"*) ok "reusable workflow ref pinned";; *) bad "reusable workflow ref pinned";; esac
case "$wf" in *"actions/alpha@pinned/v1.1.0"*) ok "action ref pinned";; *) bad "action ref pinned";; esac
case "$wf" in *'actions/beta/nested@pinned/v1.1.0"   # trailing comment'*) ok "quoted ref with a trailing comment pinned";; *) bad "quoted ref with a trailing comment pinned";; esac
case "$wf" in *"actions/checkout@v7"*) ok "actions/checkout@v7 untouched";; *) bad "actions/checkout@v7 untouched";; esac
case "$wf" in *"other-org/.github/actions/alpha@v1"$'\n'*) ok "another org's ref untouched";; *) bad "another org's ref untouched";; esac
case "$wf" in *"actions/alpha@v1.2.3"*) ok "an exact version is left alone";; *) bad "an exact version is left alone";; esac
case "$wf" in *"#   uses: dodi-smart/.github/.github/workflows/wf.yml@v1"$'\n'*) ok "a commented example is left alone";; *) bad "a commented example is left alone";; esac
case "$wf" in *'in a script stays"'*) ok "a ref inside a run script is left alone";; *) bad "a ref inside a run script is left alone";; esac
case "$(show "$R" "$P" actions/alpha/action.yml)" in *"nested@pinned/v1.1.0"*) ok "composite action ref pinned";; *) bad "composite action ref pinned";; esac
# Self-consistent at every depth: each internal ref in the pinned commit names a
# tag that resolves to that same commit, so an action called by a pinned action
# runs the pinned commit too, never the release commit with its floating refs.
# Only `uses:` lines count: a ref in a comment or a run script is prose.
refs="$(git -C "$R" grep -h -E '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*["]?dodi-smart/\.github/' "$P" -- .github/workflows actions \
        | grep -oE '@[^"[:space:]]+' | grep -vE '^@v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^@//' | sort -u)"
eq "every rewritten ref names the pinned tag" "$refs" "pinned/v1.1.0"
eq "that tag is the pinned commit itself" "$(sha "$R" "$refs")" "$P"
case "$(show "$R" "$P" actions/beta/nested/action.yml)" in *"actions/cache@v5"*) ok "nested action third-party ref untouched";; *) bad "nested action third-party ref untouched";; esac
eq "files that name no internal ref are byte-identical" "$(show "$R" "$P" .github/workflows/other.yml)" "$(show "$R" v1.1.0 .github/workflows/other.yml)"
eq "README is never rewritten" "$(show "$R" "$P" README.md)" "$(show "$R" v1.1.0 README.md)"
eq "the release tag still holds the floating refs" "$(show "$R" v1.1.0 actions/alpha/action.yml | grep -c 'nested@v1$')" 1
eq "only the expected files differ" "$(git -C "$R" diff --name-only v1.1.0 "$P" | sort | tr '\n' ' ')" ".github/workflows/wf.yml actions/alpha/action.yml "

# idempotency: same commit, same tags, no new objects needed
out2="$(run "$R" pin)" || bad "second pin exits 0"
eq "second pin keeps the pinned commit" "$(sha "$R" pinned/v1.1.0)" "$P"
eq "second pin keeps next" "$(sha "$R" next)" "$P"
eq "second pin keeps next on the remote" "$(remote_sha "$R" next)" "$P"
case "$out2" in *"already exists"*) ok "second pin says it reused the commit";; *) bad "second pin says it reused the commit ($out2)";; esac

# a rerun of an older release never drags next backwards
run "$R" pin --version 1.0.0 >/dev/null || bad "pin of an older release exits 0"
ne "older release gets its own pinned commit" "$(sha "$R" pinned/v1.0.0)" none
eq "next is not moved backwards" "$(sha "$R" next)" "$P"
run "$R" pin --version 1.0.0 --force >/dev/null
eq "--force moves next back deliberately" "$(sha "$R" next)" "$(sha "$R" pinned/v1.0.0)"
run "$R" pin --version 1.1.0 >/dev/null
eq "pinning the newer release moves next forward again" "$(sha "$R" next)" "$P"

no "a missing release tag is an error" run "$R" pin --version 9.9.9
no "a malformed version is an error" run "$R" pin --version banana

# a push that cannot happen is not silently ignored, and --no-push stays local
R2="$TMP/r2"; make_repo "$R2" 1; release "$R2" 1.0.0
run "$R2" pin --no-push >/dev/null
ne "--no-push still tags locally" "$(sha "$R2" next)" none
eq "--no-push pushes nothing" "$(remote_sha "$R2" next)" none

# ---------------------------------------------------------------- promote
# v1 sits on 1.0.0 (the pre-channel release, no pinned commit). next is 1.1.0.
# The pin of 1.0.0 above was only there to test the guard on next, so drop it.
git -C "$R" tag -d pinned/v1.0.0 >/dev/null && git -C "$R" push -q origin :refs/tags/pinned/v1.0.0
eq "before promote, v1 is the old release" "$(sha "$R" v1)" "$V1_BEFORE"
out="$(run "$R" promote)" || bad "promote exits 0 ($out)"
eq "promote with no version moves v1 to what next points at" "$(sha "$R" v1)" "$P"
eq "promote pushes v1" "$(remote_sha "$R" v1)" "$P"
case "$out" in *"promoted=true"*"version=1.1.0"*) ok "promote reports what it did";; *) bad "promote reports what it did ($out)";; esac

# rollback: an older version, here one cut before channels existed
run "$R" promote --version 1.0.0 >/dev/null || bad "rollback exits 0"
eq "rollback to a pre-channel release uses its own tag" "$(sha "$R" v1)" "$V1_BEFORE"
eq "rollback leaves next alone" "$(sha "$R" next)" "$P"
run "$R" promote --version v1.1.0 >/dev/null
eq "a leading v on the version is accepted" "$(sha "$R" v1)" "$P"
run "$R" promote --version 1.0.0 >/dev/null
no "promoting a version that does not exist fails" run "$R" promote --version 7.7.7
eq "a failed promote leaves v1 where it was" "$(sha "$R" v1)" "$V1_BEFORE"

# automatic: waits out the soak time, never goes backwards, is a no-op when current
out="$(run "$R" promote --auto)"
case "$out" in *"promoted=false"*) ok "auto does not promote a fresh next";; *) bad "auto does not promote a fresh next ($out)";; esac
eq "auto leaves v1 alone while next is fresh" "$(sha "$R" v1)" "$V1_BEFORE"
out="$(run "$R" promote --auto --min-age-hours 0)"
case "$out" in *"promoted=true"*) ok "auto promotes once the soak time is over";; *) bad "auto promotes once the soak time is over ($out)";; esac
eq "auto moved v1" "$(sha "$R" v1)" "$P"
out="$(run "$R" promote --auto --min-age-hours 0)"
case "$out" in *"promoted=false"*) ok "auto is a no-op when v1 is already there";; *) bad "auto is a no-op when v1 is already there ($out)";; esac
run "$R" pin --version 1.0.0 --force --no-push >/dev/null
eq "next now sits on the older release" "$(sha "$R" next)" "$(sha "$R" pinned/v1.0.0)"
out="$(run "$R" promote --auto --min-age-hours 0)"
case "$out" in *"promoted=false"*) ok "auto never promotes an older next over a newer v1";; *) bad "auto never promotes an older next over a newer v1 ($out)";; esac
eq "v1 survived" "$(sha "$R" v1)" "$P"

# soak time is measured from when the pinned commit was made
R3="$TMP/r3"; make_repo "$R3" 1; release "$R3" 1.0.0; git -C "$R3" tag v1 v1.0.0
release "$R3" 1.1.0
GIT_COMMITTER_DATE="$(( $(date +%s) - 3 * 86400 )) +0000" run "$R3" pin --no-push >/dev/null
out="$(run "$R3" promote --auto --no-push)"
case "$out" in *"promoted=true"*) ok "auto promotes a next that is older than 24h by default";; *) bad "auto promotes a next older than 24h ($out)";; esac

# ---------------------------------------------------------------- majors
R4="$TMP/r4"; make_repo "$R4" 1; release "$R4" 1.5.0; git -C "$R4" tag v1 v1.5.0
run "$R4" pin >/dev/null
P1="$(sha "$R4" next)"
# 2.0.0: the internal refs were moved to @v2 by the change that cut it
perl -pi -e 's{(dodi-smart/\.github/\S*)\@v1(?![\w.-])}{$1\@v2}' "$R4/.github/workflows/wf.yml" "$R4/actions/alpha/action.yml"
git -C "$R4" add -A && git -C "$R4" commit -q -m "feat!: v2"
release "$R4" 2.0.0
eq "the 2.0.0 sources name @v2, not @v1" "$(grep -c 'alpha@v2$' "$R4/.github/workflows/wf.yml")" 1
run "$R4" pin >/dev/null
P2="$(sha "$R4" pinned/v2.0.0)"
eq "a new major is pinned to its own version" "$(show "$R4" "$P2" actions/alpha/action.yml | grep -c 'nested@pinned/v2.0.0')" 1
eq "next stays a single channel and follows the newest release" "$(sha "$R4" next)" "$P2"
eq "the 1.5.0 pinned commit is what next held before 2.0.0" "$P1" "$(sha "$R4" pinned/v1.5.0)"
ne "the old major's pinned commit is kept" "$(sha "$R4" pinned/v1.5.0)" none
run "$R4" promote >/dev/null
eq "promote derives v2 from the version" "$(sha "$R4" v2)" "$P2"
eq "promote leaves v1 frozen at the last 1.x" "$(sha "$R4" v1)" "$(sha "$R4" v1.5.0)"
run "$R4" promote --version 1.5.0 >/dev/null
eq "a 1.x rollback moves v1, not v2" "$(sha "$R4" v1)" "$(sha "$R4" pinned/v1.5.0)"
eq "and leaves v2 where it was" "$(sha "$R4" v2)" "$P2"

# A checkout that persisted GITHUB_TOKEN as an extraheader would send it in place
# of the App token in the URL, and GitHub refuses that push for workflow files.
SHIM="$TMP/shim"; mkdir -p "$SHIM"; REAL_GIT="$(command -v git)"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/git.log"\nexec "%s" "$@"\n' "$TMP" "$REAL_GIT" > "$SHIM/git"; chmod +x "$SHIM/git"
(cd "$R4" && PATH="$SHIM:$PATH" CHANNEL_TOKEN=t GITHUB_REPOSITORY=o/r "$SCRIPT" promote --version 1.5.0 --remote origin >/dev/null 2>&1)
eq "a token push clears the persisted auth header" "$(grep -c '^-c http.https://github.com/.extraheader= push' "$TMP/git.log")" 1
: > "$TMP/git.log"
(cd "$R4" && PATH="$SHIM:$PATH" "$SCRIPT" promote --version 1.5.0 >/dev/null 2>&1)
eq "a plain push leaves the header alone" "$(grep -c 'extraheader' "$TMP/git.log")" 0

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
