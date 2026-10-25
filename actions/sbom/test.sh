#!/usr/bin/env bash
# Assert what gets attached and that nothing fails the job, against a fake syft
# and a fake gh: one scan for every tag, one asset per tag with a file-safe name,
# no asset for an empty or invalid SBOM, and a warning (never a red job) for each
# thing that went wrong. Also the install (a fake curl: checksum, platform,
# archive, cache). Self test checks that Renovate reads the pinned version.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/sbom.sh"
INSTALL="$HERE/install.sh"
ACTION="$HERE/action.yml"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sbom-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

BIN="$WORK/bin"; REPO_DIR="$WORK/repo"; RT="$WORK/rt"
SUMM="$WORK/summary.md"; LOG="$WORK/log"; SYFTLOG="$WORK/syft.log"; GHLOG="$WORK/gh.log"
mkdir -p "$BIN" "$REPO_DIR"

# A fake syft. $SYFT_MODE picks what it does: `ok` writes a CycloneDX document
# with $SYFT_COMPONENTS components (or the $SYFT_JSON array), `fail` exits 1,
# `junk` writes a non-CycloneDX document. Its arguments are logged one per line.
cat > "$BIN/syft" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$SYFTLOG"
echo "---" >> "$SYFTLOG"
out=""
for a in "$@"; do case "$a" in cyclonedx-json=*) out="${a#cyclonedx-json=}" ;; esac; done
case "${SYFT_MODE:-ok}" in
  fail) exit 1 ;;
  junk) echo '{"spdxVersion":"SPDX-2.3"}' > "$out" ;;
  *) if [ -n "${SYFT_JSON:-}" ]; then
       jq -n --argjson c "$SYFT_JSON" '{bomFormat: "CycloneDX", specVersion: "1.6", components: $c}' > "$out"
     else
       jq -n --argjson n "${SYFT_COMPONENTS:-3}" '{bomFormat: "CycloneDX", specVersion: "1.6", components: [range($n) | {name: "p\(.)"}]}' > "$out"
     fi ;;
esac
EOF

# A Gradle SBOM, the same shape from the plugin and from cdxgen: $1 components
# g0.. with purls, each depending on the next (the last on one that is absent).
cat > "$BIN/gradle_doc" <<'EOF'
#!/usr/bin/env bash
jq -n --argjson n "$1" '{bomFormat: "CycloneDX", specVersion: "1.6",
  metadata: {component: {"bom-ref": "root", name: "app"}},
  components: [range($n) | {"bom-ref": "pkg:maven/g/g\(.)@1", name: "g\(.)", purl: "pkg:maven/g/g\(.)@1"}],
  dependencies: ([{ref: "root", dependsOn: ["pkg:maven/g/g0@1"]}]
    + [range($n) | {ref: "pkg:maven/g/g\(.)@1", dependsOn: ["pkg:maven/g/g\(. + 1)@1"]}])}'
EOF

# A fake cdxgen: `-o <file>` gets $CDXGEN_COMPONENTS Gradle components, unless
# $CDXGEN_MODE is `fail` or `junk`. A fake gradlew: `cyclonedxBom` writes the
# plugin's 3.x aggregate (or 1.x path with $PLUGIN_LAYOUT=1), unless
# $GRADLEW_MODE is `fail` or `silent` (succeeds, writes nothing). Both log a line.
cat > "$BIN/cdxgen" <<'EOF'
#!/usr/bin/env bash
printf 'cdxgen %s\n' "$*" >> "$SYFTLOG.tools"
out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
case "${CDXGEN_MODE:-ok}" in
  fail) exit 1 ;;
  junk) echo '{}' > "$out" ;;
  *) gradle_doc "${CDXGEN_COMPONENTS:-4}" > "$out" ;;
