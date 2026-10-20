#!/usr/bin/env bash
# Assert the sizing, the deltas, the limit and the base lookup against build
# directories generated here: a pages router build, Turbopack- and webpack-shaped
# app router builds, and a Next 15 app-build-manifest. A wrong total, a delta
# with the wrong sign or a limit that never trips reads as a healthy bundle.
# The backticks in the expected text are markdown, not command substitution.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/bundle-report.sh"
# An explicit template is required: BSD/macOS `mktemp -d` with no template
# ignores TMPDIR.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bundle-report-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

# ---- fixtures ---------------------------------------------------------------
# A deterministic text chunk of N bytes. Its gzip size is whatever it is, so the
# expectations below are computed with the same gzip call and test the sums.
chunk() { # dir name seed bytes
  mkdir -p "$(dirname "$1/static/chunks/$2.js")"
  awk -v n="$4" -v s="$3" 'BEGIN { srand(s); for (i = 0; i < n; i++) printf "%c", 97 + int(rand() * 26) }' > "$1/static/chunks/$2.js"
}
gz() { gzip -c -9 < "$1" | wc -c | tr -d ' '; }
sumgz() { # dir chunk... (names under static/chunks)
  local d="$1" t=0 c; shift
  for c in "$@"; do t=$((t + $(gz "$d/static/chunks/$c.js"))); done
  echo "$t"
}
jl() { printf '"static/chunks/%s.js",' "$@" | sed -e 's/,$//' -e 's/^/[/' -e 's/$/]/'; }

# Turbopack shape: the assignment is on line 2, entryJSFiles lists a layout and a
# page, and clientModules chunk names start with /_next/. The key holds a `]`.
rsc_turbo() { # nextdir routedir key chunk...
  local d="$1/server/app/$2" key="$3"; shift 3
  local plain pref
  plain="$(jl "$@")"
  pref="$(printf '"/_next/static/chunks/%s.js",' "$@" | sed -e 's/,$//' -e 's/^/[/' -e 's/$/]/')"
  mkdir -p "$d"
  {
    echo 'globalThis.__RSC_MANIFEST = globalThis.__RSC_MANIFEST || {};'
    printf 'globalThis.__RSC_MANIFEST["%s"] = {"moduleLoading":{"prefix":""},"clientModules":{"[project]/x.js":{"id":1,"name":"*","chunks":%s,"async":false}},"entryJSFiles":{"[project]/app/page":%s},"entryCSSFiles":{}};\n' "$key" "$pref" "$plain"
  } > "$d/page_client-reference-manifest.js"
}

# webpack shape: one line, no entryJSFiles, chunk ids beside file names.
rsc_webpack() { # nextdir routedir key chunk...
  local d="$1/server/app/$2" key="$3"; shift 3
  local list
  list="$(printf '"static/chunks/%s.js",' "$@" | sed -e 's/,$//')"
  mkdir -p "$d"
  printf 'globalThis.__RSC_MANIFEST=(globalThis.__RSC_MANIFEST||{});globalThis.__RSC_MANIFEST["%s"]={"moduleLoading":{"prefix":"/_next/"},"clientModules":{"/abs/x.js":{"id":1,"name":"*","chunks":["974",%s],"async":false}},"entryCSSFiles":{}};\n' "$key" "$list" > "$d/page_client-reference-manifest.js"
}

# Pages router, webpack shape: /_error is not a route worth a line, polyfills are
# nomodule, and a CSS file is not JS.
P="$WORK/pages"
chunk "$P" rt 1 3000; chunk "$P" fw 2 20000; chunk "$P" app 3 5000
chunk "$P" leg 4 4000; chunk "$P" err 5 2000; chunk "$P" poly 6 6000
mkdir -p "$P/static/css"; echo 'a{}' > "$P/static/css/x.css"
cat > "$P/build-manifest.json" <<JSON
{"polyfillFiles":$(jl poly),"pages":{
  "/_app":$(jl rt fw app),
  "/_error":$(jl rt err),
  "/legacy":$(jl rt fw leg),
  "/legacy/[id]":["static/chunks/leg.js","static/css/x.css"]}}
JSON

