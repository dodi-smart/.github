#!/usr/bin/env bash
# Tests for envfile.sh, bun-version.sh and the resolve and defaults steps.
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

# --- action.yml, read once: the defaults and resolve scripts, setup-bun's no-cache, and who saves.
python3 - "$HERE/action.yml" "$TMP" <<'EOF'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))['runs']['steps']
for id in ('defaults', 'resolve'):
    open(f'{sys.argv[2]}/{id}.sh', 'w').write([s for s in steps if s.get('id') == id][0]['run'])
bun = [s for s in steps if str(s.get('uses', '')).startswith('oven-sh/setup-bun@')][0]
open(f'{sys.argv[2]}/bun-no-cache', 'w').write(str(bun['with'].get('no-cache', '')))
# Only cache_save decides who writes: ~/.konan restores where it is false and
# saves (post step, on a miss) where it is true, under one exact key.
uses = lambda s: str(s.get('uses', ''))
konan = [s for s in steps if '.konan' in str((s.get('with') or {}).get('path', ''))]
by = {u: [s for s in konan if uses(s).startswith(u)] for u in ('actions/cache/restore@', 'actions/cache@')}
gradle = [s for s in steps if uses(s).startswith('gradle/actions/setup-gradle@')][0]['with']
rust = [s for s in steps if uses(s).startswith('Swatinem/rust-cache@')][0]['with']
bad = [m for m, broken in (
    ('want one restore-only and one saving konan step', len(konan) != 2 or any(len(v) != 1 for v in by.values())),
    ('a konan step has restore-keys', any(s['with'].get('restore-keys') for s in konan)),
    ('konan steps use different keys', len({s['with'].get('key') for s in konan}) != 1),
    ('restore-only konan step not gated on cache_save != true', "cache_save != 'true'" not in str(by['actions/cache/restore@'][:1])),
    ('saving konan step not gated on cache_save == true', "cache_save == 'true'" not in str(by['actions/cache@'][:1])),
    ('an inline actions/cache/save saves before the build', any(uses(s).startswith('actions/cache/save') for s in steps)),
    ('setup-gradle cache-read-only ignores cache_save', 'cache_save' not in str(gradle.get('cache-read-only'))),
    ('rust-cache save-if ignores cache_save', 'cache_save' not in str(rust.get('save-if'))),
) if broken]
open(f'{sys.argv[2]}/saves', 'w').write('; '.join(bad) or 'ok')
EOF

# --- the defaults step: lock command, version files and the lockfile list.
defaults() { # stack output [VAR=VALUE...] -> that output's value
  local stack="$1" key="$2"; shift 2
  : > "$TMP/defaults.out"
  env -i PATH="$PATH" STACK="$stack" O_INSTALL=@stack O_LINT=@stack O_TYPECHECK=@stack O_TEST=@stack O_BUILD=@stack \
    O_DESIGN_LINT=@stack O_LOCK=@stack O_VERSION_FILES=@stack ACTION_PATH="$HERE" GITHUB_OUTPUT="$TMP/defaults.out" "$@" \
    bash "$TMP/defaults.sh" >/dev/null 2>&1
  awk -v k="$key" '$0 == k "<<__SETUP_STACK_EOF__" { on = 1; next } $0 == "__SETUP_STACK_EOF__" { on = 0 } on' "$TMP/defaults.out"
}
listed() { printf '%s' "$2" | grep -qE "$(defaults "$1" version-files)" && echo yes || echo no; }
locked() { printf '%s' "$1" | grep -qE "$(defaults none lockfiles)" && echo yes || echo no; }
check "bun locks with --lockfile-only"         'bun install --lockfile-only' "$(defaults bun lock)"
check "node locks with scripts off"            'npm install --package-lock-only --ignore-scripts' "$(defaults node lock)"
check "a node repo on pnpm overrides lock"     'pnpm install --lockfile-only' "$(defaults node lock O_LOCK='pnpm install --lockfile-only')"
check "none has no lock command"               '' "$(defaults none lock)"
check "android lists the wrapper properties"   yes "$(listed android gradle/wrapper/gradle-wrapper.properties)"
check "gradle lists the version catalog"       yes "$(listed gradle gradle/libs.versions.toml)"
check "android lists a module build file"      yes "$(listed android app/build.gradle.kts)"
check "bun lists a workspace package.json"     yes "$(listed bun packages/web/package.json)"
check "flutter lists pubspec.yaml"             yes "$(listed flutter pubspec.yaml)"
check "rust lists a crate's Cargo.toml"        yes "$(listed rust crates/a/Cargo.toml)"
check "every stack lists mise.toml"            yes "$(listed none mise.toml)"
check "no stack lists source code"             no  "$(listed android app/src/main/Main.kt)"
check "a stack's manifests are not another's"  no  "$(listed rust package.json)"
check "version files never include a lockfile" no  "$(listed bun bun.lock)"
for f in bun.lock bun.lockb package-lock.json pnpm-lock.yaml yarn.lock pubspec.lock Cargo.lock Podfile.lock Package.resolved app/gradle.lockfile go.sum; do
  check "lockfiles covers $f" yes "$(locked "$f")"
done
check "lockfiles does not cover a manifest"    no  "$(locked package.json)"