esac
EOF
cat > "$WORK/gradlew" <<'EOF'
#!/usr/bin/env bash
printf 'gradlew %s\n' "$*" >> "$SYFTLOG.tools"
case "${GRADLEW_MODE:-ok}" in
  fail) echo "BUILD FAILED" >&2; exit 1 ;;
  silent) exit 0 ;;
esac
dir=build/reports/cyclonedx; [ "${PLUGIN_LAYOUT:-3}" = 1 ] && dir=build/reports
mkdir -p "$dir" && gradle_doc "${PLUGIN_COMPONENTS:-5}" > "$dir/bom.json"
EOF
mkdir -p "$WORK/jdk"; printf '#!/bin/sh\necho fake java\n' > "$WORK/jdk/java"
chmod +x "$BIN/gradle_doc" "$BIN/cdxgen" "$WORK/gradlew" "$WORK/jdk/java"
# A PATH with the tools the script needs and no java, for the no-JDK case: the
# hosted image has a real one on its PATH.
SYS="$WORK/sys"; mkdir -p "$SYS"
for t in bash env jq git find mktemp tr xargs grep sed tail head cp mv cat dirname rm mkdir printf wc; do
  p="$(command -v "$t")" && ln -sf "$p" "$SYS/$t"
done

# A fake gh: `release upload <tag> <file> --clobber -R <repo>` logs the tag and the
# file's base name. A tag listed in $GH_MISSING has no release and fails.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "release upload" ] || { echo "unexpected gh $*" >&2; exit 2; }
tag="$3"; file="$4"
case " ${GH_MISSING:-} " in *" $tag "*) echo "release not found" >&2; exit 1 ;; esac
[ -f "$file" ] || { echo "no such file $file" >&2; exit 1; }
printf '%s\t%s\n' "$tag" "${file##*/}" >> "$GHLOG"
EOF
chmod +x "$BIN/syft" "$BIN/gh"

