#!/usr/bin/env bash
# Assert how versions compare and when a pull request lowers one. versions.pl
# runs on fixed inputs; guard.sh runs against a `gh` on PATH that serves file
# contents from a fixture tree, so nothing here needs a network.
# The backticks in the greps are literal; `A && B || C` is a report, not control flow.
# shellcheck disable=SC2016,SC2015
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$HERE/versions.pl"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/version-guard-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }

echo "max: semver precedence, loosely"
m() { perl "$V" max "$1" "$2" 2>/dev/null || echo "<none>"; }
eq "a prerelease of the next minor beats a patch"   "$(m 1.10.0-develop.14 1.9.1)"   1.10.0-develop.14
eq "a release beats its own prerelease"             "$(m 0.2.0-develop.1 0.2.0)"     0.2.0
eq "prerelease numbers compare as numbers"          "$(m 1.0.0-develop.9 1.0.0-develop.10)" 1.0.0-develop.10
eq "a numeric identifier is lower than a word"      "$(m 1.0.0-1 1.0.0-alpha)"       1.0.0-alpha
eq "more identifiers win a tie"                     "$(m 1.0.0-rc.1 1.0.0-rc.1.1)"   1.0.0-rc.1.1
eq "missing parts are zero"                         "$(m 1.2 1.2.1)"                 1.2.1
eq "a build number breaks a tie"                    "$(m 1.2.3+45 1.2.3+44)"         1.2.3+45
eq "a bare build number is a number"                "$(m 803 99)"                    803
eq "a leading v is fine"                            "$(m v2.0.0 1.9.9)"              v2.0.0
eq "one side empty is the other"                    "$(m '' 1.0.0)"                  1.0.0
eq "two words cannot be compared"                   "$(m next latest)"               "<none>"

echo "values: only the version keys, from each kind of file"
vals() { printf '%b' "$2" > "$WORK/f"; perl "$V" values "$1" "$WORK/f" | tr '\t' '=' | tr '\n' ' '; }
eq "package.json: the root version, not a dependency's" "$(vals package.json '{"name":"a","dependencies":{"x":"1.0.0"},"version":"2.0.0"}')" "version=2.0.0 "
eq "version.properties"   "$(vals app/version.properties 'version=1.11.0-develop.9\nversionCode=803\nother=1\n')" "version=1.11.0-develop.9 versionCode=803 "
eq "gradle.properties"    "$(vals gradle.properties 'org.gradle.jvmargs=-Xmx2g\nVERSION_NAME=3.1.0\nVERSION_CODE=31\n')" "version=3.1.0 versionCode=31 "
eq "pubspec.yaml"         "$(vals pubspec.yaml 'name: app\nversion: 1.2.3+45\n')" "version=1.2.3+45 "
eq "Cargo.toml: the package's, not a dependency table's" "$(vals Cargo.toml '[package]\nname = "x"\nversion = "0.3.0"\n\n[dependencies.serde]\nversion = "1.0.200"\n')" "version=0.3.0 "
eq "Cargo.toml: a workspace package" "$(vals Cargo.toml '[workspace.package]\nversion = "0.4.0"\n')" "version=0.4.0 "
eq "project.pbxproj: the highest configuration" "$(vals ios/A.xcodeproj/project.pbxproj '\t\tMARKETING_VERSION = 1.4;\n\t\tCURRENT_PROJECT_VERSION = 12;\n\t\tMARKETING_VERSION = 1.5;\n')" "CURRENT_PROJECT_VERSION=12 MARKETING_VERSION=1.5 "
eq "package-lock.json: the root version" "$(vals package-lock.json '{"name":"a","version":"1.2.0","packages":{"":{"version":"1.2.0"},"node_modules/x":{"version":"9.0.0"}}}')" "version=1.2.0 "
eq "bun.lock: the root workspace's, trailing commas and all" "$(vals bun.lock '{"workspaces":{"":{"name":"a","version":"0.3.0",},},"packages":{},}')" "version=0.3.0 "
eq "a lockfile with no root version has none" "$(vals package-lock.json '{"packages":{"node_modules/x":{"version":"9.0.0"}}}')" ""
eq "an unknown file has none" "$(vals README.md 'version: 1.0.0\n')" ""
eq "files keeps only version files" "$(printf 'a/package.json\nREADME.md\nm/version.properties\nCargo.lock\nbun.lock\n' | perl "$V" files | tr '\n' ' ')" "a/package.json m/version.properties bun.lock "

