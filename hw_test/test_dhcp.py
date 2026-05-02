"""
test_dhcp.py — DHCP client integration test (D017)

Verifies the Pi 4 acquires an IP via DHCP from a dnsmasq running on
the laptop's Pi-facing interface. Assumes:
  - SD has been flashed with a kernel built from `make pi4-test`
    using a network.conf that contains `dhcp=yes` and the desired
    `hostname=`.
  - dnsmasq is running on the laptop bound to the Pi-facing iface,
    handing out leases from 10.0.0.100-10.0.0.110 (see
    /tmp/dnsmasq-wspi5.conf).
  - avahi-daemon is running on the laptop so the Pi's mDNS
    advertisement can be resolved post-DHCP.

Run with:
    HW_TEST=1 PI4_HOSTNAME=wspi5 pytest hw_test/test_dhcp.py -v
"""

# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=unused-import,inconsistent-quotes,line-too-long
# mypy: ignore-errors

import os
import re
import shutil
import subprocess
import time

import pytest

from conftest import (  # noqa: F401
    requires_hardware, TEST_TIMEOUT,
)

PI4_HOSTNAME = os.environ.get("PI4_HOSTNAME", "wspi5")
PI4_FQDN = f"{PI4_HOSTNAME}.local"

# DHCP pool boundaries (must match /tmp/dnsmasq-wspi5.conf).
DHCP_POOL_START = 100
DHCP_POOL_END = 110

pytestmark = pytest.mark.l5


def _avahi_available() -> bool:
    return shutil.which("avahi-resolve") is not None


def _resolve_pi() -> str | None:
    """Resolve PI4_FQDN via avahi-resolve. Returns IP string or None."""
    if not _avahi_available():
        return None
    proc = subprocess.run(
        ["avahi-resolve", "-4", "-n", PI4_FQDN],
        capture_output=True, text=True, timeout=TEST_TIMEOUT + 2,
        check=False,
    )
    if proc.returncode != 0:
        return None
    parts = proc.stdout.strip().split()
    if len(parts) != 2:
        return None
    return parts[1]


@requires_hardware
@pytest.mark.skipif(not _avahi_available(), reason="avahi-resolve not installed")
class TestDHCP:

    def test_pi_gets_ip_in_pool(self):
        """The Pi resolves to an IP inside the DHCP pool range.

        The Pi's mDNS announcement requires it to know its own IP,
        so a successful resolve to 10.0.0.[100..110] proves the
        full path: DHCP DISCOVER → OFFER → REQUEST → ACK →
        h_commit_lease_arm_timers → mDNS answers with the new IP.
        """
        # Give the Pi up to 30 s to (a) DHCP-acquire and (b) announce
        # via mDNS. dnsmasq usually responds in < 1 s, mDNS announce
        # is ~750 ms after BOUND.
        deadline = time.time() + 30
        ip = None
        while time.time() < deadline:
            ip = _resolve_pi()
            if ip is not None:
                break
            time.sleep(1)

        assert ip is not None, (
            f"timed out waiting for {PI4_FQDN} to resolve via mDNS — "
            "DHCP probably didn't succeed; check dnsmasq leases"
        )

        m = re.match(r"10\.0\.0\.(\d+)$", ip)
        assert m, f"unexpected IP format: {ip!r}"
        octet = int(m.group(1))
        assert DHCP_POOL_START <= octet <= DHCP_POOL_END, (
            f"Pi got {ip}, outside the DHCP pool "
            f"10.0.0.{DHCP_POOL_START}-{DHCP_POOL_END}; either dnsmasq "
            "isn't the lease source or the static fallback was used "
            "(which D017 explicitly forbids when dhcp=yes)"
        )

    def test_http_via_dhcp_assigned_ip(self):
        """curl http://<assigned>/ returns the appliance's HTML.

        Re-uses _resolve_pi to discover the IP, then opens a TCP
        connection. Locks in the post-commit_lease state: net_our_ip
        was correctly stamped from yiaddr, and the HTTP server is
        listening on it.
        """
        ip = _resolve_pi()
        assert ip is not None, "Pi not resolvable — run test_pi_gets_ip_in_pool first"

        proc = subprocess.run(
            ["curl", "-sS", "--max-time", str(TEST_TIMEOUT), f"http://{ip}/"],
            capture_output=True, text=True, check=False,
        )
        assert proc.returncode == 0, (
            f"curl failed: rc={proc.returncode} stderr={proc.stderr!r}"
        )
        assert "Hello from bare-metal Pi 4" in proc.stdout, (
            f"unexpected HTTP body: {proc.stdout!r}"
        )
