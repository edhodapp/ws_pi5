"""
test_l2_linkflap.py — link down/up recovery on the laptop side.

Brings the laptop's Pi-facing NIC down and back up via link.py's
netlink helper, then verifies the Pi remains ARP-reachable. The Pi
sees the carrier go away and come back; this catches GENET driver
bugs around link-state changes (e.g. RX/TX descriptor pointers not
re-initialized after a carrier flap, MAC filter stale, MIB counters
unfrozen incorrectly).

Two test methods:

* test_link_down_up_recovers — single down/up cycle.
* test_link_down_up_repeated  — five cycles, asserting reachability
  after each. Catches "works once after recovery, breaks the second
  time" bugs.

Run:
    HW_TEST=1 .venv/bin/pytest hw_test/test_l2_linkflap.py -v
"""

import time

import pytest

import eth_frames
import link
import wire
from conftest import requires_hardware, PI4_IP


@requires_hardware
@pytest.mark.l2
class TestLinkFlap:

    def test_link_down_up_recovers(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """One down/up cycle: Pi must answer ARP afterwards."""
        # Sanity: link starts up
        before = link.link_state(eth_iface)
        assert before["admin_up"], "link not up at test start"
        assert before["carrier"], "no carrier at test start"

        with link.temporary_link_down(eth_iface, down_ms=500, recover_ms=8000):
            # Inside the with-block the link is admin-down. Verify.
            inside = link.link_state(eth_iface)
            assert not inside["admin_up"], (
                "expected link admin-down inside with-block"
            )

        # After exit: link is up, carrier is back
        after = link.link_state(eth_iface)
        assert after["admin_up"], "link did not come admin-up after flap"
        assert after["carrier"], "no carrier after link flap recovery"

        # Pi must respond to ARP
        reply = _arp_probe(eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms)
        assert reply is not None, (
            f"Pi at {PI4_IP} did not respond to ARP after link flap"
        )
        arp = eth_frames.parse_arp(reply)
        assert arp["sha"] == pi_mac
        assert arp["spa"] == PI4_IP

    def test_link_down_up_repeated(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """Five down/up cycles, ARP-reachable after each.

        Catches the classic "first recovery works, subsequent ones
        leave a stale state somewhere" bug. Each iteration is fully
        independent — we re-probe through wire capture, no caching.
        """
        for cycle in range(5):
            with link.temporary_link_down(eth_iface, down_ms=300, recover_ms=8000):
                pass

            after = link.link_state(eth_iface)
            assert after["admin_up"], (
                f"cycle {cycle}: link did not come admin-up"
            )
            assert after["carrier"], (
                f"cycle {cycle}: no carrier after recovery"
            )

            reply = _arp_probe(
                eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
            )
            assert reply is not None, (
                f"cycle {cycle}: Pi did not answer ARP after flap"
            )
            arp = eth_frames.parse_arp(reply)
            assert arp["sha"] == pi_mac, (
                f"cycle {cycle}: Pi MAC drifted "
                f"({arp['sha'].hex()} vs expected {pi_mac.hex()})"
            )

    def test_link_state_restored_after_test(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """Sanity guard: confirm temporary_link_down doesn't leave the
        link in a wrong autoneg/speed state.

        We're not flapping a forced-speed link here, but the test
        exists to catch a regression where temporary_link_down might
        accidentally start touching ethtool settings in the future.
        """
        before = link.link_state(eth_iface)
        with link.temporary_link_down(eth_iface, down_ms=200, recover_ms=8000):
            pass
        after = link.link_state(eth_iface)
        assert after["autoneg"] == before["autoneg"], (
            f"autoneg changed: before={before['autoneg']} after={after['autoneg']}"
        )
        # Speed must be the same after recovery (auto-renegotiated)
        link.wait_for_speed(eth_iface, before["speed_mbps"], deadline_ms=8000)


# --- Helper ---

def _arp_probe(iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms):
    """Single ARP probe with the standard tight BPF + deadline."""
    request = eth_frames.build_arp_request(laptop_mac, laptop_ip, PI4_IP)
    bpf = (
        f"arp and ether src {eth_frames.mac_bytes_to_str(pi_mac)} "
        f"and ether dst {eth_frames.mac_bytes_to_str(laptop_mac)}"
    )
    deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
    with wire.WireCapture(iface, bpf=bpf) as cap:
        wire.send_frame(iface, request)
        return wire.wait_for_frame(
            cap,
            lambda d: _is_arp_reply_from(d, pi_mac, PI4_IP),
            deadline_ms=deadline_ms,
        )


def _is_arp_reply_from(frame: bytes, expected_mac: bytes, expected_ip: str) -> bool:
    try:
        arp = eth_frames.parse_arp(frame)
    except (ValueError, OSError):
        return False
    return (
        arp["opcode"] == eth_frames.ARP_OP_REPLY
        and arp["sha"] == expected_mac
        and arp["spa"] == expected_ip
    )
