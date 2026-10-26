#!/usr/bin/env bash
# Install one of the two SBOM generators, syft (the default) or cdxgen (`install.sh
# cdxgen`, for a Gradle build: see sbom.sh), and print its path on stdout.
#
# A static binary from the project's GitHub release, not its container image: no
# job on the self-hosted fleet may use a Docker container action (AGENTS.md,
# commitlint row), and a container would not see the workspace anyway. The
# archive is checked against the checksums file published beside it, so a
# truncated or corrupted asset stops here rather than running. That is integrity,
# not authenticity: the sums come from the same release as the archive.
#
# cdxgen publishes one sha256 file per binary rather than one checksums file,
# and the binary itself rather than an archive; the `-slim` build, which leaves
# out the bundled tools a Gradle scan never runs (a third of the size).
#
# Each version is pinned exact, and this is the only place it is written. The
# marker comment is what Renovate's regex manager (renovate.json) reads, so it
# stays on the line directly above the version; test.sh fails if they part.
#
# A copy of the same version already in $RUNNER_TOOL_CACHE is reused, so a
# self-hosted runner downloads it once. Diagnostics go to stderr: stdout is the
# path and nothing else.
#
# Arg: syft | cdxgen. Env: RUNNER_OS, RUNNER_ARCH, RUNNER_TOOL_CACHE. test.sh puts
# a fake `curl` on PATH.
set -euo pipefail

# renovate: datasource=github-releases depName=anchore/syft
SYFT_VERSION=1.55.0
# renovate: datasource=github-releases depName=CycloneDX/cdxgen
CDXGEN_VERSION=13.4.0

tool="${1:-syft}"
case "${RUNNER_OS:-}" in
  Linux) os=linux ;;
  macOS) os=darwin ;;
  *) echo "::error::$tool is installed on Linux and macOS runners only, not '${RUNNER_OS:-unknown}'" >&2; exit 1 ;;
esac
case "${RUNNER_ARCH:-}" in
  X64)   arch=amd64 ;;
  ARM64) arch=arm64 ;;
  *) echo "::error::$tool is installed on x64 and arm64 runners only, not '${RUNNER_ARCH:-unknown}'" >&2; exit 1 ;;
esac
case "$tool" in
  syft)
    version="$SYFT_VERSION"
    asset="syft_${version}_${os}_${arch}.tar.gz"
    sums="syft_${version}_checksums.txt"
    base="https://github.com/anchore/syft/releases/download/v$version" ;;
  cdxgen)
    version="$CDXGEN_VERSION"
    asset="cdxgen-${os}-${arch}-slim"
    sums="$asset.sha256"
    base="https://github.com/CycloneDX/cdxgen/releases/download/v$version" ;;
  *) echo "::error::install.sh installs syft or cdxgen, not '$tool'" >&2; exit 1 ;;
esac
: "${RUNNER_TOOL_CACHE:?}"
parent="$RUNNER_TOOL_CACHE/$tool/$version"
dest="$parent/$os-$arch/$tool"

if [ -x "$dest" ]; then
  echo "$tool $version is already installed" >&2
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

curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 120 -o "$tmp/$asset" "$base/$asset"
curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 120 -o "$tmp/$sums" "$base/$sums"

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

# syft's archive holds the binary beside its licence and readme; only the
# binary is kept. cdxgen's asset is the binary.
if [ "$tool" = cdxgen ]; then
  mv "$tmp/$asset" "$tmp/cdxgen"
elif ! tar -xzf "$tmp/$asset" -C "$tmp" syft 2>/dev/null || [ ! -f "$tmp/syft" ]; then
  echo "::error::$asset holds no syft binary" >&2
  exit 1
fi
chmod +x "$tmp/$tool"
mkdir -p "$(dirname "$dest")"
mv "$tmp/$tool" "$dest"
echo "installed $tool $version ($os $arch)" >&2
echo "$dest"
