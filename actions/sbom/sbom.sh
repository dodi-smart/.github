#!/usr/bin/env bash
# Build one CycloneDX SBOM of the checkout and attach it to the GitHub release of
# every tag the run just cut.
#
# It never fails the job. It runs after the tags are pushed, and a red release
# job would hold back the deploy jobs callers chain on it over a file that can be
# attached later. Every problem is a `::warning` and a line in the job summary
# instead, and the verdict line below says what happened, so a reader (or a
# later audit) can tell "attached" from "skipped" from "could not".
#
# One scan for all tags: a multi-module release cuts its tags on the same commit,
# so the components are the same; only the asset name differs per tag.
#
# An SBOM with no components is not attached. It would read as "this release
# depends on nothing", which is false; it means syft found no lockfile it reads
# (a Gradle build without dependency locking, for one).
#
# Env: SYFT (binary), TAGS (JSON array), EXCLUDE (extra globs, newline-separated),
#      REPO (owner/repo), GH_TOKEN, RUNNER_TEMP, GITHUB_STEP_SUMMARY.
set -uo pipefail

: "${SYFT:?}" "${REPO:?}" "${RUNNER_TEMP:?}"
TAGS="${TAGS:-[]}"
summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; return 0; }
verdict() { echo "sbom: result=$1 components=${2:-0} attached=${3:-0} failed=${4:-0}"; }
# Nothing gets attached: warn, say so in the summary, record the verdict, exit 0.
give_up() { # verdict, warning, summary
  echo "::warning title=SBOM not attached::$2"
  summary "$3"
  verdict "$1"
  exit 0
}

tags=()
while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.[]?' <<<"$TAGS" 2>/dev/null)
if [ "${#tags[@]}" -eq 0 ]; then
  echo "No new tags, so there is no release to attach an SBOM to."
  verdict skipped
  exit 0
fi

# Dependency trees and build output are not what the release declares; the
# lockfiles are. Excluding them also keeps a vendored copy from being counted twice.
excludes=(
  './.git/**'
  './**/node_modules/**'
  './**/.next/**'
  './**/build/**'
  './**/dist/**'
  './**/target/**'
  './**/.gradle/**'
  './**/vendor/**'
)
while IFS= read -r g; do
  g="${g#"${g%%[![:space:]]*}"}"; g="${g%"${g##*[![:space:]]}"}"
  [ -n "$g" ] && excludes+=("$g")
done <<<"${EXCLUDE:-}"
args=()
for g in "${excludes[@]}"; do args+=(--exclude "$g"); done

out="$RUNNER_TEMP/sbom.cdx.json"
summary "### SBOM" ""
if ! SYFT_CHECK_FOR_APP_UPDATE=false "$SYFT" scan dir:. "${args[@]}" -o "cyclonedx-json=$out" -q; then
  give_up error "syft could not scan the checkout, so no release got an SBOM. Re-run the job, or attach one by hand." \
    "syft could not scan the checkout; no SBOM was attached."
fi

count="$(jq -r 'if .bomFormat == "CycloneDX" then (.components // [] | length) else "invalid" end' "$out" 2>/dev/null || echo invalid)"
if [ "$count" = invalid ]; then
  give_up error "syft wrote something that is not a CycloneDX document, so no release got an SBOM." \
    "syft's output was not a CycloneDX document; no SBOM was attached."
fi
if [ "$count" -eq 0 ]; then
  give_up empty "syft found no components, which usually means no lockfile it can read. An empty SBOM would claim the release has no dependencies, so none was attached." \
    "syft found no components (no readable lockfile?); no SBOM was attached."
fi

summary "$count components, CycloneDX JSON." "" "| Release | SBOM |" "|---|---|"
attached=0; failed=0
for tag in "${tags[@]}"; do
  # A tag like `app@1.2.0` is a valid release name but not a tidy file name.
  asset="$RUNNER_TEMP/sbom-$(printf '%s' "$tag" | tr -c 'A-Za-z0-9._-' '-').cdx.json"
  cp "$out" "$asset"
  if gh release upload "$tag" "$asset" --clobber -R "$REPO" >/dev/null 2>"$RUNNER_TEMP/sbom-upload.err"; then
    attached=$((attached + 1))
    summary "| \`$tag\` | \`${asset##*/}\` |"
  else
    failed=$((failed + 1))
    echo "::warning title=SBOM not attached to $tag::$(head -c 300 "$RUNNER_TEMP/sbom-upload.err" | tr '\n' ' ')"
    summary "| \`$tag\` | not attached (no GitHub release for the tag?) |"
  fi
done

if [ "$failed" -eq 0 ]; then verdict attached "$count" "$attached" 0
else verdict partial "$count" "$attached" "$failed"; fi
exit 0
