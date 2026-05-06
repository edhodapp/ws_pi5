#!/usr/bin/env bash
# wedge_recovery_test.sh — driver for the kernel-self-recovery test.
#
# Single-pass driver that flashes the Pi, runs ONE invocation of
# test_dhcp_wedge_recovery, captures /status samples for forensics,
# and reports the outcome.
#
# Three outcomes are meaningful:
#   PASS  — the test induced a wedge AND observed self-recovery
#           within the deadline. The kernel heals on its own.
#   FAIL  — the test induced a wedge and the Pi was still silent
#           after ~9 min. Empirical proof we need a watchdog.
#   SKIP  — the test could not induce a wedge in 6 rebind attempts.
#           The kernel is more robust on this iteration than during
#           take-1; rerun to retry. Skip is NOT a failure for the
#           binary "do we need a watchdog?" question — it just
#           means this iteration didn't reach the recovery probe.
#
# Wall-clock budget: induction up to ~6 min, recovery probe up to
# ~9 min. Worst case ~15 min per pass; passing iterations finish in
# ~6 min when no wedge is induced.
#
# Usage:
#   bash scripts/wedge_recovery_test.sh                # one shot
#   bash scripts/wedge_recovery_test.sh --repeat 5     # five shots
#
# Pre-reqs:
#   make rig-setup
#   scripts/dnsmasq-rig.sh start

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

VENV="$PROJECT_DIR/.venv/bin/python"
if [ ! -x "$VENV" ]; then
    echo "ERROR: .venv not found" >&2
    exit 1
fi

REPEAT=1
while [ $# -gt 0 ]; do
    case "$1" in
        --repeat) REPEAT="$2"; shift 2 ;;
        --repeat=*) REPEAT="${1#*=}"; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
    esac
done

if ! [[ "$REPEAT" =~ ^[0-9]+$ ]] || [ "$REPEAT" -lt 1 ]; then
    echo "ERROR: --repeat must be a positive integer" >&2
    exit 1
fi

echo "=== wedge_recovery_test: $REPEAT pass(es) ==="

if ! bash "$SCRIPT_DIR/dnsmasq-rig.sh" status > /dev/null 2>&1; then
    echo "ERROR: dnsmasq-rig.sh not running" >&2
    echo "  Run: make rig-setup && scripts/dnsmasq-rig.sh start" >&2
    exit 1
fi

DYNAMICS_BASE_CONF=/tmp/dnsmasq-wspi5-dynamics-base.conf

# Reuse helpers from the dynamics driver. Sourcing avoids drift —
# any change to the flash/conf logic stays in one place. The helper
# functions are named at the top of dhcp_dynamics_tests.sh; we only
# need write_dynamics_base, flash_pi_dhcp, kill_stale.
# shellcheck source=/dev/null
. <(sed -n '/^kill_stale()/,/^}$/p; /^write_dynamics_base()/,/^}$/p; /^flash_pi_dhcp()/,/^}$/p' \
        "$SCRIPT_DIR/dhcp_dynamics_tests.sh")

PASSES=()
FAILS=()
SKIPS=()

for n in $(seq 1 "$REPEAT"); do
    echo
    echo "##########################################################"
    echo "# Pass $n / $REPEAT"
    echo "##########################################################"

    echo "--- write dynamics-base dnsmasq conf ---"
    write_dynamics_base

    echo "--- flash Pi with DHCP config ---"
    flash_log=/tmp/wedge-recovery-pass$n-flash.log
    if ! flash_pi_dhcp "$flash_log"; then
        echo "Pass $n: flash failed — see $flash_log" >&2
        FAILS+=("$n-flash")
        continue
    fi

    sampler_log="/tmp/wedge-recovery-pass$n-status-samples.log"
    pi_ip=$(awk '$3 ~ /^10\.0\.0\.10[0-9]$/ {print $1, $3}' \
                /tmp/dnsmasq-wspi5-dynamics.leases \
              | sort -k1 -n | tail -1 | awk '{print $2}')
    [ -z "$pi_ip" ] && pi_ip=10.0.0.109
    echo "--- start /status sampler against ${pi_ip} → ${sampler_log} ---"
    bash "$SCRIPT_DIR/status_sampler.sh" "$pi_ip" "$sampler_log" &
    sampler_pid=$!
    trap "kill $sampler_pid 2>/dev/null || true" EXIT

    out=/tmp/wedge-recovery-pass$n.out
    echo "--- pytest -m wedge_recovery ---"
    set +e
    HW_TEST=1 NETWORK_MODE=dhcp \
        WSPI5_DNSMASQ_DYNAMICS_BASE="$DYNAMICS_BASE_CONF" \
        WSPI5_DNSMASQ_LEASES=/tmp/dnsmasq-wspi5-dynamics.leases \
        "$VENV" -m pytest hw_test/test_dhcp_wedge_recovery.py \
        -m wedge_recovery --tb=short -v -s 2>&1 | tee "$out"
    rc=${PIPESTATUS[0]}
    set -e

    kill "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
    trap - EXIT
    samples=$(grep -c '^=== ' "$sampler_log" 2>/dev/null || echo 0)
    echo "--- sampler captured $samples samples ---"

    # Distinguish skip vs pass vs fail from pytest's own summary.
    # Skip looks like " 1 skipped"; pass like " 1 passed"; fail like
    # " 1 failed". Mutually exclusive when running a single test.
    if grep -qE '^=+ 1 skipped' "$out"; then
        echo "Pass $n: SKIP (no wedge induced)"
        SKIPS+=("$n")
    elif grep -qE '^=+ 1 passed' "$out"; then
        echo "Pass $n: PASS (kernel self-recovered)"
        PASSES+=("$n")
    else
        echo "Pass $n: FAIL — kernel did not self-recover (or pytest error)"
        FAILS+=("$n")
    fi
done

echo
echo "##########################################################"
echo "# wedge_recovery_test summary"
echo "#   passes : ${#PASSES[@]} (${PASSES[*]:-none})"
echo "#   fails  : ${#FAILS[@]}  (${FAILS[*]:-none})"
echo "#   skips  : ${#SKIPS[@]}  (${SKIPS[*]:-none})"
echo "##########################################################"

# Exit non-zero if any pass actually failed (skip + pass are both
# acceptable outcomes; a fail is the empirical signal we need to
# report).
[ ${#FAILS[@]} -eq 0 ]