echo "align: every stage to the higher of ours and theirs, the rest untouched"
printf 'version=1.2.0\nversionCode=10\nkeep=b\n'           > "$WORK/b"
printf 'version=1.3.0-develop.4\nversionCode=11\nkeep=o\n' > "$WORK/o"
printf 'version=1.2.1\nversionCode=12\nkeep=t\n'           > "$WORK/t"
perl "$V" align m/version.properties "$WORK/b" "$WORK/o" "$WORK/t"
eq "base"   "$(cat "$WORK/b")" "$(printf 'version=1.3.0-develop.4\nversionCode=12\nkeep=b')"
eq "ours"   "$(cat "$WORK/o")" "$(printf 'version=1.3.0-develop.4\nversionCode=12\nkeep=o')"
eq "theirs" "$(cat "$WORK/t")" "$(printf 'version=1.3.0-develop.4\nversionCode=12\nkeep=t')"
printf 'version: next\n' > "$WORK/o"; printf 'version: 1.0.0\n' > "$WORK/t"; printf 'version: 0.9.0\n' > "$WORK/b"
perl "$V" align pubspec.yaml "$WORK/b" "$WORK/o" "$WORK/t" && bad "align must fail on values it cannot compare" || ok "align fails on values it cannot compare"

echo "changelog: ours, plus theirs' missing releases in place"
log() { local p; printf '# Changelog\n'; for p in "$@"; do printf '\n## [%s](u) (d)\n\n* %s\n' "${p%%:*}" "${p#*:}"; done; }
# shellcheck disable=SC2086  # each argument is a list of releases, split on purpose
cl() { log $1 > "$WORK/o"; log $2 > "$WORK/t"; perl "$V" changelog "$WORK/o" "$WORK/t"; }
eq "a hotfix lands below develop's prereleases" "$(cl '1.10.0-develop.14:d14 1.10.0-develop.13:d13 1.9.0:old' '1.9.1:fix 1.9.0:old')" "$(log 1.10.0-develop.14:d14 1.10.0-develop.13:d13 1.9.1:fix 1.9.0:old)"
eq "a release lands above its own prerelease"   "$(cl '0.2.0-develop.1:dev' '0.2.0:rel')" "$(log 0.2.0:rel 0.2.0-develop.1:dev)"
eq "nothing missing: ours, byte for byte"       "$(cl '1.1.0:a 1.0.0:b' '1.0.0:b')" "$(log 1.1.0:a 1.0.0:b)"
printf '# Changelog\n\n# [app@1.3.0](u) (d)\n\n* a\n' > "$WORK/o"; printf '# Changelog\n\n## [app@1.2.1](u) (d)\n\n* b\n' > "$WORK/t"
eq "a monorepo's name@version headings" "$(perl "$V" changelog "$WORK/o" "$WORK/t")" "$(printf '# Changelog\n\n# [app@1.3.0](u) (d)\n\n* a\n\n## [app@1.2.1](u) (d)\n\n* b')"
printf 'notes\n' > "$WORK/o"; printf 'other\n' > "$WORK/t"
perl "$V" changelog "$WORK/o" "$WORK/t" >/dev/null && bad "no release heading must fail" || ok "no release heading fails, so a person decides"

echo "regress: what the new file lowers"
printf 'version=1.10.0-develop.14\nversionCode=20\n' > "$WORK/old"
printf 'version=1.9.1\nversionCode=21\n'             > "$WORK/new"
eq "a lowered version is reported, a raised code is not" "$(perl "$V" regress m/version.properties "$WORK/old" "$WORK/new")" "m/version.properties: version: 1.10.0-develop.14 -> 1.9.1"
printf 'version=1.9.1\nversionCode=21\n' > "$WORK/mb"
eq "a key the change did not touch is not its doing" "$(perl "$V" regress m/version.properties "$WORK/old" "$WORK/new" "$WORK/mb")" ""

