#!/bin/bash
# Idempotent: re-run any time after a package upgrade, venv rebuild, or
# unexplained "Operation not permitted" from tcpdump/tshark/ethtool/arping/scapy.
# See hw_test/TOOLS_SETUP.md for the full explanation.

set -eu

sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/tcpdump
sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/dumpcap
sudo setcap cap_net_admin=eip             /usr/sbin/ethtool
sudo setcap cap_net_raw=eip               /usr/sbin/arping
# tcpreplay sends raw frames via PACKET_MMAP — needs cap_net_raw.
# Used by hw_test for deterministic-rate L2 burst tests (see
# hw_test/test_l2_ring.py, hw_test/bin/arp_burst_send.py).
sudo setcap cap_net_raw=eip               /usr/bin/tcpreplay
# NOTE: we deliberately do NOT setcap /usr/bin/ip here. On at least one
# Ubuntu 24.04 / kernel 6.17 system, file caps applied to /usr/bin/ip
# are recorded by setcap but not honoured by the kernel at exec time
# (the running process gets CapPrm=0), even though the same caps work
# fine on tcpdump, ethtool, dumpcap, and arping. Rather than spelunk
# into that, hw_test/link.py uses raw AF_NETLINK from the venv python
# for link up/down — which only requires cap_net_admin on the venv
# python interpreter (added below).

# setcap cannot operate on symlinks, and venvs symlink python3 by default.
# Replace the symlink with a real copy of the interpreter so caps attach
# only to the venv python (not system-wide via /usr/bin/python3.12).
VENV_PY=/home/ed/ws_pi5/.venv/bin/python3
if [ -L "$VENV_PY" ]; then
    REAL_PY=$(readlink -f "$VENV_PY")
    rm "$VENV_PY"
    cp "$REAL_PY" "$VENV_PY"
fi
# Venv python needs cap_net_raw for AF_PACKET sends (wire.send_frame)
# AND cap_net_admin for AF_NETLINK link up/down (link.link_up/down).
sudo setcap cap_net_admin,cap_net_raw=eip "$VENV_PY"

echo
echo "Current caps:"
getcap /usr/bin/tcpdump /usr/bin/dumpcap /usr/sbin/ethtool \
       /usr/sbin/arping /home/ed/ws_pi5/.venv/bin/python3
