#!/usr/bin/env bash
# Run tests under QEMU with -d exec,nochain tracing for branch coverage.
# Same logic as run_tests.sh but adds trace output to build/qemu_trace.log.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_KERNEL="$PROJECT_DIR/build/test_kernel8.img"
TRACE_LOG="$PROJECT_DIR/build/qemu_trace.log"

if [ -n "${QEMU:-}" ]; then
    :
elif [ -x "$HOME/qemu-dev/qemu/build/qemu-system-aarch64" ]; then
    QEMU="$HOME/qemu-dev/qemu/build/qemu-system-aarch64"
elif command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="$(command -v qemu-system-aarch64)"
else
    echo "ERROR: no qemu-system-aarch64 found." >&2
    exit 1
fi
TIMEOUT=${QEMU_TIMEOUT:-30}

if [ ! -f "$TEST_KERNEL" ]; then
    echo "ERROR: $TEST_KERNEL not found." >&2
    exit 1
fi

echo "Running tests with branch tracing..."

OUTFILE=$(mktemp)
trap 'rm -f "$OUTFILE"' EXIT

"$QEMU" \
    -M raspi3b \
    -kernel "$TEST_KERNEL" \
    -nographic \
    -serial file:"$OUTFILE" \
    -device usb-net,netdev=net0 \
    -netdev user,id=net0 \
    -d in_asm \
    -D "$TRACE_LOG" \
    >/dev/null 2>&1 &
QEMU_PID=$!

ELAPSED=0
RESULT=""
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))
    if grep -q "ALL TESTS PASSED" "$OUTFILE" 2>/dev/null; then
        RESULT="pass"
        break
    elif grep -q "TESTS FAILED" "$OUTFILE" 2>/dev/null; then
        RESULT="fail"
        break
    fi
done

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null || true

cat "$OUTFILE"
echo "---"

case "$RESULT" in
    pass)
        echo "Tests passed. Trace: $TRACE_LOG"
        exit 0
        ;;
    fail)
        echo "Tests FAILED."
        exit 1
        ;;
    *)
        echo "ERROR: No test result (timeout/crash)."
        exit 1
        ;;
esac
