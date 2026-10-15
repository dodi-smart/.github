#!/usr/bin/env bash
# Assert what the runner report writes, against recorded jobs-API shapes and a
# stubbed `gh` / `curl`. The cases that matter most are the ones where the API
# says no: the report must still name the runner and must never exit non-zero.
# BASH_BIN=/bin/bash runs report.sh under the macOS bash 3.2.
# shellcheck disable=SC2016  # the backticks are markdown, not command substitution
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASH_BIN="${BASH_BIN:-bash}"
T="$(mktemp -d "${TMPDIR:-/tmp}/runner-report.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
mkdir -p "$T/bin" "$T/curlbin"

# --- Recorded shapes (trimmed; ids, names and times are synthetic) -----------
# Page 1 of a paginated listing: another runner's job, and an earlier finished
# job on the SAME runner name, which must not be picked.
cat > "$T/page1.json" <<'JSON'
{"total_count":3,"jobs":[
 {"id":1001,"run_id":900,"run_attempt":1,"name":"pick","status":"completed","conclusion":"success",
  "created_at":"2026-10-15T14:00:00Z","started_at":"2026-10-15T14:00:02Z","completed_at":"2026-10-15T14:00:20Z",
  "runner_id":7,"runner_name":"GitHub Actions 1000000001","runner_group_name":"GitHub Actions",
  "labels":["ubuntu-latest"],"workflow_name":"PR Checks"},
 {"id":1002,"run_id":900,"run_attempt":1,"name":"earlier","status":"completed","conclusion":"success",
  "created_at":"2026-10-15T13:00:00Z","started_at":"2026-10-15T13:50:00Z","completed_at":"2026-10-15T13:55:00Z",
  "runner_id":11,"runner_name":"hetzner-linux-03","runner_group_name":"Default",
  "labels":["self-hosted","Linux","X64","hetzner","light"],"workflow_name":"PR Checks"}
]}
JSON
# Page 2: this job, in progress, on the self-hosted runner. Queued 12s.
cat > "$T/page2.json" <<'JSON'
{"total_count":3,"jobs":[
 {"id":1003,"run_id":900,"run_attempt":1,"name":"checks","status":"in_progress","conclusion":null,
  "created_at":"2026-10-15T14:00:20Z","started_at":"2026-10-15T14:00:32Z","completed_at":null,
  "runner_id":11,"runner_name":"hetzner-linux-03","runner_group_name":"Default",
  "labels":["self-hosted","Linux","X64","hetzner","light"],"workflow_name":"PR Checks"}
]}
JSON
cat "$T/page1.json" "$T/page2.json" > "$T/selfhosted.json"

cat > "$T/hosted.json" <<'JSON'
{"total_count":1,"jobs":[
 {"id":2001,"run_id":901,"run_attempt":1,"name":"build","status":"in_progress","conclusion":null,
  "created_at":"2026-10-15T15:00:00Z","started_at":"2026-10-15T15:00:03Z","completed_at":null,
  "runner_id":9,"runner_name":"GitHub Actions 1000000042","runner_group_name":"GitHub Actions",
  "labels":["ubuntu-latest"],"workflow_name":"PR Checks"}
]}
JSON

# A whole run for run mode: finished self-hosted and hosted jobs, a skipped job
# (no runner, started_at == created_at), a name with a pipe, and the job running now.
cat > "$T/run.json" <<'JSON'
{"total_count":5,"jobs":[
 {"id":3001,"name":"pick","status":"completed","conclusion":"success",
  "created_at":"2026-10-15T16:00:00Z","started_at":"2026-10-15T16:00:02Z","completed_at":"2026-10-15T16:00:20Z",
  "runner_name":"GitHub Actions 1000000007","labels":["ubuntu-latest"]},
 {"id":3002,"name":"checks (lint | types)","status":"completed","conclusion":"failure",
  "created_at":"2026-10-15T16:00:20Z","started_at":"2026-10-15T16:01:05Z","completed_at":"2026-10-15T16:03:35Z",
  "runner_name":"m4pro-vm-2","labels":["self-hosted","macOS","ARM64","m4pro"]},
 {"id":3003,"name":"deploy","status":"completed","conclusion":"skipped",
  "created_at":"2026-10-15T16:03:36Z","started_at":"2026-10-15T16:03:36Z","completed_at":"2026-10-15T16:03:36Z",
  "runner_name":null,"labels":["ubuntu-latest"]},
 {"id":3004,"name":"report","status":"in_progress","conclusion":null,
  "created_at":"2026-10-15T16:03:36Z","started_at":"2026-10-15T16:03:40Z","completed_at":null,
  "runner_name":"rpi5-04","labels":["self-hosted","Linux","ARM64","rpi5"]}
]}
JSON

