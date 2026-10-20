#!/usr/bin/env bash
# Install the pinned squawk release as one static binary, outside the checkout.
#
# squawk publishes a plain executable per platform with no archive and no
# checksum file, but GitHub records a sha256 digest for every release asset. That
# digest is read from the API and compared with the download, so a truncated or
# swapped file fails here rather than being run.
#
# Prints the directory holding `squawk` on stdout (everything else goes to
# stderr). Env: GH_TOKEN, RUNNER_TEMP. test.sh also uses `--asset <os> <arch>`
# and SQUAWK_REPO.
set -euo pipefail

# The one place the version lives. Renovate bumps it through the regex manager
# in this repo's renovate.json, and a bump releases like any chore(deps) because
# it changes what callers run.
# renovate: datasource=github-releases depName=sbdchd/squawk
SQUAWK_VERSION="v2.70.0"

REPO="${SQUAWK_REPO:-sbdchd/squawk}"

# `uname -m` -> the release asset's name. Every runner this job lands on, the
# light pool or a hosted one, is glibc Linux. `arm64` is macOS's spelling, so
# test.sh runs on a laptop too.
asset_name() {
  case "$1" in
    x86_64)        echo squawk-linux-x64 ;;
    aarch64|arm64) echo squawk-linux-arm64 ;;
    *) echo "no squawk build for the architecture '$1'" >&2; return 1 ;;
  esac
}

if [ "${1:-}" = "--asset" ]; then
  asset_name "$2"
  exit $?
fi

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

asset=$(asset_name "$(uname -m)")

: "${RUNNER_TEMP:?}"
dir="$RUNNER_TEMP/squawk/$SQUAWK_VERSION"
mkdir -p "$dir"
tmp=$(mktemp -d "$RUNNER_TEMP/squawk-dl.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "Installing squawk $SQUAWK_VERSION ($asset)" >&2
want=$(gh release view "$SQUAWK_VERSION" -R "$REPO" --json assets \
  --jq ".assets[] | select(.name == \"$asset\") | .digest // \"\"")
want="${want#sha256:}"
if [ -z "$want" ]; then
  # Without a digest there is nothing to verify the download against, and an
  # unverified binary is not run.
  echo "::error::the $SQUAWK_VERSION release lists no sha256 digest for $asset, so the download cannot be verified" >&2
  exit 1
fi
gh release download "$SQUAWK_VERSION" -R "$REPO" -p "$asset" -D "$tmp" >&2
got=$(sha256 "$tmp/$asset")
if [ "$got" != "$want" ]; then
  echo "::error::$asset does not match the release's sha256 digest (got $got, wanted $want)" >&2
  exit 1
fi
chmod +x "$tmp/$asset"
mv "$tmp/$asset" "$dir/squawk"
# A binary built for the wrong libc or architecture fails here, by name.
"$dir/squawk" --version >&2
echo "$dir"
