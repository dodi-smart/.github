#!/usr/bin/env bash
# Clean a workspace as `actions/checkout` would, except the Dart build-hook
# output, so native assets built by an earlier job on this runner are reused.
#
#   keep.sh <cap-mb>      (run in the checkout's root)
#
# Flutter's and Dart's native-asset hooks (OpenCV, SQLite and the like) compile
# for minutes and write to `.dart_tool/hooks_runner`, which `git clean -ffdx`
# deletes. Their output records absolute paths, so it is only reusable at the
# path that built it: a self-hosted slot, whose workspace path never changes.
# Never copy it elsewhere; a build restored on another path fails its first run.
#
# The hooks runner keys each build by its inputs and the Dart SDK, so a changed
# lockfile or toolchain rebuilds beside the old output; past the cap it is all
# dropped. Prints what it did on stderr.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: keep.sh <cap-mb>" >&2; exit 2; }
cap=$1
keep='.dart_tool/hooks_runner'

# Every package's hooks_runner, from the index rather than a walk of a tree an
# earlier job left dirty: the root (a pub workspace) and each pubspec beside it.
dirs=()
while IFS= read -r spec; do
  d="$(dirname "$spec")/$keep"
  if [ -d "$d" ]; then dirs+=("$d"); fi
done < <(git ls-files -- pubspec.yaml '*/pubspec.yaml')

mb=0
if [ "${#dirs[@]}" -gt 0 ]; then
  mb=$(du -smc "${dirs[@]}" | tail -n 1 | cut -f1)
  if [ "$mb" -gt "$cap" ]; then
    echo "dropping the kept builds: ${mb} MB is over the ${cap} MB cap" >&2
    rm -rf "${dirs[@]}"
    mb=0
  fi
fi

# What a clean checkout removes, minus the hook output.
git clean -ffdxq -e "**/$keep"
echo "kept ${mb} MB of Dart build-hook output (cap ${cap} MB)" >&2
