#!/usr/bin/env bash
# Regression tests for decompose.sh.
#
# The script is the only thing allowed to create issues from an agent's
# proposal, so what it accepts is the security boundary: whose block it reads,
# what it refuses, and that a refusal writes nothing. `run` is exercised against
# a stub `gh` that records every call.
#
# Run: actions/decompose/test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/decompose-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# A comment as the REST API returns it. $1 user type, $2 association, $3 body,
# $4 login: by default claude[bot] for a bot (the triage agent) and alice for a person.
comment() {
  local login="${4:-}"; [ -n "$login" ] || { [ "$1" = Bot ] && login='claude[bot]' || login=alice; }
  jq -n --arg t "$1" --arg a "$2" --arg b "$3" --arg l "$login" '{user:{type:$t,login:$l},author_association:$a,body:$b}'
}
# shellcheck disable=SC2016  # the backticks are a literal markdown fence
block() { printf 'Plan text.\n\n```children\n%s\n```\n' "$1"; }
GOOD='[{"repo":"web","type":"Feature","title":"feat: export as CSV","areas":["web","area:api"],"plan":"Add a CSV writer behind the export button."},
       {"type":"Chore","title":"chore: drop the old exporter","areas":[],"plan":"Remove the XLS path once CSV ships."}]'

parse_ok() {  # $1 name, $2 comments JSON, $3 jq assertion on the output
  local out
  if out="$(printf '%s' "$2" | "$HERE/decompose.sh" parse acme web 2>"$TMP/err")" \
     && printf '%s' "$out" | jq -e "$3" >/dev/null 2>&1; then ok "$1"
  else bad "$1 -> $(cat "$TMP/err") $out"; fi
}
parse_no() {  # $1 name, $2 comments JSON, $3 text the error must contain
  if printf '%s' "$2" | "$HERE/decompose.sh" parse acme web >"$TMP/out" 2>"$TMP/err"; then
    bad "$1 -> accepted: $(cat "$TMP/out")"
  elif [ "$?" = 2 ] && grep -qF -- "$3" "$TMP/err"; then ok "$1"
  else bad "$1 -> $(cat "$TMP/err")"; fi
}

echo "== whose block is read =="
parse_ok "the triage bot's block"          "[$(comment Bot NONE "$(block "$GOOD")")]" 'length == 2'
parse_ok "a member's corrected block"      "[$(comment User MEMBER "$(block "$GOOD")")]" 'length == 2'
parse_no "an outsider's block is ignored"  "[$(comment User NONE "$(block "$GOOD")")]" 'no ```children block'
parse_no "a contributor's block is ignored" "[$(comment User CONTRIBUTOR "$(block "$GOOD")")]" 'no ```children block'
one='[{"type":"Task","title":"task: one","plan":"Only one."}]'
parse_ok "the newest trusted block wins"   "[$(comment Bot NONE "$(block "$GOOD")"),$(comment User OWNER "$(block "$one")")]" 'length == 1 and .[0].title == "task: one"'
parse_ok "an outsider cannot override"     "[$(comment Bot NONE "$(block "$GOOD")"),$(comment User NONE "$(block "$one")")]" 'length == 2'
parse_ok "another bot cannot override triage" "[$(comment Bot NONE "$(block "$GOOD")"),$(comment Bot NONE "$(block "$one")" 'renovate[bot]')]" 'length == 2'
parse_ok "a bot with write access is still not triage" "[$(comment Bot NONE "$(block "$GOOD")"),$(comment Bot MEMBER "$(block "$one")" 'some-app[bot]')]" 'length == 2'
parse_no "only another bot's block: nothing"  "[$(comment Bot NONE "$(block "$GOOD")" 'github-actions[bot]')]" 'no ```children block'
if printf '%s' "[$(comment Bot NONE "$(block "$one")" 'dodi-app[bot]')]" | PROPOSER='dodi-app[bot]' "$HERE/decompose.sh" parse acme web >/dev/null 2>&1; then
  ok "PROPOSER names the triage login"; else bad "PROPOSER names the triage login"; fi
