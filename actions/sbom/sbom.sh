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
# One SBOM for all tags: a multi-module release cuts its tags on the same commit,
# so the components are the same; only the asset name differs per tag.
#
# syft reads lockfiles, and a Gradle build rarely has one (locking is opt-in),
# so a Gradle build is asked for its resolved graph too: by its own CycloneDX
# plugin when it applies one, since then it has said how it wants its SBOM, else
# by cdxgen. syft's lockfiles (a KMM app's pods and Swift packages) are merged on
# top, and a Gradle generator that fails leaves syft's SBOM to go on alone.
#
# An SBOM with no components is not attached. It would read as "this release
# depends on nothing", which is false; it means no generator found anything (no
# JDK for a Gradle build, or no lockfile syft reads).
#
# Env: SYFT, CDXGEN (binaries to use instead of installing them), TAGS (JSON
#      array), EXCLUDE (extra globs, newline-separated), REPO (owner/repo),
#      GH_TOKEN, RUNNER_TEMP, GITHUB_STEP_SUMMARY. SBOM_ONLY=<path> writes the
#      SBOM there and attaches nothing, with or without tags (self-test).
set -uo pipefail

: "${RUNNER_TEMP:?}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAGS="${TAGS:-[]}"
via=""
summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; return 0; }
verdict() { echo "sbom: result=$1 components=${2:-0} attached=${3:-0} failed=${4:-0} via=${via:-none}"; }
# Nothing gets attached: warn, say so in the summary, record the verdict, exit 0.
give_up() { # verdict, warning, summary
  echo "::warning title=SBOM not attached::$2"
  summary "$3"
  verdict "$1"
  exit 0
}

tags=()
while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.[]?' <<<"$TAGS" 2>/dev/null)
if [ "${#tags[@]}" -eq 0 ] && [ -z "${SBOM_ONLY:-}" ]; then
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

out="${SBOM_ONLY:-$RUNNER_TEMP/sbom.cdx.json}"
parts="$(mktemp -d "$RUNNER_TEMP/sbom-parts.XXXXXX")"
summary "### SBOM" ""
is_cdx() { jq -e '.bomFormat == "CycloneDX"' "$1" >/dev/null 2>&1; }
# A tool's output goes to a log, shown only when it fails.
show() { echo "::group::$1 output"; tail -n 40 "$2"; echo "::endgroup::"; }