# Turbopack app router: five routes, two of them sharing a chunk (s).
T="$WORK/tp"
chunk "$T" r1 11 6000; chunk "$T" r2 12 9000; chunk "$T" lay 13 2000
chunk "$T" p0 14 1500; chunk "$T" pa 15 3000; chunk "$T" pb 16 2500
chunk "$T" pc1 17 4000; chunk "$T" pc2 18 500; chunk "$T" pd 19 3500; chunk "$T" s 20 1000
echo "{\"pages\":{},\"rootMainFiles\":$(jl r1 r2)}" > "$T/build-manifest.json"
rsc_turbo "$T" ""  "/page"   lay p0
rsc_turbo "$T" a   "/a/page" lay pa
rsc_turbo "$T" b   "/b/page" lay pb s
rsc_turbo "$T" c   "/c/page" lay pc1 pc2 s
rsc_turbo "$T" d   "/d/page" lay pd
# First load per route, and the total over distinct chunks.
T_ROOT="$(sumgz "$T" r1 r2 lay)"
T_A=$((T_ROOT + $(sumgz "$T" pa)));  T_B=$((T_ROOT + $(sumgz "$T" pb s)))
T_C=$((T_ROOT + $(sumgz "$T" pc1 pc2 s))); T_D=$((T_ROOT + $(sumgz "$T" pd)))
T_HOME=$((T_ROOT + $(sumgz "$T" p0)))
T_TOTAL=$((T_ROOT + $(sumgz "$T" p0 pa pb pc1 pc2 s pd)))

# webpack app router: a route group, the route map, chunk ids among the files.
W="$WORK/wp"
chunk "$W" r 21 7000; chunk "$W" fw 22 15000; chunk "$W" 974-aaa 23 3000
chunk "$W" app/page-ccc 24 800; chunk "$W" app/about/page-bbb 25 1200
echo "{\"pages\":{},\"rootMainFiles\":$(jl r fw)}" > "$W/build-manifest.json"
echo '{"/page":"/","/(marketing)/about/page":"/about"}' > "$W/app-path-routes-manifest.json"
rsc_webpack "$W" ""                  "/page"                    974-aaa app/page-ccc
rsc_webpack "$W" "(marketing)/about" "/(marketing)/about/page"  974-aaa app/about/page-bbb

# Next 15: app-build-manifest.json already lists a route's chunks, and wins over
# a client reference manifest (zzz is only named there).
N="$WORK/n15"
chunk "$N" rt 31 4000; chunk "$N" main-app 32 500; chunk "$N" lay 33 900
chunk "$N" pg 34 700; chunk "$N" px 35 1100; chunk "$N" o 36 600; chunk "$N" zzz 37 9000
mkdir -p "$N/static/css"; echo 'a{}' > "$N/static/css/a.css"
cat > "$N/build-manifest.json" <<JSON
{"pages":{"/_app":$(jl rt),"/old":$(jl rt o)}}
JSON
cat > "$N/app-build-manifest.json" <<JSON
{"pages":{"/layout":$(jl rt lay),
  "/page":$(jl rt main-app lay pg),
  "/(g)/x/page":["static/chunks/rt.js","static/chunks/main-app.js","static/chunks/lay.js","static/chunks/px.js","static/css/a.css"]}}
JSON
echo '{"/page":"/","/(g)/x/page":"/x"}' > "$N/app-path-routes-manifest.json"
rsc_turbo "$N" "" "/page" zzz

