#!/usr/bin/env bash
# dhcp_dynamics_tests.sh — driver for the DHCP-dynamics suite (TEST_PLAN §2).
#
# Each pass:
#   1. Restore the baseline dnsmasq config and restart the launcher.
#   2. Flash the Pi with hw_test/network-dhcp.conf and wait for the
#      Pi to acquire its baseline lease (10.0.0.109).
#   3. Run pytest -m dhcp_dynamics — the conftest fixture mutates
#      dnsmasq state per scenario; tests assert against lease file
#      and avahi-resolve.
#   4. Restore baseline dnsmasq + reflash to baseline kernel state.
#
# Usage:
#   bash scripts/dhcp_dynamics_tests.sh                 # one pass
#   bash scripts/dhcp_dynamics_tests.sh --repeat 4      # four passes
#   bash scripts/dhcp_dynamics_tests.sh --pytest-args="-k rebind"
#                                                       # subset
#
# Pre-reqs:
#   make rig-setup            (one-time setcap on /usr/sbin/dnsmasq)
#   scripts/dnsmasq-rig.sh start
#
# Total wall-clock per pass: ~10–15 min (3 tests × ~3–4 min each).
# Each scenario waits for real DHCP timers to fire on real hardware
# — there's no shortcut.
#
# Output:
#   /tmp/dhcp-dynamics-pass<N>.out   — per-pass pytest log
#   exit 0 if every pass green, non-zero otherwise.

set -uo pipefail   # NOT -e: per-pass exit captured independently

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

VENV="$PROJECT_DIR/.venv/bin/python"
if [ ! -x "$VENV" ]; then
    echo "ERROR: .venv not found — install Python venv per project setup" >&2
    exit 1
fi

REPEAT=1
EXTRA_PYTEST_ARGS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --repeat)
            REPEAT="$2"
            shift 2
            ;;
        --repeat=*)
            REPEAT="${1#*=}"
            shift
            ;;
        --pytest-args=*)
            EXTRA_PYTEST_ARGS="${1#*=}"
            shift
            ;;
        -h|--help)
            sed -n '2,28p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown arg '$1'" >&2
            exit 1
            ;;
    esac
done

if ! [[ "$REPEAT" =~ ^[0-9]+$ ]] || [ "$REPEAT" -lt 1 ]; then
    echo "ERROR: --repeat must be a positive integer" >&2
    exit 1
fi

echo "=== dhcp_dynamics_tests: $REPEAT pass(es) ==="

# Verify rig prereqs.
if ! bash "$SCRIPT_DIR/dnsmasq-rig.sh" status > /dev/null 2>&1; then
    echo "ERROR: dnsmasq-rig.sh status reports not running" >&2
    echo "  Run: make rig-setup && scripts/dnsmasq-rig.sh start" >&2
    exit 1
fi

if [ ! -r /tmp/dnsmasq-wspi5.leases ]; then
    echo "ERROR: /tmp/dnsmasq-wspi5.leases missing — dnsmasq is up" \
         "but no lease has been issued yet" >&2
    exit 1
fi

kill_stale() {
    "$VENV" -c "
import sys; sys.path.insert(0, 'scripts')
from hw_send import kill_stale_hw_send
kill_stale_hw_send()
" 2>/dev/null || true
}

DYNAMICS_BASE_CONF=/tmp/dnsmasq-wspi5-dynamics-base.conf

write_dynamics_base() {
    # Build a dynamics-suite base conf from the canonical baseline.
    # Two changes: 2 m lease (so T1 = 60 s and tests don't have to
    # wait six hours per renewal cycle), and a fresh
    # dhcp-leasefile path so dnsmasq doesn't carry an old 12 h
    # lease record forward across a config swap. dnsmasq persists
    # leases across restarts; if we kept the baseline lease file,
    # the Pi's 12 h record from a prior run would still be in
    # effect and the new short-lease range wouldn't apply to the
    # already-leased MAC until 6 h had passed. A clean lease path
    # forces dnsmasq to start fresh.
    sed \
        -e 's|^dhcp-range=\([^,]*\),\([^,]*\),\([^,]*\),.*$|dhcp-range=\1,\2,\3,2m|' \
        -e 's|^dhcp-leasefile=.*$|dhcp-leasefile=/tmp/dnsmasq-wspi5-dynamics.leases|' \
        "$SCRIPT_DIR/dnsmasq-wspi5.conf" > "$DYNAMICS_BASE_CONF"
    # Clear the dynamics lease file so dnsmasq starts from empty
    # (the kernel hands out fresh 2 m leases to the rig MAC).
    : > /tmp/dnsmasq-wspi5-dynamics.leases
    bash "$SCRIPT_DIR/dnsmasq-rig.sh" restart "$DYNAMICS_BASE_CONF" \
        > /dev/null 2>&1
}

