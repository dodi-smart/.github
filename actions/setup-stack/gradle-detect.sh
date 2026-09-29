#!/usr/bin/env bash
# Look at a checked-out repo and say what Gradle-side caching it can use.
#
# Usage: gradle-detect.sh [dir]   (default: the current directory)
# Prints, one per line, for $GITHUB_OUTPUT:
#   gradle=true|false      a gradlew sits at the root
#   kmp=true|false         the repo applies the Kotlin Multiplatform plugin
#   konan-key=<key>        exact cache key for ~/.konan, empty unless kmp=true
#
# Cheap on purpose: grep a few small files, never run Gradle. The key is runner
# OS + arch + the Kotlin version, because Kotlin/Native downloads its own LLVM
# per Kotlin release and per host. With no version to read it falls back to a
# hash of the files that could change it.
set -euo pipefail
cd "${1:-.}"

catalog=gradle/libs.versions.toml
gradle=false
[ -f gradlew ] && gradle=true

# Root and one level down: enough for the usual `shared/` or `composeApp/` module.
build_files=()
while IFS= read -r f; do build_files+=("$f"); done < <(
  find . -maxdepth 2 \( -name 'build.gradle' -o -name 'build.gradle.kts' \) \
    -not -path '*/build/*' -not -path './.*' | LC_ALL=C sort)
files=("${build_files[@]+"${build_files[@]}"}")
[ -f "$catalog" ] && files+=("$catalog")

kmp=false
pattern='kotlin\("multiplatform"\)|kotlin-multiplatform|kotlinMultiplatform|org\.jetbrains\.kotlin\.multiplatform'
if [ "$gradle" = "true" ] && [ "${#files[@]}" -gt 0 ] && grep -Eqs "$pattern" "${files[@]}"; then
  kmp=true
fi

key=""
if [ "$kmp" = "true" ]; then
  version=""
  if [ -f "$catalog" ]; then
    version="$(sed -nE 's/^[[:space:]]*kotlin[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$catalog" | head -n 1)"
  fi
  if [ -z "$version" ]; then
    version="h-$(cat "${files[@]}" | shasum -a 256 | cut -c1-16)"
  fi
  key="konan-${RUNNER_OS:-unknown}-${RUNNER_ARCH:-unknown}-${version}"
fi

printf 'gradle=%s\nkmp=%s\nkonan-key=%s\n' "$gradle" "$kmp" "$key"
