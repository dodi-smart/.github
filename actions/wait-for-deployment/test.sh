#!/usr/bin/env bash
# Assert what the wait proves: it passes only for a deployment the HOST made of
# the checked-out commit (or the commit before a `[skip ci]` release commit),
# fails on a failed one and on timeout, and never counts the deployment the
# calling job's own environment creates. The API is faked with a `gh` on PATH
# and the sha route with a `curl`, so nothing here needs a network.
# shellcheck disable=SC2015
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/wait.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wait-for-deployment-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

# --- a repo with a merge commit and a `[skip ci]` release commit on top ------
REPO_DIR="$WORK/repo"
mkdir "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email t@example.com
git -C "$REPO_DIR" config user.name t
git -C "$REPO_DIR" config commit.gpgsign false
git -C "$REPO_DIR" commit -q --allow-empty -m "feat: something"
MERGE=$(git -C "$REPO_DIR" rev-parse HEAD)
git -C "$REPO_DIR" commit -q --allow-empty -m "chore(release): 1.2.3 [skip ci]"
RELEASE=$(git -C "$REPO_DIR" rev-parse HEAD)

# --- fakes -------------------------------------------------------------------
FIX="$WORK/fix"; mkdir "$FIX" "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
# Deployments come from deployments-<sha>.json. Each poll of a deployment's
# statuses moves on to the next statuses-<id>.<n>.json, and stays on the last.
[ -z "${FAKE_GH_FAIL:-}" ] || { echo "HTTP 403" >&2; exit 1; }
path="$2"
case "$path" in
  *"/statuses"*)
    id="${path#*/deployments/}"; id="${id%%/*}"
    n=$(cat "$FAKE_FIX/n-$id" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_FIX/n-$id"
    f="$FAKE_FIX/statuses-$id.$n.json"
    [ -f "$f" ] || f=$(ls "$FAKE_FIX"/statuses-"$id".*.json | sort -V | tail -1)
    cat "$f" ;;
  *)
    sha="${path#*sha=}"; sha="${sha%%&*}"
    cat "$FAKE_FIX/deployments-$sha.json" 2>/dev/null || echo '[]' ;;
esac
GH
cat > "$WORK/bin/curl" <<'CURL'
#!/usr/bin/env bash
cat "$FAKE_FIX/route-body" 2>/dev/null
CURL
chmod +x "$WORK/bin/gh" "$WORK/bin/curl"

# deployment <id> <sha> <creator> <app slug or null> <created_at>
dep() {
  local app='null'
  [ "$4" = null ] || app="{\"slug\":\"$4\"}"
  printf '{"id":%s,"sha":"%s","environment":"staging","created_at":"%s","creator":{"login":"%s"},"performed_via_github_app":%s}' \
    "$1" "$2" "$5" "$3" "$app"
}
# status <state> [url]
status() { printf '[{"state":"%s","environment_url":"%s","target_url":"%s"}]' "$1" "${2:-}" "${2:-}"; }

reset() { rm -rf "$FIX"; mkdir "$FIX"; OUT="$WORK/out"; : > "$OUT"; }

# run <name> <want exit> <extra env...>; the last output is left in $LOG and $OUT
run() {
  local name="$1" want="$2" code; shift 2
  LOG="$WORK/log"
  ( cd "$REPO_DIR" && env PATH="$WORK/bin:$PATH" FAKE_FIX="$FIX" GITHUB_OUTPUT="$OUT" REPO=o/r \
      INTERVAL=0 TIMEOUT_MINUTES=1 "$@" "$SCRIPT" ) > "$LOG" 2>&1
  code=$?
  if [ "$code" = "$want" ]; then ok "$name"; else bad "$name" "exit $code, wanted $want: $(tail -3 "$LOG" | tr '\n' '|')"; fi
}
out_has() { grep -qxF "$2" "$OUT" && ok "$1" || bad "$1" "no '$2' in: $(tr '\n' '|' < "$OUT")"; }

