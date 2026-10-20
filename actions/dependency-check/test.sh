#!/usr/bin/env bash
# Assert what is reported and what blocks, against a fake osv-scanner and a fake
# gh: only a finding the base commit lacks is new, a new one at or above the
# threshold fails the job, and a scan that could not run is reported apart from
# findings. Also the install (a fake curl: checksum, platform, cache). Self test
# checks that Renovate reads the pinned version.
# The backticks in the expected text are markdown, not command substitution.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dependency-check.sh"
INSTALL="$HERE/install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dependency-check-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

BIN="$WORK/bin"; FIX="$WORK/fix"; REPO_DIR="$WORK/repo"; BASE="$WORK/base"
OUTS="$WORK/out"; SUMM="$WORK/summary.md"; LOG="$WORK/log"
SCANLOG="$WORK/scanned.log"; GHLOG="$WORK/gh.log"
mkdir -p "$BIN"

# A fake osv-scanner. The file it is asked to scan holds, on its first line, the
# name of a fixture: that fixture's JSON is the output and its .rc the exit code.
# A lockfile's content therefore says what the scanner "finds" in it, wherever
# the file sits, which is how head and base differ in these tests.
cat > "$BIN/osv-scanner" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  if [ "$1" = -L ]; then f="$2"; fi
  shift
done
key="$(head -n 1 "$f" | tr -d '\r')"
printf '%s\t%s\n' "$f" "$key" >> "$SCANLOG"
[ -f "$FIX/$key.json" ] && cat "$FIX/$key.json"
exit "$(cat "$FIX/$key.rc" 2>/dev/null || echo 0)"
EOF

