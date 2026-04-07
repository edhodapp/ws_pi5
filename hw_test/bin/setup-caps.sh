#!/bin/bash
# Idempotent: re-run any time after a package upgrade, venv rebuild, or
# unexplained "Operation not permitted" from tcpdump/tshark/ethtool/arping/scapy.
# See hw_test/TOOLS_SETUP.md for the full explanation.

set -eu

sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/tcpdump
sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/dumpcap
sudo setcap cap_net_admin=eip             /usr/sbin/ethtool
sudo setcap cap_net_raw=eip               /usr/bin/arping
sudo setcap cap_net_raw=eip               /home/ed/ws_pi5/.venv/bin/python3

echo
echo "Current caps:"
getcap /usr/bin/tcpdump /usr/bin/dumpcap /usr/sbin/ethtool \
       /usr/bin/arping /home/ed/ws_pi5/.venv/bin/python3
