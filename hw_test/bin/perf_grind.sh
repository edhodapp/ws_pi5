#!/bin/bash
# perf_grind.sh — one-command per-commit validation loop for the
# GENET hot-path optimization work.
#
# Runs the full discipline on each grind commit:
#
#   1. make clean && make test               (Pi 3 / QEMU unit tests)
#   2. make clean && make PLATFORM=pi4 PERF=<stage>  (build instrumented)
#   3. Kill stale hw_send.py processes, flash the kernel to the Pi 4
#   4. Wait for the Pi to reach "GENET Gigabit Ethernet initialized"
#   5. HW_TEST=1 pytest hw_test/ -m l2     (full L2 integration suite)
#   6. hw_test/bin/burst_stats.py 1024 10  (10-trial per-stage stats)
#
# Any step that fails causes the script to exit non-zero. The final
# stats table from burst_stats.py is the measurement of record for
# the commit under test.
#
# Usage:
#   hw_test/bin/perf_grind.sh [stage]
#
#     stage  — PERF build flavor: recv, send, dispatch, or all
#              (default: all)
#
# Example workflow for one grind tweak:
#
#   $ edit platform/pi/drivers/genet.S
#   $ hw_test/bin/perf_grind.sh recv
#   ...validation loop runs...
#   ...stats table at bottom...
#   $ git commit -am "..."
#   $ hw_test/bin/perf_grind.sh recv     # post-commit re-measure for log

set -euo pipefail

# --- Config --------------------------------------------------------------

BURST_SIZE="${BURST_SIZE:-1024}"
TRIALS="${TRIALS:-10}"
# Boot deadline measured from hw_send.py spawn in Step 3. Budget:
#   ~12s for chainloader to transfer all records at current baud
#   ~3s max for Pi boot + genet_init's PHY auto-negotiation wait
#   ~15s margin for the AN "retry forever" path if the link is slow
# Total 30s comfortably covers a fresh boot with normal AN timing.
BOOT_DEADLINE_S="${BOOT_DEADLINE_S:-30}"
BOOT_READY_TOKEN="GENET Gigabit Ethernet initialized"
HW_SEND_LOG="${HW_SEND_LOG:-/tmp/perf_grind_hw_send.log}"

STAGE="${1:-all}"
case "$STAGE" in
    recv|send|dispatch|all) ;;
    *)
        echo "ERROR: unknown stage '$STAGE' (expected: recv, send, dispatch, all)" >&2
        exit 2
        ;;
esac

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_DIR"

# --- Helpers -------------------------------------------------------------

log() {
    printf '\n\033[1;36m== %s ==\033[0m\n' "$*"
}

die() {
    printf '\n\033[1;31mFAIL: %s\033[0m\n' "$*" >&2
    exit 1
}

kill_stale_hw_send() {
    # Previous perf_grind.sh or manual hw_send.py invocations may
    # have left background processes holding /dev/ttyUSB0. Reap them
    # so this run can flash cleanly.
    local pids
    pids=$(pgrep -f 'scripts/hw_send\.py' 2>/dev/null || true)
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill $pids 2>/dev/null || true
        sleep 1
    fi
}

wait_for_boot() {
    local deadline=$((SECONDS + BOOT_DEADLINE_S))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if grep -q "$BOOT_READY_TOKEN" "$HW_SEND_LOG" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    echo "--- hw_send log tail ---" >&2
    tail -20 "$HW_SEND_LOG" >&2 || true
    die "Pi did not reach '$BOOT_READY_TOKEN' within ${BOOT_DEADLINE_S}s"
}

# --- Step 1: unit tests --------------------------------------------------

log "Step 1/6: Off-hardware unit tests (make clean && make test)"
make clean >/dev/null
if ! make test 2>&1 | tail -20; then
    die "Unit tests failed"
fi
# make test prints "Tests passed." on success; fail-fast already
# handled above via pipe exit code (set -o pipefail).

# --- Step 2: build the instrumented kernel -------------------------------

log "Step 2/6: Build PERF=$STAGE kernel (make clean && make PLATFORM=pi4 PERF=$STAGE)"
make clean >/dev/null
make PLATFORM=pi4 PERF="$STAGE" 2>&1 | tail -5 || die "Build failed"
if [ ! -f kernel8.img ]; then
    die "kernel8.img not produced by build"
fi
size=$(stat -c%s kernel8.img)
printf "  kernel8.img: %d bytes\n" "$size"

# --- Step 3: flash -------------------------------------------------------

log "Step 3/6: Flash kernel to Pi 4"
kill_stale_hw_send
# hw_send.py stays alive after flash, reading kernel output from the
# serial port. We background it, wait for the boot token, and leave
# it running — pytest uses Ethernet, not serial, so the running
# hw_send doesn't conflict. Next perf_grind.sh invocation cleans up
# via kill_stale_hw_send.
: > "$HW_SEND_LOG"
python3 scripts/hw_send.py kernel8.img > "$HW_SEND_LOG" 2>&1 &
HW_SEND_PID=$!

# --- Step 4: wait for boot ----------------------------------------------

log "Step 4/6: Wait for boot ('$BOOT_READY_TOKEN' in UART log)"
wait_for_boot
printf "  Pi booted successfully\n"

# --- Step 5: L2 integration suite ---------------------------------------

log "Step 5/6: Full L2 test suite (HW_TEST=1 pytest hw_test/ -m l2)"
if ! HW_TEST=1 .venv/bin/pytest hw_test/ -m l2 2>&1 | tail -10; then
    die "L2 suite failed"
fi

# --- Step 6: 10-trial burst_stats ---------------------------------------

log "Step 6/6: ${TRIALS}-trial burst_stats at N=${BURST_SIZE}"
hw_test/bin/burst_stats.py "$BURST_SIZE" "$TRIALS" 2>&1 || die "burst_stats failed"

# --- Done ---------------------------------------------------------------

log "perf_grind.sh (PERF=$STAGE) — ALL STEPS PASSED"
printf "\nNext steps:\n"
printf "  * Compare the stats table above against the latest entry in\n"
printf "    hw_test/perf_history.md.\n"
printf "  * If this is a grind commit, append the new entry manually.\n"
printf "  * If the measurement looks worse than baseline, revert the tweak.\n"