if printf '%s' "[$(comment Bot NONE "$(block "$one")")]" | PROPOSER='' "$HERE/decompose.sh" parse acme web >/dev/null 2>&1; then
  bad "an empty PROPOSER trusts no bot"; else ok "an empty PROPOSER trusts no bot"; fi
parse_no "no block at all"                 "[$(comment Bot NONE 'just a plan')]" 'no ```children block'
parse_no "no comments"                     '[]' 'no ```children block'
# shellcheck disable=SC2016  # literal markdown fence
parse_ok "a json fence is not a children block" "[$(comment Bot NONE "$(printf '```json\n%s\n```' "$one")"),$(comment Bot NONE "$(block "$GOOD")")]" 'length == 2'

echo "== normalisation =="
parse_ok "bare repo becomes owner/repo"    "[$(comment Bot NONE "$(block "$GOOD")")]" '.[0].repo == "acme/web" and .[0].local'
parse_ok "missing repo is the parent's"    "[$(comment Bot NONE "$(block "$GOOD")")]" '.[1].repo == "acme/web" and .[1].local'
parse_ok "areas gain the area: prefix"     "[$(comment Bot NONE "$(block "$GOOD")")]" '.[0].areas == ["area:api","area:web"]'
other='[{"repo":"acme/api","type":"Task","title":"task: api side","plan":"Expose the export endpoint."}]'
parse_ok "another org repo is not local"   "[$(comment Bot NONE "$(block "$other")")]" '.[0].repo == "acme/api" and (.[0].local | not)'
parse_ok "title and plan are trimmed"      "[$(comment Bot NONE "$(block '[{"type":"Task","title":"  t  ","plan":" p "}]')")]" '.[0].title == "t" and .[0].plan == "p"'

echo "== refusals: one bad entry refuses the whole list =="
parse_no "not JSON"                        "[$(comment Bot NONE "$(block '- a\n- b')")]" 'not a JSON array'
parse_no "an object, not a list"           "[$(comment Bot NONE "$(block '{"title":"x"}')")]" 'not a JSON array'
parse_no "empty list"                      "[$(comment Bot NONE "$(block '[]')")]" 'lists no children'
parse_no "unknown type"                    "[$(comment Bot NONE "$(block '[{"type":"Story","title":"x","plan":"y"}]')")]" 'type "Story"'
parse_no "an Initiative as a child"        "[$(comment Bot NONE "$(block '[{"type":"Initiative","title":"x","plan":"y"}]')")]" 'type "Initiative"'
parse_no "no title"                        "[$(comment Bot NONE "$(block '[{"type":"Task","title":" ","plan":"y"}]')")]" 'no title'
parse_no "no plan"                         "[$(comment Bot NONE "$(block '[{"type":"Task","title":"x"}]')")]" 'no plan line'
parse_no "a plan of two lines"             "[$(comment Bot NONE "$(block '[{"type":"Task","title":"x","plan":"a\nb"}]')")]" 'more than one line'
parse_no "a repo in another org"           "[$(comment Bot NONE "$(block '[{"repo":"evil/x","type":"Task","title":"x","plan":"y"}]')")]" 'outside acme'
parse_no "a repo that is not a name"       "[$(comment Bot NONE "$(block '[{"repo":"a b","type":"Task","title":"x","plan":"y"}]')")]" 'not a repository name'
parse_no "areas not a list"                "[$(comment Bot NONE "$(block '[{"type":"Task","title":"x","plan":"y","areas":"web"}]')")]" 'areas is not a list'
parse_no "duplicate titles"                "[$(comment Bot NONE "$(block '[{"type":"Task","title":"Same","plan":"y"},{"type":"Task","title":"same","plan":"z"}]')")]" 'share the title'
many="$(jq -nc '[range(21) | {type:"Task", title:"t\(.)", plan:"p"}]')"
parse_no "more than 20 children"           "[$(comment Bot NONE "$(block "$many")")]" 'more than 20'