# --- the resolve step: which runners get GitHub cache, setup-bun's included.
cached() { # environment os arch [isolate] [cache] -> cache_enabled
  : > "$TMP/resolve.out"
  env -i PATH="$PATH" STACK=bun ISOLATE="${4:-false}" CACHE="${5:-auto}" RUNNER_ENVIRONMENT="$1" RUNNER_OS="$2" \
    RUNNER_ARCH="$3" RUNNER_TEMP="$TMP" GITHUB_ENV=/dev/null GITHUB_OUTPUT="$TMP/resolve.out" \
    bash "$TMP/resolve.sh" >/dev/null 2>&1
  sed -n 's/^cache_enabled=//p' "$TMP/resolve.out"
}
check "hosted caches"                          true  "$(cached github-hosted Linux X64)"
check "self-hosted Linux does not cache"       false "$(cached self-hosted Linux X64)"
check "self-hosted macOS caches"               true  "$(cached self-hosted macOS ARM64)"
check "isolate turns cache off on hosted"      false "$(cached github-hosted Linux X64 true)"
check "cache: false turns it off on hosted"    false "$(cached github-hosted Linux X64 false false)"
# shellcheck disable=SC2016  # the expression is matched literally
check "setup-bun's cache follows the mode"     '${{ steps.resolve.outputs.cache_enabled != '\''true'\'' }}' "$(< "$TMP/bun-no-cache")"

# --- RUNNER_PERSISTENT_CACHE and cache_save. `res` runs resolve with extra
# VAR=VALUE pairs on top of a self-hosted macOS gradle job on a pull request ref.
res() {
  : > "$TMP/p.env"; : > "$TMP/p.out"
  env -i PATH="$PATH" STACK=gradle ISOLATE=false CACHE=auto RUNNER_ENVIRONMENT=self-hosted RUNNER_OS=macOS \
    RUNNER_ARCH=ARM64 RUNNER_TEMP="$TMP" REF=refs/pull/7/merge DEFAULT_BRANCH=main \
    GITHUB_ENV="$TMP/p.env" GITHUB_OUTPUT="$TMP/p.out" "$@" bash "$TMP/resolve.sh" > "$TMP/p.log" 2>&1
}
out() { sed -n "s/^$1=//p" "$TMP/p.out"; }
envv() { sed -n "s/^$1=//p" "$TMP/p.env"; }
warned() { grep -c '::warning::RUNNER_PERSISTENT_CACHE' "$TMP/p.log"; }
# A path that is not usable leaves the runner's usual mode, says so, and fails nothing.
falls_back() { # desc warnings
  check "$1: the usual macOS mode"     true "$(out cache_enabled)"
  check "$1: no GRADLE_USER_HOME"      ''   "$(envv GRADLE_USER_HOME)"
  check "$1: no KONAN_DATA_DIR"        ''   "$(envv KONAN_DATA_DIR)"
  check "$1: empty persistent output"  ''   "$(out persistent)"
  check "$1: warnings"                 "$2" "$(warned)"
}

share="$TMP/ci cache"; mkdir -p "$share"   # a space, like a VM share's "My Shared Files"
res RUNNER_PERSISTENT_CACHE="$share"
check "persistent: cache goes off on macOS"       false "$(out cache_enabled)"
check "persistent: the output names the path"     "$share" "$(out persistent)"
check "persistent: GRADLE_USER_HOME under it"     "$share/gradle" "$(envv GRADLE_USER_HOME)"
check "persistent: KONAN_DATA_DIR under it"       "$share/konan" "$(envv KONAN_DATA_DIR)"
check "persistent: both directories are created"  yes "$([ -d "$share/gradle" ] && [ -d "$share/konan" ] && echo yes || echo no)"
check "persistent: no warning when it is usable"  0 "$(warned)"
check "persistent: the log line names it"         1 "$(grep -c "persistent=$share" "$TMP/p.log")"
res RUNNER_PERSISTENT_CACHE="$share" RUNNER_ENVIRONMENT=github-hosted RUNNER_OS=Linux RUNNER_ARCH=X64
check "persistent: any OS honours the declaration" false "$(out cache_enabled)"
res RUNNER_PERSISTENT_CACHE="$TMP/does not exist"; falls_back "persistent: a missing path" 1
: > "$TMP/a file"
res RUNNER_PERSISTENT_CACHE="$TMP/a file"; rc=$?
falls_back "persistent: a file" 1
check "persistent: a file does not fail the step" 0 "$rc"
res RUNNER_PERSISTENT_CACHE=""; falls_back "persistent: empty is unset" 0
res RUNNER_PERSISTENT_CACHE="$share" ISOLATE=true
check "persistent: isolate=true ignores it"       '' "$(out persistent)"
check "persistent: isolate=true keeps RUNNER_TEMP dirs" "$TMP/gradle-home" "$(envv GRADLE_USER_HOME)"
check "persistent: isolate=true sets no KONAN_DATA_DIR" '' "$(envv KONAN_DATA_DIR)"
res RUNNER_PERSISTENT_CACHE="$share" RUNNER_OS=Linux
check "persistent: isolated Linux ARM64 ignores it" '' "$(out persistent)"

res;                         check "a pull request ref reads and never saves" false "$(out cache_save)"
res REF=refs/heads/main;     check "the default branch saves"                 true  "$(out cache_save)"
res REF=refs/heads/feat/x;   check "another branch never saves"               false "$(out cache_save)"
res REF=refs/heads/ DEFAULT_BRANCH=; check "no default branch in the payload never saves" false "$(out cache_save)"
res REF=refs/heads/main RUNNER_OS=Linux RUNNER_ARCH=X64; check "no cache, nothing to save (self-hosted Linux)" false "$(out cache_save)"
res REF=refs/heads/main RUNNER_PERSISTENT_CACHE="$share"; check "a persistent dir saves nothing to Actions" false "$(out cache_save)"
check "every cache step's save follows cache_save" ok "$(< "$TMP/saves")"

echo "setup-stack: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
