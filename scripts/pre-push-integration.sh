#!/usr/bin/env bash
# Pre-push hook: run integration tests + perf stats on Pi 4 hardware.
#
# Phases:
#   1. Flash default build → L2 functional tests
#   2. Flash PERF=recv build → L2 perf tests (with stats)
#   3. Restore default build
#
# Perf stats are appended to hw_test/perf_runs.log tagged with
# the commit hash for regression tracking.
#
# Install: ln -sf ../../scripts/pre-push-integration.sh .git/hooks/pre-push
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../../Makefile" ]; then
    PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
    PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
cd "$PROJECT_DIR"

VENV=".venv/bin/python"
if [ ! -x "$VENV" ]; then
    echo "pre-push: .venv not found, skipping integration tests"
    exit 0
fi

COMMIT=$(git rev-parse --short HEAD)
PERF_LOG="$PROJECT_DIR/hw_test/perf_runs.log"

kill_stale() {
    $VENV -c "
import sys; sys.path.insert(0, 'scripts')
from hw_send import kill_stale_hw_send
kill_stale_hw_send()
" 2>/dev/null || true
}

# flash_and_wait BUILD_LOG [MAKE_ARGS...]
# Builds, flashes in background, waits for GENET init, verifies ping.
flash_and_wait() {
    local logfile="$1"; shift
    kill_stale
    make clean > /dev/null 2>&1
    make "$@" > /dev/null 2>&1
    $VENV scripts/hw_send.py kernel8.img > "$logfile" 2>&1 &
    local hw_pid=$!
    # hw_send typically takes ~35 s (5182 records @ ~150 rec/s + DTR
    # reset + post-BOOT handshake). Give 75 s so a transiently slow
    # serial link doesn't false-fail the whole integration suite.
    for i in $(seq 1 75); do
        if grep -q 'GENET Gigabit Ethernet' "$logfile" 2>/dev/null; then
            break
        fi
        sleep 1
    done
    if ! grep -q 'GENET Gigabit Ethernet' "$logfile"; then
        kill "$hw_pid" 2>/dev/null || true
        echo "FAIL: Pi 4 did not boot"
        exit 1
    fi
    if ! ping -c 2 -W 2 10.0.0.2 > /dev/null 2>&1; then
        kill "$hw_pid" 2>/dev/null || true
        echo "FAIL: Pi 4 not reachable"
        exit 1
    fi
}

echo "=== pre-push: L2 integration tests (commit $COMMIT) ==="

# --- Phase 1: functional tests (default build) ---
echo "--- Phase 1: flash default build ---"
flash_and_wait /tmp/pre-push-flash.log PLATFORM=pi4

echo "--- Phase 1: running L2 functional tests ---"
L2_FUNC_OUT=$(mktemp)
if ! HW_TEST=1 $VENV -m pytest hw_test/ -m l2 --tb=short -q -s 2>&1 | tee "$L2_FUNC_OUT"; then
    rm -f "$L2_FUNC_OUT"
    echo "FAIL: L2 functional tests failed"
    exit 1
fi
echo "--- Phase 1: perf stats (commit $COMMIT) ---"
FUNC_STATS=$(grep -E 'RTT baseline|BURST_STATS|PERF_STATS' "$L2_FUNC_OUT" || true)
if [ -n "$FUNC_STATS" ]; then
    echo "$FUNC_STATS"
    {
        echo "--- $COMMIT $(date -u +%Y-%m-%dT%H:%M:%SZ) default ---"
        echo "$FUNC_STATS"
    } >> "$PERF_LOG"
else
    echo "(no perf stats in default build)"
fi
rm -f "$L2_FUNC_OUT"

# --- Phase 2: perf tests (PERF=recv build) ---
echo "--- Phase 2: flash PERF=recv build ---"
flash_and_wait /tmp/pre-push-flash-perf.log PLATFORM=pi4 PERF=recv

echo "--- Phase 2: running L2 perf tests ---"
L2_PERF_OUT=$(mktemp)
if ! HW_TEST=1 $VENV -m pytest hw_test/ -m l2 --tb=short -q -s 2>&1 | tee "$L2_PERF_OUT"; then
    rm -f "$L2_PERF_OUT"
    kill_stale
    echo "FAIL: L2 perf tests failed"
    exit 1
fi
echo "--- Phase 2: perf stats (commit $COMMIT, PERF=recv) ---"
PERF_STATS=$(grep -E 'RTT baseline|BURST_STATS|PERF_STATS' "$L2_PERF_OUT" || true)
if [ -n "$PERF_STATS" ]; then
    echo "$PERF_STATS"
    {
        echo "--- $COMMIT $(date -u +%Y-%m-%dT%H:%M:%SZ) PERF=recv ---"
        echo "$PERF_STATS"
    } >> "$PERF_LOG"
else
    echo "(no perf stats)"
fi
rm -f "$L2_PERF_OUT"

# --- Phase 3: restore default build ---
echo "--- Phase 3: restoring default build ---"
flash_and_wait /tmp/pre-push-flash-restore.log PLATFORM=pi4
kill_stale
echo "Default build restored."

echo "=== pre-push: all integration tests passed ==="
