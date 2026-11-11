#!/usr/bin/env bash
# Price and time one agent run from the result record claude-code-action
# writes to its execution file. run-agent's outcome step calls it.
#
# Usage: price.sh PRICES < result.json
# Prints one line: cost|priced|wall|unknown. Not tabs: `read` collapses empty
# tab-separated fields, and wall or unknown is often empty.
#
#   cost     USD, rounded to a millionth, or `?` when the run cannot be priced
#   priced   table     every model in modelUsage has a row in PRICES, and the
#                      tokens were multiplied out (a session that never reached
#                      a model is priced 0 this way)
#            reported  some model has no row; the cost Claude Code reported
#            none      neither, so the cost is `?`
#   wall     the session's duration_ms in whole seconds, empty when absent
#   unknown  comma-separated models with no row in PRICES
#
# The table wins over the reported cost so every run in the org is priced from
# one list, the same way, whatever the CLI version or login type. Absent is not
# zero: a run that used a model and cannot be priced prints `?`.
set -euo pipefail
jq -r --rawfile p "${1:?usage: price.sh PRICES < result.json}" '
  def norm: sub("\\[[^]]*\\]$"; "") | sub("-[0-9]{8}$"; "");
  ($p | split("\n") | map(select(test("^[a-z0-9]")) | split("\t") | select(length >= 5)
      | {key: .[0], value: (.[1:5] | map(tonumber))}) | from_entries) as $t
  | [(.modelUsage // {}) | to_entries[] | {m: (.key | norm), u: .value}] as $rows
  | ([$rows[].m | select($t[.] == null)] | unique) as $unknown
  | .total_cost_usd as $rep
  | (if ($rows | length) > 0 and ($unknown | length) == 0 then
       {cost: ([$rows[] | $t[.m] as $r | .u as $u
                | ($u.inputTokens // 0) * $r[0] + ($u.outputTokens // 0) * $r[1]
                  + ($u.cacheReadInputTokens // 0) * $r[2] + ($u.cacheCreationInputTokens // 0) * $r[3]]
               | add / 1000000), priced: "table"}
     elif ($rep | type) == "number" and $rep > 0 then {cost: $rep, priced: "reported"}
     elif ($rows | length) == 0 and (.num_turns // 0) == 0 then {cost: 0, priced: "table"}
     else {cost: null, priced: "none"} end) as $c
  | [(if $c.cost == null then "?" else ($c.cost * 1000000 | round) / 1000000 | tostring end),
     $c.priced,
     (if (.duration_ms | type) == "number" then (.duration_ms / 1000 | round | tostring) else "" end),
     ($unknown | join(","))]
  | join("|")'
