#!/usr/bin/env bash
# Assert what keep.sh keeps and drops, in a throwaway repo: every other untracked
# or ignored file goes, as with a clean checkout, and the hook output stays, at
# the root and in packages, until it passes the cap.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dart-hooks-cache-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
expect() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

R="$WORK/repo"
mkdir -p "$R/pkg/core" && cd "$R" || exit 1
git init -q && echo a > pkg/core/a.dart && echo 'name: app' > pubspec.yaml && echo 'name: core' > pkg/core/pubspec.yaml
git add -A && git -c user.email=t@example.invalid -c user.name=t commit -qm init
build() { # what a job's hooks leave, at the root and in a package
  mkdir -p .dart_tool/hooks_runner/shared pkg/core/.dart_tool/hooks_runner
  echo built > .dart_tool/hooks_runner/shared/lib.so
  echo built > pkg/core/.dart_tool/hooks_runner/lib.so
}
leftovers() { mkdir -p .dart_tool/package_graph build; echo x > .dart_tool/package_graph/g.json; echo x > build/out; echo x > stray.txt; }
run() { "$HERE/keep.sh" "$@" 2>/dev/null; }

build; leftovers; run 3072
expect "untracked files go"                       test ! -e stray.txt
expect "build output goes"                        test ! -e build
expect "the rest of .dart_tool goes"              test ! -e .dart_tool/package_graph
expect "the root build stays"                     test -f .dart_tool/hooks_runner/shared/lib.so
expect "and a package build"                      test -f pkg/core/.dart_tool/hooks_runner/lib.so
expect "tracked files stay"                       test -f pkg/core/a.dart

dd if=/dev/zero of=.dart_tool/hooks_runner/shared/big bs=1048576 count=3 2>/dev/null
run 2
expect "over the cap drops the root build"        test ! -e .dart_tool/hooks_runner/shared/big
expect "and the package build"                    test ! -e pkg/core/.dart_tool/hooks_runner/lib.so

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
