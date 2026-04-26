# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=line-too-long,too-few-public-methods,too-many-locals
# pylint: disable=duplicate-code,too-many-arguments,too-many-positional-arguments
# pylint: disable=redefined-outer-name,unused-argument
# mypy: ignore-errors
# flake8: noqa: E501
"""
test_l4_perf.py — TX hot-path (genet_send) perf assertions.

The PERF=send build wraps genet_send in main.S / drivers/genet.S
with cycle counters, accumulating send_ticks + send_count into
perf_counters. We stimulate the Pi to send by issuing N ICMP echo
requests; each request triggers one echo reply, which traverses the
TX path exactly once. After the burst we read perf_counters via
0x88B6 and assert:

  1. send_count tracks the number of replies we received (the Pi
     sent every reply we observed — no silent send-side drops).
  2. send_ticks / send_count is below SEND_NS_CEILING (catches a
     2x or worse regression in the TX path).

ICMP is the right stimulator because:
  - one request → exactly one reply, so send_count is unambiguous
  - the reply is built and pushed in one tight loop with no
    application-layer bookkeeping to dilute the measurement
  - we already have ICMP burst helpers in icmp_helpers.py

Skip cleanly if the Pi isn't a PERF build (perf_query times out)
or has PERF_COUNTERS but not PERF_SEND (send_ticks stays at 0).

Marker is `l4 and perf` so it slots into the existing perf-l4 phase
in scripts/hw_tests.sh.
"""

import time

import pytest

import ip_frames
import wire
from conftest import PI4_IP, requires_hardware
from icmp_helpers import (
    is_any_echo_reply_from_pi,
    send_echo_burst_and_wait,
)

pytestmark = [pytest.mark.perf, pytest.mark.l4]


# Per-send cost ceiling (ns). Observed on Pi 4 with PERF=send for a
# 64-byte ICMP echo reply: ~700-1200 ns. 3000 ns is ~2.5-4x —
# catches a regression without locking in current numbers.
SEND_NS_CEILING = 3000.0

BURST_N = 100
QUIESCE_MS = 500
ECHO_PAYLOAD = b"L4-perf-stimulus"
DEADLINE_MS = 5000


@pytest.fixture
def perf_send_session(eth_iface, laptop_mac, pi_mac):
    """Verify the Pi is on a PERF build that responds to perf_query.

    A PERF=send build has the readout handler compiled in. A default
    build doesn't — surface that as a skip rather than a deep failure.
    """
    try:
        wire.perf_query(eth_iface, pi_mac, laptop_mac, reset=True)
    except wire.WireError as e:
        pytest.skip(
            f"Pi is not a PERF build (perf_query failed: {e}). "
            f"Build with `make PLATFORM=pi4 PERF=send`."
        )

    class SendPerf:
        def snapshot(self) -> dict:
            return wire.perf_query(eth_iface, pi_mac, laptop_mac)

        def reset(self) -> dict:
            return wire.perf_query(eth_iface, pi_mac, laptop_mac, reset=True)

    return SendPerf()


def _stimulate_echo_burst(eth_iface, laptop_mac, laptop_ip, pi_mac, n):
    """Build n ICMP echo requests, send them, collect replies.
    Returns the list of reply frames (caller asserts len == n)."""
    frames = [
        ip_frames.build_icmp_echo_frame(
            laptop_mac, pi_mac, laptop_ip, PI4_IP,
            ident=0xC4FE, seq=i, payload=ECHO_PAYLOAD,
        )
        for i in range(n)
    ]
    return send_echo_burst_and_wait(
        eth_iface,
        pi_mac=pi_mac, laptop_mac=laptop_mac,
        pi_ip=PI4_IP, laptop_ip=laptop_ip,
        frames=frames,
        expected_count=n,
        match=lambda data: is_any_echo_reply_from_pi(
            data,
            pi_mac=pi_mac, laptop_mac=laptop_mac,
            pi_ip=PI4_IP, laptop_ip=laptop_ip,
        ),
        deadline_ms=DEADLINE_MS,
    )


@requires_hardware
class TestL4SendPerf:

    def test_send_count_tracks_burst(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, perf_send_session,
    ):
        """One reply per echo → send_count >= BURST_N."""
        perf_send_session.reset()
        replies = _stimulate_echo_burst(
            eth_iface, laptop_mac, laptop_ip, pi_mac, BURST_N,
        )
        assert len(replies) == BURST_N, (
            f"got {len(replies)}/{BURST_N} echo replies — "
            f"can't measure send perf if the burst itself is short"
        )
        time.sleep(QUIESCE_MS / 1000.0)

        snap = perf_send_session.snapshot()
        assert snap["send_count"] >= BURST_N, (
            f"send_count={snap['send_count']} < expected {BURST_N}; "
            f"replies arrived but the send-path counter didn't bump. "
            f"Snapshot: {snap}"
        )
        # Probes-not-compiled detection.
        assert snap["send_ticks"] > 0, (
            "send_count > 0 but send_ticks == 0 — Pi is built with "
            "PERF_COUNTERS but not PERF_SEND. Flash with "
            "`make PLATFORM=pi4 PERF=send` (or PERF=all)."
        )

    def test_send_cost_below_ceiling(
        self, eth_iface, laptop_mac, laptop_ip, pi_mac, perf_send_session,
    ):
        """ns/send is below SEND_NS_CEILING."""
        perf_send_session.reset()
        replies = _stimulate_echo_burst(
            eth_iface, laptop_mac, laptop_ip, pi_mac, BURST_N,
        )
        assert len(replies) == BURST_N, (
            f"got {len(replies)}/{BURST_N} echo replies — burst short"
        )
        time.sleep(QUIESCE_MS / 1000.0)

        snap = perf_send_session.snapshot()
        if snap["send_ticks"] == 0:
            pytest.skip(
                "send_ticks=0 — Pi missing PERF_SEND probes; see "
                "test_send_count_tracks_burst for the diagnostic."
            )

        ns_per = (
            wire.perf_ticks_to_ns(snap["send_ticks"])
            / max(snap["send_count"], 1)
        )
        # BURST_STATS / PERF_STATS lines for the perf-log scraper.
        print(
            f"BURST_STATS: n={BURST_N} replies={len(replies)} "
            f"send_ms=0 wire_pps=0 total_ms=0"
        )
        print(
            f"PERF_STATS: n={BURST_N} "
            f"recv_count={snap['recv_count']} "
            f"recv_none={snap['recv_none']} "
            f"dispatch_count={snap['dispatch_count']} "
            f"drop_count={snap['drop_count']} "
            f"send_count={snap['send_count']} "
            f"send_fail={snap['send_fail']} "
            f"max_burst={snap['max_burst']} "
            f"rx_discards={snap['rx_discards']} "
            f"recv_ns=0 dispatch_ns=0 send_ns={ns_per:.0f}"
        )

        assert ns_per < SEND_NS_CEILING, (
            f"send cost {ns_per:.0f} ns/frame exceeds ceiling "
            f"{SEND_NS_CEILING:.0f} ns. Snapshot: {snap}"
        )