run() { # VAR=value ...: runs sbom.sh in the fake repo; sets rc
  : > "$SUMM"; : > "$SYFTLOG"; : > "$SYFTLOG.tools"; : > "$GHLOG"; rm -rf "$RT" "$REPO_DIR/build"; mkdir -p "$RT"
  ( cd "$REPO_DIR" && env -i PATH="$WORK/jdk:$BIN:$PATH" HOME="$WORK" TMPDIR="$WORK" \
      GITHUB_STEP_SUMMARY="$SUMM" RUNNER_TEMP="$RT" SYFT="$BIN/syft" CDXGEN="$BIN/cdxgen" \
      SYFTLOG="$SYFTLOG" GHLOG="$GHLOG" REPO=o/r GH_TOKEN=t \
      "$@" "$SCRIPT" > "$LOG" 2>&1 )
  rc=$?
}
attached_doc() { cat "$RT/sbom.cdx.json"; }
tools() { cat "$SYFTLOG.tools"; }
verdict() { sed -n 's/^sbom: result=\([^ ]*\) .*/\1/p' "$LOG"; }
field() { sed -n "s/^sbom: .* $1=\([^ ]*\).*/\1/p" "$LOG"; }
check() { # name, detail for a failure, then the test command
  local name="$1" detail="$2"; shift 2
  if "$@"; then ok "$name"; else bad "$name" "$detail"; fi
}
expect_in()     { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1" "lacks: $3"; fi; }
expect_not_in() { if grep -qF -- "$3" "$2"; then bad "$1" "has: $3"; else ok "$1"; fi; }
scans()   { grep -c '^---$' "$SYFTLOG" | tr -d ' '; }
uploads() { wc -l < "$GHLOG" | tr -d ' '; }

check "the action has no outputs" "an outputs: block is back" [ -z "$(grep -n '^outputs:' "$ACTION")" ]

# ---- what gets attached ------------------------------------------------------

run TAGS='["v1.4.0"]'
check "a single tag exits 0" "exit $rc" [ "$rc" -eq 0 ]
check "and is attached" "$(verdict)" [ "$(verdict)" = attached ]
expect_in "as sbom-<tag>.cdx.json on that tag's release" "$GHLOG" "v1.4.0	sbom-v1.4.0.cdx.json"
check "the verdict counts the components" "$(field components)" [ "$(field components)" = 3 ]
expect_in "it scans the checkout as a directory" "$SYFTLOG" "dir:."
expect_in "and writes CycloneDX JSON" "$SYFTLOG" "cyclonedx-json="
expect_in "dependency trees are excluded" "$SYFTLOG" "./**/node_modules/**"
expect_in "and build output" "$SYFTLOG" "./**/build/**"
expect_in "the summary names the asset" "$SUMM" "sbom-v1.4.0.cdx.json"

run TAGS='["core@1.2.0","app@2.0.0-develop.3"]'
check "a multi-module release scans once" "$(scans) scans" [ "$(scans)" -eq 1 ]
check "and attaches to every tag" "$(uploads) uploads" [ "$(uploads)" -eq 2 ]
expect_in "a tag with @ gets a file-safe asset name" "$GHLOG" "core@1.2.0	sbom-core-1.2.0.cdx.json"
expect_in "and so does a prerelease" "$GHLOG" "app@2.0.0-develop.3	sbom-app-2.0.0-develop.3.cdx.json"

run TAGS='["v1.0.0"]' EXCLUDE=$'./fixtures/**\n  ./samples/**  \n'
expect_in "a caller's exclude is passed on" "$SYFTLOG" "./fixtures/**"
expect_in "trimmed, one per line" "$SYFTLOG" "./samples/**"
expect_in "on top of the built-in list" "$SYFTLOG" "./.git/**"

# ---- nothing to do -----------------------------------------------------------

run TAGS='[]'
check "no tags is a no-op that exits 0" "exit $rc" [ "$rc" -eq 0 ]
check "and is reported as skipped" "$(verdict)" [ "$(verdict)" = skipped ]
check "with no scan" "$(scans) scans" [ "$(scans)" -eq 0 ]
run
check "an unset TAGS is the same" "$(verdict)" [ "$(verdict)" = skipped ]

# ---- never a red job ---------------------------------------------------------

run TAGS='["v1.0.0"]' SYFT_MODE=fail
check "a failed scan still exits 0" "exit $rc" [ "$rc" -eq 0 ]
check "and is an error, not an attachment" "$(verdict)" [ "$(verdict)" = error ]
expect_in "with a warning" "$LOG" "::warning title=SBOM not attached::"
check "and nothing is uploaded" "$(uploads)" [ "$(uploads)" -eq 0 ]

run TAGS='["v1.0.0"]' SYFT_MODE=junk
check "output that is not CycloneDX exits 0" "exit $rc" [ "$rc" -eq 0 ]
check "and is an error" "$(verdict)" [ "$(verdict)" = error ]
check "and is not uploaded" "$(uploads)" [ "$(uploads)" -eq 0 ]

run TAGS='["v1.0.0"]' SYFT_COMPONENTS=0
check "an SBOM with no components exits 0" "exit $rc" [ "$rc" -eq 0 ]
check "and is reported as empty" "$(verdict)" [ "$(verdict)" = empty ]
check "and is not attached, so no release claims zero dependencies" "$(uploads)" [ "$(uploads)" -eq 0 ]
expect_in "with a warning that says why" "$LOG" "found no components"

run TAGS='["a@1.0.0","b@1.0.0"]' GH_MISSING='a@1.0.0'
check "a tag without a release exits 0" "exit $rc" [ "$rc" -eq 0 ]
check "and is partial" "$(verdict)" [ "$(verdict)" = partial ]
check "the other tag is still attached" "$(uploads)" [ "$(uploads)" -eq 1 ]
expect_in "and the missing one is warned about by name" "$LOG" "SBOM not attached to a@1.0.0"
check "the counts add up" "$(field attached)/$(field failed)" [ "$(field attached)/$(field failed)" = "1/1" ]

# ---- a Gradle build -----------------------------------------------------------

# The fake repo becomes a Gradle build with a wrapper. No build script names the
# plugin, so cdxgen lists the Gradle components; syft still scans for lockfiles.
cp "$WORK/gradlew" "$REPO_DIR/gradlew"; echo 'rootProject.name = "app"' > "$REPO_DIR/settings.gradle.kts"
run TAGS='["v2.0.0"]'
check "a Gradle build without the plugin exits 0" "exit $rc" [ "$rc" -eq 0 ]
expect_in "and asks cdxgen in Gradle mode" "$SYFTLOG.tools" "cdxgen -t gradle"
expect_in "for CycloneDX 1.6, the version syft writes" "$SYFTLOG.tools" "--spec-version 1.6"
expect_not_in "and lets it run the build, without which it resolves nothing" "$SYFTLOG.tools" "--no-install-deps"
expect_not_in "and never runs the plugin task" "$SYFTLOG.tools" "cyclonedxBom"
check "syft still scans" "$(scans) scans" [ "$(scans)" -eq 1 ]
check "the components of both are attached" "$(field components)" [ "$(field components)" = 7 ]
check "and the verdict names both" "$(field via)" [ "$(field via)" = "cdxgen+syft" ]
expect_in "the summary names them" "$SUMM" "from cdxgen and syft."
check "the Gradle graph survives the merge" "$(attached_doc | jq -c '.dependencies | length')" \
  [ "$(attached_doc | jq '[.dependencies[] | select(.ref == "pkg:maven/g/g0@1")] | length')" = 1 ]
check "the root comes from the Gradle document" "$(attached_doc | jq -c .metadata)" [ "$(attached_doc | jq -r .metadata.component.name)" = app ]
check "no edge points at a component that is not there" "$(attached_doc | jq -c '[.dependencies[].dependsOn[]]')" \
  [ "$(attached_doc | jq '[.dependencies[].dependsOn[]] | index("pkg:maven/g/g4@1")')" = null ]

# A KMM app: the Gradle graph, plus the pods and Swift packages syft reads from
# the lockfiles, one of them a component the Gradle side reports too.
run TAGS='["v2.0.0"]' CDXGEN_COMPONENTS=3 \
  SYFT_JSON='[{"name":"Alamofire","version":"5.6.0","purl":"pkg:cocoapods/Alamofire@5.6.0"},{"name":"swift-nio","version":"2.29.0","purl":"pkg:swift/github.com/apple/swift-nio@2.29.0"},{"name":"g1","purl":"pkg:maven/g/g1@1"}]'
check "a KMM build lists the Gradle and the lockfile components once each" "$(field components)" [ "$(field components)" = 5 ]
check "the pod is in" "$(attached_doc | jq -c '[.components[].purl]')" [ "$(attached_doc | jq '[.components[] | select(.purl == "pkg:cocoapods/Alamofire@5.6.0")] | length')" = 1 ]
check "a component both report keeps the Gradle copy" "$(attached_doc | jq -c '[.components[] | select(.name == "g1")]')" \
  [ "$(attached_doc | jq -r '[.components[] | select(.purl == "pkg:maven/g/g1@1")] | length, .[0]["bom-ref"]' | paste -sd' ' -)" = "1 pkg:maven/g/g1@1" ]

# The build names the plugin: its own task, not cdxgen.
printf 'plugins {\n  id("org.cyclonedx.bom") version "3.5.1"\n}\n' > "$REPO_DIR/build.gradle.kts"
run TAGS='["v2.0.0"]' SYFT_COMPONENTS=0
check "a build that applies org.cyclonedx.bom runs cyclonedxBom" "$(tools)" [ "$(tools)" = "gradlew --no-daemon cyclonedxBom" ]
check "and attaches the plugin's aggregate" "$(field components)" [ "$(field components)" = 5 ]
check "and says so" "$(field via)" [ "$(field via)" = "cyclonedx-gradle+syft" ]
run TAGS='["v2.0.0"]' SYFT_COMPONENTS=0 PLUGIN_LAYOUT=1
check "the 1.x and 2.x output path is read too" "$(field components)" [ "$(field components)" = 5 ]
rm "$REPO_DIR/build.gradle.kts"; mkdir -p "$REPO_DIR/gradle"
printf '[plugins]\ncyclonedx = { id = "org.cyclonedx.bom", version = "3.5.1" }\n' > "$REPO_DIR/gradle/libs.versions.toml"
run TAGS='["v2.0.0"]'
check "naming it in the version catalog counts" "$(field via)" [ "$(field via)" = "cyclonedx-gradle+syft" ]
run TAGS='["v2.0.0"]' GRADLEW_MODE=fail
check "a failed cyclonedxBom falls back to cdxgen" "$(field via)" [ "$(field via)" = "cdxgen+syft" ]
expect_in "with a warning" "$LOG" "::warning title=SBOM: cyclonedxBom failed::"
expect_in "and the task's output" "$LOG" "BUILD FAILED"
run TAGS='["v2.0.0"]' GRADLEW_MODE=silent
check "a cyclonedxBom that writes nothing falls back too" "$(field via)" [ "$(field via)" = "cdxgen+syft" ]
rm -r "$REPO_DIR/gradle"

run TAGS='["v2.0.0"]' CDXGEN_MODE=fail
check "a failed cdxgen still exits 0" "exit $rc" [ "$rc" -eq 0 ]
check "and syft's SBOM goes on alone" "$(field via) $(field components)" [ "$(field via) $(field components)" = "syft 3" ]
expect_in "with a warning" "$LOG" "::warning title=SBOM: cdxgen failed::"
run TAGS='["v2.0.0"]' CDXGEN_MODE=junk
check "cdxgen output that is not CycloneDX is left out" "$(field via)" [ "$(field via)" = syft ]
run TAGS='["v2.0.0"]' CDXGEN_MODE=fail SYFT_COMPONENTS=0
check "nothing from either is an empty SBOM, not attached" "$(verdict) $(uploads)" [ "$(verdict) $(uploads)" = "empty 0" ]

run PATH="$BIN:$SYS" TAGS='["v2.0.0"]'   # env keeps the last PATH
check "no JDK still exits 0" "exit $rc" [ "$rc" -eq 0 ]
expect_in "and says the stack would bring one" "$LOG" "::warning title=SBOM: no JDK::"
check "and attaches syft's alone" "$(field via)" [ "$(field via)" = syft ]

rm "$REPO_DIR/gradlew"
run TAGS='["v2.0.0"]'
check "settings.gradle.kts without a gradlew is not a Gradle build" "$(tools)" [ -z "$(tools)" ]
rm "$REPO_DIR/settings.gradle.kts"

run SBOM_ONLY="$WORK/only.cdx.json"
check "SBOM_ONLY writes the SBOM without tags" "$(verdict)" [ "$(verdict)" = written ]
check "there" "missing" [ "$(jq '.components | length' "$WORK/only.cdx.json")" = 3 ]
check "and uploads nothing" "$(uploads)" [ "$(uploads)" -eq 0 ]

# ---- install -----------------------------------------------------------------

VERSION="$(sed -n 's/^SYFT_VERSION=//p' "$INSTALL")"

mkdir -p "$WORK/dl"
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl: `-o <file> <url>` serves $DLDIR/<last path part of the url>.
while [ $# -gt 0 ]; do
  case "$1" in -o) dest="$2"; shift ;; --retry) shift ;; -*) ;; *) url="$1" ;; esac
  shift