# --- the pure pieces ----------------------------------------------------------
cands=$(cd "$REPO_DIR" && "$SCRIPT" --candidates | tr '\n' ' ')
[ "$cands" = "$RELEASE $MERGE " ] && ok "a [skip ci] commit also counts its parent" || bad "candidates of a release commit" "$cands"
git -C "$REPO_DIR" checkout -q --detach "$MERGE"
cands=$(cd "$REPO_DIR" && "$SCRIPT" --candidates | tr '\n' ' ')
[ "$cands" = "$MERGE " ] && ok "an ordinary commit counts only itself" || bad "candidates of an ordinary commit" "$cands"
git -C "$REPO_DIR" checkout -q --detach "$RELEASE"

picked=$( { printf '['; dep 1 "$RELEASE" azlekov github-actions 2026-09-11T07:28:58Z; printf ','
  dep 2 "$MERGE" 'host[bot]' null 2026-09-11T07:28:04Z; printf ',';
  dep 3 "$MERGE" 'host[bot]' null 2026-09-11T07:20:00Z; printf ']'; } | "$SCRIPT" --pick | jq -r .id)
[ "$picked" = 2 ] && ok "pick skips the job's own deployment and takes the newest" || bad "pick" "$picked"
[ -z "$(echo '[]' | "$SCRIPT" --pick)" ] && ok "pick of nothing is nothing" || bad "pick of nothing" "not empty"
[ "$(status success https://x.example | "$SCRIPT" --state)" = $'success\thttps://x.example' ] \
  && ok "state reads the newest status and its url" || bad "state" "$(status success https://x.example | "$SCRIPT" --state)"
[ "$(echo '[]' | "$SCRIPT" --state)" = $'none\t' ] && ok "no statuses yet reads as none" || bad "state of nothing" "?"

# --- the wait -----------------------------------------------------------------
reset
echo "[$(dep 2 "$MERGE" 'host[bot]' null 2026-09-11T07:28:04Z)]" > "$FIX/deployments-$MERGE.json"
status in_progress > "$FIX/statuses-2.1.json"; status queued > "$FIX/statuses-2.2.json"
status success https://d.example > "$FIX/statuses-2.3.json"
run "waits through in-progress, then passes on success" 0 ENVIRONMENT=staging
out_has "  reports the deployment id" "deployment-id=2"
out_has "  reports the sha it proved" "sha=$MERGE"
out_has "  reports the deployment url" "url=https://d.example"

reset
echo "[$(dep 1 "$RELEASE" azlekov github-actions 2026-09-11T07:28:58Z)]" > "$FIX/deployments-$RELEASE.json"
status success > "$FIX/statuses-1.1.json"
run "the job's own deployment never counts (times out)" 1 ENVIRONMENT=staging TIMEOUT_MINUTES=0

reset
run "no deployment at all times out" 1 ENVIRONMENT=staging TIMEOUT_MINUTES=0

reset
echo "[$(dep 2 "$MERGE" 'host[bot]' null 2026-09-11T07:28:04Z)]" > "$FIX/deployments-$MERGE.json"
status failure > "$FIX/statuses-2.1.json"
run "a failed deployment fails at once" 1 ENVIRONMENT=staging
grep -q "as failure" "$LOG" && ok "  and says so" || bad "  and says so" "$(cat "$LOG")"

reset
run "an API that refuses fails, not waits" 1 ENVIRONMENT=staging FAKE_GH_FAIL=1
grep -q "deployments: read" "$LOG" && ok "  and names the permission" || bad "  and names the permission" "$(cat "$LOG")"

# --- the sha route --------------------------------------------------------------
reset
echo "{\"sha\":\"${MERGE:0:7}\"}" > "$FIX/route-body"
run "a route reporting the commit passes" 0 SHA_URL=https://x.example/api/version
out_has "  reports the sha" "sha=$MERGE"

reset
echo '{"sha":"0000000"}' > "$FIX/route-body"
run "a route reporting another commit times out" 1 SHA_URL=https://x.example/api/version TIMEOUT_MINUTES=0

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
