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
# with $SYFT_COMPONENTS components, `fail` exits 1, `junk` writes a non-CycloneDX
# document. Its arguments are logged one per line.
cat > "$BIN/syft" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$SYFTLOG"
echo "---" >> "$SYFTLOG"
out=""
for a in "$@"; do case "$a" in cyclonedx-json=*) out="${a#cyclonedx-json=}" ;; esac; done
case "${SYFT_MODE:-ok}" in
  fail) exit 1 ;;
  junk) echo '{"spdxVersion":"SPDX-2.3"}' > "$out" ;;
  *) jq -n --argjson n "${SYFT_COMPONENTS:-3}" '{bomFormat: "CycloneDX", specVersion: "1.6", components: [range($n) | {name: "p\(.)"}]}' > "$out" ;;
esac
EOF

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
  : > "$SUMM"; : > "$SYFTLOG"; : > "$GHLOG"; rm -rf "$RT"; mkdir -p "$RT"
  ( cd "$REPO_DIR" && env -i PATH="$BIN:$PATH" HOME="$WORK" TMPDIR="$WORK" \
      GITHUB_STEP_SUMMARY="$SUMM" RUNNER_TEMP="$RT" SYFT="$BIN/syft" \
      SYFTLOG="$SYFTLOG" GHLOG="$GHLOG" REPO=o/r GH_TOKEN=t \
      "$@" "$SCRIPT" > "$LOG" 2>&1 )
  rc=$?
}
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
install() { # RUNNER_OS RUNNER_ARCH; sets rc and the stdout in $WORK/install.out
  local os="$1" arch="$2"; shift 2
  env -i PATH="$BIN:$PATH" HOME="$WORK" TMPDIR="$WORK" RUNNER_OS="$os" RUNNER_ARCH="$arch" \
    RUNNER_TOOL_CACHE="$TC" DLDIR="$WORK/dl" CURLLOG="$CURLLOG" "$@" "$INSTALL" \
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

expect_not_in "the script never calls exit with a failure code" "$SCRIPT" "exit 1"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