# --- Stubs --------------------------------------------------------------------
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_LOG"
if [ -n "${GH_FAIL:-}" ]; then echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; fi
cat "$FIXTURE"
STUB
cat > "$T/curlbin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
cat > /dev/null   # the config on stdin carries the token
url="${*: -1}"
case "$url" in *page=1) cat "$FIXTURE" ;; *) echo '{"total_count":0,"jobs":[]}' ;; esac
STUB
chmod +x "$T/bin/gh" "$T/curlbin/curl"
# A PATH with curl and jq but no gh, for the fallback.
ln -s "$(command -v jq)" "$T/curlbin/jq"
for t in tr sed cat printf bash env; do p="$(command -v "$t")"; [ -n "$p" ] && ln -sf "$p" "$T/curlbin/$t" 2>/dev/null; done

# --- Harness ------------------------------------------------------------------
# run_case <fixture> [VAR=value ...]; leaves stdout, summary, outputs, log, exit code.
run_case() {
  local fixture="$1"; shift
  : > "$T/summary.md"; : > "$T/out.txt"; : > "$T/log.txt"
  env -i HOME="$T" PATH="${CASE_PATH:-$T/bin:$PATH}" TMPDIR="$T" \
    GITHUB_STEP_SUMMARY="$T/summary.md" GITHUB_OUTPUT="$T/out.txt" STUB_LOG="$T/log.txt" \
    FIXTURE="$fixture" REPO=example-org/example-repo RUN_ID=900 RUN_ATTEMPT=1 GH_TOKEN=t0ken \
    "$@" "$BASH_BIN" "$HERE/report.sh" > "$T/stdout.txt" 2>"$T/stderr.txt"
  rc=$?
}

ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
has() { # <file> <fixed string> <name>
  if grep -qF -- "$2" "$T/$1"; then ok "$3"; else no "$3 (no '$2' in $1)"; sed 's/^/       | /' "$T/$1"; fi
}
lacks() {
  if grep -qF -- "$2" "$T/$1"; then no "$3 (found '$2' in $1)"; else ok "$3"; fi
}
exit0() { if [ "$rc" = 0 ]; then ok "$1: exits 0"; else no "$1: exit $rc"; fi; }

echo "self-hosted job, jobs on two pages"
run_case "$T/selfhosted.json" RUNNER_NAME=hetzner-linux-03 RUNNER_OS=Linux RUNNER_ARCH=X64 \
  RUNNER_ENVIRONMENT=self-hosted SELECTOR=light RUNNER_IMAGE_TAG=2026.10.1 RUNNER_IMAGE_REVISION=abc1234 MODE=job
exit0 "self-hosted"
has stdout.txt '::notice title=Runner::hetzner-linux-03 (hetzner) queued 12s' "notice names runner, pool, queue"
has summary.md '| Runner | `hetzner-linux-03` |' "summary: runner"
has summary.md '| Pool | hetzner |' "summary: pool"
has summary.md '| Labels | `self-hosted`, `Linux`, `X64`, `hetzner`, `light` |' "summary: labels from the job"
has summary.md '| OS / arch | Linux / X64 |' "summary: os / arch"
has summary.md '| Selector | `light` |' "summary: selector"
has summary.md '| Image | 2026.10.1 @ abc1234 |' "summary: image tag and revision"
has summary.md '| Queued | 12s |' "summary: queued 12s from the in-progress job, not the finished one"
has out.txt 'runner=hetzner-linux-03' "output: runner"
has out.txt 'pool=hetzner' "output: pool"
has out.txt 'queued-seconds=12' "output: queued-seconds"
has out.txt 'markdown<<' "output: markdown block"
has out.txt '| Pool | hetzner |' "output: markdown holds the table"
has log.txt 'attempts/1/jobs?per_page=100' "asks for the attempt's jobs, 100 per page"
has log.txt '--paginate' "paginates"

echo "hosted job, nothing optional set"
run_case "$T/hosted.json" RUNNER_NAME="GitHub Actions 1000000042" RUNNER_OS=Linux RUNNER_ARCH=X64 \
  RUNNER_ENVIRONMENT=github-hosted RUN_ID=901
exit0 "hosted"
has stdout.txt '::notice title=Runner::GitHub Actions 1000000042 (hosted) queued 3s' "notice: hosted, 3s"
has summary.md '| Image | n/a |' "image is n/a without the env"
lacks summary.md 'Selector' "no selector row when none was asked for"