done
printf '%s\n' "$url" >> "$CURLLOG"
[ -f "$DLDIR/${url##*/}" ] || exit 22
cp "$DLDIR/${url##*/}" "$dest"
EOF
chmod +x "$BIN/curl"

digest() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
SUMS="syft_${VERSION}_checksums.txt"
: > "$WORK/dl/$SUMS"
for a in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64; do
  d="$WORK/pkg-$a"; mkdir -p "$d"
  printf '#!/bin/sh\necho syft %s\n' "$a" > "$d/syft"; echo licence > "$d/LICENSE"
  tar -czf "$WORK/dl/syft_${VERSION}_$a.tar.gz" -C "$d" syft LICENSE
  printf '%s  %s\n' "$(digest "$WORK/dl/syft_${VERSION}_$a.tar.gz")" "syft_${VERSION}_$a.tar.gz" >> "$WORK/dl/$SUMS"
done

TC="$WORK/toolcache"; CURLLOG="$WORK/curl.log"
install() { # RUNNER_OS RUNNER_ARCH [tool]; sets rc and the stdout in $WORK/install.out
  local os="$1" arch="$2"; shift 2
  env -i PATH="$BIN:$PATH" HOME="$WORK" TMPDIR="$WORK" RUNNER_OS="$os" RUNNER_ARCH="$arch" \
    RUNNER_TOOL_CACHE="$TC" DLDIR="$WORK/dl" CURLLOG="$CURLLOG" "$INSTALL" "$@" \
    > "$WORK/install.out" 2> "$WORK/install.err"
  rc=$?
}

