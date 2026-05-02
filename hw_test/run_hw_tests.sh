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
#   PI4_IP=10.0.0.2         Pi 4 IP address (auto-resolved from mDNS if unset;
#                           falls back to 10.0.0.2 for static / chainloader boots)
#   PI4_HOSTNAME=wspi5      Hostname used for mDNS auto-resolve
#   PI4_HTTP_PORT=80        HTTP port
#   PI4_SERIAL=/dev/ttyUSB0 Serial adapter device
#   HW_TEST=1               Required to enable hardware tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export HW_TEST="${HW_TEST:-1}"

# Resolve PI4_IP. Precedence:
#   1. Explicit PI4_IP env var (caller knows the address — honor it)
#   2. mDNS resolve of ${PI4_HOSTNAME:-wspi5}.local (real-SD/DHCP boot)
#   3. Static fallback 10.0.0.2 (chainloader / static-config boot)
#
# We log which path was taken so a run against the wrong IP is obvious
# in the output instead of silently defaulting.
PI4_HOSTNAME="${PI4_HOSTNAME:-wspi5}"
PI4_FQDN="${PI4_HOSTNAME}.local"

if [ -n "${PI4_IP:-}" ]; then
    echo "PI4_IP source: explicit env (${PI4_IP})"
elif command -v avahi-resolve >/dev/null 2>&1 \
        && resolved=$(avahi-resolve -4 -n "$PI4_FQDN" 2>/dev/null) \
        && [ -n "$resolved" ]; then
    PI4_IP="$(echo "$resolved" | awk '{print $2}')"
    export PI4_IP
    echo "PI4_IP source: mDNS resolve of ${PI4_FQDN} -> ${PI4_IP}"
else
    export PI4_IP="10.0.0.2"
    echo "PI4_IP source: static fallback (mDNS resolve failed) -> ${PI4_IP}"
fi

echo "=== Pi 4 Hardware Integration Tests ==="
echo "Target: ${PI4_IP}:${PI4_HTTP_PORT:-80}"
echo ""

cd "$SCRIPT_DIR"

if [ $# -gt 0 ]; then
    python3 -m pytest "$@"
else
    python3 -m pytest
fi
