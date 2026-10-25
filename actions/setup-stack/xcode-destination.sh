#!/usr/bin/env bash
# Resolve the simulator an iOS test or build runs on, as an xcodebuild
# -destination, and export it as XCODE_DESTINATION for every later step.
#
# A device name written into the command table (it was `iPhone 15`) breaks the
# day the runner image drops that simulator, and hosted images rotate theirs
# with every Xcode. `auto` asks the runner instead: the first iPhone of the
# newest iOS runtime it has, by id. Anything else is the caller's destination,
# used as given. With no iPhone at all it falls back to the generic simulator
# destination, which builds but cannot run tests, and says so.
#
# Arg: the `xcode-destination` input. Env: GITHUB_ENV, GITHUB_OUTPUT.
# test.sh puts a fake `xcrun` on PATH.
set -euo pipefail

want="${1:-auto}"
# GITHUB_ENV takes KEY=VALUE to the end of the line, so a second line would be a
# second variable.
case "$want" in
  *$'\n'*|*$'\r'*) echo "::error::xcode-destination must be one line"; exit 1 ;;
esac

if [ -n "$want" ] && [ "$want" != auto ]; then
  dest="$want"
else
  # `xcrun simctl list devices available` prints a `-- iOS 18.2 --` header per
  # runtime, then `    iPhone 16 Pro (<id>) (Shutdown)` per device. awk keeps
  # the first iPhone of the highest runtime; no sort -V, which BSD sort lacks.
  dev="$( { xcrun simctl list devices available 2>/dev/null || true; } | awk '
    /^-- iOS [0-9.]+ --$/ { split($3, v, "."); rt = v[1] * 1000 + v[2]; ios = 1; next }
    /^-- / { ios = 0; next }
    ios && /^[[:space:]]+iPhone / && !(rt in first) {
      line = $0; sub(/^[[:space:]]+/, "", line)
      if (match(line, /\([0-9A-Fa-f-]{36}\)/)) {
        first[rt] = substr(line, RSTART + 1, 36) "\t" substr(line, 1, RSTART - 2)
        if (rt > best) best = rt
      }
    }
    END { if (best != "") print first[best] }')"
  if [ -n "$dev" ]; then
    dest="platform=iOS Simulator,id=${dev%%$'\t'*}"
    echo "xcode-destination: ${dev#*$'\t'} (${dev%%$'\t'*})"
  else
    dest="generic/platform=iOS Simulator"
    echo "::warning title=No iPhone simulator::this runner lists no available iPhone simulator, so XCODE_DESTINATION is the generic one: builds work, xcodebuild test does not. Set xcode-destination to one the runner has."
  fi
fi

echo "XCODE_DESTINATION=$dest" >> "$GITHUB_ENV"
echo "destination=$dest" >> "$GITHUB_OUTPUT"
