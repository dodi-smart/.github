#!/usr/bin/env bash
# Measure a Next.js build's first-load JavaScript per route and in total, compare
# it with a base report, and write a short markdown comment and a JSON report.
#
# Sizes are gzip bytes (`gzip -c -9`) of each JS chunk. First load of a route is
# the chunks the router needs to render it: its own plus the shared ones. The
# total is the sum over every DISTINCT chunk any route loads, so a chunk shared
# by fifty routes counts once and only a change in what ships moves it. A kB is
# 1000 bytes, the unit `next build` prints.
#
# Where the chunks of a route come from, in the build output of Next.js 16:
#   pages router  build-manifest.json: `pages[route]` plus `pages["/_app"]`, which
#                 every page loads. Webpack and Turbopack write the same shape.
#   app router    `rootMainFiles` of build-manifest.json (the runtime and the
#                 shared chunks) plus the route's client chunks, from its
#                 server/app/**/page_client-reference-manifest.js. Both bundlers
#                 write one per page: `entryJSFiles` and `clientModules[].chunks`
#                 on Turbopack, `clientModules[].chunks` alone on webpack, where
#                 the chunk list holds chunk ids beside file names.
#   Next 15 and older: app-build-manifest.json already lists a route's chunks and
#                 is used when it exists. Next 16 no longer writes it.
# Turbopack also writes diagnostics/route-bundle-stats.json (per-route chunk
# paths and UNCOMPRESSED bytes), but only Turbopack, only recent 16.x, and
# uncompressed. It is deliberately not read: a base and a head built by different
# bundlers or versions must be measured the same way or the deltas mean nothing.
# Nothing here runs Node: the manifests are JSON, or a JSON object assigned to a
# global, which sed strips. Polyfills are left out: they are `nomodule`, so a
# browser that runs the app never loads them.
#
# No base is a warning and a comment without deltas, never a failure. A missing
# `.next` or a build with no routes is the build job's failure to report: warn,
# comment, exit 0 with empty outputs.
#
# Reads its inputs from the environment and writes total-bytes/delta-bytes/
# report-file/failed to $GITHUB_OUTPUT. It never exits non-zero for a breached
# limit, so the comment can be posted first; the action fails the job from
# `failed` afterwards. action.yml is a thin wrapper; test.sh runs this directly.
set -euo pipefail

: "${OUT:?}" "${REPORT_FILE:?}"
out="${GITHUB_OUTPUT:-/dev/stdout}"
NEXT_DIR="${NEXT_DIR:-.next}"
TOP="${TOP:-10}"
MAX_KB="${MAX_INCREASE_KB:-0}"
BASE_FILE="${BASE_FILE:-}"
BASE_ARTIFACT="${BASE_ARTIFACT:-}"

# A gate that silently ignores a bad setting is worse than one that stops.
if ! [[ "$TOP" =~ ^[0-9]+$ ]] || [ "$TOP" -lt 1 ]; then
  echo "::error::bundle-report: top must be a whole number of at least 1, got '$TOP'."
  exit 1
