#!/usr/bin/env bash
# Regression tests for set-issue-fields.sh.
#
# A fake `gh` on PATH stands in for the real API: it recognises the shapes of
# query this script sends (the issue-fields catalog, the issue node id, the
# setIssueFieldValue mutation) and records every REST call it makes, so a test
# can assert what was sent without touching a real repository.
#
# Run: actions/set-issue-fields/test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# An explicit template: BSD/macOS `mktemp -d` with no template ignores
# TMPDIR. This org runs macOS runners, so that difference is not hypothetical.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/set-issue-fields-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# Fake `gh`, just enough of it to test set-issue-fields.sh against.
set -euo pipefail
LOG="${FAKE_GH_LOG:?FAKE_GH_LOG must be set}"

for a in "$@"; do
  case "$a" in
    */orgs/*) echo "403 Resource not accessible by integration" >&2; exit 1 ;;
  esac
done

catalog='{"data":{"repository":{"issueFields":{"nodes":[
  {"id":"IFSS_p","name":"Priority","options":[
    {"id":"IFSSO_p_urgent","name":"Urgent"},
    {"id":"IFSSO_p_high","name":"High"},
    {"id":"IFSSO_p_medium","name":"Medium"},
    {"id":"IFSSO_p_low","name":"Low"}]},
  {"id":"IFSS_e","name":"Effort","options":[
    {"id":"IFSSO_e_high","name":"High"},
    {"id":"IFSSO_e_medium","name":"Medium"},
    {"id":"IFSSO_e_low","name":"Low"}]},
  {"id":"IFSS_r","name":"Risk","options":[
    {"id":"IFSSO_r_low","name":"Low"},
    {"id":"IFSSO_r_medium","name":"Medium"},
    {"id":"IFSSO_r_high","name":"High"},
    {"id":"IFSSO_r_critical","name":"Critical"}]},
  {"id":"IFSS_t","name":"Triage state","options":[
    {"id":"IFSSO_t_new","name":"New"},
    {"id":"IFSSO_t_ready","name":"Ready for agent"},
    {"id":"IFSSO_t_inprogress","name":"In progress"},
    {"id":"IFSSO_t_blocked","name":"Blocked"},
    {"id":"IFSSO_t_done","name":"Done"},
    {"id":"IFSSO_t_wontfix","name":"Won'"'"'t fix"}]}
]}}}}'

if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
  shift 2
  query=""
  jqfilter=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -f) kv="$2"; k="${kv%%=*}"; v="${kv#*=}"; [ "$k" = "query" ] && query="$v"; shift 2 ;;
      -F) shift 2 ;;
      --jq) jqfilter="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # The mutation itself contains the substring "issueFields" (its own
  # `issueFields:[...]` argument), so it must be matched BEFORE the catalog
  # query pattern below, or every mutation call is misread as a catalog read.
  case "$query" in
    *setIssueFieldValue*)
      printf '%s\n' "$query" >> "$LOG"
      resp='{"data":{"setIssueFieldValue":{"clientMutationId":null}}}' ;;
    *issueFields*) resp="$catalog" ;;
    *'issue(number'*) resp='{"data":{"repository":{"issue":{"id":"I_kw1"}}}}' ;;
    *) resp='{"data":{}}' ;;
  esac

  if [ -n "$jqfilter" ]; then jq -r "$jqfilter" <<<"$resp"; else echo "$resp"; fi
  exit 0
fi

if [ "${1:-}" = "api" ]; then
  shift
  method="GET"; path=""; fields=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -f) fields="$fields $2"; shift 2 ;;
      --silent) shift ;;
      --jq) shift 2 ;;
      *) [ -z "$path" ] && path="$1"; shift ;;
    esac
  done
  printf '%s %s%s\n' "$method" "$path" "$fields" >> "$LOG"
  echo '{}'
  exit 0
fi

echo "fake gh: unhandled invocation: $*" >&2
exit 1
FAKE_GH
chmod +x "$TMP/bin/gh"

SCRIPT="$HERE/set-issue-fields.sh"
pass=0; fail=0

run() {
  : > "$TMP/log"
  FAKE_GH_LOG="$TMP/log" PATH="$TMP/bin:$PATH" "$SCRIPT" "$@" > "$TMP/stdout" 2> "$TMP/stderr"
  echo $?
}

check() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok   $desc"
    pass=$((pass+1))
  else
    echo "  FAIL $desc (got '$got' want '$want')"
    fail=$((fail+1))
  fi
}

echo "== single select fields, one mutation =="
rc=$(run --repo acme/widgets --issue 5 --field "Priority=High" --field "Risk=Low")
check "two fields: exit 0" "$rc" "0"
mutation="$(cat "$TMP/log")"
check "mutation carries fieldId" "$(grep -c 'fieldId:"IFSS_p"' <<<"$mutation")" "1"
check "mutation carries the second field too" "$(grep -c 'fieldId:"IFSS_r"' <<<"$mutation")" "1"
check "mutation is a single call" "$(grep -c 'setIssueFieldValue' "$TMP/log")" "1"
check "issueFieldId never appears" "$(grep -c 'issueFieldId' <<<"$mutation")" "0"

echo "== unknown option =="
rc=$(run --repo acme/widgets --issue 5 --field "Priority=Nonsense")
check "unknown option: exit 1" "$rc" "1"
check "lists valid options" "$(grep -c 'Urgent' "$TMP/stderr")" "1"

echo "== unknown field =="
rc=$(run --repo acme/widgets --issue 5 --field "NoSuchField=High")
check "unknown field: exit 1" "$rc" "1"
check "reports the field name" "$(grep -c 'NoSuchField' "$TMP/stderr")" "1"

echo "== org endpoint is never called =="
rc=$(run --repo acme/widgets --issue 5 --field "Priority=High" --type Bug --add-label area:x --remove-label area:y)
check "full run: exit 0" "$rc" "0"
check "log never mentions /orgs/" "$(grep -c '/orgs/' "$TMP/log" || true)" "0"

echo "== issue type =="
rc=$(run --repo acme/widgets --issue 7 --type Bug)
check "type: exit 0" "$rc" "0"
check "records a PATCH with type=Bug" "$(grep -c 'PATCH /repos/acme/widgets/issues/7 type=Bug' "$TMP/log")" "1"

echo "== remove label =="
rc=$(run --repo acme/widgets --issue 7 --remove-label "area:x")
check "remove-label: exit 0" "$rc" "0"
check "records a DELETE with area%3Ax" "$(grep -c 'DELETE /repos/acme/widgets/issues/7/labels/area%3Ax' "$TMP/log")" "1"

echo "== add label =="
rc=$(run --repo acme/widgets --issue 7 --add-label "area:y")
check "add-label: exit 0" "$rc" "0"
check "records a POST with labels[]=area:y" "$(grep -c 'POST /repos/acme/widgets/issues/7/labels labels\[\]=area:y' "$TMP/log")" "1"

echo "== from-decisions =="
cat > "$TMP/decisions.json" <<'JSON'
{
  "task": "triage",
  "mode": "active",
  "fields": [
    {"name": "Priority", "value": "High", "confidence": 0.9, "act": true},
    {"name": "Effort", "value": "Low", "confidence": 0.4, "act": false}
  ],
  "type": {"value": "Bug", "confidence": 0.95, "act": true},
  "labels": {"add": ["area:z"], "remove": []}
}
JSON
rc=$(run --repo acme/widgets --issue 9 --from-decisions "$TMP/decisions.json")
check "from-decisions: exit 0" "$rc" "0"
check "sets the act:true field" "$(grep -c 'fieldId:"IFSS_p"' "$TMP/log")" "1"
check "does not set the act:false field" "$(grep -c 'fieldId:"IFSS_e"' "$TMP/log")" "0"
check "sets the act:true type" "$(grep -c 'PATCH /repos/acme/widgets/issues/9 type=Bug' "$TMP/log")" "1"
check "adds the decided label" "$(grep -c 'POST /repos/acme/widgets/issues/9/labels labels\[\]=area:z' "$TMP/log")" "1"

echo "== nothing to do =="
rc=$(run --repo acme/widgets --issue 9)
check "nothing to do: exit 0" "$rc" "0"
check "prints nothing to set" "$(grep -c 'nothing to set' "$TMP/stdout")" "1"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
