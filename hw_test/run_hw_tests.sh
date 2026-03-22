#!/usr/bin/env bash
#
# run_hw_tests.sh — Run hardware integration tests against the Pi 4
#
# Prerequisites:
#   - Pi 4 booted with bare-metal kernel, Ethernet connected
#   - pip install pytest pyserial (if using serial tests)
#
# Usage:
#   HW_TEST=1 bash hw_test/run_hw_tests.sh              # all tests
#   HW_TEST=1 bash hw_test/run_hw_tests.sh test_ping.py  # just ping
#
# Environment:
#   PI4_IP=10.0.2.15       Pi 4 IP address
#   PI4_HTTP_PORT=80        HTTP port
#   PI4_SERIAL=/dev/ttyUSB0 Serial adapter device
#   HW_TEST=1               Required to enable hardware tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export HW_TEST="${HW_TEST:-1}"
export PI4_IP="${PI4_IP:-10.0.2.15}"

echo "=== Pi 4 Hardware Integration Tests ==="
echo "Target: ${PI4_IP}:${PI4_HTTP_PORT:-80}"
echo ""

cd "$SCRIPT_DIR"

if [ $# -gt 0 ]; then
    python3 -m pytest "$@"
else
    python3 -m pytest
fi