# A fixture-driven gh: GH_ART is the artifacts payload, GH_RUN_<id> the run's
# conclusion, GH_DL_<id> the report a download of that run unpacks. GH_LOG
# records every call, so a test can assert gh was not used.
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
[ -z "${GH_LOG:-}" ] || echo "$*" >> "$GH_LOG"
case "$*" in
  "api --method GET repos/o/r/actions/artifacts"*) cat "${GH_ART:?}" ;;
  "api repos/o/r/actions/runs/"*) v="GH_RUN_${2##*/}"; echo "${!v:-}" ;;
  "run download"*)
    v="GH_DL_$3"; dir=""
    while [ $# -gt 0 ]; do [ "$1" = -D ] && dir="$2"; shift; done
    [ -n "${!v:-}" ] || exit 1
    cp "${!v}" "$dir/bundle-report.json" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$BIN/gh"

# ---- harness ----------------------------------------------------------------
# run KEY=value ... : runs the script with those variables. Sets $OUTS (outputs),
# $MD (the comment), $REP (the report), $LOG (stdout+stderr) and $RC.
run() {
  OUTS="$WORK/out"; MD="$WORK/report.md"; REP="$WORK/report.json"; LOG="$WORK/log"
  : > "$OUTS"; rm -f "$MD" "$REP"
  env OUT="$MD" REPORT_FILE="$REP" GITHUB_OUTPUT="$OUTS" PATH="$BIN:$PATH" "$@" "$SCRIPT" > "$LOG" 2>&1
  RC=$?
}
out() { grep "^$1=" "$OUTS" | head -1 | cut -d= -f2-; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', wanted '$3'"; fi; }
expect() { eq "$1" "$(out "$2")" "$3"; }          # name, output key, want
expect_md() { if grep -qF -- "$2" "$MD"; then ok "$1"; else bad "$1" "comment lacks: $2"; fi; }
expect_no_md() { if grep -qF -- "$2" "$MD"; then bad "$1" "comment has: $2"; else ok "$1"; fi; }
expect_log() { if grep -qF -- "$2" "$LOG"; then ok "$1"; else bad "$1" "log lacks: $2 ($(head -c 300 "$LOG"))"; fi; }
route_bytes() { jq -r --arg r "$1" '.routes[$r] // "none"' "$REP"; }
# The route names in the comment's table, in order.
table_routes() { grep -o '^| `[^`]*`' "$MD" | sed -e 's/^| `//' -e 's/`$//' | tr '\n' ' '; }
kb()  { awk -v b="$1" 'BEGIN { printf "%.1f kB", b / 1000 }'; }
skb() { awk -v b="$1" 'BEGIN { printf "%+.2f kB", b / 1000 }'; }
mkbase() { # file total routes-json
  jq -n --argjson t "$2" --argjson r "$3" '{version: 1, total: $t, routes: $r}' > "$1"
}

# ---- pages router -----------------------------------------------------------
run NEXT_DIR="$P"
eq "a pages router build exits 0" "$RC" 0
eq "a route is _app's chunks plus its own" "$(route_bytes /legacy)" "$(sumgz "$P" rt fw app leg)"
eq "a dynamic route keeps its brackets, and CSS is not counted" "$(route_bytes '/legacy/[id]')" "$(sumgz "$P" rt fw app leg)"
eq "_app and _error are not routes" "$(jq -r '.routes | keys | join(" ")' "$REP")" "/legacy /legacy/[id]"
expect "the total counts each chunk once, without polyfills" total-bytes "$(sumgz "$P" rt fw app leg)"
eq "the report file holds the total" "$(jq -r .total "$REP")" "$(sumgz "$P" rt fw app leg)"
expect "report-file names the report" report-file "$REP"
expect "no base, no delta" delta-bytes ""
expect "no base, no failure" failed ""
expect_md "the comment says there is no base" "no base report"
expect_md "the comment states the total" "Total first-load JS: $(kb "$(sumgz "$P" rt fw app leg)")"
expect_md "the comment says how first load is counted" "1 kB is 1000 bytes"

# ---- app router, Turbopack shape -------------------------------------------
run NEXT_DIR="$T"
eq "a route is the shared chunks plus its client chunks" "$(route_bytes /a)" "$T_A"
eq "the root route is found at server/app itself" "$(route_bytes /)" "$T_HOME"
eq "a chunk shared by two routes is in both" "$(route_bytes /b)" "$T_B"
eq "and a route can have several of its own" "$(route_bytes /c)" "$T_C"
expect "the total counts the shared chunk once" total-bytes "$T_TOTAL"
eq "the sum of the routes is more than the total" "$([ $((T_HOME + T_A + T_B + T_C + T_D)) -gt "$T_TOTAL" ] && echo yes)" yes

# ---- app router, webpack shape ----------------------------------------------
run NEXT_DIR="$W"
eq "a webpack route skips chunk ids and uses the route map" "$(route_bytes /about)" "$(sumgz "$W" r fw 974-aaa app/about/page-bbb)"
eq "a webpack root route" "$(route_bytes /)" "$(sumgz "$W" r fw 974-aaa app/page-ccc)"
eq "a route group is not in the route name" "$(jq -r '.routes | keys | join(" ")' "$REP")" "/ /about"

# ---- Next 15 ----------------------------------------------------------------
run NEXT_DIR="$N"
eq "app-build-manifest lists a route's chunks" "$(route_bytes /)" "$(sumgz "$N" rt main-app lay pg)"
eq "a route group is mapped, CSS dropped" "$(route_bytes /x)" "$(sumgz "$N" rt main-app lay px)"
eq "its pages router still adds _app" "$(route_bytes /old)" "$(sumgz "$N" rt o)"
eq "layout entries are not routes" "$(jq -r '.routes | keys | join(" ")' "$REP")" "/ /old /x"

# ---- base: deltas, order, truncation ---------------------------------------
# Current: / a b c d. Base: / a b c gone. a +5000, b -3000, c +100, d added,
# gone removed (7000). The total grew by exactly 15000 bytes.
BASE="$WORK/base.json"
mkbase "$BASE" $((T_TOTAL - 15000)) "$(jq -n --argjson h "$T_HOME" --argjson a "$((T_A - 5000))" --argjson b "$((T_B + 3000))" --argjson c "$((T_C - 100))" \
  '{"/": $h, "/a": $a, "/b": $b, "/c": $c, "/gone": 7000}')"
run NEXT_DIR="$T" BASE_FILE="$BASE"
eq "a base exits 0" "$RC" 0
expect "the delta is current minus base" delta-bytes 15000
expect "a growth under no limit does not fail" failed ""
eq "sorted by absolute change, unchanged left out" "$(table_routes)" "/d /gone /a /b /c "
expect_md "the total line has the sign, kB and percent" "Total first-load JS: $(kb "$T_TOTAL")**, +15.00 kB ($(awk -v d=15000 -v b=$((T_TOTAL - 15000)) 'BEGIN { printf "%+.1f%%", 100 * d / b }')) against $(kb $((T_TOTAL - 15000))) on the base"
expect_md "a grown route shows its change and percent" "| \`/a\` | $(kb "$T_A") | +5.00 kB ($(awk -v d=5000 -v b=$((T_A - 5000)) 'BEGIN { printf "%+.1f%%", 100 * d / b }')) |"
expect_md "a shrunk route has a minus" "| \`/b\` | $(kb "$T_B") | -3.00 kB ($(awk -v d=-3000 -v b=$((T_B + 3000)) 'BEGIN { printf "%+.1f%%", 100 * d / b }')) |"
expect_md "an added route is new, in full" "| \`/d\` | $(kb "$T_D") | new, $(skb "$T_D") |"
expect_md "a removed route says so and shows its loss" '| `/gone` | removed | -7.00 kB |'

run NEXT_DIR="$T" BASE_FILE="$BASE" TOP=2
eq "top 2 lists the two largest changes" "$(table_routes)" "/d /gone "
expect_md "and counts the rest" "3 more changed routes not shown"
run NEXT_DIR="$T" BASE_FILE="$BASE" TOP=5
expect_no_md "all fit: nothing is said to be cut" "not shown"

# Identical to its base: nothing changed.
run NEXT_DIR="$T"; cp "$REP" "$WORK/same.json"
run NEXT_DIR="$T" BASE_FILE="$WORK/same.json"
expect "an unchanged build has a zero delta" delta-bytes 0
expect_md "and says no route changed" "No route changed."
expect_md "with a zero change in the total line" "+0.00 kB (+0.0%)"

# Without a base the table is sorted by size, and truncated.
run NEXT_DIR="$T" TOP=3
eq "no base: the three largest, biggest first" "$(table_routes)" "$(jq -r '.routes | to_entries | sort_by([-.value, .key]) | .[:3] | map(.key) | join(" ")' "$REP") "
expect_md "no base: the rest are counted" "2 more routes not shown"

# ---- the limit ---------------------------------------------------------------
run NEXT_DIR="$T" BASE_FILE="$BASE" MAX_INCREASE_KB=0
expect "0 is report only, whatever the growth" failed ""
run NEXT_DIR="$T" BASE_FILE="$BASE" MAX_INCREASE_KB=15
expect "growth exactly at the limit passes" failed ""
eq "and the script exits 0 either way" "$RC" 0
run NEXT_DIR="$T" BASE_FILE="$BASE" MAX_INCREASE_KB=14.99
expect "a hair over the limit fails, with the reason" failed "total first-load JS grew by +15.00 kB, over the 14.99 kB limit"
expect_md "the comment says why" "**Over the limit:** total first-load JS grew by +15.00 kB"
eq "the script still exits 0, so the comment can post first" "$RC" 0
run NEXT_DIR="$T" BASE_FILE="$BASE" MAX_INCREASE_KB=100
expect "growth under the limit passes" failed ""
mkbase "$WORK/bigger.json" $((T_TOTAL + 50000)) '{"/": 1}'
run NEXT_DIR="$T" BASE_FILE="$WORK/bigger.json" MAX_INCREASE_KB=1
expect "a shrinking bundle never breaches" failed ""
run NEXT_DIR="$T" MAX_INCREASE_KB=1
expect "no base: the limit is not checked, never failed" failed ""
expect_md "and the comment says it was not checked" "The 1 kB limit was not checked"

# ---- settings that cannot be right -----------------------------------------
run NEXT_DIR="$T" MAX_INCREASE_KB=lots
eq "a non-numeric limit stops the job" "$RC" 1
run NEXT_DIR="$T" TOP=0
eq "top 0 stops the job" "$RC" 1
run NEXT_DIR="$T" TOP=many
eq "a non-numeric top stops the job" "$RC" 1

# ---- nothing to measure -----------------------------------------------------
run NEXT_DIR="$WORK/does-not-exist"
eq "no .next exits 0" "$RC" 0
expect "no .next: no total" total-bytes ""
expect "no .next: no report file" report-file ""
expect "no .next: no failure" failed ""
expect_md "no .next: the comment says there is nothing to measure" "does not exist, so there is nothing to measure"
expect_log "no .next: a warning" "::warning::bundle-report:"

mkdir -p "$WORK/empty"
run NEXT_DIR="$WORK/empty"
eq "a directory with no manifest exits 0" "$RC" 0
expect "no manifest: no total" total-bytes ""
expect_md "no manifest: the comment says so" "holds no route manifests"

mkdir -p "$WORK/broken"; printf 'not json' > "$WORK/broken/build-manifest.json"
run NEXT_DIR="$WORK/broken"
eq "a malformed build-manifest.json does not crash" "$RC" 0
expect_log "and is named in a warning" "build-manifest.json is not valid JSON"
expect_md "and reads as nothing to measure" "nothing to measure"

# ---- a base that is not usable ----------------------------------------------
printf '{ truncated' > "$WORK/bad.json"
run NEXT_DIR="$T" BASE_FILE="$WORK/bad.json" MAX_INCREASE_KB=1
eq "a malformed base exits 0" "$RC" 0
expect_log "a malformed base warns" "is missing or is not a bundle report"
expect "a malformed base is no base" delta-bytes ""
expect "and never breaches a limit" failed ""
expect_md "and the comment lists sizes without deltas" "no base report"
echo '{"total": "big", "routes": []}' > "$WORK/shape.json"
run NEXT_DIR="$T" BASE_FILE="$WORK/shape.json"
expect "valid JSON of the wrong shape is no base" delta-bytes ""
run NEXT_DIR="$T" BASE_FILE="$WORK/missing.json"
expect "a missing base file is no base" delta-bytes ""
eq "and exits 0" "$RC" 0

# ---- chunks that are not there, and names that must not be followed ---------
M="$WORK/gap"; cp -R "$T" "$M"; rm "$M/static/chunks/pa.js"
run NEXT_DIR="$M"
eq "a chunk missing on disk exits 0" "$RC" 0
expect_log "and is counted in a warning" "1 chunk file(s) named in the manifests are not in"
eq "and leaves a route short, not broken" "$(route_bytes /a)" "$T_ROOT"

# The target exists, so only the ".." check keeps it out.
O="$WORK/escape"; cp -R "$T" "$O"; echo 'x' > "$WORK/outside.js"
sed -i.bak 's#static/chunks/pa.js#static/../../outside.js#g' "$O/server/app/a/page_client-reference-manifest.js"
run NEXT_DIR="$O"
eq "a chunk path that climbs out is ignored" "$(route_bytes /a)" "$T_ROOT"
if grep -q 'not in' "$LOG"; then bad "and is not reported as missing" "$(cat "$LOG")"; else ok "and is not reported as missing"; fi

R="$WORK/odd"; cp -R "$T" "$R"; mkdir -p "$R/server/app/we|ird"
rsc_turbo "$R" 'we|ird' '/we|ird/page' lay p0
run NEXT_DIR="$R"
eq "a route name keeps pipes and backticks out of the table" "$(table_routes | tr ' ' '\n' | grep -c weird)" 1

# ---- the base from an artifact ----------------------------------------------
ART="$WORK/artifacts.json"
cat > "$ART" <<'JSON'
{"artifacts":[
 {"id":1,"created_at":"2026-10-01T00:00:00Z","expired":false,"workflow_run":{"id":100,"head_branch":"main"}},
 {"id":2,"created_at":"2026-10-03T00:00:00Z","expired":false,"workflow_run":{"id":300,"head_branch":"main"}},
 {"id":3,"created_at":"2026-10-04T00:00:00Z","expired":false,"workflow_run":{"id":400,"head_branch":"feature"}},
 {"id":4,"created_at":"2026-10-05T00:00:00Z","expired":true,"workflow_run":{"id":500,"head_branch":"main"}},
 {"id":5,"created_at":"2026-10-02T00:00:00Z","expired":false,"workflow_run":{"id":200,"head_branch":"main"}}]}
JSON
mkbase "$WORK/dl200.json" $((T_TOTAL - 2000)) '{"/": 1}'
mkbase "$WORK/dl100.json" $((T_TOTAL - 9000)) '{"/": 1}'
mkbase "$WORK/dl400.json" $((T_TOTAL - 500)) '{"/": 1}'
GH_ENV=(BASE_ARTIFACT=bundle-report REPO=o/r DEFAULT_BRANCH=main GH_ART="$ART" GH_LOG="$WORK/gh.log")

: > "$WORK/gh.log"
run NEXT_DIR="$T" "${GH_ENV[@]}" GH_RUN_300=failure GH_RUN_200=success GH_RUN_100=success \
  GH_DL_200="$WORK/dl200.json" GH_DL_100="$WORK/dl100.json" GH_DL_400="$WORK/dl400.json"
expect "the newest successful default-branch run is the base (not a failed, expired or feature-branch one)" delta-bytes 2000

run NEXT_DIR="$T" "${GH_ENV[@]}" GH_RUN_300=failure GH_RUN_200=success GH_RUN_100=success GH_DL_100="$WORK/dl100.json"
expect "a run whose download fails falls back to the next" delta-bytes 9000

echo '{ nope' > "$WORK/dlbad.json"
run NEXT_DIR="$T" "${GH_ENV[@]}" GH_RUN_200=success GH_RUN_100=success GH_DL_200="$WORK/dlbad.json" GH_DL_100="$WORK/dl100.json"
expect "a downloaded report that is malformed is skipped" delta-bytes 9000

run NEXT_DIR="$T" "${GH_ENV[@]}" GH_RUN_300=failure GH_RUN_200=cancelled GH_RUN_100=failure MAX_INCREASE_KB=1
eq "no successful run is no base, exit 0" "$RC" 0
expect "and no delta" delta-bytes ""
expect "and no failure" failed ""
expect_log "and a warning" "no unexpired artifact 'bundle-report' from a successful run on main"

run NEXT_DIR="$T" "${GH_ENV[@]}" GH_ART="$WORK/none.json"
eq "an API failure is no base, exit 0" "$RC" 0
expect "an API failure has no delta" delta-bytes ""
expect_log "and warns" "there is no base"

run NEXT_DIR="$T" BASE_ARTIFACT=bundle-report REPO=o/r GH_ART="$ART"
expect "an unknown default branch is no base" delta-bytes ""
expect_log "and says why" "the default branch is unknown"

: > "$WORK/gh.log"
run NEXT_DIR="$T" "${GH_ENV[@]}" BASE_FILE="$BASE" GH_RUN_200=success GH_DL_200="$WORK/dl200.json"
expect "base-file wins over base-artifact" delta-bytes 15000
eq "and gh is never called" "$(wc -c < "$WORK/gh.log" | tr -d ' ')" 0

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