echo "== body: the chore form's fields, in order =="
b="$("$HERE/decompose.sh" body 7 'Add a CSV writer.' 'feat: export')"
if printf '%s' "$b" | grep -q '^### What needs doing$' && printf '%s' "$b" | grep -q '^### Why now$' \
   && printf '%s' "$b" | grep -q '^### Blast radius$' && printf '%s' "$b" | grep -q 'Part of #7\.' \
   && printf '%s' "$b" | grep -q '^Add a CSV writer\.$'; then ok "body has the three headings, the plan and the parent"
else bad "body: $b"; fi

echo "== run, against a stub gh =="
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
# Records every call; answers from fixtures in $FIX.
echo "$*" >> "$FIX/calls"
args="$*"
case "$args" in
  *"/issues/7/comments?"*)    cat "$FIX/comments" ;;
  *"/issues/7/sub_issues?"*)  cat "$FIX/subs" ;;
  *"/issues/7/timeline?"*)    cat "$FIX/timeline" ;;
  *"/issues/7/sub_issues -F"*) [ -z "${FAIL_LINK:-}" ] || exit 1 ;;
  *"/labels?"*)               cat "$FIX/labels" ;;
  "api /repos/acme/web/issues/7 --jq"*) echo "$PARENT_TYPE" ;;
  "api graphql -f query=query"*) echo '[{"id":"F1","name":"Triage state","options":[{"id":"O1","name":"Needs triage"}]},{"id":"F2","name":"Source","options":[{"id":"O2","name":"Internal"}]}]' ;;
  "api -X POST /repos/acme/web/issues --input -")
     cat > "$FIX/created.$(wc -l < "$FIX/calls" | tr -d ' ')"
     echo '{"number":42,"id":4200,"node_id":"I_42"}' ;;
  *) : ;;
esac
GH
chmod +x "$STUB/gh"
run_case() {  # $1 parent type, $2 comments, $3 existing sub-issues JSON
  FIX="$TMP/fix"; rm -rf "$FIX"; mkdir -p "$FIX"; : > "$FIX/calls"
  printf '%s' "$2" > "$FIX/comments"; printf '%s' "$3" > "$FIX/subs"; printf '%s' "${4:-[]}" > "$FIX/timeline"
  echo '[{"name":"area:web"},{"name":"agent:triage"}]' > "$FIX/labels"
  PATH="$STUB:$PATH" FIX="$FIX" PARENT_TYPE="$1" REPO=acme/web NUMBER=7 GH_TOKEN=x \
    "$HERE/decompose.sh" run > "$FIX/out" 2>&1
  echo $? > "$FIX/rc"
}
creates() { grep -c '^api -X POST /repos/acme/web/issues --input -$' "$FIX/calls"; }

run_case Epic "[$(comment Bot NONE "$(block "$GOOD")")]" '[]'
if [ "$(creates)" = 2 ]; then ok "an Epic: both children created"; else bad "an Epic created $(creates)"; fi
if [ "$(grep -c 'sub_issues -F sub_issue_id=4200' "$FIX/calls")" = 2 ]; then ok "each is linked as a sub-issue"; else bad "sub-issue links: $(cat "$FIX/calls")"; fi
if [ "$(grep -c 'setIssueFieldValue' "$FIX/calls")" = 2 ]; then ok "each gets Triage state and Source"; else bad "fields not set"; fi
c="$(cat "$FIX"/created.* | jq -s -c 'map(select(.type == "Feature")) | first')"
if jq -e '.labels == ["area:web"] and .title == "feat: export as CSV"' <<<"$c" >/dev/null; then ok "only area labels the repo has are applied"
else bad "created payload: $c"; fi
if grep -q 'not in this repo, so not applied: area:api' "$FIX/out"; then ok "the missing area is reported, not invented"; else bad "missing area not reported"; fi
if grep -q '/issues/7/comments -f body=' "$FIX/calls"; then ok "the result is commented on the parent"; else bad "no report comment"; fi

