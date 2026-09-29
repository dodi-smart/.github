#!/usr/bin/env bash
# lint.sh against a fake `gh` and a fake commitlint: which messages it lints,
# that it fails on any bad one, and that a missing config falls back.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; export HERE
TMP="$(mktemp -d "${TMPDIR:-/tmp}/commitlint-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1: got '$3', want '$2'"; fi; }

mkdir -p "$TMP/bin"
# Fake gh: prints the commits fixture as `sha<TAB>base64(message)` rows.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
while IFS= read -r line; do
  sha=${line%%|*}; msg=${line#*|}
  printf '%s\t%s\n' "$sha" "$(printf '%b' "$msg" | base64 | tr -d '\n')"
done < "$FIXTURE"
EOF
# Fake commitlint: a conventional header passes, anything else fails.
cat > "$TMP/bin/commitlint" <<'EOF'
#!/usr/bin/env bash
head -n 1 | grep -qE '^[a-z]+(\([^)]+\))?!?: .+' || { echo "type may not be empty"; exit 1; }
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/commitlint"

run() { # fixture-lines -> exit code
  printf '%s\n' "$@" > "$TMP/fixture"
  (cd "$TMP" && PATH="$TMP/bin:$PATH" FIXTURE="$TMP/fixture" COMMITLINT="$TMP/bin/commitlint" \
     SKIP_INSTALL=true REPO=o/r NUMBER=1 PREFIX="$TMP/p" CONFIG=.commitlintrc.json \
     "$HERE/lint.sh" > "$TMP/out" 2>&1); echo $?
}

check "all conventional"      0 "$(run 'aaaaaaa1|feat(x): add' 'bbbbbbb2|fix: y\n\nbody line')"
check "one bad message fails" 1 "$(run 'aaaaaaa1|feat: ok' 'bbbbbbb2|wip stuff')"
check "the bad one is named"  1 "$(grep -c '::error title=Commit message::bbbbbbb wip stuff' "$TMP/out")"
check "missing config falls back to conventional" 1 "$(grep -c 'linting against @commitlint/config-conventional' "$TMP/out")"
printf '{"extends":["@commitlint/config-angular"]}\n' > "$TMP/.commitlintrc.json"
run 'aaaaaaa1|feat: ok' > /dev/null
check "the repo config is copied beside the tools" 1 "$(grep -c config-angular "$TMP/p/.commitlintrc.json")"

echo "commitlint: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
