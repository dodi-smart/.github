#!/usr/bin/env bash
# Tests for envfile.sh, bun-version.sh, defaults.sh and the resolve and next steps.
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

# --- action.yml, read once: the resolve and next scripts, setup-bun's no-cache, who saves, and the wiring.
python3 - "$HERE/action.yml" "$TMP" <<'EOF'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))['runs']['steps']
for id in ('resolve', 'next'):
    open(f'{sys.argv[2]}/{id}.sh', 'w').write([s for s in steps if s.get('id') == id][0]['run'])
bun = [s for s in steps if str(s.get('uses', '')).startswith('oven-sh/setup-bun@')][0]
open(f'{sys.argv[2]}/bun-no-cache', 'w').write(str(bun['with'].get('no-cache', '')))
# Only cache_save decides who writes: ~/.konan restores where it is false and
# saves (post step, on a miss) where it is true, under one exact key. The
# .next/cache pair follows the same gate and is the only one with restore-keys.
uses = lambda s: str(s.get('uses', ''))
konan = [s for s in steps if '.konan' in str((s.get('with') or {}).get('path', ''))]
by = {u: [s for s in konan if uses(s).startswith(u)] for u in ('actions/cache/restore@', 'actions/cache@')}
nxt = [s for s in steps if 'steps.next.outputs.key' in str((s.get('with') or {}).get('key', ''))]
nby = {u: [s for s in nxt if uses(s).startswith(u)] for u in ('actions/cache/restore@', 'actions/cache@')}
gradle = [s for s in steps if uses(s).startswith('gradle/actions/setup-gradle@')][0]['with']
rust = [s for s in steps if uses(s).startswith('Swatinem/rust-cache@')][0]['with']
bad = [m for m, broken in (
    ('want one restore-only and one saving konan step', len(konan) != 2 or any(len(v) != 1 for v in by.values())),
    ('a konan step has restore-keys', any(s['with'].get('restore-keys') for s in konan)),
    ('konan steps use different keys', len({s['with'].get('key') for s in konan}) != 1),
    ('restore-only konan step not gated on cache_save != true', "cache_save != 'true'" not in str(by['actions/cache/restore@'][:1])),
    ('saving konan step not gated on cache_save == true', "cache_save == 'true'" not in str(by['actions/cache@'][:1])),
    ('want one restore-only and one saving .next/cache step', len(nxt) != 2 or any(len(v) != 1 for v in nby.values())),
    ('.next/cache steps use different keys', len({s['with'].get('key') for s in nxt}) != 1),
    ('a .next/cache step has no restore-keys', any(not s['with'].get('restore-keys') for s in nxt)),
    ('restore-only .next/cache step not gated on mode and cache_save != true', any(g not in str(nby['actions/cache/restore@'][:1]) for g in ("steps.next.outputs.mode == 'actions'", "cache_save != 'true'"))),
    ('saving .next/cache step not gated on mode and cache_save == true', any(g not in str(nby['actions/cache@'][:1]) for g in ("steps.next.outputs.mode == 'actions'", "cache_save == 'true'"))),
    ('an inline actions/cache/save saves before the build', any(uses(s).startswith('actions/cache/save') for s in steps)),
    ('setup-gradle cache-read-only ignores cache_save', 'cache_save' not in str(gradle.get('cache-read-only'))),
    ('rust-cache save-if ignores cache_save', 'cache_save' not in str(rust.get('save-if'))),
) if broken]
open(f'{sys.argv[2]}/saves', 'w').write('; '.join(bad) or 'ok')
# The wiring: cache-enabled is resolve's cache_enabled, and the per-stack table
# lives in defaults.sh, not in the step that runs it.
doc = yaml.safe_load(open(sys.argv[1]))
dstep = [s for s in steps if s.get('id') == 'defaults'][0]
bad = [m for m, broken in (
    ('cache-enabled is not exposed', 'cache-enabled' not in doc['outputs']),
    ('cache-enabled is not steps.resolve.outputs.cache_enabled', doc['outputs'].get('cache-enabled', {}).get('value') != '${{ steps.resolve.outputs.cache_enabled }}'),
    ('the defaults step does not run defaults.sh', dstep['run'].strip() != '"$ACTION_PATH/defaults.sh"'),
    ('the defaults step still carries a case table', 'case ' in dstep['run']),
) if broken]
open(f'{sys.argv[2]}/wiring', 'w').write('; '.join(bad) or 'ok')
EOF