run_case Initiative "[$(comment Bot NONE "$(block "$GOOD")")]" '[]'
if [ "$(creates)" = 2 ]; then ok "an Initiative may be split too"; else bad "Initiative created $(creates)"; fi

run_case Feature "[$(comment Bot NONE "$(block "$GOOD")")]" '[]'
if [ "$(creates)" = 0 ]; then ok "a Feature is never split"; else bad "Feature created $(creates)"; fi

run_case Epic "[$(comment Bot NONE "$(block "$GOOD")")]" '[{"title":"feat: export as CSV"}]'
if [ "$(creates)" = 1 ]; then ok "a second confirmation files no duplicate"; else bad "re-run created $(creates)"; fi

run_case Epic "[$(comment Bot NONE "$(block '[{"type":"Task","title":"x","plan":"y"},{"type":"Story","title":"z","plan":"y"}]')")]" '[]'
if [ "$(creates)" = 0 ] && [ "$(cat "$FIX/rc")" != 0 ]; then ok "one invalid entry: nothing created and the run fails"; else bad "invalid list created $(creates), rc $(cat "$FIX/rc")"; fi

run_case Epic "[$(comment Bot NONE "$(block "$other")")]" '[]'
if [ "$(creates)" = 0 ] && grep -qF 'belongs in' "$FIX/out" && grep -qF 'acme/api' "$FIX/out"; then ok "a child in another repo is listed, not created"; else bad "cross-repo: $(cat "$FIX/out")"; fi

echo "== a partial failure files no duplicate =="
FAIL_LINK=1 run_case Epic "[$(comment Bot NONE "$(block "$GOOD")")]" '[]'
if [ "$(cat "$FIX/rc")" != 0 ] && [ "$(creates)" = 1 ]; then ok "a failed link stops the run after one child"; else bad "failed link: rc $(cat "$FIX/rc"), created $(creates)"; fi
if grep -q '/issues/7/comments -f body=Stopped partway: could not link #42' "$FIX/calls" && grep -q 'created but NOT linked' "$FIX/calls"; then
  ok "the stop is reported, naming the unlinked child"; else bad "no partway report: $(grep comments "$FIX/calls")"; fi
if grep -q 'child-of=7' "$FIX"/created.*; then ok "the child's body carries its parent marker"; else bad "no child-of marker"; fi
# The re-run: the unlinked child is on the parent's timeline as a cross-reference.
xref() { jq -nc --arg t "$1" --argjson id "$2" --arg b "$3" --arg r "$4" \
  '{event:"cross-referenced", source:{issue:{title:$t, number:41, id:$id, node_id:"I_41", body:$b, repository:{full_name:$r}}}}'; }
run_case Epic "[$(comment Bot NONE "$(block "$GOOD")")]" '[]' "[$(xref 'feat: export as CSV' 999 'x <!-- dodi-decompose child-of=7 -->' acme/web)]"
if [ "$(creates)" = 1 ] && grep -q 'sub_issues -F sub_issue_id=999' "$FIX/calls"; then ok "the re-run links the unlinked child and files only the rest"
else bad "re-run: created $(creates), calls: $(grep sub_issue "$FIX/calls")"; fi
run_case Epic "[$(comment Bot NONE "$(block "$GOOD")")]" '[]' "[$(xref 'feat: export as CSV' 999 'x <!-- dodi-decompose child-of=8 -->' acme/web),$(xref 'feat: export as CSV' 998 'a person typed this' acme/web)]"
if [ "$(creates)" = 2 ]; then ok "a reference without this parent's marker is not a child"; else bad "foreign reference adopted: created $(creates)"; fi

DRY_RUN=1 run_case Epic "[$(comment Bot NONE "$(block "$GOOD")")]" '[]'
if ! grep -q -- '-X POST' "$FIX/calls" && ! grep -q setIssueFieldValue "$FIX/calls"; then ok "--dry-run writes nothing"
else bad "dry run wrote: $(grep -- '-X POST\|mutation' "$FIX/calls")"; fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