rm -rf "$TC"; : > "$CURLLOG"
install Linux X64
check "install on Linux x64" "exit $rc" [ "$rc" -eq 0 ]
want="$TC/syft/$VERSION/linux-amd64/syft"
check "it prints the binary's path" "$(cat "$WORK/install.out")" [ "$(cat "$WORK/install.out")" = "$want" ]
check "the binary is executable" "$want" [ -x "$want" ]
check "and it is the binary from the archive, not the licence" "$("$want" 2>&1)" [ "$("$want")" = "syft linux_amd64" ]
expect_in "it downloads the Linux amd64 archive at the pinned version" "$CURLLOG" "/download/v$VERSION/syft_${VERSION}_linux_amd64.tar.gz"
expect_in "and the checksums file from the same release" "$CURLLOG" "/download/v$VERSION/$SUMS"
n="$(wc -l < "$CURLLOG" | tr -d ' ')"
install Linux X64
check "a copy in the tool cache is reused, with no download" "curl ran again" [ "$(wc -l < "$CURLLOG" | tr -d ' ')" -eq "$n" ]
check "no download directory is left behind" "$(ls "$TC/syft/$VERSION")" [ -z "$(find "$TC/syft/$VERSION" -name 'download.*')" ]

: > "$CURLLOG"
install Linux ARM64
expect_in "Linux arm64 gets its own archive" "$CURLLOG" "syft_${VERSION}_linux_arm64.tar.gz"
install macOS ARM64
expect_in "macOS arm64 gets the darwin archive" "$CURLLOG" "syft_${VERSION}_darwin_arm64.tar.gz"

