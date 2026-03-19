#!/usr/bin/env bash
# hw_test/run_tests.sh — automated hardware test runner (runs on Pi 4)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/config.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Configure usb0 (idempotent) ---

echo "Configuring $USB_IFACE ($PI4_USB_IP/$PI4_USB_PREFIX)..."
sudo ip addr add "$PI4_USB_IP/$PI4_USB_PREFIX" dev "$USB_IFACE" 2>/dev/null || true
sudo ip link set "$USB_IFACE" up

# --- Wait for Pi 3 boot ---

echo "Waiting for Pi 3 at $PI3_IP (timeout ${BOOT_TIMEOUT}s)..."
elapsed=0
while [ "$elapsed" -lt "$BOOT_TIMEOUT" ]; do
    if arping -c 1 -w 1 -I "$USB_IFACE" "$PI3_IP" >/dev/null 2>&1; then
        echo "Pi 3 responded after ${elapsed}s"
        break
    fi
    elapsed=$((elapsed + 1))
done

if [ "$elapsed" -ge "$BOOT_TIMEOUT" ]; then
    echo "TIMEOUT: Pi 3 did not respond within ${BOOT_TIMEOUT}s"
    exit 1
fi

# --- Test 1: ARP ---

echo ""
echo "--- Test: ARP ---"
if arping -c 3 -I "$USB_IFACE" "$PI3_IP"; then
    pass "ARP"
else
    fail "ARP"
fi

# --- Test 2: ICMP ---

echo ""
echo "--- Test: ICMP ---"
PING_OUT=$(ping -c 10 -W 2 "$PI3_IP" 2>&1) || true
echo "$PING_OUT"

if echo "$PING_OUT" | grep -q ' 0% packet loss'; then
    pass "ICMP"
else
    fail "ICMP"
fi

# --- Summary ---

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
