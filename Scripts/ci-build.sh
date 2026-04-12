#!/usr/bin/env bash
# CI build script: swift build + swift test from project root.
# Usage: ./Scripts/ci-build.sh [PROJECT_ROOT]
# If PROJECT_ROOT is omitted, uses directory containing Scripts/ (project root).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(dirname "$SCRIPT_DIR")}"

cd "$ROOT"

echo "==> Building from $ROOT"
if ! swift build; then
  echo "ci-build.sh: swift build failed"
  exit 1
fi

echo "==> Running tests"
if ! swift test; then
  echo "ci-build.sh: swift test failed"
  exit 1
fi

echo "==> CI build passed"
exit 0
