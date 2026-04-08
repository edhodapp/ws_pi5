"""
test_l2_speed.py — speed renegotiation recovery on the laptop side.

Forces the laptop NIC to a non-default speed (100M), waits for
carrier to re-establish, asserts the Pi is still ARP-reachable, then
restores the original speed and verifies again. This catches GENET
driver bugs around link-speed transitions: PHY register state stale,
RGMII delay reconfiguration, MIB counter freeze logic broken on
speed change.

Uses link.temporary_link_speed which always restores even on test
body raise — the link can never be left at a wrong speed by a failed
test. The session-scope finalizer in conftest.py is the second safety
net.

Run:
    HW_TEST=1 .venv/bin/pytest hw_test/test_l2_speed.py -v
"""

import pytest

import eth_frames
import link
import wire
from conftest import requires_hardware, PI4_IP, RTT_BASELINE_CEILING_MS


@requires_hardware
@pytest.mark.l2
class TestSpeedRenegotiation:

    def test_force_100m_then_arp(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """Force the laptop NIC to 100M; verify Pi follows and ARP works."""
        before = link.link_state(eth_iface)
        assert before["speed_mbps"] == 1000, (
            f"baseline speed not 1G: got {before['speed_mbps']}"
        )

        with link.temporary_link_speed(eth_iface, 100, settle_ms=10000):
            inside = link.link_state(eth_iface)
            assert inside["speed_mbps"] == 100, (
                f"forced speed didn't take: got {inside['speed_mbps']}"
            )
            assert inside["autoneg"] is False, (
                "autoneg should be off when forcing speed"
            )
            assert inside["carrier"], "no carrier at 100M"

            # Pi must answer ARP at 100M. RTT will be higher than the
            # 1G baseline, so widen the deadline accordingly.
            reply = _arp_probe(
                eth_iface, laptop_mac, laptop_ip, pi_mac,
                deadline_ms=2000,
            )
            assert reply is not None, (
                "Pi did not answer ARP after speed forced to 100M"
            )
            arp = eth_frames.parse_arp(reply)
            assert arp["sha"] == pi_mac
            assert arp["spa"] == PI4_IP

        # After exit: link is back to original speed
        link.wait_for_speed(eth_iface, before["speed_mbps"], deadline_ms=10000)
        after = link.link_state(eth_iface)
        assert after["speed_mbps"] == before["speed_mbps"]
        assert after["autoneg"] == before["autoneg"]

        # And Pi is reachable again at the restored speed
        reply = _arp_probe(
            eth_iface, laptop_mac, laptop_ip, pi_mac,
            deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
        )
        assert reply is not None, (
            "Pi did not answer ARP after speed restored to "
            f"{before['speed_mbps']} M"
        )

    def test_force_1000m_explicitly_then_arp(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """Force the laptop NIC to 1000M (explicit, autoneg off);
        verify Pi follows and ARP works at the forced speed.

        Different code path from autoneg-1G: forces the speed even if
        autoneg would have negotiated 1G, so any GENET bug that only
        triggers on autoneg-vs-forced is exercised.
        """
        with link.temporary_link_speed(eth_iface, 1000, settle_ms=10000):
            inside = link.link_state(eth_iface)
            assert inside["speed_mbps"] == 1000
            assert inside["autoneg"] is False
            assert inside["carrier"]

            reply = _arp_probe(
                eth_iface, laptop_mac, laptop_ip, pi_mac,
                deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
            )
            assert reply is not None, (
                "Pi did not answer ARP at forced 1000M"
            )

        # Confirm autoneg is back on after exit
        after = link.link_state(eth_iface)
        assert after["autoneg"] is True, (
            f"autoneg not restored: {after['autoneg']}"
        )

    def test_round_trip_speed_cycle(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """Drive the speed transition both ways: 1G → 100M → 1G in
        one test, with ARP probes at each step.

        Catches state-reset bugs that only manifest on the second
        transition (e.g. PHY register left in 100M state when going
        back to 1G).
        """
        # Start: 1G autoneg
        assert link.link_state(eth_iface)["speed_mbps"] == 1000

        # Down to 100M
        with link.temporary_link_speed(eth_iface, 100, settle_ms=10000):
            assert link.link_state(eth_iface)["speed_mbps"] == 100
            reply = _arp_probe(
                eth_iface, laptop_mac, laptop_ip, pi_mac, deadline_ms=2000,
            )
            assert reply is not None, "ARP failed at 100M (first transition)"

        # Back to 1G (auto)
        link.wait_for_speed(eth_iface, 1000, deadline_ms=10000)
        reply = _arp_probe(
            eth_iface, laptop_mac, laptop_ip, pi_mac,
            deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
        )
        assert reply is not None, "ARP failed at 1G after restore"

        # Down to 100M AGAIN
        with link.temporary_link_speed(eth_iface, 100, settle_ms=10000):
            reply = _arp_probe(
                eth_iface, laptop_mac, laptop_ip, pi_mac, deadline_ms=2000,
            )
            assert reply is not None, (
                "ARP failed at 100M (second transition — state reset bug?)"
            )


# --- Helpers ---

def _arp_probe(iface, laptop_mac, laptop_ip, pi_mac, *, deadline_ms):
    request = eth_frames.build_arp_request(laptop_mac, laptop_ip, PI4_IP)
    bpf = (
        f"arp and ether src {eth_frames.mac_bytes_to_str(pi_mac)} "
        f"and ether dst {eth_frames.mac_bytes_to_str(laptop_mac)}"
    )
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
