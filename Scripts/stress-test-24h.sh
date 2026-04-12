#!/usr/bin/env bash
# INT-006: 24-hour continuous capture stress test.
# Requires DeckLink hardware with active signal. Run from project root.
#
# Usage:
#   ./Scripts/stress-test-24h.sh [PROJECT_ROOT]
#
# Optional env:
#   CAPTURE_STRESS_MAX_DROPS  - allowed drop count (default 0)
#   STRESS_LOG                - if set, append test output to this file
#
# Procedure: Scripts/STRESS_TEST_24H.md

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(dirname "$SCRIPT_DIR")}"

cd "$ROOT"

export CAPTURE_STRESS_24H=1
# Duration is fixed to 24h in testCaptureStress24HourRun
export CAPTURE_STRESS_DURATION=86400

echo "==> INT-006 24-hour capture stress test (DeckLink required)"
echo "    Start: $(TZ=UTC date +%Y-%m-%dT%H:%M:%SZ)"
echo "    Expected end: ~24h later"

run_test() {
    swift test --filter "CaptureStressTests.testCaptureStress24HourRun" "$@"
}

if [[ -n "$STRESS_LOG" ]]; then
    run_test 2>&1 | tee -a "$STRESS_LOG"
else
    run_test
fi

echo "==> INT-006 24h stress test finished: $(TZ=UTC date +%Y-%m-%dT%H:%M:%SZ)"
