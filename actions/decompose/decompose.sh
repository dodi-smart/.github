#!/usr/bin/env bash
# Create the child issues an Epic's triage proposed, after a person confirmed.
#
# Triage may PROPOSE children; it never creates one. It writes them into a
# fenced block on the parent:
#
#   ```children
#   [
#     {"repo": "web", "type": "Feature", "title": "feat: export as CSV",
#      "areas": ["area:web"], "plan": "Add a CSV writer behind the export button."}
#   ]
#   ```
#
# A person confirms by applying `agent:decompose`. This script then reads the
# newest trusted block, checks every entry before it writes anything, and
# creates each child as a well-formed issue: a type, the area labels
# that exist in the repo, a body in issue-form shape, `Triage state = Needs
# triage` and `Source = Internal`, linked to the parent as a sub-issue.
#
# Subcommands:
#   parse OWNER REPO        stdin: the parent's comments (REST JSON array).
#                           stdout: the checked children, one JSON array.
#                           Exit 2, with every problem on stderr, when there is
#                           no block or any entry is invalid.
#   body PARENT PLAN TITLE  stdout: the child's body.
#   run                     The whole thing against the API. Env: REPO
#                           (owner/name), NUMBER (the parent), GH_TOKEN,
#                           DRY_RUN=1 to print and write nothing.
#
# Env for parse and run: PROPOSER, the exact login triage comments as
# (default claude[bot]). Empty trusts no bot at all, only people.
set -euo pipefail

# Types a child may have. An Initiative's children are Epics; nothing below
# an Epic is an Initiative.
CHILD_TYPES='Feature Improvement Task Chore Spike Bug Epic'
PARENT_TYPES='Epic Initiative'
MAX_CHILDREN=20
MARKER='<!-- dodi-decompose -->'
# `trim` is built into jq 1.7 only, and a self-hosted image may be older.
JQ_DEFS='def trim_: gsub("^\\s+|\\s+$"; ""); def blank: type != "string" or trim_ == ""; '

