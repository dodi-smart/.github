#!/usr/bin/env bash
# Tests for envfile.sh and bun-version.sh.
#
# Run: actions/setup-stack/test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Explicit template: BSD/macOS `mktemp -d` ignores TMPDIR without one.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/setup-stack-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # desc want got
  if [ "$2" = "$3" ]; then pass=$((pass + 1))
  else fail=$((fail + 1)); printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fi
}

# --- envfile.sh: parse, then source in a fresh shell and read the value back.
envval() { # text var
  printf '%s' "$1" | "$HERE/envfile.sh" "$TMP/env.sh"
  bash -c '. "$1"; printf "%s" "${!2-<unset>}"' _ "$TMP/env.sh" "$2"
}
text=$'# a comment\n\n   LEADING=  kept spaces\nURL=https://x.test/?a=b&c=d==\nNODE_OPTIONS=--max-old-space-size=4096\nQUOTED=it\'s a "test" $HOME `id`\n  # indented comment\nEMPTY=\nNOEQUALS\nGRADLE_OPTS=-Xmx2g -Dfoo=bar'
check "leading spaces trimmed from key"    '  kept spaces' "$(envval "$text" LEADING)"
check "= inside a value survives"          'https://x.test/?a=b&c=d==' "$(envval "$text" URL)"
check "NODE_OPTIONS"                       '--max-old-space-size=4096' "$(envval "$text" NODE_OPTIONS)"
# shellcheck disable=SC2016  # the dollar sign and backticks are the point
check "quotes and expansions stay literal" 'it'\''s a "test" $HOME `id`' "$(envval "$text" QUOTED)"
check "empty value"                        '' "$(envval "$text" EMPTY)"
check "line without ="                     '' "$(envval "$text" NOEQUALS)"
check "value with spaces stays one word"   '-Xmx2g -Dfoo=bar' "$(envval "$text" GRADLE_OPTS)"
check "the file has one line per variable" '7' "$(wc -l < "$TMP/env.sh" | tr -d ' ')"
check "no trailing newline on last line"   'v' "$(envval 'LAST=v' LAST)"
printf '' | "$HERE/envfile.sh" "$TMP/empty.sh"
check "empty input gives an empty file"    '0' "$(wc -c < "$TMP/empty.sh" | tr -d ' ')"
printf '%s' "$text" | "$HERE/envfile.sh" "$TMP/env.sh"
check "a set -euo pipefail step can source it" 'ok' "$(bash -c 'set -euo pipefail; . "$1"; echo ok' _ "$TMP/env.sh")"

# --- bun-version.sh
resolve() { # dir requested -> "version source"
  local out="$TMP/gho"; : > "$out"
  (cd "$1" && GITHUB_OUTPUT="$out" "$HERE/bun-version.sh" "$2" > /dev/null)
  printf '%s %s' "$(sed -n 's/^version=//p' "$out")" "$(sed -n 's/^source=//p' "$out")"
}
fx() { rm -rf "$TMP/fx"; mkdir -p "$TMP/fx"; echo "$TMP/fx"; }

d="$(fx)"
check "empty repo -> latest" "latest none" "$(resolve "$d" auto)"
echo 9.9.9 > "$d/.bun-version"
check "explicit version wins over files" "1.2.3 input" "$(resolve "$d" 1.2.3)"
check "explicit latest wins over files" "latest input" "$(resolve "$d" latest)"
check "empty input resolves like auto" "9.9.9 .bun-version" "$(resolve "$d" '')"

d="$(fx)"; echo '{"name":"x","packageManager":"bun@1.4.2+sha256.abcdef"}' > "$d/package.json"
check "packageManager, +sha stripped" "1.4.2 package.json" "$(resolve "$d" auto)"
echo 1.1.1 > "$d/.bun-version"
check "packageManager beats .bun-version" "1.4.2 package.json" "$(resolve "$d" auto)"

d="$(fx)"; echo '{"packageManager": "pnpm@9.0.0"}' > "$d/package.json"; echo 1.1.1 > "$d/.bun-version"
check "packageManager for another tool is skipped" "1.1.1 .bun-version" "$(resolve "$d" auto)"

d="$(fx)"; printf 'v1.3.0\n' > "$d/.bun-version"; printf 'bun 1.0.0\n' > "$d/.tool-versions"
check ".bun-version beats .tool-versions, leading v dropped" "1.3.0 .bun-version" "$(resolve "$d" auto)"

d="$(fx)"; printf 'nodejs 24.1.0\nbun 1.0.5 1.0.4 # pinned\n' > "$d/.tool-versions"; printf '[tools]\nbun = "2.0.0"\n' > "$d/mise.toml"
check ".tool-versions beats mise.toml, first version taken" "1.0.5 .tool-versions" "$(resolve "$d" auto)"

d="$(fx)"; printf '[settings]\nbun = "7.7.7"\n\n[tools]\nnode = "24"\nbun = "1.4.2"\n' > "$d/mise.toml"
check "mise.toml reads only [tools]" "1.4.2 mise.toml" "$(resolve "$d" auto)"

d="$(fx)"; printf "[tools]\nbun = '1.4.1' # comment\n" > "$d/.mise.toml"
check ".mise.toml, single quotes" "1.4.1 .mise.toml" "$(resolve "$d" auto)"

d="$(fx)"; printf '[tools]\nbun = "latest"\n' > "$d/mise.toml"
check "mise latest passes through" "latest mise.toml" "$(resolve "$d" auto)"

d="$(fx)"; printf '[settings]\nbun = "7.7.7"\n' > "$d/mise.toml"
check "no bun under [tools] -> latest" "latest none" "$(resolve "$d" auto)"

echo "setup-stack: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
