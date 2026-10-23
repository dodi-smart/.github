#!/usr/bin/env bash
# Install the syft release binary and print its path on stdout.
#
# A static binary from the project's GitHub release, not its container image: no
# job on the self-hosted fleet may use a Docker container action (AGENTS.md,
# commitlint row), and a container would not see the workspace anyway. The
# archive is checked against the checksums file published beside it, so a
# truncated or corrupted asset stops here rather than running. That is integrity,
# not authenticity: the sums come from the same release as the archive.
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

# renovate: datasource=github-releases depName=anchore/syft
SYFT_VERSION=1.54.1

case "${RUNNER_OS:-}" in
  Linux) os=linux ;;
  macOS) os=darwin ;;
  *) echo "::error::syft is installed on Linux and macOS runners only, not '${RUNNER_OS:-unknown}'" >&2; exit 1 ;;
esac
case "${RUNNER_ARCH:-}" in
  X64)   arch=amd64 ;;
  ARM64) arch=arm64 ;;
  *) echo "::error::syft is installed on x64 and arm64 runners only, not '${RUNNER_ARCH:-unknown}'" >&2; exit 1 ;;
esac
: "${RUNNER_TOOL_CACHE:?}"

asset="syft_${SYFT_VERSION}_${os}_${arch}.tar.gz"
sums="syft_${SYFT_VERSION}_checksums.txt"
base="https://github.com/anchore/syft/releases/download/v$SYFT_VERSION"
parent="$RUNNER_TOOL_CACHE/syft/$SYFT_VERSION"
dest="$parent/$os-$arch/syft"

if [ -x "$dest" ]; then
  echo "syft $SYFT_VERSION is already installed" >&2
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

curl -fsSL --retry 3 -o "$tmp/$asset" "$base/$asset"
curl -fsSL --retry 3 -o "$tmp/$sums" "$base/$sums"

want="$(awk -v a="$asset" '$2 == a { print $1 }' "$tmp/$sums")"
if [ -z "$want" ]; then
  echo "::error::the release's checksums file lists no $asset" >&2
  exit 1
fi
got="$(sha256 "$tmp/$asset")"
if [ "$got" != "$want" ]; then
  echo "::error::$asset does not match the release checksum (wanted $want, got $got)" >&2
  exit 1
fi

# The archive holds the binary beside its licence and readme; only the binary is kept.
if ! tar -xzf "$tmp/$asset" -C "$tmp" syft 2>/dev/null || [ ! -f "$tmp/syft" ]; then
  echo "::error::$asset holds no syft binary" >&2
  exit 1
fi
chmod +x "$tmp/syft"
mkdir -p "$(dirname "$dest")"
mv "$tmp/syft" "$dest"
echo "installed syft $SYFT_VERSION ($os $arch)" >&2
echo "$dest"