flash_pi_dhcp() {
    # Build the kernel + push it with network-dhcp.conf via UART.
    # Boot polling: wait for "GENET Gigabit Ethernet" then for the
    # Pi to land in the dynamics lease file at .109. Returns 0 on
    # success.
    local logfile="$1"
    kill_stale
    make clean > /dev/null 2>&1
    make PLATFORM=pi4 CONTENT_MAX=65536 > /dev/null 2>&1
    "$VENV" scripts/hw_send.py \
        --network-conf "$PROJECT_DIR/hw_test/network-dhcp.conf" \
        kernel8.img > "$logfile" 2>&1 &
    local hw_pid=$!
    local i
    for i in $(seq 1 150); do
        if grep -q 'GENET Gigabit Ethernet' "$logfile" 2>/dev/null; then
            break
        fi
        sleep 1
    done
    if ! grep -q 'GENET Gigabit Ethernet' "$logfile"; then
        kill "$hw_pid" 2>/dev/null || true
        echo "  flash-fail: kernel didn't reach GENET init" >&2
        return 1
    fi
    # Wait for baseline lease in the dynamics lease file.
    for i in $(seq 1 60); do
        if grep -q ' 10\.0\.0\.109 ' \
               /tmp/dnsmasq-wspi5-dynamics.leases 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    kill "$hw_pid" 2>/dev/null || true
    echo "  flash-fail: Pi did not acquire baseline lease at 10.0.0.109" >&2
    return 1
}

restore_baseline_dnsmasq() {
    bash "$SCRIPT_DIR/dnsmasq-rig.sh" restart \
        "$SCRIPT_DIR/dnsmasq-wspi5.conf" > /dev/null 2>&1
}

ANY_FAIL=0
FAILED_PASSES=()

for n in $(seq 1 "$REPEAT"); do
    echo
    echo "##########################################################"
    echo "# Pass $n / $REPEAT"
    echo "##########################################################"
    out="/tmp/dhcp-dynamics-pass$n.out"

    echo "--- write dynamics-base dnsmasq conf (2 m lease, clean lease file) ---"
    write_dynamics_base

    echo "--- flash Pi with DHCP config ---"
    flash_log="/tmp/dhcp-dynamics-pass$n-flash.log"
    if ! flash_pi_dhcp "$flash_log"; then
        echo "Pass $n: FLASH FAILED — see $flash_log" >&2
        FAILED_PASSES+=("$n-flash")
        ANY_FAIL=1
        continue
    fi

    echo "--- pytest -m dhcp_dynamics ---"
    set +e
    HW_TEST=1 NETWORK_MODE=dhcp \
        WSPI5_DNSMASQ_DYNAMICS_BASE="$DYNAMICS_BASE_CONF" \
        WSPI5_DNSMASQ_LEASES=/tmp/dnsmasq-wspi5-dynamics.leases \
        "$VENV" -m pytest hw_test/test_dhcp_dynamics.py \
        -m dhcp_dynamics --tb=short -v $EXTRA_PYTEST_ARGS 2>&1 | tee "$out"
    rc=${PIPESTATUS[0]}
    set -e
    if [ "$rc" -ne 0 ]; then
        echo "Pass $n: pytest exit $rc — see $out" >&2
        FAILED_PASSES+=("$n-pytest")
        ANY_FAIL=1
    fi
done

# Final cleanup: restore baseline dnsmasq + reflash Pi to default
# static config so the rig is in a known state for the next run.
echo
echo "--- final cleanup ---"
restore_baseline_dnsmasq
kill_stale

echo
echo "##########################################################"
echo "# dhcp_dynamics_tests summary"
if [ "$ANY_FAIL" -eq 0 ]; then
    echo "#   all $REPEAT pass(es) green"
else
    echo "#   ${#FAILED_PASSES[@]} failure(s): ${FAILED_PASSES[*]}"
fi
echo "##########################################################"

exit "$ANY_FAIL"
