#!/usr/bin/env bash
# After a signed Android release build: find the APKs, attach them to the GitHub
# Release of the tag, and hand one to Firebase App Distribution with the
# Release's body as its notes.
#
# Reads its inputs from the environment (action.yml is a thin wrapper):
#   TAG                    the release tag the APKs belong to (required)
#   APK_GLOB               newline-separated globs, `**` allowed (default below)
#   FIREBASE_APP_ID        empty skips distribution; the APKs are still attached
#   FIREBASE_GROUPS        comma-separated group aliases; empty distributes to nobody
#   FIREBASE_TOOLS_VERSION exact version, run through npx (required with an app id)
#   CREDENTIALS_FILE       service-account JSON, required with an app id
#   REPO                   owner/repo of the release (default $GITHUB_REPOSITORY)
#   GH_TOKEN               what `gh` authenticates with
#   NOTES_MAX              byte cap on the release notes (default 8000)
#
# No secret is ever an argument: the GitHub token reaches `gh` as GH_TOKEN and
# the Firebase credentials reach firebase-tools as GOOGLE_APPLICATION_CREDENTIALS,
# a path. Arguments are visible to every process on the machine.
#
# Needs bash 4 (globstar, mapfile).
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "::error::this needs bash 4 or later for globstar (found $BASH_VERSION)"
  exit 1
fi

TAG="${TAG:-}"
APK_GLOB="${APK_GLOB:-**/build/outputs/apk/release/*.apk}"
FIREBASE_APP_ID="${FIREBASE_APP_ID:-}"
FIREBASE_GROUPS="${FIREBASE_GROUPS:-}"
FIREBASE_TOOLS_VERSION="${FIREBASE_TOOLS_VERSION:-}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
# Firebase documents no limit for release notes. Staff have said 65536 bytes and
# an API error has been seen at 16384 characters, so stay well under the lower.
NOTES_MAX="${NOTES_MAX:-8000}"

fail() { echo "::error::$*"; exit 1; }

[ -n "$TAG" ] || fail "tag is required"
[ -n "$REPO" ] || fail "repository is required (owner/repo)"

# --- the APKs ------------------------------------------------------------------
# An unsigned APK is never uploaded: injected signing that did not apply leaves
# `*-unsigned.apk` beside (or instead of) the signed one, and installing that
# fails on a tester's phone long after the job went green.
resolve() {
  shopt -s globstar nullglob
  local IFS= pattern f
  local -a found=()
  while read -r pattern; do
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"
    pattern="${pattern%"${pattern##*[![:space:]]}"}"
    [ -n "$pattern" ] || continue
    # shellcheck disable=SC2206  # expanding the glob is the point; IFS is empty, so nothing splits
    found+=( $pattern )
  done <<< "$APK_GLOB"
  for f in "${found[@]+"${found[@]}"}"; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done | sort -u
}

mapfile -t matched < <(resolve)
signed=(); unsigned=()
for f in "${matched[@]+"${matched[@]}"}"; do
  case "${f##*/}" in
    *unsigned*) unsigned+=("$f") ;;
    *) signed+=("$f") ;;
  esac
done

if [ "${#signed[@]}" -eq 0 ]; then
  if [ "${#unsigned[@]}" -gt 0 ]; then
    fail "only unsigned APKs matched (${unsigned[*]}). The build did not apply the injected signing, so nothing was uploaded."
  fi
  fail "no APK matches apk-glob in $PWD. Looked for: $(tr '\n' ' ' <<< "$APK_GLOB")"
fi

# `gh release upload` names an asset by file name, so two APKs that differ only
# by directory would overwrite one another.
dups="$(printf '%s\n' "${signed[@]}" | sed 's|.*/||' | sort | uniq -d)"
[ -z "$dups" ] || fail "two matched APKs share the file name $(tr '\n' ' ' <<< "$dups")and would overwrite each other as release assets. Narrow apk-glob."

# Decided before anything is uploaded, acted on after: the assets belong on the
# release either way.
mode=go
if [ -z "$FIREBASE_APP_ID" ]; then
  mode=skip
elif [ "${#signed[@]}" -ne 1 ]; then
  mode=ambiguous
fi

# Checked before the upload too, so a wrong input does not leave a half-done deploy.
if [ "$mode" = go ]; then
  [[ "$FIREBASE_TOOLS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "firebase-tools-version must be an exact version such as 1.2.3 (got '$FIREBASE_TOOLS_VERSION')"
  [ -n "$CREDENTIALS_FILE" ] && [ -s "$CREDENTIALS_FILE" ] \
    || fail "credentials-file is empty or missing, and a firebase-app-id needs it"
fi

echo "APKs: ${signed[*]}"

# --- attach to the release -----------------------------------------------------
gh release upload "$TAG" "${signed[@]}" --clobber --repo "$REPO"

if [ "$mode" = skip ]; then
  echo "::notice::firebase-app-id is empty, so the APKs are attached to $TAG and nothing is distributed."
  exit 0
fi
if [ "$mode" = ambiguous ]; then
  fail "${#signed[@]} APKs matched and Firebase App Distribution takes one binary per release, so none was distributed (all are attached to $TAG): ${signed[*]}. Narrow apk-glob to the one to distribute."
fi

# --- the notes -----------------------------------------------------------------
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/android-distribute.XXXXXX")"
trap 'rm -rf "$work"' EXIT
notes="$work/notes.txt"

if ! body="$(gh release view "$TAG" --repo "$REPO" --json body --jq '.body // ""')"; then
  echo "::warning::could not read the release notes of $TAG; distributing with the fallback text."
  body=""
fi

if [ -z "${body//[[:space:]]/}" ]; then
  printf 'Release %s\n' "$TAG" > "$notes"
elif [ "$(printf '%s' "$body" | wc -c)" -gt "$NOTES_MAX" ]; then
  # Cut on bytes; `iconv -c` drops a multibyte character the cut split, and
  # exits non-zero when it did.
  cut="$(printf '%s' "$body" | { head -c "$NOTES_MAX"; cat >/dev/null; } | { iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true; })"
  printf '%s\n\n[Release notes truncated. The full text is on the GitHub release: %s/%s/releases/tag/%s]\n' \
    "$cut" "${GITHUB_SERVER_URL:-https://github.com}" "$REPO" "$TAG" > "$notes"
else
  printf '%s\n' "$body" > "$notes"
fi

# --- Firebase ------------------------------------------------------------------
args=( appdistribution:distribute "${signed[0]}" --app "$FIREBASE_APP_ID" --release-notes-file "$notes" )
groups="$(printf '%s' "$FIREBASE_GROUPS" | tr -d '[:space:]')"
[ -z "$groups" ] || args+=( --groups "$groups" )

GOOGLE_APPLICATION_CREDENTIALS="$CREDENTIALS_FILE" \
  npx --yes "firebase-tools@${FIREBASE_TOOLS_VERSION}" "${args[@]}"
