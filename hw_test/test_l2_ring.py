"""
test_l2_ring.py — GENET descriptor ring wraparound exercises.

Bursts ARP requests at the Pi at boundary multiples of the 256-entry
RX descriptor ring and asserts:

  1. The Pi replies to all (or nearly all) of the burst.
  2. The Pi remains responsive after the burst (post-burst probe gets
     a reply within normal RTT).

The 256-frame boundary is the most interesting one — wraparound bugs
typically show up at index 256 → 0 first. Parametrizing across
[1, 50, 255, 256, 257, 512, 1024] hits below, exactly at, just over,
and a few wrap-cycles past the boundary.

NOTE: this exercises the Pi's RX descriptor ring (the laptop is the
sender). The Pi's TX ring is exercised by the reply traffic, so this
test indirectly covers both rings on the Pi side.

Run:
    HW_TEST=1 .venv/bin/pytest hw_test/test_l2_ring.py -v
"""

import pytest

import eth_frames
import wire
from conftest import requires_hardware, PI4_IP


# Boundaries around the 256-entry GENET RX ring.
# 1   — sanity baseline
# 50  — small burst
# 255 — one below wrap
# 256 — exactly at wrap
# 257 — one wrap
# 512 — two full cycles
# 1024 — four full cycles
RING_BURST_SIZES = [1, 50, 255, 256, 257, 512, 1024]


@requires_hardware
@pytest.mark.l2
class TestRingWraparound:

    @pytest.mark.parametrize("n", RING_BURST_SIZES)
    def test_burst_n_arp_replies_received(
        self, n, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """Send `n` ARP requests as a tight burst, count replies.

        For small n the Pi MUST reply to every request. For large n
        we tolerate up to ~5% reply loss because:
          - The Linux kernel may drop a few outgoing frames under
            burst conditions on the laptop side
          - The Pi's RX ring may genuinely overrun before software
            can drain it; the assertion is "the Pi recovers", not
            "zero loss in a flooded ring"
        After the burst we send ONE more probe and require a reply
        within normal RTT — that's the real recovery test.
        """
        # Build all the request frames up front so the send loop is
        # tight (no per-frame allocation in the hot path).
        request = eth_frames.build_arp_request(laptop_mac, laptop_ip, PI4_IP)
        burst = [request] * n

        # Tight BPF: only ARP replies from the Pi to us
        bpf = (
            f"arp and ether src {eth_frames.mac_bytes_to_str(pi_mac)} "
            f"and ether dst {eth_frames.mac_bytes_to_str(laptop_mac)}"
        )

        # Deadline scales with burst size: assume each round-trip can
        # cost up to rtt_p99_ms; add a 500 ms floor for setup overhead.
        burst_deadline_ms = int(max(n * rtt_p99_ms + 500, 1000))

        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            sent = wire.send_frames(eth_iface, burst)
            assert sent == n, f"laptop only sent {sent}/{n} frames"

            replies = wire.wait_for_frames(
                cap,
                _is_arp_reply,
                count=n,
                deadline_ms=burst_deadline_ms,
            )

        # Reply count assertion (tolerance ramps with burst size)
        if n <= 50:
            tolerance = 0  # small bursts must be lossless
        else:
            tolerance = max(1, n // 20)  # ~5% loss budget for large bursts
        min_expected = n - tolerance
        assert len(replies) >= min_expected, (
            f"got {len(replies)}/{n} ARP replies (tolerance {tolerance}, "
            f"min expected {min_expected}); deadline {burst_deadline_ms} ms"
        )

        # Reply payloads must all be well-formed
        for i, reply in enumerate(replies):
            arp = eth_frames.parse_arp(reply)
            assert arp["opcode"] == eth_frames.ARP_OP_REPLY, (
                f"reply {i} is not an ARP reply: opcode={arp['opcode']}"
            )
            assert arp["sha"] == pi_mac, (
                f"reply {i} sender MAC mismatch: "
                f"expected {pi_mac.hex()}, got {arp['sha'].hex()}"
            )
            assert arp["spa"] == PI4_IP, (
                f"reply {i} sender IP mismatch: expected {PI4_IP}, "
                f"got {arp['spa']}"
            )

    @pytest.mark.parametrize("n", RING_BURST_SIZES)
    def test_pi_responsive_after_burst(
        self, n, eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms
    ):
        """After an n-frame burst, the Pi answers a fresh probe within
        normal RTT — proving the descriptor ring (and the GENET driver
        state) recovered cleanly.

        Run as a separate test from the burst-counting one so the
        report distinguishes "burst lost some frames" from "Pi was
        permanently bricked by the burst".
        """
        request = eth_frames.build_arp_request(laptop_mac, laptop_ip, PI4_IP)
        burst = [request] * n

        # Send the burst (don't even capture replies — we just want
        # to stress the ring)
        sent = wire.send_frames(eth_iface, burst)
        assert sent == n

        # Now send a SINGLE fresh probe and assert reply within
        # generous-but-not-unbounded deadline. We give 50x the
        # baseline to absorb any post-burst settle time.
        bpf = (
            f"arp and ether src {eth_frames.mac_bytes_to_str(pi_mac)} "
            f"and ether dst {eth_frames.mac_bytes_to_str(laptop_mac)}"
        )
        deadline_ms = int(max(50.0 * rtt_p99_ms, 1000.0))
        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frame(eth_iface, request)
            reply = wire.wait_for_frame(
                cap, _is_arp_reply,
                deadline_ms=deadline_ms,
            )
        assert reply is not None, (
            f"Pi unresponsive after {n}-frame burst — no ARP reply within "
            f"{deadline_ms} ms"
        )
        arp = eth_frames.parse_arp(reply)
        assert arp["sha"] == pi_mac
        assert arp["spa"] == PI4_IP


# --- Module-private predicate ---

def _is_arp_reply(frame: bytes) -> bool:
    try:
        arp = eth_frames.parse_arp(frame)
    except (ValueError, OSError):
        return False
    return arp["opcode"] == eth_frames.ARP_OP_REPLY