rm -rf "$TC"
install Windows X64
check "Windows is refused" "exit $rc" [ "$rc" -eq 1 ]
install Linux X86
check "a 32-bit runner is refused" "exit $rc" [ "$rc" -eq 1 ]

rm -rf "$TC"; cp "$WORK/dl/$SUMS" "$WORK/sums.good"
sed "s/^[0-9a-f]\{64\}  syft_${VERSION}_linux_amd64.tar.gz$/0000000000000000000000000000000000000000000000000000000000000000  syft_${VERSION}_linux_amd64.tar.gz/" \
  "$WORK/sums.good" > "$WORK/dl/$SUMS"
install Linux X64
check "a checksum mismatch fails" "exit $rc" [ "$rc" -eq 1 ]
expect_in "and says so" "$WORK/install.err" "does not match the release checksum"
check "and installs nothing" "$want exists" [ ! -e "$want" ]
check "and prints no path" "$(cat "$WORK/install.out")" [ -z "$(cat "$WORK/install.out")" ]
grep -v "syft_${VERSION}_linux_amd64.tar.gz" "$WORK/sums.good" > "$WORK/dl/$SUMS"
install Linux X64
check "an archive the checksums file does not list fails" "exit $rc" [ "$rc" -eq 1 ]

# An archive without the binary is refused, even with a matching checksum.
d="$WORK/pkg-empty"; mkdir -p "$d"; echo licence > "$d/LICENSE"
tar -czf "$WORK/dl/syft_${VERSION}_linux_amd64.tar.gz" -C "$d" LICENSE
grep -v "syft_${VERSION}_linux_amd64.tar.gz" "$WORK/sums.good" > "$WORK/dl/$SUMS"
printf '%s  %s\n' "$(digest "$WORK/dl/syft_${VERSION}_linux_amd64.tar.gz")" "syft_${VERSION}_linux_amd64.tar.gz" >> "$WORK/dl/$SUMS"
install Linux X64
check "an archive with no syft binary fails" "exit $rc" [ "$rc" -eq 1 ]
expect_in "and says so" "$WORK/install.err" "holds no syft binary"
rm -f "$WORK/dl/syft_${VERSION}_linux_amd64.tar.gz"
install Linux X64
check "a failed download fails" "exit 0" [ "$rc" -ne 0 ]

