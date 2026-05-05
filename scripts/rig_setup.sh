#!/usr/bin/env bash
# rig_setup.sh — one-time hardware-rig setup for ws_pi5.
#
# Grants /usr/sbin/dnsmasq the capabilities it needs to bind UDP/67
# (cap_net_bind_service) and manage interface state (cap_net_admin)
# without running as root. After this, the rig's dnsmasq starts as
# the invoking user and the test fixture can kill/restart it freely
# without sudo prompts at test time.
#
# Idempotent: safe to re-run after a dnsmasq package upgrade
# reinstalls /usr/sbin/dnsmasq (which clears file caps).
#
# Run via:    make rig-setup
# Or direct:  bash scripts/rig_setup.sh
#
# Asks once for the sudo password; everything else runs as you.

set -euo pipefail

DNSMASQ=/usr/sbin/dnsmasq
# Three caps:
#   cap_net_bind_service — bind UDP/67 (privileged port).
#   cap_net_admin        — manage interface state.
#   cap_net_raw          — open AF_PACKET / SOCK_RAW for sending
#                          unicast DHCP frames before the client
#                          has an IP. Without it dnsmasq exits at
#                          startup with "process is missing
#                          required capability NET_RAW".
SETCAP_ARG='cap_net_bind_service,cap_net_admin,cap_net_raw+ep'

# getcap prints the cap set in its own canonical order (which differs
# between distros and libcap versions) using either `=ep` or `+ep`,
# so we can't string-compare the line. Check that all three required
# caps appear and the trailing flags include 'e' and 'p'.
caps_ok() {
    local raw
    raw="$(getcap "$DNSMASQ" 2>/dev/null)"
    [ -n "$raw" ] || return 1
    echo "$raw" | grep -q 'cap_net_bind_service' || return 1
    echo "$raw" | grep -q 'cap_net_admin'        || return 1
    echo "$raw" | grep -q 'cap_net_raw'          || return 1
    # Suffix shape: =ep / +ep / =eip / etc. — at least 'e' and 'p'.
    echo "$raw" | grep -qE '[=+][ip]*e[ip]*p[ip]*( |$)' || return 1
    return 0
}

if [ ! -x "$DNSMASQ" ]; then
    echo "rig_setup: $DNSMASQ not found — apt install dnsmasq?" >&2
    exit 1
fi

if caps_ok; then
    echo "rig_setup: $DNSMASQ already has the right caps — nothing to do."
    getcap "$DNSMASQ" | sed 's/^/  /'
    exit 0
fi

echo "rig_setup: applying caps to $DNSMASQ (one sudo prompt)..."
sudo setcap "$SETCAP_ARG" "$DNSMASQ"

if ! caps_ok; then
    echo "rig_setup: setcap reported success but cap check failed" >&2
    echo "  getcap: $(getcap "$DNSMASQ" 2>/dev/null || echo '(none)')" >&2
    exit 1
fi

echo "rig_setup: ok"
getcap "$DNSMASQ" | sed 's/^/  /'
echo
echo "Verify by running:"
echo "  scripts/dnsmasq-rig.sh start"
echo "  scripts/dnsmasq-rig.sh status"
echo "  scripts/dnsmasq-rig.sh stop"