# --- defaults.sh: lock command, version files and the lockfile list.
dval() { # output -> that output's value, from the last run
  awk -v k="$1" '$0 == k "<<__SETUP_STACK_EOF__" { on = 1; next } $0 == "__SETUP_STACK_EOF__" { on = 0 } on' "$TMP/defaults.out"
}
defaults() { # stack output [VAR=VALUE...] -> that output's value, every override @stack unless a pair says otherwise
  local stack="$1" key="$2"; shift 2
  : > "$TMP/defaults.out"
  env -i PATH="$PATH" STACK="$stack" O_INSTALL=@stack O_LINT=@stack O_TYPECHECK=@stack O_TEST=@stack O_BUILD=@stack \
    O_DESIGN_LINT=@stack O_LOCK=@stack O_VERSION_FILES=@stack GITHUB_OUTPUT="$TMP/defaults.out" "$@" \
    "$HERE/defaults.sh" >/dev/null 2>&1
  dval "$key"
}
bare() { # [VAR=VALUE...] -> exit code of defaults.sh with only those variables set, plus a PATH and GITHUB_OUTPUT
  : > "$TMP/defaults.out"
  env -i PATH="$PATH" GITHUB_OUTPUT="$TMP/defaults.out" "$@" "$HERE/defaults.sh" >"$TMP/defaults.log" 2>&1
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

# Unset overrides are @stack, so a caller that only knows the stack (pr-checks' pick) can run it.
bare STACK=bun; rc=$?
check "defaults: STACK alone succeeds"                   0 "$rc"
check "defaults: unset install is the stack's"           'bun install --frozen-lockfile' "$(dval install)"
check "defaults: unset build is the stack's"             'bun run build' "$(dval build)"
check "defaults: unset lock is the stack's"              'bun install --lockfile-only' "$(dval lock)"
check "defaults: unset design-lint has none"             '' "$(dval design-lint)"
check "defaults: unset version-files is the stack's"     "$(defaults bun version-files)" "$(dval version-files)"
check "defaults: unset overrides equal @stack"           "$(defaults rust build)" "$(bare STACK=rust; dval build)"
check "defaults: an explicit empty build is empty"       '' "$(defaults bun build O_BUILD=)"
check "defaults: ...and leaves the other steps alone"    'bun run test:run' "$(defaults bun test O_BUILD=)"
check "defaults: an empty override beats unset"          '' "$(bare STACK=bun O_TEST=; dval test)"
check "defaults: a set override beats the stack"         'make t' "$(bare STACK=bun O_TEST='make t'; dval test)"
ml=$'bun run a\nbun run b "x y"\n  keeps $HOME `id` and = signs'
check "defaults: a multi-line override round-trips"      "$ml" "$(defaults bun test "O_TEST=$ml")"
check "defaults: ...and does not leak into the next output" 'bun run build' "$(defaults bun build "O_TEST=$ml")"
check "defaults: ...and every output is still named"     'install lint typecheck test build design-lint lock version-files lockfiles' \
  "$(sed -n 's/<<__SETUP_STACK_EOF__$//p' "$TMP/defaults.out" | paste -sd' ' -)"
bare STACK=nonesuch; rc=$?
check "defaults: an unknown stack exits non-zero"        1 "$rc"
check "defaults: ...with resolve's error wording"        1 "$(grep -c "::error::unknown stack 'nonesuch' (expected bun|node|gradle|android|flutter|rust|xcode|none)" "$TMP/defaults.log")"
check "defaults: ...and writes no output"                0 "$(wc -c < "$TMP/defaults.out" | tr -d ' ')"
bare; rc=$?
check "defaults: no stack at all is an unknown stack"    1 "$rc"
mkdir -p "$TMP/elsewhere"
check "defaults: runs from another cwd"                  "$(defaults bun lockfiles)" "$(cd "$TMP/elsewhere" && bare STACK=bun && dval lockfiles)"
check "defaults: ...and through a relative path"         "$(defaults bun lockfiles)" "$(cd "$HERE/.." && : > "$TMP/defaults.out" && env -i PATH="$PATH" STACK=bun GITHUB_OUTPUT="$TMP/defaults.out" bash setup-stack/defaults.sh >/dev/null 2>&1; dval lockfiles)"
check "defaults: lockfiles.re is read from beside it"    "$(cat "$HERE/lockfiles.re")" "$(defaults bun lockfiles)"

# The wiring in action.yml: the new output, and the table out of the step.
check "action.yml: cache-enabled and the defaults step"  ok "$(< "$TMP/wiring")"

# --- the resolve step: which runners get GitHub cache, setup-bun's included.
cached() { # environment os arch [isolate] [cache] -> cache_enabled
  : > "$TMP/resolve.out"
  env -i PATH="$PATH" STACK=bun ISOLATE="${4:-false}" CACHE="${5:-auto}" NEXT_CACHE=auto RUNNER_ENVIRONMENT="$1" RUNNER_OS="$2" \
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
  env -i PATH="$PATH" HOME="$TMP/home" STACK=gradle ISOLATE=false CACHE=auto NEXT_CACHE=auto RUNNER_ENVIRONMENT=self-hosted RUNNER_OS=macOS \
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

res NEXT_CACHE=bogus; rc=$?
check "next-cache: an invalid value fails resolve" 1 "$rc"
check "next-cache: the error names the input"      1 "$(grep -c '::error::next-cache must be' "$TMP/p.log")"
for v in auto true false; do res NEXT_CACHE="$v"; check "next-cache: $v is accepted" 0 "$?"; done

# --- cache_dir: the one directory that outlives the job.
res RUNNER_PERSISTENT_CACHE="$share";   check "cache_dir: the runner's declaration"      "$share" "$(out cache_dir)"
res RUNNER_PERSISTENT_CACHE="$share" RUNNER_OS=Linux RUNNER_ARCH=X64
check "cache_dir: a declaration beats the Linux home"                                    "$share" "$(out cache_dir)"
res RUNNER_OS=Linux RUNNER_ARCH=X64;    check "cache_dir: self-hosted Linux, the home"   "$TMP/home/.cache" "$(out cache_dir)"
res;                                    check "cache_dir: self-hosted macOS, none"       '' "$(out cache_dir)"
res RUNNER_ENVIRONMENT=github-hosted RUNNER_OS=Linux RUNNER_ARCH=X64; check "cache_dir: hosted, none" '' "$(out cache_dir)"
res RUNNER_OS=Linux RUNNER_ARCH=X64 ISOLATE=true; check "cache_dir: isolated, none"      '' "$(out cache_dir)"

# --- the next step: where .next/cache goes. `nrun` runs it in a fixture repo
# with a cache_dir under a fake HOME and stack bun, unless a pair says otherwise.
nfx() { rm -rf "${TMP:?}/home"; fx; }
cdir="$TMP/home/.cache"; home="$cdir/next"
nrun() { # dir [VAR=VALUE...]
  local dir="$1"; shift
  : > "$TMP/n.out"
  (cd "$dir" && env -i PATH="$PATH" GITHUB_REPOSITORY=acme/web STACK=bun NEXT_CACHE=auto ISOLATED=false \
    CACHE_ENABLED=false CACHE_DIR="$cdir" RUNNER_OS=Linux RUNNER_ARCH=X64 ACTION_PATH="$HERE" \
    GITHUB_OUTPUT="$TMP/n.out" "$@" bash "$TMP/next.sh" > "$TMP/n.log" 2>&1)
}
nout() { sed -n "s/^$1=//p" "$TMP/n.out"; }
npaths() { awk '$0 == "paths<<__SETUP_STACK_EOF__" { on = 1; next } $0 == "__SETUP_STACK_EOF__" { on = 0 } on' "$TMP/n.out" | paste -sd, -; }
link() { readlink "$1/.next/cache" || echo none; }

d="$(nfx)"; touch "$d/next.config.ts"; nrun "$d"
check "next: auto, root config, a cache_dir: link"            link "$(nout mode)"
check "next: the link targets <cache_dir>/next/<owner>-<repo>" "$home/acme-web" "$(link "$d")"

d="$(nfx)"; mkdir "$d/cloud"; touch "$d/cloud/next.config.mjs"; nrun "$d"
check "next: a subdirectory app links its own target"        "$home/acme-web/cloud" "$(link "$d/cloud")"
check "next: ...and the root gets none"                      none "$(link "$d")"

d="$(nfx)"; touch "$d/next.config.js"; mkdir -p "$d/apps/b/c"; touch "$d/apps/next.config.cjs" "$d/apps/b/c/next.config.mts"; nrun "$d"
check "next: three apps: root"                               "$home/acme-web" "$(link "$d")"
check "next: three apps: one level down"                     "$home/acme-web/apps" "$(link "$d/apps")"
check "next: a config four levels deep is not found"         none "$(link "$d/apps/b/c")"

d="$(nfx)"; mkdir -p "$d/node_modules/pkg" "$d/.git"; touch "$d/node_modules/pkg/next.config.js" "$d/.git/next.config.js"; nrun "$d"
check "next: configs in node_modules and .git are ignored"   off "$(nout mode)"

for st in rust gradle android flutter xcode none; do
  d="$(nfx)"; touch "$d/next.config.ts"; nrun "$d" STACK="$st"
  check "next: auto on stack $st is off"                     off "$(nout mode)"
done
d="$(nfx)"; touch "$d/next.config.ts"; nrun "$d" STACK=node
check "next: auto on stack node is on"                       link "$(nout mode)"

d="$(nfx)"; nrun "$d"
check "next: auto with no config is off"                     off "$(nout mode)"
nrun "$d" NEXT_CACHE=true
check "next: true with no config links the root"             "$home/acme-web" "$(link "$d")"
d="$(nfx)"; nrun "$d" NEXT_CACHE=true STACK=rust
check "next: true ignores the stack"                         link "$(nout mode)"

d="$(nfx)"; touch "$d/next.config.ts"; nrun "$d" NEXT_CACHE=false
check "next: false is off and links nothing"                 "off none" "$(nout mode) $(link "$d")"
nrun "$d" NEXT_CACHE=true ISOLATED=true CACHE_ENABLED=true
check "next: isolated is off, true and the cache included"   "off none no" "$(nout mode) $(link "$d") $([ -e "$TMP/home" ] && echo yes || echo no)"

share="$TMP/ci cache"; mkdir -p "$share"
d="$(nfx)"; touch "$d/next.config.ts"; nrun "$d" CACHE_DIR="$share"
check "next: a cache_dir with a space"                       "$share/next/acme-web" "$(link "$d")"
nrun "$d" CACHE_DIR="$share" CACHE_ENABLED=true
check "next: a cache_dir beats the Actions cache"            link "$(nout mode)"

# The Actions path keys on the lockfiles' index hashes, then the commit's tree.
d="$(nfx)"; touch "$d/next.config.ts"; mkdir "$d/cloud"; touch "$d/cloud/next.config.js"; echo 1 > "$d/bun.lock"
git -C "$d" init -q && git -C "$d" add . && git -C "$d" -c user.name=t -c user.email=t@t.test commit -qm one
nrun "$d" CACHE_DIR= CACHE_ENABLED=true; key1="$(nout key)"; restore1="$(nout restore)"
check "next: no cache_dir, the Actions cache"                actions "$(nout mode)"
check "next: ...with every app's path"                       ".next/cache,cloud/.next/cache" "$(npaths)"
check "next: ...and no link"                                 none "$(link "$d")"
check "next: the key is the restore prefix plus the tree"    "$restore1$(git -C "$d" rev-parse 'HEAD^{tree}')" "$key1"
check "next: the prefix names OS and arch"                   yes "$(case "$restore1" in next-Linux-X64-*-) echo yes ;; *) echo no ;; esac)"
echo 2 > "$d/cloud/page.tsx"; git -C "$d" add . && git -C "$d" -c user.name=t -c user.email=t@t.test commit -qm two
nrun "$d" CACHE_DIR= CACHE_ENABLED=true
check "next: a source change keeps the prefix"               "$restore1" "$(nout restore)"
check "next: ...and changes the key"                         no "$([ "$(nout key)" = "$key1" ] && echo yes || echo no)"
echo 3 > "$d/bun.lock"; git -C "$d" add . && git -C "$d" -c user.name=t -c user.email=t@t.test commit -qm three
nrun "$d" CACHE_DIR= CACHE_ENABLED=true
check "next: a lockfile change moves the prefix"             no "$([ "$(nout restore)" = "$restore1" ] && echo yes || echo no)"
nrun "$d" CACHE_DIR= CACHE_ENABLED=false
check "next: no cache_dir and the cache off is off, no key"  "off " "$(nout mode) $(nout key)"
d="$(nfx)"; touch "$d/next.config.ts"; nrun "$d" CACHE_DIR= CACHE_ENABLED=true
check "next: outside a git repo it still keys, and passes"   "actions 0" "$(nout mode) $(grep -c '::error' "$TMP/n.log")"

d="$(nfx)"; touch "$d/next.config.ts"; mkdir -p "$d/.next/cache/webpack"; touch "$d/.next/cache/webpack/stale"
nrun "$d"
check "next: a real .next/cache is replaced by the link"     "$home/acme-web" "$(link "$d")"
check "next: ...its stale content is not in the target"      no "$([ -e "$home/acme-web/webpack/stale" ] && echo yes || echo no)"
touch "$home/acme-web/kept"; nrun "$d"
check "next: a second run keeps the link and the cache"      "$home/acme-web yes" "$(link "$d") $([ -e "$home/acme-web/kept" ] && echo yes || echo no)"
check "next: ...without nesting a link inside the target"    no "$([ -e "$home/acme-web/cache" ] && echo yes || echo no)"

d="$(nfx)"; touch "$d/next.config.ts"; mkdir -p "$TMP/home"; : > "$cdir"
nrun "$d"; rc=$?
check "next: a target that cannot be made warns, is off, passes" "0 off 1" "$rc $(nout mode) $(grep -c '::warning::could not link' "$TMP/n.log")"

# --- defaults.sh <output>: one value on stdout, for a caller such as pick.
get() { local key="$1"; shift; env -i PATH="$PATH" "$@" "$HERE/defaults.sh" "$key" 2>/dev/null; }
check "an argument prints that one value"        'bun run build' "$(get build STACK=bun)"
check "...with an override applied"             'vitest run'    "$(get test STACK=bun O_TEST='vitest run')"
check "...empty when the repo has no such step"  ''              "$(get build STACK=bun O_BUILD=)"
check "...needs no GITHUB_OUTPUT"                0               "$(get install STACK=gradle >/dev/null; echo "$?")"

echo "setup-stack: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
