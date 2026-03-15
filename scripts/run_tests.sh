#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_KERNEL="$PROJECT_DIR/build/test_kernel8.img"
TIMEOUT=5

if [ ! -f "$TEST_KERNEL" ]; then
    echo "ERROR: Test kernel not found at $TEST_KERNEL"
    exit 1
fi

echo "Running tests on QEMU raspi3b..."

OUTPUT=$(timeout "$TIMEOUT" \
    qemu-system-aarch64 \
        -M raspi3b \
        -kernel "$TEST_KERNEL" \
        -nographic \
        -serial mon:stdio \
    2>/dev/null || true)

echo "$OUTPUT"
echo "---"

if echo "$OUTPUT" | grep -q "ALL TESTS PASSED"; then
    echo "Tests passed."
    exit 0
elif echo "$OUTPUT" | grep -q "TESTS FAILED"; then
    echo "Tests FAILED."
    exit 1
else
    echo "ERROR: No test result detected (timeout or crash)."
    exit 1
fi