# The newest comment carrying a ```children block, from a source allowed to
# propose: the triage agent, by its exact login, or a person with write
# access. Any other bot is ignored, a dependency bot or another App included:
# the person who confirms read triage's list, so a newer list from anyone else
# must not be the one filed. Prints the block's raw text, or nothing.
pick_block() {
  jq -r --arg by "${PROPOSER-claude[bot]}" '
    [ .[]
      | select(($by != "" and (.user.login // "") == $by)
               or ((.user.type // "") != "Bot"
                   and ((.author_association // "") | IN("OWNER","MEMBER","COLLABORATOR"))))
      | select((.body // "") | test("(^|\n)```children[ \t]*\r?\n")) ]
    | last // empty
    | .body' |
  awk '
    /^```children[ \t]*\r?$/ { on = 1; next }
    on && /^```[ \t]*\r?$/   { exit }
    on                        { print }
  '
}

parse() {
  local owner="$1" repo="$2" raw
  raw="$(pick_block)"
  if [ -z "$raw" ]; then
    echo "no \`\`\`children block from triage or a maintainer on this issue" >&2
    exit 2
  fi
  if ! printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "the children block is not a JSON array" >&2
    exit 2
  fi
  local errors
  errors="$(printf '%s' "$raw" | jq -r \
      --arg owner "$owner" --arg types "$CHILD_TYPES" --argjson max "$MAX_CHILDREN" "$JQ_DEFS"'
    ($types | split(" ")) as $ok
    | (if length == 0 then ["the block lists no children"] else [] end)
    + (if length > $max then ["\(length) children, more than \($max): split the Epic first"] else [] end)
    + ( [ to_entries[] | .key as $i | .value as $c
          | ( if ($c | type) != "object" then ["child \($i + 1): not an object"]
              else
                ( if ($c.title | blank)
                    then ["child \($i + 1): no title"] else [] end )
              + ( if (($c.title // "") | length) > 256 then ["child \($i + 1): title over 256 characters"] else [] end )
              + ( if ($ok | index($c.type // "")) == null
                    then ["child \($i + 1): type \"\($c.type // "")\" is not one of \($ok | join(", "))"] else [] end )
              + ( if ($c.plan | blank)
                    then ["child \($i + 1): no plan line"]
                  elif ($c.plan | test("\n")) then ["child \($i + 1): the plan is more than one line"]
                  else [] end )
              + ( if ($c.areas // [] | type) != "array" or any($c.areas // [] | .[]; type != "string")
                    then ["child \($i + 1): areas is not a list of names"] else [] end )
              + ( ($c.repo // "") as $r
                  | if ($r | type) != "string" then ["child \($i + 1): repo is not a name"]
                    elif ($r | test("/")) and ($r | split("/")[0]) != $owner
                      then ["child \($i + 1): repo \($r) is outside \($owner)"]
                    elif ($r | test("^[A-Za-z0-9_.-]*(/[A-Za-z0-9_.-]+)?$") | not)
                      then ["child \($i + 1): repo \"\($r)\" is not a repository name"]
                    else [] end )
              end ) ]
        | add // [] )
    + ( [ .[] | objects | (.title // "" | ascii_downcase | trim_) ]
        | group_by(.) | map(select(length > 1) | "two children share the title \"\(.[0])\"") )
    | .[]')"
  if [ -n "$errors" ]; then
    printf '%s\n' "$errors" >&2
    exit 2
  fi
  # Normalise: trim, default the repo to the parent's, write areas as
  # `area:<name>` whichever way they came in, and mark which repo it lands in.
  printf '%s' "$raw" | jq -c --arg owner "$owner" --arg repo "$repo" "$JQ_DEFS"'
    map({
      repo: ( (.repo // "") as $r
              | if $r == "" then "\($owner)/\($repo)"
                elif ($r | test("/")) then $r
                else "\($owner)/\($r)" end ),
      type,
      title: (.title | trim_),
      plan:  (.plan  | trim_),
      areas: ( [ (.areas // [])[] | trim_ | select(. != "")
                 | if startswith("area:") then . else "area:" + . end ] | unique )
    })
    | map(. + {local: (.repo == "\($owner)/\($repo)")})'
}

# The chore.yml issue form, rendered the way GitHub renders a submitted form:
# `### <label>` and that field's answer. A child has a one-line plan and a
# parent, so this is the one org shape whose fields it can fill truthfully.
# Triage reads the code and fills in the rest.
body() {
  local parent="$1" plan="$2" title="$3"
  cat <<EOF
### What needs doing

$plan

### Why now

Part of #$parent. Proposed when that issue was triaged, and created after a person confirmed the list.

### Blast radius

Not assessed yet. Triage sets Risk when it reads the code for "$title".

$(child_marker "$parent")
EOF
}

# Every child's body carries this. A re-run finds a child an earlier run filed
# but did not link by searching for it, so body() and run() must agree on it.
child_marker() { printf '<!-- dodi-decompose child-of=%s -->' "$1"; }

# --- run: everything below talks to GitHub ------------------------------

# Every write goes through here, so DRY_RUN is decided in one place.
api() {
  if [ "${DRY_RUN:-0}" = 1 ] && [ "${1:-}" = -X ] && [ "${2:-}" != GET ]; then
    echo "dry-run: gh api $*" >&2
    echo '{}'
    return 0
  fi
  gh api "$@"
}

field_ids() {
  # Repo-scoped on purpose: /orgs/*/issue-fields is 403 for a repo-scoped token.
  # shellcheck disable=SC2016  # GraphQL variables, not shell
  gh api graphql -f query='query($o:String!,$r:String!){
    repository(owner:$o,name:$r){ issueFields(first:50){ nodes{
      ... on IssueFieldSingleSelect { id name options{ id name } } } } } }' \
    -f o="$1" -f r="$2" --jq '.data.repository.issueFields.nodes'
}

# The mutation's literal for Triage state = Needs triage and Source = Internal,
# or nothing when this repo lacks either. Ids only, never user text, so the
# literal needs no escaping.
fields_literal() {
  jq -r '
    [ ( .[] | select(.name == "Triage state") | {f: .id, o: (.options[] | select(.name == "Needs triage") | .id)} ),
      ( .[] | select(.name == "Source")       | {f: .id, o: (.options[] | select(.name == "Internal")     | .id)} ) ]
    | if length == 2 then map("{fieldId:\"\(.f)\",singleSelectOptionId:\"\(.o)\"}") | join(",") else "" end'
}

run() {
  : "${REPO:?REPO is required}" "${NUMBER:?NUMBER is required}"
  local owner="${REPO%%/*}" name="${REPO##*/}"

  local type
  type="$(gh api "/repos/$REPO/issues/$NUMBER" --jq '.type.name // ""')"
  case " $PARENT_TYPES " in
    *" $type "*) : ;;
    *) report "Nothing created. #$NUMBER is a ${type:-issue with no type}, and only an Epic or an Initiative is split into children."
       return 0 ;;
  esac

  local children errfile
  errfile="$(mktemp "${TMPDIR:-/tmp}/decompose.XXXXXX")"
  # A subshell, so parse's `exit 2` ends only the parse.
  if ! children="$(gh api --paginate "/repos/$REPO/issues/$NUMBER/comments?per_page=100" | jq -s 'add // []' \
                   | (parse "$owner" "$name") 2>"$errfile")"; then
    report "Nothing created. The proposed children did not pass the check, so no child was filed:

$(sed 's/^/- /' "$errfile")

Fix the \`\`\`children block (or ask for \`@claude triage\` again), then apply \`agent:decompose\` again."
    return 1
  fi

  # Idempotent. A child whose title is already a sub-issue is skipped. A child an
  # earlier run created but failed to link is found by the marker its body
  # carries, through the cross-reference it left on this issue's timeline, and
  # is linked instead of filed again. A failed read here stops the run before
  # any write, so it files nothing.
  local existing unlinked='{}' labels='[]' literal=''
  existing="$(gh api --paginate "/repos/$REPO/issues/$NUMBER/sub_issues?per_page=100" \
              | jq -s '[add // [] | .[] | .title | ascii_downcase]')"
  children="$(jq -c --argjson existing "$existing" '
                map(. + {already: ((.title | ascii_downcase) as $t | $existing | index($t) != null)})' <<<"$children")"
  # The timeline, labels and field ids matter only when something is left to
  # file here, so a re-run on a finished Epic reads none of them.
  if jq -e 'any(.[]; .local and (.already | not))' <<<"$children" >/dev/null; then
    unlinked="$(gh api --paginate "/repos/$REPO/issues/$NUMBER/timeline?per_page=100" | jq -s \
                  --arg repo "$REPO" --arg m "$(child_marker "$NUMBER")" '
                  [ add // [] | .[] | select(.event == "cross-referenced") | .source.issue // empty
                    | select((.pull_request | not) and (.repository.full_name // "") == $repo
                             and ((.body // "") | contains($m)))
                    | {key: (.title | ascii_downcase), value: {number, id, node_id}} ] | from_entries')"
    labels="$(gh api --paginate "/repos/$REPO/labels?per_page=100" | jq -s '[add // [] | .[] | .name]')"
    literal="$(field_ids "$owner" "$name" | fields_literal)"
    [ -n "$literal" ] || echo "::warning title=decompose::could not resolve Triage state and Source for this repo; the children are created without them"
  fi

  # One jq pass per child: its fields as shell assignments, and its areas split
  # into those this repo has and those it does not. Never invent an area.
  local c title ctype plan crepo local_ already found areas missing created cnum cid cnode verb nofields
  lines=()
  while IFS= read -r c; do
    eval "$(jq -r --argjson have "$labels" --argjson unlinked "$unlinked" '
      [.areas[] | select(. as $a | $have | index($a))] as $has
      | @sh "title=\(.title) ctype=\(.type) plan=\(.plan) crepo=\(.repo) local_=\(.local) already=\(.already) found=\($unlinked[.title | ascii_downcase] // "" | tostring) areas=\($has | tojson) missing=\(.areas - $has | join(", "))"' <<<"$c")"

    if [ "$already" = true ]; then
      lines+=("- already a sub-issue: $title"); continue
    fi
    # One repo per run: the token is minted for this repository. A child that
    # belongs elsewhere is listed for a person to file by hand.
    if [ "$local_" != true ]; then
      lines+=("- not created, it belongs in \`$crepo\`: $ctype \"$title\". File it there by hand in the same shape and add it as a sub-issue.")
      continue
    fi

    nofields=""
    # Every write below reports what was done so far if it fails, so a person
    # never has to work out from the issue list which children exist.
    if [ -n "$found" ]; then
      created="$found"; verb="linked, filed by an earlier run"
    elif ! created="$(jq -n --arg t "$title" --arg b "$(body "$NUMBER" "$plan" "$title")" --arg ty "$ctype" --argjson l "$areas" \
                       '{title:$t, body:$b, type:$ty, labels:$l}' | api -X POST "/repos/$REPO/issues" --input -)"; then
      abort "could not create \"$title\""; return 1
    else
      verb="$ctype"
    fi
    IFS=$'\t' read -r cnum cid cnode < <(jq -r '[.number // "?", .id // "", .node_id // ""] | @tsv' <<<"$created")
    if [ -n "$cid" ] && ! api -X POST "/repos/$REPO/issues/$NUMBER/sub_issues" -F sub_issue_id="$cid" >/dev/null; then
      lines+=("- #$cnum: $title, created but NOT linked")
      abort "could not link #$cnum as a sub-issue"; return 1
    fi
    if [ -n "$cnode" ] && [ -n "$literal" ] && ! api -X POST graphql -f query="mutation{ setIssueFieldValue(input:{
      issueId:\"$cnode\", issueFields:[$literal] }){ clientMutationId } }" >/dev/null; then
      nofields=1
    fi
    lines+=("- #$cnum $verb: $title${missing:+ (not in this repo, so not applied: $missing)}${nofields:+ (Triage state and Source not set)}")
  done < <(jq -c '.[]' <<<"$children")

  report "Created from the confirmed proposal:

$(printf '%s\n' "${lines[@]}")

Each child starts at \`Triage state: Needs triage\`. Apply \`agent:triage\` to one to plan it."
}

# Stop partway, saying what this run already did. Applying the label again
# links what was created and files the rest.
abort() {
  report "Stopped partway: $1. Done before that:

$(if [ "${#lines[@]}" -gt 0 ]; then printf '%s\n' "${lines[@]}"; else echo "- nothing"; fi)

Apply \`agent:decompose\` again. It links what was already created and files the rest."
}

report() {
  printf '%s\n' "$1"
  api -X POST "/repos/$REPO/issues/$NUMBER/comments" -f body="$1

$MARKER" >/dev/null
}

case "${1:-}" in
  parse) shift; parse "$@" ;;
  body)  shift; body "$@" ;;
  run)   run ;;
  *)     echo "usage: decompose.sh parse OWNER REPO | body PARENT PLAN TITLE | run" >&2; exit 64 ;;
esac