# Every document's components, the first document's kept on a clash (by purl, or
# by group, name and version where there is none), and the dependency graph
# trimmed to the refs that are left, so no edge points at a dropped component.
merge() { # out in...
  local dest="$1"; shift
  jq -s '
    def key: .purl // ((.group // "") + "/" + (.name // "") + "@" + (.version // ""));
    . as $docs
    | ([$docs[] | .components // [] | .[]] | unique_by(key)) as $c
    | ([$c[] | .["bom-ref"] // empty] + [$docs[0].metadata.component["bom-ref"] // empty]
       | map({(.): true}) | add // {}) as $known
    | $docs[0]
    | .components = $c
    | .dependencies = ([$docs[] | .dependencies // [] | .[] | select((.ref | type) == "string" and $known[.ref])
                        | .dependsOn = [(.dependsOn // [])[] | select(type == "string" and $known[.])]]
                       | unique_by(.ref))' "$@" > "$dest.tmp" && mv "$dest.tmp" "$dest"
}

# ---- the Gradle build, when there is one -------------------------------------

gradle_build=false
if [ -x ./gradlew ]; then
  for f in settings.gradle settings.gradle.kts build.gradle build.gradle.kts; do
    [ -f "$f" ] && gradle_build=true
  done
fi

# A build script or catalog that names the plugin; never build output.
applies_plugin() {
  grep -rqE --include='*.gradle' --include='*.gradle.kts' --include='*.toml' \
    --exclude-dir=build --exclude-dir=.gradle --exclude-dir=.git --exclude-dir=node_modules \
    'org\.cyclonedx\.bom' . 2>/dev/null
}

gradle_plugin() { # -> 0 with $parts/gradle.cdx.json
  local log="$parts/gradle.log" f found=()
  echo "the build applies org.cyclonedx.bom, so its cyclonedxBom task lists the Gradle components"
  if ! ./gradlew --no-daemon cyclonedxBom > "$log" 2>&1 < /dev/null; then
    show "./gradlew cyclonedxBom" "$log"
    echo "::warning title=SBOM: cyclonedxBom failed::./gradlew cyclonedxBom failed, so the Gradle components come from cdxgen instead."
    return 1
  fi
  # 3.x writes the aggregate to build/reports/cyclonedx/bom.json, 1.x and 2.x
  # write build/reports/bom.json, in each project that applies it.
  while IFS= read -r f; do is_cdx "$f" && found+=("$f"); done < <(
    find . \( -name .gradle -o -name .git -o -name node_modules \) -prune -o -type f \
      \( -path '*/build/reports/cyclonedx/bom.json' -o -path '*/build/reports/bom.json' \) -print 2>/dev/null)
  if [ "${#found[@]}" -eq 0 ]; then
    echo "::warning title=SBOM: no plugin output::cyclonedxBom ran but wrote no bom.json where the plugin's defaults put it, so the Gradle components come from cdxgen instead."
    return 1
  fi
  merge "$parts/gradle.cdx.json" "${found[@]}"
}

gradle_cdxgen() { # -> 0 with $parts/gradle.cdx.json
  local log="$parts/cdxgen.log"
  if [ -z "${CDXGEN:-}" ] && ! CDXGEN="$("$HERE/install.sh" cdxgen)"; then
    echo "::warning title=SBOM: no cdxgen::cdxgen could not be installed, so the SBOM lists no Gradle components."
    return 1
  fi
  echo "running cdxgen in Gradle mode for the Gradle components"
  # Never --no-install-deps: for Gradle it skips running the build, and the
  # static parse it falls back to lists nothing a plugin block resolves.
  if ! "$CDXGEN" -t gradle --spec-version 1.6 -o "$parts/gradle.cdx.json" . > "$log" 2>&1 < /dev/null \
     || ! is_cdx "$parts/gradle.cdx.json"; then
    show cdxgen "$log"
    echo "::warning title=SBOM: cdxgen failed::cdxgen could not read the Gradle build, so the SBOM lists no Gradle components."
    return 1
  fi
}

docs=()
if [ "$gradle_build" = true ]; then
  if ! command -v java >/dev/null 2>&1 && [ -z "${JAVA_HOME:-}" ]; then
    echo "::warning title=SBOM: no JDK::this is a Gradle build, but the runner has no JDK, so the SBOM lists no Gradle components. Release with stack gradle, android or kmm, which installs one."
  elif applies_plugin && gradle_plugin; then
    via="cyclonedx-gradle"
  elif gradle_cdxgen; then
    via="cdxgen"
  fi
  [ -z "$via" ] || docs+=("$parts/gradle.cdx.json")
fi

# ---- syft, over every checkout -----------------------------------------------

if [ -z "${SYFT:-}" ] && ! SYFT="$("$HERE/install.sh")"; then
  echo "::warning title=SBOM: no syft::syft could not be installed, so the SBOM lists no lockfile components."
elif ! SYFT_CHECK_FOR_APP_UPDATE=false "$SYFT" scan dir:. "${args[@]}" -o "cyclonedx-json=$parts/syft.cdx.json" -q; then
  echo "::warning title=SBOM: syft failed::syft could not scan the checkout, so the SBOM lists no lockfile components."
elif ! is_cdx "$parts/syft.cdx.json"; then
  echo "::warning title=SBOM: syft output::syft wrote something that is not a CycloneDX document, so it was left out."
else
  docs+=("$parts/syft.cdx.json"); via="${via:+$via+}syft"
fi

if [ "${#docs[@]}" -eq 0 ]; then
  give_up error "no generator produced a CycloneDX document, so no release got an SBOM. Re-run the job, or attach one by hand." \
    "No generator produced a CycloneDX document; no SBOM was attached."
fi
if ! merge "$out" "${docs[@]}"; then
  give_up error "the SBOMs could not be merged, so no release got an SBOM." \
    "The SBOMs could not be merged; no SBOM was attached."
fi

count="$(jq -r '.components | length' "$out")"
if [ "$count" -eq 0 ]; then
  give_up empty "$via found no components, which usually means no lockfile syft reads and no Gradle build it could resolve. An empty SBOM would claim the release has no dependencies, so none was attached." \
    "$via found no components (no readable lockfile?); no SBOM was attached."
fi

if [ -n "${SBOM_ONLY:-}" ]; then
  verdict written "$count"
  exit 0
fi

: "${REPO:?}"
summary "$count components, CycloneDX JSON, from ${via//+/ and }." "" "| Release | SBOM |" "|---|---|"
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
