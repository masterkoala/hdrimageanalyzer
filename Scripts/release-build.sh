#!/usr/bin/env bash
# Release build and optional code signing for HDR Image Analyzer Pro.
# Usage: ./Scripts/release-build.sh [--sign IDENTITY] [--no-build]
#   --sign IDENTITY   Sign .build/release/HDRAnalyzerProApp with IDENTITY (e.g. "Developer ID Application: Name (TEAM_ID)")
#   --no-build        Skip swift build -c release (use existing release binary)
# Notarization is not run here; see Scripts/RELEASE_BUILD.md.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

RELEASE_BIN="$ROOT/.build/release/HDRAnalyzerProApp"
SIGN_IDENTITY=""
SKIP_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign)
      SIGN_IDENTITY="${2:-}"
      shift 2
      ;;
    --no-build)
      SKIP_BUILD=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--sign IDENTITY] [--no-build]" >&2
      exit 1
      ;;
  esac
done

if [[ "$SKIP_BUILD" != true ]]; then
  echo "==> Building release (swift build -c release)"
  swift build -c release
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "==> Release binary: $RELEASE_BIN"
  echo "==> To sign: $0 --sign 'Developer ID Application: Your Name (TEAM_ID)'"
  exit 0
fi

if [[ ! -f "$RELEASE_BIN" ]]; then
  echo "release-build.sh: Release binary not found: $RELEASE_BIN" >&2
  exit 1
fi

echo "==> Signing $RELEASE_BIN with identity: $SIGN_IDENTITY"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$RELEASE_BIN"

echo "==> Verifying signature"
codesign -dv --verbose=2 "$RELEASE_BIN"
echo "==> Release build and signing done. For notarization see Scripts/RELEASE_BUILD.md"
