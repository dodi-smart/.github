#!/usr/bin/env bash
# The conventional commands per stack, resolved against a caller's overrides:
# the one copy of the table, so pr-checks' `pick` can ask it too.
#
# Reads STACK and the overrides O_INSTALL O_LINT O_TYPECHECK O_TEST O_BUILD
# O_DESIGN_LINT O_IOS O_LOCK O_VERSION_FILES. Unset or "@stack" is the stack's
# command, empty is "no such step", anything else is taken literally.
# Writes every output to $GITHUB_OUTPUT in delimiter form; with an argument,
# `STACK=bun defaults.sh build`, prints that one value instead.
set -euo pipefail

STACK="${STACK:-}"
want="${1:-}"
here="$(dirname "${BASH_SOURCE[0]}")"

install=""; lint=""; typecheck=""; test=""; build=""; ios=""; lock=""; versions=""
js='package\.json|\.nvmrc|\.node-version|\.bun-version'
gradle='gradle/wrapper/gradle-wrapper\.properties|gradle/libs\.versions\.toml|[^/]+\.gradle(\.kts)?|gradle\.properties'
case "$STACK" in
  bun)
    install="bun install --frozen-lockfile"
    lint="bun run lint"; typecheck="bun run typecheck"
    test="bun run test:run"; build="bun run build"
    lock="bun install --lockfile-only"; versions="$js" ;;
  node)
    install="npm ci"
    lint="npm run lint"; typecheck="npm run typecheck"
    test="npm test"; build="npm run build"
    lock="npm install --package-lock-only --ignore-scripts"; versions="$js" ;;
  gradle|android)
    # Gradle resolves on demand; there is no separate install step.
    lint="./gradlew ktlintCheck"
    test="./gradlew test"; build="./gradlew assemble"
    lock="./gradlew dependencies --write-locks"; versions="$gradle" ;;
  kmm)
    # The shared module's JVM-side and host tests plus the Android unit tests,
    # on Linux. The Kotlin plugin disables Apple targets on a host that cannot
    # build them, so neither command touches iOS there; `ios` is the macOS half.
    lint="./gradlew ktlintCheck"
    test="./gradlew allTests testDebugUnitTest"; build="./gradlew assemble"
    ios="./gradlew iosSimulatorArm64Test"
    lock="./gradlew dependencies --write-locks"; versions="$gradle" ;;
  flutter)
    install="flutter pub get"
    lint="flutter analyze"
    test="flutter test"; build="flutter build apk --debug"
    ios="flutter build ios --simulator --debug"
    lock="flutter pub get"; versions="pubspec\.yaml|$gradle" ;;
  rust)
    lint="cargo clippy --all-targets -- -D warnings"
    typecheck="cargo check --all-targets"
    test="cargo test --all"; build="cargo build --release"
    lock="cargo update --workspace"; versions='Cargo\.toml|rust-toolchain(\.toml)?' ;;
  xcode)
    lint="swiftlint --strict"
    # XCODE_DESTINATION is setup-stack's `xcode-destination`, resolved on macOS.
    test="xcodebuild test -scheme \"\$SCHEME\" -destination \"\$XCODE_DESTINATION\""
    build="xcodebuild build -scheme \"\$SCHEME\""
    ios="xcodebuild build -scheme \"\$SCHEME\" -destination \"\$XCODE_DESTINATION\" CODE_SIGNING_ALLOWED=NO"
    lock="swift package resolve"; versions="Package\.swift|$gradle" ;;
  none) : ;;
  *) echo "::error::unknown stack '$STACK' (expected bun|node|gradle|android|kmm|flutter|rust|xcode|none)"; exit 1 ;;
esac

# "@stack" or unset -> the conventional command above. Anything else, empty
# string included, is taken literally.
pick() { if [ "$1" = "@stack" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# Delimiter form, not `echo "k=v"`. A caller's command may span lines,
# which `k=v` would write into $GITHUB_OUTPUT as if they were outputs.
emit() {
  if [ -n "$want" ]; then
    [ "$1" != "$want" ] || printf '%s\n' "$2"
    return 0
  fi
  {
    printf '%s<<__SETUP_STACK_EOF__\n' "$1"
    printf '%s\n' "$2"
    printf '__SETUP_STACK_EOF__\n'
  } >> "$GITHUB_OUTPUT"
}
emit install   "$(pick "${O_INSTALL-@stack}" "$install")"
emit lint      "$(pick "${O_LINT-@stack}" "$lint")"
emit typecheck "$(pick "${O_TYPECHECK-@stack}" "$typecheck")"
emit test      "$(pick "${O_TEST-@stack}" "$test")"
emit build     "$(pick "${O_BUILD-@stack}" "$build")"
# No conventional command for any stack: this is opt-in only.
emit design-lint "$(pick "${O_DESIGN_LINT-@stack}" "")"
# The iOS half of a mobile stack, run only on macOS by pr-checks' `ios` job.
emit ios       "$(pick "${O_IOS-@stack}" "$ios")"
emit lock      "$(pick "${O_LOCK-@stack}" "$lock")"
# Toolchain pins in mise apply to every stack, and so does the hk schema pin
# that moves with the hk binary.
emit version-files "$(pick "${O_VERSION_FILES-@stack}" "(^|/)(${versions:+$versions|}mise\.toml|\.tool-versions|hk\.pkl)\$")"
emit lockfiles "$(cat "$here/lockfiles.re")"