fi
if ! [[ "$MAX_KB" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "::error::bundle-report: max-increase-kb must be a number of 0 or more, got '$MAX_KB'."
  exit 1
fi

# An explicit template is required: BSD/macOS `mktemp -d` ignores TMPDIR without one.
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bundle-report.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

warn() { echo "::warning::bundle-report: $1"; }
valid() { jq -e . "$1" >/dev/null 2>&1; }
finish() { printf 'total-bytes=%s\ndelta-bytes=%s\nreport-file=%s\nfailed=%s\n' "$1" "$2" "$3" "$4" >> "$out"; }

# Nothing to measure: say so in the comment and leave the verdict to the build job.
nothing() {
  warn "$1"
  printf '### Bundle size\n\n%s\n' "$1" > "$OUT"
  finish "" "" "" ""
  exit 0
}

shown="${NEXT_DIR//\`/}"
[ -d "$NEXT_DIR" ] || nothing "\`$shown\` does not exist, so there is nothing to measure. A failed build is reported by the build job."

# ---- 1. Which chunks does each route load? ----------------------------------
# One `{route: [files]}` object per line; files are relative to NEXT_DIR.
ROUTES="$WORK/routes.ndjson"; : > "$ROUTES"
BM="$NEXT_DIR/build-manifest.json"
# Chunk names are written by the build, which is the pull request's code: drop
# anything that is not a JS file under the build directory.
# shellcheck disable=SC2016  # jq definitions, not shell
JS='def js: map(select(type == "string") | sub("^/?_next/"; "") | sub("\\?.*$"; "") | select(endswith(".js") and (contains("..") | not)));
    def route($map; $key): $map[$key] // ($key | sub("/page$"; "") | if . == "" then "/" else . end);'
ROOT='[]'
if [ -f "$BM" ] && valid "$BM"; then
  ROOT="$(jq -c "$JS"' (.rootMainFiles // []) | js' "$BM")"
  jq -c "$JS"' (.pages // {}) as $p | ($p["/_app"] // []) as $app
    | $p | del(.["/_app"], .["/_error"]) | map_values((. + $app) | js | unique)' "$BM" >> "$ROUTES"
elif [ -f "$BM" ]; then
  warn "$shown/build-manifest.json is not valid JSON, so the pages router and the shared chunks are missing."
fi

MAP="$(jq -c . "$NEXT_DIR/app-path-routes-manifest.json" 2>/dev/null || echo '{}')"
if [ -f "$NEXT_DIR/app-build-manifest.json" ] && valid "$NEXT_DIR/app-build-manifest.json"; then
  jq -c --argjson map "$MAP" "$JS"' (.pages // {}) | to_entries | map(select(.key | endswith("/page")))
    | map({key: route($map; .key), value: (.value | js | unique)}) | from_entries' \
    "$NEXT_DIR/app-build-manifest.json" >> "$ROUTES"
else
  while IFS= read -r f; do
    rel="${f#"$NEXT_DIR/server/app"}"; rel="${rel%/page_client-reference-manifest.js}"
    # The file assigns the manifest to a global, on line 2 (Turbopack) or on one
    # line after another statement (webpack). Keep what follows the `=`.
    if ! grep '__RSC_MANIFEST\[' "$f" | sed -E 's/^.*__RSC_MANIFEST\[[^]]*\] *= *//; s/;[[:space:]]*$//' \
        | jq -c --arg k "$rel/page" --argjson map "$MAP" --argjson root "$ROOT" "$JS"'
            {(route($map; $k)): (([(.entryJSFiles // {})[]?[]?] + [(.clientModules // {})[]?.chunks[]?] + $root) | js | unique)}' \
        >> "$ROUTES" 2>/dev/null; then
      warn "could not read ${f#"$NEXT_DIR"/}, so its route is missing."
    fi
  done < <(find "$NEXT_DIR/server/app" -name page_client-reference-manifest.js 2>/dev/null | sort)
fi

jq -s 'add // {}' "$ROUTES" > "$WORK/routes.json"
jq -e 'length > 0' "$WORK/routes.json" >/dev/null 2>&1 \
  || nothing "\`$shown\` holds no route manifests (build-manifest.json, app-build-manifest.json or server/app/**/page_client-reference-manifest.js), so there is nothing to measure."

# ---- 2. Size every distinct chunk once ---------------------------------------
SIZES="$WORK/sizes.tsv"
missing=0
while IFS= read -r f; do
  if [ -f "$NEXT_DIR/$f" ]; then
    # Arithmetic expansion drops the padding BSD wc puts before the count.
    printf '%s\t%s\n' "$f" "$(( $(gzip -c -9 < "$NEXT_DIR/$f" | wc -c) ))"
  else
    missing=$((missing + 1))
  fi
done < <(jq -r '[.[][]] | unique[]' "$WORK/routes.json") > "$SIZES"
[ "$missing" -eq 0 ] || warn "$missing chunk file(s) named in the manifests are not in $shown, so they are not counted."

jq -S --rawfile sizes "$SIZES" '
  ($sizes | split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: (.[1] | tonumber)}) | from_entries) as $sz
  | {version: 1,
     total: ([.[][]] | unique | map($sz[.] // empty) | add // 0),
     routes: map_values(map($sz[.] // empty) | add // 0)}' "$WORK/routes.json" > "$REPORT_FILE"
total="$(jq '.total' "$REPORT_FILE")"

# ---- 3. The base ------------------------------------------------------------
usable() { jq -e '(.routes | type == "object") and ([.total, .routes[]] | all(type == "number" and . == floor))' "$1" >/dev/null 2>&1; }

# The newest unexpired artifact of that name whose run on the default branch
# succeeded. `gh run download` unpacks it, so no unzip is needed.
base_from_artifact() {
  if [ -z "${DEFAULT_BRANCH:-}" ] || [ -z "${REPO:-}" ]; then
    warn "the default branch is unknown, so base-artifact '$BASE_ARTIFACT' was not fetched."; return 0
  fi
  local runs run dir f
  runs="$(gh api --method GET "repos/$REPO/actions/artifacts" -f name="$BASE_ARTIFACT" -F per_page=30 2>/dev/null \
    | jq -r --arg b "$DEFAULT_BRANCH" '[.artifacts[] | select(.expired == false and .workflow_run.head_branch == $b)]
        | sort_by(.created_at) | reverse | .[:5][] | .workflow_run.id')" || runs=""
  for run in $runs; do
    [ "$(gh api "repos/$REPO/actions/runs/$run" --jq .conclusion 2>/dev/null || true)" = success ] || continue
    dir="$WORK/base-$run"; mkdir -p "$dir"
    gh run download "$run" --repo "$REPO" -n "$BASE_ARTIFACT" -D "$dir" >/dev/null 2>&1 || continue
    f="$(find "$dir" -name '*.json' | head -n 1)"
    if [ -n "$f" ] && usable "$f"; then BASE="$f"; return 0; fi
  done
  warn "no unexpired artifact '$BASE_ARTIFACT' from a successful run on $DEFAULT_BRANCH could be fetched, so there is no base."
}

BASE=""
if [ -n "$BASE_FILE" ]; then
  if usable "$BASE_FILE"; then BASE="$BASE_FILE"; else warn "base-file '$BASE_FILE' is missing or is not a bundle report, so there is no base."; fi
elif [ -n "$BASE_ARTIFACT" ]; then
  base_from_artifact
fi

# ---- 4. The verdict and the comment -----------------------------------------
fmt() { awk -v m="$1" -v b="$2" 'BEGIN { f = (m == "s") ? "%+.2f kB" : "%.1f kB"; printf f, b / 1000 }'; }
pct() { awk -v d="$1" -v b="$2" 'BEGIN { if (b > 0) printf "%+.1f%%", 100 * d / b; else printf "n/a" }'; }

delta=""; failed=""; ROWS="$WORK/rows.tsv"
if [ -n "$BASE" ]; then
  base_total="$(jq '.total' "$BASE")"
  delta=$((total - base_total))
  # Added and removed routes count in full. Unchanged routes are left out.
  jq -rn --slurpfile cur "$REPORT_FILE" --slurpfile base "$BASE" '
    def abs: if . < 0 then -. else . end;
    $cur[0].routes as $n | $base[0].routes as $o
    | [$n, $o] | map(keys) | add | unique
    | map({r: ., n: $n[.], o: $o[.]} | .d = ((.n // 0) - (.o // 0)))
    | map(select(.d != 0)) | sort_by([-(.d | abs), .r])
    | .[] | [.r, .n, .o, .d] | @tsv' > "$ROWS"
  if awk -v d="$delta" -v m="$MAX_KB" 'BEGIN { exit !(m > 0 && d > m * 1000 + 1e-6) }'; then
    failed="total first-load JS grew by $(fmt s "$delta"), over the $MAX_KB kB limit"
  fi
else
  jq -r '.routes | to_entries | sort_by([-.value, .key]) | .[] | [.key, .value, "", ""] | @tsv' "$REPORT_FILE" > "$ROWS"
fi

{
  printf '### Bundle size\n\n'
  if [ -n "$BASE" ]; then
    printf '**Total first-load JS: %s**, %s (%s) against %s on the base.\n\n' \
      "$(fmt k "$total")" "$(fmt s "$delta")" "$(pct "$delta" "$base_total")" "$(fmt k "$base_total")"
  else
    printf '**Total first-load JS: %s.** There is no base report to compare with, so no deltas.\n\n' "$(fmt k "$total")"
  fi
  if [ ! -s "$ROWS" ]; then
    printf 'No route changed.\n'
  else
    awk -F'\t' -v top="$TOP" -v base="${BASE:+1}" '
      function kb(b)  { return sprintf("%.1f kB", b / 1000) }
      function skb(d) { return sprintf("%+.2f kB", d / 1000) }
      # Route names come from the build, so keep them from breaking the table.
      function clean(s) { gsub(/[|`\r]/, "", s); return s }
      BEGIN {
        if (base) { print "| Route | First load | Change |"; print "| --- | ---: | ---: |" }
        else      { print "| Route | First load |"; print "| --- | ---: |" }
      }
      NR <= top {
        r = "`" clean($1) "`"
        if (!base)          print "| " r " | " kb($2) " |"
        else if ($3 == "")  print "| " r " | " kb($2) " | new, " skb($4) " |"
        else if ($2 == "")  print "| " r " | removed | " skb($4) " |"
        else                print "| " r " | " kb($2) " | " skb($4) ($3 > 0 ? sprintf(" (%+.1f%%)", 100 * $4 / $3) : "") " |"
      }
      END { if (NR > top) printf "\n_%d more %s not shown._\n", NR - top, base ? "changed routes" : "routes" }
    ' "$ROWS"
  fi
  if [ -n "$failed" ]; then
    printf '\n**Over the limit:** %s.\n' "$failed"
  elif [ -z "$BASE" ] && awk -v m="$MAX_KB" 'BEGIN { exit !(m > 0) }'; then
    printf '\n_The %s kB limit was not checked: there is no base._\n' "$MAX_KB"
  fi
  printf '\n_First load is the gzip size of the chunks a route loads, its own and the shared ones. The total counts each chunk once. 1 kB is 1000 bytes._\n'
} > "$OUT"

finish "$total" "$delta" "$REPORT_FILE" "$failed"