# cdxgen: the binary itself, checked against the sha256 file beside it.
CDX_VERSION="$(sed -n 's/^CDXGEN_VERSION=//p' "$INSTALL")"
for a in linux-amd64 linux-arm64 darwin-arm64; do
  printf '#!/bin/sh\necho cdxgen %s\n' "$a" > "$WORK/dl/cdxgen-$a-slim"
  printf '%s  %s\n' "$(digest "$WORK/dl/cdxgen-$a-slim")" "cdxgen-$a-slim" > "$WORK/dl/cdxgen-$a-slim.sha256"
done
rm -rf "$TC"; : > "$CURLLOG"
install Linux X64 cdxgen
want="$TC/cdxgen/$CDX_VERSION/linux-amd64/cdxgen"
check "cdxgen installs on Linux x64" "exit $rc" [ "$rc" -eq 0 ]
check "and prints its path" "$(cat "$WORK/install.out")" [ "$(cat "$WORK/install.out")" = "$want" ]
check "it is the downloaded binary" "$("$want" 2>&1)" [ "$("$want")" = "cdxgen linux-amd64" ]
expect_in "the slim build at the pinned version" "$CURLLOG" "CycloneDX/cdxgen/releases/download/v$CDX_VERSION/cdxgen-linux-amd64-slim"
expect_in "and its own sha256 file" "$CURLLOG" "/cdxgen-linux-amd64-slim.sha256"
install macOS ARM64 cdxgen
expect_in "macOS arm64 gets the darwin binary" "$CURLLOG" "cdxgen-darwin-arm64-slim"
rm -rf "$TC"; echo "0000000000000000000000000000000000000000000000000000000000000000  cdxgen-linux-amd64-slim" > "$WORK/dl/cdxgen-linux-amd64-slim.sha256"
install Linux X64 cdxgen
check "a cdxgen checksum mismatch fails" "exit $rc" [ "$rc" -eq 1 ]
check "and installs nothing" "$want exists" [ ! -e "$want" ]
install Linux X64 grype
check "any other tool is refused" "exit $rc" [ "$rc" -eq 1 ]
for v in SYFT CDXGEN; do
  check "the renovate marker sits right above ${v}_VERSION" "$(grep -B1 "^${v}_VERSION=" "$INSTALL" | head -n 1)" \
    [ "$(grep -B1 "^${v}_VERSION=" "$INSTALL" | head -n 1 | grep -c '^# renovate: datasource=github-releases depName=')" = 1 ]
done

expect_not_in "the script never calls exit with a failure code" "$SCRIPT" "exit 1"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
