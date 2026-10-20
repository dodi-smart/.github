#!/usr/bin/env bash
# lint.sh against a fake `gh`, a fake commitlint and a fake npm: which messages it
# lints, that it fails on any bad one, that a missing config falls back to the org
# preset, that `extends` is held to the pinned set with nothing installed on a
# config's say-so, and that the preset carries the rules it is meant to.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; export HERE
TMP="$(mktemp -d "${TMPDIR:-/tmp}/commitlint-test.XXXXXX")"; export TMP
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1: got '$3', want '$2'"; fi; }

mkdir -p "$TMP/bin" "$TMP/repo"
# Fake gh: serves a contents call from $TMP/repo (404 when missing), and prints
# the commits fixture as `sha<TAB>base64(message)` rows.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in
  */contents/*) f=${a#*/contents/}; cat "$TMP/repo/${f%%\?*}" 2>/dev/null; exit;; esac; done
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
# Fake npm: records its arguments and installs nothing.
cat > "$TMP/bin/npm" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TMP/npm.log"
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/commitlint" "$TMP/bin/npm"

# SKIP comes from the environment. SKIP=false runs the install step
# against the fake npm. COMMITLINT= (empty) runs the real commitlint, for the
# REAL=1 section at the end.
run() { # fixture-lines -> exit code; $TMP/npm.log holds this run's npm calls
  printf '%s\n' "$@" > "$TMP/fixture"
  : > "$TMP/npm.log"
  (cd "$TMP" && PATH="$TMP/bin:$PATH" FIXTURE="$TMP/fixture" COMMITLINT="${COMMITLINT-$TMP/bin/commitlint}" \
     SKIP_INSTALL="${SKIP:-true}" \
     REPO=o/r NUMBER=1 REF=abc PREFIX="$TMP/p" CONFIG=.commitlintrc.json \
     "$HERE/lint.sh" > "$TMP/out" 2>&1); echo $?
}
pinned=$(jq -r '.dependencies | keys | join(", ")' "$HERE/package.json")

check "all conventional"      0 "$(run 'aaaaaaa1|feat(x): add' 'bbbbbbb2|fix: y\n\nbody line')"
check "one bad message fails" 1 "$(run 'aaaaaaa1|feat: ok' 'bbbbbbb2|wip stuff')"
check "the bad one is named"  1 "$(grep -c '::error title=Commit message::bbbbbbb wip stuff' "$TMP/out")"
check "missing config says it uses the org preset" 1 "$(grep -c 'linting against the org preset' "$TMP/out")"
check "missing config lints against the preset" '{"extends":["@dodi-smart/commitlint-config"]}' "$(cat "$TMP/p/.commitlintrc.json")"

# An allowed `extends` is fetched beside the tools and accepted, as a list or a string.
printf '{"extends":["@dodi-smart/commitlint-config"],"rules":{"scope-empty":[2,"never"]}}\n' > "$TMP/repo/.commitlintrc.json"
check "a config extending the preset is accepted" 0 "$(run 'aaaaaaa1|feat(x): ok')"
check "the repo config is fetched beside the tools" 1 "$(grep -c scope-empty "$TMP/p/.commitlintrc.json")"
printf '{"extends":"@commitlint/config-conventional"}\n' > "$TMP/repo/.commitlintrc.json"
check "a string extends in the pinned set is accepted" 0 "$(run 'aaaaaaa1|feat: ok')"
printf '{"rules":{}}\n' > "$TMP/repo/.commitlintrc.json"
check "a config with no extends is accepted" 0 "$(run 'aaaaaaa1|feat: ok')"

# Anything outside the pinned set fails the run, and nothing is installed for it.
printf '{"extends":["@commitlint/config-conventional","@commitlint/config-angular"]}\n' > "$TMP/repo/.commitlintrc.json"
check "an unpinned package fails the run" 1 "$(SKIP=false run 'aaaaaaa1|feat: ok')"
check "the error names the entry" 1 "$(grep -c "::error title=Commitlint config::.*'@commitlint/config-angular'" "$TMP/out")"
check "the error lists what is allowed" 1 "$(grep -cF "Allowed: $pinned." "$TMP/out")"
check "the error points at package.json" 1 "$(grep -c 'actions/commitlint/package.json' "$TMP/out")"
check "nothing is installed for it" "" "$(cat "$TMP/npm.log")"
printf '{"extends":["./shared.json"]}\n' > "$TMP/repo/.commitlintrc.json"
check "a relative extends is rejected" 1 "$(run 'aaaaaaa1|feat: ok')"
check "the relative entry is named" 1 "$(grep -c "extends './shared.json'" "$TMP/out")"

# A config that is not JSON cannot be read here, so it is left to commitlint.
printf 'module.exports = { extends: ["@commitlint/config-conventional"] };\n' > "$TMP/repo/.commitlintrc.json"
check "a non-JSON config is not checked" 0 "$(run 'aaaaaaa1|feat: ok')"

# The install step: `npm ci` of the pinned set, never `npm install`.
printf '{"extends":["@dodi-smart/commitlint-config"]}\n' > "$TMP/repo/.commitlintrc.json"
rm -rf "$TMP/p/preset"
check "an install runs" 0 "$(SKIP=false run 'aaaaaaa1|feat: ok')"
check "the install is npm ci and nothing else" "ci --prefer-offline --ignore-scripts --no-audit --no-fund" "$(cat "$TMP/npm.log")"
check "the preset is copied beside package.json" 1 "$([ -f "$TMP/p/preset/index.js" ] && echo 1 || echo 0)"

# The preset's rules, read from the file the lockfile links. subject-case is absent
# on purpose: it stays as config-conventional has it.
check "the preset" '{"extends":["@commitlint/config-conventional"],"rules":{"header-max-length":[2,"always",180],"body-max-line-length":[1,"always",180],"footer-max-line-length":[1,"always",180]}}' \
  "$(node -p "JSON.stringify(require('$HERE/preset'))")"

# REAL=1 (needs network): the real npm installs the pinned set and the real
# commitlint lints through the preset by name. The preset declares no dependency,
# so this is what proves it finds config-conventional in that one tree. Only gh is
# faked. A 150-char header and a 190-char body line both break config-conventional's
# own limit of 100 and pass here only if the preset's 180 applies.
if [ "${REAL:-}" = 1 ]; then
  rm "$TMP/bin/npm"
  printf '{"extends":["@dodi-smart/commitlint-config"]}\n' > "$TMP/repo/.commitlintrc.json"
  line() { head -c "$1" < /dev/zero | tr '\0' "$2"; }
  check "real: long header and body lines pass under the preset" 0 \
    "$(COMMITLINT='' SKIP=false run "aaaaaaa1|feat: $(line 144 y)\n\n$(line 190 z)")"
  check "real: a 190-char header still fails" 1 "$(COMMITLINT='' run "aaaaaaa1|feat: $(line 184 y)")"
  check "real: on header-max-length" 1 "$(grep -c 'header-max-length' "$TMP/out")"
fi

echo "commitlint: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
