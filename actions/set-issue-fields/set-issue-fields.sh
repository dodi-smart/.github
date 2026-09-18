#!/usr/bin/env bash
# Set org issue-field values, an issue type, and labels on one issue.
#
# Everything field-related here is a GraphQL node id, deliberately. The REST
# catalog returns NUMERIC option ids, and the mutation rejects them with
# "Could not resolve to a node with the global id of '80100031'": those are
# database ids, not node ids. The catalog is fetched from GraphQL so field and
# option ids come from the same namespace the mutation expects.
#
# The catalog is read from the REPOSITORY, never the organisation, even though
# the fields themselves are org-level. `organization{ issueFields }` needs an
# org permission that a repo-scoped token does not hold, and every CI token in
# this org is repo-scoped: it gets a 403 on any /orgs/* path, REST and GraphQL
# alike. `repository{ issueFields }` returns the same fields with the same ids
# and needs nothing beyond repo access, so this script never touches the org
# path and never offers it as a fallback. There is no flag that reaches it.
#
# The inner input type for the mutation is IssueFieldCreateOrUpdateInput, and
# its key is `fieldId`. The outer mutation argument is `issueFields`, which
# reads as though the inner key should be `issueFieldId`. It is not.
#
# Usage:
#   set-issue-fields.sh --repo OWNER/REPO --issue N \
#     [--field "Name=Option"]... [--type IssueType] \
#     [--add-label name]... [--remove-label name]... \
#     [--from-decisions decisions.json]
set -euo pipefail

REPO=""; NUM=""; TYPE=""; DECISIONS=""
declare -a FIELD_PAIRS=() ADD_LABELS=() REMOVE_LABELS=()

usage() {
  sed -n '2,25p' "$0"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)            REPO="$2"; shift 2 ;;
    --issue)           NUM="$2"; shift 2 ;;
    --field)           FIELD_PAIRS+=("$2"); shift 2 ;;
    --type)            TYPE="$2"; shift 2 ;;
    --add-label)       ADD_LABELS+=("$2"); shift 2 ;;
    --remove-label)    REMOVE_LABELS+=("$2"); shift 2 ;;
    --from-decisions)  DECISIONS="$2"; shift 2 ;;
    -h|--help)         usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 2 ;;
  esac
done

if [ -z "$REPO" ] || [ -z "$NUM" ]; then
  echo "usage: set-issue-fields.sh --repo OWNER/REPO --issue N [--field 'Name=Option']..." >&2
  exit 2
fi

ORG="${REPO%%/*}"; NAME="${REPO##*/}"

# Merge in whatever the decisions file already decided to act on. Only
# act:true entries: a field the classifier is unsure about is left for a
# person or the agent to set, never written just because it was mentioned.
if [ -n "$DECISIONS" ]; then
  [ -f "$DECISIONS" ] || { echo "no such decisions file: $DECISIONS" >&2; exit 1; }

  while IFS= read -r pair; do
    [ -n "$pair" ] && FIELD_PAIRS+=("$pair")
  done < <(jq -r '(.fields // []) | map(select(.act == true)) | .[] | "\(.name)=\(.value)"' "$DECISIONS")

  decided_type=$(jq -r 'if (.type // null) != null and .type.act == true then .type.value else empty end' "$DECISIONS")
  [ -n "$decided_type" ] && TYPE="$decided_type"

  while IFS= read -r label; do
    [ -n "$label" ] && ADD_LABELS+=("$label")
  done < <(jq -r '(.labels.add // [])[]' "$DECISIONS")

  while IFS= read -r label; do
    [ -n "$label" ] && REMOVE_LABELS+=("$label")
  done < <(jq -r '(.labels.remove // [])[]' "$DECISIONS")
fi

if [ "${#FIELD_PAIRS[@]}" -eq 0 ] && [ -z "$TYPE" ] && [ "${#ADD_LABELS[@]}" -eq 0 ] && [ "${#REMOVE_LABELS[@]}" -eq 0 ]; then
  echo "nothing to set"
  exit 0
fi

# ---- single select fields, in one mutation -------------------------------

if [ "${#FIELD_PAIRS[@]}" -gt 0 ]; then
  # shellcheck disable=SC2016 # $o/$r/$n are GraphQL variables inside a single-quoted query, not shell
  issue_id=$(gh api graphql -f query='
    query($o:String!,$r:String!,$n:Int!){
      repository(owner:$o,name:$r){ issue(number:$n){ id } } }' \
    -f o="$ORG" -f r="$NAME" -F n="$NUM" --jq '.data.repository.issue.id')
  if [ -z "$issue_id" ] || [ "$issue_id" = "null" ]; then
    echo "issue $REPO#$NUM not found" >&2
    exit 1
  fi

  # shellcheck disable=SC2016 # $o/$r are GraphQL variables inside a single-quoted query, not shell
  catalog=$(gh api graphql -f query='
    query($o:String!,$r:String!){
      repository(owner:$o,name:$r){ issueFields(first:50){ nodes{
        ... on IssueFieldSingleSelect { id name options { id name } }
      } } } }' -f o="$ORG" -f r="$NAME" \
    --jq '[.data.repository.issueFields.nodes[] | select(.name != null)]')

  inputs=""
  for pair in "${FIELD_PAIRS[@]}"; do
    fname="${pair%%=*}"; oname="${pair#*=}"
    fid=$(jq -r --arg f "$fname" '.[]|select(.name==$f)|.id' <<<"$catalog")
    if [ -z "$fid" ] || [ "$fid" = "null" ]; then
      echo "no such issue field: $fname. Available:" >&2
      jq -r '.[]|"  - "+.name' <<<"$catalog" >&2
      exit 1
    fi
    oid=$(jq -r --arg f "$fname" --arg o "$oname" \
          '.[]|select(.name==$f)|.options[]?|select(.name==$o)|.id' <<<"$catalog")
    if [ -z "$oid" ] || [ "$oid" = "null" ]; then
      echo "field '$fname' has no option '$oname'. Valid:" >&2
      jq -r --arg f "$fname" '.[]|select(.name==$f)|.options[]?|"  - "+.name' <<<"$catalog" >&2
      exit 1
    fi
    inputs="$inputs{fieldId:\"$fid\",singleSelectOptionId:\"$oid\"},"
    echo "  $fname = $oname"
  done

  gh api graphql -f query="mutation{ setIssueFieldValue(input:{
    issueId:\"$issue_id\", issueFields:[${inputs%,}] }){ clientMutationId } }" >/dev/null
fi

# ---- issue type ------------------------------------------------------------

if [ -n "$TYPE" ]; then
  gh api -X PATCH "/repos/$REPO/issues/$NUM" -f type="$TYPE" >/dev/null
  echo "  type = $TYPE"
fi

# ---- labels -----------------------------------------------------------------

for label in "${ADD_LABELS[@]}"; do
  gh api -X POST "/repos/$REPO/issues/$NUM/labels" -f "labels[]=$label" >/dev/null
  echo "  +label $label"
done

for label in "${REMOVE_LABELS[@]}"; do
  # Percent-encoded: a label like area:x carries the colon as part of the
  # name, not a path separator, so it has to survive as %3A to reach the API
  # as one segment instead of being read as two.
  encoded=$(jq -rn --arg s "$label" '$s|@uri')
  gh api -X DELETE "/repos/$REPO/issues/$NUM/labels/$encoded" --silent
  echo "  -label $label"
done

echo "set on $REPO#$NUM"