# guard.sh against a fake API. A file's content at a commit is $FIX/<sha>/<path>;
# FAKE_MB is the merge base and FAKE_FAIL a path whose read errors (not a 404).
echo "guard: a pull request that lowers a version fails"
FIX="$WORK/fix"
mkdir "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
all="$*"
case "$all" in
  *compare/*)      echo compare >> "$FIX/calls"; printf '%s\n' "${FAKE_MB:-}" ;;
  *contents/*)
    p="${all#*contents/}"; sha="${p##*ref=}"; p="${p%%\?ref=*}"
    [ "$p" != "${FAKE_FAIL:-}" ] || { echo "HTTP 500" >&2; exit 1; }
    [ -f "$FIX/$sha/$p" ] || { echo "HTTP 404" >&2; exit 1; }
    cat "$FIX/$sha/$p" ;;
esac
GH
chmod +x "$WORK/bin/gh"

# $1 sha, $2 path, $3 content.
put() { mkdir -p "$(dirname "$FIX/$1/$2")"; printf '%b' "$3" > "$FIX/$1/$2"; }
pkg() { printf '{\n  "name": "app",\n  "version": "%s",\n  "dependencies": { "next": "%s" }\n}\n' "$1" "${2:-16.4.2}"; }

# $1 name, $2 want verdict, then env assignments.
guard() {
  local name="$1" want="$2" out v rc; shift 2
  out="$WORK/out"; : > "$out"; : > "$FIX/calls"
  env PATH="$WORK/bin:$PATH" FIX="$FIX" GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$WORK/summary" \
      EVENT=pull_request REPO=o/r NUMBER=7 BASE_SHA=base HEAD_SHA=head FAKE_MB=mb COMPLETE=true "$@" \
      "$HERE/guard.sh" > "$WORK/log" 2>&1
  rc=$?
  v=$(sed -n 's/^verdict=//p' "$out")
  if [ "$v" != "$want" ]; then bad "$(printf '%-60s -> %s (wanted %s)' "$name" "${v:-<none>}" "$want")"; cat "$WORK/log"
  elif [ "$want" = reject ] && [ "$rc" -ne 1 ]; then bad "$name: a reject must exit 1, exited $rc"
  elif [ "$want" != reject ] && [ "$rc" -ne 0 ]; then bad "$name: exited $rc"
  else ok "$(printf '%-60s -> %s' "$name" "$v")"; fi
}

# A back-merge resolved by taking the release branch's version line.
put base package.json "$(pkg 1.10.0-develop.14)"
put mb   package.json "$(pkg 1.10.0-develop.14)"
put head package.json "$(pkg 1.9.1)"
guard "a back-merge that takes the hotfix's version"          reject FILES=$'CHANGELOG.md\npackage.json'
grep -q '^::error file=package.json,title=Version moves backwards::package.json: version: 1.10.0-develop.14 -> 1.9.1' "$WORK/log" \
  && ok "the error names the file, the key and both versions" || bad "the error does not say what moved"
grep -q 'never takes the release branch' "$WORK/summary" && ok "the summary says what to do instead" || bad "the summary gives no advice"

# A feature branch cut before the base's last prerelease, changing a dependency.
put base package.json "$(pkg 1.10.0-develop.15)"
put mb   package.json "$(pkg 1.10.0-develop.14 16.4.1)"
put head package.json "$(pkg 1.10.0-develop.14 16.4.2)"
guard "a stale version line the pull request never touched"   pass   FILES=package.json
guard "the same without a merge base still blocks"            reject FILES=package.json FAKE_MB=

# A module's version file.
put base app/version.properties 'version=1.3.0-develop.4\nversionCode=14\n'
put mb   app/version.properties 'version=1.3.0-develop.4\nversionCode=14\n'
put head app/version.properties 'version=1.3.0-develop.4\nversionCode=12\n'
guard "a lowered versionCode"                                 reject FILES=app/version.properties
put head app/version.properties 'version=1.3.0-develop.5\nversionCode=15\n'
guard "a raised version"                                      pass   FILES=app/version.properties
eq "a pass reads no merge base" "$(cat "$FIX/calls")" ""
put head new/version.properties 'version=0.1.0\n'
guard "a version file the pull request adds"                  pass   FILES=new/version.properties

guard "no version file changed"                               pass   FILES=$'src/a.ts\nREADME.md'
guard "an incomplete file list: a warning, not a block"       skip   FILES=package.json COMPLETE=false
grep -q '^::warning title=Version guard::' "$WORK/log" && ok "the incomplete list is a warning" || bad "the incomplete list is silent"
guard "a file that cannot be read: a warning, not a pass in silence" pass FILES=package.json FAKE_FAIL=package.json
grep -q '^::warning title=Version guard::package.json could not be read' "$WORK/log" && ok "the unreadable file is named" || bad "the unreadable file is silent"
guard "a push is skipped"                                     skip   EVENT=push

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
