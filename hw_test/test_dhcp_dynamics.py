"""
test_dhcp_dynamics.py — DHCP-dynamics integration suite (TEST_PLAN §2).

Exercises kernel DHCP / mDNS code paths that don't fire in a
single-flash run. Each test mutates dnsmasq state mid-flight and
waits for the Pi to react. Slow (multi-minute per test) and stateful
(dnsmasq config gets rewritten between tests via the
`dnsmasq_apply_conf` fixture in conftest.py); excluded from the
default L5 sweep by the `dhcp_dynamics` marker.

Prerequisites — see hw_test/TOOLS_SETUP.md §6b for the one-time
`make rig-setup` step that grants `/usr/sbin/dnsmasq` the caps it
needs to run as the operator. The fixture in conftest.py will skip
the suite with a clear reason if the launcher isn't reporting a
healthy dnsmasq.

Each test starts from a baseline state where the Pi has been
flashed with `hw_test/network-dhcp.conf` and acquired a lease at
10.0.0.109. The driver `scripts/dhcp_dynamics_tests.sh` does that
flash before invoking pytest.
"""

# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=line-too-long
# mypy: ignore-errors

import time

import pytest

from conftest import requires_hardware


# Pool boundaries — match scripts/dnsmasq-wspi5.conf.
DHCP_POOL_START = 100
DHCP_POOL_END = 110

# Baseline lease for the rig Pi (sticky on dnsmasq's default
# allocation since this MAC is the only client). Tests assert
# initial state against this so a missing pre-flash is a loud
# skip rather than a confusing miscompare.
RIG_PI_MAC = "de:ad:be:ef:ca:fe"
RIG_PI_BASELINE_IP = "10.0.0.109"

# Module-level marker — applies to every test in the file. The
# dhcp_only marker pairs with the conftest collection hook so the
# suite skips cleanly if the rig is in static mode. dhcp_dynamics
# excludes from default `pytest -m l5` runs.
pytestmark = [
    pytest.mark.l5,
    pytest.mark.dhcp_only,
    pytest.mark.dhcp_dynamics,
    pytest.mark.slow,
]


def _wait_for_lease(
    lease_reader, predicate, deadline_s: float, poll_s: float = 1.0
):
    """Poll the lease file until predicate(lease) returns truthy.
    Returns the matching lease dict or None on timeout."""
    deadline = time.monotonic() + deadline_s
    while time.monotonic() < deadline:
        for lease in lease_reader():
            if predicate(lease):
                return lease
        time.sleep(poll_s)
    return None


def _wait_for_avahi(avahi_resolve, expected_ip: str, deadline_s: float):
    """Poll avahi-resolve until it returns expected_ip. Returns True
    on match, False on timeout. avahi has a cache TTL so this can
    take a few seconds even after the Pi announces."""
    deadline = time.monotonic() + deadline_s
    while time.monotonic() < deadline:
        got = avahi_resolve()
        if got == expected_ip:
            return True
        time.sleep(1.0)
    return False


