#!/usr/bin/env bash
# Put mikefarah yq on PATH and print its directory on stdout.
#
#   install-yq.sh <version>      e.g. v4.53.3
#
# mikefarah's yq specifically: zavet reads decision frontmatter with it, and the
# python `yq` of the same name takes different arguments, an easy and confusing
# way for every check to report NONE. One already on PATH is used as it is.
#
# Otherwise the release binary goes into $RUNNER_TOOL_CACHE, like osv-scanner
# and syft, so a self-hosted runner downloads a version once; /usr/local/bin
# goes with the job's container. The download is checked against the release's
# checksums-bsd before it is moved into place. Diagnostics go to stderr.
#
# Env: RUNNER_OS, RUNNER_ARCH, RUNNER_TOOL_CACHE. Linux only. test.sh puts a
# fake `curl` on PATH.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: install-yq.sh <version>" >&2; exit 2; }
version=$1

if command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -q mikefarah; then
  dirname "$(command -v yq)"
  exit 0
fi
if [ "${RUNNER_OS:-}" != Linux ]; then
  echo "::error::yq is missing and only a Linux build is installed here, not '${RUNNER_OS:-unknown}'" >&2; exit 1
fi
case "${RUNNER_ARCH:-}" in
  X64)   arch=amd64 ;;
  ARM64) arch=arm64 ;;
  *) echo "::error::no yq build for '${RUNNER_ARCH:-unknown}'" >&2; exit 1 ;;
esac
: "${RUNNER_TOOL_CACHE:?}"

asset="yq_linux_$arch"
dir="$RUNNER_TOOL_CACHE/yq/$version/$arch"
if [ -x "$dir/yq" ]; then
  echo "yq $version is already installed" >&2
  echo "$dir"
  exit 0
fi

sha256() { # file -> hex digest; macOS has shasum, not sha256sum
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Inside the cache, so the final move is a rename on one filesystem.
mkdir -p "$dir"
tmp="$(mktemp -d "$dir/download.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Into files, never a pipe: a retried transfer would write its bytes twice.
# --retry-max-time bounds all attempts together, well inside the job timeout.
fetch=(curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 60 --retry-max-time 150)
base="https://github.com/mikefarah/yq/releases/download/$version"
"${fetch[@]}" -o "$tmp/$asset" "$base/$asset"
"${fetch[@]}" -o "$tmp/checksums" "$base/checksums-bsd"

want="$(sed -n "s/^SHA256 ($asset) = //p" "$tmp/checksums")"
if [ -z "$want" ]; then
  echo "::error::the release's checksums-bsd lists no $asset" >&2; exit 1
fi
got="$(sha256 "$tmp/$asset")"
if [ "$got" != "$want" ]; then
  echo "::error::$asset does not match the release checksum (wanted $want, got $got)" >&2; exit 1
fi

chmod +x "$tmp/$asset"
mv "$tmp/$asset" "$dir/yq"
echo "installed yq $version ($arch)" >&2
echo "$dir"
