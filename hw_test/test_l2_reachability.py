"""
test_l2_reachability.py — L2 baseline reachability for the Pi 4 GENET stack.

These are the foundation tests for the L2 hardening suite. They MUST
pass before any other test_l2_*.py file is meaningful: every later test
depends on the Pi being ARP-reachable on the test interface.

Coverage:
  * Unicast ARP request → reply (sender HW + protocol address correct)
  * Broadcast ARP request → reply (proves Pi has no over-strict MAC filter)
  * RTT baseline sanity (p99 within ceiling on direct gigabit cable)

Each test asserts on a meaningful value per project rule — no
"didn't crash" assertions.

Run:
    HW_TEST=1 .venv/bin/pytest hw_test/test_l2_reachability.py -v
"""

import pytest

import eth_frames
import wire
from conftest import requires_hardware, PI4_IP, RTT_BASELINE_CEILING_MS


@requires_hardware
@pytest.mark.l2
class TestArpReachability:
    """ARP-level reachability — the most basic L2 sanity check."""

    def test_unicast_arp_request_gets_reply(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """A unicast ARP request to the Pi's MAC gets a valid reply.

        The pi_mac fixture has already done one ARP probe to discover
        the MAC; this test sends a SECOND probe (now unicast) and
        asserts the full reply contents.
        """
        # Build a unicast ARP request directly to the Pi's MAC
        request = eth_frames.build_arp_request(
            laptop_mac, laptop_ip, PI4_IP, dst_mac=pi_mac,
        )

        bpf = (
            f"arp and ether src {eth_frames.mac_bytes_to_str(pi_mac)} "
            f"and ether dst {eth_frames.mac_bytes_to_str(laptop_mac)}"
        )
        deadline_ms = max(20.0 * rtt_p99_ms, 500.0)

        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frame(eth_iface, request)
            reply_bytes = wire.wait_for_frame(
                cap,
                lambda data: _is_arp_reply_from(data, pi_mac, PI4_IP),
                deadline_ms=int(deadline_ms),
            )

        assert reply_bytes is not None, (
            f"no unicast ARP reply from {PI4_IP} within {deadline_ms:.0f} ms "
            f"(BPF: {bpf})"
        )
        arp = eth_frames.parse_arp(reply_bytes)
        assert arp["opcode"] == eth_frames.ARP_OP_REPLY
        assert arp["sha"] == pi_mac
        assert arp["spa"] == PI4_IP
        assert arp["tha"] == laptop_mac
        assert arp["tpa"] == laptop_ip
        # Reply MUST be unicast back to us, not broadcast
        assert arp["eth_dst"] == laptop_mac
        assert arp["eth_src"] == pi_mac

    def test_broadcast_arp_request_gets_reply(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """A broadcast ARP request gets a valid reply.

        Proves the Pi has no over-strict MAC filter that drops
        broadcast frames before they reach the L2 dispatch. (lib/eth.S
        currently has no MAC filter at all, but this test pins that
        contract so a future filter regression is caught.)
        """
        request = eth_frames.build_arp_request(
            laptop_mac, laptop_ip, PI4_IP,
            dst_mac=eth_frames.BROADCAST_MAC,
        )

        bpf = (
            f"arp and ether src {eth_frames.mac_bytes_to_str(pi_mac)} "
            f"and ether dst {eth_frames.mac_bytes_to_str(laptop_mac)}"
        )
        deadline_ms = max(20.0 * rtt_p99_ms, 500.0)

        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frame(eth_iface, request)
            reply_bytes = wire.wait_for_frame(
                cap,
                lambda data: _is_arp_reply_from(data, pi_mac, PI4_IP),
                deadline_ms=int(deadline_ms),
            )

        assert reply_bytes is not None, (
            f"no ARP reply to broadcast request from {PI4_IP} "
            f"within {deadline_ms:.0f} ms"
        )
        arp = eth_frames.parse_arp(reply_bytes)
        assert arp["opcode"] == eth_frames.ARP_OP_REPLY
        assert arp["sha"] == pi_mac
        assert arp["spa"] == PI4_IP

    def test_pi_mac_is_stable_across_probes(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """Five sequential ARP probes return the same Pi MAC.

        Catches non-determinism in the Pi's ARP responder (e.g. some
        early-development bugs that returned uninitialized memory in
        the sender HW field).
        """
        deadline_ms = int(max(20.0 * rtt_p99_ms, 500.0))
        seen: list[bytes] = []
        for _ in range(5):
            request = eth_frames.build_arp_request(laptop_mac, laptop_ip, PI4_IP)
            bpf = f"arp and ether dst {eth_frames.mac_bytes_to_str(laptop_mac)}"
            with wire.WireCapture(eth_iface, bpf=bpf) as cap:
                wire.send_frame(eth_iface, request)
                reply = wire.wait_for_frame(
                    cap,
                    lambda data: _is_arp_reply_from(data, pi_mac, PI4_IP),
                    deadline_ms=deadline_ms,
                )
            assert reply is not None, "ARP probe lost mid-burst"
            seen.append(eth_frames.parse_arp(reply)["sha"])

        # All five probes returned the same MAC
        assert all(m == pi_mac for m in seen), (
            f"Pi MAC unstable across probes: {[m.hex() for m in seen]}"
        )


@requires_hardware
@pytest.mark.l2
class TestRttBaseline:
    """Sanity checks on the measured RTT baseline."""

    def test_rtt_p99_within_ceiling(self, rtt_p99_ms):
        """The session-start RTT baseline is within the ceiling.

        rtt_p99_ms fixture exits the session if it's not, but this
        test pins it explicitly so the assertion shows up in the
        report rather than as a session-level abort.
        """
        assert rtt_p99_ms > 0, "RTT baseline not measured"
        assert rtt_p99_ms < RTT_BASELINE_CEILING_MS, (
            f"RTT p99 {rtt_p99_ms:.2f} ms exceeds ceiling "
            f"{RTT_BASELINE_CEILING_MS} ms — test bench is broken"
        )

    def test_rtt_baseline_consistent_with_post_session_probe(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """A fresh ARP probe right now is no more than 5x the baseline.

        Catches drift between the session-start measurement and the
        actual mid-session reachability — if the Pi has degraded since
        startup, deadlines sized off rtt_p99_ms will silently fail
        unrelated tests, so we want to catch that explicitly.
        """
        import time
        request = eth_frames.build_arp_request(laptop_mac, laptop_ip, PI4_IP)
        bpf = f"arp and ether dst {eth_frames.mac_bytes_to_str(laptop_mac)}"
        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            t0 = time.monotonic()
            wire.send_frame(eth_iface, request)
            reply = wire.wait_for_frame(
                cap,
                lambda data: _is_arp_reply_from(data, pi_mac, PI4_IP),
                deadline_ms=int(max(20.0 * rtt_p99_ms, 500.0)),
            )
            elapsed_ms = (time.monotonic() - t0) * 1000.0
        assert reply is not None
        # 5x slack — wire_capture startup adds ~50ms, but rtt_p99_ms
        # comes from the same code path so they should track.
        assert elapsed_ms < 5 * rtt_p99_ms + 100, (
            f"current probe RTT {elapsed_ms:.2f} ms is way over "
            f"baseline p99 {rtt_p99_ms:.2f} ms — Pi may have degraded"
        )


# --- Module-private predicate ---

def _is_arp_reply_from(frame: bytes, expected_mac: bytes, expected_ip: str) -> bool:
    """Predicate for wait_for_frame: ARP reply with sender == expected."""
    try:
        arp = eth_frames.parse_arp(frame)
    except (ValueError, OSError):
        return False
    return (
        arp["opcode"] == eth_frames.ARP_OP_REPLY
        and arp["sha"] == expected_mac
        and arp["spa"] == expected_ip
    )