@requires_hardware
class TestDHCPDynamics:

    def test_short_lease_renewal_stays_at_same_ip(
        self, dnsmasq_apply_conf, lease_reader,
    ):
        """A 2-minute lease renews at T1 (60 s) and T2 (105 s).
        Across two complete renewal cycles the Pi must keep the
        same IP — DHCP RENEWING/REBINDING with the same server
        should never produce a different yiaddr.

        Pin: the lease file's expire epoch advances at least twice
        from the baseline observation; the IP stays at .109; no
        gap longer than ~70 s appears in lease updates (proxy for
        "Pi never went into INIT").
        """
        dnsmasq_apply_conf([
            "dhcp-range=10.0.0.100,10.0.0.110,255.255.255.0,2m",
        ])
        # The dnsmasq restart cancelled the Pi's prior lease record
        # but the Pi still believes it has the lease until T1 fires.
        # Wait for the first renewal to land — that proves the Pi
        # noticed the new (short-lease) reality.
        first = _wait_for_lease(
            lease_reader,
            lambda l: l["mac"] == RIG_PI_MAC
                      and l["ip"] == RIG_PI_BASELINE_IP,
            deadline_s=180.0,
        )
        assert first is not None, (
            "no lease for the rig Pi within 180 s of applying the "
            "short-lease config — Pi may not be running DHCP-mode "
            "kernel, or dnsmasq isn't seeing renewal traffic"
        )

        # Wait for the next renewal — expire epoch should advance.
        second = _wait_for_lease(
            lease_reader,
            lambda l: l["mac"] == RIG_PI_MAC
                      and l["expire"] > first["expire"],
            deadline_s=120.0,
        )
        assert second is not None, (
            f"lease did not renew within 120 s of first observation "
            f"(first expire={first['expire']}); Pi's T1 may not be "
            f"firing"
        )

        # IP must not have changed across renewals.
        assert second["ip"] == first["ip"], (
            f"IP changed across same-server renewal: "
            f"first={first['ip']} second={second['ip']}"
        )

        # And one more, to prove it's not just a one-off.
        third = _wait_for_lease(
            lease_reader,
            lambda l: l["mac"] == RIG_PI_MAC
                      and l["expire"] > second["expire"],
            deadline_s=120.0,
        )
        assert third is not None, "second renewal cycle didn't fire"
        assert third["ip"] == first["ip"]

    def test_dhcpnak_rebind_updates_mdns(
        self, dnsmasq_apply_conf, lease_reader, avahi_resolve,
    ):
        """Force dnsmasq to reassign this MAC to a different IP via
        dhcp-host. On the next REQUEST, dnsmasq sends DHCPNAK; the
        Pi enters INIT, DISCOVERs, gets ACK at the new IP. The
        kernel's h_commit_lease_arm_timers fires mdns_kick, which
        sees ANNOUNCED_IP != net_our_ip and restarts the probe
        cycle on the new IP. avahi-resolve eventually returns the
        new IP (cache-flush bit on the new announce per RFC 6762
        §10.2 makes peers replace the stale A record).

        This is the core test for commit 0862993 — the kernel
        defect that caused wspi5.local to resolve to a stale IP
        forever after a router-induced rebind.
        """
        new_ip = "10.0.0.105"
        # 2-minute lease so T1 fires at ~60 s, well within budget.
        # dhcp-host pins this MAC to the new IP, forcing a NAK on
        # the next REQUEST for the old one.
        dnsmasq_apply_conf([
            "dhcp-range=10.0.0.100,10.0.0.110,255.255.255.0,2m",
            f"dhcp-host={RIG_PI_MAC},{new_ip}",
        ])

        # Wait for the rebind: Pi ends up at new_ip in the lease file.
        rebind = _wait_for_lease(
            lease_reader,
            lambda l: l["mac"] == RIG_PI_MAC and l["ip"] == new_ip,
            deadline_s=180.0,
        )
        assert rebind is not None, (
            f"Pi did not rebind to {new_ip} within 180 s of the "
            f"dhcp-host override; check tcpdump for NAK delivery"
        )

        # avahi-resolve must eventually return the new IP. mDNS TTL
        # is conservative (we use 120 s) but cache-flush replaces
        # the stale record on receipt — give it 30 s.
        assert _wait_for_avahi(avahi_resolve, new_ip, deadline_s=30.0), (
            f"avahi-resolve still returns the old IP 30 s after rebind. "
            f"Either the Pi's mdns_kick didn't re-announce, or peers "
            f"aren't honouring cache-flush. Last avahi-resolve: "
            f"{avahi_resolve()!r}"
        )

    def test_scope_change_assigns_from_new_range(
        self, dnsmasq_apply_conf, lease_reader,
    ):
        """Replace the entire DHCP scope (e.g. router rebooted with
        a different subnet). dnsmasq has no record of the Pi's old
        IP being in the new pool; it NAKs and offers something in
        the new range.

        This is the "router scope change" failure mode — common
        when a user reboots a router that had a custom range, or
        moves the Pi between networks. The kernel must follow.
        """
        new_pool_start = "10.0.0.50"
        new_pool_end = "10.0.0.60"
        dnsmasq_apply_conf([
            f"dhcp-range={new_pool_start},{new_pool_end},255.255.255.0,2m",
        ])

        # Pi T1 fires within ~60 s, REQUESTs old IP, gets NAK
        # (pool no longer contains 10.0.0.109), DISCOVERs, gets
        # something in 50-60.
        rebind = _wait_for_lease(
            lease_reader,
            lambda l: (
                l["mac"] == RIG_PI_MAC
                and l["ip"].startswith("10.0.0.")
                and 50 <= int(l["ip"].split(".")[3]) <= 60
            ),
            deadline_s=180.0,
        )
        assert rebind is not None, (
            f"Pi did not acquire a lease in the new pool "
            f"({new_pool_start}-{new_pool_end}) within 180 s"
        )
        assert rebind["ip"] != RIG_PI_BASELINE_IP, (
            f"Pi somehow kept the old IP {RIG_PI_BASELINE_IP} after "
            f"a scope change — dnsmasq's dhcp-authoritative isn't "
            f"taking, or the Pi's renewal isn't being NAKed"
        )
