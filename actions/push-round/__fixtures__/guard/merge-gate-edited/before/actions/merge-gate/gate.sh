#!/usr/bin/env bash
# merges only a green, approved head
set -euo pipefail
[ "$CHECKS" = success ] || exit 1
