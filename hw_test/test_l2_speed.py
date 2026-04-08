"""
test_l2_speed.py — speed renegotiation recovery on the laptop side.

Restricts the laptop NIC's advertised speed to a non-default value
(100M), waits for the Pi to renegotiate down via auto-negotiation,
asserts ARP still works at the new speed, then restores the full
advertisement and verifies again. This catches GENET driver bugs
around link-speed transitions: PHY register state stale, RGMII
delay reconfiguration, MIB counter freeze logic broken on speed
change.

NOTE: link.link_set_speed deliberately keeps autoneg ON and only
restricts the advertise mask. The "autoneg off + force speed"
approach fails to bring up carrier when the remote side has autoneg
enabled (Pi 4 BCM54213PE always autonegs — we have no kernel-side
mechanism to force speed on the Pi). Restricting the advertise mask
is the IEEE-correct way to "force" a speed between two
autoneg-capable endpoints.

Uses link.temporary_link_speed which always restores even on test
body raise. The session-scope finalizer in conftest.py is the
second safety net.

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
                f"renegotiated speed didn't reach 100: "
                f"got {inside['speed_mbps']}"
            )
            assert inside["autoneg"] is True, (
                "autoneg should remain on (we restrict advertise, not force)"
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

    def test_advertise_only_1000m_then_arp(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """Restrict advertised speed to 1000M only; verify ARP works
        at the negotiated speed.

        Different code path from the default 1G autoneg: the laptop
        only OFFERS 1000M, not the full set, so the Pi PHY's autoneg
        state machine takes a slightly different path. Catches GENET
        bugs that only manifest when only one mode is in the advert.
        """
        with link.temporary_link_speed(eth_iface, 1000, settle_ms=10000):
            inside = link.link_state(eth_iface)
            assert inside["speed_mbps"] == 1000
            assert inside["autoneg"] is True
            assert inside["carrier"]

            reply = _arp_probe(
                eth_iface, laptop_mac, laptop_ip, pi_mac,
                deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
            )
            assert reply is not None, (
                "Pi did not answer ARP at advertised-only 1000M"
            )

        # Confirm we're back to advertising the full default set
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
