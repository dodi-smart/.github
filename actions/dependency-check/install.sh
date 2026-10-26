#!/usr/bin/env bash
# Install the osv-scanner release binary and print its path on stdout.
#
# A static binary from the project's GitHub release, not its container image: no
# job on the self-hosted fleet may use a Docker container action (AGENTS.md,
# commitlint row), and a container would not see the workspace anyway. The
# download is checked against the SHA256SUMS file published beside it, so a
# truncated or corrupted asset stops here rather than running. That is integrity,
# not authenticity: the sums come from the same release as the binary.
#
# The version is pinned exact, and this is the only place it is written. The
# marker comment is what Renovate's regex manager (renovate.json) reads, so it
# stays on the line directly above the version; test.sh fails if they part.
#
# A copy of the same version already in $RUNNER_TOOL_CACHE is reused, so a
# self-hosted runner downloads it once. Diagnostics go to stderr: stdout is the
# path and nothing else.
#
# Env: RUNNER_OS, RUNNER_ARCH, RUNNER_TOOL_CACHE. test.sh puts a fake `curl` on PATH.
set -euo pipefail

# renovate: datasource=github-releases depName=google/osv-scanner
OSV_SCANNER_VERSION=2.7.0

case "${RUNNER_OS:-}" in
  Linux) os=linux ;;
  macOS) os=darwin ;;
  *) echo "::error::osv-scanner is installed on Linux and macOS runners only, not '${RUNNER_OS:-unknown}'" >&2; exit 1 ;;
esac
case "${RUNNER_ARCH:-}" in
  X64)   arch=amd64 ;;
  ARM64) arch=arm64 ;;
  *) echo "::error::osv-scanner is installed on x64 and arm64 runners only, not '${RUNNER_ARCH:-unknown}'" >&2; exit 1 ;;
esac
: "${RUNNER_TOOL_CACHE:?}"

asset="osv-scanner_${os}_${arch}"
base="https://github.com/google/osv-scanner/releases/download/v$OSV_SCANNER_VERSION"
parent="$RUNNER_TOOL_CACHE/osv-scanner/$OSV_SCANNER_VERSION"
dest="$parent/$os-$arch/osv-scanner"

if [ -x "$dest" ]; then
  echo "osv-scanner $OSV_SCANNER_VERSION is already installed" >&2
  echo "$dest"
  exit 0
fi

sha256() { # file -> hex digest; macOS has shasum, not sha256sum
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Inside the cache, so the final move is a rename on one filesystem: a job
# killed halfway never leaves a half-written file at $dest. An explicit
# template, because macOS mktemp ignores TMPDIR.
mkdir -p "$parent"
tmp="$(mktemp -d "$parent/download.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# --retry-max-time bounds all attempts together, well inside the job timeout.
fetch=(curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 60 --retry-max-time 150)
"${fetch[@]}" -o "$tmp/$asset" "$base/$asset"
"${fetch[@]}" -o "$tmp/SHA256SUMS" "$base/osv-scanner_SHA256SUMS"

want="$(awk -v a="$asset" '$2 == a { print $1 }' "$tmp/SHA256SUMS")"
if [ -z "$want" ]; then
  echo "::error::the release's SHA256SUMS lists no $asset" >&2
  exit 1
fi
got="$(sha256 "$tmp/$asset")"
if [ "$got" != "$want" ]; then
  echo "::error::$asset does not match the release checksum (wanted $want, got $got)" >&2
  exit 1
fi

chmod +x "$tmp/$asset"
mkdir -p "$(dirname "$dest")"
mv "$tmp/$asset" "$dest"
echo "installed osv-scanner $OSV_SCANNER_VERSION ($os $arch)" >&2
echo "$dest"
