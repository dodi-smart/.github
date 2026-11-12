#!/usr/bin/env bash
# Assert when request.sh applies agent:review: only the org App's verdict on the
# head stops it. `gh` is a stub that answers the statuses list from
# $STUB_STATUSES and records the label call.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/request-review-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
expect() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_CALLS"
case "$*" in
  *labels*) ;;
  */statuses*) jq -c '.[]' <<<"$STUB_STATUSES" ;;
esac
STUB
chmod +x "$WORK/bin/gh"

# rr STATUSES [VAR=value ...] -> requested
rr() {
  : > "$WORK/calls"; : > "$WORK/out"
  local s="$1"; shift
  env -i PATH="$WORK/bin:$PATH" STUB_CALLS="$WORK/calls" STUB_STATUSES="$s" GITHUB_OUTPUT="$WORK/out" \
    GH_TOKEN=t REPO=o/r PR=7 SHA=abc APP_BOT='app[bot]' "$@" "$HERE/request.sh" > /dev/null 2>&1
  sed -n 's/^requested=//p' "$WORK/out" | tail -n 1
}
v() { jq -cn --arg s "$1" --arg by "$2" '{context: "review / verdict", state: $s, creator: $by, id: 1}'; }
labelled() { grep -q 'labels\[\]=agent:review' "$WORK/calls"; }

expect "no verdict: a review is requested"        test "$(rr '[]')" = true
expect "and agent:review is applied"              labelled
expect "the App's verdict: nothing is requested"  test "$(rr "[$(v success 'app[bot]')]")" = false
expect "and no label is applied"                  bash -c '! grep -q labels "$1"' _ "$WORK/calls"
expect "a pending App verdict is a review in flight" test "$(rr "[$(v pending 'app[bot]')]")" = false
expect "a verdict from anyone else is no review: one is requested" test "$(rr "[$(v success mallory)]")" = true
expect "and agent:review is applied"              labelled
expect "another context from the App is no verdict" \
  test "$(rr '[{"context":"judge / verdict","state":"success","creator":"app[bot]","id":1}]')" = true
expect "with no App login no verdict counts"      test "$(rr "[$(v success 'app[bot]')]" APP_BOT='')" = true
expect "with no App token nothing is requested"   test "$(rr '[]' GH_TOKEN='')" = false
expect "and gh is never called"                   test ! -s "$WORK/calls"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
