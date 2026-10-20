#!/usr/bin/env bash
# Print what the knowledge layer needs run, as lines for $GITHUB_OUTPUT.
#
#   need.sh <zavet-dir>   ->   cli=true|false      CLI is a regular executable file
#                              declared=<n>        decision and spec files with a top-level `checks:`
#                              install=true|false  cli and declared > 0
#
# A `checks:` command is the only thing that needs the repo's toolchain, so
# with none declared an install is pure cost. `zavet verify` reads checks from
# decisions/ and specs/ both, so both are counted; over-counting only costs an
# install. yq needs just `cli`, because guards and audit read frontmatter too.
set -uo pipefail

[ $# -eq 1 ] || { echo "usage: need.sh <zavet-dir>" >&2; exit 2; }
dir="$1"

cli=false
if [ -f "$dir/bin/zavet" ] && [ -x "$dir/bin/zavet" ]; then cli=true; fi

# grep exits 1 on no match and 2 on a missing directory; both mean zero here.
declared=$(grep -rlE '^checks:' "$dir/decisions" "$dir/specs" 2>/dev/null | wc -l | tr -d ' ')

echo "cli=$cli"
echo "declared=$declared"
if [ "$cli" = true ] && [ "$declared" -gt 0 ]; then echo "install=true"; else echo "install=false"; fi