# A fake gh serving `repos/<o>/<r>/contents/<path>?ref=<sha>` from $BASEDIR: a
# missing file is a 404, and `<path>.error` makes it a server error.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in repos/*) url="$a" ;; esac; done
p="${url#repos/*/*/contents/}"; p="${p%%\?*}"
printf '%s\n' "$p" >> "$GHLOG"
p="$(printf '%b' "${p//%/\\x}")"
if [ -f "$BASEDIR/$p.error" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
if [ -f "$BASEDIR/$p" ]; then cat "$BASEDIR/$p"; exit 0; fi
echo "gh: Not Found (HTTP 404)" >&2; exit 1
EOF
chmod +x "$BIN/osv-scanner" "$BIN/gh"

fresh() { rm -rf "$REPO_DIR" "$BASE" "$FIX"; mkdir -p "$REPO_DIR" "$BASE" "$FIX"; }
put()  { mkdir -p "$(dirname "$REPO_DIR/$1")"; printf '%s\n' "$2" > "$REPO_DIR/$1"; }  # head file
base() { mkdir -p "$(dirname "$BASE/$1")"; printf '%s\n' "$2" > "$BASE/$1"; }          # base file

# One osv-scanner package entry, in the shape the real binary writes (checked
# against 2.7.0): name, version, ecosystem, id, an alias, max_severity. A
# severity of @absent leaves the key out.
pkg() {
  jq -cn --arg n "$1" --arg v "$2" --arg e "$3" --arg id "$4" --arg al "$5" --arg s "$6" '
    {package: {name: $n, version: $v, ecosystem: $e},
     vulnerabilities: [{id: $id}],
     groups: [{ids: [$id], aliases: ([$id, $al] | map(select(. != "")))}
              + (if $s == "@absent" then {} else {max_severity: $s} end)]}'
}
# fx <fixture> <exit code> [package entries]: what the scanner prints and returns.
fx() {
  local key="$1" rc="$2"; shift 2
  printf '%s\n' "$@" | jq -s '{results: [{source: {path: "x", type: "lockfile"}, packages: .}]}' > "$FIX/$key.json"
  echo "$rc" > "$FIX/$key.rc"
}

# run VAR=value ...: runs the script in the fake repo with the given inputs.
# Sets rc, and leaves the outputs, summary and log in files.
run() {
  : > "$OUTS"; : > "$SUMM"; : > "$SCANLOG"; : > "$GHLOG"
  ( cd "$REPO_DIR" && env -i PATH="$BIN:$PATH" HOME="$WORK" TMPDIR="$WORK" \
      GITHUB_OUTPUT="$OUTS" GITHUB_STEP_SUMMARY="$SUMM" OSV_SCANNER="$BIN/osv-scanner" \
      FIX="$FIX" BASEDIR="$BASE" SCANLOG="$SCANLOG" GHLOG="$GHLOG" \
      REPO=o/r NUMBER=7 BASE_SHA=basesha GH_TOKEN=t FAIL_ON=none \
      "$@" "$SCRIPT" > "$LOG" 2>&1 )
  rc=$?
}
out() { grep "^$1=" "$OUTS" | head -1 | cut -d= -f2-; }
expect() { # name, output key, want
  local got; got="$(out "$2")"
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1" "$2 is '$got', wanted '$3'"; fi
}
expect_rc() { # name, want
  if [ "$rc" -eq "$2" ]; then ok "$1"; else bad "$1" "exit $rc, wanted $2"; fi
}
expect_in() { # name, file, text it must hold
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1" "lacks: $3"; fi
}
check() { # name, detail for a failure, then the test command
  local name="$1" detail="$2"; shift 2
  if "$@"; then ok "$name"; else bad "$name" "$detail"; fi
}
expect_scans() { # name, want
  check "$1" "$(scans) scans" [ "$(scans)" -eq "$2" ]
}
expect_not_in() { # name, file, text it must not hold
  if grep -qF -- "$3" "$2"; then bad "$1" "has: $3"; else ok "$1"; fi
}
scans() { wc -l < "$SCANLOG" | tr -d ' '; }

LOCK=package-lock.json

# ---- what gets scanned -------------------------------------------------------

fresh; put $LOCK head-x
# No OSV_SCANNER and no RUNNER_OS: the install would fail, so this also shows the
# binary is fetched only once there is something to scan.
run FILES=$'README.md\nsrc/a.ts' OSV_SCANNER=
expect_rc "no lockfile changed passes" 0
expect "no lockfile changed is skipped" result skipped
expect_in "the summary says no lockfile changed" "$SUMM" "no lockfile changed"
expect "nothing counted when skipped" new-count 0

fresh; put $LOCK head-x
run AUTHOR_KIND=dependency FILES=$LOCK FAIL_ON=critical OSV_SCANNER=
expect_rc "a dependency PR passes" 0
expect "a dependency PR is skipped" result skipped
expect_in "the summary says deps-verify owns it" "$SUMM" "deps-verify owns dependency pull requests"
run AUTHOR_KIND=dependency LOCKFILES=$LOCK OSV_SCANNER=
expect "a dependency PR is skipped even with an explicit list" result skipped

fresh; put $LOCK head-x
run NUMBER= FILES= OSV_SCANNER=
expect "an event that is not a pull request is skipped" result skipped
expect_in "and says why" "$SUMM" "not a pull request"

fresh; put $LOCK head-x; fx head-x 0
run FILES=$'vendor/xbun.lock\ndocs/requirements.md'
expect "changed paths that are no lockfile are skipped" result skipped
expect "and nothing is scanned" new-count 0
expect_scans "no scanner run for it" 0

fresh; put $LOCK head-x; fx head-x 0
put app/requirements-dev.txt head-x
put docs/requirements.md head-x
run FILES=$'README.md\napp/requirements-dev.txt\ndocs/requirements.md\n'"$LOCK"
expect "only real lockfile names are scanned" result clean
expect_scans "two scans: the lockfile and requirements-dev.txt" 2
expect_not_in "requirements.md is not scanned" "$SCANLOG" "requirements.md"

# Every supported name, nested or not, is scanned; a name osv-scanner cannot read
# is not, since passing it makes the scanner fail instead of skip.
names="bun.lock package-lock.json pnpm-lock.yaml yarn.lock Cargo.lock go.mod gradle.lockfile
       Gemfile.lock poetry.lock uv.lock composer.lock pubspec.lock requirements.txt requirements-dev.txt"
fresh; fx head-x 0
list=""
for n in $names; do
  put "$n" head-x; put "svc/api/$n" head-x
  list="$list$n"$'\n'"svc/api/$n"$'\n'
done
for n in go.sum Podfile.lock package.json dev-requirements.txt; do put "$n" head-x; done
run FILES="${list}go.sum"$'\nPodfile.lock\npackage.json\ndev-requirements.txt'
expect_scans "all 14 supported names, at the root and nested, are scanned" 28
expect_not_in "go.sum is not scanned" "$SCANLOG" "go.sum"
expect_not_in "Podfile.lock is not scanned" "$SCANLOG" "Podfile.lock"
expect_not_in "package.json is not scanned" "$SCANLOG" "package.json"

# changed-files answers matched=true with an empty list when it could not read
# one, and a cut-off list at its cap. Neither says no lockfile changed.
fresh; put $LOCK head-x; put README.md hello; fx head-x 0
run FILES=
expect "an unread list scans the checkout" result clean
expect_in "and says so" "$LOG" "scanning every supported lockfile in the checkout"
expect_scans "only the lockfile is scanned" 1
mkdir -p "$REPO_DIR/node_modules/x"; put node_modules/x/package-lock.json head-x
run FILES=
expect_scans "node_modules is left alone" 1
big="$(seq 1 3000 | sed 's|^|src/f|')"
run FILES="$big"
expect_in "a list at the 3000-file cap scans the checkout" "$LOG" "scanning every supported lockfile in the checkout"
expect_scans "the lockfile past the cut is found" 1

fresh; put $LOCK head-x; fx head-x 0
run LOCKFILES="$LOCK" FILES=README.md
expect "an explicit list overrides the computed one" result clean
expect_scans "and is scanned" 1

fresh; put keep/$LOCK head-x; fx head-x 0
run LOCKFILES=$'gone/package-lock.json\nkeep/package-lock.json'
expect "a removed lockfile is passed over" result clean
expect_in "and named" "$LOG" "gone/package-lock.json: not in this checkout"
run LOCKFILES=$'gone/package-lock.json'
expect "only removed lockfiles is a skip" result skipped

# ---- old and new -------------------------------------------------------------

LODASH_HIGH="$(pkg lodash 4.17.15 npm GHSA-35jh-r3h4-6jhm CVE-2021-23337 7.2)"

# Already at base, so it never fails, at any threshold.
fresh; put $LOCK head-a; base $LOCK base-a
fx head-a 1 "$LODASH_HIGH"; fx base-a 1 "$LODASH_HIGH"
run LOCKFILES=$LOCK FAIL_ON=low
expect_rc "a finding present at base does not fail fail-on low" 0
expect "and the result is clean" result clean
expect "no new finding" new-count 0
expect "one existing" existing-count 1
expect_in "the summary counts it as already present" "$SUMM" "1 already present at the base commit"

# The version is not part of the identity: the same advisory on a newer release
# of the same package is still the old problem.
fresh; put $LOCK head-a; base $LOCK base-a
fx head-a 1 "$(pkg lodash 4.17.20 npm GHSA-35jh-r3h4-6jhm CVE-2021-23337 7.2)"; fx base-a 1 "$LODASH_HIGH"
run LOCKFILES=$LOCK FAIL_ON=low
expect "a bumped version of the same advisory is existing" existing-count 1
expect_rc "and does not fail" 0

# Matched by any shared id or alias, since two scans may group them differently.
fresh; put $LOCK head-a; base $LOCK base-a
fx head-a 1 "$(pkg lodash 4.17.15 npm GHSA-35jh-r3h4-6jhm CVE-2021-23337 7.2)"
fx base-a 1 "$(pkg lodash 4.17.15 npm OSV-2021-1 CVE-2021-23337 7.2)"
run LOCKFILES=$LOCK FAIL_ON=low
expect "a shared alias makes it existing" existing-count 1

# Same advisory on another package, or another advisory on the same package, is new.
fresh; put $LOCK head-a; base $LOCK base-a
fx head-a 1 "$LODASH_HIGH" "$(pkg minimist 1.2.0 npm GHSA-xvch-5gv4-984h CVE-2021-44906 9.8)"
fx base-a 1 "$LODASH_HIGH"
run LOCKFILES=$LOCK FAIL_ON=critical
expect "an advisory on another package is new" new-count 1
expect "the old one stays old" existing-count 1
expect_rc "a new critical fails fail-on critical" 1
expect "the result is failed" result failed
expect_in "the error says how many" "$LOG" "1 new vulnerabilities at critical or above"

# A new high: blocks high, passes critical and none.
fresh; put $LOCK head-a; base $LOCK base-a
fx head-a 1 "$LODASH_HIGH"; fx base-a 0
run LOCKFILES=$LOCK FAIL_ON=high
expect_rc "a new high fails fail-on high" 1
expect "failed" result failed
expect "one new" new-count 1
run LOCKFILES=$LOCK FAIL_ON=critical
expect_rc "a new high passes fail-on critical" 0
expect "and is reported as findings" result findings
run LOCKFILES=$LOCK FAIL_ON=none
expect_rc "a new high passes fail-on none" 0
expect "and is reported as findings under none" result findings
run LOCKFILES=$LOCK
expect_rc "fail-on defaults to report only" 0
expect_in "the summary has the table header" "$SUMM" "| Package | Version | Ecosystem | Advisories | Severity | Lockfile |"
expect_in "the table names the package, version, ecosystem and id" "$SUMM" '| `lodash` | 4.17.15 | npm | GHSA-35jh-r3h4-6jhm | high (7.2) | `package-lock.json` |'
expect_in "the summary counts the new ones" "$SUMM" "**1 new**"
expect_in "base was read for the lockfile" "$GHLOG" "package-lock.json"

# A lockfile the base does not have: everything in it is new.
fresh; put svc/$LOCK head-a; fx head-a 1 "$LODASH_HIGH" "$(pkg minimist 1.2.0 npm GHSA-xvch-5gv4-984h CVE-2021-44906 9.8)"
run LOCKFILES=svc/$LOCK FAIL_ON=high
expect "a lockfile new in the PR has every finding new" new-count 2
expect "and none existing" existing-count 0
expect_rc "and fails" 1
expect_in "the log says the base lacks it" "$LOG" "not in the base commit"

# The base is asked for by its path, encoded.
fresh; put "my app/$LOCK" head-a; base "my app/$LOCK" base-a
fx head-a 1 "$LODASH_HIGH"; fx base-a 1 "$LODASH_HIGH"
run LOCKFILES="my app/$LOCK" FAIL_ON=low
expect "a path with a space is read at base" existing-count 1
expect_in "the request encodes it" "$GHLOG" "my%20app/package-lock.json"

# Nothing found at head: base is never read.
fresh; put $LOCK head-a; fx head-a 0
run LOCKFILES=$LOCK FAIL_ON=low
expect "a clean lockfile is clean" result clean
check "and costs no API call" "$(cat "$GHLOG")" [ ! -s "$GHLOG" ]

# ---- severity bands ----------------------------------------------------------

band_case() { # score, fail-on, wanted exit
  fresh; put $LOCK head-b; fx head-b 1 "$(pkg lodash 4.0.0 npm GHSA-b "" "$1")"
  run LOCKFILES=$LOCK FAIL_ON="$2"
  expect_rc "severity '$1' with fail-on $2 exits $3" "$3"
}
band_case 3.9 low 1
band_case 3.9 moderate 0
band_case 4.0 moderate 1
band_case 4.0 high 0
band_case 6.9 moderate 1
band_case 6.9 high 0
band_case 7.0 high 1
band_case 7.0 critical 0
band_case 8.9 high 1
band_case 8.9 critical 0
band_case 9.0 critical 1

# A score of 0 is no severity at all, and never blocks.
band_case 0 low 0

# No usable score ranks as high: it blocks high and below, passes critical, and
# is never silently dropped.
band_case "" high 1
band_case "" moderate 1
band_case "" low 1
band_case "" critical 0
band_case "@absent" high 1
band_case "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H" high 1
band_case "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H" critical 0

fresh; put $LOCK head-b; fx head-b 1 "$(pkg lodash 4.0.0 npm GHSA-b "" 4.0)" "$(pkg minimist 1.0.0 npm GHSA-c "" "")"
run LOCKFILES=$LOCK
expect_in "a score is shown beside its band" "$SUMM" "moderate (4.0)"
expect_in "no score is shown as unknown" "$SUMM" "| unknown |"
run LOCKFILES=$LOCK FAIL_ON=high
expect_in "a gating run says an unscored advisory counts as high" "$SUMM" "an unscored advisory counts as high"

# ---- a scan that could not run -----------------------------------------------

# 127 is osv-scanner's error code, 1 its "found vulnerabilities".
fresh; put $LOCK head-e; fx head-e 127
run LOCKFILES=$LOCK FAIL_ON=none
expect_rc "a scanner error passes under fail-on none" 0
expect "and is not called clean" result skipped
expect "and is counted as an error" errors 1
expect "and not as a finding" new-count 0
expect_in "with a warning" "$LOG" "::warning::dependency-check could not check package-lock.json"
expect_in "the summary lists it apart" "$SUMM" "**Could not check 1:**"
run LOCKFILES=$LOCK FAIL_ON=high
expect_rc "a scanner error fails a threshold" 1
expect "the result is failed" result failed
expect "still counted as an error" errors 1
expect "and still not a finding" new-count 0
expect_in "the error says the check did not run" "$LOG" "this is not a finding"

# Unparsable output, or a code that is neither 0, 1 nor 128, is an error too.
fresh; put $LOCK head-e; printf 'not json' > "$FIX/head-e.json"; echo 0 > "$FIX/head-e.rc"
run LOCKFILES=$LOCK FAIL_ON=low
expect_rc "output that is not JSON fails a threshold" 1
expect "as an error, not a finding" errors 1
fresh; put $LOCK head-e; fx head-e 2
run LOCKFILES=$LOCK FAIL_ON=low
expect "an unknown exit code is an error" errors 1

# 128 is "no packages in this file", e.g. a lockfile emptied by the change.
fresh; put $LOCK head-e; fx head-e 128
run LOCKFILES=$LOCK FAIL_ON=low
expect_rc "a lockfile with no packages passes" 0
expect "and is clean" result clean

# The base could not be read, or its scan failed: old cannot be told from new.
fresh; put $LOCK head-a; fx head-a 1 "$LODASH_HIGH"; base $LOCK base-a; : > "$BASE/$LOCK.error"
run LOCKFILES=$LOCK FAIL_ON=high
expect_rc "an unreadable base fails a threshold" 1
expect "as an error" errors 1
expect "not as a finding" new-count 0
run LOCKFILES=$LOCK FAIL_ON=none
expect_rc "and passes under none" 0
fresh; put $LOCK head-a; base $LOCK base-a; fx head-a 1 "$LODASH_HIGH"; fx base-a 127
run LOCKFILES=$LOCK FAIL_ON=high
expect "a failed base scan is an error" errors 1
expect_rc "that fails a threshold" 1

# One lockfile failing does not hide another's finding.
fresh; put a/$LOCK head-a; put b/$LOCK head-e; fx head-a 1 "$LODASH_HIGH"; fx head-e 127
run LOCKFILES=$'a/package-lock.json\nb/package-lock.json' FAIL_ON=none
expect_rc "an error and a finding pass under none" 0
expect "the finding is reported" result findings
expect "the error is counted" errors 1
expect "the finding is counted" new-count 1

# The base commit is needed to compare anything.
fresh; put $LOCK head-a; fx head-a 1 "$LODASH_HIGH"
run LOCKFILES=$LOCK FAIL_ON=high BASE_SHA=
expect_rc "no base commit fails a threshold" 1
expect_in "and says nothing was checked" "$LOG" "nothing was checked"
run LOCKFILES=$LOCK FAIL_ON=none BASE_SHA=
expect_rc "no base commit warns under none" 0
expect "and is not called clean" result skipped

run LOCKFILES=$LOCK FAIL_ON=urgent
expect_rc "an unknown fail-on is refused" 2

# ---- install -----------------------------------------------------------------

VERSION="$(sed -n 's/^OSV_SCANNER_VERSION=//p' "$INSTALL")"
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
for a in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64; do printf 'binary %s\n' "$a" > "$WORK/dl/osv-scanner_$a"; done
: > "$WORK/dl/osv-scanner_SHA256SUMS"
for a in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64; do
  printf '%s  osv-scanner_%s\n' "$(digest "$WORK/dl/osv-scanner_$a")" "$a" >> "$WORK/dl/osv-scanner_SHA256SUMS"
done

TC="$WORK/toolcache"; CURLLOG="$WORK/curl.log"
install() { # RUNNER_OS RUNNER_ARCH [VAR=value ...]; sets rc and the stdout in $WORK/install.out
  local os="$1" arch="$2"; shift 2
  : > "$WORK/install.out"
  env -i PATH="$BIN:$PATH" HOME="$WORK" TMPDIR="$WORK" RUNNER_OS="$os" RUNNER_ARCH="$arch" \
    RUNNER_TOOL_CACHE="$TC" DLDIR="$WORK/dl" CURLLOG="$CURLLOG" "$@" "$INSTALL" \
    > "$WORK/install.out" 2> "$WORK/install.err"
  rc=$?
}

rm -rf "$TC"; : > "$CURLLOG"
install Linux X64
expect_rc "install on Linux x64" 0
want="$TC/osv-scanner/$VERSION/linux-amd64/osv-scanner"
check "it prints the binary's path" "$(cat "$WORK/install.out")" [ "$(cat "$WORK/install.out")" = "$want" ]
check "the binary is executable" "$want" [ -x "$want" ]
expect_in "it downloads the Linux amd64 asset at the pinned version" "$CURLLOG" "/download/v$VERSION/osv-scanner_linux_amd64"
expect_in "and the checksum file from the same release" "$CURLLOG" "/download/v$VERSION/osv-scanner_SHA256SUMS"
n="$(wc -l < "$CURLLOG" | tr -d ' ')"
install Linux X64
check "a copy in the tool cache is reused, with no download" "curl ran again" [ "$(wc -l < "$CURLLOG" | tr -d ' ')" -eq "$n" ]
check "and its path is printed" "$(cat "$WORK/install.out")" [ "$(cat "$WORK/install.out")" = "$want" ]
check "no download directory is left behind" "$(ls "$TC/osv-scanner/$VERSION")" [ -z "$(find "$TC/osv-scanner/$VERSION" -name 'download.*')" ]

: > "$CURLLOG"
install Linux ARM64
expect_in "Linux arm64 gets its own asset" "$CURLLOG" "osv-scanner_linux_arm64"
install macOS ARM64
expect_in "macOS arm64 gets the darwin asset" "$CURLLOG" "osv-scanner_darwin_arm64"
install macOS X64
expect_in "macOS x64 gets the darwin amd64 asset" "$CURLLOG" "osv-scanner_darwin_amd64"

rm -rf "$TC"
install Windows X64
expect_rc "Windows is refused" 1
install Linux X86
expect_rc "a 32-bit runner is refused" 1

# A digest that does not match is a refusal, and nothing is left to be reused.
rm -rf "$TC"; cp "$WORK/dl/osv-scanner_SHA256SUMS" "$WORK/sums.good"
sed 's/^[0-9a-f]\{64\}  osv-scanner_linux_amd64$/0000000000000000000000000000000000000000000000000000000000000000  osv-scanner_linux_amd64/' \
  "$WORK/sums.good" > "$WORK/dl/osv-scanner_SHA256SUMS"
install Linux X64
expect_rc "a checksum mismatch fails" 1
expect_in "and says so" "$WORK/install.err" "does not match the release checksum"
check "and installs nothing" "$want exists" [ ! -e "$want" ]
check "and prints no path" "$(cat "$WORK/install.out")" [ -z "$(cat "$WORK/install.out")" ]
grep -v 'osv-scanner_linux_amd64' "$WORK/sums.good" > "$WORK/dl/osv-scanner_SHA256SUMS"
install Linux X64
expect_rc "an asset the checksum file does not list fails" 1
cp "$WORK/sums.good" "$WORK/dl/osv-scanner_SHA256SUMS"
rm -f "$WORK/dl/osv-scanner_linux_amd64"
install Linux X64
check "a failed download fails" "exit 0" [ "$rc" -ne 0 ]

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
