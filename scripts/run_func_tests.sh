#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_KERNEL="$PROJECT_DIR/build/func_kernel8.img"
TIMEOUT=${QEMU_TIMEOUT:-30}

if [ ! -f "$TEST_KERNEL" ]; then
    echo "ERROR: Functional test kernel not found at $TEST_KERNEL"
    echo "Run 'make build/func_kernel8.img' first."
    exit 1
fi

echo "Running functional tests on QEMU raspi3b..."

OUTFILE=$(mktemp)
trap "rm -f $OUTFILE" EXIT

# Run QEMU in background with serial output to file
qemu-system-aarch64 \
    -M raspi3b \
    -kernel "$TEST_KERNEL" \
    -nographic \
    -serial file:"$OUTFILE" \
    -device usb-net,netdev=net0 \
    -netdev user,id=net0 \
    >/dev/null 2>&1 &
QEMU_PID=$!

# Poll for test result or timeout
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

# Kill QEMU
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null || true

cat "$OUTFILE"
echo "---"

case "$RESULT" in
    pass)
        echo "Functional tests passed."
        exit 0
        ;;
    fail)
        echo "Functional tests FAILED."
        exit 1
        ;;
    *)
        echo "ERROR: No test result detected (timeout or crash)."
        exit 1
        ;;
esac
