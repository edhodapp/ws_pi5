#!/usr/bin/env bash
# perf_set_baseline.sh — append a BASELINE_RESET marker to perf_runs.log
# so subsequent perf_check.py invocations ignore prior runs of the
# specified flavor.
#
# Use when an intentional code change costs perf and we accept the new
# (lower) value as the floor going forward — the policy is
# "functional > perf, intentional perf cost requires explicit baseline
# reset with written rationale."
#
# Usage:
#   scripts/perf_set_baseline.sh PERF=recv "VMIO migration: 5% drop at n=1024 accepted for keepalive throughput win"
#
# The marker becomes part of perf_runs.log permanently (auditable via
# git log on that file) and is honored by scripts/perf_check.py.
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <flavor> <rationale>" >&2
    echo "  example: $0 PERF=recv \"VMIO migration: 5% drop at n=1024 accepted\"" >&2
    exit 1
fi

FLAVOR="$1"
shift
RATIONALE="$*"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG="$PROJECT_DIR/hw_test/perf_runs.log"

if [ ! -f "$LOG" ]; then
    echo "ERROR: $LOG not found" >&2
    exit 1
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

{
    echo ""
    echo "--- BASELINE_RESET $FLAVOR $TIMESTAMP $RATIONALE ---"
} >> "$LOG"

echo "Appended BASELINE_RESET to $LOG:"
echo "  flavor:    $FLAVOR"
echo "  timestamp: $TIMESTAMP"
echo "  rationale: $RATIONALE"
echo
echo "Subsequent scripts/perf_check.py invocations will ignore prior"
echo "runs of $FLAVOR. Next perf run sets the new floor."
