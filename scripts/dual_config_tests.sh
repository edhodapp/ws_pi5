#!/usr/bin/env bash
# dual_config_tests.sh — run the full pre-push test pass twice, once
# per network.conf config (static-IP and DHCP). Same chainloader SD
# stays in the Pi the whole time; the difference between the two
# passes is just the network.conf bytes that hw_send.py prepends to
# the kernel HEX records.
#
# Critically: pass 2 ALWAYS runs, even if pass 1 fails. We want
# independent diagnostics for both configs from one invocation.
# A previous version chained `set -e` across both, which silently
# skipped pass 2 the moment pass 1 hit a flake — exactly the
# opposite of what the script is supposed to deliver.
#
# Prereq for the DHCP pass: a dnsmasq instance bound to the Pi-facing
# interface on the laptop. See /tmp/dnsmasq-wspi5.conf for the rig
# config (10.0.0.100-110 lease pool); the DHCP pass will fail in
# unhelpful ways if dnsmasq isn't running.
#
# Usage:
#   bash scripts/dual_config_tests.sh
#
# Each pass is full A+B+C+perf via pre_push_tests.sh. Total wall-clock
# is ~50-60 minutes (single pass is ~25-30 min, two of them serial).
#
# Exit code: 0 if both passes pass, otherwise non-zero. The script
# never exits early — both passes run regardless of intermediate
# results, and the final summary tells you which (if any) failed.

set -uo pipefail   # NOT -e: per-pass control over exit, see above

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

run_pass() {
    # run_pass <name> <network.conf path>
    # Always returns 0 to the caller; the actual exit code is captured
    # in the global RC_<name> variable so the final summary can read it.
    local name="$1"
    local conf="$2"
    local rc
    echo
    echo "##########################################################"
    echo "# Pass: $name"
    echo "# NETWORK_CONF: $conf"
    echo "##########################################################"
    NETWORK_MODE="$name" NETWORK_CONF="$conf" \
        PATH="$PROJECT_DIR/.venv/bin:$PATH" \
        bash "$SCRIPT_DIR/pre_push_tests.sh"
    rc=$?
    eval "RC_${name}=${rc}"
    echo "# Pass $name finished with exit ${rc}"
    return 0
}

run_pass "static" "$PROJECT_DIR/hw_test/network-static.conf"
run_pass "dhcp"   "$PROJECT_DIR/hw_test/network-dhcp.conf"
# The two pass names ("static"/"dhcp") double as NETWORK_MODE values
# the pytest hook in hw_test/conftest.py reads to skip @dhcp_only /
# @static_only marked tests during the mismatched pass.

echo
echo "##########################################################"
echo "# dual_config_tests summary"
echo "#   static : exit ${RC_static}"
echo "#   dhcp   : exit ${RC_dhcp}"
echo "##########################################################"

if [[ "${RC_static}" -eq 0 && "${RC_dhcp}" -eq 0 ]]; then
    echo "=== dual_config_tests: BOTH passes green ==="
    exit 0
fi
echo "=== dual_config_tests: at least one pass failed ===" >&2
exit 1