echo "API says no (403)"
run_case "$T/hosted.json" GH_FAIL=1 RUNNER_NAME=beelink-2 RUNNER_OS=Linux RUNNER_ARCH=ARM64 RUNNER_ENVIRONMENT=self-hosted
exit0 "403"
has stdout.txt '::notice title=Runner::beelink-2 (beelink) queued n/a' "notice still written, pool from the runner name"
has summary.md '| Runner | `beelink-2` |' "summary still names the runner"
has summary.md '| OS / arch | Linux / ARM64 |' "summary still has os / arch"
has summary.md '| Queued | n/a (needs actions: read) |' "queued says what is missing"
has out.txt 'queued-seconds=' "queued-seconds output is set, empty"
lacks out.txt 'queued-seconds=0' "queued-seconds is not a fake zero"

echo "no token, no API call"
run_case "$T/hosted.json" GH_TOKEN= RUNNER_NAME=rpi5-1 RUNNER_OS=Linux RUNNER_ARCH=ARM64 RUNNER_ENVIRONMENT=self-hosted
exit0 "no token"
has summary.md '| Queued | n/a (no token) |' "no token is named"
if [ -s "$T/log.txt" ]; then no "no API call without a token"; else ok "no API call without a token"; fi

echo "self-hosted runner with no pool label, job not in the listing"
run_case "$T/hosted.json" RUNNER_NAME=somebox RUNNER_OS=Linux RUNNER_ARCH=X64 RUNNER_ENVIRONMENT=self-hosted
exit0 "job not found"
has summary.md '| Pool | self-hosted |' "unlabelled self-hosted is not called hosted"
has summary.md '| Queued | n/a (job not found) |' "job not found is named"

echo "macOS-shaped runner whose job is already finished: pool comes from the name"
run_case "$T/run.json" RUNNER_NAME=m4pro-vm-2 RUNNER_OS=macOS RUNNER_ARCH=ARM64 RUNNER_ENVIRONMENT=self-hosted
exit0 "macOS (finished job is not in progress)"
has summary.md '| Pool | m4pro |' "pool from the name when the job is not found"

echo "no gh on PATH: curl fallback"
CASE_PATH="$T/curlbin" run_case "$T/selfhosted.json" RUNNER_NAME=hetzner-linux-03 RUNNER_OS=Linux RUNNER_ARCH=X64
exit0 "curl, unparsable page"
has summary.md '| Queued | n/a (needs actions: read) |' "a bad curl response degrades, never fails"
# The two-object fixture is gh's --paginate shape, not one curl page; use page 2.
CASE_PATH="$T/curlbin" run_case "$T/page2.json" RUNNER_NAME=hetzner-linux-03 RUNNER_OS=Linux RUNNER_ARCH=X64
exit0 "curl"
has summary.md '| Queued | 12s |' "curl path finds the job"
if grep -q t0ken "$T/log.txt"; then no "token kept out of curl's arguments"; else ok "token kept out of curl's arguments"; fi

echo "run mode"
run_case "$T/run.json" MODE=run RUNNER_NAME=rpi5-04 RUNNER_OS=Linux RUNNER_ARCH=ARM64 RUNNER_ENVIRONMENT=self-hosted
exit0 "run mode"
has summary.md '### Where it ran' "heading"
has summary.md '| Job | Runner | Pool | Queued | Duration | Result |' "header"
has summary.md '| pick | `GitHub Actions 1000000007` | hosted | 2s | 18s | success |' "hosted row"
has summary.md '| checks (lint \| types) | `m4pro-vm-2` | m4pro | 45s | 150s | failure |' "self-hosted row, pipe escaped"
has summary.md '| deploy | - | - | - | 0s | skipped |' "skipped job has no runner or queue"
has summary.md '| report | `rpi5-04` | rpi5 | 4s | running | in_progress |' "current job is running"
has out.txt 'queued-seconds=4' "run mode still sets the job outputs"
has out.txt '| Job | Runner | Pool |' "run mode markdown output"

echo "run mode, API says no"
run_case "$T/run.json" MODE=run GH_FAIL=1 RUNNER_NAME=rpi5-04 RUNNER_OS=Linux RUNNER_ARCH=ARM64
exit0 "run mode 403"
has summary.md 'n/a (needs actions: read)' "run table says what is missing"

echo "unknown mode"
run_case "$T/hosted.json" MODE=bogus RUNNER_NAME="GitHub Actions 1000000042" RUN_ID=901
exit0 "unknown mode"
has stdout.txt "::warning title=Runner::runner-report: unknown mode 'bogus'" "warns, does not fail"
has summary.md '### Runner' "falls back to job mode"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
