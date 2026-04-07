#!/bin/bash
# Idempotent: re-run any time after a package upgrade, venv rebuild, or
# unexplained "Operation not permitted" from tcpdump/tshark/ethtool/arping/scapy.
# See hw_test/TOOLS_SETUP.md for the full explanation.

set -eu

sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/tcpdump
sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/dumpcap
sudo setcap cap_net_admin=eip             /usr/sbin/ethtool
sudo setcap cap_net_raw=eip               /usr/sbin/arping
# /bin/ip is multi-purpose; cap_net_admin is needed for `ip link set
# <iface> down/up`, used by hw_test/link.py for the L2 link-flap tests.
# Resolve the symlink (/usr/sbin/ip -> /bin/ip on Ubuntu) so caps land
# on the real inode.
IP_BIN=$(readlink -f "$(command -v ip)")
sudo setcap cap_net_admin=eip             "$IP_BIN"

# setcap cannot operate on symlinks, and venvs symlink python3 by default.
# Replace the symlink with a real copy of the interpreter so caps attach
# only to the venv python (not system-wide via /usr/bin/python3.12).
VENV_PY=/home/ed/ws_pi5/.venv/bin/python3
if [ -L "$VENV_PY" ]; then
    REAL_PY=$(readlink -f "$VENV_PY")
    rm "$VENV_PY"
    cp "$REAL_PY" "$VENV_PY"
fi
sudo setcap cap_net_raw=eip               "$VENV_PY"

echo
echo "Current caps:"
getcap /usr/bin/tcpdump /usr/bin/dumpcap /usr/sbin/ethtool \
       /usr/sbin/arping "$IP_BIN" /home/ed/ws_pi5/.venv/bin/python3
