# mypy: disable-error-code="no-untyped-def"
# pylint: disable=missing-class-docstring
"""
test_burst_wedge.py — Isolate the concurrent-burst wedge by layer.

The Pi wedges after 10 concurrent HTTP connections (curl). But that
activates L2 + ARP + IP + TCP + HTTP simultaneously, making it
impossible to determine which layer causes the stall.

This test suite sends bursts at INDIVIDUAL layers to isolate:
  - L3-only burst: raw ICMP echo flood (no TCP, no HTTP)
  - L2-only burst: raw ARP flood (no IP at all)
  - Mixed L3: rapid sequential ICMP echoes

If an ICMP-only burst wedges the Pi, the bug is at L2/L3.
If only TCP bursts wedge it, the bug is in TCP close/state.

Uses wire.py raw L2 sockets — NO curl, NO HTTP, NO TCP.

Run:
    HW_TEST=1 .venv/bin/pytest hw_test/test_burst_wedge.py -v -s
"""

import time

import pytest

import eth_frames
import ip_frames
import wire
from conftest import PI4_IP, requires_hardware
from icmp_helpers import (
    icmp_bpf_from_pi,
    send_echo_and_wait,
)


BURST_SIZES = [10, 50, 100, 200]


def _verify_alive(
    eth_iface: str,
    pi_mac: bytes,
    laptop_mac: bytes,
    laptop_ip: str,
    rtt_p99_ms: float,
    *,
    tag: str,
) -> None:
    """Assert the Pi responds to a single ICMP echo."""
    deadline = int(max(20.0 * rtt_p99_ms, 1000.0))
    reply = send_echo_and_wait(
        eth_iface,
        pi_mac=pi_mac, laptop_mac=laptop_mac,
        pi_ip=PI4_IP, laptop_ip=laptop_ip,
        ident=0xDEAD, seq=1, payload=b"alive?",
        deadline_ms=deadline,
    )
    assert reply is not None, (
        f"Pi did not respond to ping after {tag} "
        f"(waited {deadline} ms)"
    )


@requires_hardware
class TestIcmpBurstWedge:
    """Send rapid ICMP echo bursts and verify the Pi stays alive.

    If the Pi wedges here, the bug is at L2 or L3 — TCP is not
    involved. If the Pi survives all sizes, the wedge is TCP-specific.
    """

    @pytest.mark.parametrize("n", BURST_SIZES)
    def test_icmp_burst_then_alive(
        self, n,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Fire N ICMP echo requests as fast as possible, then
        verify the Pi is still responsive.
        """
        frames = [
            ip_frames.build_icmp_echo_frame(
                laptop_mac, pi_mac, laptop_ip, PI4_IP,
                ident=0xB000 + i, seq=1,
                payload=b"burst!" + bytes([i & 0xFF]),
            )
            for i in range(n)
        ]

        # Fire the burst
        sent = wire.send_frames(eth_iface, frames)
        assert sent == n

        # Brief settle
        time.sleep(0.5)

        # Pi must still respond
        _verify_alive(
            eth_iface, pi_mac, laptop_mac, laptop_ip,
            rtt_p99_ms, tag=f"ICMP burst N={n}",
        )

    @pytest.mark.parametrize("n", BURST_SIZES)
    def test_icmp_burst_reply_count(
        self, n,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        """Fire N ICMP echoes, count how many replies arrive.
        Not all may arrive (ring overflow), but the Pi must not wedge.
        """
        frames = [
            ip_frames.build_icmp_echo_frame(
                laptop_mac, pi_mac, laptop_ip, PI4_IP,
                ident=0xC000 + i, seq=1,
                payload=b"count!",
            )
            for i in range(n)
        ]

        bpf = icmp_bpf_from_pi(pi_mac, laptop_mac)
        deadline_ms = int(max(20.0 * rtt_p99_ms, 2000.0))

        with wire.WireCapture(eth_iface, bpf=bpf) as cap:
            wire.send_frames(eth_iface, frames)
            replies = wire.wait_for_frames(
                cap,
                lambda data: True,  # any ICMP from Pi
                count=n,
                deadline_ms=deadline_ms,
            )

        print(
            f"BURST_WEDGE: n={n} replies={len(replies)} "
            f"loss={n - len(replies)}"
        )

        # Pi must still respond after the burst
        time.sleep(0.5)
        _verify_alive(
            eth_iface, pi_mac, laptop_mac, laptop_ip,
            rtt_p99_ms, tag=f"ICMP burst N={n} (counted)",
        )


@requires_hardware
class TestArpBurstWedge:
    """Send rapid ARP request bursts (L2 only, no IP) and verify
    the Pi stays alive. Isolates L2 from L3.
    """

    @pytest.mark.parametrize("n", BURST_SIZES)
    def test_arp_burst_then_alive(
        self, n,
        eth_iface, laptop_mac, laptop_ip, pi_mac, rtt_p99_ms,
    ):
        frames = [
            eth_frames.build_arp_request(
                laptop_mac, laptop_ip, PI4_IP,
            )
            for _ in range(n)
        ]

        sent = wire.send_frames(eth_iface, frames)
        assert sent == n

        time.sleep(0.5)

        _verify_alive(
            eth_iface, pi_mac, laptop_mac, laptop_ip,
            rtt_p99_ms, tag=f"ARP burst N={n}",
        )
